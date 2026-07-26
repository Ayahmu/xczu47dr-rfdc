from __future__ import annotations

import fcntl
import json
import socket
import struct
import subprocess
from pathlib import Path

from .models import BoardProfile, NetworkInterfaceInfo


# Keep the dedicated SFP+ ports and the server's RJ45 ports available. The
# switch may bridge an RJ45 host link to the board's 10G SFP+ link.
SUPPORTED_UDP_INTERFACES = ("enp225s0f0", "enp225s0f1", "eno1np0", "eno2np1")
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


def list_udp_interfaces(sysfs_root: Path = Path("/sys/class/net")) -> list[NetworkInterfaceInfo]:
    result: list[NetworkInterfaceInfo] = []
    for name in SUPPORTED_UDP_INTERFACES:
        root = sysfs_root / name
        present = root.exists()
        operstate = _read_text(root / "operstate", "missing") if present else "missing"
        carrier = _read_text(root / "carrier", "0") == "1" if present else False
        ipv4_addresses = _ipv4_addresses(name) if present and sysfs_root == Path("/sys/class/net") else []
        if not present:
            message = "服务器未发现该网卡"
        elif not carrier:
            message = "未检测到网线载波"
        elif not ipv4_addresses:
            message = "链路已连接，但未配置 IPv4 地址"
        else:
            message = f"链路已连接，IPv4 {', '.join(ipv4_addresses)}"
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
