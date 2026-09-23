`timescale 1ns/1ps

// Unit test for udp_rvctrl_framer: verifies RFCTRL2 packets are re-framed
// into the rvctrl_* tfirst/tlast/word_count/protocol contract and that
// WAVECTR0 packets are dropped.
module tb_udp_rvctrl_framer;
  reg        clk = 0;
  reg        rst_n = 0;
  reg        udp_tvalid = 0;
  reg [63:0] udp_tdata = 0;
  reg        udp_tlast = 0;
  wire       rvctrl_tvalid;
  wire [63:0] rvctrl_tdata;
  wire       rvctrl_tfirst;
  wire       rvctrl_tlast;
  wire [31:0] rvctrl_word_count;
  wire [1:0]  rvctrl_protocol;

  udp_rvctrl_framer dut (
      .clk(clk), .rst_n(rst_n),
      .udp_tvalid(udp_tvalid), .udp_tdata(udp_tdata), .udp_tlast(udp_tlast),
      .rvctrl_tvalid(rvctrl_tvalid), .rvctrl_tdata(rvctrl_tdata),
      .rvctrl_tfirst(rvctrl_tfirst), .rvctrl_tlast(rvctrl_tlast),
      .rvctrl_word_count(rvctrl_word_count), .rvctrl_protocol(rvctrl_protocol)
  );

  localparam [63:0] RFCTRL2_MAGIC = 64'h00324C5254434652;
  localparam [63:0] WAVE_MAGIC    = 64'h5741564543545230;

  // 5 ns clock (200 MHz class; timing-agnostic for this behavioral tb).
  always #5 clk = ~clk;

  // Feed one packet word-by-word (assert tvalid per word; tlast on last).
  task send_word(input [63:0] w, input last);
    begin
      @(negedge clk);
      udp_tvalid <= 1; udp_tdata <= w; udp_tlast <= last;
      @(negedge clk);
      udp_tvalid <= 0; udp_tlast <= 0;
    end
  endtask

  integer errors = 0;
  integer i;

  // Capture emitted words from the framer.
  reg [63:0] emitted [0:15];
  reg        emitted_first [0:15];
  reg        emitted_last [0:15];
  reg [31:0] emitted_wc;
  reg [1:0]  emitted_proto;
  integer    nwords = 0;

  always @(posedge clk) begin
    if (rvctrl_tvalid) begin
      emitted[nwords] <= rvctrl_tdata;
      emitted_first[nwords] <= rvctrl_tfirst;
      emitted_last[nwords] <= rvctrl_tlast;
      emitted_wc <= rvctrl_word_count;
      emitted_proto <= rvctrl_protocol;
      nwords <= nwords + 1;
    end
  end

  initial begin
    // Drive clock + reset.
    rst_n = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // ---- Test 1: RFCTRL2 HELLO (opcode 1, zero payload) ----
    // wire: magic / hdr0 / hdr1 ; no payload. hdr0 = opcode<<32 | version(3)
    // hdr1 = 0<<32 | seq. word_count = 4 + ceil(0/4) = 4.
    send_word(RFCTRL2_MAGIC, 0);
    send_word({32'h00000001, 16'h0000, 16'h0003}, 0); // opcode HELLO, ver 3
    send_word({32'h00000000, 32'd5}, 1);              // payload 0, seq 5
    @(negedge clk); @(negedge clk);

    if (nwords != 2) begin $display("FAIL t1: expected 2 emitted words (hdr0+hdr1), got %0d", nwords); errors=errors+1; end
    if (emitted_first[0] !== 1'b1) begin $display("FAIL t1: word0 tfirst != 1"); errors=errors+1; end
    if (emitted[0] !== {32'h00000001, 16'h0000, 16'h0003}) begin $display("FAIL t1: hdr0 mismatch 0x%h", emitted[0]); errors=errors+1; end
    if (emitted_last[1] !== 1'b1) begin $display("FAIL t1: word1 tlast != 1"); errors=errors+1; end
    if (emitted_wc !== 32'd4) begin $display("FAIL t1: word_count=%0d want 4", emitted_wc); errors=errors+1; end
    if (emitted_proto !== 2'd2) begin $display("FAIL t1: protocol=%0d want 2", emitted_proto); errors=errors+1; end

    // ---- Test 2: RFCTRL2 NETWORK_GET with 8-byte payload ----
    nwords = 0;
    // payload 8 bytes => word_count = 4 + ceil(8/4)= 4+2 = 6
    send_word(RFCTRL2_MAGIC, 0);
    send_word({32'h0000000C, 16'h0000, 16'h0003}, 0); // opcode NETWORK_GET
    send_word({32'd8, 32'd7}, 0);                     // 8 bytes payload, seq 7
    send_word(64'hDEADBEEFCAFEBABE, 1);               // payload word
    @(negedge clk); @(negedge clk);

    if (nwords != 3) begin $display("FAIL t2: expected 3 emitted words, got %0d", nwords); errors=errors+1; end
    if (emitted_first[0] !== 1'b1) begin $display("FAIL t2: tfirst not on word0"); errors=errors+1; end
    if (emitted_last[2] !== 1'b1) begin $display("FAIL t2: tlast not on last word"); errors=errors+1; end
    if (emitted[2] !== 64'hDEADBEEFCAFEBABE) begin $display("FAIL t2: payload mismatch"); errors=errors+1; end
    if (emitted_wc !== 32'd6) begin $display("FAIL t2: word_count=%0d want 6", emitted_wc); errors=errors+1; end

    // ---- Test 3: WAVECTR0 magic must be dropped (no emission) ----
    nwords = 0;
    send_word(WAVE_MAGIC, 0);
    send_word(64'h1234567890abcdef, 1);
    @(negedge clk); @(negedge clk);
    if (nwords != 0) begin $display("FAIL t3: WAVECTR0 leaked %0d words", nwords); errors=errors+1; end

    if (errors == 0) $display("PASS: udp_rvctrl_framer framing contract");
    else $display("FAIL: %0d error(s)", errors);
    $finish;
  end
endmodule
