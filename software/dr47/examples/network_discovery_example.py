#!/usr/bin/env python3
"""Discover RFCTRL2 boards without changing board or host configuration.

Edit the constants below, make sure the source IP is already configured on the
selected interface, then run this file without command-line arguments.
"""

from __future__ import annotations

from dr47 import DriverError, discover_boards


# =============================================================================
# User configuration
# =============================================================================

UDP_INTERFACE = "enp1s0f0"
DISCOVERY_SOURCE_IP = "169.254.250.11"
DISCOVERY_SOURCE_CIDR = "169.254.250.11/16"
DISCOVERY_BROADCAST_IP = "169.254.255.255"
BOARD_PORT = 1234
DISCOVERY_TIMEOUT_S = 1.0
DISCOVERY_ROUNDS = 3


def main() -> int:
    try:
        boards = discover_boards(
            interface=UDP_INTERFACE,
            source_ip=DISCOVERY_SOURCE_IP,
            source_cidr=DISCOVERY_SOURCE_CIDR,
            broadcast_ip=DISCOVERY_BROADCAST_IP,
            port=BOARD_PORT,
            timeout_s=DISCOVERY_TIMEOUT_S,
            rounds=DISCOVERY_ROUNDS,
        )
    except DriverError as error:
        print(f"FAIL: {error}")
        return 1

    print(f"found {len(boards)} board(s)")
    for board in boards:
        print(
            f"UID={board.device_uid} IP={board.current_ip} "
            f"MAC={board.current_mac} profile={board.build_profile}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
