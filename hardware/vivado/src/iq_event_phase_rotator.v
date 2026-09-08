`timescale 1ns/1ps
`default_nettype none
// Remove the event-dependent RF NCO phase in the IQ data. The arbitrary
// constant phase between this accumulator and RFDC does not affect jitter
// within an armed session. RFDC reconfiguration starts a new phase reference.
module iq_event_phase_rotator (
    input wire clk, rst_n, clear, config_valid, armed, enable,
    input wire [47:0] frequency_word,
    input wire [31:0] current_epoch, event_epoch,
    input wire [10:0] event_phase_10ps,
    input wire [255:0] in_data,
    input wire in_busy,
    output reg [255:0] out_data,
    output wire busy,
    output reg clip_pulse
);
  reg [47:0] frequency_meta, frequency_sync, frequency_hold, accumulator;
  reg [47:0] epoch_product, accumulator_snapshot, correction_angle;
  reg signed [62:0] fine_product;
  wire signed [62:0] fine_phase = fine_product / 63'sd125;
  reg [2:0] calculation_valid;
  reg enable_hold;
  wire signed [17:0] sine_rom, cosine_rom;
  reg signed [17:0] sine_hold, cosine_hold;
  wire [47:0] rounded_angle = correction_angle + 48'h000200000000;
  tdc_sincos u_sincos (.clk(clk), .phase(rounded_angle[47:34]), .sine(sine_rom), .cosine(cosine_rom));
  always @(posedge clk) begin
    if (!rst_n) begin
      frequency_meta <= 0; frequency_sync <= 0; frequency_hold <= 0; accumulator <= 0;
      epoch_product <= 0; accumulator_snapshot <= 0; correction_angle <= 0; fine_product <= 0;
      calculation_valid <= 0; enable_hold <= 0;
      sine_hold <= 0; cosine_hold <= 18'sd65536;
    end else begin
      frequency_meta <= frequency_word;
      frequency_sync <= frequency_meta;
      if (!armed && frequency_sync != frequency_hold) begin
        frequency_hold <= frequency_sync;
        accumulator <= 0;
      end else accumulator <= accumulator + (frequency_hold << 7);
      calculation_valid <= {calculation_valid[1:0], config_valid};
      if (config_valid) begin
        epoch_product <= (frequency_hold << 7) * (current_epoch - event_epoch);
        fine_product <= $signed(frequency_hold) * $signed({1'b0, event_phase_10ps, 3'd0});
        accumulator_snapshot <= accumulator;
        enable_hold <= enable;
      end
      if (calculation_valid[0])
        correction_angle <= -(accumulator_snapshot - epoch_product + fine_phase[47:0]);
      if (calculation_valid[2]) begin
        sine_hold <= enable_hold ? sine_rom : 18'sd0;
        cosine_hold <= enable_hold ? cosine_rom : 18'sd65536;
      end
      if (clear) calculation_valid <= 0;
    end
  end
  reg [2:0] valid_pipe;
  (* use_dsp = "yes" *) reg signed [33:0] ic [0:7], qs [0:7], is_ [0:7], qc [0:7];
  reg signed [34:0] result_i [0:7], result_q [0:7];
  wire [7:0] clipping;
  assign busy = rst_n && !clear && !config_valid && (in_busy || (|valid_pipe));
  function signed [35:0] rounded;
    input signed [34:0] value;
    reg signed [35:0] ext;
    begin
      ext = {value[34], value};
      rounded = ext < 0 ? -((-ext + 36'sd32768) >>> 16) : ((ext + 36'sd32768) >>> 16);
    end
  endfunction
  function [15:0] saturated;
    input signed [34:0] value;
    reg signed [35:0] r;
    begin
      r = rounded(value);
      saturated = r > 32767 ? 16'h7fff : r < -32768 ? 16'h8000 : r[15:0];
    end
  endfunction
  genvar lane;
  generate
    for (lane = 0; lane < 8; lane = lane + 1) begin : lanes
      wire signed [15:0] i_value = in_data[lane*32 +: 16];
      wire signed [15:0] q_value = in_data[lane*32+16 +: 16];
      assign clipping[lane] = rounded(result_i[lane]) > 32767 || rounded(result_i[lane]) < -32768 ||
                              rounded(result_q[lane]) > 32767 || rounded(result_q[lane]) < -32768;
      always @(posedge clk) begin
        ic[lane] <= i_value * cosine_hold;
        qs[lane] <= q_value * sine_hold;
        is_[lane] <= i_value * sine_hold;
        qc[lane] <= q_value * cosine_hold;
        result_i[lane] <= {ic[lane][33],ic[lane]} - {qs[lane][33],qs[lane]};
        result_q[lane] <= {is_[lane][33],is_[lane]} + {qc[lane][33],qc[lane]};
        if (!rst_n || clear || config_valid || !valid_pipe[1]) begin
          out_data[lane*32 +: 32] <= 0;
        end else begin
          out_data[lane*32 +: 16] <= saturated(result_i[lane]);
          out_data[lane*32+16 +: 16] <= saturated(result_q[lane]);
        end
      end
    end
  endgenerate
  always @(posedge clk) begin
    if (!rst_n || clear || config_valid) begin valid_pipe <= 0; clip_pulse <= 0; end
    else begin valid_pipe <= {valid_pipe[1:0], in_busy}; clip_pulse <= valid_pipe[1] && (|clipping); end
  end
endmodule
`default_nettype wire
