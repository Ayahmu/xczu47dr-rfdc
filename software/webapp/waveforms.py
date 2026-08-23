from __future__ import annotations

import math
import sys
from dataclasses import replace
from pathlib import Path

import numpy as np

SOFTWARE_DIR = Path(__file__).resolve().parents[1]
if str(SOFTWARE_DIR) not in sys.path:
    sys.path.insert(0, str(SOFTWARE_DIR))

import dr47 as host  # noqa: E402
import waveform_model as gui_model  # noqa: E402

from .models import BoardOverride, BoardRfdcConfig, EzqChannel, PreviewResponse, PreviewSeries, WaveformRequest


def _override_for(override: BoardOverride | None, field: str, channel: int, default):
    if override is None:
        return default
    return getattr(override, field).get(channel, default)


def _manual_config(request: WaveformRequest, override: BoardOverride | None) -> gui_model.WaveformConfig:
    channels: dict[str, gui_model.ChannelWaveformConfig] = {}
    record_s = request.record_duration_ns * 1e-9
    for item in request.manual_channels:
        enabled = bool(_override_for(override, "channel_enabled", item.channel, item.enabled))
        phase_deg = item.phase_deg + float(_override_for(override, "phase_offset_deg", item.channel, 0.0))
        if item.data_amplitude is not None:
            amplitude = round(float(item.data_amplitude) * 32767.0)
        elif item.amplitude is not None:
            amplitude = item.amplitude
        else:
            amplitude = 12000
        delay_ns = item.delay_ns + float(_override_for(override, "start_offset_ns", item.channel, 0.0))
        if enabled and delay_ns + item.duration_ns > request.record_duration_ns:
            raise ValueError(
                f"CH{item.channel}: delay {delay_ns:g} ns + duration {item.duration_ns:g} ns "
                f"exceeds record/loop cache length {request.record_duration_ns:g} ns"
            )
        channels[f"ch{item.channel}"] = gui_model.ChannelWaveformConfig(
            waveform_type=item.waveform if enabled else "off",
            domain=item.format,
            freq_hz=(item.data_offset_mhz or item.frequency_mhz) * 1e6,
            phase_rad=math.radians(phase_deg),
            amplitude=amplitude,
            delay_s=delay_ns * 1e-9,
            duration_s=item.duration_ns * 1e-9,
            record_duration_s=record_s,
            zero_tail_s=0.0,
        )
    return gui_model.WaveformConfig(
        mode="manual-channels",
        ddr_layout=host.DEFAULT_DDR_LAYOUT,
        sample_rate_hz=host.DEFAULT_WAVEFORM_SAMPLE_RATE_HZ,
        rfdc_interpolation=host.RFDC_INTERPOLATION,
        axis_freq_hz=host.DEFAULT_AXIS_HZ,
        loop=request.loop,
        record_duration_s=request.record_duration_ns * 1e-9,
        wait_for_trigger=True,
        **channels,
    )


