"""Command line entry point for switched multi-board enrollment."""

from __future__ import annotations

import argparse
import json
import sys

from .device import Dr47Device
from .errors import DriverError
from .network import discover_boards, parse_ip_pool, prepare_interface, provision_board


def _common_discovery(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--interface", required=True)
    parser.add_argument("--source-ip", required=True)
    parser.add_argument("--source-cidr", default=None)
    parser.add_argument("--broadcast-ip", default="169.254.255.255")
    parser.add_argument("--port", type=int, default=1234)
    parser.add_argument("--timeout", type=float, default=1.0)
    parser.add_argument("--rounds", type=int, default=3)


def _discover(args):
    return discover_boards(
        interface=args.interface,
        source_ip=args.source_ip,
        source_cidr=args.source_cidr or f"{args.source_ip}/16",
        broadcast_ip=args.broadcast_ip,
        port=args.port,
        timeout_s=args.timeout,
        rounds=args.rounds,
    )


def _print_boards(boards, as_json: bool) -> None:
    if as_json:
        print(json.dumps([board.as_dict() for board in boards], ensure_ascii=True, indent=2))
        return
    print("DEVICE_UID        CURRENT_IP       CURRENT_MAC             PROFILE")
    for board in boards:
        print(f"{board.device_uid:<18} {board.current_ip:<16} {board.current_mac:<24} {board.build_profile}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dr47-network", description="XCZU47DR switched multi-board network enrollment")
    sub = parser.add_subparsers(dest="command", required=True)
    discover = sub.add_parser("discover", help="broadcast NETWORK_GET")
    _common_discovery(discover)
    discover.add_argument("--json", action="store_true")
    plan = sub.add_parser("plan", help="preview static IP assignments")
    _common_discovery(plan)
    plan.add_argument("--ip-pool", required=True, help="inclusive range START-END")
    plan.add_argument("--json", action="store_true")
    provision = sub.add_parser("provision", help="configure one discovered board")
    _common_discovery(provision)
    provision.add_argument("--device-uid", required=True)
    provision.add_argument("--ip", required=True)
    provision.add_argument("--mac")
    provision.add_argument("--subnet-mask", default="255.255.255.0")
    provision.add_argument("--gateway", default="0.0.0.0")
    provision.add_argument("--json", action="store_true")
    for name in ("status", "connect"):
        command = sub.add_parser(name, help=f"{name} one board using unicast IP")
        command.add_argument("--ip", required=True)
        command.add_argument("--interface", required=True)
        command.add_argument("--source-ip", default="")
        command.add_argument("--port", type=int, default=1234)
        command.add_argument("--json", action="store_true")
    prepare = sub.add_parser("prepare-interface", help="configure host link-local address")
    prepare.add_argument("--interface", required=True)
    prepare.add_argument("--source-ip", required=True, help="address with prefix, e.g. 169.254.250.10/16")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "discover":
            _print_boards(_discover(args), args.json)
        elif args.command == "plan":
            boards = _discover(args)
            pool = parse_ip_pool(args.ip_pool)
            if len(pool) < len(boards):
                raise DriverError(f"IP pool has {len(pool)} addresses for {len(boards)} boards")
            rows = [{"device_uid": board.device_uid, "current_ip": board.current_ip, "ip": pool[index]} for index, board in enumerate(boards)]
            if args.json:
                print(json.dumps(rows, ensure_ascii=True, indent=2))
            else:
                for row in rows:
                    print(f"{row['device_uid']} -> {row['ip']} (current {row['current_ip']})")
        elif args.command == "provision":
            boards = _discover(args)
            board = next((item for item in boards if item.device_uid.lower() == args.device_uid.lower()), None)
            if board is None:
                raise DriverError(f"device_uid {args.device_uid} was not discovered")
            result = provision_board(board, args.ip, args.mac, args.subnet_mask, args.gateway, args.port, known_boards=boards)
            print(json.dumps(result.as_dict(), ensure_ascii=True, indent=2) if args.json else f"{result.device_uid} -> {result.ip} verified")
        elif args.command in {"status", "connect"}:
            device = Dr47Device(ip=args.ip, port=args.port, udp_interface=args.interface, udp_source_ip=args.source_ip)
            try:
                device.connect()
                status = device.status(refresh=False)
                payload = {"ip": args.ip, "port": args.port, "device_uid": status.capabilities.device_uid, "build_profile": status.capabilities.build_profile, "message": status.message}
                print(json.dumps(payload, ensure_ascii=True, indent=2) if args.json else f"{args.ip}:{args.port} online ({payload['device_uid']})")
            finally:
                device.close()
        elif args.command == "prepare-interface":
            prepare_interface(args.interface, args.source_ip)
            print(f"configured {args.interface} with {args.source_ip}")
        return 0
    except (DriverError, OSError, ValueError) as exc:
        print(f"dr47-network: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
