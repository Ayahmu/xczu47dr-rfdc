`timescale 1ns/1ps

module tb_dac_play_burst;
  reg clk=0, rst_n=0, trigger=0, rfctrl2_trigger=0, prepare=0, abort=0, armed=1;
  reg [15:0] cfg_seq_id=1;
  reg [31:0] repeat_limit=3;
  reg debug_alternate=0;
  reg auto_start=1;
  wire allow, started, prepared;
  wire [31:0] admitted, skipped, fires;
  always #5 clk=~clk;

  dac_play_ctrl dut(
    .clk(clk), .rst_n(rst_n), .trigger(trigger), .rfctrl2_trigger(rfctrl2_trigger),
    .prepare(prepare), .abort(abort), .armed(armed), .cfg_seq_id(cfg_seq_id),
    .auto_start(auto_start), .loop_enable(1'b1), .repeat_limit(repeat_limit),
    .debug_alternate(debug_alternate),
    .ch1_delay_cycles(0), .ch2_delay_cycles(0), .ch3_delay_cycles(0), .ch4_delay_cycles(0),
    .ch5_delay_cycles(0), .ch6_delay_cycles(0), .ch7_delay_cycles(0), .ch8_delay_cycles(0),
    .ch1_len_beats(2), .ch2_len_beats(0), .ch3_len_beats(0), .ch4_len_beats(0),
    .ch5_len_beats(0), .ch6_len_beats(0), .ch7_len_beats(0), .ch8_len_beats(0),
    .ch1_arm(1'b1), .ch2_arm(0), .ch3_arm(0), .ch4_arm(0), .ch5_arm(0), .ch6_arm(0), .ch7_arm(0), .ch8_arm(0),
    .ch1_fifo_tvalid(1'b1), .ch2_fifo_tvalid(0), .ch3_fifo_tvalid(0), .ch4_fifo_tvalid(0),
    .ch5_fifo_tvalid(0), .ch6_fifo_tvalid(0), .ch7_fifo_tvalid(0), .ch8_fifo_tvalid(0),
    .ch1_fifo_prog_empty(1'b0), .ch2_fifo_prog_empty(1), .ch3_fifo_prog_empty(1), .ch4_fifo_prog_empty(1),
    .ch5_fifo_prog_empty(1), .ch6_fifo_prog_empty(1), .ch7_fifo_prog_empty(1), .ch8_fifo_prog_empty(1),
    .dac_ch1_ready_in(1'b1), .dac_ch2_ready_in(0), .dac_ch3_ready_in(0), .dac_ch4_ready_in(0),
    .dac_ch5_ready_in(0), .dac_ch6_ready_in(0), .dac_ch7_ready_in(0), .dac_ch8_ready_in(0),
    .ch1_allow(allow), .ch2_allow(), .ch3_allow(), .ch4_allow(), .ch5_allow(), .ch6_allow(), .ch7_allow(), .ch8_allow(),
    .ch1_active(), .ch2_active(), .ch3_active(), .ch4_active(), .ch5_active(), .ch6_active(), .ch7_active(), .ch8_active(),
    .prepared(prepared), .dbg_trig_pulse(), .dbg_new_cfg(), .dbg_trig_start(), .dbg_started(started),
    .dbg_last_seq_id(), .dbg_done_pulse(), .dbg_underflow_seen(), .dbg_ch1_fire_count(fires),
    .dbg_ch2_fire_count(), .dbg_ch3_fire_count(), .dbg_ch4_fire_count(), .dbg_ch5_fire_count(),
    .dbg_ch6_fire_count(), .dbg_ch7_fire_count(), .dbg_ch8_fire_count(),
    .dbg_trigger_admitted_count(admitted), .dbg_trigger_skipped_count(skipped)
  );

  task pulse_trigger; begin
    @(negedge clk); rfctrl2_trigger=1; @(negedge clk); rfctrl2_trigger=0; end
  endtask
  task pulse_prepare; begin
    @(negedge clk); prepare=1; @(negedge clk); prepare=0; end
  endtask

  initial begin
    #5000; $error("timeout state started=%b prepared=%b fires=%0d admitted=%0d skipped=%0d", started, prepared, fires, admitted, skipped); $finish;
  end

  initial begin
    repeat(3) @(posedge clk); rst_n=1; pulse_prepare(); wait(prepared); pulse_trigger(); wait(started);
    wait(prepared); @(posedge clk);
    if(fires != 6 || admitted != 1 || skipped != 0) begin
      $error("finite burst must emit exactly repeat_limit frames fires=%0d admitted=%0d skipped=%0d", fires, admitted, skipped); $finish;
    end
    @(negedge clk); rst_n=0; repeat(2) @(posedge clk); rst_n=1;
    cfg_seq_id=2; debug_alternate=1; repeat_limit=1; auto_start=0; pulse_prepare(); wait(prepared);
    pulse_trigger(); repeat(3) @(posedge clk);
    if(started || skipped != 1 || admitted != 0) begin
      $error("debug alternate must skip the first trigger after ARM"); $finish;
    end
    pulse_trigger(); wait(prepared); @(posedge clk);
    if(admitted != 1 || fires != 2) begin
      $error("debug alternate must admit the second trigger"); $finish;
    end
    $display("PASS: finite burst repeat count and ARM-scoped debug alternate gating");
    $finish;
  end
endmodule
