#!/usr/bin/env python3
"""One-command master/slave synchronization for two XCZU47DR boards.

Flow: wait until both boards report HMC7044 done, send one RFCTRL2 SYNC_EPOCH
to the master, wait until both boards report the single-pulse XS20 SYNC completed,
then wait until both boards publish DAC MTS and NCO SYSREF ready. With
--apply-arm-trigger the same script also performs RFDC_APPLY, ARM on both
boards, and TRIGGER on the master; upload the waveform to both boards first
with send_waveform_udp.py.
"""

import argparse
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import host  # noqa: E402


def _open_client(
    ip: str,
    port: int,
    interface: str,
    source_ip: str,
    args: argparse.Namespace,
) -> host.RFSocController:
    return host.RFSocController(
        ip,
        port=port,
        timeout_s=args.timeout_s,
        transport="udp",
        udp_interface=interface,
        udp_source_ip=source_ip,
    )


def _require_ok(response: dict, action: str, label: str) -> None:
    status = int(response.get("status", host.RF2_STATUS_BAD_REQUEST))
    if status != host.RF2_STATUS_OK:
        raise RuntimeError(f"{label}: {action} returned status 0x{status:04X}")


def _wait_network_state(
    client: host.RFSocController,
    label: str,
    key: str,
    timeout_s: float,
    poll_s: float,
    description: str,
) -> dict:
    deadline = time.monotonic() + timeout_s
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            response = client.rfctrl2_network_get(wait_response=True)
            if (
                int(response.get("status", host.RF2_STATUS_BAD_REQUEST)) == host.RF2_STATUS_OK
                and bool(response.get(key))
            ):
                return response
            last_error = None
        except (OSError, RuntimeError, ValueError, TimeoutError) as exc:
            last_error = exc
        time.sleep(poll_s)
    detail = f" ({last_error})" if last_error is not None else ""
    raise TimeoutError(f"{label}: timed out waiting for {description}{detail}")


def _wait_mts_ready(
    client: host.RFSocController,
    label: str,
    timeout_s: float,
    poll_s: float,
) -> dict:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        response = client.rfctrl2_status(wait_response=True)
        _require_ok(response, "STATUS", label)
        decoded = host.parse_rfctrl2_status_payload(response)
        if decoded["dac_mts_failed"]:
            raise RuntimeError(
                f"{label}: DAC MTS failed error=0x{int(decoded['dac_mts_error']) & 0xFFFF:04X}"
            )
        if decoded["dac_mts_ready"] and decoded["nco_sync_ready"]:
            return decoded
        time.sleep(poll_s)
    raise TimeoutError(f"{label}: timed out waiting for DAC MTS and NCO SYSREF ready")


def _wait_prepared(
    client: host.RFSocController,
    label: str,
    timeout_s: float,
    poll_s: float,
) -> dict:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        response = client.rfctrl2_status(wait_response=True)
        _require_ok(response, "STATUS", label)
        decoded = host.parse_rfctrl2_status_payload(response)
        if decoded["prepared"]:
            return decoded
        time.sleep(poll_s)
    raise TimeoutError(f"{label}: timed out waiting for PREPARED before TRIGGER")


