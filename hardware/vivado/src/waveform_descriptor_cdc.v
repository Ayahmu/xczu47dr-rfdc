`timescale 1ns/1ps

// Complete descriptor CDC. The descriptor is written once per COMMIT and is
// consumed as one FIFO record; no individual descriptor bit is synchronized.
module waveform_descriptor_cdc #(
    parameter integer WIDTH = 176,
    parameter integer DEPTH = 16
) (
    input wire wr_clk, input wire wr_rst_n,
    input wire [WIDTH-1:0] wr_data, input wire wr_valid, output wire wr_ready,
    input wire rd_clk, input wire rd_rst_n,
    output wire [WIDTH-1:0] rd_data, output wire rd_valid, input wire rd_ready
);
  wire full, empty, wr_rst_busy, rd_rst_busy;

  // The XPM FIFO has one common reset input, while the wrapper receives
  // independent domain resets.  Synchronize DAC reset release into the write
  // domain and use that write-domain reset bridge for the FIFO reset.  The
  // read-side ready gate still reacts immediately to rd_rst_n, so a DAC reset
  // cannot consume stale data while the common FIFO reset catches up.
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] rd_rst_sync_wr;
  always @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n)
      rd_rst_sync_wr <= 3'b000;
    else
      rd_rst_sync_wr <= {rd_rst_sync_wr[1:0], rd_rst_n};
  end
  wire fifo_rst_n = wr_rst_n && rd_rst_sync_wr[2];

  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("distributed"), .ECC_MODE("no_ecc"), .RELATED_CLOCKS(0),
    .FIFO_WRITE_DEPTH(DEPTH), .WRITE_DATA_WIDTH(WIDTH), .READ_DATA_WIDTH(WIDTH),
    .READ_MODE("fwft"), .USE_ADV_FEATURES("0000")
  ) u_descriptor_fifo (
    .rst(!fifo_rst_n),
    .wr_clk(wr_clk), .wr_en(wr_valid && wr_ready), .din(wr_data),
    .full(full), .wr_data_count(), .wr_rst_busy(wr_rst_busy),
    .rd_clk(rd_clk), .rd_en(rd_ready && rd_valid), .dout(rd_data),
    .empty(empty), .rd_data_count(), .rd_rst_busy(rd_rst_busy),
    .sleep(1'b0), .injectdbiterr(1'b0), .injectsbiterr(1'b0),
    .dbiterr(), .sbiterr()
  );
  // full/empty and the corresponding busy flag are native to their
  // respective FIFO clock domains; do not gate either side with the
  // opposite-domain busy signal.
  assign wr_ready = wr_rst_n && !full && !wr_rst_busy;
  assign rd_valid = rd_rst_n && !empty && !rd_rst_busy;
endmodule
