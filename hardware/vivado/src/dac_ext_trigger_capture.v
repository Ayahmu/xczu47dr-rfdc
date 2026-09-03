`timescale 1ns/1ps

// External Trigger capture in the RFDC DAC fabric clock domain.
//
// Two problems are solved here.
//
// 1. Clock-domain quantization.  The legacy slave path captured XS19 in
//    hmc_pl_clk (96 MHz) and handed the event to dac_axis_clk (50 MHz) through
//    a toggle CDC.  Both clocks descend from the same HMC7044 VCO, so their
//    period ratio is exactly 25:48 and the phase relation repeats every 500 ns.
//    The launch toggle therefore lands at one of 48 positions inside the 20 ns
//    DAC period, spaced gcd(20, 125/12) = 5/12 ns apart and spanning 19.583 ns.
//    That spreads the launch by ~19.6 ns even when XS19 is perfectly clean,
//    because which hmc_pl_clk edge captured it decides where in the DAC period
//    the event arrives.  Capturing XS19 here removes that term; what remains is
//    the Trigger's own arrival phase inside one dac_axis_clk period.
//
// 2. Short pulses.  The real external Trigger is ~8 ns wide - shorter than half
//    a dac_axis_clk period, and shorter than one hmc_pl_clk period.  Sampling
//    the pad with any of those clocks would miss roughly 60% (DAC) or 23% (HMC)
//    of Triggers.  The pad therefore drives the asynchronous set of a latch, so
//    capture does not depend on a clock edge at all; the clocked logic then
//    synchronizes a held level instead of racing a narrow pulse.  A pulse only
//    has to satisfy the flop's minimum set pulse width (~1 ns), so 8 ns is
//    ample.  Wide pulses (the 83 ns XS18 loopback) still produce exactly one
//    event because the release only takes effect once the pad returns low.
module dac_ext_trigger_capture #(
    // Accepts are suppressed for this many clk cycles after one is taken, so
    // ringing on a long unterminated MMCX cable cannot fake a second Trigger.
    parameter integer MIN_RETRIGGER_CYCLES = 4
) (
    input  wire        clk,
    input  wire        rst_n,
    // Raw asynchronous pad input (XS19/TRIG_2).  May be far shorter than clk.
    input  wire        trigger_in,
    // Playback may consume a Trigger.  Must include the DAC-domain PREPARED
    // state so the interlock below re-arms on the same clock that clears it.
    input  wire        gate_open,
    // ABORT/MUTE cancels a consumed marker without waiting for PREPARED.
    input  wire        clear,
    output reg         trigger_pulse,
    output reg         trigger_edge_raw,
    output reg  [31:0] input_count,
    output reg  [31:0] accept_count,
    output wire        trigger_in_sync,
    output wire        trigger_latched
);
  localparam integer BLANK_WIDTH =
      (MIN_RETRIGGER_CYCLES <= 1) ? 1 : $clog2(MIN_RETRIGGER_CYCLES + 1);

  // Asynchronous-set capture latch.  trigger_in drives the set, not the clock,
  // so an 8 ns pad pulse is held until the clocked logic has seen it.
  reg trig_latch;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] latch_sync_ff;
  reg latch_prev;
  reg consumed;
  reg [BLANK_WIDTH-1:0] blank_count;

  // Release the latch whenever its level has already been observed for a full
  // cycle.  Continuous rather than counted, so a pad that keeps setting the
  // latch (a wide pulse, or ringing) can never leave it stuck set.
  wire latch_release = latch_prev && latch_sync_ff[2];

  always @(posedge clk or posedge trigger_in) begin
    if (trigger_in)
      trig_latch <= 1'b1;
    else if (!rst_n || latch_release)
      trig_latch <= 1'b0;
  end

  wire latch_rise = latch_sync_ff[2] && !latch_prev;
  wire blanked    = (blank_count != {BLANK_WIDTH{1'b0}});
  wire accept     = latch_rise && gate_open && !consumed && !blanked;

  assign trigger_in_sync = latch_sync_ff[2];
  assign trigger_latched = trig_latch;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      latch_sync_ff    <= 3'b000;
      latch_prev       <= 1'b0;
      consumed         <= 1'b0;
      blank_count      <= {BLANK_WIDTH{1'b0}};
      trigger_pulse    <= 1'b0;
      trigger_edge_raw <= 1'b0;
      input_count      <= 32'd0;
      accept_count     <= 32'd0;
    end else begin
      latch_sync_ff    <= {latch_sync_ff[1:0], trig_latch};
      latch_prev       <= latch_sync_ff[2];
      trigger_pulse    <= accept;
      trigger_edge_raw <= latch_rise;

      if (latch_rise)
        input_count <= input_count + 32'd1;
      if (accept) begin
        accept_count <= accept_count + 32'd1;
        blank_count  <= MIN_RETRIGGER_CYCLES[BLANK_WIDTH-1:0];
      end else if (blanked) begin
        blank_count <= blank_count - 1'b1;
      end

      if (clear)
        consumed <= 1'b0;
      else if (accept)
        consumed <= 1'b1;
      else if (!gate_open)
        consumed <= 1'b0;
    end
  end
endmodule