def _apply_arm_trigger(
    master: host.RFSocController,
    slave: host.RFSocController,
    args: argparse.Namespace,
) -> None:
    default_nco = [-1.9e9, -1.9e9, -1.9e9, -1.9e9, 0.0, 0.0, -0.6e9, -0.2e9]
    default_zones = [2, 2, 2, 2, 1, 1, 2, 2]
    default_currents = [20.0, 20.0, 20.0, 20.0, 6.4, 6.4, 20.0, 20.0]
    nco_hz = [int(args.nco_hz)] * 8 if args.nco_hz is not None else [int(hz) for hz in default_nco]
    zones = [int(args.nyquist_zone)] * 8 if args.nyquist_zone is not None else default_zones
    phases = [float(args.phase_deg)] * 8
    currents = [float(args.current_ma)] * 8 if args.current_ma is not None else default_currents
    channel_mask = int(args.channel_mask) & 0xFF

    for client, label in ((master, "master"), (slave, "slave")):
        response = client.rfctrl2_rfdc_apply(
            nco_hz,
            zones,
            phases,
            currents,
            revision=int(args.revision),
            channel_mask=channel_mask,
            wait_response=True,
            retries=2,
        )
        _require_ok(response, "RFDC_APPLY", label)
        if int(response.get("error_mask", 0)) != 0:
            raise RuntimeError(
                f"{label}: RFDC_APPLY error_mask=0x{int(response['error_mask']) & 0xFF:02X}"
            )
        print(f"[sync] {label} RFDC_APPLY ok, applied_mask=0x{int(response['applied_mask']) & 0xFF:02X}")

    for client, label in ((master, "master"), (slave, "slave")):
        response = client.rfctrl2_arm(
            int(args.epoch) & 0xFFFFFFFF,
            channel_mask=channel_mask,
            wait_response=True,
        )
        _require_ok(response, "ARM", label)
        print(f"[sync] {label} ARM accepted")

    for client, label in ((master, "master"), (slave, "slave")):
        _wait_prepared(client, label, args.mts_timeout_s, args.poll_interval_s)
        print(f"[sync] {label} PREPARED")

    response = master.rfctrl2_trigger(wait_response=True)
    _require_ok(response, "TRIGGER", "master")
    print("[sync] master TRIGGER sent; slave starts on the master clk_dac2 edge")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--master-ip", required=True, help="master card RFCTRL2 IPv4 address")
    parser.add_argument("--slave-ip", required=True, help="slave card RFCTRL2 IPv4 address")
    parser.add_argument("--master-port", type=int, default=host.DEFAULT_BOARD_PORT)
    parser.add_argument("--slave-port", type=int, default=host.DEFAULT_BOARD_PORT)
    parser.add_argument("--udp-interface", default="enp225s0f0")
    parser.add_argument("--udp-source-ip", default="192.168.1.10")
    parser.add_argument(
        "--master-interface",
        default=None,
        help="master UDP interface; defaults to --udp-interface",
    )
    parser.add_argument(
        "--master-source-ip",
        default=None,
        help="master UDP source address; defaults to --udp-source-ip",
    )
    parser.add_argument(
        "--slave-interface",
        default=None,
        help="slave UDP interface; defaults to --udp-interface",
    )
    parser.add_argument(
        "--slave-source-ip",
        default=None,
        help="slave UDP source address; defaults to --udp-source-ip",
    )
    parser.add_argument("--timeout-s", type=float, default=5.0)
    parser.add_argument("--epoch", type=lambda text: int(text, 0), default=1)
    parser.add_argument("--sync-timeout-s", type=float, default=30.0)
    parser.add_argument("--mts-timeout-s", type=float, default=60.0)
    parser.add_argument("--poll-interval-s", type=float, default=0.5)
    parser.add_argument("--apply-arm-trigger", action="store_true")
    parser.add_argument("--nco-hz", type=float, default=None)
    parser.add_argument("--nyquist-zone", type=int, choices=(1, 2), default=None)
    parser.add_argument("--phase-deg", type=float, default=0.0)
    parser.add_argument("--current-ma", type=float, default=None)
    parser.add_argument("--channel-mask", type=lambda text: int(text, 0), default=0xFF)
    parser.add_argument("--revision", type=lambda text: int(text, 0), default=1)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    print(
        "[sync] plan: wait HMC done -> SYNC_EPOCH(master) -> wait HMC SYNC done -> "
        "wait MTS/NCO ready"
    )
    if args.apply_arm_trigger:
        print("[sync] plan: then RFDC_APPLY both -> ARM both -> TRIGGER master")
    if args.dry_run:
        print("[sync] dry-run: no UDP packets sent")
        return 0

    master = _open_client(
        args.master_ip,
        args.master_port,
        args.master_interface or args.udp_interface,
        args.master_source_ip or args.udp_source_ip,
        args,
    )
    slave = _open_client(
        args.slave_ip,
        args.slave_port,
        args.slave_interface or args.udp_interface,
        args.slave_source_ip or args.udp_source_ip,
        args,
    )
    try:
        master_net = _wait_network_state(
            master, "master", "hmc_done", args.sync_timeout_s, args.poll_interval_s, "HMC7044 done"
        )
        slave_net = _wait_network_state(
            slave, "slave", "hmc_done", args.sync_timeout_s, args.poll_interval_s, "HMC7044 done"
        )
        print(f"[sync] HMC done: master={master_net['device_uid']} slave={slave_net['device_uid']}")

        response = master.rfctrl2_sync_epoch(args.epoch, wait_response=True)
        _require_ok(response, "SYNC_EPOCH", "master")
        print(f"[sync] SYNC_EPOCH epoch={int(args.epoch)} sent to master")

        _wait_network_state(
            master, "master", "sync_done", args.sync_timeout_s, args.poll_interval_s, "HMC SYNC complete"
        )
        _wait_network_state(
            slave, "slave", "sync_done", args.sync_timeout_s, args.poll_interval_s, "HMC SYNC complete"
        )
        print("[sync] both boards observed the single-pulse XS20 SYNC")

        master_mts = _wait_mts_ready(master, "master", args.mts_timeout_s, args.poll_interval_s)
        slave_mts = _wait_mts_ready(slave, "slave", args.mts_timeout_s, args.poll_interval_s)
        print(
            f"[sync] MTS ready: master tiles=0x{int(master_mts['dac_mts_tile_mask']) & 0xF:X} "
            f"slave tiles=0x{int(slave_mts['dac_mts_tile_mask']) & 0xF:X}"
        )
        print("[sync] both boards report DAC MTS ready and NCO SYSREF ready")

        if args.apply_arm_trigger:
            _apply_arm_trigger(master, slave, args)
        return 0
    finally:
        master.close()
        slave.close()


if __name__ == "__main__":
    sys.exit(main())
