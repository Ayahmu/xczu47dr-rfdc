`timescale 1ns/1ps

module tb_dac_play_ctrl;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg trigger = 1'b0;
  reg [15:0] cfg_seq_id = 16'd1;
  reg auto_start = 1'b1;
  reg [31:0] ch1_len_beats = 32'd8;
  reg ch1_arm = 1'b1;
  reg ch1_fifo_tvalid = 1'b1;
  reg ch1_fifo_prog_empty = 1'b1;
  reg dac_ch1_ready_in = 1'b1;

  wire ch1_allow;
  wire dbg_started;
  wire dbg_trig_start;

  always #5 clk = ~clk;

  dac_play_ctrl #(
    .BEAT_BYTES(32)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .trigger(trigger),
    .cfg_seq_id(cfg_seq_id),
    .auto_start(auto_start),
    .ch1_delay_cycles(32'd0),
    .ch2_delay_cycles(32'd0),
    .ch3_delay_cycles(32'd0),
    .ch4_delay_cycles(32'd0),
    .ch5_delay_cycles(32'd0),
    .ch6_delay_cycles(32'd0),
    .ch7_delay_cycles(32'd0),
    .ch8_delay_cycles(32'd0),
    .ch1_len_beats(ch1_len_beats),
    .ch2_len_beats(32'd0),
    .ch3_len_beats(32'd0),
    .ch4_len_beats(32'd0),
    .ch5_len_beats(32'd0),
    .ch6_len_beats(32'd0),
    .ch7_len_beats(32'd0),
    .ch8_len_beats(32'd0),
    .ch1_arm(ch1_arm),
    .ch2_arm(1'b0),
    .ch3_arm(1'b0),
    .ch4_arm(1'b0),
    .ch5_arm(1'b0),
    .ch6_arm(1'b0),
    .ch7_arm(1'b0),
    .ch8_arm(1'b0),
    .ch1_fifo_tvalid(ch1_fifo_tvalid),
    .ch2_fifo_tvalid(1'b0),
    .ch3_fifo_tvalid(1'b0),
    .ch4_fifo_tvalid(1'b0),
    .ch5_fifo_tvalid(1'b0),
    .ch6_fifo_tvalid(1'b0),
    .ch7_fifo_tvalid(1'b0),
    .ch8_fifo_tvalid(1'b0),
    .ch1_fifo_prog_empty(ch1_fifo_prog_empty),
    .ch2_fifo_prog_empty(1'b1),
    .ch3_fifo_prog_empty(1'b1),
    .ch4_fifo_prog_empty(1'b1),
    .ch5_fifo_prog_empty(1'b1),
    .ch6_fifo_prog_empty(1'b1),
    .ch7_fifo_prog_empty(1'b1),
    .ch8_fifo_prog_empty(1'b1),
    .dac_ch1_ready_in(dac_ch1_ready_in),
    .dac_ch2_ready_in(1'b0),
    .dac_ch3_ready_in(1'b0),
    .dac_ch4_ready_in(1'b0),
    .dac_ch5_ready_in(1'b0),
    .dac_ch6_ready_in(1'b0),
    .dac_ch7_ready_in(1'b0),
    .dac_ch8_ready_in(1'b0),
    .ch1_allow(ch1_allow),
    .ch2_allow(),
    .ch3_allow(),
    .ch4_allow(),
    .ch5_allow(),
    .ch6_allow(),
    .ch7_allow(),
    .ch8_allow(),
    .ch1_active(),
    .ch2_active(),
    .ch3_active(),
    .ch4_active(),
    .ch5_active(),
    .ch6_active(),
    .ch7_active(),
    .ch8_active(),
    .dbg_trig_pulse(),
    .dbg_new_cfg(),
    .dbg_trig_start(dbg_trig_start),
    .dbg_started(dbg_started),
    .dbg_last_seq_id()
  );

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);
    if (!dbg_started || !ch1_allow) begin
      $error("dac_play_ctrl must start when FIFO tvalid=1 even if short-frame prog_empty remains asserted");
      $finish;
    end

    wait (dbg_started == 1'b0);

    auto_start = 1'b0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    trigger = 1'b1;
    @(negedge clk);
    trigger = 1'b0;
    repeat (4) @(posedge clk);
    if (dbg_started || dbg_trig_start) begin
      $error("dac_play_ctrl must not restart an already consumed cfg_seq_id");
      $finish;
    end

    @(negedge clk);
    cfg_seq_id = 16'd2;
    repeat (4) @(posedge clk);
    if (!dbg_started || !ch1_allow) begin
      $error("dac_play_ctrl must preserve an early trigger until the next cfg_seq_id arrives");
      $finish;
    end

    $display("PASS: dac_play_ctrl starts short frames and preserves early trigger until cfg arrival");
    $finish;
  end
endmodule
