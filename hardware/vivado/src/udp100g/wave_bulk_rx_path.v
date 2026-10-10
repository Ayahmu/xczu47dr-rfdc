`timescale 1ns/1ps

// Bulk waveform receive path between the CMAC RX interface and the DDR/UI
// clock domain.
//
//   CMAC RX (512 bit, rx_clk) -> wave_bulk_rx_classifier
//       control frames -> m_ctl_axis_* (rx_clk, to the 64-bit UDP stack)
//       bulk frames    -> asynchronous frame FIFO -> m_bulk_axis_* (clk)
//
// The FIFO is store-and-forward: the MAC reports a bad FCS only on the last
// word, so a frame is released to the DDR writer only once it is complete and
// clean.  A frame that does not fit is dropped whole.  Both cases are counted
// in rx_clk and published to clk as a coherent snapshot.
module wave_bulk_rx_path #(
    parameter integer FIFO_DEPTH_WORDS = 4096
) (
    input  wire         rx_clk,
    input  wire         rx_rst,
    input  wire [511:0] s_axis_tdata,
    input  wire [63:0]  s_axis_tkeep,
    input  wire         s_axis_tvalid,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tuser,

    output wire [511:0] m_ctl_axis_tdata,
    output wire [63:0]  m_ctl_axis_tkeep,
    output wire         m_ctl_axis_tvalid,
    output wire         m_ctl_axis_tlast,
    output wire         m_ctl_axis_tuser,

    // DDR/UI clock domain.  The identity inputs are quasi-static.
    input  wire         clk,
    input  wire         rst,
    input  wire         enable,
    input  wire [47:0]  local_mac,
    input  wire [31:0]  local_ip,
    input  wire [15:0]  bulk_port,

    output wire [511:0] m_bulk_axis_tdata,
    output wire         m_bulk_axis_tvalid,
    input  wire         m_bulk_axis_tready,
    output wire         m_bulk_axis_tlast,

    output reg  [31:0]  stat_frames,        // bulk frames seen by the classifier
    output reg  [31:0]  stat_dropped_full,  // dropped because the FIFO was full
    output reg  [31:0]  stat_dropped_bad    // dropped because the MAC marked them bad
);
  // ---- identity into rx_clk (quasi-static, two-flop synchronizer) ----
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [96:0] cfg_sync1_reg = 97'd0;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [96:0] cfg_sync2_reg = 97'd0;
  always @(posedge rx_clk) begin
    cfg_sync1_reg <= {enable, bulk_port, local_ip, local_mac};
    cfg_sync2_reg <= cfg_sync1_reg;
  end

  wire [511:0] bulk_tdata;
  wire         bulk_tvalid, bulk_tlast, bulk_tuser;
  wave_bulk_rx_classifier classifier_i (
      .clk(rx_clk), .rst(rx_rst), .enable(cfg_sync2_reg[96]),
      .local_mac(cfg_sync2_reg[47:0]), .local_ip(cfg_sync2_reg[79:48]), .bulk_port(cfg_sync2_reg[95:80]),
      .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep), .s_axis_tvalid(s_axis_tvalid),
      .s_axis_tlast(s_axis_tlast), .s_axis_tuser(s_axis_tuser),
      .m_ctl_axis_tdata(m_ctl_axis_tdata), .m_ctl_axis_tkeep(m_ctl_axis_tkeep),
      .m_ctl_axis_tvalid(m_ctl_axis_tvalid), .m_ctl_axis_tlast(m_ctl_axis_tlast),
      .m_ctl_axis_tuser(m_ctl_axis_tuser),
      .m_bulk_axis_tdata(bulk_tdata), .m_bulk_axis_tvalid(bulk_tvalid),
      .m_bulk_axis_tlast(bulk_tlast), .m_bulk_axis_tuser(bulk_tuser));

  wire fifo_overflow, fifo_bad_frame;
  axis_async_fifo #(
      .DEPTH(FIFO_DEPTH_WORDS), .DATA_WIDTH(512), .KEEP_ENABLE(0), .LAST_ENABLE(1),
      .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1), .USER_WIDTH(1),
      .RAM_PIPELINE(2), .OUTPUT_FIFO_ENABLE(0), .FRAME_FIFO(1),
      .USER_BAD_FRAME_VALUE(1'b1), .USER_BAD_FRAME_MASK(1'b1),
      .DROP_OVERSIZE_FRAME(1), .DROP_BAD_FRAME(1), .DROP_WHEN_FULL(1),
      .MARK_WHEN_FULL(0), .PAUSE_ENABLE(0), .FRAME_PAUSE(0)
  ) bulk_fifo_i (
      .s_clk(rx_clk), .s_rst(rx_rst),
      .s_axis_tdata(bulk_tdata), .s_axis_tkeep(64'd0), .s_axis_tvalid(bulk_tvalid), .s_axis_tready(),
      .s_axis_tlast(bulk_tlast), .s_axis_tid(8'd0), .s_axis_tdest(8'd0), .s_axis_tuser(bulk_tuser),
      .m_clk(clk), .m_rst(rst),
      .m_axis_tdata(m_bulk_axis_tdata), .m_axis_tkeep(), .m_axis_tvalid(m_bulk_axis_tvalid),
      .m_axis_tready(m_bulk_axis_tready), .m_axis_tlast(m_bulk_axis_tlast),
      .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
      .s_pause_req(1'b0), .s_pause_ack(), .m_pause_req(1'b0), .m_pause_ack(),
      .s_status_depth(), .s_status_depth_commit(),
      .s_status_overflow(fifo_overflow), .s_status_bad_frame(fifo_bad_frame), .s_status_good_frame(),
      .m_status_depth(), .m_status_depth_commit(),
      .m_status_overflow(), .m_status_bad_frame(), .m_status_good_frame());

  // ---- counters in rx_clk ----
  reg [31:0] cnt_frames = 32'd0, cnt_full = 32'd0, cnt_bad = 32'd0;
  always @(posedge rx_clk) begin
    if (rx_rst) begin
      cnt_frames <= 32'd0; cnt_full <= 32'd0; cnt_bad <= 32'd0;
    end else begin
      if (bulk_tvalid && bulk_tlast) cnt_frames <= cnt_frames + 1'b1;
      if (fifo_overflow) cnt_full <= cnt_full + 1'b1;
      if (fifo_bad_frame) cnt_bad <= cnt_bad + 1'b1;
    end
  end

  // ---- snapshot to clk: toggle handshake around a held copy ----
  reg [95:0] stat_hold_reg = 96'd0;
  reg        stat_req = 1'b0;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg stat_ack_sync1_reg = 1'b0;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg stat_ack_sync2_reg = 1'b0;
  reg        stat_ack = 1'b0;
  always @(posedge rx_clk) begin
    stat_ack_sync1_reg <= stat_ack;
    stat_ack_sync2_reg <= stat_ack_sync1_reg;
    if (stat_ack_sync2_reg == stat_req) begin
      stat_hold_reg <= {cnt_bad, cnt_full, cnt_frames};
      stat_req <= !stat_req;
    end
  end
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg stat_req_sync1_reg = 1'b0;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg stat_req_sync2_reg = 1'b0;
  always @(posedge clk) begin
    stat_req_sync1_reg <= stat_req;
    stat_req_sync2_reg <= stat_req_sync1_reg;
    if (stat_req_sync2_reg != stat_ack) begin
      // stat_hold_reg has been stable since stat_req toggled.
      {stat_dropped_bad, stat_dropped_full, stat_frames} <= stat_hold_reg;
      stat_ack <= stat_req_sync2_reg;
    end
    if (rst) begin
      stat_frames <= 32'd0; stat_dropped_full <= 32'd0; stat_dropped_bad <= 32'd0;
    end
  end
endmodule
