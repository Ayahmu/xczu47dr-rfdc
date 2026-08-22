`timescale 1ns/1ps

// Software-triggered board synchronization and post-sync playback trigger.
// The DDR-domain request/trigger inputs are intentionally kept separate from
// the PL-domain sync sequencer so both CDC paths can be verified in isolation.
module sync_trigger_link #(
    parameter integer IS_MASTER = 1,
    parameter integer WAIT_CYCLES = 100000,
    parameter integer HIGH_CYCLES = 100,
    // Keep the post-sync playback trigger high long enough to tolerate the
    // Type-C differential input and the slave clock phase at the DAC CDC.
    parameter integer TRIGGER_HIGH_CYCLES = 64
) (
    input  wire ddr_clk,
    input  wire ddr_rst_n,
    input  wire pl_clk,
    input  wire pl_rst_n,
    input  wire sync_request_ddr,
    input  wire trigger_request_ddr,
    input  wire sync_request_vio_pl,
    input  wire sync_in,
    input  wire dac_trigger_start,
    output wire hmc_sync,
    output wire sync_link_out,
    output wire role_trigger_raw,
    output wire sync_done,
    output wire sync_seen,
    output wire sync_link_ready
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
        sync_epoch_stretch_cnt <= sync_epoch_stretch_cnt - 5'd1;
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
    end else begin
      sync_epoch_pl_sync <= {sync_epoch_pl_sync[0], sync_epoch_stretch};
      trigger_toggle_pl_sync <= {
          trigger_toggle_pl_sync[0], trigger_link_toggle_ddr
      };
      if (trigger_toggle_pl_sync[1] != trigger_toggle_pl_seen) begin
        trigger_toggle_pl_seen <= trigger_toggle_pl_sync[1];
        trigger_stretch_cnt <= TRIGGER_HIGH_CYCLES;
      end else if (trigger_stretch_cnt != {TRIGGER_CNT_WIDTH{1'b0}}) begin
        trigger_stretch_cnt <= trigger_stretch_cnt - 1'b1;
      end
      trigger_stretched <=
          (trigger_toggle_pl_sync[1] != trigger_toggle_pl_seen) ||
          (trigger_stretch_cnt != 4'd0);
    end
  end

  wire sync_request_pl = sync_request_vio_pl | sync_epoch_pl_sync[1];
  wire master_hmc_sync;
  wire master_slave_sync;
  reg sync_seen_reg;
  reg slave_hmc_sync_hold;
  reg sync_link_ready_reg;

  sync_role_control #(
      .IS_MASTER(IS_MASTER),
      .WAIT_CYCLES(WAIT_CYCLES),
      .HIGH_CYCLES(HIGH_CYCLES)
  ) sync_role_i (
      .clk         (pl_clk),
      .rst_n       (pl_rst_n),
      .sync_request(sync_request_pl),
      .sync_in     (sync_in),
      .hmc_sync    (master_hmc_sync),
      .slave_sync  (master_slave_sync),
      .sync_done   (sync_done)
  );

  always @(posedge pl_clk or negedge pl_rst_n) begin
    if (!pl_rst_n) begin
      sync_seen_reg <= 1'b0;
      sync_link_ready_reg <= 1'b0;
    end else begin
      if (sync_done)
        sync_seen_reg <= 1'b1;
      // Do not expose the tail of the second HMC pulse as a playback trigger.
      if (sync_seen_reg && !sync_in)
        sync_link_ready_reg <= 1'b1;
    end
  end

  // Preserve the complete second received HMC pulse after sync_done. Once the
  // pulse is low, later AN8/AN7 pulses are reserved for playback triggering.
  always @(posedge pl_clk or negedge pl_rst_n) begin
    if (!pl_rst_n)
      slave_hmc_sync_hold <= 1'b0;
    else if (IS_MASTER)
      slave_hmc_sync_hold <= 1'b0;
    else if (!sync_seen_reg || slave_hmc_sync_hold)
      slave_hmc_sync_hold <= sync_in;
    else
      slave_hmc_sync_hold <= 1'b0;
  end

  assign hmc_sync = IS_MASTER ? master_hmc_sync : slave_hmc_sync_hold;
  assign sync_link_out = IS_MASTER ?
      (master_slave_sync | trigger_stretched) : 1'b0;
  assign role_trigger_raw = IS_MASTER ? 1'b0 :
      (dac_trigger_start | (sync_link_ready_reg && sync_in));
  assign sync_seen = sync_seen_reg;
  assign sync_link_ready = sync_link_ready_reg;
endmodule
