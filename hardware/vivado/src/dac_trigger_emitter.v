`timescale 1ns/1ps

// XS18/XS20 Trigger pulse generated in the RFDC DAC fabric clock domain.
//
// The default emitter lives in hmc_pl_clk (96 MHz).  That is fine as a physical
// output, but it makes the board useless as its own timing reference: the pulse
// edge is quantized to hmc_pl_clk while playback starts on dac_axis_clk, and the
// two clocks sit on a 25:48 phase lattice (5/12 ns granularity, 19.583 ns span).
// An XS18->XS19 loopback therefore shows ~19.6 ns of launch spread no matter
// which capture path is used, which hides everything else being measured.
//
// Emitting here instead puts the scope reference (XS20) and the RF launch in the
// same clock domain, so a single-board loopback should show only IO and PCB
// skew.  That gives a zero-reference ruler for separating measurement error from
// the jitter actually under test.
module dac_trigger_emitter #(
    // Output pulse width in dac_axis_clk cycles.  4 x 20 ns = 80 ns, close to
    // the 8 x 10.4167 ns = 83 ns the hmc_pl_clk emitter produces.
    parameter integer HIGH_CYCLES = 4
) (
    input  wire ddr_clk,
    input  wire ddr_rst_n,
    // One-cycle request in the DDR domain (RFCTRL2 EMIT_TRIGGER).
    input  wire emit_request_ddr,
    input  wire dac_clk,
    input  wire dac_rst_n,
    // Gate: same admission rule as the hmc_pl_clk emitter uses.
    input  wire emit_allowed,
    output reg  pulse_out,
    output reg  [31:0] pulse_count
);
  localparam integer CNT_WIDTH =
      (HIGH_CYCLES <= 1) ? 1 : $clog2(HIGH_CYCLES + 1);

  // A toggle survives the DDR -> DAC crossing regardless of the clock ratio.
  reg emit_toggle_ddr;
  always @(posedge ddr_clk or negedge ddr_rst_n) begin
    if (!ddr_rst_n)
      emit_toggle_ddr <= 1'b0;
    else if (emit_request_ddr)
      emit_toggle_ddr <= ~emit_toggle_ddr;
  end

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] emit_sync_ff;
  reg emit_seen;
  reg [CNT_WIDTH-1:0] high_count;

  wire emit_pulse = emit_sync_ff[2] != emit_seen;

  always @(posedge dac_clk or negedge dac_rst_n) begin
    if (!dac_rst_n) begin
      emit_sync_ff <= 3'b000;
      emit_seen    <= 1'b0;
      high_count   <= {CNT_WIDTH{1'b0}};
      pulse_out    <= 1'b0;
      pulse_count  <= 32'd0;
    end else begin
      emit_sync_ff <= {emit_sync_ff[1:0], emit_toggle_ddr};
      emit_seen    <= emit_sync_ff[2];

      if (emit_pulse && emit_allowed) begin
        high_count  <= HIGH_CYCLES[CNT_WIDTH-1:0];
        pulse_out   <= 1'b1;
        pulse_count <= pulse_count + 32'd1;
      end else if (high_count != {CNT_WIDTH{1'b0}}) begin
        high_count <= high_count - 1'b1;
        pulse_out  <= 1'b1;
      end else begin
        pulse_out <= 1'b0;
      end
    end
  end
endmodule
