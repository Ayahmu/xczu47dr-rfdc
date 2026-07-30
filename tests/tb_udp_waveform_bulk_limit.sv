`timescale 1ns / 1ps

module tb_udp_waveform_bulk_limit;
  localparam [63:0] BULK_MAGIC = 64'h5741564553545230;
  localparam [63:0] INSTR_MAGIC = 64'h57415645494E5330;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg        udp_tvalid = 1'b0;
  reg [63:0] udp_tdata = 64'd0;
  reg        udp_tlast = 1'b0;

  wire        instr_tvalid;
  wire [63:0] instr_tdata;
  wire [31:0] write_count;
  wire [31:0] drop_count;
  integer     instr_count = 0;
  reg [63:0]  first_instr = 64'd0;

  always @(posedge clk) begin
    if (instr_tvalid) begin
      if (instr_count == 0)
        first_instr <= instr_tdata;
      instr_count <= instr_count + 1;
    end
  end

  udp_waveform_ddr_writer dut (
    .clk(clk),
    .rst_n(rst_n),
    .udp_tvalid(udp_tvalid),
    .udp_tdata(udp_tdata),
    .udp_tlast(udp_tlast),
    .instr_tvalid(instr_tvalid),
    .instr_tdata(instr_tdata),
    .trigger_pulse(),
    .rvctrl_tvalid(),
    .rvctrl_tdata(),
    .rvctrl_tfirst(),
    .rvctrl_tlast(),
    .rvctrl_word_count(),
    .rvctrl_protocol(),
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
    .m_axi_bready(),
    .m_axi_bresp(2'b00),
    .m_axi_bvalid(1'b1),
    .dbg_wave_pkt(),
    .dbg_instr_word(),
    .dbg_state(),
    .dbg_write_count(write_count),
    .dbg_bresp_count(),
    .dbg_drop_count_o(drop_count),
    .dbg_align_error_count_o(),
    .dbg_fifo_count_o(),
    .dbg_resync_count(),
    .dbg_last_bresp(),
    .dbg_last_addr(),
    .dbg_last_wdata()
  );

  task send_word(input [63:0] word, input last);
    begin
      @(negedge clk);
      udp_tdata = word;
      udp_tlast = last;
      udp_tvalid = 1'b1;
      @(negedge clk);
      udp_tvalid = 1'b0;
      udp_tlast = 1'b0;
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
    repeat (4) @(negedge clk);

    // Five beats fit in a standard-MTU UDP packet but exceed the current
    // writer FIFO-safe limit. The complete UDP packet must be discarded.
    send_word(BULK_MAGIC, 1'b0);
    send_word(64'h0000000000003000, 1'b0);
    send_word(64'd40, 1'b0);
    for (integer word = 0; word < 40; word = word + 1)
      send_word(word + 64'h100, word == 39);

    // A following packet must still be decoded as an instruction packet.
    send_word(INSTR_MAGIC, 1'b0);
    send_word(64'd2, 1'b0);
    send_word(64'h0000000000000012, 1'b0);
    send_word(64'd0, 1'b1);
    repeat (8) @(negedge clk);

    check_condition(write_count == 32'd0, "oversized bulk packet must not write DDR");
    check_condition(drop_count == 32'd1, "oversized bulk packet must increment drop count once");
    check_condition(instr_count == 2, "oversized bulk payload must not pollute the next instruction packet");
    check_condition(first_instr == 64'h0000000000000012, "next instruction packet was not preserved");

    $display("PASS: UDP writer drops oversized bulk packets at the UDP boundary");
    $finish;
  end
endmodule
