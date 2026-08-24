"""Shared network enrollment used by the three board-level wave tests.

The hardware tests deliberately keep their settings as module constants.  This
module contains only the common implementation: broadcast discovery, role/UID
selection, NETWORK_APPLY, NETWORK_RESTART, and verification at the assigned IP.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from .errors import DriverError
from .network import (
    DiscoveredBoard,
    connect_discovered,
    discover_boards,
    provision_board,
)


@dataclass(frozen=True)
class BoardNetworkAssignment:
    """Network identity requested by one hardware test.

    ``device_uid`` may be left empty when exactly one discovered board has the
    requested hardware role.  Set it when multiple master or slave boards are
    present.  ``mac`` may be left empty to preserve the DNA-derived board MAC.
    """

    label: str
    sync_role: str
    ip: str
    device_uid: str = ""
    mac: str | None = None
    subnet_mask: str = "255.255.0.0"
    gateway: str = "0.0.0.0"


@dataclass(frozen=True)
class EnrolledBoard:
    """Verified board identity returned to a hardware wave test."""

    label: str
    sync_role: str
    device_uid: str
    ip: str
    mac: str
    port: int


def _read_discovered_roles(boards: Sequence[DiscoveredBoard]) -> dict[str, str]:
    """Connect to each temporary address and read its bitstream role."""

    roles: dict[str, str] = {}
    for board in boards:
        device = connect_discovered(board, timeout_s=1.0, retries=2)
        try:
            role = str(device.status(refresh=False).capabilities.sync_role)
            roles[board.device_uid] = role
            print(
                f"发现板卡：UID={board.device_uid}，临时IP={board.current_ip}，"
                f"MAC={board.current_mac}，角色={role}"
            )
        finally:
            device.close()
    return roles


def _select_board(
    boards: Sequence[DiscoveredBoard],
    roles: dict[str, str],
    assignment: BoardNetworkAssignment,
    used_uids: set[str],
) -> DiscoveredBoard:
    expected_role = assignment.sync_role.strip().lower()
    expected_uid = assignment.device_uid.strip().lower()
    candidates = [
        board
        for board in boards
        if board.device_uid not in used_uids
        and roles.get(board.device_uid, "").lower() == expected_role
        and (not expected_uid or board.device_uid.lower() == expected_uid)
    ]
    if not candidates:
        identity = f"UID={assignment.device_uid}" if assignment.device_uid else "任意UID"
        raise DriverError(
            f"没有发现符合 {assignment.label} 的板卡：角色={expected_role}，{identity}"
        )
    if len(candidates) > 1:
        uids = ", ".join(board.device_uid for board in candidates)
        raise DriverError(
            f"发现多块角色为 {expected_role} 的板卡（{uids}）；"
            f"请在测试文件顶部填写 {assignment.label} 的 device_uid"
        )
    return candidates[0]


def discover_and_provision_boards(
    assignments: Sequence[BoardNetworkAssignment],
    *,
    interface: str,
    discovery_source_ip: str,
    discovery_source_cidr: str,
    control_source_ip: str,
    broadcast_ip: str = "169.254.255.255",
    port: int = 1234,
    timeout_s: float = 1.0,
    rounds: int = 3,
) -> list[EnrolledBoard]:
    """Discover, select, assign, restart, and verify all requested boards.

    ``discovery_source_ip`` is used while boards still have DNA-derived
    169.254.x.y addresses.  ``control_source_ip`` is used to verify and later
    control the assigned addresses.  They may be equal when assigned IPs remain
    in 169.254.0.0/16.  For another subnet, the host NIC must already own the
    matching control address.
    """

    if not assignments:
        raise ValueError("assignments must contain at least one board")
    target_ips = [assignment.ip for assignment in assignments]
    if len(target_ips) != len(set(target_ips)):
        raise DriverError("测试文件中的目标 IP 重复；每块板卡必须使用不同 IP")

    print(
        f"通过 {interface} 从 {discovery_source_ip} 广播 NETWORK_GET，"
        f"目标 {broadcast_ip}:{port}"
    )
    boards = discover_boards(
        interface=interface,
        source_ip=discovery_source_ip,
        source_cidr=discovery_source_cidr,
        broadcast_ip=broadcast_ip,
        port=port,
        timeout_s=timeout_s,
        rounds=rounds,
    )
    roles = _read_discovered_roles(boards)

    selected: list[tuple[BoardNetworkAssignment, DiscoveredBoard]] = []
    used_uids: set[str] = set()
    for assignment in assignments:
        board = _select_board(boards, roles, assignment, used_uids)
        selected.append((assignment, board))
        used_uids.add(board.device_uid)

    enrolled: list[EnrolledBoard] = []
    for assignment, board in selected:
        print(
            f"配置{assignment.label}：UID={board.device_uid}，"
            f"{board.current_ip} -> {assignment.ip}"
        )
        result = provision_board(
            board,
            ip=assignment.ip,
            mac=assignment.mac,
            subnet_mask=assignment.subnet_mask,
            gateway=assignment.gateway,
            port=port,
            known_boards=boards,
            verification_source_ip=control_source_ip,
        )
        enrolled.append(
            EnrolledBoard(
                label=assignment.label,
                sync_role=assignment.sync_role,
                device_uid=result.device_uid,
                ip=result.ip,
                mac=result.mac,
                port=result.port,
            )
        )
        print(
            f"{assignment.label}网络配置完成：UID={result.device_uid}，"
            f"IP={result.ip}，MAC={result.mac}"
        )
    return enrolled


__all__ = [
    "BoardNetworkAssignment",
    "EnrolledBoard",
    "discover_and_provision_boards",
]