def _apply_ezq_values(base: gui_model.EzqChannelConfig, item: EzqChannel, override: BoardOverride | None) -> gui_model.EzqChannelConfig:
    enabled = bool(_override_for(override, "channel_enabled", item.channel, item.enabled))
    phase_deg = item.phase_deg + float(_override_for(override, "phase_offset_deg", item.channel, 0.0))
    start_ns = item.start_ns + float(_override_for(override, "start_offset_ns", item.channel, 0.0))
    target_rf_hz = item.target_rf_mhz * 1e6 + float(_override_for(override, "nco_offset_hz", item.channel, 0.0))
    values = {
        "enabled": enabled,
        "waveform": item.role,
        "start_time_s": start_ns * 1e-9,
        "target_rf_hz": target_rf_hz,
        "detune_hz": item.detune_mhz * 1e6,
        "xy_phase_rad": math.radians(phase_deg),
        "readout_phase_rad": math.radians(phase_deg),
        "xy_gate": item.xy_gate,
        "z_shape": item.z_shape,
        "period_s": max(item.duration_ns * 1e-9, 1e-9),
    }
    if item.role == "xy":
        if item.xy_gate in {"x_half", "y_half", "x12_half"}:
            values.update(pi_amp_half=item.amplitude, pi_len_half_s=item.duration_ns * 1e-9)
        elif item.xy_gate == "spec":
            values.update(spec_amp=item.amplitude, spec_len_s=item.duration_ns * 1e-9)
        elif item.xy_gate == "x12_pi":
            values.update(pi_amp21=item.amplitude, pi_len_s=item.duration_ns * 1e-9)
        else:
            values.update(pi_amp=item.amplitude, pi_len_s=item.duration_ns * 1e-9)
    elif item.role == "z":
        values.update(z_amp=item.amplitude, z_len_s=item.duration_ns * 1e-9, z_gate_time_s=item.duration_ns * 1e-9)
    else:
        values.update(
            readout_freq_hz=target_rf_hz,
            readout_fc_hz=target_rf_hz,
            readout_amp=item.amplitude,
            readout_len_s=item.duration_ns * 1e-9,
            readout_flattop_s=max(0.0, item.duration_ns * 1e-9 - 2.0 * base.readout_edge_s),
        )
    return replace(base, **values)


def _ezq_config(request: WaveformRequest, override: BoardOverride | None) -> gui_model.WaveformConfig:
    ezq = gui_model.default_test_ezq_config()
    channel_mask = 0
    values: dict[str, gui_model.EzqChannelConfig] = {}
    for item in request.ezq_channels:
        base = getattr(ezq, f"ch{item.channel}") or gui_model.EzqChannelConfig(waveform=item.role)
        channel = _apply_ezq_values(base, item, override)
        values[f"ch{item.channel}"] = channel
        if channel.enabled:
            channel_mask |= 1 << (item.channel - 1)
    ezq = replace(
        ezq,
        record_duration_s=request.record_duration_ns * 1e-9,
        period_s=request.record_duration_ns * 1e-9,
        channel_mask=channel_mask,
        **values,
    )
    return gui_model.WaveformConfig(
        mode="ezq-quantum",
        ddr_layout=host.DEFAULT_DDR_LAYOUT,
        sample_rate_hz=host.DEFAULT_WAVEFORM_SAMPLE_RATE_HZ,
        rfdc_interpolation=host.RFDC_INTERPOLATION,
        axis_freq_hz=host.DEFAULT_AXIS_HZ,
        loop=request.loop,
        record_duration_s=request.record_duration_ns * 1e-9,
        wait_for_trigger=True,
        ezq=ezq,
    )


def to_waveform_config(request: WaveformRequest, override: BoardOverride | None = None) -> gui_model.WaveformConfig:
    if request.mode == "manual":
        return _manual_config(request, override)
    return _ezq_config(request, override)


def _final_preview_wave(
    wave: np.ndarray,
    domain: str,
    nco_hz: float,
    nco_phase_deg: float,
    dac_rate_hz: float,
    interpolation: int,
) -> np.ndarray:
    iq = np.asarray(wave, dtype=np.int16).reshape(-1, 2)
    i_data = iq[:, 0].astype(np.float64)
    q_data = iq[:, 1].astype(np.float64)
    if str(domain).lower() == "real":
        return np.repeat(i_data, int(interpolation))
    i_up = np.repeat(i_data, int(interpolation))
    q_up = np.repeat(q_data, int(interpolation))
    t = np.arange(int(i_up.size), dtype=np.float64) / float(dac_rate_hz)
    angle = (2.0 * np.pi * float(nco_hz) * t) + math.radians(float(nco_phase_deg))
    return (i_up * np.cos(angle)) - (q_up * np.sin(angle))


def _downsample_preview(values: np.ndarray, max_points: int = 768) -> tuple[np.ndarray, np.ndarray]:
    values = np.asarray(values, dtype=np.float64).reshape(-1)
    if values.size <= max_points:
        return values, np.arange(values.size, dtype=np.int64)
    step = max(1, math.ceil(values.size / max_points))
    indices = np.arange(0, values.size, step, dtype=np.int64)
    return values[indices], indices


