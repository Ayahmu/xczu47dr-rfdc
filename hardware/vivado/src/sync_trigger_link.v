`timescale 1ns/1ps

// Independent SYNC and external Trigger links.
//
// sync_link_out is the only signal driven on XS20. trigger_link_out is the
// only signal driven on XS18. sync_in is sampled from XS20 and trigger_in is
// sampled from XS19. No Type-C signal is used by this module.
module sync_trigger_link #(
    parameter integer IS_MASTER = 1,
    parameter integer WAIT_CYCLES = 20000,
    parameter integer HIGH_CYCLES = 40,
    parameter integer TRIGGER_HIGH_CYCLES = 64
) (
    input  wire ddr_clk,
    input  wire ddr_rst_n,
    input  wire pl_clk,
    input  wire pl_rst_n,
    input  wire mclk,
    input  wire sync_request_ddr,
    input  wire trigger_request_ddr,
    input  wire sync_request_vio_pl,
    input  wire sync_in,
    input  wire trigger_in,
    input  wire dac_trigger_start,
    input  wire role_master,
    input  wire sync_bypass,
    input  wire [5:0] firmware_ack_epoch,
    input  wire firmware_align_failed,
    output wire hmc_sync,
    output wire sync_link_out,
    output wire trigger_link_out,
    output wire role_trigger_raw,
    output wire sync_done,
    output wire sync_seen,
    output wire sync_link_ready,
    output wire [5:0] sync_event_epoch,
    output wire sync_align_busy,
    output wire sync_align_failed,
    output wire [5:0] sync_alignment_epoch,
    output wire trigger_in_seen,
    output wire trigger_accepted,
    output wire trigger_output_active,
    output wire [31:0] trigger_input_count,
    output wire [31:0] trigger_accepted_count,
    output wire [31:0] trigger_output_count
);
  reg [4:0] sync_epoch_stretch_cnt;
  reg sync_epoch_stretch;
  reg trigger_link_toggle_ddr;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] sync_epoch_pl_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] trigger_toggle_pl_sync;
  reg trigger_toggle_pl_seen;
  localparam integer TRIGGER_CNT_WIDTH =
      (TRIGGER_HIGH_CYCLES <= 1) ? 1 : $clog2(TRIGGER_HIGH_CYCLES + 1);
  reg [TRIGGER_CNT_WIDTH-1:0] trigger_stretch_cnt;
  reg trigger_stretched;

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] trigger_in_pl_sync;
  reg trigger_in_pl_prev;
  reg trigger_in_seen_reg;
  reg trigger_accepted_reg;
  reg trigger_output_active_reg;
  reg [31:0] trigger_input_count_reg;
  reg [31:0] trigger_accepted_count_reg;
  reg [31:0] trigger_output_count_reg;
  reg sync_link_ready_reg;
  reg sync_bypass_prev;
  reg [5:0] sync_event_epoch_reg;
  reg [5:0] sync_alignment_epoch_reg;
  reg sync_align_busy_reg;
  reg sync_align_failed_reg;
  reg sync_sequence_pending_reg;
  reg sync_request_pl_prev;
  wire sync_transaction_busy = sync_sequence_pending_reg || sync_align_busy_reg;
  wire trigger_allowed = (role_master || sync_bypass || sync_link_ready_reg) &&
                         !sync_transaction_busy && !sync_align_failed_reg;

  always @(posedge ddr_clk or negedge ddr_rst_n) begin
    if (!ddr_rst_n) begin
      sync_epoch_stretch_cnt <= 5'd0;
      sync_epoch_stretch <= 1'b0;
      trigger_link_toggle_ddr <= 1'b0;
    end else begin
      if (sync_request_ddr)
        sync_epoch_stretch_cnt <= 5'd16;
      if (trigger_request_ddr)
        trigger_link_toggle_ddr <= ~trigger_link_toggle_ddr;
      if (sync_epoch_stretch_cnt != 5'd0) begin
        sync_epoch_stretch <= 1'b1;
        sync_epoch_stretch_cnt <= sync_epoch_stretch_cnt - 1'b1;
      end else begin
        sync_epoch_stretch <= 1'b0;
      end
    end
  end

  always @(posedge pl_clk or negedge pl_rst_n) begin
    if (!pl_rst_n) begin
      sync_epoch_pl_sync <= 2'b00;
      trigger_toggle_pl_sync <= 2'b00;
      trigger_toggle_pl_seen <= 1'b0;
      trigger_stretch_cnt <= {TRIGGER_CNT_WIDTH{1'b0}};
      trigger_stretched <= 1'b0;
      trigger_in_pl_sync <= 2'b00;
      trigger_in_pl_prev <= 1'b0;
      trigger_in_seen_reg <= 1'b0;
      trigger_accepted_reg <= 1'b0;
      trigger_output_active_reg <= 1'b0;
      trigger_input_count_reg <= 32'd0;
      trigger_accepted_count_reg <= 32'd0;
      trigger_output_count_reg <= 32'd0;
    end else begin
      sync_epoch_pl_sync <= {sync_epoch_pl_sync[0], sync_epoch_stretch};
      trigger_toggle_pl_sync <= {
          trigger_toggle_pl_sync[0], trigger_link_toggle_ddr
      };
      trigger_in_pl_sync <= {trigger_in_pl_sync[0], trigger_in};
      trigger_in_pl_prev <= trigger_in_pl_sync[1];
      trigger_in_seen_reg <= trigger_in_pl_sync[1] && !trigger_in_pl_prev;
      trigger_accepted_reg <= trigger_in_pl_sync[1] && !trigger_in_pl_prev &&
                              trigger_allowed;

      if (trigger_toggle_pl_sync[1] != trigger_toggle_pl_seen) begin
        trigger_toggle_pl_seen <= trigger_toggle_pl_sync[1];
        trigger_stretch_cnt <= TRIGGER_HIGH_CYCLES;
      end else if (trigger_stretch_cnt != {TRIGGER_CNT_WIDTH{1'b0}}) begin
        trigger_stretch_cnt <= trigger_stretch_cnt - 1'b1;
      end
      trigger_stretched <=
          (trigger_toggle_pl_sync[1] != trigger_toggle_pl_seen) ||
          (trigger_stretch_cnt != {TRIGGER_CNT_WIDTH{1'b0}});
      trigger_output_active_reg <= trigger_stretched;
      if (trigger_in_pl_sync[1] && !trigger_in_pl_prev)
        trigger_input_count_reg <= trigger_input_count_reg + 1'b1;
      if (trigger_in_pl_sync[1] && !trigger_in_pl_prev &&
          trigger_allowed)
        trigger_accepted_count_reg <= trigger_accepted_count_reg + 1'b1;
      if (trigger_stretched && !trigger_output_active_reg)
        trigger_output_count_reg <= trigger_output_count_reg + 1'b1;
    end
  end

  wire sync_request_pl = sync_request_vio_pl | sync_epoch_pl_sync[1];
  wire sync_request_pl_rise = sync_request_pl && !sync_request_pl_prev;
  wire master_hmc_sync;
  wire master_slave_sync;
  reg sync_seen_reg;
  reg sync_in_prev;

  sync_role_control #(
      .IS_MASTER(IS_MASTER),
      .WAIT_CYCLES(WAIT_CYCLES),
      .HIGH_CYCLES(HIGH_CYCLES)
  ) sync_role_i (
      .clk         (pl_clk),
      .mclk        (mclk),
      .rst_n       (pl_rst_n),
      .sync_request(sync_request_pl),
      .sync_in     (sync_in),
      .role_master (role_master),
      .sync_bypass (sync_bypass),
      .hmc_sync    (master_hmc_sync),
      .slave_sync  (master_slave_sync),
      .sync_done   (sync_done)
  );

  always @(posedge pl_clk or negedge pl_rst_n) begin
    if (!pl_rst_n) begin
      sync_seen_reg <= 1'b0;
      sync_link_ready_reg <= 1'b0;
      sync_in_prev <= 1'b0;
      sync_bypass_prev <= 1'b0;
      sync_event_epoch_reg <= 6'd0;
      sync_alignment_epoch_reg <= 6'd0;
      sync_align_busy_reg <= 1'b0;
      sync_align_failed_reg <= 1'b0;
      sync_sequence_pending_reg <= 1'b0;
      sync_request_pl_prev <= 1'b0;
    end else begin
      sync_in_prev <= sync_in;
      sync_bypass_prev <= sync_bypass;
      sync_request_pl_prev <= sync_request_pl;
      // Close every playback/configuration gate as soon as a master SYNC
      // request enters the PL sequencer, including its pre-pulse wait state.
      if (role_master && !sync_bypass && sync_request_pl_rise) begin
        sync_sequence_pending_reg <= 1'b1;
        sync_align_failed_reg <= 1'b0;
        sync_link_ready_reg <= 1'b0;
      end
      // Every real SYNC completion starts a fresh firmware alignment
      // transaction.  Bypass is intentionally excluded from this path.
      if (sync_done && !sync_bypass) begin
        sync_sequence_pending_reg <= 1'b0;
        sync_event_epoch_reg <= sync_event_epoch_reg + 1'b1;
        sync_align_busy_reg <= 1'b1;
        sync_align_failed_reg <= 1'b0;
        sync_link_ready_reg <= 1'b0;
      end else if (sync_align_busy_reg) begin
        if (firmware_align_failed &&
            (firmware_ack_epoch == sync_event_epoch_reg)) begin
          // Failures are epoch-qualified so a stale firmware failure bit
          // cannot poison the next realignment attempt.
          sync_align_failed_reg <= 1'b1;
        end else if (firmware_ack_epoch == sync_event_epoch_reg) begin
          sync_alignment_epoch_reg <= firmware_ack_epoch;
          sync_align_busy_reg <= 1'b0;
          sync_align_failed_reg <= 1'b0;
          sync_link_ready_reg <= 1'b1;
        end
      end
      if (role_master) begin
        // A master can always operate locally. sync_seen remains an event
        // indicator: it records a sync pulse actually emitted on XS20.
        if (!sync_transaction_busy && !sync_request_pl_rise &&
            !sync_done && !sync_align_failed_reg)
          sync_link_ready_reg <= 1'b1;
        if (sync_done)
          sync_seen_reg <= 1'b1;
      end else if (sync_bypass != sync_bypass_prev) begin
        // A mode change starts a fresh slave synchronization epoch. Bypass
        // grants local operation but never pretends an XS20 pulse occurred.
        sync_seen_reg <= 1'b0;
        if (!sync_transaction_busy && !sync_done)
          sync_link_ready_reg <= sync_bypass;
      end else if (sync_bypass) begin
        if (!sync_transaction_busy && !sync_done)
          sync_link_ready_reg <= 1'b1;
      end else if (sync_done && !role_master) begin
        sync_seen_reg <= 1'b1;
      end
      // The input must return low before a received SYNC is considered a
      // complete external synchronization event. This prevents its high
      // level from being interpreted as a Trigger.
      if (sync_seen_reg && !sync_in && !role_master &&
          !sync_transaction_busy && !sync_done)
        sync_link_ready_reg <= 1'b1;
      if (!sync_bypass && !role_master && !sync_seen_reg && sync_in_prev && !sync_in)
        sync_link_ready_reg <= 1'b0;
    end
  end

  assign hmc_sync = master_hmc_sync;
  assign sync_link_out = master_slave_sync;
  assign trigger_link_out = trigger_stretched;
  // The legacy trigger input is retained for pin-level compatibility, but it
  // obeys the same SYNC gate as XS19. Master always runs locally; a slave
  // needs real XS20 synchronization or the explicit runtime bypass.
  assign role_trigger_raw = (dac_trigger_start |
      (trigger_in_pl_sync[1] && !trigger_in_pl_prev)) &&
      trigger_allowed;
  assign sync_seen = sync_seen_reg;
  assign sync_link_ready = sync_link_ready_reg;
  assign sync_event_epoch = sync_event_epoch_reg;
  assign sync_align_busy = sync_transaction_busy;
  assign sync_align_failed = sync_align_failed_reg;
  assign sync_alignment_epoch = sync_alignment_epoch_reg;
  assign trigger_in_seen = trigger_in_seen_reg;
  assign trigger_accepted = trigger_accepted_reg;
  assign trigger_output_active = trigger_output_active_reg;
  assign trigger_input_count = trigger_input_count_reg;
  assign trigger_accepted_count = trigger_accepted_count_reg;
  assign trigger_output_count = trigger_output_count_reg;
endmodule
