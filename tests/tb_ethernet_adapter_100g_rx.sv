`timescale 1ns/1ps
// RX overflow contract of the 100G 512->64 width adapter.
//
// The CMAC RX interface has no backpressure: it may present one 512-bit word
// every clk_axis cycle, while the 64-bit side drains eight times slower.  A
// burst of back-to-back frames therefore overflows any finite buffer.  The
// adapter must then drop WHOLE frames; it must never deliver a truncated frame
// or splice the head of one frame onto the tail of another.
//
// Every byte of frame N carries (N, byte index), so a delivered frame is
// checked byte-for-byte against its original length and content.
module tb_ethernet_adapter_100g_rx;
  reg clk=0; always #1.55 clk=~clk;   // 322 MHz
  reg rst=1;
  reg rx_tvalid=0; reg [511:0] rx_tdata=0; reg [0:0] rx_tuser=0; reg [63:0] rx_tkeep=0; reg rx_tlast=0;
  wire tx_tvalid; wire [511:0] tx_tdata; wire [63:0] tx_tkeep; wire [0:0] tx_tuser; wire tx_tlast;
  wire udp_rx_tvalid; wire [63:0] udp_rx_tdata; wire [0:0] udp_rx_tuser; wire [7:0] udp_rx_tkeep; wire udp_rx_tlast;
  wire udp_tx_tready;

  ethernet_adapter_100g dut (
    .clk(clk), .user_rx_reset_0(rst), .user_tx_reset_0(rst),
    .rx_axis_tvalid_0(rx_tvalid), .rx_axis_tdata_0(rx_tdata), .rx_axis_tuser_0(rx_tuser),
    .rx_axis_tkeep_0(rx_tkeep), .rx_axis_tlast_0(rx_tlast),
    .tx_axis_tready_0(1'b1), .tx_axis_tvalid_0(tx_tvalid), .tx_axis_tdata_0(tx_tdata),
    .tx_axis_tkeep_0(tx_tkeep), .tx_axis_tuser_0(tx_tuser), .tx_axis_tlast_0(tx_tlast),
    .udp_rx_axis_tvalid(udp_rx_tvalid), .udp_rx_axis_tdata(udp_rx_tdata), .udp_rx_axis_tuser(udp_rx_tuser),
    .udp_rx_axis_tkeep(udp_rx_tkeep), .udp_rx_axis_tlast(udp_rx_tlast),
    .udp_tx_axis_tready(udp_tx_tready), .udp_tx_axis_tvalid(1'b0), .udp_tx_axis_tdata(64'd0),
    .udp_tx_axis_tkeep(8'd0), .udp_tx_axis_tuser(1'b0), .udp_tx_axis_tlast(1'b0)
  );

  localparam integer NFRAMES = 60;
  integer lens [0:NFRAMES-1];
  function [7:0] pattern(input integer frame, input integer idx);
    pattern = (frame * 37 + idx * 13 + (idx >> 8)) & 8'hff;
  endfunction

  // ------------------------------------------------------------ RX driver
  // Words are presented every cycle with no gaps inside or between frames.
  initial begin : drive
    integer f, b, w, nwords;
    for (f = 0; f < NFRAMES; f = f + 1)
      lens[f] = (f % 5 == 0) ? 9000 : (f % 5 == 1) ? 64 : (f % 5 == 2) ? 1500 : (f % 5 == 3) ? 4000 : 777;
    repeat (20) @(posedge clk); rst <= 0; repeat (20) @(posedge clk);
    for (f = 0; f < NFRAMES; f = f + 1) begin
      nwords = (lens[f] + 63) / 64;
      for (w = 0; w < nwords; w = w + 1) begin
        @(negedge clk);
        rx_tvalid = 1; rx_tlast = (w == nwords - 1); rx_tuser = 0;
        for (b = 0; b < 64; b = b + 1) begin
          rx_tkeep[b] = (w * 64 + b) < lens[f];
          rx_tdata[b*8 +: 8] = rx_tkeep[b] ? pattern(f, w * 64 + b) : 8'h00;
        end
      end
    end
    @(negedge clk); rx_tvalid = 0; rx_tlast = 0;
  end

  // ------------------------------------------------------------ checker
  // A delivered frame is identified by its first byte's tag and must match
  // one original frame exactly; frames must arrive in increasing order.
  integer cur_len=0, delivered=0, last_frame=-1, cur_frame=-1, k, bad=0;
  always @(posedge clk) if (!rst && udp_rx_tvalid) begin
    for (k = 0; k < 8; k = k + 1) if (udp_rx_tkeep[k]) begin
      if (cur_len == 0) begin : identify
        integer f;
        cur_frame = -1;
        for (f = last_frame + 1; f < NFRAMES; f = f + 1)
          if (cur_frame < 0 && pattern(f, 0) == udp_rx_tdata[k*8 +: 8]) cur_frame = f;
        if (cur_frame < 0) $fatal(1, "delivered frame starts with unknown tag %h", udp_rx_tdata[k*8 +: 8]);
      end
      if (udp_rx_tdata[k*8 +: 8] !== pattern(cur_frame, cur_len))
        $fatal(1, "frame %0d corrupted at byte %0d: got %h expected %h (spliced or truncated frame)",
               cur_frame, cur_len, udp_rx_tdata[k*8 +: 8], pattern(cur_frame, cur_len));
      cur_len = cur_len + 1;
    end
    if (udp_rx_tlast) begin
      if (cur_len != lens[cur_frame])
        $fatal(1, "frame %0d delivered %0d bytes, sent %0d", cur_frame, cur_len, lens[cur_frame]);
      if (udp_rx_tuser != 0) $fatal(1, "frame %0d delivered with bad-frame tuser", cur_frame);
      delivered = delivered + 1; last_frame = cur_frame; cur_len = 0;
    end
  end

  initial begin
    #400000;
    if (cur_len != 0) $fatal(1, "a frame was left half delivered (%0d bytes of frame %0d)", cur_len, cur_frame);
    if (delivered == 0) $fatal(1, "no frame was delivered");
    $display("tb_ethernet_adapter_100g_rx PASS delivered=%0d of %0d", delivered, NFRAMES);
    $finish;
  end
endmodule
