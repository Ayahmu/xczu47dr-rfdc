"""XCZU47DR direct UDP driver."""

from __future__ import annotations

from .capabilities import DeviceCapabilities, DeviceStatus, PlaybackState, RfdcChannelReadback
from .device import (
    Dr47Device,
    GHZ_TO_HZ,
    RFDC_NCO_MAX_GHZ,
    RFDC_NCO_MIN_GHZ,
    connect,
    ghz_to_hz,
    hz_to_ghz,
    rfdc_nco_plan_for_target,
)
from .errors import *  # noqa: F401,F403
from .errors import __all__ as _error_exports
from .protocol import *  # noqa: F401,F403
from .simulator import SimulatedDr47Device
from .transport import UdpTransport
from .network import (
    DiscoveredBoard,
    DiscoveryError,
    ProvisionError,
    ProvisionedBoard,
    connect_discovered,
    discover_boards,
    parse_ip_pool,
    prepare_interface,
    provision_board,
)
from .waveforms import *  # noqa: F401,F403
from ._version import __version__

__all__ = [
    "Dr47Device", "connect", "SimulatedDr47Device",
    "DeviceCapabilities", "DeviceStatus", "PlaybackState", "RfdcChannelReadback",
    "UdpTransport", "rfdc_nco_plan_for_target",
    "DiscoveredBoard", "ProvisionedBoard", "DiscoveryError", "ProvisionError",
    "discover_boards", "provision_board", "connect_discovered", "parse_ip_pool", "prepare_interface",
    "ghz_to_hz", "hz_to_ghz", "GHZ_TO_HZ", "RFDC_NCO_MIN_GHZ", "RFDC_NCO_MAX_GHZ",
    "__version__",
]
__all__ += [name for name in globals() if name.startswith(("RF", "UDP_", "DDR_", "pack_", "parse_", "align_", "require_", "normalize_", "ezq_"))]
__all__ += [name for name in _error_exports if name not in __all__]
