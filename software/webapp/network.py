from __future__ import annotations

import fcntl
import hashlib
import json
import os
import socket
import struct
import subprocess
from pathlib import Path

from .models import BoardProfile, NetworkInterfaceInfo


# These profiles describe host NIC preparation defaults only. They are not an
# inventory of FPGA boards; boards enter the workspace only after RFCTRL2
# discovery reports a device_uid.
PROFILED_UDP_INTERFACES = ("enp225s0f0", "enp225s0f1", "eno1np0", "eno2np1")
SIOCGIFADDR = 0x8915
FPGA_BOOTSTRAP_IP = "192.168.254.254"
FPGA_LINKLOCAL_DEFAULT_IP = "169.254.32.1"
AUTO_FPGA_LINK_PROFILES = {
    "enp225s0f0": {
        "target_ip": "192.168.1.128",
        "target_mac": "02:00:00:00:00:01",
        "target_profile": "custom_xczu47dr_master",
        "inventory_name": "XCZU47DR 081",
        "jtag_cable_serial": "210512180081",
        "serial_path": "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_AQ04KVC7-if00-port0",
        "source_ip": "192.168.1.10",
        "source_cidr": "192.168.1.10/24",
        "discovery_source_ip": "169.254.250.10",
        "discovery_source_cidr": "169.254.250.10/16",
        "bootstrap_source_ip": "192.168.254.10",
        "bootstrap_source_cidr": "192.168.254.10/24",
        "bootstrap_ip": FPGA_BOOTSTRAP_IP,
        "pool_prefix": "192.168.1",
        "pool_start": "128",
        "pool_end": "254",
    },
    "enp225s0f1": {
        "target_ip": "192.168.2.128",
        "target_mac": "02:00:00:00:00:02",
        "target_profile": "custom_xczu47dr_slave",
        "inventory_name": "XCZU47DR 082",
        "jtag_cable_serial": "210512180082",
        "serial_path": "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_AQ04KVC8-if00-port0",
        "source_ip": "192.168.2.10",
        "source_cidr": "192.168.2.10/24",
        "discovery_source_ip": "169.254.250.11",
        "discovery_source_cidr": "169.254.250.11/16",
        "bootstrap_source_ip": "192.168.254.11",
        "bootstrap_source_cidr": "192.168.254.11/24",
        "bootstrap_ip": FPGA_BOOTSTRAP_IP,
        "pool_prefix": "192.168.2",
        "pool_start": "128",
        "pool_end": "254",
    },
}
REQUIRED_LINK_CAPABILITIES = ("CAP_NET_ADMIN", "CAP_NET_RAW")
CAPABILITY_BITS = {
    "CAP_NET_ADMIN": 12,
    "CAP_NET_RAW": 13,
}


class NetworkAutoConfigError(RuntimeError):
    pass


def _decode_capability_names(mask: int) -> list[str]:
    return [name for name, bit in CAPABILITY_BITS.items() if mask & (1 << bit)]


def process_capability_report(status_path: Path = Path("/proc/self/status")) -> dict[str, object]:
    fields: dict[str, int] = {}
    try:
        for line in status_path.read_text(encoding="ascii").splitlines():
            if line.startswith(("CapEff:", "CapPrm:", "CapAmb:")):
                key, value = line.split(":", 1)
                fields[key] = int(value.strip(), 16)
    except OSError:
        fields = {}
    effective = _decode_capability_names(fields.get("CapEff", 0))
    permitted = _decode_capability_names(fields.get("CapPrm", 0))
    ambient = _decode_capability_names(fields.get("CapAmb", 0))
    missing = [name for name in REQUIRED_LINK_CAPABILITIES if name not in effective]
    return {
        "source": str(status_path),
        "effective": effective,
        "permitted": permitted,
        "ambient": ambient,
        "required": list(REQUIRED_LINK_CAPABILITIES),
        "missing": missing,
        "ok": not missing,
    }


def auto_fpga_link_profile(interface: str) -> dict[str, str] | None:
    profile = AUTO_FPGA_LINK_PROFILES.get(interface)
    return dict(profile) if profile else dynamic_fpga_link_profile(interface)


def explicit_auto_fpga_link_profile(interface: str) -> dict[str, str] | None:
    profile = AUTO_FPGA_LINK_PROFILES.get(interface)
    return dict(profile) if profile else None


