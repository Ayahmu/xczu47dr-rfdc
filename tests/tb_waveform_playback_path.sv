`timescale 1ns/1ps
// End-to-end unit test for the descriptor -> reader -> FIFO -> DAC path.
// The DDR and RFDC endpoints are modeled; no internal state is forced.
module tb_waveform_playback_path;
  reg ddr_clk=0; always #2 ddr_clk=~ddr_clk;
  reg dac_clk=0; always #5 dac_clk=~dac_clk;
  reg ddr_rst_n=0, dac_rst_n=0;
  reg begin_cmd=0, commit_cmd=0, play_cmd=0, pause_cmd=0, stop_cmd=0, abort_cmd=0;
  reg [63:0] descriptor_base=64'h0000_0000_0000_1000;
  reg [31:0] descriptor_total_beats=4;
  reg [7:0] descriptor_channel_mask=8'hff;
  reg [31:0] descriptor_loop_count=2;
  reg [31:0] descriptor_generation=1;
  reg [15:0] fifo_level_beats=0, fifo_free_beats=1024;
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

  waveform_playback_path dut (.*);

  // Eight independent async FIFOs are modelled as one common store: the DAC
  // stream always consumes all enabled lanes together, so a single occupancy
  // is sufficient to exercise the reader/DAC contract.
  reg [2047:0] fifo_mem [0:15];
  integer wr_total = 0, fifo_rd = 0;
  wire [15:0] fifo_count = wr_total[15:0] - fifo_rd[15:0];
  integer issued=0, burst_beats=0, return_beat=0, cycles=0, firsts=0, fired=0;
  reg responding=1;
  always @* begin
    fifo_level_beats = fifo_count;
    fifo_free_beats = 1024 - fifo_count;
  end

  // Async-FIFO publication model.
  //
  // The real axis_async_fifo_256 exposes only the WRITE-domain occupancy; the
  // DAC domain sees a word only after the FIFO's internal read-pointer
  // synchronizer has crossed the CDC.  Modelling that as a one-cycle
  // store-and-forward would hide the hazard this test exists to catch: a
  // controller that opens the DAC gate on the write-side prefetch level alone
  // starts playing before the DAC side has the data, and a short descriptor
  // then reports a false underflow.  PUB_LATENCY therefore makes the CDC
  // publication lag explicit.
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

  always @(posedge ddr_clk) if (ddr_rst_n) begin
    cycles <= cycles + 1;
    if (m_axi_arvalid && m_axi_arready) begin
      if (m_axi_araddr[7:0] != 0 || m_axi_araddr[11:0] + (m_axi_arlen+1)*64 > 4096)
        $fatal(1, "reader issued invalid burst addr=%h len=%0d", m_axi_araddr, m_axi_arlen+1);
      issued <= issued + 1;
      burst_beats <= m_axi_arlen + 1;
      return_beat <= 0;
    end
    if (fifo_write_valid && (&fifo_write_ready)) begin
      fifo_mem[wr_total[3:0]] <= fifo_write_data;
      wr_total <= wr_total + 1;
    end
  end

  always @(posedge dac_clk) if (dac_rst_n) begin
    if (pub_avail != 0) begin
      fifo_data <= fifo_mem[fifo_rd[3:0]];
      fifo_valid <= 8'hff;
    end else begin
      fifo_data <= 0;
      fifo_valid <= 0;
    end
    if (|fifo_read_ready) begin
      if (fifo_read_ready !== 8'hff) $fatal(1, "common frame did not consume all lanes: %b", fifo_read_ready);
      if (pub_avail == 0) $fatal(1, "FIFO underflow in test model");
      fifo_rd <= fifo_rd + 1;
    end
    if (output_first_transfer) firsts <= firsts + 1;
    if (output_beat_fire) fired <= fired + 1;
    if (state_dac == 4'd8) $fatal(1, "path entered ERROR code=%0d off=%h", reader_error_code_ddr, reader_error_offset_ddr);
  end

  always @(negedge ddr_clk) begin
    // Drive the AXI response for the following rising edge with blocking
    // assignments; the bus model must not move RLAST one cycle after RDATA.
    if (responding && issued != 0 && burst_beats != 0) begin
      m_axi_rvalid = 1'b1;
      m_axi_rlast = return_beat == burst_beats-1;
      for (integer ch=0; ch<8; ch=ch+1)
        m_axi_rdata[ch*64 +: 64] = ((issued-1)*16 + return_beat*8 + ch);
    end else begin
      m_axi_rvalid = 1'b0;
      m_axi_rlast = 1'b0;
    end
    if (m_axi_rvalid && m_axi_rready) begin
      if (m_axi_rlast) begin
        issued = issued - 1;
        burst_beats = 0;
        return_beat = 0;
      end else return_beat = return_beat + 1;
    end
  end

  task ddr_tick(input integer n); begin repeat(n) @(negedge ddr_clk); end endtask
  task dac_tick(input integer n); begin repeat(n) @(negedge dac_clk); end endtask
  task pulse_begin; begin @(negedge ddr_clk); begin_cmd=1; @(negedge ddr_clk); begin_cmd=0; end endtask
  task pulse_commit; begin @(negedge ddr_clk); commit_cmd=1; @(negedge ddr_clk); commit_cmd=0; end endtask
  task pulse_stop; begin @(negedge ddr_clk); stop_cmd=1; @(negedge ddr_clk); stop_cmd=0; end endtask
  task pulse_play; begin @(negedge ddr_clk); play_cmd=1; @(negedge ddr_clk); play_cmd=0; end endtask
  task pulse_abort; begin @(negedge ddr_clk); abort_cmd=1; @(negedge ddr_clk); abort_cmd=0; end endtask

  initial begin
    // Hold the destination clock domain in reset and fill the local command
    // mailbox.  The ninth request must be refused rather than overwriting an
    // older command.
    ddr_tick(3); ddr_rst_n=1;
    repeat (8) pulse_begin;
    if (command_ready_ddr) $fatal(1, "command mailbox did not report full");
    pulse_begin;
    if (command_ready_ddr) $fatal(1, "full command mailbox accepted an overwrite");
    // Reset both domains before the functional path phase so the deliberately
    // rejected stress commands cannot become playback requests.
    ddr_rst_n=0; dac_rst_n=0;
    ddr_tick(3); dac_tick(3);
    dac_rst_n=1;
    ddr_rst_n=1;
    dac_tick(3);

    pulse_begin; pulse_commit;
    wait(state_dac == 4'd4); // WAIT_TRIGGER
    if (!prefetch_safe_ddr || fifo_count == 0) $fatal(1, "prefetch did not reach safe state");
    // A narrow external event must be admitted once and start only after the
    // CDC quiet guard has re-armed the WAIT window.
    dac_tick(12);
    #1 trigger_in=1; #2 trigger_in=0;
    wait(dac_gate);
    wait(output_first_transfer);
    dac_tick(2);
    wait(state_dac == 4'd7);
    if (firsts != 2 || trigger_fire_count != 1 || fired != 8) $fatal(1, "loop/trigger accounting failed firsts=%0d firecnt=%0d fired=%0d", firsts, trigger_fire_count, fired);

    // Software PLAY from DONE must replay the descriptor from beat 0.
    //
    // The DAC stream's beat position, first-transfer flag and fire counters
    // belong to one session.  If they are not cleared when the session starts
    // (PREFETCH), a PLAY issued in DONE re-enters PLAYING with
    // beat_position == total_beats, no beat can fire, and the controller stalls
    // in PLAYING with the DAC gate open.  This phase is the regression for that
    // defect: a full second pass and a fresh TRIG_1 are required.
    pulse_play;
    wait(state_dac == 4'd5);
    wait(state_dac == 4'd7);
    // LOOP_COUNT is 2, so each playback contributes two full passes and one
    // TRIG_1 (first_transfer) per pass: 16 fires and 4 first transfers total.
    if (fired != 16 || firsts != 4)
      $fatal(1, "PLAY from DONE did not replay the descriptor: fired=%0d firsts=%0d beatpos=%0d",
             fired, firsts, dut.u_dac_stream.beat_position);
    if (trigger_fire_count != 1)
      $fatal(1, "software PLAY changed trigger_fire_count to %0d", trigger_fire_count);

    pulse_stop; dac_tick(20);
    if (state_dac != 4'd2) $fatal(1, "STOP did not return to READY");

    // Regression: software PLAY from WAIT_TRIGGER must NOT re-arm the DDR
    // reader.  The descriptor is already fully prefetched at WAIT_TRIGGER, so
    // the raw play_cmd historically fed reader_start and re-read the same
    // descriptor into the full FIFO (double fill) while also resetting the
    // prefetch accounting.  The gate-open transition must leave the FIFO level
    // untouched and still drain to DONE.
    pulse_begin; pulse_commit;
    wait(state_dac == 4'd4);  // WAIT_TRIGGER
    dac_tick(4);
    begin
      integer fifo_before;
      fifo_before = fifo_count;
      if (fifo_before == 0) $fatal(1, "prefetch left FIFO empty before WAIT_TRIGGER PLAY");
      pulse_play;
      dac_tick(4);
      if (fifo_count > fifo_before)
        $fatal(1, "software PLAY from WAIT_TRIGGER re-filled FIFO: %0d -> %0d", fifo_before, fifo_count);
    end
    wait(state_dac == 4'd7);

    $display("PASS: descriptor path prefetches, admits trigger once, and drains playback");
    $finish;
  end
  initial begin #200000; $fatal(1, "playback path timeout state=%0d busy=%b issued=%0d fifo=%0d", state_dac, reader_busy_ddr, issued, fifo_count); end
endmodule
