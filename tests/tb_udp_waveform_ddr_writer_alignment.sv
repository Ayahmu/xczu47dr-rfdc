`timescale 1ns / 1ps

module tb_udp_waveform_ddr_writer_alignment;
  localparam [63:0] MAGIC = 64'h5741564544445230;
  localparam [63:0] BULK_MAGIC = 64'h5741564553545230;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg         udp_tvalid = 1'b0;
  reg [63:0] udp_tdata = 64'd0;

  wire         instr_tvalid;
  wire [63:0] instr_tdata;
  wire [63:0] m_axi_awaddr;
  wire        m_axi_awvalid;
  wire [255:0] m_axi_wdata;
  wire        m_axi_wvalid;
  wire [31:0] dbg_write_count;
  wire [31:0] dbg_drop_count;
  wire [31:0] dbg_align_error_count;

  udp_waveform_ddr_writer dut (
    .clk(clk),
    .rst_n(rst_n),
    .udp_tvalid(udp_tvalid),
    .udp_tdata(udp_tdata),
    .instr_tvalid(instr_tvalid),
    .instr_tdata(instr_tdata),
    .trigger_pulse(),
    .m_axi_awaddr(m_axi_awaddr),
    .m_axi_awburst(),
    .m_axi_awcache(),
    .m_axi_awlen(),
    .m_axi_awlock(),
    .m_axi_awprot(),
    .m_axi_awqos(),
    .m_axi_awready(1'b1),
    .m_axi_awsize(),
    .m_axi_awvalid(m_axi_awvalid),
    .m_axi_wdata(m_axi_wdata),
    .m_axi_wlast(),
    .m_axi_wready(1'b1),
    .m_axi_wstrb(),
    .m_axi_wvalid(m_axi_wvalid),
    .m_axi_bready(),
    .m_axi_bresp(2'b00),
    .m_axi_bvalid(1'b1),
    .dbg_wave_pkt(),
    .dbg_instr_word(),
    .dbg_state(),
    .dbg_write_count(dbg_write_count),
    .dbg_bresp_count(),
    .dbg_drop_count_o(dbg_drop_count),
    .dbg_align_error_count_o(dbg_align_error_count),
    .dbg_fifo_count_o(),
    .dbg_resync_count(),
    .dbg_last_bresp(),
    .dbg_last_addr(),
    .dbg_last_wdata()
  );

  task send_word(input [63:0] word);
    begin
      @(negedge clk);
      udp_tdata = word;
      udp_tvalid = 1'b1;
      @(negedge clk);
      udp_tvalid = 1'b0;
      udp_tdata = 64'd0;
    end
  endtask

  task send_wave_packet(input [63:0] addr);
    begin
      send_word(MAGIC);
      send_word(addr);
      send_word(64'h0000000000000001);
      send_word(64'h0000000000000002);
      send_word(64'h0000000000000003);
      send_word(64'h0000000000000004);
    end
  endtask

  task check_condition(input condition, input string message);
    begin
      if(!condition) begin
        $display("FAIL: %s", message);
        $finish;
      end
    end
  endtask

  initial begin
    repeat(4) @(negedge clk);
    rst_n = 1'b1;
    repeat(4) @(negedge clk);

    send_wave_packet(64'h0000000000000008);
    repeat(4) @(negedge clk);
    check_condition(dbg_write_count == 0, "unaligned UDP DDR write should not enqueue");
    check_condition(dbg_drop_count == 1, "unaligned UDP DDR write should increment drop count");
    check_condition(dbg_align_error_count == 1, "unaligned UDP DDR write should increment align error count");

    send_wave_packet(64'h0000000000001000);
    repeat(8) @(negedge clk);
    check_condition(dbg_write_count == 1, "aligned UDP DDR write should enqueue once");
    check_condition(m_axi_awaddr == 64'h0000000000001000, "aligned UDP DDR write address should reach AXI");
    check_condition(m_axi_wdata == 256'h0000000000000004000000000000000300000000000000020000000000000001,
                    "UDP data words should pack into one 256-bit AXI beat");

    send_word(BULK_MAGIC);
    send_word(64'h0000000000002000);
    send_word(64'd8);
    send_word(64'h0000000000000011);
    send_word(64'h0000000000000012);
    send_word(64'h0000000000000013);
    send_word(64'h0000000000000014);
    send_word(64'h0000000000000021);
    send_word(64'h0000000000000022);
    send_word(64'h0000000000000023);
    send_word(64'h0000000000000024);
    repeat(16) @(negedge clk);
    check_condition(dbg_write_count == 3, "bulk UDP write should enqueue two consecutive AXI beats");
    check_condition(m_axi_awaddr == 64'h0000000000002020, "bulk UDP write should increment the AXI address by 32 bytes");
    check_condition(m_axi_wdata == 256'h0000000000000024000000000000002300000000000000220000000000000021,
                    "bulk UDP second beat data order mismatch");

    $display("PASS: UDP DDR writer preserves legacy writes and bulk sequential writes");
    $finish;
  end
endmodule
