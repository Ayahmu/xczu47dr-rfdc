from __future__ import annotations

from datetime import UTC, datetime

from .management import ManagementError, ManagementStore
from .models import BoardRfdcConfig, BoardStatus, RfdcChannelConfig, RfdcConfigApplyRequest

import host


RFDC_STATUS_MESSAGES = {
    host.RF2_STATUS_BAD_VERSION: "RFCTRL2 protocol version is not supported by the PL",
    host.RF2_STATUS_UNSUPPORTED: "installed bitstream does not support PL RFDC runtime configuration",
    host.RF2_STATUS_BAD_REQUEST: "PL rejected the RFDC request format",
    host.RF2_STATUS_BUSY: "PL RFDC configuration controller is busy",
    host.RF2_STATUS_RFDC_NOT_READY: "RFDC tiles are not ready",
    host.RF2_STATUS_UNSAFE_STATE: "RFDC configuration requires playback to be muted and disarmed",
    host.RF2_STATUS_RANGE: "one or more RFDC channel parameters are outside the hardware range",
    host.RF2_STATUS_AXI_ERROR: "RFDC AXI-Lite transaction failed",
    host.RF2_STATUS_AXI_TIMEOUT: "RFDC AXI-Lite transaction timed out",
    host.RF2_STATUS_READBACK: "RFDC register readback did not match the requested configuration",
    host.RF2_STATUS_PARTIAL: "only part of the RFDC channel configuration was applied",
}


def default_rfdc_config(board_id: str) -> BoardRfdcConfig:
    targets = {1: 4.5e9, 2: 4.5e9, 3: 4.5e9, 4: 4.5e9, 5: 0.0, 6: 0.0, 7: 5.8e9, 8: 6.2e9}
    channels: list[RfdcChannelConfig] = []
    for channel in range(1, 9):
        plan = host.rfdc_nco_plan_for_target(targets[channel])
        channels.append(RfdcChannelConfig(
            channel=channel,
            target_rf_hz=targets[channel],
            nco_hz=float(plan["nco_hz"]),
            nyquist_zone=int(plan["nyquist_zone"]),
        ))
    return BoardRfdcConfig(board_id=board_id, channels=channels)


