`timescale 1ns/1ps

// Test-only models for board chips and the UDP transport boundary.  These
// modules are outside the production playback logic; the real Top still uses
// its production waveform_upload_writer, playback_path, reader, FIFOs and DAC
// stream.  Test code injects UDP words through the hierarchical variables
// below instead of forcing Top internal state.
module udp_10G (
    input  wire        gt_rxp_in,
    input  wire        gt_rxn_in,
    output wire        gt_txp_out,
    output wire        gt_txn_out,
    input  wire        gt_refclk_p,
    input  wire        gt_refclk_n,
    input  wire        clk_100Mhz,
    output wire        calibration_clk_out,
    input  wire        clk,
    input  wire        rst,
    input  wire [47:0] network_local_mac,
    input  wire [31:0] network_local_ip,
    input  wire [31:0] network_gateway_ip,
    input  wire [31:0] network_subnet_mask,
    input  wire [15:0] network_udp_port,
    input  wire        network_clear_arp_cache,
    input  wire        network_restart_pulse,
    input  wire        fifo64_wr,
    input  wire [63:0] fifo64_din,
    output wire        fifo64_af,
    input  wire        resp64_tvalid,
    input  wire [63:0] resp64_tdata,
    input  wire        resp64_tlast,
    input  wire [15:0] resp64_word_count,
    output wire        resp64_tready,
    output wire [7:0]  control_tx_debug,
    output wire        rcv_vld,
    output wire [63:0] rcv_dat,
    output wire        rcv_last,
    input  wire [23:0] gap_num_vio,
    input  wire        loop_en
);
  reg        inj_valid = 1'b0;
  reg [63:0] inj_data = 64'd0;
  reg        inj_last = 1'b0;
  reg        resp_ready = 1'b1;

  assign gt_txp_out = 1'b0;
  assign gt_txn_out = 1'b0;
  assign calibration_clk_out = clk_100Mhz;
  assign fifo64_af = 1'b0;
  assign resp64_tready = resp_ready;
  assign control_tx_debug = 8'd0;
  assign rcv_vld = inj_valid;
  assign rcv_dat = inj_data;
  assign rcv_last = inj_last;
endmodule

module hmc7044 #(
    parameter integer PLL2_SETTLE_TICKS = 2500000
) (
    input  wire clk,
    input  wire rst,
    output wire H7044_SLEN,
    output wire H7044_SCLK,
    output wire H7044_SDATA,
    output wire SET_FINISH,
    input  wire USE_EXTERNAL_250MHZ,
    input  wire IS_MASTER
);
  assign H7044_SLEN = 1'b0;
  assign H7044_SCLK = 1'b0;
  assign H7044_SDATA = 1'b0;
  assign SET_FINISH = 1'b1;
endmodule
