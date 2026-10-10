`timescale 1ns/1ps
// CMAC RX -> classifier -> 512-bit asynchronous frame FIFO -> DDR clock.
//
// Bulk frames must reach the DDR clock domain whole and in order, or not at
// all: a frame the MAC marked bad, or one that does not fit in the FIFO, is
// dropped completely and counted.  Everything else stays on the control port.
module tb_wave_bulk_rx_path;
  reg rx_clk=0; always #1.55 rx_clk=~rx_clk;     // 322 MHz
  reg clk=0;    always #1.666 clk=~clk;          // 300 MHz, unrelated phase
  reg rx_rst=1, rst=1;
  reg enable=1;
  localparam [47:0] MAC = 48'h02_00_10_6d_15_95;
  localparam [31:0] IP  = {8'd169, 8'd254, 8'd5, 8'd248};
  localparam [15:0] BULK_PORT = 16'd1235;

  reg s_tvalid=0; reg [511:0] s_tdata=0; reg [63:0] s_tkeep=0; reg s_tlast=0; reg s_tuser=0;
  wire c_tvalid; wire [511:0] c_tdata; wire [63:0] c_tkeep; wire c_tlast; wire c_tuser;
  wire b_tvalid; wire [511:0] b_tdata; wire b_tlast; reg b_tready=1;
  wire [31:0] stat_frames, stat_dropped_full, stat_dropped_bad;

  wave_bulk_rx_path #(.FIFO_DEPTH_WORDS(256)) dut (
    .rx_clk(rx_clk), .rx_rst(rx_rst),
    .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
    .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
    .m_ctl_axis_tdata(c_tdata), .m_ctl_axis_tkeep(c_tkeep), .m_ctl_axis_tvalid(c_tvalid),
    .m_ctl_axis_tlast(c_tlast), .m_ctl_axis_tuser(c_tuser),
    .clk(clk), .rst(rst), .enable(enable), .local_mac(MAC), .local_ip(IP), .bulk_port(BULK_PORT),
    .m_bulk_axis_tdata(b_tdata), .m_bulk_axis_tvalid(b_tvalid), .m_bulk_axis_tready(b_tready),
    .m_bulk_axis_tlast(b_tlast),
    .stat_frames(stat_frames), .stat_dropped_full(stat_dropped_full), .stat_dropped_bad(stat_dropped_bad));

  integer errors = 0;
  task automatic expect_eq(input string what, input longint got, input longint want);
    if (got !== want) begin errors = errors + 1; $display("ERROR @%0t: %s = %0d, expected %0d", $time, what, got, want); end
  endtask

  // Frame `tag` is 64 + 64*words(tag) bytes; byte i >= 64 is pattern(tag, i).
  // The tag sits in the session field of the bulk header.
  function automatic integer words_of(input integer tag); words_of = 1 + (tag * 7) % 40; endfunction
  function automatic [7:0] pattern(input integer tag, input integer idx); pattern = (tag * 29 + idx * 7 + (idx >> 8)) & 8'hff; endfunction
  task automatic send(input integer tag, input bit bulk, input bit bad);
    integer w, b, nwords; reg [511:0] d;
    begin
      nwords = 1 + words_of(tag);
      for (w = 0; w < nwords; w = w + 1) begin
        for (b = 0; b < 64; b = b + 1) d[b*8 +: 8] = pattern(tag, w * 64 + b);
        if (w == 0) begin
          d[0 +: 48] = {MAC[7:0], MAC[15:8], MAC[23:16], MAC[31:24], MAC[39:32], MAC[47:40]};
          d[12*8 +: 16] = 16'h0008; d[14*8 +: 8] = 8'h45; d[20*8 +: 16] = 16'h0040; d[23*8 +: 8] = 8'd17;
          d[30*8 +: 32] = {IP[7:0], IP[15:8], IP[23:16], IP[31:24]};
          d[36*8 +: 16] = bulk ? {BULK_PORT[7:0], BULK_PORT[15:8]} : 16'hd204;
          d[42*8 +: 32] = {"K", "L", "B", "W"};
          d[46*8 +: 32] = tag;
        end
        @(negedge rx_clk);
        s_tdata = d; s_tkeep = {64{1'b1}}; s_tvalid = 1; s_tlast = (w == nwords - 1); s_tuser = s_tlast && bad;
      end
    end
  endtask
  task automatic idle; begin @(negedge rx_clk); s_tvalid = 0; s_tlast = 0; s_tuser = 0; end endtask

  // ---- checker in the DDR clock domain: whole frames, increasing tags ----
  integer delivered = 0, cur_tag = -1, cur_word = 0, last_tag = -1, ctl_frames = 0;
  always @(posedge clk) if (!rst && b_tvalid && b_tready) begin : check
    integer b; bit bad;
    bad = 0;
    if (cur_word == 0) begin
      cur_tag = b_tdata[46*8 +: 32];
      if (cur_tag <= last_tag) begin errors = errors + 1; $display("ERROR: frame %0d out of order after %0d", cur_tag, last_tag); end
    end else begin
      for (b = 0; b < 64; b = b + 1) if (b_tdata[b*8 +: 8] !== pattern(cur_tag, cur_word * 64 + b)) bad = 1;
      if (bad) begin errors = errors + 1; $display("ERROR: frame %0d word %0d corrupted", cur_tag, cur_word); end
    end
    if (b_tlast) begin
      if (cur_word != words_of(cur_tag)) begin
        errors = errors + 1; $display("ERROR: frame %0d delivered with %0d words, sent %0d", cur_tag, cur_word, words_of(cur_tag));
      end
      delivered = delivered + 1; last_tag = cur_tag; cur_word = 0;
    end else cur_word = cur_word + 1;
  end
  always @(posedge rx_clk) if (!rx_rst && c_tvalid && c_tlast) ctl_frames = ctl_frames + 1;

  task automatic settle; begin idle; repeat (1500) @(posedge clk); end endtask

  initial begin : stim
    integer t, sent_bulk, sent_ctl, n_bad;
    repeat (30) @(posedge rx_clk); rx_rst <= 0; rst <= 0; repeat (40) @(posedge rx_clk);

    // 1. Mixed traffic, receiver keeps up.
    sent_bulk = 0; sent_ctl = 0;
    for (t = 1; t <= 60; t = t + 1) begin
      if (t % 4 == 0) begin send(t, 0, 0); sent_ctl = sent_ctl + 1; end
      else begin send(t, 1, 0); sent_bulk = sent_bulk + 1; end
    end
    settle;
    expect_eq("delivered bulk frames", delivered, sent_bulk);
    expect_eq("control frames", ctl_frames, sent_ctl);
    expect_eq("stat_frames", stat_frames, sent_bulk);
    expect_eq("stat_dropped_full", stat_dropped_full, 0);

    // 2. A frame the MAC marked bad never reaches the writer.
    send(61, 1, 1); send(62, 1, 0);
    settle;
    expect_eq("delivered after a bad frame", delivered, sent_bulk + 1);
    expect_eq("stat_dropped_bad", stat_dropped_bad, 1);
    n_bad = 1;

    // 3. Receiver stalls: frames that do not fit are dropped whole.
    @(negedge clk); b_tready = 0;
    for (t = 100; t < 160; t = t + 1) send(t, 1, 0);
    idle; repeat (200) @(posedge clk);
    @(negedge clk); b_tready = 1;
    settle;
    expect_eq("stat_frames after overflow", stat_frames, sent_bulk + 2 + 60);
    if (stat_dropped_full == 0) begin errors = errors + 1; $display("ERROR: nothing was dropped by a 256-word FIFO"); end
    if (stat_dropped_full >= 60) begin errors = errors + 1; $display("ERROR: every frame was dropped"); end
    expect_eq("delivered + dropped", delivered + stat_dropped_full + stat_dropped_bad, stat_frames);

    // 4. After the overflow the path works again.
    t = delivered;
    send(200, 1, 0); send(201, 1, 0);
    settle;
    expect_eq("delivered after recovery", delivered, t + 2);

    // 5. Disabled: bulk-looking frames stay on the control port.
    @(negedge clk); enable = 0; repeat (20) @(posedge rx_clk);
    t = ctl_frames;
    send(300, 1, 0);
    settle;
    expect_eq("control frames while disabled", ctl_frames, t + 1);

    if (errors == 0) $display("tb_wave_bulk_rx_path PASS (%0d delivered, %0d dropped full)", delivered, stat_dropped_full);
    else $display("tb_wave_bulk_rx_path FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #50_000_000; $display("tb_wave_bulk_rx_path FAIL (timeout)"); $finish; end
endmodule
