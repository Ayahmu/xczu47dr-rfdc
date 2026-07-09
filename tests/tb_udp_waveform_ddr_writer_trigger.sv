`timescale 1ns / 1ps

module tb_udp_waveform_ddr_writer_trigger;
  localparam [63:0] TRIGGER_WORD = 64'h3152454747495254;
  localparam [63:0] LEGACY_TRIGGER_HEADER = 64'h0000000200000002;
  localparam [63:0] LEGACY_TRIGGER_GO = 64'h0000000000004F47;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg         udp_tvalid = 1'b0;
  reg [63:0] udp_tdata = 64'd0;

  wire instr_tvalid;
  wire [63:0] instr_tdata;
  wire trigger_pulse;
  wire dbg_instr_word;

  udp_waveform_ddr_writer dut (
    .clk(clk),
    .rst_n(rst_n),
    .udp_tvalid(udp_tvalid),
    .udp_tdata(udp_tdata),
    .instr_tvalid(instr_tvalid),
    .instr_tdata(instr_tdata),
    .trigger_pulse(trigger_pulse),
    .m_axi_awaddr(),
    .m_axi_awburst(),
    .m_axi_awcache(),
    .m_axi_awlen(),
    .m_axi_awlock(),
    .m_axi_awprot(),
    .m_axi_awqos(),
    .m_axi_awready(1'b1),
    .m_axi_awsize(),
    .m_axi_awvalid(),
    .m_axi_wdata(),
    .m_axi_wlast(),
    .m_axi_wready(1'b1),
    .m_axi_wstrb(),
    .m_axi_wvalid(),
    .m_axi_bready(),
    .m_axi_bresp(2'b00),
    .m_axi_bvalid(1'b0),
    .dbg_wave_pkt(),
    .dbg_instr_word(dbg_instr_word),
    .dbg_state(),
    .dbg_write_count(),
    .dbg_bresp_count(),
    .dbg_drop_count_o(),
    .dbg_align_error_count_o(),
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

    send_word(TRIGGER_WORD);
    @(posedge clk);
    check_condition(trigger_pulse == 1'b1, "TRIGGER1 should create one trigger pulse");
    check_condition(instr_tvalid == 1'b0, "TRIGGER1 must not be forwarded as an instruction");
    check_condition(dbg_instr_word == 1'b0, "TRIGGER1 must not assert dbg_instr_word");
    repeat(2) @(posedge clk);
    check_condition(trigger_pulse == 1'b0, "TRIGGER1 pulse should be one clock wide");

    send_word(LEGACY_TRIGGER_HEADER);
    @(posedge clk);
    check_condition(trigger_pulse == 1'b1, "legacy type=2 header should create one trigger pulse");
    check_condition(instr_tvalid == 1'b0, "legacy type=2 header must not be forwarded as an instruction");

    send_word(LEGACY_TRIGGER_GO);
    @(posedge clk);
    check_condition(trigger_pulse == 1'b0, "legacy GO payload should be swallowed");
    check_condition(instr_tvalid == 1'b0, "legacy GO payload must not be forwarded as an instruction");

    send_word(64'h0000000000000012);
    @(posedge clk);
    check_condition(instr_tvalid == 1'b1, "normal instruction word should still pass through");
    check_condition(instr_tdata == 64'h0000000000000012, "normal instruction word data should be preserved");

    $display("PASS: UDP trigger words are decoded without polluting instruction stream");
    $finish;
  end
endmodule
