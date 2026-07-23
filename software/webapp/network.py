from __future__ import annotations

import fcntl
import socket
import struct
from pathlib import Path

from .models import BoardProfile, NetworkInterfaceInfo


SUPPORTED_UDP_INTERFACES = ("enp225s0f0", "enp225s0f1")
SIOCGIFADDR = 0x8915


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


def _read_text(path: Path, default: str) -> str:
    try:
        return path.read_text(encoding="ascii").strip()
    except OSError:
        return default


def list_udp_interfaces(sysfs_root: Path = Path("/sys/class/net")) -> list[NetworkInterfaceInfo]:
    result: list[NetworkInterfaceInfo] = []
    for name in SUPPORTED_UDP_INTERFACES:
        root = sysfs_root / name
        present = root.exists()
        operstate = _read_text(root / "operstate", "missing") if present else "missing"
        carrier = _read_text(root / "carrier", "0") == "1" if present else False
        address = _ipv4_address(name) if present and sysfs_root == Path("/sys/class/net") else None
        ipv4_addresses = [address] if address else []
        if not present:
            message = "服务器未发现该网卡"
        elif not carrier:
            message = "未检测到网线载波"
        elif not ipv4_addresses:
            message = "链路已连接，但未配置 IPv4 地址"
        else:
            message = f"链路已连接，IPv4 {ipv4_addresses[0]}"
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
