`timescale 1ns / 1ps

// Verify that an XCZU47DR only learns ARP senders that it can legitimately
// use as an L2 next hop: the board subnet or its configured gateway.
module tb_arp_local_subnet_filter;
  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  reg s_eth_hdr_valid = 1'b0;
  wire s_eth_hdr_ready;
  reg [47:0] s_eth_dest_mac = 48'd0;
  reg [47:0] s_eth_src_mac = 48'd0;
  reg [15:0] s_eth_type = 16'h0806;
  reg [63:0] s_eth_payload_axis_tdata = 64'd0;
  reg [7:0] s_eth_payload_axis_tkeep = 8'd0;
  reg s_eth_payload_axis_tvalid = 1'b0;
  wire s_eth_payload_axis_tready;
  reg s_eth_payload_axis_tlast = 1'b0;
  reg s_eth_payload_axis_tuser = 1'b0;

  wire m_eth_hdr_valid;
  reg m_eth_hdr_ready = 1'b1;
  wire [47:0] m_eth_dest_mac;
  wire [47:0] m_eth_src_mac;
  wire [15:0] m_eth_type;
  wire [63:0] m_eth_payload_axis_tdata;
  wire [7:0] m_eth_payload_axis_tkeep;
  wire m_eth_payload_axis_tvalid;
  reg m_eth_payload_axis_tready = 1'b1;
  wire m_eth_payload_axis_tlast;
  wire m_eth_payload_axis_tuser;

  reg arp_request_valid = 1'b0;
  wire arp_request_ready;
  reg [31:0] arp_request_ip = 32'd0;
  wire arp_response_valid;
  reg arp_response_ready = 1'b1;
  wire arp_response_error;
  wire [47:0] arp_response_mac;

  localparam [31:0] LOCAL_IP = 32'hA9FE_D6BD;  // 169.254.214.189
  localparam [31:0] SUBNET_MASK = 32'hFFFF_0000;
  integer cache_writes = 0;

  arp #(
      .DATA_WIDTH(64),
      .KEEP_ENABLE(1),
      .KEEP_WIDTH(8),
      .CACHE_ADDR_WIDTH(4),
      .REQUEST_RETRY_COUNT(2),
      .REQUEST_RETRY_INTERVAL(16),
      .REQUEST_TIMEOUT(32)
  ) dut (
      .clk(clk), .rst(rst),
      .s_eth_hdr_valid(s_eth_hdr_valid), .s_eth_hdr_ready(s_eth_hdr_ready),
      .s_eth_dest_mac(s_eth_dest_mac), .s_eth_src_mac(s_eth_src_mac),
      .s_eth_type(s_eth_type), .s_eth_payload_axis_tdata(s_eth_payload_axis_tdata),
      .s_eth_payload_axis_tkeep(s_eth_payload_axis_tkeep),
      .s_eth_payload_axis_tvalid(s_eth_payload_axis_tvalid),
      .s_eth_payload_axis_tready(s_eth_payload_axis_tready),
      .s_eth_payload_axis_tlast(s_eth_payload_axis_tlast),
      .s_eth_payload_axis_tuser(s_eth_payload_axis_tuser),
      .m_eth_hdr_valid(m_eth_hdr_valid), .m_eth_hdr_ready(m_eth_hdr_ready),
      .m_eth_dest_mac(m_eth_dest_mac), .m_eth_src_mac(m_eth_src_mac),
      .m_eth_type(m_eth_type), .m_eth_payload_axis_tdata(m_eth_payload_axis_tdata),
      .m_eth_payload_axis_tkeep(m_eth_payload_axis_tkeep),
      .m_eth_payload_axis_tvalid(m_eth_payload_axis_tvalid),
      .m_eth_payload_axis_tready(m_eth_payload_axis_tready),
      .m_eth_payload_axis_tlast(m_eth_payload_axis_tlast),
      .m_eth_payload_axis_tuser(m_eth_payload_axis_tuser),
      .arp_request_valid(arp_request_valid), .arp_request_ready(arp_request_ready),
      .arp_request_ip(arp_request_ip), .arp_response_valid(arp_response_valid),
      .arp_response_ready(arp_response_ready), .arp_response_error(arp_response_error),
      .arp_response_mac(arp_response_mac),
      .local_mac(48'h02_00_00_2C_D6_91), .local_ip(LOCAL_IP),
      .gateway_ip(LOCAL_IP), .subnet_mask(SUBNET_MASK), .clear_cache(1'b0)
  );

  always @(posedge clk) begin
    if (dut.cache_write_request_valid_reg)
      cache_writes <= cache_writes + 1;
  end

  task check_condition(input condition, input string message);
    begin
      if (!condition) begin
        $display("FAIL: %s", message);
        $finish;
      end
    end
  endtask

  task inject_arp_sender(input [31:0] sender_ip, input [47:0] sender_mac);
    begin
      // Bypass the byte-level ARP parser.  The test targets the ARP policy
      // boundary immediately before the cache write request.
      force dut.incoming_frame_valid = 1'b1;
      force dut.incoming_eth_type = 16'h0806;
      force dut.incoming_arp_htype = 16'h0001;
      force dut.incoming_arp_ptype = 16'h0800;
      force dut.incoming_arp_oper = 16'h0001;
      force dut.incoming_arp_spa = sender_ip;
      force dut.incoming_arp_sha = sender_mac;
      force dut.incoming_arp_tpa = LOCAL_IP;
      force dut.incoming_eth_src_mac = sender_mac;
      force dut.outgoing_frame_ready = 1'b1;
      @(negedge clk);
      release dut.incoming_frame_valid;
      release dut.incoming_eth_type;
      release dut.incoming_arp_htype;
      release dut.incoming_arp_ptype;
      release dut.incoming_arp_oper;
      release dut.incoming_arp_spa;
      release dut.incoming_arp_sha;
      release dut.incoming_arp_tpa;
      release dut.incoming_eth_src_mac;
      release dut.outgoing_frame_ready;
      repeat (2) @(negedge clk);
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst = 1'b0;
    repeat (24) @(negedge clk);

    // Corporate-VLAN ARP broadcasts must not evict the link-local host MAC.
    inject_arp_sender(32'h0A56_8101, 48'h10_20_30_40_50_60);
    check_condition(cache_writes == 0,
                    "off-subnet ARP sender must not be learned");

    inject_arp_sender(32'hA9FE_FA0B, 48'h00_1B_21_C7_B2_F0);
    check_condition(cache_writes == 1,
                    "same-subnet host ARP sender must be learned");

    $display("PASS: ARP cache learns only local-subnet senders");
    $finish;
  end
endmodule