class RfdcConfigService:
    def __init__(self, store: ManagementStore, boards, serial, events) -> None:
        self.store = store
        self.boards = boards
        # Serial remains a separate diagnostic service. It is deliberately not
        # consulted anywhere in this RFDC runtime configuration service.
        self.events = events

    def get(self, board_id: str, refresh: bool = False) -> BoardRfdcConfig:
        self.store.board(board_id)
        current = self.store.load_rfdc_config(board_id) or default_rfdc_config(board_id)
        if not refresh:
            return current
        response = self.boards.rfdc_get_config(board_id)
        if int(response.get("status", host.RF2_STATUS_BAD_REQUEST)) != host.RF2_STATUS_OK:
            raise ManagementError(self._response_error(response))
        refreshed = self._config_from_hardware(current, response, "applied")
        self.store.save_rfdc_config(refreshed)
        return refreshed

    def apply(self, board_id: str, request: RfdcConfigApplyRequest) -> BoardRfdcConfig:
        self.store.board(board_id)
        current = self.get(board_id)
        status: BoardStatus = self.boards.status(board_id, refresh=True)
        allowed_states = {"OFFLINE", "IDLE", "MUTED"} if self.boards.simulation else {"IDLE", "MUTED"}
        if status.state.value not in allowed_states:
            raise ManagementError(
                f"RFDC parameters require a muted or idle board, current state is {status.state.value}"
            )

        channels = sorted(request.channels, key=lambda item: item.channel)
        revision = current.revision + 1
        pending = BoardRfdcConfig(
            board_id=board_id,
            channels=channels,
            revision=revision,
            applied_at=None,
            apply_status="pending",
            apply_error="",
            requested_mask=request.channel_mask,
            applied_mask=0,
            error_mask=0,
            config_valid_mask=current.config_valid_mask,
        )
        self.store.save_rfdc_config(pending)
        self.events.publish({"type": "rfdc.apply.started", "data": pending.model_dump(mode="json")})

        try:
            response = self.boards.rfdc_apply(
                board_id,
                channels,
                revision=revision,
                channel_mask=request.channel_mask,
            )
            response_status = int(response.get("status", host.RF2_STATUS_BAD_REQUEST))
            applied_mask = int(response.get("applied_mask", 0)) & request.channel_mask
            error_mask = int(response.get("error_mask", 0)) & request.channel_mask
            complete = (
                response_status == host.RF2_STATUS_OK
                and applied_mask == request.channel_mask
                and error_mask == 0
            )
            partial = applied_mask != 0 and not complete
            if not complete and not partial:
                raise ManagementError(self._response_error(response))

            apply_status = "applied" if complete else "partial"
            result = self._config_from_hardware(pending, response, apply_status)
            if partial:
                result = result.model_copy(update={"apply_error": self._response_error(response)})
            self.store.save_rfdc_config(result)
            event_type = "rfdc.apply.succeeded" if complete else "rfdc.apply.failed"
            self.events.publish({"type": event_type, "data": result.model_dump(mode="json")})
            return result
        except Exception as exc:
            failed = pending.model_copy(update={"apply_status": "failed", "apply_error": str(exc)})
            self.store.save_rfdc_config(failed)
            self.events.publish({"type": "rfdc.apply.failed", "data": failed.model_dump(mode="json")})
            raise

    @staticmethod
    def _config_from_hardware(
        base: BoardRfdcConfig,
        response: dict,
        apply_status: str,
    ) -> BoardRfdcConfig:
        actual_by_channel = {int(item["channel"]): item for item in response.get("channels", [])}
        valid_mask = int(response.get("config_valid_mask", 0)) & 0xFF
        channels = []
        for requested in sorted(base.channels, key=lambda item: item.channel):
            actual = actual_by_channel.get(requested.channel)
            if actual is None or not valid_mask & (1 << (requested.channel - 1)):
                channels.append(requested)
                continue
            channels.append(requested.model_copy(update={
                "actual_nco_hz": float(actual["nco_hz"]),
                "actual_nyquist_zone": int(actual["nyquist_zone"]),
                "actual_nco_phase_deg": float(actual["nco_phase_deg"]),
                "actual_dac_output_current_ma": float(actual["dac_output_current_ma"]),
                "nco_word": int(actual["nco_word"]),
                "phase_word": int(actual["phase_word"]),
                "vop_code": int(actual["vop_code"]),
                "hardware_status": int(actual["status"]),
            }))
        return base.model_copy(update={
            "channels": channels,
            "revision": int(response.get("revision", base.revision)),
            "applied_at": datetime.now(UTC).isoformat(),
            "apply_status": apply_status,
            "apply_error": "",
            "applied_mask": int(response.get("applied_mask", 0)) & 0xFF,
            "error_mask": int(response.get("error_mask", 0)) & 0xFF,
            "config_valid_mask": int(response.get("config_valid_mask", 0)) & 0xFF,
            "failure_stage": int(response.get("failure_stage", 0)),
            "failure_address": int(response.get("failure_address", 0)),
            "axi_response": int(response.get("axi_response", 0)),
        })

    @staticmethod
    def _response_error(response: dict) -> str:
        status = int(response.get("status", host.RF2_STATUS_BAD_REQUEST))
        message = RFDC_STATUS_MESSAGES.get(status, f"PL RFDC configuration failed with status 0x{status:04X}")
        details = []
        error_mask = int(response.get("error_mask", 0)) & 0xFF
        if error_mask:
            details.append(f"error_mask=0x{error_mask:02X}")
        stage = int(response.get("failure_stage", 0))
        if stage:
            details.append(f"stage={stage}")
        address = int(response.get("failure_address", 0))
        if address:
            details.append(f"address=0x{address:05X}")
        axi_response = int(response.get("axi_response", 0))
        if axi_response:
            details.append(f"AXI response=0b{axi_response:02b}")
        return f"{message} ({', '.join(details)})" if details else message
