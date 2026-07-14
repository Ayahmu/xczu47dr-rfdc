`timescale 1ns / 1ps

module tb_pl_riscv_control_v1;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg         rvctrl_tvalid = 1'b0;
  reg [63:0]  rvctrl_tdata = 64'd0;
  reg         rvctrl_tfirst = 1'b0;
  reg         rvctrl_tlast = 1'b0;
  reg [31:0]  rvctrl_word_count = 32'd0;

  wire [127:0] m_instr_tdata;
  wire         m_instr_tvalid;
  reg          m_instr_tready = 1'b1;
  wire         trigger_pulse;
  wire [31:0] dbg_status;
  wire [31:0] dbg_last_seq;
  wire [31:0] dbg_play_count;
  wire [31:0] dbg_trigger_count;

  reg [127:0] instrs [0:8];
  reg [3:0] instr_count = 4'd0;
  reg trigger_seen = 1'b0;

  pl_riscv_control_v1 dut (
    .clk(clk),
    .rst_n(rst_n),
    .rvctrl_tvalid(rvctrl_tvalid),
    .rvctrl_tdata(rvctrl_tdata),
    .rvctrl_tfirst(rvctrl_tfirst),
    .rvctrl_tlast(rvctrl_tlast),
    .rvctrl_word_count(rvctrl_word_count),
    .m_instr_tdata(m_instr_tdata),
    .m_instr_tvalid(m_instr_tvalid),
    .m_instr_tready(m_instr_tready),
    .trigger_pulse(trigger_pulse),
    .dbg_status(dbg_status),
    .dbg_last_seq(dbg_last_seq),
    .dbg_last_cmd(),
    .dbg_ping_count(),
    .dbg_play_count(dbg_play_count),
    .dbg_trigger_count(dbg_trigger_count),
    .dbg_mmio_write_count(),
    .dbg_error_count(),
    .dbg_scratch(),
    .dbg_state()
  );

  always @(posedge clk) begin
    if (!rst_n) begin
      instr_count <= 4'd0;
      trigger_seen <= 1'b0;
    end else begin
      if (m_instr_tvalid && m_instr_tready && instr_count < 4'd9) begin
        instrs[instr_count] <= m_instr_tdata;
        instr_count <= instr_count + 4'd1;
      end
      if (trigger_pulse) begin
        trigger_seen <= 1'b1;
      end
    end
  end

  task send_rv_beat(
    input [63:0] word,
    input first,
    input last,
    input [31:0] count
  );
    begin
      @(negedge clk);
      rvctrl_tdata = word;
      rvctrl_tfirst = first;
      rvctrl_tlast = last;
      rvctrl_word_count = count;
      rvctrl_tvalid = 1'b1;
      @(negedge clk);
      rvctrl_tvalid = 1'b0;
      rvctrl_tfirst = 1'b0;
      rvctrl_tlast = 1'b0;
      rvctrl_word_count = 32'd0;
      rvctrl_tdata = 64'd0;
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

    // PLAY_INTERLEAVED, seq=0x55, bytes_per_channel=4096, auto_start=1.
    send_rv_beat(64'h0000005500000002, 1'b1, 1'b0, 32'd4);
    send_rv_beat(64'h0000000100001000, 1'b0, 1'b1, 32'd4);
    repeat (32) @(negedge clk);

    check_condition(dbg_play_count == 32'd1, "PLAY_INTERLEAVED command was not counted");
    check_condition(dbg_last_seq == 32'h55, "PLAY_INTERLEAVED seq mismatch");
    check_condition(instr_count == 4'd9, "PLAY_INTERLEAVED should emit 8 PLAY instructions plus END");
    check_condition(instrs[0] == 128'h00000000000000000000100000000412, "CH1 PLAY instruction mismatch");
    check_condition(instrs[7] == 128'h00000000000000000000100000000482, "CH8 PLAY instruction mismatch");
    check_condition(instrs[8] == 128'h000000000000000000000000000000F3, "auto-start END instruction mismatch");

    send_rv_beat(64'h0000006600000003, 1'b1, 1'b1, 32'd2);
    repeat (4) @(negedge clk);
    check_condition(trigger_seen == 1'b1, "TRIGGER command should create a trigger pulse");
    check_condition(dbg_trigger_count == 32'd1, "TRIGGER command was not counted");

    $display("PASS: PL RISC-V control V1 shim emits PLAY/END instructions and trigger pulses");
    $finish;
  end
endmodule
