"""Exceptions raised by :mod:`dr47`.

The public exception hierarchy intentionally keeps transport, protocol and
capability failures separate.  Applications can therefore decide whether a
failure is retryable without parsing an error string.
"""

from __future__ import annotations


class DriverError(Exception):
    """Base class for all driver errors."""


class ConnectionError(DriverError):
    """The board could not be reached or is not connected."""


class ConnectionStateError(DriverError):
    """An operation was attempted in an invalid connection state."""


class TransportError(DriverError):
    """A socket or network transport operation failed."""


class TransportTimeout(TransportError, TimeoutError):
    """A board response was not received before the configured deadline."""


class ProtocolError(DriverError):
    """A packet was malformed, truncated or used an incompatible version."""


class ProtocolVersionError(ProtocolError):
    """The board speaks a protocol version unsupported by this driver."""


class DeviceStatusError(DriverError):
    """The board returned a non-success RFCTRL2 status."""

    def __init__(self, operation: str, status: int, message: str = "") -> None:
        self.operation = str(operation)
        self.status = int(status) & 0xFFFF
        self.message = message or f"RFCTRL2 {self.operation} failed with status 0x{self.status:04X}"
        super().__init__(self.message)


class DeviceBusyError(DeviceStatusError):
    """The board is busy and cannot accept the requested operation."""


class DeviceNotReadyError(DeviceStatusError):
    """The board is online but its RFDC/playback path is not ready."""


class SynchronizationError(DriverError):
    """The board synchronization role or synchronization state is invalid."""


class SyncRequiredError(SynchronizationError):
    """An external Trigger path was used before external SYNC completed."""


class ParameterRangeError(DriverError, ValueError):
    """A user parameter is outside the hardware-supported range."""


class UnsupportedCapabilityError(DriverError, NotImplementedError):
    """The selected board does not advertise a required capability."""

    def __init__(self, operation: str, required: str = "", capabilities: int | None = None) -> None:
        self.operation = str(operation)
        self.required = str(required)
        self.capabilities = None if capabilities is None else int(capabilities)
        details = f" requires {self.required}" if self.required else ""
        advertised = ""
        if capabilities is not None:
            advertised = f"; board capabilities=0x{int(capabilities) & 0xFFFFFFFF:08X}"
        super().__init__(f"{self.operation}{details} is not supported by this board{advertised}")


class UnsupportedParameterError(UnsupportedCapabilityError):
    """A compatibility parameter has no safe physical mapping yet."""


class UnsupportedSequenceError(DriverError, ValueError):
    """An ez-Q sequence uses an instruction unsupported by this playback PL."""


class WaveformFormatError(ParameterRangeError):
    """Waveform data cannot be converted to the board's IQ layout."""


__all__ = [
    "DriverError",
    "ConnectionError",
    "ConnectionStateError",
    "TransportError",
    "TransportTimeout",
    "ProtocolError",
    "ProtocolVersionError",
    "DeviceStatusError",
    "DeviceBusyError",
    "DeviceNotReadyError",
    "SynchronizationError",
    "SyncRequiredError",
    "ParameterRangeError",
    "UnsupportedCapabilityError",
    "UnsupportedParameterError",
    "UnsupportedSequenceError",
    "WaveformFormatError",
]
