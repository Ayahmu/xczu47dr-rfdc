`timescale 1ns/1ps

// In-situ measurement of what the hmc_pl_clk detour costs.
//
// Both inputs describe the same physical XS19 rising edge: direct_pulse is the
// DAC-domain capture, legacy_pulse is the same event after it travelled
// through hmc_pl_clk and the toggle CDC.  The difference, counted in
// dac_axis_clk cycles, is the legacy path's latency; its variation across
// triggers is exactly the launch jitter that path contributes.
//
// Resolution is one AXIS cycle (20 ns), so this cannot resolve the 5/12 ns
// fine structure - the scope does that.  What it does prove is whether the
// legacy hop adds a *variable* number of DAC cycles, which is the claim under
// test.  delta_max == delta_min would falsify it.
module dac_trigger_latency_probe #(
    // Give up on a pending pair after this many cycles so a blocked legacy
    // path shows up as an orphan instead of corrupting the next measurement.
    parameter integer PAIR_TIMEOUT_CYCLES = 1024
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        direct_pulse,
    input  wire        legacy_pulse,
    input  wire        started_pulse,
    output reg  [31:0] tick,
    output reg  [15:0] delta_last,
    output reg  [15:0] delta_min,
    output reg  [15:0] delta_max,
    output reg  [15:0] start_delta_last,
    output reg  [31:0] pair_count,
    output reg  [31:0] orphan_count,
    output wire        pair_pending
);
  localparam integer TO_WIDTH =
      (PAIR_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(PAIR_TIMEOUT_CYCLES + 1);

  reg [31:0] direct_tick;
  reg        pending;
  reg [TO_WIDTH-1:0] timeout_count;
  reg        start_pending;

  assign pair_pending = pending;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tick             <= 32'd0;
      direct_tick      <= 32'd0;
      pending          <= 1'b0;
      timeout_count    <= {TO_WIDTH{1'b0}};
      delta_last       <= 16'd0;
      // Seed min high / max low so the first pair sets both.
      delta_min        <= 16'hFFFF;
      delta_max        <= 16'd0;
      start_delta_last <= 16'd0;
      pair_count       <= 32'd0;
      orphan_count     <= 32'd0;
      start_pending    <= 1'b0;
    end else begin
      tick <= tick + 32'd1;

      if (direct_pulse) begin
        // A second direct edge before the legacy one arrived means the legacy
        // path dropped an event; count it and restart the pair.
        if (pending)
          orphan_count <= orphan_count + 32'd1;
        direct_tick   <= tick;
        pending       <= 1'b1;
        timeout_count <= PAIR_TIMEOUT_CYCLES[TO_WIDTH-1:0];
        start_pending <= 1'b1;
      end else if (pending) begin
        if (legacy_pulse) begin
          pending    <= 1'b0;
          delta_last <= tick[15:0] - direct_tick[15:0];
          pair_count <= pair_count + 32'd1;
          if ((tick[15:0] - direct_tick[15:0]) < delta_min)
            delta_min <= tick[15:0] - direct_tick[15:0];
          if ((tick[15:0] - direct_tick[15:0]) > delta_max)
            delta_max <= tick[15:0] - direct_tick[15:0];
        end else if (timeout_count == {TO_WIDTH{1'b0}}) begin
          pending      <= 1'b0;
          orphan_count <= orphan_count + 32'd1;
        end else begin
          timeout_count <= timeout_count - 1'b1;
        end
      end else if (legacy_pulse) begin
        // Legacy event with no direct capture in flight.
        orphan_count <= orphan_count + 32'd1;
      end

      // Capture-to-playback latency of whichever path actually drives launch.
      if (started_pulse && start_pending) begin
        start_pending    <= 1'b0;
        start_delta_last <= tick[15:0] - direct_tick[15:0];
      end
    end
  end
endmodule
