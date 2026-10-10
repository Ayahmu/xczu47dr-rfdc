"""Host side of the bulk waveform path: a stream of UDP datagrams, no replies.

Each datagram is a 22-byte bulk header followed by whole 64-byte DDR words
(see :func:`dr47.protocol.pack_wave_bulk_header`).  Datagrams are handed to
the kernel in batches with UDP generic segmentation offload: one ``sendmsg``
carries up to 64 of them and the network card cuts the batch apart, which is
what makes line rate reachable from a handful of threads.

Every thread sends on the same socket.  A socket keeps to one transmit queue
of the card, so each batch goes out as an unbroken run of consecutive
addresses.  One socket per thread looks faster and is not: the card
interleaves its queues frame by frame, the board then has to switch DDR4 rows
on every frame, and at line rate it drops about a fifth of them.

``BulkSender`` only sends.  Which chunks arrived is the board's knowledge;
:meth:`dr47.device.Dr47Device.upload_image_bulk` asks and resends.

The inner loop exists twice.  The Python one runs in the calling thread and
manages roughly 9 Gb/s; the interpreter lock would serialise more threads.
``_fastsend.c`` does the same work in C; it is compiled on first use with the
system C compiler into the user's cache directory and loaded with ctypes.
Without a compiler, or with ``DR47_FASTSEND=0``, the Python loop is used.
"""

from __future__ import annotations

import ctypes
import hashlib
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

from .errors import TransportError
from .protocol import (
    WAVE_BULK_HEADER_BYTES, WAVE_BULK_MAX_WORDS, WAVE_BULK_WORD_BYTES, pack_wave_bulk_header,
)
from .waveforms import LaneImage

SO_BINDTODEVICE = getattr(socket, "SO_BINDTODEVICE", 25)
UDP_SEGMENT = 103                 # linux/udp.h
_GSO_MAX_SEGMENTS = 64            # UDP_MAX_SEGMENTS on older kernels
_GSO_MAX_BYTES = 65000            # stay below the 64 KiB datagram limit
_IPV4_UDP_HEADER_BYTES = 28


def payload_bytes_for_interface(udp_interface: str = "") -> int:
    """Largest power-of-two payload whose datagram fits the interface MTU.

    1024 bytes at the standard 1500-byte MTU; 8192 with jumbo frames.  Falls
    back to 1024 when the MTU cannot be read.
    """
    mtu = 1500
    if udp_interface:
        try:
            mtu = int(Path(f"/sys/class/net/{udp_interface}/mtu").read_text().strip())
        except (OSError, ValueError):
            mtu = 1500
    room = mtu - _IPV4_UDP_HEADER_BYTES - WAVE_BULK_HEADER_BYTES
    payload = WAVE_BULK_MAX_WORDS * WAVE_BULK_WORD_BYTES
    while payload > WAVE_BULK_WORD_BYTES and payload > room:
        payload //= 2
    if payload > room:
        raise TransportError(f"interface MTU {mtu} is too small for a bulk datagram")
    return payload


_UNSET = object()
_fastsend_lib = _UNSET
_fastsend_lock = threading.Lock()


def _build_fastsend() -> ctypes.CDLL | None:
    source = Path(__file__).with_name("_fastsend.c")
    compiler = shutil.which(os.environ.get("CC", "cc")) or shutil.which("gcc")
    if not sys.platform.startswith("linux") or compiler is None or not source.is_file():
        return None
    code = source.read_bytes()
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "dr47"
    target = cache / f"_fastsend-{hashlib.sha256(code).hexdigest()[:16]}.so"
    try:
        if not target.is_file():
            cache.mkdir(parents=True, exist_ok=True)
            # Build next to the target and rename, so a concurrent process
            # never loads a half-written library.
            with tempfile.NamedTemporaryFile(dir=cache, suffix=".so", delete=False) as handle:
                temporary = Path(handle.name)
            try:
                subprocess.run([compiler, "-O2", "-shared", "-fPIC", "-pthread", "-o", str(temporary), str(source)],
                               check=True, capture_output=True, timeout=120)
                os.replace(temporary, target)
            finally:
                temporary.unlink(missing_ok=True)
        lib = ctypes.CDLL(str(target))
        lib.dr47_bulk_send.restype = ctypes.c_int64
        lib.dr47_bulk_send.argtypes = [
            ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint64,
            ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32]
        lib.dr47_bulk_send_lanes.restype = ctypes.c_int64
        lib.dr47_bulk_send_lanes.argtypes = [
            ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint64),
            ctypes.c_uint64, ctypes.c_uint64, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32]
        return lib
    except (OSError, subprocess.SubprocessError):
        return None


def load_fastsend() -> ctypes.CDLL | None:
    """The compiled sender core, or None when it cannot be built or is disabled."""
    global _fastsend_lib
    with _fastsend_lock:
        if _fastsend_lib is _UNSET:
            _fastsend_lib = None if os.environ.get("DR47_FASTSEND", "1") == "0" else _build_fastsend()
        return _fastsend_lib


