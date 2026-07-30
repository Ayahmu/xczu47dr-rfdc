`timescale 1ns / 1ps

// Single-board RFCTRL2 playback command crossing.
//
// ARM prepares/prefills the current DDR waveform, TRIGGER opens the DAC output
// gate only after ARM has entered a live session, and ABORT/MUTE clears that
// session. No multi-board clock or trigger synchronization is implemented here.
module rfctrl2_playback_controller (
    input  wire        ddr_clk,
    input  wire        ddr_rst_n,
    input  wire        rfctrl2_arm_pulse,
    input  wire        rfctrl2_trigger_pulse,
    input  wire        rfctrl2_abort_mute_pulse,

    input  wire        dac_clk,
    input  wire        dac_rst_n,

    output reg         play_prepare_pulse,
    output reg         play_trigger_pulse,
    output reg         play_abort_pulse,
    output reg         armed,
    output reg  [63:0] hardware_tick,
    output wire        start_pending
);

  assign start_pending = 1'b0;

  reg arm_toggle;
  reg trigger_toggle;
  reg abort_toggle;

  always @(posedge ddr_clk or negedge ddr_rst_n) begin
    if (!ddr_rst_n) begin
      arm_toggle     <= 1'b0;
      trigger_toggle <= 1'b0;
      abort_toggle   <= 1'b0;
    end else begin
      if (rfctrl2_arm_pulse)        arm_toggle     <= ~arm_toggle;
      if (rfctrl2_trigger_pulse)    trigger_toggle <= ~trigger_toggle;
      if (rfctrl2_abort_mute_pulse) abort_toggle   <= ~abort_toggle;
    end
  end

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg arm_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg arm_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg trigger_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg trigger_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg abort_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg abort_sync;

  reg arm_seen;
  reg trigger_seen;
  reg abort_seen;

  always @(posedge dac_clk or negedge dac_rst_n) begin
    if (!dac_rst_n) begin
      arm_meta           <= 1'b0;
      arm_sync           <= 1'b0;
      trigger_meta       <= 1'b0;
      trigger_sync       <= 1'b0;
      abort_meta         <= 1'b0;
      abort_sync         <= 1'b0;
      arm_seen           <= 1'b0;
      trigger_seen       <= 1'b0;
      abort_seen         <= 1'b0;
      play_prepare_pulse <= 1'b0;
      play_trigger_pulse <= 1'b0;
      play_abort_pulse   <= 1'b0;
      armed              <= 1'b0;
      hardware_tick      <= 64'd0;
    end else begin
      arm_meta     <= arm_toggle;
      arm_sync     <= arm_meta;
      trigger_meta <= trigger_toggle;
      trigger_sync <= trigger_meta;
      abort_meta   <= abort_toggle;
      abort_sync   <= abort_meta;

      play_prepare_pulse <= 1'b0;
      play_trigger_pulse <= 1'b0;
      play_abort_pulse   <= 1'b0;
      hardware_tick      <= hardware_tick + 64'd1;

      if (abort_sync != abort_seen) begin
        abort_seen         <= abort_sync;
        armed              <= 1'b0;
        play_abort_pulse   <= 1'b1;
      end else begin
        if (arm_sync != arm_seen) begin
          arm_seen           <= arm_sync;
          armed              <= 1'b1;
          play_prepare_pulse <= 1'b1;
        end

        if (trigger_sync != trigger_seen) begin
          trigger_seen <= trigger_sync;
          if (armed)
            play_trigger_pulse <= 1'b1;
        end
      end
    end
  end

endmodule
