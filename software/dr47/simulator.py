"""In-memory board simulator used by tests and the web console simulation mode."""

from __future__ import annotations

import struct
from typing import Any, Mapping

import numpy as np

from .capabilities import DeviceCapabilities, DeviceStatus, PlaybackState, DiagnosticsSnapshot
from .device import Dr47Device
from .errors import ParameterRangeError
from .protocol import _FIXED_DAC_OUTPUT_CURRENT_MA, pack_wave_begin, pack_wave_data
from .protocol import (
    RF2_CAP_DAC_MTS,
    RF2_CAP_NCO_SYNC,
    RF2_CAP_TRIGGER_IO,
    RF2_CAP_PL_RFDC_CONFIG,
    RF2_CAP_RFDC_GET_CONFIG,
    RF2_OP_HELLO,
    RF2_OP_RFDC_APPLY,
    RF2_OP_RFDC_GET_CONFIG,
    RF2_OP_STATUS,
    RF2_OP_DIAG_SNAPSHOT,
    RF2_OP_DIAG_CONTROL,
    RF2_CAP_DIAGNOSTICS,
    RF2_STATUS_DAC_MTS_READY,
    RF2_STATUS_DAC_MTS_REQUIRED,
    RF2_STATUS_NCO_SYNC_READY,
    RF2_STATUS_OK,
    RF2_STATUS_RFDC_READY,
    RFCTRL2_VERSION,
    parse_rfctrl2_rfdc_config_response,
    WAVE_OP_BEGIN, WAVE_OP_DATA, WAVE_OP_COMMIT, WAVE_OP_PLAY, WAVE_OP_PAUSE,
    WAVE_OP_STOP, WAVE_OP_ABORT, WAVE_OP_STATUS, WAVE_STATUS_OK,
    WAVE_OP_BULK_STATUS, WAVE_OP_BULK_CHUNK_RESET, WAVE_LAYOUT_INTERLEAVED_512B_BULK,
    WAVE_BULK_CHUNK_BYTES, WAVE_BULK_HEADER_BYTES, WAVE_BULK_MAX_WORDS, WAVE_BULK_TAG,
    WAVE_BULK_WORD_BYTES, pack_wave_bulk_frame,
    WAVE_STATUS_BAD_REQUEST, WAVE_STATUS_INCOMPLETE, WAVE_STATUS_SEQUENCE,
    WAVE_STATUS_OFFSET, WAVE_STATUS_CRC, WAVEFORM_STATE_ID, WAVEFORM_STATE_UPLOAD,
    WAVEFORM_STATE_READY, WAVEFORM_STATE_PREFETCH, WAVEFORM_STATE_WAIT_TRIGGER,
    WAVEFORM_STATE_PLAYING, WAVEFORM_STATE_DONE, WAVEFORM_STATE_ERROR,
    WAVE_ERROR_NONE, WAVE_ERROR_UNDERFLOW, crc32,
)
class SimulatedDr47Device(Dr47Device):
    """A deterministic simulator with the same public API as ``Dr47Device``."""

    def __init__(self, *args, device_uid: str = "sim-xczu47dr", **kwargs) -> None:
        kwargs["transport"] = object()
        super().__init__(*args, **kwargs)
        self.device_uid = str(device_uid)
        self.waveforms: dict[int, np.ndarray] = {}
        self.sequences: dict[int, Any] = {}
        self.playback_armed = False
        self.playback_prepared = False
        self.playback_running = False
        self._sim_revision = 0
        self._sim_valid_mask = 0
        self._sim_last_response: dict[str, Any] = {}
        self._trigger_input_count = 0
        self._trigger_accepted_count = 0
        self._trigger_output_count = 0
        self._diag_generation = 0
        self._wave_state = WAVEFORM_STATE_ID
        self._wave_session = 0
        self._wave_descriptor = 0
        self._wave_generation = 0
        self._wave_fragments = {}
        self._wave_total_bytes = 0
        self._wave_total_beats = 0
        self._wave_channel_mask = 0
        self._wave_loop_count = 0
        self._wave_received = bytearray()
        self._wave_next_packet = 0
        self._wave_received_bytes = 0
        self._wave_error = WAVE_ERROR_NONE
        self._wave_error_offset = 0
        self._wave_prefetch_complete = False
        self._wave_play_pending = False
        # Bulk path model, mirroring wave_bulk_ddr_writer: per-chunk
        # [epoch, words], with an "over" mark when a chunk received too much.
        self.sim_bulk_supported = True
        self._bulk_settle_interval_s = 0.0
        self._bulk_mode = False
        self._bulk_chunks: dict[int, list[int]] = {}
        self._bulk_counters = dict.fromkeys(
            ("frames_ok", "frames_rejected", "frames_duplicate", "frames_stale",
             "rx_frames", "rx_dropped_full"), 0)
        self._bulk_overrun = False
        self._bulk_drop = None
        self._bulk_resets: list[tuple[int, int]] = []

    def _make_status_payload(self) -> bytes:
        capabilities = (RF2_CAP_PL_RFDC_CONFIG | RF2_CAP_RFDC_GET_CONFIG |
                        RF2_CAP_DAC_MTS | RF2_CAP_NCO_SYNC |
                        RF2_CAP_TRIGGER_IO | RF2_CAP_DIAGNOSTICS)
        state_flags = RF2_STATUS_RFDC_READY | RF2_STATUS_DAC_MTS_READY | RF2_STATUS_DAC_MTS_REQUIRED | RF2_STATUS_NCO_SYNC_READY
        if self.playback_armed:
            state_flags |= RF2_STATUS_ARMED | RF2_STATUS_PREPARED
        if self.playback_running:
            state_flags |= RF2_STATUS_RUNNING
        base = struct.pack(
            "<IIIIIIIIQQQQII",
            capabilities, state_flags, self._sim_valid_mask, self._sim_revision,
            0, 0, 0, 0,
            self._channel_mask & 0xFF, 0,
            self._sim_valid_mask & 0xFF, 0,
            1, 0,
        )
        return base + struct.pack(
            "<QIIII", 0, self._trigger_input_count,
            self._trigger_accepted_count, self._trigger_output_count, 0,
        )

    def _response(self, opcode: int, payload: bytes = b"", seq: int = 1, status: int = RF2_STATUS_OK) -> dict[str, Any]:
        return {
            "version": RFCTRL2_VERSION,
            "status": int(status),
            "opcode": int(opcode),
            "seq": int(seq) & 0xFFFFFFFF,
            "payload_bytes": len(payload),
            "payload": payload,
        }

    def connect(self) -> int:
        self._closed = False
        self._connected = True
        self._capabilities = DeviceCapabilities(
            device_uid=self.device_uid,
            protocol_version=RFCTRL2_VERSION,
            build_profile_id=1,
            build_profile="simulated_xczu47dr",
            source_commit_id=0,
            trigger_path_version=3,
            capability_bits=(RF2_CAP_PL_RFDC_CONFIG | RF2_CAP_RFDC_GET_CONFIG |
                              RF2_CAP_DAC_MTS | RF2_CAP_NCO_SYNC |
                              RF2_CAP_TRIGGER_IO | RF2_CAP_DIAGNOSTICS),
            state_flags=RF2_STATUS_RFDC_READY | RF2_STATUS_DAC_MTS_READY | RF2_STATUS_DAC_MTS_REQUIRED | RF2_STATUS_NCO_SYNC_READY,
            rfdc_ready=True,
            dac_mts_required=True,
            dac_mts_ready=True,
            nco_sync_ready=True,
            trigger_input_count=self._trigger_input_count,
            trigger_accepted_count=self._trigger_accepted_count,
            trigger_output_count=self._trigger_output_count,
            config_valid_mask=self._sim_valid_mask,
            raw={"device_uid": self.device_uid},
        )
        self._status = DeviceStatus(True, self.ip, self.port, PlaybackState.IDLE, self._capabilities, "simulation mode")
        return 0

    def status(self, refresh: bool = True) -> DeviceStatus:
        state_map = {
            WAVEFORM_STATE_ID: PlaybackState.IDLE, WAVEFORM_STATE_UPLOAD: PlaybackState.UPLOAD,
            WAVEFORM_STATE_READY: PlaybackState.READY, WAVEFORM_STATE_PREFETCH: PlaybackState.PREFETCH,
            WAVEFORM_STATE_WAIT_TRIGGER: PlaybackState.WAIT_TRIGGER,
            WAVEFORM_STATE_PLAYING: PlaybackState.PLAYING, WAVEFORM_STATE_DONE: PlaybackState.DONE,
            WAVEFORM_STATE_ERROR: PlaybackState.ERROR,
        }
        state = state_map.get(self._wave_state, PlaybackState.ERROR)
        self._capabilities = DeviceCapabilities(
            **{**self._capabilities.__dict__,
               "config_valid_mask": self._sim_valid_mask,
               "playback_state": state,
               "playback_armed": self.playback_armed,
               "playback_prepared": self.playback_prepared,
               "playback_running": self.playback_running,
               "trigger_input_count": self._trigger_input_count,
               "trigger_accepted_count": self._trigger_accepted_count,
               "trigger_output_count": self._trigger_output_count,
               "raw": {"device_uid": self.device_uid, "config_valid_mask": self._sim_valid_mask}},
        )
        self._status = DeviceStatus(self.connected, self.ip, self.port, state, self._capabilities, "simulation mode")
        return self._status

    def rfctrl2_hello(self, seq: int | None = None, wait_response: bool = True):
        return self._response(RF2_OP_HELLO, self._make_status_payload(), seq or 1)

    def rfctrl2_status(self, seq: int | None = None, wait_response: bool = True, retries: int | None = None):
        return self._response(RF2_OP_STATUS, self._make_status_payload(), seq or 1)

    def read_diagnostics(self) -> DiagnosticsSnapshot:
        self._diag_generation = (self._diag_generation + 1) & 0xFFFFFFFFFFFFFFFF
        return DiagnosticsSnapshot(
            generation=self._diag_generation,
            trigger_input_count=self._trigger_input_count,
            trigger_accepted_count=self._trigger_accepted_count,
            replay_ready=self.playback_prepared,
            replay_active=self.playback_running,
            raw={"device_uid": self.device_uid},
        )

    def clear_diagnostics(self, events: int = 0xFFFFFFFF, counters: bool = True):
        if counters:
            self._trigger_input_count = 0
            self._trigger_accepted_count = 0
            self._trigger_output_count = 0
        self._diag_generation = 0
        return self._response(RF2_OP_DIAG_CONTROL, self._make_status_payload(), seq=1)

    def rfctrl2_rfdc_apply(self, per_channel_nco_hz, per_channel_nyquist_zone, per_channel_phase_deg,
                           revision: int, channel_mask: int = 0xFF,
                           seq: int | None = None, wait_response: bool = True, retries: int | None = None):
        self._sim_revision = int(revision) & 0xFFFFFFFF
        self._sim_valid_mask |= int(channel_mask) & 0xFF
        for channel in range(1, 9):
            self._pending_nco[channel] = _value(per_channel_nco_hz, channel, 0.0)
            self._pending_zone[channel] = _value(per_channel_nyquist_zone, channel, 1)
            self._pending_phase[channel] = _value(per_channel_phase_deg, channel, 0.0)
        return parse_rfctrl2_rfdc_config_response(
            self._response(RF2_OP_RFDC_APPLY, self._make_config_payload(), seq or 1)
        )

    def _make_config_payload(self) -> bytes:
        header = struct.pack("<IIIIIIII", self._sim_revision, self._sim_valid_mask, 0, self._sim_valid_mask, 0, 0, 0, RF2_STATUS_RFDC_READY)
        entries = bytearray()
        for channel in range(1, 9):
            entries += struct.pack(
                "<qIiIIQII", int(round(self._pending_nco[channel])), int(self._pending_zone[channel]),
                int(round(self._pending_phase[channel] * 1000)), int(round(_FIXED_DAC_OUTPUT_CURRENT_MA[channel] * 1000)),
                0, 0, 0, 0,
            )
        return header + bytes(entries)

    def rfctrl2_rfdc_get_config(self, seq: int | None = None, wait_response: bool = True, retries: int | None = None):
        return parse_rfctrl2_rfdc_config_response(
            self._response(RF2_OP_RFDC_GET_CONFIG, self._make_config_payload(), seq or 1)
        )

    def waveform_status(self, session: int = 0):
        return self._wave_response(WAVE_OP_STATUS)

    def _wave_response(self, opcode: int, *, seq: int = 1, status: int = WAVE_STATUS_OK,
                       error_code: int = 0, error_offset: int = 0, **extra) -> dict[str, Any]:
        result = {"version": 1, "opcode": opcode, "seq": seq or 1,
                  "status": status, "session": self._wave_session,
                  "state": self._wave_state, "descriptor": self._wave_descriptor,
                  "error_code": error_code, "error_offset": error_offset,
                  "state_name": {0:"idle",1:"upload",2:"ready",3:"prefetch",4:"wait_trigger",5:"playing",6:"draining",7:"done",8:"error"}.get(self._wave_state, "unknown")}
        result.update(extra)
        return result

    def begin_waveform(self, *, session: int, total_bytes: int, channel_mask: int,
                       total_beats: int, loop_count: int = 1, layout: int = 1):
        try:
            pack_wave_begin(session=session, total_bytes=total_bytes, channel_mask=channel_mask,
                            total_beats=total_beats, loop_count=loop_count, layout=layout)
        except ParameterRangeError:
            return self._wave_response(WAVE_OP_BEGIN, status=WAVE_STATUS_BAD_REQUEST)
        bulk = int(layout) == WAVE_LAYOUT_INTERLEAVED_512B_BULK
        if bulk and not self.sim_bulk_supported:
            return self._wave_response(WAVE_OP_BEGIN, status=WAVE_STATUS_BAD_REQUEST)
        self._bulk_mode = bulk
        self._bulk_chunks = {}
        self._bulk_counters = dict.fromkeys(self._bulk_counters, 0)
        self._bulk_overrun = False
        self._wave_session = int(session) & 0xFFFFFFFF
        self._wave_total_bytes = int(total_bytes)
        self._wave_total_beats = int(total_beats)
        self._wave_channel_mask = int(channel_mask) & 0xFF
        self._wave_loop_count = int(loop_count) & 0xFFFFFFFF
        # Grow on accepted fragments, not on BEGIN: an 8 GiB descriptor must
        # not allocate 8 GiB just to exercise protocol boundaries.
        self._wave_received = bytearray()
        self._wave_fragments.clear()
        self._wave_descriptor = 0
        self._wave_play_pending = False
        self._wave_prefetch_complete = False
        self._wave_next_packet = 0
        self._wave_received_bytes = 0
        self._wave_error = WAVE_ERROR_NONE
        self._wave_state = WAVEFORM_STATE_UPLOAD
        return self._wave_response(WAVE_OP_BEGIN)

    def data_waveform(self, *, session: int, packet_seq: int, byte_offset: int,
                      payload: bytes, payload_crc: int | None = None):
        raw = bytes(payload)
        if byte_offset < 0 or byte_offset % 32:
            return self._wave_response(WAVE_OP_DATA, status=WAVE_STATUS_OFFSET,
                next_expected_sequence=self._wave_next_packet, received_bytes=self._wave_received_bytes,
                first_error_offset=byte_offset)
        try:
            pack_wave_data(session=session, packet_seq=packet_seq, byte_offset=byte_offset, payload=raw)
        except ParameterRangeError:
            return self._wave_response(WAVE_OP_DATA, status=WAVE_STATUS_BAD_REQUEST)
        if payload_crc is not None and (int(payload_crc) & 0xFFFFFFFF) != crc32(raw):
            self._wave_error_offset = int(byte_offset)
            return self._wave_response(WAVE_OP_DATA, status=WAVE_STATUS_CRC,
                next_expected_sequence=self._wave_next_packet, received_bytes=self._wave_received_bytes,
                first_error_offset=byte_offset)
        if session != self._wave_session or self._wave_state != WAVEFORM_STATE_UPLOAD or self._bulk_mode:
            return self._wave_response(WAVE_OP_DATA, status=WAVE_STATUS_BAD_REQUEST)
        if packet_seq < self._wave_next_packet:
            if self._wave_fragments.get(packet_seq) != (byte_offset, len(raw), crc32(raw)):
                return self._wave_response(WAVE_OP_DATA, status=WAVE_STATUS_SEQUENCE)
            return self._wave_response(WAVE_OP_DATA, ack_packet_seq=packet_seq,
                next_expected_sequence=self._wave_next_packet, received_bytes=self._wave_received_bytes,
                first_error_offset=self._wave_error_offset)
        if packet_seq != self._wave_next_packet:
            return self._wave_response(WAVE_OP_DATA, status=WAVE_STATUS_SEQUENCE,
                next_expected_sequence=self._wave_next_packet, received_bytes=self._wave_received_bytes,
                first_error_offset=byte_offset)
        if byte_offset != self._wave_received_bytes or byte_offset + len(raw) > self._wave_total_bytes:
            self._wave_error_offset = byte_offset
            return self._wave_response(WAVE_OP_DATA, status=WAVE_STATUS_OFFSET,
                next_expected_sequence=self._wave_next_packet, received_bytes=self._wave_received_bytes,
                first_error_offset=byte_offset)
        self._wave_received[byte_offset:byte_offset + len(raw)] = raw
        self._wave_received_bytes += len(raw)
        self._wave_fragments[packet_seq] = (byte_offset, len(raw), crc32(raw))
        self._wave_next_packet += 1
        return self._wave_response(WAVE_OP_DATA, ack_packet_seq=packet_seq,
            next_expected_sequence=self._wave_next_packet, received_bytes=self._wave_received_bytes,
            first_error_offset=0)

    def commit_waveform(self, *, session: int):
        if session == self._wave_session and self._wave_descriptor:
            return self._wave_response(WAVE_OP_COMMIT)
        if session != self._wave_session or self._wave_state != WAVEFORM_STATE_UPLOAD:
            return self._wave_response(WAVE_OP_COMMIT, status=WAVE_STATUS_BAD_REQUEST)
        if (not self._bulk_complete() if self._bulk_mode
                else self._wave_received_bytes != self._wave_total_bytes):
            return self._wave_response(WAVE_OP_COMMIT, status=WAVE_STATUS_INCOMPLETE)
        self._wave_generation = (self._wave_generation + 1) & 0xFFFFFFFF or 1
        self._wave_descriptor = self._wave_generation
        self._wave_state = WAVEFORM_STATE_PREFETCH
        self._wave_prefetch_complete = False
        return self._wave_response(WAVE_OP_COMMIT)

    # ------------------------------------------------------------------ bulk path
    def _bulk_expected_words(self, chunk: int) -> int:
        remaining = self._wave_total_bytes - chunk * WAVE_BULK_CHUNK_BYTES
        return min(remaining, WAVE_BULK_CHUNK_BYTES) // WAVE_BULK_WORD_BYTES

    def _bulk_total_chunks(self) -> int:
        return (self._wave_total_bytes + WAVE_BULK_CHUNK_BYTES - 1) // WAVE_BULK_CHUNK_BYTES

    def _bulk_chunk_complete(self, chunk: int) -> bool:
        return self._bulk_chunks.get(chunk, [0, 0])[1] == self._bulk_expected_words(chunk)

    def _bulk_complete(self) -> bool:
        return all(self._bulk_chunk_complete(c) for c in range(self._bulk_total_chunks()))

    def _bulk_response(self, opcode: int, status: int = WAVE_STATUS_OK) -> dict[str, Any]:
        chunks = range(self._bulk_total_chunks()) if self._bulk_mode else range(0)
        incomplete = [c for c in chunks if not self._bulk_chunk_complete(c)]
        committed = bool(self._wave_descriptor)
        return self._wave_response(
            opcode, status=status,
            bulk_complete=self._bulk_mode and (committed or not incomplete),
            bulk_overrun=self._bulk_overrun, bulk_axi_error=False,
            bulk_complete_chunks=len(chunks) - len(incomplete),
            bulk_first_incomplete_chunk=incomplete[0] if incomplete else None,
            bulk_rx_dropped_bad=0, **{f"bulk_{k}": v for k, v in self._bulk_counters.items()})

    def bulk_status(self, *, session: int):
        if not self._bulk_mode or session != self._wave_session:
            return self._bulk_response(WAVE_OP_BULK_STATUS, WAVE_STATUS_BAD_REQUEST)
        return self._bulk_response(WAVE_OP_BULK_STATUS)

    def bulk_chunk_reset(self, *, session: int, chunk: int, epoch: int):
        if (not self._bulk_mode or session != self._wave_session or
                self._wave_state != WAVEFORM_STATE_UPLOAD):
            return self._bulk_response(WAVE_OP_BULK_CHUNK_RESET, WAVE_STATUS_BAD_REQUEST)
        self._bulk_chunks[int(chunk)] = [int(epoch) & 0xFF, 0]
        self._bulk_resets.append((int(chunk), int(epoch)))
        return self._bulk_response(WAVE_OP_BULK_CHUNK_RESET)

    def _bulk_payload_bytes(self) -> int:
        return 1024

    def _bulk_send(self, image, start: int, end: int, *, session: int, epoch: int, payload_bytes: int) -> int:
        """The link: every datagram either reaches the writer or is dropped whole."""
        lanes = hasattr(image, "pack")            # a LaneImage: build only the datagram being sent
        view = None if lanes else memoryview(image).cast("B")
        frames = 0
        for offset in range(int(start), int(end), int(payload_bytes)):
            last = min(offset + payload_bytes, end)
            frame = pack_wave_bulk_frame(session=session, byte_offset=offset, epoch=epoch,
                                         payload=image.pack(offset, last).tobytes() if lanes else view[offset:last])
            frames += 1
            self._bulk_counters["rx_frames"] += 1
            drop = self._bulk_drop
            lost = drop(offset, epoch) if callable(drop) else (drop is not None and (offset, epoch) in drop)
            if lost:
                self._bulk_counters["rx_dropped_full"] += 1
            else:
                self.sim_receive_bulk_frame(frame)
        return frames

    def sim_receive_bulk_frame(self, frame: bytes) -> None:
        """Deliver one bulk datagram to the modelled DDR writer."""
        raw = bytes(frame)
        tag = raw[:4]
        session, offset, words, epoch = struct.unpack_from("<IQHB", raw, 4)
        payload = raw[WAVE_BULK_HEADER_BYTES:]
        end = offset + words * WAVE_BULK_WORD_BYTES
        chunk = offset // WAVE_BULK_CHUNK_BYTES
        if (tag != WAVE_BULK_TAG or not self._bulk_mode or self._wave_state != WAVEFORM_STATE_UPLOAD or
                session != self._wave_session or offset % WAVE_BULK_WORD_BYTES or
                not 1 <= words <= WAVE_BULK_MAX_WORDS or len(payload) != words * WAVE_BULK_WORD_BYTES or
                end > self._wave_total_bytes or (end - 1) // WAVE_BULK_CHUNK_BYTES != chunk):
            self._bulk_counters["frames_rejected"] += 1
            return
        # The writer stores the words before it looks at the chunk epoch.
        if len(self._wave_received) < end:
            self._wave_received.extend(bytes(end - len(self._wave_received)))
        self._wave_received[offset:end] = payload
        entry = self._bulk_chunks.setdefault(chunk, [0, 0])
        expected = self._bulk_expected_words(chunk)
        if entry[0] != epoch:
            self._bulk_counters["frames_stale"] += 1
        elif entry[1] == expected:
            self._bulk_counters["frames_duplicate"] += 1
        else:
            self._bulk_counters["frames_ok"] += 1
            if entry[1] < 0 or entry[1] + words > expected:
                entry[1] = -1                       # over: never equals expected until reset
                self._bulk_overrun = True
            else:
                entry[1] += words

    def sim_drop_bulk_frames(self, drop) -> None:
        """Lose bulk datagrams: a set of (offset, epoch), or callable(offset, epoch) -> bool."""
        self._bulk_drop = drop

    def sim_bulk_chunk_resets(self) -> list[tuple[int, int]]:
        return list(self._bulk_resets)

    def sim_ddr_image(self) -> bytes:
        return bytes(self._wave_received[:self._wave_total_bytes])

    def complete_prefetch(self):
        if self._wave_state == WAVEFORM_STATE_PREFETCH:
            self._wave_prefetch_complete = True
            self._wave_state = WAVEFORM_STATE_PLAYING if self._wave_play_pending else WAVEFORM_STATE_WAIT_TRIGGER
            self._wave_play_pending = False
        return self.status(refresh=False)

    def play(self, *, session: int = 0):
        return self._check_wave_response(self._play(session=session), "PLAY")

    def _play(self, *, session: int = 0):
        if session and session != self._wave_session:
            return self._wave_response(WAVE_OP_PLAY, status=WAVE_STATUS_BAD_REQUEST)
        if self._wave_state in (WAVEFORM_STATE_READY, WAVEFORM_STATE_DONE, WAVEFORM_STATE_PREFETCH):
            self._wave_state = WAVEFORM_STATE_PREFETCH
            self._wave_prefetch_complete = False
            self._wave_play_pending = True
            return self._wave_response(WAVE_OP_PLAY)
        if self._wave_state == WAVEFORM_STATE_WAIT_TRIGGER:
            self._wave_state = WAVEFORM_STATE_PLAYING
            return self._wave_response(WAVE_OP_PLAY)
        return self._wave_response(WAVE_OP_PLAY, status=WAVE_STATUS_BAD_REQUEST)

    def pause(self, *, session: int = 0):
        return self._check_wave_response(self._pause(session=session), "PAUSE")

    def _pause(self, *, session: int = 0):
        if session and session != self._wave_session:
            return self._wave_response(WAVE_OP_PAUSE, status=WAVE_STATUS_BAD_REQUEST)
        if self._wave_state in (WAVEFORM_STATE_READY, WAVEFORM_STATE_DONE, WAVEFORM_STATE_PLAYING,
                                WAVEFORM_STATE_WAIT_TRIGGER, WAVEFORM_STATE_PREFETCH):
            self._wave_state = WAVEFORM_STATE_READY
            self._wave_prefetch_complete = False
            self._wave_play_pending = False
            return self._wave_response(WAVE_OP_PAUSE)
        return self._wave_response(WAVE_OP_PAUSE, status=WAVE_STATUS_BAD_REQUEST)

    def stop(self, *, session: int = 0):
        return self._check_wave_response(self._stop(session=session), "STOP")

    def _stop(self, *, session: int = 0):
        if session and session != self._wave_session:
            return self._wave_response(WAVE_OP_STOP, status=WAVE_STATUS_BAD_REQUEST)
        if self._wave_state == WAVEFORM_STATE_UPLOAD:
            self._abort(session=session)
            return self._wave_response(WAVE_OP_STOP)
        result = self._pause(session=session)
        result["opcode"] = WAVE_OP_STOP
        return result

    def abort(self, *, session: int = 0):
        return self._check_wave_response(self._abort(session=session), "ABORT")

    def _abort(self, *, session: int = 0):
        if session and session != self._wave_session:
            return self._wave_response(WAVE_OP_ABORT, status=WAVE_STATUS_BAD_REQUEST)
        self._wave_state = WAVEFORM_STATE_ID
        self._wave_session = 0
        self._wave_descriptor = 0
        self._wave_received = bytearray()
        self._wave_received_bytes = 0
        self._wave_next_packet = 0
        self._wave_error = WAVE_ERROR_NONE
        self._wave_error_offset = 0
        self._wave_play_pending = False
        self._wave_prefetch_complete = False
        self._wave_fragments.clear()
        return self._wave_response(WAVE_OP_ABORT)

    def trigger_event(self):
        if self._wave_state == WAVEFORM_STATE_WAIT_TRIGGER:
            self._wave_state = WAVEFORM_STATE_PLAYING
            return True
        return False

    def close(self) -> None:
        self._closed = True
        self._connected = False
        self._status = DeviceStatus(False, self.ip, self.port, PlaybackState.IDLE, self._capabilities, "closed")


def _value(mapping: Mapping | list | tuple, channel: int, default):
    if isinstance(mapping, Mapping):
        return mapping.get(channel, mapping.get(f"ch{channel}", default))
    values = list(mapping)
    return values[channel - 1] if len(values) == 8 else default


__all__ = ["SimulatedDr47Device"]
