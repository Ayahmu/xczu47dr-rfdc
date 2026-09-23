`timescale 1ns/1ps

// Ordered command mailbox from the WAVECTR0/DDR domain into the DAC domain.
// Unlike a pulse toggle, this cannot merge two adjacent commands when the
// source and destination clocks have an unlucky phase relationship.
module waveform_command_cdc #(
    parameter integer DEPTH = 16
) (
    input wire wr_clk,
    input wire wr_rst_n,
    input wire [2:0] wr_cmd,
    input wire wr_valid,
    output wire wr_ready,
    input wire rd_clk,
    input wire rd_rst_n,
    output wire [2:0] rd_cmd,
    output wire rd_valid,
    input wire rd_ready
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
      .FIFO_MEMORY_TYPE("distributed"),
      .ECC_MODE("no_ecc"),
      .RELATED_CLOCKS(0),
      .FIFO_WRITE_DEPTH(DEPTH),
      .WRITE_DATA_WIDTH(3),
      .READ_DATA_WIDTH(3),
      .READ_MODE("fwft"),
      .FIFO_READ_LATENCY(0),
      .CDC_SYNC_STAGES(2),
      .USE_ADV_FEATURES("0000")
  ) u_command_fifo (
      .rst(!fifo_rst_n),
      .wr_clk(wr_clk),
      .wr_en(wr_valid && wr_ready),
      .din(wr_cmd),
      .full(full),
      .wr_data_count(),
      .wr_rst_busy(wr_rst_busy),
      .rd_clk(rd_clk),
      .rd_en(rd_valid && rd_ready),
      .dout(rd_cmd),
      .empty(empty),
      .rd_data_count(),
      .rd_rst_busy(rd_rst_busy),
      .sleep(1'b0),
      .injectdbiterr(1'b0),
      .injectsbiterr(1'b0),
      .dbiterr(),
      .sbiterr()
  );

  // full/empty and the corresponding busy flag are native to their
  // respective FIFO clock domains; do not gate either side with the
  // opposite-domain busy signal.
  assign wr_ready = wr_rst_n && !full && !wr_rst_busy;
  assign rd_valid = rd_rst_n && !empty && !rd_rst_busy;
endmodule
