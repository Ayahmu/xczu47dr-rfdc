`timescale 1ns/1ps
// Regression for the >START_WATERMARK finite-descriptor underflow ceiling.
//
// The DDR reader keeps a single one-frame AXI burst in flight, so its sustained
// refill rate is far below the DAC consumption rate.  Opening the DAC gate at
// START_WATERMARK while the reader is still filling drains the head-start buffer
// and underflows any finite descriptor once it outruns the reader (measured
// hardware ceiling ~875 beats at a 768 watermark).
//
// Fix under test (waveform_playback_path.v): a descriptor that FITS in the FIFO
// (total_beats <= FIFO_DEPTH_BEATS) is FULLY prefetched before the gate opens,
// so the DAC drains a static, fully-loaded FIFO the reader never has to feed.
// Only a descriptor larger than the FIFO falls back to the streaming watermark.
//
// This bench uses a small model (START_WATERMARK=4, FIFO_DEPTH_BEATS=8) and the
// common-store async-FIFO model.  It asserts, at the exact cycle the path first
// leaves PREFETCH:
//   * a fits-in-FIFO descriptor (total=6) leaves with prefetched==total and the
//     reader already done (full prefetch, no early open);
//   * an oversized descriptor (total=10 > 8) leaves at the watermark with the
//     reader still busy (streaming path preserved).
module tb_waveform_prefetch_fits_full_load;
  localparam integer WM = 4;
  localparam integer CAP = 8;   // model FIFO capacity == DUT FIFO_DEPTH_BEATS

  reg ddr_clk=0; always #2 ddr_clk=~ddr_clk;
  reg dac_clk=0; always #5 dac_clk=~dac_clk;
  reg ddr_rst_n=0, dac_rst_n=0;
  reg begin_cmd=0, commit_cmd=0, play_cmd=0, pause_cmd=0, stop_cmd=0, abort_cmd=0;
  reg [63:0] descriptor_base=64'h0000_0000_0000_1000;
  reg [31:0] descriptor_total_beats=6;
  reg [7:0] descriptor_channel_mask=8'hff;
  reg [31:0] descriptor_loop_count=1;
  reg [31:0] descriptor_generation=1;
  reg [15:0] fifo_level_beats=0, fifo_free_beats=CAP;
  wire command_ready_ddr;
  wire [2047:0] fifo_write_data; wire fifo_write_valid; reg [7:0] fifo_write_ready=8'hff;
  wire fifo_write_last;
  wire fifo_clear_ddr;
  wire prefetch_safe_ddr, reader_busy_ddr, reader_done_ddr, reader_error_ddr;
  wire [31:0] reader_error_code_ddr; wire [63:0] reader_error_offset_ddr;
  wire [63:0] m_axi_araddr; wire [7:0] m_axi_arlen; wire m_axi_arvalid; reg m_axi_arready=1;
  reg [511:0] m_axi_rdata=0; reg [1:0] m_axi_rresp=0; reg m_axi_rvalid=0, m_axi_rlast=0;
  wire m_axi_rready;
  reg trigger_in=0; reg launch_sync=0; reg [2047:0] fifo_data=0; reg [7:0] fifo_valid=0; wire [7:0] fifo_read_ready;
  reg [7:0] dac_ready=8'hff; wire [2047:0] dac_data; wire [7:0] dac_valid;
  wire [7:0] dac_last; wire [255:0] dac_keep; wire [3:0] state_dac; wire dac_gate;
  wire [31:0] trigger_seen_count, trigger_dropped_count, trigger_fire_count;
  wire output_first_transfer, output_beat_fire, output_beat_last, output_underflow;
  wire [31:0] current_beat_dac, loop_position_dac, loop_count_dac, descriptor_generation_dac;
  wire [7:0] channel_mask_dac;
  wire [31:0] underflow_count_dac;

  waveform_playback_path #(.START_WATERMARK(WM), .FIFO_DEPTH_BEATS(CAP)) dut (.*);

  reg [2047:0] fifo_mem [0:15];
  integer wr_total = 0, fifo_rd = 0;
  wire [15:0] fifo_count = wr_total[15:0] - fifo_rd[15:0];
  integer issued=0, burst_beats=0, return_beat=0, fired=0;
  reg responding=1;
  always @* begin
    fifo_level_beats = fifo_count;
    // Model a FIFO of exactly CAP beats so an oversized descriptor backpressures
    // the reader (never completes) and only the watermark can release PREFETCH.
    fifo_free_beats = (fifo_count >= CAP) ? 16'd0 : (CAP - fifo_count);
  end

  localparam integer PUB_LATENCY = 8;
  reg [15:0] pub_pipe [0:PUB_LATENCY-1];
  integer pi;
  initial for (pi = 0; pi < PUB_LATENCY; pi = pi + 1) pub_pipe[pi] = 16'd0;
  always @(posedge dac_clk) if (dac_rst_n) begin
    pub_pipe[0] <= wr_total[15:0];
    for (pi = 1; pi < PUB_LATENCY; pi = pi + 1) pub_pipe[pi] <= pub_pipe[pi-1];
  end
  wire [15:0] pub_visible = pub_pipe[PUB_LATENCY-1];
  wire [15:0] pub_avail = (pub_visible > fifo_rd[15:0]) ? pub_visible - fifo_rd[15:0] : 16'd0;

  // AR acceptance throttle: the reader must take LONGER to fill from the
  // watermark to total than the DAC-side publish-settle window (16 dac cycles),
  // otherwise a zero-latency model would finish prefetch before the gate could
  // ever open early and the watermark-vs-full-load distinction would be
  // invisible.  ~30 ddr cycles/beat (~15 dac cycles) keeps the reader visibly
  // busy through the settle window on the OLD (watermark) logic.
  integer ar_hold=0;
  always @(posedge ddr_clk) if (ddr_rst_n) begin
    if (ar_hold != 0) ar_hold <= ar_hold - 1;
    if (m_axi_arvalid && m_axi_arready) begin
      issued <= issued + 1;
      burst_beats <= m_axi_arlen + 1;
      return_beat <= 0;
      ar_hold <= 30;
    end
    if (fifo_write_valid && (&fifo_write_ready)) begin
      fifo_mem[wr_total[3:0]] <= fifo_write_data;
      wr_total <= wr_total + 1;
    end
  end
  always @* m_axi_arready = (ar_hold == 0);

  always @(posedge dac_clk) if (dac_rst_n) begin
    if (pub_avail != 0) begin
      fifo_data <= fifo_mem[fifo_rd[3:0]];
      fifo_valid <= 8'hff;
    end else begin
      fifo_data <= 0;
      fifo_valid <= 0;
    end
    if (|fifo_read_ready) begin
      if (pub_avail == 0) $fatal(1, "FIFO underflow in test model");
      fifo_rd <= fifo_rd + 1;
    end
    if (output_beat_fire) fired <= fired + 1;
  end

  always @(negedge ddr_clk) begin
    if (responding && issued != 0 && burst_beats != 0) begin
      m_axi_rvalid = 1'b1;
      m_axi_rlast = return_beat == burst_beats-1;
      for (integer ch=0; ch<8; ch=ch+1)
        m_axi_rdata[ch*64 +: 64] = ((issued-1)*16 + return_beat*8 + ch);
    end else begin
      m_axi_rvalid = 1'b0; m_axi_rlast = 1'b0;
    end
    if (m_axi_rvalid && m_axi_rready) begin
      if (m_axi_rlast) begin issued=issued-1; burst_beats=0; return_beat=0; end
      else return_beat = return_beat + 1;
    end
  end

  task ddr_tick(input integer n); begin repeat(n) @(negedge ddr_clk); end endtask
  task dac_tick(input integer n); begin repeat(n) @(negedge dac_clk); end endtask
  task pulse_begin; begin @(negedge ddr_clk); begin_cmd=1; @(negedge ddr_clk); begin_cmd=0; end endtask
  task pulse_commit; begin @(negedge ddr_clk); commit_cmd=1; @(negedge ddr_clk); commit_cmd=0; end endtask
  task pulse_abort; begin @(negedge ddr_clk); abort_cmd=1; @(negedge ddr_clk); abort_cmd=0; end endtask

  // Capture prefetched-count and reader busy at the FIRST PREFETCH exit.
  reg [3:0] prev=4'hf;
  integer exit_prefetched=-1, exit_busy=-1;
  reg captured=0;
  always @(posedge dac_clk) begin
    if (prev == 4'd3 && state_dac != 4'd3 && !captured) begin
      captured <= 1'b1;
      exit_prefetched <= dut.prefetched_beats_ddr;
      exit_busy <= reader_busy_ddr;
    end
    prev <= state_dac;
  end

  task reset_between; begin
    pulse_abort; dac_tick(6); ddr_tick(6);
    captured=0; exit_prefetched=-1; exit_busy=-1;
    fired=0; wr_total=0; fifo_rd=0; issued=0; burst_beats=0; return_beat=0;
    ddr_rst_n=0; dac_rst_n=0; ddr_tick(3); dac_tick(3);
    dac_rst_n=1; ddr_rst_n=1; dac_tick(3);
  end endtask

  // A descriptor that fits in the FIFO must FULLY prefetch (reader done) before
  // the gate opens, then drain every beat.  tb is the total; it must be > WM
  // (so the old watermark logic would have opened early) and <= CAP.
  task run_fits(input integer tb); begin
    descriptor_total_beats = tb;
    pulse_begin; pulse_commit;
    wait(state_dac == 4'd4 || state_dac == 4'd5);  // left PREFETCH
    dac_tick(3);   // let the posedge capture of the PREFETCH-exit values commit
    if (exit_prefetched != tb)
      $fatal(1, "FITS(%0d): gate released before full prefetch: prefetched=%0d (want %0d)", tb, exit_prefetched, tb);
    if (exit_busy != 0)
      $fatal(1, "FITS(%0d): reader still busy at gate release (want done): busy=%0d", tb, exit_busy);
    dac_tick(12);
    @(negedge dac_clk); launch_sync=1; @(negedge dac_clk); launch_sync=0;
    wait(state_dac == 4'd7 || state_dac == 4'd8);
    if (state_dac == 4'd8) $fatal(1, "FITS(%0d): entered ERROR", tb);
    if (fired != tb) $fatal(1, "FITS(%0d): did not drain fully: fired=%0d", tb, fired);
  end endtask

  initial begin
    ddr_tick(3); dac_tick(3);
    dac_rst_n=1; ddr_rst_n=1; dac_tick(3);

    // Phase 1a: mid-range fit (WM < tb < CAP) — the common 769..1023 regime.
    run_fits(6);
    reset_between;
    // Phase 1b: fit at the EXACT FIFO depth (tb == CAP == FIFO_DEPTH_BEATS).
    // This is the highest-risk case flagged in review: full prefetch of a
    // max-size descriptor must complete (reader reaches done) and not hang.
    run_fits(CAP);
    reset_between;

    // Phase 2: oversized descriptor (> CAP) keeps the streaming watermark.
    descriptor_total_beats = 10;  // > CAP(8): must stream, release at watermark
    pulse_begin; pulse_commit;
    wait(state_dac == 4'd4 || state_dac == 4'd5);
    dac_tick(3);   // let the posedge capture of the PREFETCH-exit values commit
    if (exit_prefetched > CAP)
      $fatal(1, "STREAM: released above FIFO capacity: prefetched=%0d", exit_prefetched);
    if (exit_prefetched < WM)
      $fatal(1, "STREAM: released below watermark: prefetched=%0d (want >= %0d)", exit_prefetched, WM);
    if (exit_busy != 1)
      $fatal(1, "STREAM: reader not busy at watermark release (streaming path lost): busy=%0d", exit_busy);

    $display("PASS: fits-in-FIFO fully prefetches; oversized keeps the streaming watermark");
    $finish;
  end
  initial begin #300000; $fatal(1, "timeout state=%0d prefetched=%0d busy=%b fired=%0d",
                                state_dac, exit_prefetched, reader_busy_ddr, fired); end
endmodule
