`timescale 1ns/1ps

// Async-set pulse capture, not a pad-clocked state machine. Only the last
// stages of the two ASYNC_REG chains feed logic. A captured episode stays
// latched until raw-low has been observed for four complete DAC clocks; the
// latch synchronizer must then drain before another episode is armed.
//
// On entry to WAIT a conservative five-observation guard (four full intervals) isolates old events.
// Admission also uses the delayed window permission, so an edge already in
// the capture pipeline cannot inherit permission from a newly opened window.
// The guard is intentional dead time, not an external-trigger queue.
module waveform_trigger_cdc (
    input wire clk, input wire rst_n, input wire trigger_in,
    input wire wait_trigger,
    output wire trigger_event,
    output reg trigger_seen, output reg trigger_dropped,
    output reg [31:0] trigger_seen_count,
    output reg [31:0] trigger_dropped_count
);
  reg trigger_latch = 1'b0;
  (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [2:0] sync_ff;
  (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [2:0] raw_sync;
  reg [2:0] low_cycles;
  reg [3:0] wait_quiet_cycles, wait_history;
  reg armed;
  wire low_qualified = low_cycles == 4;
  wire captured = armed && sync_ff[2];
  wire wait_qualified = wait_trigger && wait_quiet_cycles == 5;
  wire admitted = wait_qualified && wait_history[3];

  always @(posedge clk or posedge trigger_in) begin
    if (trigger_in) trigger_latch <= 1;
    else if (!rst_n || (!armed && low_qualified)) trigger_latch <= 0;
  end
  assign trigger_event = captured && admitted;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync_ff<=0;raw_sync<=0;low_cycles<=0;wait_quiet_cycles<=0;
      wait_history<=0;armed<=0;trigger_seen<=0;trigger_dropped<=0;
      trigger_seen_count<=0;trigger_dropped_count<=0;
    end else begin
      sync_ff<={sync_ff[1:0],trigger_latch};
      raw_sync<={raw_sync[1:0],trigger_in};
      wait_history<={wait_history[2:0],wait_qualified};
      if (raw_sync[2]) low_cycles<=0;
      else if (!low_qualified) low_cycles<=low_cycles+1'b1;
      if (!wait_trigger) wait_quiet_cycles<=0;
      else if (!wait_qualified) begin
        if (armed && low_qualified && !sync_ff[2] && !raw_sync[2])
          wait_quiet_cycles<=wait_quiet_cycles+1'b1;
        else wait_quiet_cycles<=0;
      end
      if (captured) armed<=0;
      else if (!armed && low_qualified && !sync_ff[2] && !raw_sync[2]) armed<=1;
      trigger_seen<=captured;trigger_dropped<=captured&&!admitted;
      if (captured) begin
        trigger_seen_count<=trigger_seen_count+1'b1;
        if (!admitted) trigger_dropped_count<=trigger_dropped_count+1'b1;
      end
    end
  end
endmodule
