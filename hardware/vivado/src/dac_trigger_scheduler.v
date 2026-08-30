`timescale 1ns/1ps

// Deterministic launch scheduler in the RFDC DAC fabric clock domain.
//
// A trigger request may cross into this domain on either side of a DAC clock
// edge. Starting immediately would therefore produce a one-cycle (20 ns)
// ambiguity. The request is latched and released after a fixed number of DAC
// clock cycles. SYSREF is retained as a diagnostic epoch counter only; it is
// deliberately not used as a launch condition because its 2 MHz period would
// introduce a 500 ns two-state ambiguity between boards.
module dac_trigger_scheduler #(
    parameter integer EPOCH_WIDTH = 16,
    parameter integer TARGET_DAC_DELAY_CYCLES = 4
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    sysref_in,
    input  wire                    trigger_request,
    input  wire                    clear_pending,
    output reg                     trigger_launch,
    output reg [EPOCH_WIDTH-1:0]   sysref_epoch,
    output reg [EPOCH_WIDTH-1:0]   trigger_target_epoch,
    output reg                     trigger_pending
);
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] sysref_sync;
  reg sysref_prev;
  localparam integer DELAY_WIDTH =
      (TARGET_DAC_DELAY_CYCLES <= 1) ? 1 : $clog2(TARGET_DAC_DELAY_CYCLES + 1);
  reg [DELAY_WIDTH-1:0] delay_count;
  wire sysref_rise = sysref_sync[1] && !sysref_prev;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sysref_sync <= 2'b00;
      sysref_prev <= 1'b0;
      trigger_launch <= 1'b0;
      sysref_epoch <= {EPOCH_WIDTH{1'b0}};
      trigger_target_epoch <= {EPOCH_WIDTH{1'b0}};
      trigger_pending <= 1'b0;
      delay_count <= {DELAY_WIDTH{1'b0}};
    end else begin
      sysref_sync <= {sysref_sync[0], sysref_in};
      sysref_prev <= sysref_sync[1];
      trigger_launch <= 1'b0;

      if (sysref_rise)
        sysref_epoch <= sysref_epoch + 1'b1;

      // ABORT/MUTE cancels a request that has not reached its launch boundary.
      if (clear_pending) begin
        trigger_pending <= 1'b0;
        delay_count <= {DELAY_WIDTH{1'b0}};
      end else if (trigger_request && !trigger_pending) begin
        // Requests are one-cycle pulses produced by the HMC event CDC. Use a
        // fixed DAC-domain delay so launch never depends on SYSREF phase.
        trigger_pending <= 1'b1;
        // The request is sampled on this edge.  Loading D+1 causes the
        // launch edge to occur exactly D full DAC periods later.
        delay_count <= TARGET_DAC_DELAY_CYCLES + 1;
        trigger_target_epoch <= sysref_epoch;
      end

      if (trigger_pending) begin
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
