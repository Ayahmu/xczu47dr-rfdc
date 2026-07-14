`timescale 1ns / 1ps

module tb_udp_rvctrl_protocol;
  localparam [63:0] RVCTRL_MAGIC = 64'h00304C5254435652;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg         udp_tvalid = 1'b0;
  reg [63:0] udp_tdata = 64'd0;

  wire        instr_tvalid;
  wire [63:0] instr_tdata;
  wire        rvctrl_tvalid;
  wire [63:0] rvctrl_tdata;
  wire        rvctrl_tfirst;
  wire        rvctrl_tlast;
  wire [31:0] rvctrl_word_count;

  reg [31:0] rv_beats = 32'd0;
  reg [63:0] first_rv_data = 64'd0;
  reg [63:0] last_rv_data = 64'd0;
  reg        first_seen = 1'b0;
  reg        last_seen = 1'b0;
  reg        legacy_seen = 1'b0;
  reg [63:0] legacy_data = 64'd0;

  udp_waveform_ddr_writer dut (
    .clk(clk),
    .rst_n(rst_n),
    .udp_tvalid(udp_tvalid),
    .udp_tdata(udp_tdata),
    .instr_tvalid(instr_tvalid),
    .instr_tdata(instr_tdata),
    .trigger_pulse(),
    .rvctrl_tvalid(rvctrl_tvalid),
    .rvctrl_tdata(rvctrl_tdata),
    .rvctrl_tfirst(rvctrl_tfirst),
    .rvctrl_tlast(rvctrl_tlast),
    .rvctrl_word_count(rvctrl_word_count),
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
    .m_axi_bvalid(1'b1),
    .dbg_wave_pkt(),
    .dbg_instr_word(),
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

  always @(posedge clk) begin
    if (!rst_n) begin
      rv_beats <= 32'd0;
      first_rv_data <= 64'd0;
      last_rv_data <= 64'd0;
      first_seen <= 1'b0;
      last_seen <= 1'b0;
      legacy_seen <= 1'b0;
      legacy_data <= 64'd0;
    end else if (rvctrl_tvalid) begin
      rv_beats <= rv_beats + 32'd1;
      if (rvctrl_tfirst) begin
        first_seen <= 1'b1;
        first_rv_data <= rvctrl_tdata;
      end
      if (rvctrl_tlast) begin
        last_seen <= 1'b1;
        last_rv_data <= rvctrl_tdata;
      end
    end else if (instr_tvalid) begin
      legacy_seen <= 1'b1;
      legacy_data <= instr_tdata;
    end
  end

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

    send_word(RVCTRL_MAGIC);
    send_word(64'd3);
    send_word(64'h1234567800000001);
    send_word(64'h00000000A5A5A5A5);
    repeat (4) @(negedge clk);

    check_condition(instr_tvalid == 1'b0, "RVCTRL0 packet must not be forwarded as legacy instruction");
    check_condition(rv_beats == 32'd2, "RVCTRL0 payload should emit two 64-bit beats for three words");
    check_condition(first_seen == 1'b1, "RVCTRL0 first beat flag missing");
    check_condition(last_seen == 1'b1, "RVCTRL0 last beat flag missing");
    check_condition(first_rv_data == 64'h1234567800000001, "RVCTRL0 first payload beat mismatch");
    check_condition(last_rv_data == 64'h00000000A5A5A5A5, "RVCTRL0 final payload beat mismatch");
    check_condition(rvctrl_word_count == 32'd3, "RVCTRL0 word count should remain visible on payload beats");

    send_word(64'h0000100000000012);
    repeat (2) @(negedge clk);
    check_condition(legacy_seen == 1'b1, "legacy instruction path should still work after RVCTRL0 packet");
    check_condition(legacy_data == 64'h0000100000000012, "legacy instruction word mismatch after RVCTRL0 packet");

    $display("PASS: RVCTRL0 packets route to the PL RISC-V control path without breaking legacy UDP instructions");
    $finish;
  end
endmodule
