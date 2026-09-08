`timescale 1ns/1ps
module tdc_trigger_request_mux #(
    parameter integer IS_MASTER = 0
) (
    input wire prepared, sync_bypass, sync_ready,
    input wire external_valid, external_good,
    input wire [31:0] external_epoch,
    input wire [10:0] external_phase,
    input wire software_pulse, software_is_external,
    input wire [31:0] current_epoch,
    output wire admission_open, event_valid, event_good,
    output wire [31:0] event_epoch,
    output wire [10:0] event_phase
);
  wire local_request = software_pulse && !software_is_external;
  wire select_external = external_valid && (external_good || !local_request);
  assign admission_open = prepared && (IS_MASTER || sync_bypass || sync_ready);
  assign event_valid = external_valid || local_request;
  assign event_good = select_external ? external_good : 1'b1;
  assign event_epoch = select_external ? external_epoch : current_epoch;
  assign event_phase = select_external ? external_phase : 11'd0;
endmodule
