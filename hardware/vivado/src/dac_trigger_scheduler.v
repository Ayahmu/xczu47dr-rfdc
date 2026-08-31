`timescale 1ns/1ps

// Deterministic launch scheduler in the RFDC DAC fabric clock domain.
//
// A trigger request may cross into this domain on either side of a DAC clock
// edge. Starting immediately would therefore produce a one-cycle (20 ns)
// ambiguity. The request is latched and released after a fixed number of DAC
// clock cycles.  SYSREF belongs to RFDC MTS/NCO alignment and must not gate
// playback: sampling its 2 MHz waveform independently on two boards was the
// source of the former 500 ns two-state launch offset.
module dac_trigger_scheduler #(
    parameter integer TARGET_DAC_DELAY_CYCLES = 4
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    trigger_request,
    input  wire                    clear_pending,
    output reg                     trigger_launch,
    output reg                     trigger_pending
);
  localparam integer DELAY_WIDTH =
      (TARGET_DAC_DELAY_CYCLES <= 1) ? 1 : $clog2(TARGET_DAC_DELAY_CYCLES + 1);
  reg [DELAY_WIDTH-1:0] delay_count;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      trigger_launch <= 1'b0;
      trigger_pending <= 1'b0;
      delay_count <= {DELAY_WIDTH{1'b0}};
    end else begin
      trigger_launch <= 1'b0;

      // ABORT/MUTE cancels a request that has not reached its launch edge.
      if (clear_pending) begin
        trigger_pending <= 1'b0;
        delay_count <= {DELAY_WIDTH{1'b0}};
      end else if (trigger_request && !trigger_pending) begin
        // The request is a one-cycle pulse produced by the HMC-event CDC.
        // Do not add any SYSREF-dependent condition here.
        trigger_pending <= 1'b1;
        delay_count <= TARGET_DAC_DELAY_CYCLES + 1;
      end else if (trigger_pending) begin
        if (delay_count <= {{(DELAY_WIDTH-1){1'b0}}, 1'b1}) begin
          trigger_pending <= 1'b0;
          delay_count <= {DELAY_WIDTH{1'b0}};
          trigger_launch <= 1'b1;
        end else begin
          delay_count <= delay_count - 1'b1;
        end
      end
    end
  end
endmodule
