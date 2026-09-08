`timescale 1ns/1ps
module tdc_async_fifo #(
    parameter integer WIDTH = 56
) (
    input wire wr_clk, rd_clk, rst_n,
    input wire [WIDTH-1:0] wr_data,
    input wire wr_valid,
    output wire wr_ready,
    output wire [WIDTH-1:0] rd_data,
    output wire rd_valid,
    input wire rd_ready
);
  wire full, empty, wr_busy, rd_busy;
  // rst_n is released in the write domain. Release read-side admission on
  // rd_clk so reset cannot launch downstream arithmetic from the fast clock.
  (* ASYNC_REG = "TRUE" *) reg [2:0] rd_reset_sync;
  always @(posedge rd_clk or negedge rst_n) begin
    if (!rst_n) rd_reset_sync <= 3'b000;
    else rd_reset_sync <= {rd_reset_sync[1:0], 1'b1};
  end
  assign wr_ready = rst_n && !wr_busy && !full;
  assign rd_valid = rd_reset_sync[2] && !rd_busy && !empty;
  xpm_fifo_async #(
      .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(16),
      .WRITE_DATA_WIDTH(WIDTH), .READ_DATA_WIDTH(WIDTH),
      .READ_MODE("fwft"), .FIFO_READ_LATENCY(0),
      .CDC_SYNC_STAGES(2), .RELATED_CLOCKS(0), .ECC_MODE("no_ecc"),
      .WR_DATA_COUNT_WIDTH(5), .RD_DATA_COUNT_WIDTH(5),
      .USE_ADV_FEATURES("0000")
  ) fifo_i (
      .rst(!rst_n), .wr_clk(wr_clk), .rd_clk(rd_clk),
      .din(wr_data), .wr_en(wr_valid && wr_ready), .full(full),
      .wr_rst_busy(wr_busy), .dout(rd_data),
      .rd_en(rd_valid && rd_ready), .empty(empty), .rd_rst_busy(rd_busy),
      .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
      .almost_empty(), .almost_full(), .data_valid(), .dbiterr(),
      .overflow(), .prog_empty(), .prog_full(), .rd_data_count(),
      .sbiterr(), .underflow(), .wr_ack(), .wr_data_count()
  );
endmodule
