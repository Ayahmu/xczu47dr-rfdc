`timescale 1ns/1ps
// Bulk waveform frames -> 512-bit AXI writes into DDR, with per-chunk
// accounting so the host can find and resend what was lost.
//
// The first 512-bit word of a frame is the network header word; bytes 42..63
// are the bulk header: "WBLK", session, byte offset, word count, chunk epoch.
// Every following word is one 64-byte DDR beat.
//
// The AXI slave model checks the protocol (no burst crosses a 4 KiB boundary,
// WLAST on the right beat, whole-word strobes) and stores what was written.
module tb_wave_bulk_ddr_writer;
  reg clk=0; always #1.666 clk=~clk;   // 300 MHz
  reg rst_n=0;
  localparam [63:0] BASE = 64'h0000_0048_0000_0000;
  localparam integer MIB = 1048576;

  reg enable=0; reg [31:0] session=0; reg [63:0] total_bytes=0;
  reg ctl_start=0; reg [1:0] ctl_cmd=0; reg [20:0] ctl_arg=0; wire ctl_busy;
  wire complete; wire [13:0] complete_chunks; wire [31:0] first_incomplete;
  wire [31:0] frames_ok, frames_rejected, frames_duplicate, frames_stale; wire overrun, axi_error;
  reg [511:0] s_tdata=0; reg s_tvalid=0; reg s_tlast=0; wire s_tready;
  wire [63:0] awaddr; wire [7:0] awlen; wire awvalid; reg awready=0;
  wire [511:0] wdata; wire [63:0] wstrb; wire wlast; wire wvalid; reg wready=0;
  reg [1:0] bresp=0; reg bvalid=0; wire bready;

  wave_bulk_ddr_writer #(.DDR_ADDR_BASE(BASE)) dut (
    .clk(clk), .rst_n(rst_n), .enable(enable), .session(session), .total_bytes(total_bytes),
    .ctl_start(ctl_start), .ctl_cmd(ctl_cmd), .ctl_arg(ctl_arg), .ctl_busy(ctl_busy),
    .complete(complete), .complete_chunks(complete_chunks), .first_incomplete(first_incomplete),
    .frames_ok(frames_ok), .frames_rejected(frames_rejected), .frames_duplicate(frames_duplicate),
    .frames_stale(frames_stale), .overrun(overrun), .axi_error(axi_error),
    .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
    .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready));

  integer errors = 0;
  task automatic fail(input string msg); begin errors = errors + 1; $display("ERROR @%0t: %s", $time, msg); end endtask
  task automatic expect_eq(input string what, input longint got, input longint want);
    if (got !== want) begin errors = errors + 1; $display("ERROR @%0t: %s = %0d, expected %0d", $time, what, got, want); end
  endtask

  // ------------------------------------------------------------ AXI slave
  integer bp = 0;                       // percent of cycles AW/W are not ready
  reg inject_bresp_error = 0;
  logic [511:0] mem [longint];
  typedef struct { longint addr; int len; } aw_t;
  typedef struct { logic [511:0] data; logic [63:0] strb; logic last; } w_t;
  aw_t aw_q[$]; w_t w_q[$];
  bit burst_open = 0; longint cur_addr; int cur_left; int b_pending = 0;
  longint aw_count = 0, beats_written = 0, beats_masked = 0;
  always @(negedge clk) begin awready = ($urandom_range(99) >= bp); wready = ($urandom_range(99) >= bp); end
  always @(posedge clk) begin
    if (awvalid && awready) begin
      aw_t a; a.addr = awaddr; a.len = awlen; aw_q.push_back(a); aw_count = aw_count + 1;
      if (awaddr[5:0] != 0) fail("AW address is not 64-byte aligned");
      if ((awaddr >> 12) != ((awaddr + (awlen + 1) * 64 - 1) >> 12)) fail("burst crosses a 4 KiB boundary");
      if (awaddr < BASE || awaddr + (awlen + 1) * 64 > BASE + total_bytes) fail("burst outside the session image");
    end
    if (wvalid && wready) begin w_t x; x.data = wdata; x.strb = wstrb; x.last = wlast; w_q.push_back(x); end
    while (1) begin
      if (!burst_open) begin
        if (aw_q.size() == 0) break;
        cur_addr = aw_q[0].addr; cur_left = aw_q[0].len + 1; void'(aw_q.pop_front()); burst_open = 1;
      end
      if (w_q.size() == 0) break;
      begin
        w_t x; x = w_q.pop_front();
        if (x.last !== (cur_left == 1)) fail("WLAST on the wrong beat");
        if (x.strb === {64{1'b1}}) begin mem[cur_addr] = x.data; beats_written = beats_written + 1; end
        else if (x.strb === 64'd0) beats_masked = beats_masked + 1;
        else fail("partial write strobe");
        cur_addr = cur_addr + 64; cur_left = cur_left - 1;
        if (cur_left == 0) begin burst_open = 0; b_pending = b_pending + 1; end
      end
    end
    if (bvalid && bready) bvalid <= 0;
    if (b_pending > 0 && !(bvalid && !bready)) begin
      bvalid <= 1; bresp <= inject_bresp_error ? 2'b10 : 2'b00; b_pending = b_pending - 1;
    end
  end

  // ------------------------------------------------------------ frame source
  integer src_gap = 0;                  // percent of idle cycles between words
  function automatic [511:0] pattern(input [31:0] sess, input longint word_index);
    integer k;
    for (k = 0; k < 8; k = k + 1) pattern[64*k +: 64] = {sess ^ k, word_index[31:0]};
  endfunction
  task automatic push_word(input [511:0] d, input bit last);
    begin
      while ($urandom_range(99) < src_gap) @(negedge clk);
      s_tdata = d; s_tlast = last; s_tvalid = 1;
      @(posedge clk); while (!s_tready) @(posedge clk);
      @(negedge clk); s_tvalid = 0; s_tlast = 0;
    end
  endtask
  // hdr_words is what the header claims, sent_words what actually follows.
  task automatic send_frame(input [31:0] sess, input longint offset, input int hdr_words, input int sent_words, input [7:0] epoch);
    reg [511:0] h; integer i;
    begin
      h = {8{64'hdeadbeef_0badf00d}};
      h[42*8 +: 32] = {"K", "L", "B", "W"};
      h[46*8 +: 32] = sess; h[50*8 +: 64] = offset; h[58*8 +: 16] = hdr_words; h[60*8 +: 8] = epoch; h[61*8 +: 24] = 0;
      push_word(h, sent_words == 0);
      for (i = 0; i < sent_words; i = i + 1) push_word(pattern(sess, offset / 64 + i), i == sent_words - 1);
    end
  endtask
  task automatic good(input [31:0] sess, input longint offset, input int words, input [7:0] epoch);
    send_frame(sess, offset, words, words, epoch);
  endtask
  task automatic ctl(input [1:0] cmd, input [20:0] arg);
    begin
      @(negedge clk); ctl_cmd = cmd; ctl_arg = arg; ctl_start = 1; @(negedge clk); ctl_start = 0;
      @(posedge clk); while (ctl_busy) @(posedge clk); @(negedge clk);
    end
  endtask
  task automatic settle; begin repeat (400) @(posedge clk); @(negedge clk); end endtask
  localparam [1:0] CLEAR = 2'd1, CHUNK_RESET = 2'd2, SCAN = 2'd3;

  task automatic check_image(input [31:0] sess, input longint words);
    longint w; integer bad;
    begin
      bad = 0;
      for (w = 0; w < words; w = w + 1)
        if (!mem.exists(BASE + w * 64) || mem[BASE + w * 64] !== pattern(sess, w)) bad = bad + 1;
      if (bad != 0) begin errors = errors + 1; $display("ERROR: %0d of %0d image words are wrong or missing", bad, words); end
      if (mem.num() != words) begin errors = errors + 1; $display("ERROR: %0d words stored, expected %0d", mem.num(), words); end
    end
  endtask

  initial begin : stim
    integer f; longint off; longint t0, t1; integer n;
    repeat (20) @(posedge clk); rst_n <= 1; repeat (10) @(posedge clk); @(negedge clk);

    // ---- session A: 2.5 MiB = 3 chunks, the last one half full ----
    session = 32'h11; total_bytes = 5 * MIB / 2; enable = 1; @(negedge clk);
    good(32'h11, 0, 16, 0);                       // before the first CLEAR: nothing is armed
    settle; expect_eq("rejected before CLEAR", frames_rejected, 1);
    ctl(CLEAR, 0);
    expect_eq("rejected after CLEAR", frames_rejected, 0);
    expect_eq("complete after CLEAR", complete, 0);

    // 1. Frames that must be dropped without touching DDR.
    good(32'h12, 0, 16, 0);                               // other session
    good(32'h11, 5 * MIB / 2, 16, 0);                     // starts at the end
    good(32'h11, 32, 16, 0);                              // offset not 64-byte aligned
    send_frame(32'h11, 0, 0, 1, 0);                       // zero words
    good(32'h11, 0, 129, 0);                              // too long
    good(32'h11, MIB - 1024, 32, 0);                      // crosses a chunk boundary
    good(32'h11, 5 * MIB / 2 - 1024, 32, 0);              // runs past the end
    send_frame(32'h11, 0, 16, 0, 0);                      // header only
    settle;
    expect_eq("rejected frames", frames_rejected, 8);
    expect_eq("AW count after rejects", aw_count, 0);

    // 2. Length mismatches: write what arrived, finish the burst, do not count.
    send_frame(32'h11, 4096 * 5, 16, 5, 0);               // short: 5 of 16 words
    send_frame(32'h11, 4096 * 6, 4, 9, 0);                // long: 9 words for a 4-word header
    settle;
    expect_eq("rejected after length mismatches", frames_rejected, 10);
    expect_eq("frames_ok after length mismatches", frames_ok, 0);
    expect_eq("beats written by mismatched frames", beats_written, 9);
    expect_eq("beats masked by the short frame", beats_masked, 11);
    expect_eq("words stored by mismatched frames", mem.num(), 9);

    // 3. The real upload, 1024-byte frames, two of them lost on the way.
    bp = 30; src_gap = 20;
    for (f = 0; f < 2560; f = f + 1) if (f != 5 && f != 2100) good(32'h11, f * 1024, 16, 0);
    settle;
    expect_eq("frames_ok", frames_ok, 2558);
    expect_eq("complete with two frames lost", complete, 0);
    expect_eq("complete chunks with two frames lost", complete_chunks, 1);
    ctl(SCAN, 0); expect_eq("first incomplete chunk", first_incomplete, 0);

    // 4. Resend chunk 0 under a new epoch, as 8192-byte frames.
    ctl(CHUNK_RESET, {8'd1, 13'd0});
    expect_eq("complete chunks after reset of an incomplete chunk", complete_chunks, 1);
    for (f = 0; f < 128; f = f + 1) good(32'h11, f * 8192, 128, 1);
    settle;
    expect_eq("complete chunks after resending chunk 0", complete_chunks, 2);
    ctl(SCAN, 0); expect_eq("first incomplete chunk after resend", first_incomplete, 2);

    // 5. A frame that overshoots the chunk total poisons the count; a late
    //    frame from the old epoch is ignored after the reset.
    good(32'h11, 2100 * 1024, 32, 0);
    settle;
    expect_eq("overrun flag", overrun, 1);
    expect_eq("complete chunks after overrun", complete_chunks, 2);
    ctl(CHUNK_RESET, {8'd1, 13'd2});
    for (f = 2048; f < 2560; f = f + 1) begin
      if (f == 2200) good(32'h11, 2100 * 1024, 16, 0);    // stale epoch
      good(32'h11, f * 1024, 16, 1);
    end
    settle;
    expect_eq("stale frames", frames_stale, 1);
    expect_eq("complete", complete, 1);
    expect_eq("complete chunks", complete_chunks, 3);
    ctl(SCAN, 0); expect_eq("first incomplete when complete", first_incomplete, 32'hffffffff);

    // 6. A duplicate into a finished chunk changes nothing.
    good(32'h11, 0, 16, 1);
    settle;
    expect_eq("duplicate frames", frames_duplicate, 1);
    expect_eq("complete after duplicate", complete, 1);
    ctl(CHUNK_RESET, {8'd2, 13'd1});
    expect_eq("complete chunks after resetting a complete chunk", complete_chunks, 2);
    expect_eq("complete after resetting a complete chunk", complete, 0);
    check_image(32'h11, 5 * MIB / 2 / 64);

    // ---- session B: frames that straddle 4 KiB boundaries ----
    mem.delete(); beats_written = 0; beats_masked = 0; aw_count = 0;
    session = 32'h22; total_bytes = 262144; @(negedge clk);
    ctl(CLEAR, 0);
    expect_eq("counters cleared", frames_ok + frames_rejected + frames_duplicate + frames_stale, 0);
    expect_eq("overrun cleared", overrun, 0);
    good(32'h22, 0, 16, 0);
    for (off = 1024; off + 4096 <= 262144; off = off + 4096) good(32'h22, off, 64, 0);
    good(32'h22, off, (262144 - off) / 64, 0);
    settle;
    expect_eq("session B complete", complete, 1);
    expect_eq("session B bursts", aw_count, 1 + 63 * 2 + 1);
    check_image(32'h22, 262144 / 64);
    enable = 0; @(negedge clk);
    expect_eq("complete while disabled", complete, 0);
    good(32'h22, 0, 16, 0); settle;
    expect_eq("rejected while disabled", frames_rejected, 1);
    enable = 1;

    // ---- throughput: 100 Gb/s of 1024-byte frames is one frame per ~25
    //      cycles at 300 MHz; the writer must be clearly faster than that ----
    mem.delete(); session = 32'h33; total_bytes = MIB; bp = 0; src_gap = 0; @(negedge clk);
    ctl(CLEAR, 0);
    t0 = $time;
    for (f = 0; f < 1024; f = f + 1) good(32'h33, f * 1024, 16, 0);
    t1 = $time; settle;
    n = (t1 - t0) / 3.332 / 1024;
    $display("INFO: %0d cycles per 1024-byte frame", n);
    if (n > 21) fail("writer is too slow for line rate");
    expect_eq("throughput run complete", complete, 1);
    expect_eq("axi_error before injection", axi_error, 0);

    // ---- a DDR write error is sticky until the next CLEAR ----
    inject_bresp_error = 1;
    good(32'h33, 0, 16, 0); settle;
    expect_eq("axi_error", axi_error, 1);
    inject_bresp_error = 0;
    ctl(CLEAR, 0);
    expect_eq("axi_error after CLEAR", axi_error, 0);

    if (errors == 0) $display("tb_wave_bulk_ddr_writer PASS");
    else $display("tb_wave_bulk_ddr_writer FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #400_000_000; $display("tb_wave_bulk_ddr_writer FAIL (timeout)"); $finish; end
endmodule
