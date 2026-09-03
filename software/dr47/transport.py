"""UDP transport for RFCTRL2 and waveform packets."""

from __future__ import annotations

import socket
import sys
import time
from typing import Callable

from .errors import ProtocolError, TransportError, TransportTimeout
from .protocol import parse_rfresp2_packet

SO_BINDTODEVICE = getattr(socket, "SO_BINDTODEVICE", 25)

# Retransmitting the instant a receive times out can land while the board is
# still driving the response to the previous attempt.  That late reply carries
# our sequence number, so it is not filtered out - it gets consumed as the
# answer to the *next* request and desynchronizes every request/response pair
# after it.  Wait the board's send window out before resending.  Scales with
# the configured timeout and is clamped so a 5 s default does not stall a retry
# for seconds.
RETRY_BACKOFF_MIN_S = 0.002
RETRY_BACKOFF_MAX_S = 0.050


class UdpTransport:
    """Small, deterministic UDP transport used by :class:`Dr47Device`.

    A request packet is immutable across retries.  This matters for RFCTRL2:
    the sequence number identifies a logical command and must not change when
    a response is lost.
    """

    def __init__(
        self,
        ip: str,
        port: int = 1234,
        timeout_s: float = 5.0,
        udp_interface: str = "",
        udp_source_ip: str = "",
        socket_factory: Callable[..., object] | None = None,
        sock: object | None = None,
    ) -> None:
        self.ip = str(ip)
        self.port = int(port)
        self.timeout_s = float(timeout_s)
        if self.timeout_s <= 0:
            raise ValueError("timeout_s must be positive")
        self._closed = False
        self.sock = sock if sock is not None else (socket_factory or socket.socket)(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            self.sock.settimeout(self.timeout_s)
            if hasattr(self.sock, "setsockopt"):
                try:
                    self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                except OSError:
                    pass
            if udp_interface and sys.platform.startswith("linux"):
                if not hasattr(self.sock, "setsockopt"):
                    raise TransportError("UDP socket does not support interface binding")
                try:
                    self.sock.setsockopt(
                        socket.SOL_SOCKET,
                        SO_BINDTODEVICE,
                        str(udp_interface).encode("ascii") + b"\0",
                    )
                except OSError as exc:
                    # SO_BINDTODEVICE is Linux-specific and requires CAP_NET_RAW.
                    raise PermissionError(
                        f"binding UDP interface {udp_interface!r} failed; Linux requires CAP_NET_RAW"
                    ) from exc
            if udp_source_ip:
                self.sock.bind((str(udp_source_ip), 0))
        except Exception:
            try:
                self.sock.close()
            except Exception:
                pass
            raise

    @property
    def address(self) -> tuple[str, int]:
        return self.ip, self.port

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self.sock.close()
        except Exception:
            pass

    def send(self, packet: bytes) -> int:
        if self._closed:
            raise TransportError("UDP transport is closed")
        try:
            return int(self.sock.sendto(bytes(packet), self.address))
        except socket.timeout as exc:
            raise TransportTimeout(f"sending UDP packet to {self.ip}:{self.port} timed out") from exc
        except OSError as exc:
            raise TransportError(f"sending UDP packet to {self.ip}:{self.port} failed: {exc}") from exc

    def _source_matches(self, addr) -> bool:
        if not addr or len(addr) < 2 or int(addr[1]) != self.port:
            return False
        # Broadcast discovery may receive a response from the board's current
        # unicast address.  A unicast request must only accept its target.
        return self.ip in {"255.255.255.255", "169.254.255.255"} or str(addr[0]) == self.ip

    def receive_rfresp2(self, expected_seq: int | None = None, expected_opcode: int | None = None) -> dict:
        if self._closed:
            raise TransportError("UDP transport is closed")
        while True:
            try:
                packet, addr = self.sock.recvfrom(65535)
            except socket.timeout as exc:
                raise TransportTimeout(
                    f"timed out waiting for RFRESP2 from {self.ip}:{self.port}"
                ) from exc
            except OSError as exc:
                raise TransportError(f"receiving RFRESP2 failed: {exc}") from exc
            if not self._source_matches(addr):
                continue
            response = parse_rfresp2_packet(packet)
            if expected_seq is not None and int(response["seq"]) != (int(expected_seq) & 0xFFFFFFFF):
                continue
            if expected_opcode is not None and int(response["opcode"]) != (int(expected_opcode) & 0xFFFFFFFF):
                continue
            response["addr"] = addr
            return response

    def receive_rfresp2_many(
        self,
        *,
        expected_seq: int | None = None,
        expected_opcode: int | None = None,
        timeout_s: float = 1.0,
    ) -> list[dict]:
        """Collect all matching responses until *timeout_s* expires.

        Broadcast discovery produces one response per board, so callers must
        not use :meth:`receive_rfresp2`, which intentionally returns one
        response.  The socket timeout is restored before returning.
        """
        deadline = time.monotonic() + max(0.0, float(timeout_s))
        responses: list[dict] = []
        previous_timeout = self.timeout_s
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.sock.settimeout(remaining)
                try:
                    packet, addr = self.sock.recvfrom(65535)
                except socket.timeout:
                    break
                except OSError as exc:
                    raise TransportError(f"receiving RFRESP2 failed: {exc}") from exc
                if not self._source_matches(addr):
                    continue
                response = parse_rfresp2_packet(packet)
                if expected_seq is not None and int(response["seq"]) != (int(expected_seq) & 0xFFFFFFFF):
                    continue
                if expected_opcode is not None and int(response["opcode"]) != (int(expected_opcode) & 0xFFFFFFFF):
                    continue
                response["addr"] = addr
                responses.append(response)
        finally:
            self.sock.settimeout(previous_timeout)
        return responses

    def request(
        self,
        packet: bytes,
        *,
        seq: int,
        opcode: int,
        retries: int = 0,
        wait_response: bool = True,
    ):
        attempts = max(0, int(retries)) + 1
        immutable = bytes(packet)
        for attempt in range(attempts):
            self.send(immutable)
            if not wait_response:
                return len(immutable)
            try:
                return self.receive_rfresp2(expected_seq=seq, expected_opcode=opcode)
            except TransportTimeout:
                if attempt + 1 >= attempts:
                    raise
                time.sleep(self.retry_backoff_s())
        raise AssertionError("unreachable UDP retry state")

    def retry_backoff_s(self) -> float:
        """Delay inserted before a retransmit; see RETRY_BACKOFF_* above."""
        return min(RETRY_BACKOFF_MAX_S, max(RETRY_BACKOFF_MIN_S, self.timeout_s))

__all__ = ["UdpTransport", "SO_BINDTODEVICE"]
