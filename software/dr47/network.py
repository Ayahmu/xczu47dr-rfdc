"""Multi-board network enrollment for switched XCZU47DR deployments."""

from __future__ import annotations

import ipaddress
import shutil
import subprocess
import time
from dataclasses import asdict, dataclass
from typing import Iterable

from .device import Dr47Device
from .errors import ConnectionError, DriverError, ParameterRangeError
from .protocol import (
    RF2_OP_NETWORK_GET,
    RF2_STATUS_OK,
    pack_rfctrl2_network_get,
    parse_rfctrl2_network_response,
)
from .transport import UdpTransport


class DiscoveryError(DriverError):
    """The host could not discover any usable RFCTRL2 board."""


class ProvisionError(DriverError):
    """A board network identity could not be provisioned and verified."""


@dataclass(frozen=True)
class DiscoveredBoard:
    device_uid: str
    current_ip: str
    current_mac: str
    build_profile: str = ""
    revision: int = 0
    port: int = 1234
    subnet_mask: str = "255.255.0.0"
    gateway: str = "0.0.0.0"
    response_address: str = ""
    interface: str = ""
    source_ip: str = ""

    @property
    def ip(self) -> str:
        return self.current_ip

    @property
    def identity_key(self) -> tuple[str, str]:
        """返回发现阶段使用的稳定复合身份。

        某些旧版或特定批次 bitstream 可能让多块板报告相同的 DNA UID。
        MAC 地址仍然不同，因此不能只用 ``device_uid`` 去重或选择板卡。
        """
        return self.device_uid.strip().lower(), self.current_mac.strip().lower()

    def as_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class ProvisionedBoard:
    device_uid: str
    previous_ip: str
    ip: str
    mac: str
    subnet_mask: str
    gateway: str
    port: int
    revision: int
    build_profile: str = ""
    verified: bool = True

    def as_dict(self) -> dict[str, object]:
        return asdict(self)


def _validate_ipv4(value: str, field: str) -> str:
    try:
        return str(ipaddress.IPv4Address(value))
    except ipaddress.AddressValueError as exc:
        raise ParameterRangeError(f"{field} must be an IPv4 address: {value!r}") from exc


def _validate_mac(value: str) -> str:
    raw = str(value).replace(":", "").replace("-", "")
    if len(raw) != 12:
        raise ParameterRangeError(f"MAC address must contain 12 hex digits: {value!r}")
    try:
        number = int(raw, 16)
    except ValueError as exc:
        raise ParameterRangeError(f"invalid MAC address: {value!r}") from exc
    first = (number >> 40) & 0xFF
    if number in {0, 0xFFFFFFFFFFFF} or first & 1:
        raise ParameterRangeError(f"MAC address must be a non-zero unicast address: {value!r}")
    return ":".join(raw[index:index + 2].lower() for index in range(0, 12, 2))


def _board_from_response(response: dict, interface: str, source_ip: str) -> DiscoveredBoard | None:
    if int(response.get("status", 1)) != RF2_STATUS_OK:
        return None
    decoded = parse_rfctrl2_network_response(response)
    uid = str(decoded.get("device_uid") or "")
    current_ip = str(decoded.get("current_ip") or "")
    current_mac = str(decoded.get("current_mac") or "")
    addr = response.get("addr")
    response_address = str(addr[0]) if isinstance(addr, tuple) and addr else current_ip
    if not uid or not current_ip or not current_mac:
        return None
    return DiscoveredBoard(
        device_uid=uid,
        current_ip=current_ip,
        current_mac=current_mac,
        build_profile=str(decoded.get("build_profile") or ""),
        revision=int(decoded.get("revision") or 0),
        port=int(decoded.get("port") or 1234),
        subnet_mask=str(decoded.get("subnet_mask") or "255.255.0.0"),
        gateway=str(decoded.get("gateway") or "0.0.0.0"),
        response_address=response_address,
        interface=interface,
        source_ip=source_ip,
    )


