`timescale 1ns/1ps
// Classifier at the CMAC 512-bit RX output.
//
// Bulk waveform frames (IPv4/UDP to the board's MAC, IP and bulk port, with
// the "WBLK" tag right after the UDP header) leave on the bulk port; every
// other frame leaves on the control port, unchanged and in order.  The CMAC
// cannot be backpressured, so frames arrive back to back with no idle cycle.
module tb_wave_bulk_rx_classifier;
  reg clk=0; always #1.55 clk=~clk;   // 322 MHz
  reg rst=1;
  reg enable=1;
  localparam [47:0] MAC = 48'h02_00_10_6d_15_95;
  localparam [31:0] IP  = {8'd169, 8'd254, 8'd5, 8'd248};
  localparam [15:0] CTL_PORT = 16'd1234, BULK_PORT = 16'd1235;

  reg s_tvalid=0; reg [511:0] s_tdata=0; reg [63:0] s_tkeep=0; reg s_tlast=0; reg s_tuser=0;
  wire c_tvalid; wire [511:0] c_tdata; wire [63:0] c_tkeep; wire c_tlast; wire c_tuser;
  wire b_tvalid; wire [511:0] b_tdata; wire b_tlast; wire b_tuser;

  wave_bulk_rx_classifier dut (
    .clk(clk), .rst(rst), .enable(enable),
    .local_mac(MAC), .local_ip(IP), .bulk_port(BULK_PORT),
    .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
    .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
    .m_ctl_axis_tdata(c_tdata), .m_ctl_axis_tkeep(c_tkeep), .m_ctl_axis_tvalid(c_tvalid),
    .m_ctl_axis_tlast(c_tlast), .m_ctl_axis_tuser(c_tuser),
    .m_bulk_axis_tdata(b_tdata), .m_bulk_axis_tvalid(b_tvalid),
    .m_bulk_axis_tlast(b_tlast), .m_bulk_axis_tuser(b_tuser)
  );

  typedef struct { logic [511:0] data; logic [63:0] keep; logic last; logic user; } word_t;
  word_t exp_ctl[$], exp_bulk[$];
  integer errors = 0, ctl_words = 0, bulk_words = 0;

  // Frame bytes are built in a flat array, byte 0 first on the wire.
  reg [7:0] frame [0:9599];
  task automatic build(input integer tag, input integer nbytes, input [47:0] dmac, input [15:0] etype,
                       input [7:0] ver_ihl, input [15:0] frag, input [7:0] proto,
                       input [31:0] dip, input [15:0] dport, input [31:0] magic);
    integer i;
    begin
      for (i = 0; i < nbytes; i = i + 1) frame[i] = (tag * 29 + i * 7 + (i >> 8)) & 8'hff;
      for (i = 0; i < 6; i = i + 1) frame[i] = dmac[(5 - i) * 8 +: 8];
      frame[12] = etype[15:8]; frame[13] = etype[7:0];
      frame[14] = ver_ihl;
      frame[20] = frag[15:8]; frame[21] = frag[7:0];
      frame[23] = proto;
      for (i = 0; i < 4; i = i + 1) frame[30 + i] = dip[(3 - i) * 8 +: 8];
      frame[36] = dport[15:8]; frame[37] = dport[7:0];
      for (i = 0; i < 4; i = i + 1) frame[42 + i] = magic[(3 - i) * 8 +: 8];
    end
  endtask

  // Drive one frame with no idle cycles and record where it must come out.
  task automatic send(input integer nbytes, input bit to_bulk, input bit bad);
    integer w, b, nwords; word_t x;
    begin
      nwords = (nbytes + 63) / 64;
      for (w = 0; w < nwords; w = w + 1) begin
        @(negedge clk);
        s_tvalid = 1; s_tlast = (w == nwords - 1); s_tuser = s_tlast && bad;
        for (b = 0; b < 64; b = b + 1) begin
          s_tkeep[b] = (w * 64 + b) < nbytes;
          s_tdata[b*8 +: 8] = s_tkeep[b] ? frame[w * 64 + b] : 8'h00;
        end
        x.data = s_tdata; x.keep = s_tkeep; x.last = s_tlast; x.user = s_tuser;
        if (to_bulk) exp_bulk.push_back(x); else exp_ctl.push_back(x);
      end
    end
  endtask
  localparam [31:0] WBLK = "WBLK";
  task automatic bulk_frame(input integer tag, input integer nbytes, input bit bad);
    begin build(tag, nbytes, MAC, 16'h0800, 8'h45, 16'h4000, 8'd17, IP, BULK_PORT, WBLK); send(nbytes, enable, bad); end
  endtask

  always @(posedge clk) if (!rst) begin
    if (c_tvalid) begin
      ctl_words = ctl_words + 1;
      if (exp_ctl.size() == 0) begin errors = errors + 1; $display("ERROR: unexpected control word"); end
      else begin
        word_t x; x = exp_ctl.pop_front();
        if (c_tdata !== x.data || c_tkeep !== x.keep || c_tlast !== x.last || c_tuser !== x.user) begin
          errors = errors + 1; $display("ERROR: control word %0d differs", ctl_words);
        end
      end
    end
    if (b_tvalid) begin
      bulk_words = bulk_words + 1;
      if (exp_bulk.size() == 0) begin errors = errors + 1; $display("ERROR: unexpected bulk word"); end
      else begin
        word_t x; x = exp_bulk.pop_front();
        if (b_tdata !== x.data || b_tlast !== x.last || b_tuser !== x.user) begin
          errors = errors + 1; $display("ERROR: bulk word %0d differs", bulk_words);
        end
      end
    end
  end

  initial begin : stim
    integer i;
    repeat (20) @(posedge clk); rst <= 0; repeat (10) @(posedge clk);

    // 1. Every kind of frame, back to back.
    bulk_frame(1, 64 + 1024, 0);                                                                  // bulk
    build(2, 1072, MAC, 16'h0800, 8'h45, 16'h4000, 8'd17, IP, CTL_PORT, WBLK); send(1072, 0, 0);   // control port
    build(3, 60, 48'hffffffffffff, 16'h0806, 8'h00, 16'h0, 8'd0, IP, 16'd0, 32'd0); send(60, 0, 0); // ARP
    bulk_frame(4, 64 + 8192, 0);                                                                  // jumbo bulk
    build(5, 1088, MAC, 16'h0800, 8'h45, 16'h4000, 8'd17, {8'd169,8'd254,8'd5,8'd249}, BULK_PORT, WBLK); send(1088, 0, 0); // other IP
    build(6, 1088, MAC, 16'h0800, 8'h45, 16'h4000, 8'd17, IP, BULK_PORT, "WBLX"); send(1088, 0, 0); // wrong tag
    build(7, 1088, MAC, 16'h0800, 8'h45, 16'h2000, 8'd17, IP, BULK_PORT, WBLK); send(1088, 0, 0);  // IP fragment (MF)
    build(8, 1088, MAC, 16'h0800, 8'h45, 16'h0010, 8'd17, IP, BULK_PORT, WBLK); send(1088, 0, 0);  // IP fragment (offset)
    build(9, 1088, MAC, 16'h0800, 8'h46, 16'h4000, 8'd17, IP, BULK_PORT, WBLK); send(1088, 0, 0);  // IP options
    build(10, 1088, MAC, 16'h0800, 8'h45, 16'h4000, 8'd6, IP, BULK_PORT, WBLK); send(1088, 0, 0);  // TCP
    build(11, 1088, 48'h020000000001, 16'h0800, 8'h45, 16'h4000, 8'd17, IP, BULK_PORT, WBLK); send(1088, 0, 0); // other MAC
    build(12, 1088, MAC, 16'h86dd, 8'h45, 16'h4000, 8'd17, IP, BULK_PORT, WBLK); send(1088, 0, 0);  // not IPv4
    bulk_frame(13, 64 + 64, 1);                                                                   // bad FCS keeps its mark
    bulk_frame(14, 64, 0);                                                                        // header only

    // 2. A long alternating run with no gaps: the decision of one frame must
    //    not leak into the next.
    for (i = 0; i < 40; i = i + 1) begin
      if (i % 3 == 0) begin build(100 + i, 200 + i * 31, MAC, 16'h0800, 8'h45, 16'h4000, 8'd17, IP, CTL_PORT, WBLK); send(200 + i * 31, 0, 0); end
      else bulk_frame(100 + i, 64 + 64 * (1 + (i % 16)), 0);
    end
    @(negedge clk); s_tvalid = 0; s_tlast = 0; s_tuser = 0;
    repeat (10) @(posedge clk);

    // 3. Disabled: bulk-looking frames go to the control path.
    @(negedge clk); enable = 0; repeat (4) @(posedge clk);
    bulk_frame(200, 64 + 1024, 0);
    @(negedge clk); s_tvalid = 0; s_tlast = 0;
    repeat (20) @(posedge clk);

    if (exp_ctl.size() != 0 || exp_bulk.size() != 0) begin
      errors = errors + 1;
      $display("ERROR: %0d control and %0d bulk words never came out", exp_ctl.size(), exp_bulk.size());
    end
    if (bulk_words == 0 || ctl_words == 0) begin errors = errors + 1; $display("ERROR: a port stayed silent"); end
    if (errors == 0) $display("tb_wave_bulk_rx_classifier PASS (%0d bulk words, %0d control words)", bulk_words, ctl_words);
    else $display("tb_wave_bulk_rx_classifier FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #2_000_000; $display("tb_wave_bulk_rx_classifier FAIL (timeout)"); $finish; end
endmodule
