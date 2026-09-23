`timescale 1ns/1ps

// Adapts the eight physical AXIS FIFOs to the descriptor's channel mask.
//
// The DDR reader emits one complete 512-bit interleaved frame, but a disabled
// DAC lane is not part of the playback contract.  Disabled lanes therefore
// accept no FIFO write (fifo_valid_lane=0), are treated as ready by the reader
// (fifo_ready_path=1), and are excluded from the reader credit.  This prevents
// an intentionally disabled lane from filling and stopping a long
// active-channel waveform.  The DAC stream supplies zero samples for disabled
// lanes, so omitting their FIFO storage is safe and deterministic.
//
// reader_credit reports the REAL write-side free depth so the DDR reader can
// pipeline large, multi-frame bursts instead of one 256-byte frame at a time
// (the single-frame 0/1 credit throttled the reader to ~1/8 of the DAC rate and
// underflowed any streaming descriptor past ~875 beats).  The 8-lane saturate +
// max-reduction + subtract is 29 logic levels, far too deep for the 300 MHz DDR
// clock in one cycle, so reader_credit is produced by a THREE-STAGE pipeline
// (per-lane masked level -> max -> FIFO_DEPTH-max).  A credit that lags a few
// cycles is safe: it is conservative, free space changes slowly relative to the
// pipeline depth, and the reader's own in-flight `reserved` counter debits
// reservations against it.  fifo_ready_path/fifo_valid_lane/min_level/min_free
// stay combinational for the per-cycle frame handshake and status.
module waveform_fifo_mask_adapter #(
    parameter integer FIFO_DEPTH = 1024
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [7:0]   channel_mask,
    input  wire         reader_valid,
    input  wire [7:0]   fifo_ready_actual,
    input  wire [255:0] fifo_wr_counts,
    output reg  [7:0]   fifo_ready_path,
    output reg  [7:0]   fifo_valid_lane,
    output reg  [15:0]  min_level,
    output reg  [15:0]  min_free,
    output wire [15:0]  reader_credit
);
  localparam integer COUNT_W = (FIFO_DEPTH < 1) ? 1 : $clog2(FIFO_DEPTH + 1);
  localparam [COUNT_W-1:0] FIFO_DEPTH_VALUE = FIFO_DEPTH;

  integer ch;
  reg have_active;
  reg [COUNT_W-1:0] level_value;
  reg [COUNT_W-1:0] level_min_value;
  reg [COUNT_W-1:0] level_max_value;
  reg [COUNT_W-1:0] free_min_value;

  // Per-lane masked, saturated level presented to the credit pipeline: a
  // disabled lane contributes 0 so it never becomes the max (and thus never
  // reduces the reported free depth).
  reg [COUNT_W-1:0] masked_level_c [0:7];
  reg have_active_c;

  always @* begin
    fifo_ready_path = 8'h00;
    fifo_valid_lane = 8'h00;
    have_active = 1'b0;
    level_min_value = FIFO_DEPTH_VALUE;
    level_max_value = {COUNT_W{1'b0}};
    free_min_value = FIFO_DEPTH_VALUE;
    have_active_c = 1'b0;

    for (ch = 0; ch < 8; ch = ch + 1) begin
      fifo_ready_path[ch] = channel_mask[ch] ? fifo_ready_actual[ch] : 1'b1;
      fifo_valid_lane[ch] = reader_valid && channel_mask[ch];

      // Saturate the 32-bit XPM count into COUNT_W bits; an out-of-range value
      // pins to FIFO_DEPTH rather than wrapping into false free credit.
      if (|fifo_wr_counts[ch*32 + COUNT_W +: (32-COUNT_W)] ||
          fifo_wr_counts[ch*32 +: COUNT_W] >= FIFO_DEPTH_VALUE)
        level_value = FIFO_DEPTH_VALUE;
      else
        level_value = fifo_wr_counts[ch*32 +: COUNT_W];

      // Masked level for the credit pipeline (0 for disabled lanes).
      masked_level_c[ch] = channel_mask[ch] ? level_value : {COUNT_W{1'b0}};

      if (channel_mask[ch]) begin
        if (!have_active || level_value < level_min_value)
          level_min_value = level_value;
        if (!have_active || level_value > level_max_value)
          level_max_value = level_value;
        have_active = 1'b1;
        have_active_c = 1'b1;
      end
    end

    // Combinational status outputs (not on the 300 MHz AR-reservation path).
    if (!have_active) begin
      min_level = 16'd0;
      min_free = 16'd0;
    end else begin
      free_min_value = FIFO_DEPTH_VALUE - level_max_value;
      min_level = {{(16-COUNT_W){1'b0}}, level_min_value};
      min_free = {{(16-COUNT_W){1'b0}}, free_min_value};
    end
  end

  // ---- four-stage reader_credit pipeline ----
  // The 8-way max reduction is split across two register stages (pairwise then
  // final) so no stage carries more than a couple of 11-bit compare levels; a
  // single-stage 8-way max was 1 LUT level too slow for the 300 MHz DDR clock.
  // Stage 1: register the eight masked, saturated per-lane levels.
  reg [COUNT_W-1:0] lvl_s1 [0:7];
  reg have_active_s1;
  // Stage 2: register the four pairwise maxima.
  reg [COUNT_W-1:0] pair_s2 [0:3];
  reg have_active_s2;
  // Stage 3: register the overall max active level.
  reg [COUNT_W-1:0] max_s3;
  reg have_active_s3;
  // Stage 4: register the free depth = FIFO_DEPTH - max.
  reg [COUNT_W-1:0] credit_s4;

  integer k;
  reg [COUNT_W-1:0] m01, m23;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (k = 0; k < 8; k = k + 1) lvl_s1[k] <= {COUNT_W{1'b0}};
      for (k = 0; k < 4; k = k + 1) pair_s2[k] <= {COUNT_W{1'b0}};
      have_active_s1 <= 1'b0; have_active_s2 <= 1'b0; have_active_s3 <= 1'b0;
      max_s3 <= {COUNT_W{1'b0}};
      credit_s4 <= {COUNT_W{1'b0}};
    end else begin
      // Stage 1
      for (k = 0; k < 8; k = k + 1) lvl_s1[k] <= masked_level_c[k];
      have_active_s1 <= have_active_c;
      // Stage 2: pairwise max (one compare level)
      pair_s2[0] <= (lvl_s1[1] > lvl_s1[0]) ? lvl_s1[1] : lvl_s1[0];
      pair_s2[1] <= (lvl_s1[3] > lvl_s1[2]) ? lvl_s1[3] : lvl_s1[2];
      pair_s2[2] <= (lvl_s1[5] > lvl_s1[4]) ? lvl_s1[5] : lvl_s1[4];
      pair_s2[3] <= (lvl_s1[7] > lvl_s1[6]) ? lvl_s1[7] : lvl_s1[6];
      have_active_s2 <= have_active_s1;
      // Stage 3: reduce the four pairs to one (two compare levels)
      m01 = (pair_s2[1] > pair_s2[0]) ? pair_s2[1] : pair_s2[0];
      m23 = (pair_s2[3] > pair_s2[2]) ? pair_s2[3] : pair_s2[2];
      max_s3 <= (m23 > m01) ? m23 : m01;
      have_active_s3 <= have_active_s2;
      // Stage 4: free depth
      credit_s4 <= have_active_s3 ? (FIFO_DEPTH_VALUE - max_s3) : {COUNT_W{1'b0}};
    end
  end
  assign reader_credit = {{(16-COUNT_W){1'b0}}, credit_s4};
endmodule
