// ============================================================
//  cfg_cdc_fifo_xpm  (xpm_fifo_async)
// ============================================================
module cfg_cdc_fifo_xpm #(
  parameter integer W = 160,
  parameter integer DEPTH = 16
)(
  input  wire         wr_clk,
  input  wire         wr_rst_n,
  input  wire [W-1:0] wr_data,
  input  wire         wr_valid,
  output wire         wr_ready,

  input  wire         rd_clk,
  input  wire         rd_rst_n,
  output wire [W-1:0] rd_data,
  output wire         rd_valid,
  input  wire         rd_ready
);

  // DEPTH must be power of 2 for xpm_fifo_async in many configs; we keep simple.
  localparam integer ADDR_W = $clog2(DEPTH);

  wire full, empty;
  wire [W-1:0] dout;

  assign wr_ready = ~full;
  assign rd_valid = ~empty;
  assign rd_data  = dout;

  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("auto"),
    .ECC_MODE("no_ecc"),
    .RELATED_CLOCKS(0),
    .FIFO_WRITE_DEPTH(DEPTH),
    .WRITE_DATA_WIDTH(W),
    .READ_DATA_WIDTH(W),
    .WR_DATA_COUNT_WIDTH(ADDR_W+1),
    .RD_DATA_COUNT_WIDTH(ADDR_W+1),
    .READ_MODE("fwft")
  ) u_xpm_fifo_async (
    .rst(~wr_rst_n), // 只用写域复位做全局复位输入（简化）。真实工程可用同步方案
    .wr_clk(wr_clk),
    .wr_en(wr_valid && wr_ready),
    .din(wr_data),
    .full(full),
    .wr_data_count(),
    .wr_rst_busy(),

    .rd_clk(rd_clk),
    .rd_en(rd_ready && rd_valid),
    .dout(dout),
    .empty(empty),
    .rd_data_count(),
    .rd_rst_busy(),

    .sleep(1'b0),
    .injectdbiterr(1'b0),
    .injectsbiterr(1'b0),
    .dbiterr(),
    .sbiterr()
  );

endmodule