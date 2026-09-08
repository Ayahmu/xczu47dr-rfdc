`timescale 1ns/1ps

// Fixed-rate complex FIR: eight little-endian I,Q pairs per 50 MHz cycle.
// A source word sampled at edge n is presented after edge n+6 and can be
// accepted by RFDC at edge n+7. PIPELINE_CYCLES therefore measures the
// source-FIFO acceptance edge to RFDC acceptance edge, not register updates.
// Input invalid means eight explicit zeros; this datapath never stalls.
module iq_fractional_delay_8ppc (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,
    input  wire         config_valid,
    input  wire [2:0]   delay_samples,
    input  wire [5:0]   fractional_phase,
    input  wire [255:0] source_data,
    input  wire         source_valid,
    output reg  [255:0] out_data,
    output wire         busy,
    output reg          clip_pulse
);
  localparam integer PIPELINE_CYCLES = 7;
  localparam integer TAIL_CYCLES = 3;
  localparam integer COEFFICIENT_FRACTION_BITS = 16;

  reg [2:0] delay_hold;
  reg [5:0] phase_hold;
  wire [287:0] coefficients;
  iq_fractional_delay_coeffs coefficients_i (
      .phase(phase_hold), .coefficients(coefficients)
  );

  // The maximum lookback is delay_samples + 15 = 22 complex samples.
  reg signed [15:0] history_i [0:21];
  reg signed [15:0] history_q [0:21];
  reg signed [15:0] samples_i [0:127];
  reg signed [15:0] samples_q [0:127];
  (* use_dsp = "yes" *) reg signed [33:0] products_i [0:127];
  (* use_dsp = "yes" *) reg signed [33:0] products_q [0:127];
  reg signed [34:0] sum1_i [0:63];
  reg signed [34:0] sum1_q [0:63];
  reg signed [35:0] sum2_i [0:31];
  reg signed [35:0] sum2_q [0:31];
  reg signed [36:0] sum3_i [0:15];
  reg signed [36:0] sum3_q [0:15];
  reg signed [37:0] sum4_i [0:7];
  reg signed [37:0] sum4_q [0:7];
  reg [PIPELINE_CYCLES-1:0] valid_pipe;
  reg [1:0] tail_count;
  wire work_valid = source_valid || (tail_count != 0);
  assign busy = rst_n && !clear && !config_valid &&
                (source_valid || (tail_count != 0) || (|valid_pipe));

  // Symmetric round-to-nearest (ties away from zero), followed by saturation.
  // The extra bit also makes negation well-defined at the accumulator minimum.
  function signed [38:0] rounded;
    input signed [37:0] value;
    reg signed [38:0] extended;
    begin
      extended = {value[37], value};
      rounded = (extended < 0)
          ? -((-extended + 39'sd32768) >>> COEFFICIENT_FRACTION_BITS)
          : ((extended + 39'sd32768) >>> COEFFICIENT_FRACTION_BITS);
    end
  endfunction

  function [15:0] saturate;
    input signed [37:0] value;
    reg signed [38:0] result;
    begin
      result = rounded(value);
      if (result > 39'sd32767) saturate = 16'h7fff;
      else if (result < -39'sd32768) saturate = 16'h8000;
      else saturate = result[15:0];
    end
  endfunction

  function clips;
    input signed [37:0] value;
    reg signed [38:0] result;
    begin
      result = rounded(value);
      clips = (result > 39'sd32767) || (result < -39'sd32768);
    end
  endfunction

  integer lane, tap, index, h;
  always @(posedge clk) begin
    if (!rst_n || clear || config_valid) begin
      if (!rst_n) begin
        delay_hold <= 3'd0;
        phase_hold <= 6'd0;
      end else if (config_valid) begin
        delay_hold <= delay_samples;
        phase_hold <= fractional_phase;
      end
      out_data <= 256'd0;
      clip_pulse <= 1'b0;
      valid_pipe <= 0;
      tail_count <= 0;
      for (h = 0; h < 22; h = h + 1) begin
        history_i[h] <= 16'sd0;
        history_q[h] <= 16'sd0;
      end
    end else begin
      valid_pipe <= {valid_pipe[PIPELINE_CYCLES-2:0], work_valid};
      if (source_valid) tail_count <= TAIL_CYCLES;
      else if (tail_count != 0) tail_count <= tail_count - 1'b1;

      for (h = 0; h < 22; h = h + 1) begin
        if (h < 8) begin
          history_i[h] <= source_valid ? $signed(source_data[(7-h)*32 +: 16]) : 16'sd0;
          history_q[h] <= source_valid ? $signed(source_data[(7-h)*32+16 +: 16]) : 16'sd0;
        end else begin
          history_i[h] <= history_i[h-8];
          history_q[h] <= history_q[h-8];
        end
      end
      for (lane = 0; lane < 8; lane = lane + 1) begin
        for (tap = 0; tap < 16; tap = tap + 1) begin
          index = lane - {29'd0, delay_hold} - tap;
          if (index >= 0) begin
            samples_i[lane*16+tap] <= source_valid ? $signed(source_data[index*32 +: 16]) : 16'sd0;
            samples_q[lane*16+tap] <= source_valid ? $signed(source_data[index*32+16 +: 16]) : 16'sd0;
          end else begin
            samples_i[lane*16+tap] <= history_i[-index-1];
            samples_q[lane*16+tap] <= history_q[-index-1];
          end
        end
      end

      out_data <= 256'd0;
      clip_pulse <= 1'b0;
      if (valid_pipe[PIPELINE_CYCLES-2]) begin
        for (lane = 0; lane < 8; lane = lane + 1) begin
          out_data[lane*32 +: 16] <= saturate(sum4_i[lane]);
          out_data[lane*32+16 +: 16] <= saturate(sum4_q[lane]);
          if (clips(sum4_i[lane]) || clips(sum4_q[lane])) clip_pulse <= 1'b1;
        end
      end
    end
  end

  // Arithmetic registers need no reset: valid_pipe masks all flushed data.
  // Keeping the multiplier registers reset-free permits DSP register mapping.
  genvar g;
  generate
    for (g = 0; g < 128; g = g + 1) begin : multiply
      always @(posedge clk) begin
        products_i[g] <= samples_i[g] * $signed(coefficients[(g%16)*18 +: 18]);
        products_q[g] <= samples_q[g] * $signed(coefficients[(g%16)*18 +: 18]);
      end
    end
    for (g = 0; g < 64; g = g + 1) begin : add1
      always @(posedge clk) begin
        sum1_i[g] <= {products_i[2*g][33], products_i[2*g]} + {products_i[2*g+1][33], products_i[2*g+1]};
        sum1_q[g] <= {products_q[2*g][33], products_q[2*g]} + {products_q[2*g+1][33], products_q[2*g+1]};
      end
    end
    for (g = 0; g < 32; g = g + 1) begin : add2
      always @(posedge clk) begin
        sum2_i[g] <= {sum1_i[2*g][34], sum1_i[2*g]} + {sum1_i[2*g+1][34], sum1_i[2*g+1]};
        sum2_q[g] <= {sum1_q[2*g][34], sum1_q[2*g]} + {sum1_q[2*g+1][34], sum1_q[2*g+1]};
      end
    end
    for (g = 0; g < 16; g = g + 1) begin : add3
      always @(posedge clk) begin
        sum3_i[g] <= {sum2_i[2*g][35], sum2_i[2*g]} + {sum2_i[2*g+1][35], sum2_i[2*g+1]};
        sum3_q[g] <= {sum2_q[2*g][35], sum2_q[2*g]} + {sum2_q[2*g+1][35], sum2_q[2*g+1]};
      end
    end
    for (g = 0; g < 8; g = g + 1) begin : add4
      always @(posedge clk) begin
        sum4_i[g] <= {sum3_i[2*g][36], sum3_i[2*g]} + {sum3_i[2*g+1][36], sum3_i[2*g+1]};
        sum4_q[g] <= {sum3_q[2*g][36], sum3_q[2*g]} + {sum3_q[2*g+1][36], sum3_q[2*g+1]};
      end
    end
  endgenerate
endmodule
