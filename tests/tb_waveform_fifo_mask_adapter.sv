`timescale 1ns/1ps
module tb_waveform_fifo_mask_adapter;
  reg clk = 1'b0; always #5 clk = ~clk;
  reg rst_n = 1'b0;
  reg [7:0] channel_mask = 8'h01;
  reg reader_valid = 1'b1;
  reg [7:0] fifo_ready_actual = 8'b00000001;
  reg [255:0] fifo_wr_counts = 256'd0;
  wire [7:0] fifo_ready_path;
  wire [7:0] fifo_valid_lane;
  wire [15:0] min_level;
  wire [15:0] min_free;
  wire [15:0] reader_credit;
  integer failures = 0;

  waveform_fifo_mask_adapter #(.FIFO_DEPTH(1024)) dut (
      .clk(clk),
      .rst_n(rst_n),
      .channel_mask(channel_mask),
      .reader_valid(reader_valid),
      .fifo_ready_actual(fifo_ready_actual),
      .fifo_wr_counts(fifo_wr_counts),
      .fifo_ready_path(fifo_ready_path),
      .fifo_valid_lane(fifo_valid_lane),
      .min_level(min_level),
      .min_free(min_free),
      .reader_credit(reader_credit));

  // reader_credit is produced by a 3-stage pipeline; allow it to settle.
  task settle; begin repeat (5) @(posedge clk); #1; end endtask

  initial begin
    repeat (3) @(posedge clk); rst_n = 1'b1; @(posedge clk);

    fifo_wr_counts[0*32 +: 32] = 32'd10;
    fifo_wr_counts[1*32 +: 32] = 32'd1024;
    fifo_wr_counts[2*32 +: 32] = 32'd900;
    fifo_wr_counts[3*32 +: 32] = 32'd800;
    fifo_wr_counts[4*32 +: 32] = 32'd700;
    fifo_wr_counts[5*32 +: 32] = 32'd600;
    fifo_wr_counts[6*32 +: 32] = 32'd500;
    fifo_wr_counts[7*32 +: 32] = 32'd400;
    settle;
    if (fifo_ready_path !== 8'hff) begin
      $display("FAIL: inactive lanes must not block reader, ready=%b", fifo_ready_path);
      failures = failures + 1;
    end
    if (fifo_valid_lane !== 8'h01) begin
      $display("FAIL: only enabled lane may receive a reader frame, valid=%b", fifo_valid_lane);
      failures = failures + 1;
    end
    // Credit is the real free depth of the ACTIVE lanes.  Lane 1 is full (1024)
    // but disabled, so it must NOT pull the credit down: only lane 0 (level 10)
    // is active -> free = 1024-10 = 1014.
    if (min_level !== 16'd10 || min_free !== 16'd1014 || reader_credit !== 16'd1014) begin
      $display("FAIL: active FIFO credit level=%0d free=%0d reader_credit=%0d", min_level, min_free, reader_credit);
      failures = failures + 1;
    end

    channel_mask = 8'hA5;
    fifo_ready_actual = 8'b10000000;
    settle;
    if (fifo_ready_path !== 8'b11011010) begin
      $display("FAIL: active ready lanes not preserved, ready=%b", fifo_ready_path);
      failures = failures + 1;
    end
    if (fifo_valid_lane !== 8'hA5) begin
      $display("FAIL: mask-gated lane valid=%b", fifo_valid_lane);
      failures = failures + 1;
    end
    // mask 0xA5 -> active lanes 0,2,5,7 (levels 10,900,600,400); max active
    // = 900 -> free = 124.  Credit tracks that real free depth regardless of
    // instantaneous per-lane ready (the reader's frame handshake, not the
    // credit, gates each write).
    if (min_level !== 16'd10 || min_free !== 16'd124 || reader_credit !== 16'd124) begin
      $display("FAIL: masked credit level=%0d free=%0d reader_credit=%0d", min_level, min_free, reader_credit);
      failures = failures + 1;
    end

    // XPM exposes a wide count bus, but a corrupted/out-of-range value must
    // saturate rather than wrap into false free credit.
    channel_mask = 8'h01;
    fifo_wr_counts[0*32 +: 32] = 32'd2048;
    settle;
    if (min_level !== 16'd1024 || min_free !== 16'd0 || reader_credit !== 16'd0) begin
      $display("FAIL: out-of-range count did not saturate level=%0d free=%0d credit=%0d", min_level, min_free, reader_credit);
      failures = failures + 1;
    end

    // A zero mask is invalid at the protocol layer and must fail closed.
    channel_mask = 8'h00;
    settle;
    if (min_level !== 16'd0 || min_free !== 16'd0 || reader_credit !== 16'd0) begin
      $display("FAIL: zero channel mask did not fail closed level=%0d free=%0d credit=%0d", min_level, min_free, reader_credit);
      failures = failures + 1;
    end

    reader_valid = 1'b0;
    settle;
    if (fifo_valid_lane !== 8'h00) begin
      $display("FAIL: invalid reader frame leaked to lane valid=%b", fifo_valid_lane);
      failures = failures + 1;
    end
    if (failures) $fatal(1, "%0d waveform FIFO mask adapter failures", failures);
    $display("PASS: disabled FIFO lanes cannot block or consume reader credit");
    $finish;
  end
endmodule
