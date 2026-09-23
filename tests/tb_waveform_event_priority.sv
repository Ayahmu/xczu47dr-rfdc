`timescale 1ns/1ps
// Drive only the published controller interface: no forced internal state.
module tb_waveform_event_priority;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0;
  reg begin_cmd=0, commit_cmd=0, play_cmd=0, pause_cmd=0, stop_cmd=0, abort_cmd=0;
  reg trigger_event=0, prefetch_done=0, fifo_safe=0, fifo_empty=0, axi_error=0;
  reg beat_valid=0, beat_ready=0, beat_last=0;
  reg [31:0] loop_count=1;
  wire [3:0] state; wire dac_gate; wire loop_restart; wire [31:0] loop_position;
  wire [31:0] trigger_seen_count,trigger_dropped_count,trigger_fire_count;
  waveform_playback_controller dut(.*);
  integer failures=0;
  task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
  task check(input [3:0] expected, input [255:0] reason); begin
    if(state !== expected) begin
      $display("FAIL: %0s expected=%0d actual=%0d",reason,expected,state); failures++;
    end
  end endtask
  task reset_dut; begin
    rst_n=0; begin_cmd=0;commit_cmd=0;play_cmd=0;pause_cmd=0;stop_cmd=0;abort_cmd=0;
    trigger_event=0;prefetch_done=0;fifo_safe=0;fifo_empty=0;axi_error=0;
    beat_valid=0;beat_ready=0;beat_last=0;
    tick; rst_n=1;tick;
  end endtask
  task waiting; begin
    reset_dut; begin_cmd=1;tick;begin_cmd=0;commit_cmd=1;tick;commit_cmd=0;
    prefetch_done=1;fifo_safe=1;tick;prefetch_done=0;
    check(4,"prefetch -> wait");
  end endtask
  task playing; begin waiting;play_cmd=1;tick;play_cmd=0;check(5,"wait -> playing");end endtask
  initial begin
    waiting;fifo_safe=0;fifo_empty=1;trigger_event=1;play_cmd=1;tick;
    check(8,"wait safety lost before start");
    if(dac_gate || trigger_fire_count || trigger_dropped_count!=1) failures++;
    playing;trigger_event=1;fifo_empty=1;tick;check(8,"trigger must not mask underflow");
    if(trigger_seen_count!=1 || trigger_dropped_count!=1 || trigger_fire_count!=0) failures++;
    playing;trigger_event=1;stop_cmd=1;tick;check(2,"trigger must not mask stop");
    waiting;trigger_event=1;play_cmd=1;stop_cmd=1;tick;check(2,"stop must beat both starts");
    if(trigger_fire_count!=0 || trigger_dropped_count!=1) failures++;
    waiting;trigger_event=1;play_cmd=1;tick;check(5,"trigger beats software play");
    if(trigger_fire_count!=1) failures++;
    playing;stop_cmd=1;axi_error=1;tick;check(8,"fault must beat stop");
    stop_cmd=0;axi_error=0;play_cmd=1;tick;check(8,"play cannot clear error");
    play_cmd=0;pause_cmd=1;tick;check(8,"pause cannot clear error");
    pause_cmd=0;stop_cmd=1;tick;check(8,"stop cannot clear error");
    abort_cmd=1;tick;check(0,"abort clears error");
    reset_dut;begin_cmd=1;tick;begin_cmd=0;stop_cmd=1;tick;check(0,"upload stop cancels session");
    reset_dut;begin_cmd=1;tick;begin_cmd=0;pause_cmd=1;tick;check(1,"upload pause is not ready");
    reset_dut;begin_cmd=1;tick;begin_cmd=0;commit_cmd=1;tick;commit_cmd=0;
    play_cmd=1;tick;play_cmd=0;trigger_event=1;prefetch_done=1;fifo_safe=1;tick;
    check(5,"prefetch remembers software play");
    if(trigger_dropped_count!=1 || trigger_fire_count!=0) failures++;
    reset_dut;begin_cmd=1;tick;begin_cmd=0;commit_cmd=1;tick;commit_cmd=0;axi_error=1;tick;
    check(8,"prefetch fault");
    playing;begin_cmd=1;trigger_event=1;tick;check(1,"begin terminates old session");
    playing;beat_valid=1;beat_ready=0;beat_last=1;tick;check(5,"last without fire holds");
    beat_ready=1;tick;check(6,"last fire drains");tick;check(7,"drain completes");
    if(failures) $fatal(1,"%0d event-priority failures",failures);
    $display("PASS: waveform simultaneous events preserve fault and stop priority");$finish;
  end
  initial begin #100000; $fatal(1,"timeout");end
endmodule