class BulkSender:
    """Streams ranges of an image to the board's bulk UDP port.

    ``threads`` is the number of sender threads of the C core; they share one
    socket (see the module docstring).  ``accelerate`` selects that core:
    ``None`` uses it when it is available, ``False`` never, ``True`` requires
    it.
    """

    def __init__(self, ip: str, port: int, *, udp_interface: str = "", udp_source_ip: str = "",
                 threads: int = 4, accelerate: bool | None = None) -> None:
        self.ip = str(ip)
        self.port = int(port)
        self.udp_interface = str(udp_interface or "")
        self.udp_source_ip = str(udp_source_ip or "")
        self.threads = max(1, int(threads))
        self._sock: socket.socket | None = None
        self._gso = sys.platform.startswith("linux")
        self._lib = None if accelerate is False else load_fastsend()
        if accelerate and self._lib is None:
            raise TransportError("the C bulk sender is not available (no C compiler, or DR47_FASTSEND=0)")

    @property
    def accelerated(self) -> bool:
        return self._lib is not None

    def _socket(self) -> socket.socket:
        if self._sock is None:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                if self.udp_interface and sys.platform.startswith("linux"):
                    sock.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, self.udp_interface.encode("ascii") + b"\0")
                if self.udp_source_ip:
                    sock.bind((self.udp_source_ip, 0))
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
                sock.connect((self.ip, self.port))
            except OSError as exc:
                sock.close()
                raise TransportError(f"opening the bulk UDP socket failed: {exc}") from exc
            self._sock = sock
        return self._sock

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def send(self, image, start: int, end: int, *, session: int, epoch: int, payload_bytes: int) -> int:
        """Send image[start:end]; returns the number of datagrams handed to the kernel.

        ``image`` is the packed image (any bytes-like object) or a
        :class:`~dr47.waveforms.LaneImage`, whose lanes are gathered from the
        channel arrays while sending.
        """
        if not isinstance(image, LaneImage):
            image = memoryview(image).cast("B")
        start, end, payload_bytes = int(start), int(end), int(payload_bytes)
        if not 0 <= start < end <= len(image) or start % payload_bytes:
            raise ValueError("bulk range must be inside the image and start on a datagram boundary")
        sock = self._socket()
        batch = self._batch(sock, payload_bytes)
        if self._lib is None:
            return self._send_python(sock, batch, image, start, end, session, epoch, payload_bytes)
        if isinstance(image, LaneImage):
            return self._send_lanes(sock, batch, image, start, end, session, epoch, payload_bytes)
        return self._send_accelerated(sock, batch, image, start, end, session, epoch, payload_bytes)

    def _batch(self, sock: socket.socket, payload_bytes: int) -> int:
        """Datagrams per sendmsg: a full segmentation batch, or 1 without offload."""
        datagram = WAVE_BULK_HEADER_BYTES + payload_bytes
        if self._gso:
            try:
                sock.setsockopt(socket.IPPROTO_UDP, UDP_SEGMENT, datagram)
                return max(1, min(_GSO_MAX_SEGMENTS, _GSO_MAX_BYTES // datagram))
            except OSError:
                self._gso = False
        return 1

    def _send_accelerated(self, sock: socket.socket, batch: int, view: memoryview, start: int, end: int,
                          session: int, epoch: int, payload_bytes: int) -> int:
        # Borrow the buffer without copying it.  `keep` holds whatever owns
        # the memory until the call returns; the C side never writes.
        if view.readonly:
            keep = view.obj if isinstance(view.obj, bytes) and len(view.obj) == len(view) else bytes(view)
            address = ctypes.cast(ctypes.c_char_p(keep), ctypes.c_void_p).value
        else:
            keep = (ctypes.c_char * len(view)).from_buffer(view)
            address = ctypes.addressof(keep)
        result = self._lib.dr47_bulk_send(sock.fileno(), self.threads, address, start, end, session, epoch,
                                          payload_bytes, batch)
        del keep
        if result < 0:
            raise TransportError(f"sending bulk waveform data failed: {os.strerror(-result)}")
        return int(result)

    def _send_lanes(self, sock: socket.socket, batch: int, image: LaneImage, start: int, end: int,
                    session: int, epoch: int, payload_bytes: int) -> int:
        count = len(image.lanes)
        addresses = (ctypes.c_void_p * count)(*(None if lane is None else lane.ctypes.data for lane in image.lanes))
        sizes = (ctypes.c_uint64 * count)(*(0 if lane is None else lane.size for lane in image.lanes))
        result = self._lib.dr47_bulk_send_lanes(sock.fileno(), self.threads, addresses, sizes, start, end,
                                                session, epoch, payload_bytes, batch)
        if result < 0:
            raise TransportError(f"sending bulk waveform data failed: {os.strerror(-result)}")
        return int(result)

    def _send_python(self, sock: socket.socket, batch: int, image, start: int, end: int,
                     session: int, epoch: int, payload_bytes: int) -> int:
        sent = 0
        try:
            for first in range(start, end, batch * payload_bytes):
                last = min(first + batch * payload_bytes, end)
                block = memoryview(image.pack(first, last)) if isinstance(image, LaneImage) else image[first:last]
                parts = []
                for offset in range(first, last, payload_bytes):
                    length = min(payload_bytes, last - offset)
                    parts.append(pack_wave_bulk_header(session=session, byte_offset=offset,
                                                       words=length // WAVE_BULK_WORD_BYTES, epoch=epoch))
                    parts.append(block[offset - first:offset - first + length])
                sock.sendmsg(parts)
                sent += len(parts) // 2
        except OSError as exc:
            raise TransportError(f"sending bulk waveform data failed: {exc}") from exc
        return sent