def preview_waveforms(
    request: WaveformRequest,
    override: BoardOverride | None = None,
    rfdc_config: BoardRfdcConfig | None = None,
    fft_channel: int = 1,
) -> PreviewResponse:
    config = to_waveform_config(request, override)
    generated = gui_model.generate_waveforms(config)
    series: list[PreviewSeries] = []
    selected_fft = np.array([], dtype=np.complex128)
    bytes_per_channel = 0
    channel_items = {item.channel: item for item in request.manual_channels}
    for channel, (_, wave) in enumerate(generated.channel_items(), start=1):
        bytes_per_channel = max(bytes_per_channel, int(np.asarray(wave).size * 2))
        item = channel_items.get(channel)
        domain = item.format if item is not None else "iq"
        if rfdc_config is not None:
            channel_cfg = next((cfg for cfg in rfdc_config.channels if cfg.channel == channel), None)
            nco_hz = channel_cfg.nco_hz if channel_cfg is not None else 0.0
            nco_phase_deg = channel_cfg.nco_phase_deg if channel_cfg is not None else 0.0
        else:
            nco_hz = (item.nco_mhz * 1e6) if item is not None else 0.0
            nco_phase_deg = (item.nco_phase_deg) if item is not None else 0.0
        if domain == "real":
            nco_hz = 0.0
        final = _final_preview_wave(
            wave,
            domain,
            nco_hz,
            nco_phase_deg,
            host.DAC_TILE_FS,
            host.RFDC_INTERPOLATION,
        )
        preview_values, indices = _downsample_preview(final)
        active = np.flatnonzero(np.abs(final) > 0.0)
        role = host.CHANNEL_ROLES[channel]
        series.append(
            PreviewSeries(
                channel=channel,
                role=role,
                domain=domain,
                time_ns=(indices / host.DAC_TILE_FS * 1e9).tolist(),
                value=preview_values.tolist(),
                i=np.asarray(wave, dtype=np.int16).reshape(-1, 2)[indices // int(host.RFDC_INTERPOLATION), 0].astype(int).tolist()
                if int(host.RFDC_INTERPOLATION) > 1 else np.asarray(wave, dtype=np.int16).reshape(-1, 2)[indices, 0].astype(int).tolist(),
                q=np.asarray(wave, dtype=np.int16).reshape(-1, 2)[indices // int(host.RFDC_INTERPOLATION), 1].astype(int).tolist()
                if int(host.RFDC_INTERPOLATION) > 1 else np.asarray(wave, dtype=np.int16).reshape(-1, 2)[indices, 1].astype(int).tolist(),
                active_start_ns=float(active[0] / host.DAC_TILE_FS * 1e9) if active.size else None,
                active_end_ns=float((active[-1] + 1) / host.DAC_TILE_FS * 1e9) if active.size else None,
            )
        )
        if channel == fft_channel:
            selected_fft = final.astype(np.float64)

    fft_frequency_mhz: list[float] = []
    fft_db: list[float] = []
    if selected_fft.size > 1 and np.any(selected_fft):
        spectrum = np.fft.fftshift(np.fft.fft(selected_fft * np.hanning(selected_fft.size)))
        frequencies = np.fft.fftshift(np.fft.fftfreq(selected_fft.size, d=1.0 / host.DAC_TILE_FS)) / 1e6
        magnitude = 20.0 * np.log10(np.maximum(np.abs(spectrum), 1.0))
        magnitude -= magnitude.max()
        step = max(1, math.ceil(frequencies.size / 1024))
        fft_frequency_mhz = frequencies[::step].tolist()
        fft_db = magnitude[::step].tolist()

    return PreviewResponse(
        sample_rate_hz=host.DAC_TILE_FS,
        record_duration_ns=request.record_duration_ns,
        bytes_per_channel=bytes_per_channel,
        series=series,
        fft_channel=fft_channel,
        fft_frequency_mhz=fft_frequency_mhz,
        fft_db=fft_db,
    )
