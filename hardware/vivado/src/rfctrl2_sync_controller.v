`timescale 1ns / 1ps

// RFCTRL2 synchronization control in the DAC AXIS clock domain.
//
// The host only sends SYNC_EPOCH to the master.  The master emits TRIG_2 and
// delays its local epoch by the same calibrated fabric-capture latency used by
// the follower's EXT_TRIGGER synchronizer.  Both boards can then compare a
// future START_AT tick against a common epoch instead of using UDP arrival time.
module rfctrl2_sync_controller #(
    parameter integer BOARD_IS_MASTER = 1,
    parameter integer SYNC_PULSE_CYCLES = 4,
    parameter integer MASTER_EPOCH_DELAY_CYCLES = 2
) (
    input  wire        ddr_clk,
    input  wire        ddr_rst_n,
    input  wire        rfctrl2_arm_pulse,
    input  wire        rfctrl2_trigger_pulse,
    input  wire        rfctrl2_abort_mute_pulse,
    input  wire        rfctrl2_sync_epoch_pulse,
    input  wire [63:0] rfctrl2_epoch,
    input  wire        rfctrl2_start_valid,
    input  wire [63:0] rfctrl2_start_tick,

    input  wire        dac_clk,
    input  wire        dac_rst_n,
    input  wire        ext_sync_in,

    output reg         play_prepare_pulse,
    output reg         play_trigger_pulse,
    output reg         play_abort_pulse,
    output reg         sync_out,
    output reg         armed,
    output reg  [63:0] sync_epoch,
    output reg  [63:0] hardware_tick,
    output reg         start_pending
);

  // Convert the one-cycle DDR-domain commands into level changes so none are
  // lost while crossing to the unrelated DAC AXIS clock.
  reg arm_toggle;
  reg trigger_toggle;
  reg abort_toggle;
  reg epoch_toggle;
  reg start_toggle;

  always @(posedge ddr_clk or negedge ddr_rst_n) begin
    if (!ddr_rst_n) begin
      arm_toggle   <= 1'b0;
      trigger_toggle <= 1'b0;
      abort_toggle <= 1'b0;
      epoch_toggle <= 1'b0;
      start_toggle <= 1'b0;
    end else begin
      if (rfctrl2_arm_pulse)        arm_toggle   <= ~arm_toggle;
      if (rfctrl2_trigger_pulse)    trigger_toggle <= ~trigger_toggle;
      if (rfctrl2_abort_mute_pulse) abort_toggle <= ~abort_toggle;
      if (rfctrl2_sync_epoch_pulse) epoch_toggle <= ~epoch_toggle;
      if (rfctrl2_start_valid)      start_toggle <= ~start_toggle;
    end
  end

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg arm_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg arm_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg trigger_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg trigger_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg abort_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg abort_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg epoch_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg epoch_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg start_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg start_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg ext_sync_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg ext_sync_sync;

  reg arm_seen;
  reg trigger_seen;
  reg abort_seen;
  reg epoch_seen;
  reg start_seen;
  reg ext_sync_d;

  // These buses are held until the next RFCTRL2 command and are sampled only
  // after the corresponding synchronized toggle has arrived in this domain.
  reg [63:0] epoch_meta_data;
  reg [63:0] epoch_sync_data;
  reg [63:0] start_meta_data;
  reg [63:0] start_sync_data;

  reg [63:0] programmed_start_tick;
  reg [31:0] sync_width_count;
  reg [31:0] epoch_delay_count;
  reg        epoch_pending;

  wire ext_sync_pulse = ext_sync_sync & ~ext_sync_d;

  always @(posedge dac_clk or negedge dac_rst_n) begin
    if (!dac_rst_n) begin
      arm_meta          <= 1'b0;
      arm_sync          <= 1'b0;
      trigger_meta      <= 1'b0;
      trigger_sync      <= 1'b0;
      abort_meta        <= 1'b0;
      abort_sync        <= 1'b0;
      epoch_meta        <= 1'b0;
      epoch_sync        <= 1'b0;
      start_meta        <= 1'b0;
      start_sync        <= 1'b0;
      ext_sync_meta     <= 1'b0;
      ext_sync_sync     <= 1'b0;
      ext_sync_d        <= 1'b0;
      arm_seen          <= 1'b0;
      trigger_seen      <= 1'b0;
      abort_seen        <= 1'b0;
      epoch_seen        <= 1'b0;
      start_seen        <= 1'b0;
      epoch_meta_data   <= 64'd0;
      epoch_sync_data   <= 64'd0;
      start_meta_data   <= 64'd0;
      start_sync_data   <= 64'd0;
      programmed_start_tick <= 64'd0;
      sync_width_count  <= 32'd0;
      epoch_delay_count <= 32'd0;
      epoch_pending     <= 1'b0;
      play_prepare_pulse <= 1'b0;
      play_trigger_pulse <= 1'b0;
      play_abort_pulse   <= 1'b0;
      sync_out           <= 1'b0;
      armed              <= 1'b0;
      sync_epoch         <= 64'd0;
      hardware_tick      <= 64'd0;
      start_pending      <= 1'b0;
    end else begin
      arm_meta        <= arm_toggle;
      arm_sync        <= arm_meta;
      trigger_meta    <= trigger_toggle;
      trigger_sync    <= trigger_meta;
      abort_meta      <= abort_toggle;
      abort_sync      <= abort_meta;
      epoch_meta      <= epoch_toggle;
      epoch_sync      <= epoch_meta;
      start_meta      <= start_toggle;
      start_sync      <= start_meta;
      ext_sync_meta   <= ext_sync_in;
      ext_sync_sync   <= ext_sync_meta;
      ext_sync_d      <= ext_sync_sync;
      epoch_meta_data <= rfctrl2_epoch;
      epoch_sync_data <= epoch_meta_data;
      start_meta_data <= rfctrl2_start_tick;
      start_sync_data <= start_meta_data;

      play_prepare_pulse <= 1'b0;
      play_trigger_pulse <= 1'b0;
      play_abort_pulse   <= 1'b0;

      if (abort_sync != abort_seen) begin
        abort_seen        <= abort_sync;
        armed             <= 1'b0;
        start_pending     <= 1'b0;
        epoch_pending     <= 1'b0;
        epoch_delay_count <= 32'd0;
        sync_width_count  <= 32'd0;
        sync_out          <= 1'b0;
        play_abort_pulse  <= 1'b1;
      end else begin
        if (arm_sync != arm_seen) begin
          arm_seen      <= arm_sync;
          armed         <= 1'b1;
          start_pending <= 1'b0;
          play_prepare_pulse <= 1'b1;
        end

        // RFCTRL2 Trigger crosses the clock boundary as its own toggle. It
        // deliberately bypasses the legacy stretched GPIO trigger path.
        if (trigger_sync != trigger_seen) begin
          trigger_seen <= trigger_sync;
          if (armed)
            play_trigger_pulse <= 1'b1;
        end

        // The master owns the epoch command and launches the physical sync
        // pulse.  The follower deliberately ignores host epoch writes and
        // accepts its epoch only through EXT_TRIGGER.
        if ((epoch_sync != epoch_seen) && (BOARD_IS_MASTER != 0)) begin
          epoch_seen        <= epoch_sync;
          epoch_pending     <= 1'b1;
          epoch_delay_count <= MASTER_EPOCH_DELAY_CYCLES;
          start_pending     <= 1'b0;
          if (armed) begin
            sync_out         <= 1'b1;
            sync_width_count <= SYNC_PULSE_CYCLES;
          end
        end else if ((epoch_sync != epoch_seen) && (BOARD_IS_MASTER == 0)) begin
          epoch_seen <= epoch_sync;
        end

        if (sync_width_count != 32'd0) begin
          if (sync_width_count == 32'd1) begin
            sync_width_count <= 32'd0;
            sync_out <= 1'b0;
          end else begin
            sync_width_count <= sync_width_count - 32'd1;
          end
        end

        if (epoch_pending) begin
          if (epoch_delay_count == 32'd0) begin
            sync_epoch    <= epoch_sync_data;
            hardware_tick <= epoch_sync_data;
            epoch_pending <= 1'b0;
          end else begin
            epoch_delay_count <= epoch_delay_count - 32'd1;
          end
        end else if (ext_sync_pulse && (BOARD_IS_MASTER == 0)) begin
          sync_epoch    <= 64'd0;
          hardware_tick <= 64'd0;
          start_pending <= 1'b0;
        end else begin
          hardware_tick <= hardware_tick + 64'd1;

          if (start_sync != start_seen) begin
            start_seen             <= start_sync;
            programmed_start_tick  <= start_sync_data;
            start_pending          <= 1'b1;
          end

          // START_AT is intentionally ignored until an explicit ARM command.
          // A late start is left pending rather than creating a non-deterministic
          // immediate trigger; the host must abort and create a new epoch.
          if (start_pending && armed && (hardware_tick == (programmed_start_tick - 64'd1))) begin
            play_trigger_pulse <= 1'b1;
            start_pending      <= 1'b0;
          end
        end
      end
    end
  end

endmodule