def discover_boards(
    interface: str,
    source_ip: str,
    source_cidr: str = "169.254.250.10/16",
    broadcast_ip: str = "169.254.255.255",
    port: int = 1234,
    timeout_s: float = 1.0,
    rounds: int = 3,
) -> list[DiscoveredBoard]:
    """Discover every board replying to a link-local RFCTRL2 broadcast."""
    _validate_ipv4(source_ip, "source_ip")
    _validate_ipv4(broadcast_ip, "broadcast_ip")
    if not 1 <= int(port) <= 65535:
        raise ParameterRangeError("port must be in 1..65535")
    if float(timeout_s) <= 0 or int(rounds) < 1:
        raise ParameterRangeError("timeout_s must be positive and rounds must be >= 1")
    # source_cidr is part of the public API so callers can document/validate
    # the intended /16; socket binding still uses the exact configured address.
    try:
        network = ipaddress.ip_interface(source_cidr)
        if network.network.prefixlen != 16 or network.ip != ipaddress.ip_address(source_ip):
            raise ValueError
    except ValueError as exc:
        raise ParameterRangeError("source_cidr must contain source_ip with a /16 prefix") from exc

    transport = UdpTransport(
        broadcast_ip,
        port=int(port),
        timeout_s=float(timeout_s),
        udp_interface=interface,
        udp_source_ip=source_ip,
    )
    # 不能只按 device_uid 去重：交换机上多块板可能共享同一个 UID，而每块
    # 板的 MAC 仍然唯一。复合键可同时支持正常 UID 和旧 bitstream。
    found: dict[tuple[str, str], DiscoveredBoard] = {}
    try:
        for _ in range(int(rounds)):
            sequence = int(time.time_ns()) & 0xFFFFFFFF or 1
            packet = pack_rfctrl2_network_get(sequence)
            transport.send(packet)
            for response in transport.receive_rfresp2_many(
                expected_seq=sequence,
                expected_opcode=RF2_OP_NETWORK_GET,
                timeout_s=float(timeout_s),
            ):
                board = _board_from_response(response, interface, source_ip)
                if board is not None:
                    found.setdefault(board.identity_key, board)
    finally:
        transport.close()
    if not found:
        raise DiscoveryError(
            f"no RFCTRL2 boards replied on {interface} via {broadcast_ip}:{port}; "
            "check the 169.254.0.0/16 address, VLAN broadcast and link state"
        )
    return sorted(found.values(), key=lambda board: board.identity_key)


def connect_discovered(board: DiscoveredBoard, *, timeout_s: float = 5.0, retries: int = 2) -> Dr47Device:
    """Create and connect a normal single-board device from discovery data."""
    device = Dr47Device(
        ip=board.current_ip,
        port=board.port,
        timeout_s=timeout_s,
        udp_interface=board.interface,
        udp_source_ip=board.source_ip,
        retries=retries,
    )
    device.connect()
    if device.capabilities.device_uid and device.capabilities.device_uid != board.device_uid:
        device.close()
        raise ProvisionError(f"connected board UID mismatch: expected {board.device_uid}, got {device.capabilities.device_uid}")
    return device


def _check_duplicate_assignments(
    boards: Iterable[DiscoveredBoard],
    ip: str,
    mac: str,
    *,
    exclude_device_uid: str = "",
    exclude_device_mac: str = "",
) -> None:
    """拒绝与其他板卡冲突的 IP/MAC，同时跳过正在配置的同一板卡。

    ``device_uid`` 不是充分身份，因此只有 UID 和 MAC 同时相同才视为“自身”。
    这样即使两块板 UID 相同，也能正确发现它们共用临时 IP 的冲突。
    """
    normalized_uid = str(exclude_device_uid).strip().lower()
    normalized_mac = str(mac).strip().lower()
    identity_mac = str(exclude_device_mac or mac).strip().lower()
    for board in boards:
        if (
            normalized_uid
            and board.device_uid.strip().lower() == normalized_uid
            and board.current_mac.strip().lower() == identity_mac
        ):
            continue
        if board.current_ip == ip and board.current_mac.lower() != mac.lower():
            raise ProvisionError(f"IP {ip} is already used by discovered device {board.device_uid}")
        if board.current_mac.lower() == mac.lower() and board.current_ip != ip:
            raise ProvisionError(f"MAC {mac} is already used by discovered device {board.device_uid}")