def dynamic_fpga_link_profile(interface: str) -> dict[str, str] | None:
    if interface in AUTO_FPGA_LINK_PROFILES:
        return None
    if os.environ.get("RFSOC_WEB_DYNAMIC_FPGA_NICS", "1") != "1":
        return None
    root = Path("/sys/class/net") / interface
    if not root.exists() or _skip_dynamic_interface(root):
        return None
    if interface in _default_route_interfaces():
        return None
    speed = _read_int(root / "speed")
    if speed is not None and speed > 0 and speed < 10_000:
        return None
    digest = hashlib.blake2s(interface.encode("utf-8"), digest_size=2).digest()
    subnet = 32 + (digest[0] % 160)
    host_octet = 20 + (digest[1] % 180)
    linklocal_octet = 20 + (digest[0] % 200)
    return {
        "target_ip": f"192.168.{subnet}.128",
        "target_mac": "02:00:00:00:00:01",
        "target_profile": "custom_xczu47dr",
        "source_ip": f"192.168.{subnet}.10",
        "source_cidr": f"192.168.{subnet}.10/24",
        "discovery_source_ip": f"169.254.250.{host_octet}",
        "discovery_source_cidr": f"169.254.250.{host_octet}/16",
        "bootstrap_source_ip": f"192.168.254.{linklocal_octet}",
        "bootstrap_source_cidr": f"192.168.254.{linklocal_octet}/24",
        "bootstrap_ip": FPGA_BOOTSTRAP_IP,
        "pool_prefix": f"192.168.{subnet}",
        "pool_start": "128",
        "pool_end": "254",
        "dynamic": "1",
    }


def required_auto_source_cidrs(interface: str) -> list[str]:
    profile = auto_fpga_link_profile(interface)
    if profile is None:
        return []
    return [profile["source_cidr"], profile["discovery_source_cidr"], profile["bootstrap_source_cidr"]]


def missing_auto_source_addresses(interface: str) -> list[str]:
    addresses = set(_ipv4_addresses(interface))
    profile = auto_fpga_link_profile(interface)
    return _missing_auto_source_addresses(profile, addresses)


def _missing_auto_source_addresses(profile: dict[str, str] | None, addresses: set[str]) -> list[str]:
    if profile is None:
        return []
    missing: list[str] = []
    for cidr in required_auto_source_cidrs_from_profile(profile):
        address = cidr.split("/", 1)[0]
        if address not in addresses:
            missing.append(cidr)
    return missing


def required_auto_source_cidrs_from_profile(profile: dict[str, str]) -> list[str]:
    cidrs = [profile["source_cidr"], profile["discovery_source_cidr"]]
    bootstrap = profile.get("bootstrap_source_cidr")
    if bootstrap:
        cidrs.append(bootstrap)
    return cidrs


