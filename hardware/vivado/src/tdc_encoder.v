`timescale 1ns/1ps
`default_nettype none

// Capture the first non-zero delay-line snapshot for each trigger pulse.
// A valid thermometer code contains contiguous ones from bit zero upward.
module tdc_encoder #(
    parameter integer TAPS = 256,
    parameter integer SLOT_WIDTH = 2,
    parameter integer INDEX_WIDTH = $clog2(TAPS)
) (
    input  wire                   clk_sample,
    input  wire                   rst_n,
    input  wire [TAPS-1:0]        taps_in,
    input  wire [SLOT_WIDTH-1:0]  sample_slot_in,
    output reg  [INDEX_WIDTH-1:0] tap_index,
    output reg  [SLOT_WIDTH-1:0]  sample_slot_out,
    output reg                    valid,
    output reg                    overflow,
    output reg                    metastable
);

  (* DONT_TOUCH = "TRUE", SHREG_EXTRACT = "NO" *)
  reg [TAPS-1:0] sampled;
  reg [SLOT_WIDTH-1:0] sample_slot_sampled;
  reg armed;

  wire sample_is_zero = (sampled == {TAPS{1'b0}});
  wire sample_is_full = (sampled == {TAPS{1'b1}});
  wire sample_has_bubble = !sampled[0] |
      |((~sampled[TAPS-2:0]) & sampled[TAPS-1:1]);
  wire [TAPS-1:0] boundary_onehot = sampled & ~(sampled >> 1);

  function [INDEX_WIDTH-1:0] encode_onehot;
    input [TAPS-1:0] onehot;
    integer bit_number;
    integer tap_number;
    begin
      encode_onehot = {INDEX_WIDTH{1'b0}};
      for (bit_number = 0; bit_number < INDEX_WIDTH; bit_number = bit_number + 1) begin
        for (tap_number = 0; tap_number < TAPS; tap_number = tap_number + 1) begin
          if ((tap_number & (1 << bit_number)) != 0) begin
            encode_onehot[bit_number] = encode_onehot[bit_number] | onehot[tap_number];
          end
        end
      end
    end
  endfunction

  always @(posedge clk_sample or negedge rst_n) begin
    if (!rst_n) begin
      sampled <= {TAPS{1'b0}};
      sample_slot_sampled <= {SLOT_WIDTH{1'b0}};
    end else begin
      sampled <= taps_in;
      sample_slot_sampled <= sample_slot_in;
    end
  end

  always @(posedge clk_sample or negedge rst_n) begin
    if (!rst_n) begin
      tap_index <= {INDEX_WIDTH{1'b0}};
      sample_slot_out <= {SLOT_WIDTH{1'b0}};
      valid <= 1'b0;
      overflow <= 1'b0;
      metastable <= 1'b0;
      armed <= 1'b1;
    end else begin
      valid <= 1'b0;
      overflow <= 1'b0;
      metastable <= 1'b0;

      if (!armed) begin
        if (sample_is_zero) begin
          armed <= 1'b1;
        end
      end else if (!sample_is_zero) begin
        armed <= 1'b0;
        sample_slot_out <= sample_slot_sampled;
        if (sample_is_full) begin
          tap_index <= {INDEX_WIDTH{1'b1}};
          overflow <= 1'b1;
        end else if (sample_has_bubble) begin
          metastable <= 1'b1;
        end else begin
          tap_index <= encode_onehot(boundary_onehot);
          valid <= 1'b1;
        end
      end
    end
  end

  initial begin
    if (TAPS < 2) begin
      $error("TDC_ENCODER: TAPS must be at least 2");
      $finish;
    end
  end

endmodule

`default_nettype wire
