`timescale 1ns/1ps
// Regression for two hardware-observed playback defects:
//
//  1. loop_count > 1 must replay the descriptor seamlessly.  The DAC gate may
//     not close and no FIFO clear/refill may happen at a loop boundary; every
//     output frame must carry the expected descriptor frame in order.
//  2. STOP/PAUSE while PLAYING or WAIT_TRIGGER must land in READY, never in
//     the sticky ERROR state, and a following PLAY must replay from beat 0.
//     The FIFO model here honours fifo_clear_ddr like the real async-reset
//     FIFOs do: the DAC side loses its data immediately.  A clear issued before
//     the DAC FSM has left PLAYING is therefore seen as an underflow fault.
//  3. A session that underflowed into ERROR must be recoverable by ABORT even
//     when the reader is left holding a frame the full FIFO will not accept.
//
// DDR/DAC clocks keep the production 6:1 ratio and the AXI model returns data
// after a fixed latency comparable to the hardware DDR round trip.
module tb_waveform_loop_and_stop;
  reg ddr_clk=0; always #2 ddr_clk=~ddr_clk;     // 250 MHz
  reg dac_clk=0; always #12 dac_clk=~dac_clk;    // ~42 MHz (6:1)
  reg ddr_rst_n=0, dac_rst_n=0;
  reg begin_cmd=0, commit_cmd=0, play_cmd=0, pause_cmd=0, stop_cmd=0, abort_cmd=0;
  localparam [63:0] BASE = 64'h0000_0000_0010_0000;
  reg [63:0] descriptor_base=BASE;
  reg [31:0] descriptor_total_beats=16;
  reg [7:0] descriptor_channel_mask=8'h01;
  reg [31:0] descriptor_loop_count=1;
  reg [31:0] descriptor_generation=1;
  reg [15:0] fifo_level_beats=0, fifo_free_beats=1024;
  wire command_ready_ddr;
  wire [2047:0] fifo_write_data; wire fifo_write_valid; reg [7:0] fifo_write_ready;
  wire fifo_write_last, fifo_clear_ddr;
  wire prefetch_safe_ddr, reader_busy_ddr, reader_done_ddr, reader_error_ddr;
  wire [31:0] reader_error_code_ddr; wire [63:0] reader_error_offset_ddr;
  wire [63:0] m_axi_araddr; wire [7:0] m_axi_arlen; wire m_axi_arvalid; reg m_axi_arready=1;
  reg [511:0] m_axi_rdata=0; reg [1:0] m_axi_rresp=0; reg m_axi_rvalid=0, m_axi_rlast=0;
  wire m_axi_rready;
  reg trigger_in=0, launch_sync=0;
  reg [2047:0] fifo_data=0; reg [7:0] fifo_valid=0; wire [7:0] fifo_read_ready;
  reg [7:0] dac_ready=8'hff; wire [2047:0] dac_data; wire [7:0] dac_valid;
  wire [7:0] dac_last; wire [255:0] dac_keep; wire [3:0] state_dac; wire dac_gate;
  wire [31:0] trigger_seen_count, trigger_dropped_count, trigger_fire_count;
  wire output_first_transfer, output_beat_fire, output_beat_last, output_underflow;
  wire [31:0] current_beat_dac, loop_position_dac, loop_count_dac, descriptor_generation_dac;
  wire [7:0] channel_mask_dac;
  wire [31:0] underflow_count_dac;

  waveform_playback_path dut (.*);

  localparam [3:0] S_IDLE=0, S_READY=2, S_PREFETCH=3, S_WAIT=4, S_PLAYING=5, S_DONE=7, S_ERROR=8;

  // ---------------------------------------------------------------- AXI slave
  // In-order read slave with a fixed AR->first-R latency.  Each 64-byte beat
  // carries its own byte address in every lane, so an assembled frame's lane
  // word 0 equals the frame's DDR address.
  localparam integer LATENCY = 40;
  reg [63:0] q_addr [0:63]; reg [8:0] q_len [0:63]; integer q_ready_at [0:63];
  integer q_head=0, q_tail=0, q_beat=0, now=0;
  always @(posedge ddr_clk) now <= now + 1;
  always @(posedge ddr_clk) if (ddr_rst_n && m_axi_arvalid && m_axi_arready) begin
    if (m_axi_araddr[7:0] != 0 || m_axi_araddr[11:0] + (m_axi_arlen+1)*64 > 4096)
      $fatal(1, "invalid burst addr=%h len=%0d", m_axi_araddr, m_axi_arlen+1);
    if (m_axi_araddr < BASE || m_axi_araddr + (m_axi_arlen+1)*64 > BASE + descriptor_total_beats*256)
      $fatal(1, "burst outside descriptor addr=%h len=%0d", m_axi_araddr, m_axi_arlen+1);
    q_addr[q_tail%64] <= m_axi_araddr; q_len[q_tail%64] <= m_axi_arlen + 1;
    q_ready_at[q_tail%64] <= now + LATENCY; q_tail <= q_tail + 1;
  end
  always @(negedge ddr_clk) begin
    if (m_axi_rvalid && m_axi_rready) begin
      if (m_axi_rlast) begin q_head = q_head + 1; q_beat = 0; end
      else q_beat = q_beat + 1;
    end
    if (q_head != q_tail && now >= q_ready_at[q_head%64]) begin
      m_axi_rvalid = 1;
      m_axi_rlast = (q_beat == q_len[q_head%64] - 1);
      for (integer ch=0; ch<8; ch=ch+1) m_axi_rdata[ch*64 +: 64] = q_addr[q_head%64] + q_beat*64;
    end else begin
      m_axi_rvalid = 0; m_axi_rlast = 0;
    end
  end

  // -------------------------------------------------------------- FIFO model
  // One shared 1024-frame store for all lanes.  fifo_clear_ddr behaves like
  // the production asynchronous FIFO reset: contents vanish at once on both
  // sides and the DAC side sees no data.  A small publication delay models the
  // read-side pointer synchronizer.
  //
  // As in Top.v, the reader's free-space credit is not the live level: the
  // XPM write count, the mask adapter's four-stage max/subtract pipeline and
  // the Top.v timing register delay it by CREDIT_LAG DDR cycles, while
  // backpressure (tready) is the FIFO's own, immediate full flag.  Top.v's
  // lag is 6 cycles; the model uses 7 so the reader's hold has to cover more.
  localparam integer CREDIT_LAG = 7;
  reg [2047:0] mem [0:1023];
  integer wr=0, rd=0;
  integer pub0=0, pub1=0, pub2=0;
  reg [15:0] free_pipe [0:CREDIT_LAG-1];
  integer full_stalls=0;
  always @* begin
    fifo_level_beats = wr - rd;
    fifo_free_beats = free_pipe[CREDIT_LAG-1];
    fifo_write_ready = (wr - rd < 1024) ? 8'hff : 8'h00;
  end
  initial for (integer i=0; i<CREDIT_LAG; i=i+1) free_pipe[i] = 16'd1024;
  always @(posedge ddr_clk) begin
    free_pipe[0] <= 1024 - (wr - rd);
    for (integer i=1; i<CREDIT_LAG; i=i+1) free_pipe[i] <= free_pipe[i-1];
  end
  always @(posedge ddr_clk) if (ddr_rst_n) begin
    if (fifo_write_valid && !(&fifo_write_ready)) full_stalls = full_stalls + 1;
    if (fifo_clear_ddr) begin
      wr = 0; rd = 0; pub0 = 0; pub1 = 0; pub2 = 0;
    end else if (fifo_write_valid && (&fifo_write_ready)) begin
      if (wr - rd >= 1024) $fatal(1, "FIFO overflow in model");
      mem[wr % 1024] <= fifo_write_data;
      wr = wr + 1;
    end
  end
  always @(posedge dac_clk) if (dac_rst_n) begin
    pub2 <= pub1; pub1 <= pub0; pub0 <= wr;
  end
  wire [31:0] visible = (pub2 > rd) ? pub2 - rd : 0;
  always @* begin
    fifo_valid = (visible != 0) ? 8'hff : 8'h00;
    fifo_data = (visible != 0) ? mem[rd % 1024] : 2048'd0;
  end

  // --------------------------------------------------------- output checking
  integer fired=0, err_seen=0, gate_drops=0, expect_frame=0;
  reg prev_gate=0;
  always @(posedge dac_clk) if (dac_rst_n) begin
    if (|fifo_read_ready) begin
      if (visible == 0) $fatal(1, "consumed an empty FIFO");
      rd <= rd + 1;
    end
    if (output_beat_fire) begin
      if (dac_data[63:0] !== BASE + (expect_frame % descriptor_total_beats) * 256)
        $fatal(1, "frame %0d carried %h, expected %h", fired, dac_data[63:0],
               BASE + (expect_frame % descriptor_total_beats) * 256);
      fired <= fired + 1; expect_frame <= expect_frame + 1;
    end
    if (state_dac == S_ERROR) err_seen <= err_seen + 1;
    if (prev_gate && !dac_gate && state_dac == S_PREFETCH) gate_drops <= gate_drops + 1;
    prev_gate <= dac_gate;
  end

  task ddr_tick(input integer n); begin repeat(n) @(negedge ddr_clk); end endtask
  task dac_tick(input integer n); begin repeat(n) @(negedge dac_clk); end endtask
  task pulse_begin;  begin @(negedge ddr_clk); begin_cmd=1;  @(negedge ddr_clk); begin_cmd=0;  end endtask
  task pulse_commit; begin @(negedge ddr_clk); commit_cmd=1; @(negedge ddr_clk); commit_cmd=0; end endtask
  task pulse_play;   begin @(negedge ddr_clk); play_cmd=1;   @(negedge ddr_clk); play_cmd=0;   end endtask
  task pulse_pause;  begin @(negedge ddr_clk); pause_cmd=1;  @(negedge ddr_clk); pause_cmd=0;  end endtask
  task pulse_stop;   begin @(negedge ddr_clk); stop_cmd=1;   @(negedge ddr_clk); stop_cmd=0;   end endtask
  task pulse_abort;  begin @(negedge ddr_clk); abort_cmd=1;  @(negedge ddr_clk); abort_cmd=0;  end endtask
  task load(input integer frames, input integer loops); begin
    descriptor_total_beats = frames; descriptor_loop_count = loops;
    descriptor_generation = descriptor_generation + 1;
    pulse_begin; ddr_tick(20); pulse_commit;
  end endtask
  task reset_counts; begin
    @(negedge dac_clk); fired = 0; expect_frame = 0; gate_drops = 0;
  end endtask
  task wait_state(input [3:0] s, input integer limit, input [255:0] what); begin : w
    integer i;
    for (i = 0; i < limit; i = i + 1) begin
      @(negedge dac_clk);
      if (state_dac == s) disable w;
    end
    $fatal(1, "timeout waiting for %0s (state=%0d)", what, state_dac);
  end endtask
  task expect_no_error(input [255:0] what); begin
    if (err_seen != 0) $fatal(1, "%0s entered ERROR (%0d cycles), underflows=%0d", what, err_seen, underflow_count_dac);
  end endtask

  initial begin
    ddr_tick(4); ddr_rst_n=1; dac_rst_n=1; dac_tick(4);

    // ---- 1. seamless loop: 16 frames x 6 passes, software PLAY ----------
    reset_counts;
    load(16, 6);
    wait_state(S_WAIT, 20000, "loop prefetch");
    pulse_play;
    wait_state(S_DONE, 20000, "loop completion");
    expect_no_error("seamless loop");
    if (fired != 16*6) $fatal(1, "loop fired %0d frames, expected %0d", fired, 16*6);
    if (gate_drops != 0) $fatal(1, "DAC gate closed %0d times at loop boundaries", gate_drops);

    // ---- 2. STOP while PLAYING a descriptor that is already fully loaded --
    // 600 frames fit in the FIFO, so the reader is idle while the DAC drains;
    // any FIFO clear that does not wait for the DAC FSM is immediate.
    reset_counts;
    load(600, 1);
    wait_state(S_WAIT, 40000, "600-frame prefetch");
    pulse_play;
    wait_state(S_PLAYING, 200, "PLAYING");
    dac_tick(100);
    pulse_stop;
    dac_tick(60);
    expect_no_error("STOP while PLAYING");
    if (state_dac != S_READY) $fatal(1, "STOP while PLAYING left state %0d, expected READY", state_dac);
    // PLAY after STOP must re-prefetch and replay the whole descriptor.
    reset_counts;
    pulse_play;
    wait_state(S_DONE, 40000, "replay after STOP");
    expect_no_error("replay after STOP");
    if (fired != 600) $fatal(1, "replay after STOP fired %0d frames, expected 600", fired);

    // ---- 3. PAUSE while PLAYING a streaming loop, then resume ------------
    reset_counts;
    load(64, 1000);
    wait_state(S_WAIT, 40000, "loop prefetch for PAUSE");
    pulse_play;
    wait_state(S_PLAYING, 200, "PLAYING before PAUSE");
    dac_tick(300);
    pulse_pause;
    dac_tick(60);
    expect_no_error("PAUSE while PLAYING");
    if (state_dac != S_READY) $fatal(1, "PAUSE left state %0d, expected READY", state_dac);
    reset_counts;
    pulse_play;
    wait_state(S_PLAYING, 40000, "resume after PAUSE");
    dac_tick(500);
    expect_no_error("resume after PAUSE");
    if (fired < 400) $fatal(1, "resume after PAUSE produced only %0d frames", fired);

    // ---- 4. STOP while WAIT_TRIGGER ---------------------------------------
    // This ABORT lands while section 3 is still PLAYING.  ABORT clears the
    // FIFOs in the DDR domain without waiting for the DAC FSM, so the FSM may
    // spend a cycle in ERROR before the ABORT reaches it; only the STOP below
    // is under test.
    pulse_abort; dac_tick(40);
    err_seen = 0;
    reset_counts;
    load(32, 1);
    wait_state(S_WAIT, 20000, "WAIT_TRIGGER for STOP");
    pulse_stop;
    dac_tick(60);
    expect_no_error("STOP while WAIT_TRIGGER");
    if (state_dac != S_READY) $fatal(1, "STOP in WAIT_TRIGGER left state %0d", state_dac);

    // ---- 5. underflow ERROR, ABORT, then a new session --------------------
    // One-frame passes make every AR a single latency-bound frame, so the
    // reader falls behind the DAC and the session underflows into ERROR.  The
    // DAC then stops draining while the reader keeps filling the FIFO up to
    // its lagged credit, which can leave it holding a frame the full FIFO
    // will not accept.  ABORT must still retire the reader and clear the
    // FIFOs, or every later session waits in PREFETCH forever.
    pulse_abort; dac_tick(40);
    reset_counts;
    load(1, 100000);
    wait_state(S_WAIT, 40000, "one-frame loop prefetch");
    pulse_play;
    wait_state(S_ERROR, 400000, "one-frame loop underflow");
    ddr_tick(20000);
    // Every reserved frame must fit: a frame presented to a full FIFO means
    // the reader reserved against credit the FIFO did not have.
    if (full_stalls != 0)
      $fatal(1, "reader presented a frame to a full FIFO on %0d cycles (over-reserved credit)", full_stalls);
    pulse_abort; dac_tick(40);
    err_seen = 0;
    reset_counts;
    load(16, 1);
    wait_state(S_WAIT, 20000, "prefetch after ERROR + ABORT");
    pulse_play;
    wait_state(S_DONE, 20000, "playback after ERROR + ABORT");
    expect_no_error("playback after ERROR + ABORT");
    if (fired != 16) $fatal(1, "playback after ERROR + ABORT fired %0d frames, expected 16", fired);

    $display("tb_waveform_loop_and_stop PASS");
    $finish;
  end
  initial begin #20_000_000; $fatal(1, "global timeout state=%0d", state_dac); end
endmodule