def _run_ip_command(args: list[str], interface: str) -> None:
    try:
        result = subprocess.run(
            args,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        raise NetworkAutoConfigError("服务器缺少 ip 命令，无法自动配置 FPGA 网口") from exc
    if result.returncode == 0:
        return
    error = (result.stderr or result.stdout or "unknown error").strip()
    if "File exists" in error:
        return
    raise NetworkAutoConfigError(
        f"无法自动配置 UDP 网卡 {interface}: {error}。"
        "网页后端需要 CAP_NET_ADMIN 才能执行 ip link/ip address，"
        "并需要 CAP_NET_RAW 才能把 UDP socket 绑定到指定物理网卡。"
        "请给后端进程授予这两个 capability，例如 systemd 配置 "
        "AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW 和 "
        "CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW。"
    )


def ensure_auto_link_ready(interface: str) -> list[str]:
    profile = auto_fpga_link_profile(interface)
    if profile is None:
        return []
    operstate = _read_text(Path("/sys/class/net") / interface / "operstate", "missing")
    if operstate != "up":
        _run_ip_command(["ip", "link", "set", "dev", interface, "up"], interface)
    return ensure_auto_source_addresses(interface)


def ensure_auto_source_addresses(interface: str) -> list[str]:
    added: list[str] = []
    for cidr in missing_auto_source_addresses(interface):
        _run_ip_command(["ip", "address", "replace", cidr, "dev", interface], interface)
        added.append(cidr)
    return added


def udp_source_ip_for_address(board: BoardProfile, address: str | None = None) -> str:
    profile = auto_fpga_link_profile(board.udp_interface)
    if profile and address:
        if address == profile["bootstrap_ip"]:
            return profile["bootstrap_source_ip"]
        if address.startswith("169.254.") or address in {"169.254.255.255", "255.255.255.255"}:
            return profile["discovery_source_ip"]
    return board.udp_source_ip


def ip_pool_for_interface(interface: str) -> list[str]:
    profile = auto_fpga_link_profile(interface)
    if profile is None:
        return []
    prefix = profile["pool_prefix"]
    start = int(profile["pool_start"])
    end = int(profile["pool_end"])
    return [f"{prefix}.{suffix}" for suffix in range(start, end + 1)]


def discovery_targets_for_interface(interface: str, known_ips: list[str] | tuple[str, ...] = ()) -> list[str]:
    profile = auto_fpga_link_profile(interface)
    if profile is None:
        return []
    targets: list[str] = []
    for address in known_ips:
        if address and address not in targets:
            targets.append(address)
    for address in (
        profile["target_ip"],
        profile["bootstrap_ip"],
        FPGA_LINKLOCAL_DEFAULT_IP,
        "169.254.255.255",
        "255.255.255.255",
    ):
        if address and address not in targets:
            targets.append(address)
    return targets


def discovery_target_profile(interface: str, reported_profile: str = "") -> str:
    """Resolve the fixed master/slave role when older PL reports a generic build."""
    profile = auto_fpga_link_profile(interface) or {}
    configured = profile.get("target_profile", "custom_xczu47dr")
    if reported_profile in {"", "custom_xczu47dr"} and configured in {
        "custom_xczu47dr_master",
        "custom_xczu47dr_slave",
    }:
        return configured
    return reported_profile or configured


def is_control_pool_ip(interface: str, address: str) -> bool:
    return address in set(ip_pool_for_interface(interface))


def _ipv4_address(interface: str) -> str | None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        request = struct.pack("256s", interface[:15].encode("ascii"))
        response = fcntl.ioctl(sock.fileno(), SIOCGIFADDR, request)
        return socket.inet_ntoa(response[20:24])
    except OSError:
        return None
    finally:
        sock.close()


def _ipv4_addresses(interface: str) -> list[str]:
    try:
        output = subprocess.check_output(
            ["ip", "-j", "address", "show", "dev", interface],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        devices = json.loads(output)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        address = _ipv4_address(interface)
        return [address] if address else []

    result: list[str] = []
    for device in devices:
        for item in device.get("addr_info", []):
            if item.get("family") == "inet" and item.get("local"):
                result.append(str(item["local"]))
    return result


def _read_text(path: Path, default: str) -> str:
    try:
        return path.read_text(encoding="ascii").strip()
    except OSError:
        return default


def _read_int(path: Path) -> int | None:
    try:
        return int(path.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return None


def _default_route_interfaces() -> set[str]:
    try:
        output = subprocess.check_output(
            ["ip", "-j", "route", "show", "default"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        routes = json.loads(output)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return set()
    return {str(route.get("dev")) for route in routes if route.get("dev")}


def _candidate_udp_interfaces(sysfs_root: Path) -> list[str]:
    names = set(PROFILED_UDP_INTERFACES)
    try:
        for item in sysfs_root.iterdir():
            name = item.name
            if _skip_dynamic_interface(item):
                continue
            names.add(name)
    except OSError:
        pass
    profiled_order = {name: index for index, name in enumerate(PROFILED_UDP_INTERFACES)}
    return sorted(names, key=lambda name: (0, profiled_order[name]) if name in profiled_order else (1, name))


def _skip_dynamic_interface(root: Path) -> bool:
    name = root.name
    if name in PROFILED_UDP_INTERFACES:
        return False
    if name == "lo" or name.startswith(("docker", "veth", "br-", "virbr", "wl", "tailscale", "zt")):
        return True
    try:
        if (root / "type").read_text(encoding="ascii").strip() != "1":
            return True
    except OSError:
        return True
    try:
        device_path = (root / "device").resolve(strict=False)
        return "/virtual/" in str(device_path) or "/usb" in str(device_path)
    except OSError:
        return True


def list_udp_interfaces(sysfs_root: Path = Path("/sys/class/net")) -> list[NetworkInterfaceInfo]:
    result: list[NetworkInterfaceInfo] = []
    for name in _candidate_udp_interfaces(sysfs_root):
        root = sysfs_root / name
        present = root.exists()
        operstate = _read_text(root / "operstate", "missing") if present else "missing"
        carrier = _read_text(root / "carrier", "0") == "1" if present else False
        ipv4_addresses = _ipv4_addresses(name) if present and sysfs_root == Path("/sys/class/net") else []
        profile = auto_fpga_link_profile(name) if present else None
        if not present:
            message = "服务器未发现该网卡"
        elif not carrier:
            message = "未检测到网线载波"
        elif not ipv4_addresses:
            message = "链路已连接，但未配置 IPv4 地址"
        else:
            message = f"链路已连接，IPv4 {', '.join(ipv4_addresses)}"
        if profile and profile.get("dynamic") == "1":
            message += "；动态 FPGA 候选网口"
        result.append(NetworkInterfaceInfo(
            name=name,
            present=present,
            operstate=operstate,
            carrier=carrier,
            ipv4_addresses=ipv4_addresses,
            message=message,
        ))
    return result


def udp_path_error(board: BoardProfile) -> str | None:
    try:
        ensure_auto_link_ready(board.udp_interface)
    except NetworkAutoConfigError as exc:
        return str(exc)
    interface = next(
        (item for item in list_udp_interfaces() if item.name == board.udp_interface),
        None,
    )
    if interface is None or not interface.present:
        return f"UDP 网卡 {board.udp_interface} 不存在"
    if not interface.carrier:
        return f"UDP 网卡 {board.udp_interface} 未检测到网线载波"
    if board.udp_source_ip not in interface.ipv4_addresses:
        configured = ", ".join(interface.ipv4_addresses) or "无"
        return (
            f"UDP 网卡 {board.udp_interface} 未配置源 IP {board.udp_source_ip}"
            f"（当前 IPv4: {configured}）"
        )
    return None
