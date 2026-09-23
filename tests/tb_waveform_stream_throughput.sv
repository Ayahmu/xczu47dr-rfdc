`timescale 1ns/1ps
// Regression for the streaming-descriptor throughput fix (Plan B).
//
// A descriptor larger than the FIFO must STREAM: the DAC gate opens at the
// watermark while the DDR reader keeps refilling during playback.  The reader
// must therefore sustain throughput ABOVE the DAC consumption rate.  A
// single-outstanding one-frame reader is latency-bound (~1/8 of the DAC rate)
// and underflows; the production reader pipelines page-sized bursts with
// several transactions in flight and keeps up.
//
// This bench drives a FAITHFUL in-order AXI read model with real per-burst
// latency (LATENCY cycles from AR accept to first data) and back-to-back data
// for transactions already in flight, so the reader's outstanding depth and
// burst size actually determine whether it keeps up.  Clock ratio is the
// hardware 6:1 (ddr 4 ns : dac 24 ns).  The DUT uses its DEFAULT reader
// configuration (production 16-frame / 4-outstanding), so reverting the reader
// to a single-outstanding one-frame burst makes this test underflow and fail.
module tb_waveform_stream_throughput;
  // FIFO/watermark scaled down; descriptor exceeds the FIFO so it must stream.
  localparam integer CAP = 64;
  localparam integer WM  = 48;
  localparam integer TOTAL = 200;   // > CAP -> streaming
  localparam integer LATENCY = 40;  // ddr cycles from AR accept to first R beat

  reg ddr_clk=0; always #2 ddr_clk=~ddr_clk;   // 250 MHz model (period 4 ns)
  reg dac_clk=0; always #12 dac_clk=~dac_clk;  // 6:1 ratio (period 24 ns)
  reg ddr_rst_n=0, dac_rst_n=0;
  reg begin_cmd=0, commit_cmd=0, play_cmd=0, pause_cmd=0, stop_cmd=0, abort_cmd=0;
  reg [63:0] descriptor_base=64'h0000_0000_0000_1000;
  reg [31:0] descriptor_total_beats=TOTAL;
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

  // DEFAULT (production) reader config: BURST_FRAMES=16, MAX_OUTSTANDING=4.
  waveform_playback_path #(.FIFO_DEPTH_BEATS(CAP), .START_WATERMARK(WM)) dut (.*);

  // ---- write side (reader -> common FIFO store) ----
  integer wr_total = 0, fifo_rd = 0, fired = 0;
  reg [2047:0] fifo_mem [0:255];
  always @* begin
    fifo_level_beats = (wr_total - fifo_rd);
    fifo_free_beats = CAP - (wr_total - fifo_rd);   // real write-side free depth
  end

  // ---- FIFO publication (DAC-side visibility lag) ----
  localparam integer PUB_LATENCY = 4;
  reg [15:0] pub_pipe [0:PUB_LATENCY-1];
  integer pi;
  initial for (pi=0; pi<PUB_LATENCY; pi=pi+1) pub_pipe[pi]=0;
  always @(posedge dac_clk) if (dac_rst_n) begin
    pub_pipe[0] <= wr_total[15:0];
    for (pi=1; pi<PUB_LATENCY; pi=pi+1) pub_pipe[pi] <= pub_pipe[pi-1];
  end
  wire [15:0] pub_visible = pub_pipe[PUB_LATENCY-1];
  wire [15:0] pub_avail = (pub_visible > fifo_rd[15:0]) ? pub_visible - fifo_rd[15:0] : 16'd0;

  // ---- in-order AXI read model with per-burst latency + pipelining ----
  // Each accepted burst gets its own latency countdown that starts at accept
  // time and ticks every ddr cycle, so a burst issued while an earlier one is
  // still streaming has its latency hidden -> outstanding depth buys throughput.
  localparam integer QD = 8;
  integer q_len [0:QD-1];
  integer q_lat [0:QD-1];
  reg     q_occ [0:QD-1];
  integer qhead=0, qtail=0, qcount=0;
  integer beats_left=0, serving=0;
  integer qi;
  initial for (qi=0; qi<QD; qi=qi+1) begin q_occ[qi]=0; q_len[qi]=0; q_lat[qi]=0; end

  always @(posedge ddr_clk) if (ddr_rst_n) begin
    // tick every occupied slot's latency
    for (qi=0; qi<QD; qi=qi+1)
      if (q_occ[qi] && q_lat[qi] > 0) q_lat[qi] <= q_lat[qi] - 1;
    // accept AR
    if (m_axi_arvalid && m_axi_arready) begin
      if (m_axi_araddr[7:0] != 0 || m_axi_araddr[11:0] + (m_axi_arlen+1)*64 > 4096)
        $fatal(1, "reader issued invalid/page-crossing burst addr=%h len=%0d", m_axi_araddr, m_axi_arlen+1);
      if (qcount >= QD) $fatal(1, "AXI model burst queue overflow (reader exceeded MAX_OUTSTANDING model)");
      q_len[qtail] <= m_axi_arlen + 1;
      q_lat[qtail] <= LATENCY;
      q_occ[qtail] <= 1'b1;
      qtail <= (qtail+1)%QD;
      qcount <= qcount + 1;
    end
    // capture reader frame writes into the common store
    if (fifo_write_valid && (&fifo_write_ready)) begin
      fifo_mem[wr_total[7:0]] <= fifo_write_data;
      wr_total <= wr_total + 1;
    end
  end

  // R data engine (negedge drive, in order): serve head burst once its latency
  // countdown has elapsed; stream its beats back-to-back.
  always @(negedge ddr_clk) begin
    if (!ddr_rst_n) begin
      m_axi_rvalid = 0; m_axi_rlast = 0; serving = 0; beats_left = 0;
    end else begin
      if (!serving && qcount != 0 && q_occ[qhead] && q_lat[qhead] == 0) begin
        serving = 1; beats_left = q_len[qhead];
      end
      if (serving && beats_left != 0) begin
        m_axi_rvalid = 1;
        m_axi_rlast = (beats_left == 1);
        m_axi_rdata = m_axi_rdata + 1; // arbitrary non-zero payload
      end else begin
        m_axi_rvalid = 0; m_axi_rlast = 0;
      end
      if (m_axi_rvalid && m_axi_rready) begin
        beats_left = beats_left - 1;
        if (beats_left == 0) begin
          q_occ[qhead] = 0;
          qhead = (qhead+1)%QD;
          qcount = qcount - 1;
          serving = 0;
        end
      end
    end
  end

  // ---- DAC read side: always ready, drains one frame per dac cycle ----
  always @(posedge dac_clk) if (dac_rst_n) begin
    if (pub_avail != 0) begin fifo_data <= fifo_mem[fifo_rd[7:0]]; fifo_valid <= 8'hff; end
    else begin fifo_data <= 0; fifo_valid <= 0; end
    if (|fifo_read_ready) begin
      if (pub_avail == 0) $fatal(1, "FIFO underflow in test model");
      fifo_rd <= fifo_rd + 1;
    end
    if (output_beat_fire) fired <= fired + 1;
  end

  task ddr_tick(input integer n); begin repeat(n) @(negedge ddr_clk); end endtask
  task dac_tick(input integer n); begin repeat(n) @(negedge dac_clk); end endtask
  task pulse_begin; begin @(negedge ddr_clk); begin_cmd=1; @(negedge ddr_clk); begin_cmd=0; end endtask
  task pulse_commit; begin @(negedge ddr_clk); commit_cmd=1; @(negedge ddr_clk); commit_cmd=0; end endtask

  always @(posedge dac_clk) begin
    if (state_dac == 4'd8)
      $fatal(1, "STREAM underflow/fault: state=ERROR beat=%0d underflow=%0d fifo_wr=%0d (reader could not sustain the DAC rate)",
             current_beat_dac, underflow_count_dac, wr_total - fifo_rd);
  end

  initial begin
    ddr_tick(3); dac_tick(3);
    dac_rst_n=1; ddr_rst_n=1; dac_tick(3);

    pulse_begin; pulse_commit;
    // Streaming descriptor: gate opens at the watermark (reader still busy).
    wait(state_dac == 4'd4);   // WAIT_TRIGGER
    // Launch and require the whole 200-beat descriptor to drain with no fault.
    dac_tick(4);
    @(negedge dac_clk); launch_sync=1; @(negedge dac_clk); launch_sync=0;
    wait(state_dac == 4'd7 || state_dac == 4'd8);
    if (state_dac == 4'd8)
      $fatal(1, "STREAM entered ERROR (underflow) at beat=%0d", current_beat_dac);
    if (fired != TOTAL)
      $fatal(1, "STREAM did not drain fully: fired=%0d want %0d", fired, TOTAL);
    if (underflow_count_dac != 0)
      $fatal(1, "STREAM drained but reported underflow_count=%0d", underflow_count_dac);

    $display("PASS: streaming descriptor larger than the FIFO drains with no underflow");
    $finish;
  end
  initial begin #4000000; $fatal(1, "timeout state=%0d fired=%0d wr=%0d busy=%b", state_dac, fired, wr_total-fifo_rd, reader_busy_ddr); end
endmodule
