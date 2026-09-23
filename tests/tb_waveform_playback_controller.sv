`timescale 1ns/1ps
module tb_waveform_playback_controller;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0;
  reg begin_cmd=0, commit_cmd=0, play_cmd=0, pause_cmd=0, stop_cmd=0, abort_cmd=0;
  reg trigger_event=0, prefetch_done=0, fifo_safe=0, fifo_empty=0, axi_error=0;
  reg beat_valid=0, beat_ready=0, beat_last=0;
  reg [31:0] loop_count=1;
  wire [3:0] state; wire dac_gate; wire [31:0] trigger_seen_count, trigger_dropped_count, trigger_fire_count;
  waveform_playback_controller dut (
    .clk(clk), .rst_n(rst_n), .begin_cmd(begin_cmd), .commit_cmd(commit_cmd),
    .play_cmd(play_cmd), .pause_cmd(pause_cmd), .stop_cmd(stop_cmd), .abort_cmd(abort_cmd),
    .trigger_event(trigger_event), .prefetch_done(prefetch_done), .fifo_safe(fifo_safe),
    .fifo_empty(fifo_empty), .axi_error(axi_error), .beat_valid(beat_valid),
    .beat_ready(beat_ready), .beat_last(beat_last), .loop_count(loop_count), .state(state), .dac_gate(dac_gate),
    .trigger_seen_count(trigger_seen_count), .trigger_dropped_count(trigger_dropped_count),
    .trigger_fire_count(trigger_fire_count));
  task pulse(input integer which); begin
    @(negedge clk);
    case(which) 0: begin_cmd=1; 1: commit_cmd=1; 2: play_cmd=1; 3: pause_cmd=1; 4: stop_cmd=1; 5: abort_cmd=1; 6: trigger_event=1; endcase
    @(negedge clk); begin_cmd=0; commit_cmd=0; play_cmd=0; pause_cmd=0; stop_cmd=0; abort_cmd=0; trigger_event=0;
  end endtask
  initial begin
    repeat(2) @(negedge clk); rst_n=1;
    pulse(0); pulse(1);
    @(negedge clk); prefetch_done=1; fifo_safe=1;
    @(negedge clk); prefetch_done=0; fifo_safe=1;
    if (state !== 4'd4 || dac_gate) begin $display("FAIL: must wait for trigger"); $finish; end
    pulse(6);
    if (state !== 4'd5 || !dac_gate || trigger_fire_count != 1) begin $display("FAIL: trigger must start once"); $finish; end
    pulse(6);
    if (trigger_dropped_count != 1) begin $display("FAIL: trigger while playing must be dropped"); $finish; end
    pulse(3);
    if (state !== 4'd2 || dac_gate) begin $display("FAIL: pause must return ready and mute"); $finish; end
    pulse(2);
    @(negedge clk); prefetch_done=1; fifo_safe=1;
    @(negedge clk); prefetch_done=0; fifo_safe=1;
    if (state !== 4'd5 || !dac_gate) begin $display("FAIL: play must restart from ready"); $finish; end
    pulse(5);
    if (state !== 4'd0 || dac_gate) begin $display("FAIL: abort must clear descriptor"); $finish; end
    $display("PASS: unified waveform playback state machine gates and counts events"); $finish;
  end
endmodule
