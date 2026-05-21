`timescale 1ns / 1ps

module tb_udp_protocol;
  localparam [63:0] MAGIC = 64'h5741564544445230;
  localparam [63:0] DDR_X_ADDR = 64'h0000000500000000;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg         udp_tvalid = 1'b0;
  reg [63:0] udp_tdata = 64'd0;

  wire        instr64_tvalid;
  wire [63:0] instr64_tdata;
  wire [63:0] awaddr;
  wire [127:0] wdata;
  wire        awvalid;
  wire        wvalid;
  wire [2:0]  dbg_state;
  wire [31:0] dbg_write_count;
  wire [127:0] dbg_last_wdata;

  reg         instr128_tready = 1'b1;
  wire [127:0] instr128_tdata;
  wire        instr128_tvalid;
  reg         captured_instr_valid = 1'b0;
  reg [127:0] captured_instr_tdata = 128'd0;

  always @(posedge clk) begin
    if (!rst_n) begin
      captured_instr_valid <= 1'b0;
      captured_instr_tdata <= 128'd0;
    end else if (instr128_tvalid) begin
      captured_instr_valid <= 1'b1;
      captured_instr_tdata <= instr128_tdata;
    end
  end

  udp_waveform_ddr_writer dut_writer (
    .clk(clk),
    .rst_n(rst_n),
    .udp_tvalid(udp_tvalid),
    .udp_tdata(udp_tdata),
    .instr_tvalid(instr64_tvalid),
    .instr_tdata(instr64_tdata),
    .m_axi_awaddr(awaddr),
    .m_axi_awburst(),
    .m_axi_awcache(),
    .m_axi_awlen(),
    .m_axi_awlock(),
    .m_axi_awprot(),
    .m_axi_awqos(),
    .m_axi_awready(1'b1),
    .m_axi_awsize(),
    .m_axi_awvalid(awvalid),
    .m_axi_wdata(wdata),
    .m_axi_wlast(),
    .m_axi_wready(1'b1),
    .m_axi_wstrb(),
    .m_axi_wvalid(wvalid),
    .m_axi_bready(),
    .m_axi_bresp(2'b00),
    .m_axi_bvalid(awvalid && wvalid),
    .dbg_wave_pkt(),
    .dbg_instr_word(),
    .dbg_state(dbg_state),
    .dbg_write_count(dbg_write_count),
    .dbg_bresp_count(),
    .dbg_drop_count_o(),
    .dbg_fifo_count_o(),
    .dbg_resync_count(),
    .dbg_last_bresp(),
    .dbg_last_addr(),
    .dbg_last_wdata(dbg_last_wdata)
  );

  udp64_to_axis128_instr dut_instr (
    .clk(clk),
    .rst_n(rst_n),
    .udp_tvalid(instr64_tvalid),
    .udp_tdata(instr64_tdata),
    .m_axis_tdata(instr128_tdata),
    .m_axis_tvalid(instr128_tvalid),
    .m_axis_tready(instr128_tready)
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

  task check_condition(input condition, input string message);
    begin
      if (!condition) begin
        $display("FAIL: %s", message);
        $finish;
      end
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    send_word(MAGIC);
    send_word(DDR_X_ADDR);
    send_word(64'h0003000200010000);
    send_word(64'h0007000600050004);
    repeat (4) @(negedge clk);

    check_condition(dbg_write_count == 32'd1, "writer did not accept one waveform write");
    check_condition(dbg_last_wdata == 128'h00070006000500040003000200010000, "writer 128-bit lane order mismatch");

    send_word(64'h0000100000000012);
    send_word(DDR_X_ADDR);
    repeat (2) @(negedge clk);

    check_condition(captured_instr_valid == 1'b1, "instruction adapter did not emit one 128-bit instruction");
    check_condition(captured_instr_tdata == 128'h00000005000000000000100000000012, "instruction packing mismatch");
    check_condition(captured_instr_tdata[3:0] == 4'h2, "PLAY opcode decode mismatch");
    check_condition(captured_instr_tdata[7:4] == 4'h1, "PLAY channel decode mismatch");
    check_condition(captured_instr_tdata[63:32] == 32'd4096, "PLAY length decode mismatch");
    check_condition(captured_instr_tdata[127:64] == DDR_X_ADDR, "PLAY address decode mismatch");

    $display("PASS: UDP waveform writer and instruction adapter match golden protocol");
    $finish;
  end
endmodule
