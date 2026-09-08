`timescale 1ns/1ps
`default_nettype none

// Schedule against the capture epoch, never against FIFO arrival time.
module tdc_compensating_trigger #(
    parameter integer TARGET_BEATS = 32
) (
    input wire clk, rst_n, clear,
    input wire enable, calibrated, reference_ready,
    input wire prepared, source_running, output_busy, source_done, loop_enable,
    input wire runtime_fault,
    input wire [7:0] clip_pulse,
    input wire [31:0] current_epoch,
    input wire event_valid, event_good,
    input wire [31:0] event_epoch,
    input wire [10:0] event_phase_10ps,
    input wire signed [15:0] phase_offset_10ps,
    input wire clear_statistics,
    output reg launch, config_valid,
    output reg [2:0] delay_samples,
    output reg [5:0] fractional_phase,
    output reg pending, active, fault,
    output reg [31:0] accepted_count, completed_count, rejected_count, late_count,
    output reg [31:0] fault_bits,
    output reg [7:0] clipped_channels,
    output reg [31:0] accepted_epoch,
    output reg [10:0] accepted_phase_10ps
);
  reg [31:0] prepared_epoch, deadline;
  reg prepared_previous, draining, saw_source;
  reg [5:0] prepared_age;
  wire signed [17:0] adjusted_phase =
      $signed({7'd0, event_phase_10ps}) + $signed(phase_offset_10ps);
  wire negative_phase = adjusted_phase < 0;
  wire overflow_phase = adjusted_phase >= 18'sd2000;
  wire [17:0] normalized_phase = negative_phase ? adjusted_phase + 18'sd2000 :
                              overflow_phase ? adjusted_phase - 18'sd2000 : adjusted_phase;
  wire [31:0] normalized_epoch = negative_phase ? event_epoch - 1'b1 :
                                      overflow_phase ? event_epoch + 1'b1 : event_epoch;
  // One IQ sample is 250 units of 10 ps. Rounding yields a 39.0625 ps step.
  wire [23:0] phase_numerator = {normalized_phase, 6'd0} + 24'd125;
  wire [23:0] phase_quantized = phase_numerator / 24'd250;
  wire [31:0] target_epoch = normalized_epoch + TARGET_BEATS + (phase_quantized == 512);
  wire [31:0] admission_epoch = prepared_previous ? prepared_epoch : current_epoch;
  // The FIFO is drained continuously. Only the first 640 ns of PREPARED
  // need an age check; keeping a signed 32-bit comparison forever would
  // reject a first trigger after 42.95 seconds of waiting.
  wire event_after_prepare = prepared_age >= 32 || $signed(event_epoch - admission_epoch) >= 0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      launch <= 0; config_valid <= 0; delay_samples <= 0; fractional_phase <= 0;
      pending <= 0; active <= 0; fault <= 0;
      accepted_count <= 0; completed_count <= 0; rejected_count <= 0; late_count <= 0;
      fault_bits <= 0; clipped_channels <= 0;
      prepared_epoch <= 0; deadline <= 0; prepared_previous <= 0;
      prepared_age <= 0;
      draining <= 0; saw_source <= 0; accepted_epoch <= 0; accepted_phase_10ps <= 0;
    end else begin
      launch <= 0; config_valid <= 0;
      prepared_previous <= prepared;
      if (!prepared) prepared_age <= 0;
      else if (prepared_age != 63) prepared_age <= prepared_age + 1'b1;
      if (prepared && !prepared_previous) prepared_epoch <= current_epoch;
      clipped_channels <= clipped_channels | clip_pulse;
      if (clear_statistics) begin
        accepted_count <= 0; completed_count <= 0; rejected_count <= 0; late_count <= 0;
        fault_bits <= 0; clipped_channels <= 0;
      end
      if (clear) begin
        pending <= 0; active <= 0; fault <= 0;
        draining <= 0; saw_source <= 0;
      end else if (enable && (runtime_fault || !reference_ready || !calibrated)) begin
        if (active || pending) begin
          fault <= 1;
          fault_bits <= fault_bits | (runtime_fault ? 32'd2 : 32'd1);
        end
        pending <= 0; active <= 0; draining <= 0; saw_source <= 0;
      end else if (enable && !fault) begin
        if (event_valid) begin
          if (!prepared || active || pending || !event_good || !event_after_prepare) begin
            rejected_count <= rejected_count + 1'b1;
          end else if ($signed(target_epoch - current_epoch) < 32'sd3) begin
            rejected_count <= rejected_count + 1'b1;
            late_count <= late_count + 1'b1;
          end else begin
            deadline <= target_epoch;
            delay_samples <= phase_quantized[8:6];
            fractional_phase <= phase_quantized[5:0];
            config_valid <= 1;
            pending <= 1; active <= 1; saw_source <= 0; draining <= 0;
            accepted_count <= accepted_count + 1'b1;
            accepted_epoch <= normalized_epoch;
            accepted_phase_10ps <= normalized_phase[10:0];
          end
        end
        if (pending && current_epoch == deadline - 1'b1) begin
          launch <= 1; pending <= 0;
        end else if (pending && $signed(current_epoch - deadline) >= 0) begin
          pending <= 0; active <= 0; fault <= 1;
          fault_bits <= fault_bits | 32'd4;
          late_count <= late_count + 1'b1;
        end
        if (active && source_running) saw_source <= 1;
        if (active && saw_source && source_done && !loop_enable) draining <= 1;
        if (active && draining && !source_running && !output_busy) begin
          active <= 0; draining <= 0; saw_source <= 0;
          completed_count <= completed_count + 1'b1;
        end
      end else if (!enable) begin
        pending <= 0; active <= 0; draining <= 0; saw_source <= 0;
      end
    end
  end
endmodule
`default_nettype wire