def _probe_ip_conflict(ip: str, interface: str) -> bool | None:
    """Return True for conflict, False for free, None when arping is absent."""
    arping = shutil.which("arping")
    if not arping:
        return None
    result = subprocess.run(
        [arping, "-D", "-I", interface, "-c", "2", "-w", "2", ip],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.returncode != 0


def provision_board(
    board: DiscoveredBoard,
    ip: str,
    mac: str | None = None,
    subnet_mask: str = "255.255.255.0",
    gateway: str = "0.0.0.0",
    port: int = 1234,
    revision: int | None = None,
    *,
    known_boards: Iterable[DiscoveredBoard] = (),
    reject_unverified_conflict: bool = False,
    verification_source_ip: str | None = None,
) -> ProvisionedBoard:
    """Apply a static identity, restart the board, and verify the new IP."""
    target_ip = _validate_ipv4(ip, "ip")
    target_mask = _validate_ipv4(subnet_mask, "subnet_mask")
    target_gateway = _validate_ipv4(gateway, "gateway")
    target_mac = _validate_mac(mac or board.current_mac)
    verified_source_ip = ""
    if verification_source_ip is not None:
        verified_source_ip = _validate_ipv4(
            verification_source_ip,
            "verification_source_ip",
        )
    if not 1 <= int(port) <= 65535:
        raise ParameterRangeError("port must be in 1..65535")
    _check_duplicate_assignments(
        known_boards,
        target_ip,
        target_mac,
        exclude_device_uid=board.device_uid,
        exclude_device_mac=board.current_mac,
    )
    # The board itself legitimately answers ARP when the requested address is
    # already its current address.  Treat that as an idempotent re-apply, not
    # as an address conflict.
    conflict = False if target_ip == board.current_ip else _probe_ip_conflict(target_ip, board.interface)
    if conflict is True:
        raise ProvisionError(f"IP conflict detected for {target_ip}")
    if conflict is None and reject_unverified_conflict:
        raise ProvisionError("cannot verify IP conflict state: arping is unavailable")

    device = Dr47Device(
        ip=board.current_ip,
        port=board.port,
        timeout_s=3.0,
        udp_interface=board.interface,
        udp_source_ip=verified_source_ip,
        retries=2,
    )
    try:
        try:
            apply_response = device.rfctrl2_network_apply(
                revision=int(board.revision + 1 if revision is None else revision),
                ip=target_ip,
                mac=target_mac,
                subnet_mask=target_mask,
                gateway=target_gateway,
                port=int(port),
            )
        except Exception as exc:
            raise ProvisionError(f"NETWORK_APPLY failed for {board.device_uid}: {exc}") from exc
        applied_revision = int(apply_response.get("revision") or (board.revision + 1 if revision is None else revision))
        try:
            device.rfctrl2_network_restart()
        except Exception as exc:
            raise ProvisionError(f"NETWORK_RESTART failed for {board.device_uid}: {exc}") from exc
    except ProvisionError:
        raise
    except Exception as exc:
        device.close()
        raise ProvisionError(f"network configuration failed for {board.device_uid}: {exc}") from exc
    finally:
        device.close()

    confirmed = Dr47Device(
        ip=target_ip,
        port=int(port),
        timeout_s=3.0,
        udp_interface=board.interface,
        udp_source_ip=board.source_ip,
        retries=3,
    )
    try:
        response = confirmed.rfctrl2_network_get()
    except Exception as exc:
        confirmed.close()
        raise ProvisionError(f"new IP {target_ip} did not respond for {board.device_uid}: {exc}") from exc
    finally:
        confirmed.close()
    if str(response.get("device_uid") or "") != board.device_uid:
        raise ProvisionError(
            f"new IP {target_ip} returned device_uid {response.get('device_uid')!r}, expected {board.device_uid}"
        )
    return ProvisionedBoard(
        device_uid=board.device_uid,
        previous_ip=board.current_ip,
        ip=target_ip,
        mac=str(response.get("current_mac") or target_mac),
        subnet_mask=str(response.get("subnet_mask") or target_mask),
        gateway=str(response.get("gateway") or target_gateway),
        port=int(response.get("port") or port),
        revision=int(response.get("revision") or applied_revision),
        build_profile=str(response.get("build_profile") or board.build_profile),
    )


def parse_ip_pool(value: str) -> list[str]:
    """Parse a same-subnet inclusive range such as 10.50.0.101-10.50.0.120."""
    parts = str(value).split("-", 1)
    if len(parts) != 2:
        raise ParameterRangeError("IP pool must be START-END")
    start = ipaddress.IPv4Address(parts[0].strip())
    end = ipaddress.IPv4Address(parts[1].strip())
    if int(end) < int(start):
        raise ParameterRangeError("IP pool end must not precede start")
    if (int(start) >> 8) != (int(end) >> 8):
        raise ParameterRangeError("IP pool must remain within one /24 subnet")
    return [str(ipaddress.IPv4Address(number)) for number in range(int(start), int(end) + 1)]


def prepare_interface(interface: str, source_cidr: str) -> None:
    """Explicitly configure the link-local source address using Linux `ip`."""
    if "/" not in source_cidr:
        raise ParameterRangeError("source_cidr must include a prefix, e.g. 169.254.250.10/16")
    try:
        ipaddress.ip_interface(source_cidr)
    except ValueError as exc:
        raise ParameterRangeError(f"invalid source_cidr: {source_cidr}") from exc
    result = subprocess.run(["ip", "link", "set", "dev", interface, "up"], check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise ConnectionError(result.stderr.strip() or f"unable to bring up {interface}")
    result = subprocess.run(["ip", "address", "replace", source_cidr, "dev", interface], check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise ConnectionError(result.stderr.strip() or f"unable to configure {source_cidr} on {interface}")


__all__ = [
    "DiscoveryError", "ProvisionError", "DiscoveredBoard", "ProvisionedBoard",
    "discover_boards", "connect_discovered", "provision_board", "parse_ip_pool", "prepare_interface",
]
