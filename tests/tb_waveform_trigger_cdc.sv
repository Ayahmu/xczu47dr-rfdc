`timescale 1ns/1ps
module tb_waveform_trigger_cdc;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, trigger_in=0, wait_trigger=0;
  wire trigger_event, trigger_seen, trigger_dropped;
  wire [31:0] seen_count, dropped_count;
  integer accepted=0, failures=0;
  waveform_trigger_cdc dut(.clk(clk), .rst_n(rst_n), .trigger_in(trigger_in),
    .wait_trigger(wait_trigger), .trigger_event(trigger_event), .trigger_seen(trigger_seen),
    .trigger_dropped(trigger_dropped), .trigger_seen_count(seen_count),
    .trigger_dropped_count(dropped_count));
  always @(posedge clk) if(rst_n && trigger_event) accepted++;
  task cycles(input integer n); begin repeat(n) @(negedge clk); end endtask
  task pulse(input integer ns); begin #1;trigger_in=1;#(ns);trigger_in=0;end endtask
  task pulse_after_posedge(input integer ns); begin @(posedge clk);#1;trigger_in=1;#(ns);trigger_in=0;end endtask
  task check(input integer seen,input integer dropped,input integer fired,input [255:0] why);begin
    if(seen_count!==seen || dropped_count!==dropped || accepted!=fired) begin
      $display("FAIL: %0s seen=%0d drop=%0d fire=%0d",why,seen_count,dropped_count,accepted);failures++;
    end
  end endtask
  initial begin
    cycles(3);rst_n=1;cycles(20);
    pulse(8);cycles(20);check(1,1,0,"non-wait narrow pulse");
    wait_trigger=1;cycles(20);pulse(8);cycles(20);check(2,1,1,"wait narrow pulse");
    trigger_in=1;cycles(20);check(3,1,2,"wide pulse only once");
    // Brief low gaps are ringing, not re-arm. Keep the full episode longer
    // than the old capture latch round trip to expose premature re-arming.
    repeat(4) begin trigger_in=0;cycles(3);trigger_in=1;cycles(10);end
    check(3,1,2,"ringing cannot rearm");
    trigger_in=0;cycles(20);pulse(1);cycles(20);check(4,1,3,"1 ns pulse after rearm");
    wait_trigger=0;cycles(20);pulse(8);
    // The edge occurred outside WAIT, but reaches the synchronizer after the
    // state changes. The new admission window must not resurrect that edge.
    wait_trigger=1;cycles(20);check(5,2,3,"old event at new wait boundary");
    wait_trigger=0;cycles(20);trigger_in=1;cycles(10);wait_trigger=1;cycles(20);
    check(6,3,3,"held input cannot start new wait");
    trigger_in=0;cycles(20);pulse(8);cycles(20);check(7,3,4,"fresh edge after wait isolation");
    // Phase sweep through the guard interval after entry to a new WAIT.
    wait_trigger=0;cycles(20);wait_trigger=1;cycles(3);pulse(8);cycles(20);
    check(8,4,4,"pulse in final guard cycle");
    wait_trigger=0;cycles(20);wait_trigger=1;cycles(2);pulse_after_posedge(8);cycles(20);
    check(9,5,4,"pulse after sampling edge cannot enter wait");
    if(failures) $fatal(1,"%0d trigger capture failures",failures);
    $display("PASS: narrow trigger CDC captures one event and never queues it");$finish;
  end
  initial begin #20000;$fatal(1,"timeout");end
endmodule
