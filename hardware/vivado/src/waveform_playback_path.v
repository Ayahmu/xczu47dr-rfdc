`timescale 1ns/1ps

// Unified descriptor -> reader -> eight FIFO -> DAC path.
//
// DDR/UI domain owns descriptor admission and AXI reads. DAC domain owns
// trigger qualification, admission state, common-beat accounting, and RFDC
// output gating. The only cross-domain controls are toggle pulses, a complete
// descriptor FIFO record, and a synchronized prefetch/error level.
module waveform_playback_path #(
    parameter integer FIFO_DEPTH_BEATS = 1024,
    parameter integer START_WATERMARK = 768,
    parameter integer FIFO_RESET_GUARD_CYCLES = 16,
    // DAC-domain FIFO publication settle window; see the guard comment below.
    parameter integer CDC_SETTLE_CYCLES = 16,
    // DDR reader pipelining.  Defaults size one 4 KiB-page burst per AR with
    // four transactions in flight so sustained throughput exceeds the DAC rate;
    // a single-outstanding one-frame reader (1,1) is latency-bound and
    // underflows streaming descriptors.
    parameter integer READER_BURST_FRAMES = 8,
    parameter integer READER_MAX_OUTSTANDING = 4
) (
    input wire ddr_clk, input wire ddr_rst_n,
    input wire begin_cmd, input wire commit_cmd, input wire play_cmd,
    input wire pause_cmd, input wire stop_cmd, input wire abort_cmd,
    input wire [63:0] descriptor_base,
    input wire [31:0] descriptor_total_beats,
    input wire [7:0] descriptor_channel_mask,
    input wire [31:0] descriptor_loop_count,
    input wire [31:0] descriptor_generation,
    input wire [15:0] fifo_level_beats, input wire [15:0] fifo_free_beats,
    output wire command_ready_ddr,
    output wire [2047:0] fifo_write_data, output wire fifo_write_valid,
    input wire [7:0] fifo_write_ready,
    output wire fifo_write_last,
    output wire prefetch_safe_ddr, output wire reader_busy_ddr,
    output wire reader_done_ddr, output wire reader_error_ddr,
    output wire fifo_clear_ddr,
    output wire [31:0] reader_error_code_ddr,
    output wire [63:0] reader_error_offset_ddr,
    output wire [63:0] m_axi_araddr, output wire [7:0] m_axi_arlen,
    output wire m_axi_arvalid, input wire m_axi_arready,
    input wire [511:0] m_axi_rdata, input wire [1:0] m_axi_rresp,
    input wire m_axi_rvalid, input wire m_axi_rlast, output wire m_axi_rready,

    input wire dac_clk, input wire dac_rst_n, input wire trigger_in,
    // Synchronous single-cycle launch injected in the dac_clk domain. Used by
    // the TDC compensating-trigger path: a deterministic, already-scheduled
    // launch pulse that bypasses the async-pad trigger capture (trigger_in).
    // Tie 0 when unused. It only admits while the FSM is in WAIT_TRIGGER.
    input wire launch_sync,
    input wire [2047:0] fifo_data, input wire [7:0] fifo_valid,
    output wire [7:0] fifo_read_ready,
    input wire [7:0] dac_ready,
    output wire [2047:0] dac_data, output wire [7:0] dac_valid,
    output wire [7:0] dac_last, output wire [255:0] dac_keep,
    output wire [3:0] state_dac, output wire dac_gate,
    output wire [31:0] trigger_seen_count,
    output wire [31:0] trigger_dropped_count,
    output wire [31:0] trigger_fire_count,
    output wire [31:0] current_beat_dac, output wire [31:0] loop_position_dac,
    output wire [31:0] loop_count_dac, output wire [31:0] descriptor_generation_dac,
    output wire [7:0] channel_mask_dac,
    output wire [31:0] underflow_count_dac,
    output wire output_first_transfer, output wire output_beat_fire,
    output wire output_beat_last, output wire output_underflow
);
  localparam [15:0] START_WATERMARK_16 = START_WATERMARK;
  wire [2047:0] reader_frame_data;
  wire reader_frame_valid, reader_frame_ready;
  wire reader_error, reader_done;
  wire [31:0] reader_error_code;
  wire [63:0] reader_error_offset;
  wire loop_restart_ddr;
  reg loop_restart_pending_ddr;
  reg loop_restart_start_ddr;
  // Software PLAY re-arms the reader only when it needs a fresh prefetch
  // (READY/DONE -> PREFETCH), and that case is driven by loop_restart from the
  // controller, NOT by raw play_cmd: play_cmd also asserts on the
  // WAIT_TRIGGER -> PLAYING gate-open transition, where re-arming would
  // re-read the already-prefetched descriptor into a full FIFO (double fill)
  // and reset the prefetch accounting mid-read.
  wire reader_start = commit_cmd | loop_restart_start_ddr;
  wire reader_cancel = begin_cmd | pause_cmd | stop_cmd | abort_cmd;

  // Pipeline large, page-sized bursts with several transactions in flight so
  // the reader's sustained throughput exceeds the DAC consumption rate.  DDR4
  // bandwidth (~19 GB/s) far exceeds the 12.8 GB/s DAC demand, but a single
  // outstanding 256-byte burst is latency-bound (~1.6 GB/s) and underflows any
  // streaming descriptor.  BURST_FRAMES=8 issues 2 KiB per AR (clamped at
  // 4 KiB page boundaries by the reader), and MAX_OUTSTANDING=4 keeps up to
  // four in flight (8 KiB) to hide DDR read latency.  Admission is bounded
  // by the real min-free FIFO credit (waveform_fifo_mask_adapter.reader_credit)
  // and the reader's own in-flight `reserved` accounting, so it stays
  // overflow-safe.
  waveform_ddr_reader #(.MAX_OUTSTANDING(READER_MAX_OUTSTANDING), .BURST_FRAMES(READER_BURST_FRAMES)) u_reader (
    .clk(ddr_clk), .rst_n(ddr_rst_n), .start(reader_start), .cancel(reader_cancel),
    .base_addr(descriptor_base), .total_beats(descriptor_total_beats),
    .fifo_free_beats(fifo_free_beats),
    .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
    .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rlast(m_axi_rlast),
    .m_axi_rready(m_axi_rready), .frame_data(reader_frame_data),
    .frame_valid(reader_frame_valid), .frame_ready(reader_frame_ready),
    .busy(reader_busy_ddr), .done(reader_done), .error(reader_error),
    .error_code(reader_error_code_ddr), .error_offset(reader_error_offset_ddr)
  );
  assign fifo_write_data = reader_frame_data;
  assign fifo_write_valid = reader_frame_valid;
  assign reader_frame_ready = &fifo_write_ready;
  assign fifo_write_last = 1'b0;
  assign reader_error_ddr = reader_error;
  assign reader_done_ddr = reader_done;
  reg clear_pending_ddr;
  reg fifo_clear_ddr_reg;
  reg [7:0] loop_restart_guard_ddr;
  assign fifo_clear_ddr = fifo_clear_ddr_reg;
  always @(posedge ddr_clk or negedge ddr_rst_n) begin
    if (!ddr_rst_n) begin
      clear_pending_ddr <= 1'b0;
      fifo_clear_ddr_reg <= 1'b0;
      loop_restart_pending_ddr <= 1'b0;
      loop_restart_start_ddr <= 1'b0;
      loop_restart_guard_ddr <= 8'd0;
    end else begin
      fifo_clear_ddr_reg <= 1'b0;
      loop_restart_start_ddr <= 1'b0;
      if (loop_restart_guard_ddr != 0)
        loop_restart_guard_ddr <= loop_restart_guard_ddr - 1'b1;
      if (begin_cmd || pause_cmd || stop_cmd || abort_cmd) begin
        clear_pending_ddr <= 1'b1;
        loop_restart_pending_ddr <= 1'b0;
      end
      if (reader_error)
        clear_pending_ddr <= 1'b1;
      if (loop_restart_ddr) begin
        clear_pending_ddr <= 1'b1;
        loop_restart_pending_ddr <= 1'b1;
      end
      if (clear_pending_ddr && !reader_busy_ddr) begin
        fifo_clear_ddr_reg <= 1'b1;
        clear_pending_ddr <= 1'b0;
        loop_restart_guard_ddr <= FIFO_RESET_GUARD_CYCLES;
      end
      // Start one DDR clock after the FIFO reset pulse, so the reader never
      // refills an async FIFO while the top-level FIFO reset is asserted.
      if (loop_restart_pending_ddr && !clear_pending_ddr &&
          !reader_busy_ddr && !fifo_clear_ddr_reg &&
          loop_restart_guard_ddr == 0) begin
        loop_restart_start_ddr <= 1'b1;
        loop_restart_pending_ddr <= 1'b0;
      end
    end
  end
  // During PREFETCH the DAC side is gated, so the number of accepted
  // interleaved frames is the exact write-side FIFO level for this descriptor.
  // Count the real frame handshakes instead of reducing eight asynchronous FIFO
  // count buses combinationally into the 300 MHz control path.  The FIFO count
  // input remains in the interface for status/debug compatibility, but is not
  // used for admission timing.
  reg [31:0] prefetched_beats_ddr;
  wire reader_frame_fire_ddr = reader_frame_valid && reader_frame_ready;
  // Any descriptor that fits entirely in the async FIFOs is FULLY prefetched
  // before the DAC gate opens; only a descriptor too large to fit falls back to
  // the streaming watermark.
  //
  // The DDR reader keeps a single one-frame AXI burst in flight (BURST_FRAMES=1,
  // outstanding<=1), so its sustained refill rate is well below the DAC
  // consumption rate.  Opening the gate at START_WATERMARK while the reader is
  // still filling therefore drains the head-start buffer and underflows a
  // finite descriptor once it outruns the reader (measured ceiling ~875 beats
  // at 768 watermark).  When the whole descriptor fits, waiting for the reader
  // to finish makes playback drain a static, fully-loaded FIFO that the reader
  // never has to keep feeding, so it cannot underflow.  START_WATERMARK is kept
  // only for descriptors larger than the FIFO, which must genuinely stream.
  wire [31:0] prefetch_target_ddr =
      (descriptor_total_beats <= FIFO_DEPTH_BEATS) ?
      descriptor_total_beats : START_WATERMARK;
  wire level_safe = (descriptor_total_beats != 0) &&
      (prefetched_beats_ddr >= prefetch_target_ddr);
  always @(posedge ddr_clk or negedge ddr_rst_n) begin
    if (!ddr_rst_n) begin
      prefetched_beats_ddr <= 32'd0;
    end else if (begin_cmd || pause_cmd || stop_cmd || abort_cmd ||
                 commit_cmd || loop_restart_ddr ||
                 loop_restart_start_ddr || fifo_clear_ddr_reg) begin
      prefetched_beats_ddr <= 32'd0;
    end else if (reader_frame_fire_ddr &&
                 prefetched_beats_ddr < descriptor_total_beats) begin
      prefetched_beats_ddr <= prefetched_beats_ddr + 1'b1;
    end
  end

  reg prefetch_complete_ddr;
  // Publish PREFETCH_SAFE as a registered DDR-domain level.  The reader's
  // error/busy outputs and FIFO level are all native to this clock, but the
  // combinational expression itself is later synchronized into dac_clk.  A
  // source-domain register makes that CDC boundary explicit and prevents
  // the synchronizer from seeing logic fed directly by the reader state.
  reg prefetch_safe_ddr_reg;
  always @(posedge ddr_clk or negedge ddr_rst_n) begin
    if (!ddr_rst_n) begin
      prefetch_complete_ddr <= 1'b0;
      prefetch_safe_ddr_reg <= 1'b0;
    end else begin
      if (begin_cmd || pause_cmd || stop_cmd || abort_cmd || commit_cmd ||
          loop_restart_ddr || loop_restart_start_ddr)
        prefetch_complete_ddr <= 1'b0;
      if (reader_done_ddr && !reader_error_ddr)
        prefetch_complete_ddr <= 1'b1;
      if (reader_error_ddr)
        prefetch_complete_ddr <= 1'b0;
      prefetch_safe_ddr_reg <= !reader_error_ddr && level_safe &&
                               (reader_busy_ddr || prefetch_complete_ddr);
    end
  end
  assign prefetch_safe_ddr = prefetch_safe_ddr_reg;

  wire begin_dac, commit_dac, play_dac, pause_dac, stop_dac, abort_dac;
  wire [2:0] command_rd_cmd;
  wire command_rd_valid;
  wire command_rd_ready = 1'b1;
  wire command_wr_ready;
  wire [2:0] command_wr_cmd;
  wire command_wr_valid;
  reg [2:0] command_mem [0:7];
  reg [2:0] command_wr_ptr, command_rd_ptr;
  reg [3:0] command_count;
  reg descriptor_pending;
  reg descriptor_accepted;
  wire command_input_valid = begin_cmd | commit_cmd | play_cmd | pause_cmd | stop_cmd | abort_cmd;
  // The writer holds a command in ST_FINAL until this admission level is
  // true.  Keep one descriptor record outstanding at a time: COMMIT must not
  // overwrite a descriptor that is still waiting to cross into the DAC clock
  // domain.
  assign command_ready_ddr = (command_count < 4'd8) && !descriptor_pending;
  wire [2:0] command_input_code = begin_cmd ? 3'd0 : commit_cmd ? 3'd1 :
                                   play_cmd ? 3'd2 : pause_cmd ? 3'd3 :
                                   stop_cmd ? 3'd4 : 3'd5;
  wire command_head_is_commit = command_count != 0 && command_mem[command_rd_ptr] == 3'd1;
  // A COMMIT is not allowed to cross into the DAC domain until its complete
  // descriptor record has crossed the separate descriptor FIFO. This keeps
  // command ordering deterministic even while either XPM FIFO is in reset.
  assign command_wr_valid = command_count != 0 &&
                            (!command_head_is_commit || descriptor_accepted);
  assign command_wr_cmd = command_mem[command_rd_ptr];
  waveform_command_cdc u_command_cdc (
    .wr_clk(ddr_clk), .wr_rst_n(ddr_rst_n), .wr_cmd(command_wr_cmd),
    .wr_valid(command_wr_valid), .wr_ready(command_wr_ready),
    .rd_clk(dac_clk), .rd_rst_n(dac_rst_n), .rd_cmd(command_rd_cmd),
    .rd_valid(command_rd_valid), .rd_ready(command_rd_ready)
  );
  assign begin_dac = command_rd_valid && command_rd_ready && command_rd_cmd == 3'd0;
  assign commit_dac = command_rd_valid && command_rd_ready && command_rd_cmd == 3'd1;
  assign play_dac = command_rd_valid && command_rd_ready && command_rd_cmd == 3'd2;
  assign pause_dac = command_rd_valid && command_rd_ready && command_rd_cmd == 3'd3;
  assign stop_dac = command_rd_valid && command_rd_ready && command_rd_cmd == 3'd4;
  assign abort_dac = command_rd_valid && command_rd_ready && command_rd_cmd == 3'd5;

  wire [175:0] descriptor_wr_data = {
      descriptor_generation, descriptor_loop_count, descriptor_channel_mask,
      8'd0, descriptor_total_beats, descriptor_base
  };
  wire [175:0] descriptor_rd_data;
  wire descriptor_wr_ready, descriptor_rd_valid;
  reg descriptor_rd_ready;
  reg [63:0] base_dac;
  reg [31:0] total_beats_dac, descriptor_loop_count_dac, generation_dac;
  reg [7:0] mask_dac;
  reg descriptor_loaded_dac;
  reg commit_pending_dac;
  wire controller_commit_dac = descriptor_loaded_dac && commit_pending_dac;
  waveform_descriptor_cdc #(.WIDTH(176), .DEPTH(16)) u_descriptor_cdc (
    .wr_clk(ddr_clk), .wr_rst_n(ddr_rst_n), .wr_data(descriptor_wr_data),
    .wr_valid(descriptor_pending), .wr_ready(descriptor_wr_ready),
    .rd_clk(dac_clk), .rd_rst_n(dac_rst_n), .rd_data(descriptor_rd_data),
    .rd_valid(descriptor_rd_valid), .rd_ready(descriptor_rd_ready)
  );
  wire descriptor_write_fire = descriptor_pending && descriptor_wr_ready;
  always @(posedge ddr_clk or negedge ddr_rst_n) begin
    if (!ddr_rst_n) begin
      command_wr_ptr <= 0;
      command_rd_ptr <= 0;
      command_count <= 0;
      descriptor_pending <= 0;
      descriptor_accepted <= 0;
    end else begin
      if (commit_cmd) begin
        descriptor_pending <= 1'b1;
        descriptor_accepted <= 1'b0;
      end
      if (descriptor_write_fire) begin
        descriptor_pending <= 1'b0;
        descriptor_accepted <= 1'b1;
      end

      case ({command_input_valid && command_ready_ddr,
             command_wr_valid && command_wr_ready})
        2'b10: begin
          command_mem[command_wr_ptr] <= command_input_code;
          command_wr_ptr <= command_wr_ptr + 1'b1;
          command_count <= command_count + 1'b1;
        end
        2'b01: begin
          command_rd_ptr <= command_rd_ptr + 1'b1;
          command_count <= command_count - 1'b1;
        end
        2'b11: begin
          command_mem[command_wr_ptr] <= command_input_code;
          command_wr_ptr <= command_wr_ptr + 1'b1;
          command_rd_ptr <= command_rd_ptr + 1'b1;
        end
        default: begin end
      endcase
    end
  end

  always @(posedge dac_clk or negedge dac_rst_n) begin
    if (!dac_rst_n) begin
      descriptor_rd_ready <= 1'b1;
      base_dac <= 0; total_beats_dac <= 0; descriptor_loop_count_dac <= 0;
      generation_dac <= 0; mask_dac <= 0;
      descriptor_loaded_dac <= 1'b0;
      commit_pending_dac <= 1'b0;
    end else begin
      descriptor_rd_ready <= 1'b1;
      if (commit_dac) begin
        descriptor_loaded_dac <= 1'b0;
        commit_pending_dac <= 1'b1;
      end
      if (descriptor_rd_valid) begin
        base_dac <= descriptor_rd_data[63:0];
        total_beats_dac <= descriptor_rd_data[95:64];
        mask_dac <= descriptor_rd_data[111:104];
        descriptor_loop_count_dac <= descriptor_rd_data[143:112];
        generation_dac <= descriptor_rd_data[175:144];
        descriptor_loaded_dac <= 1'b1;
      end
      if (controller_commit_dac)
        commit_pending_dac <= 1'b0;
      if (abort_dac) begin
        total_beats_dac <= 0; mask_dac <= 0; descriptor_loop_count_dac <= 0;
        descriptor_loaded_dac <= 1'b0;
        commit_pending_dac <= 1'b0;
      end
    end
  end

  (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] safe_sync, error_sync;
  always @(posedge dac_clk or negedge dac_rst_n) begin
    if (!dac_rst_n) begin safe_sync<=0; error_sync<=0; end
    else begin safe_sync<={safe_sync[0],prefetch_safe_ddr}; error_sync<={error_sync[0],reader_error_ddr}; end
  end

  // The controller's session states are part of this block's wiring contract.
  localparam [3:0] ST_PREFETCH_DAC     = 4'd3;
  localparam [3:0] ST_WAIT_TRIGGER_DAC = 4'd4;

  // FIFO publication settle guard.
  //
  // FIFO_LEVEL_BEATS/FIFO_FREE_BEATS are the async FIFOs' WRITE-domain counts.
  // They are the correct credit for the DDR reader, but they are NOT what the
  // DAC domain can observe: a word written in the DDR clock domain becomes
  // visible at the FIFO's DAC-side output only after the FIFO's own read
  // pointer synchronizer has crossed the CDC.  Opening the DAC gate purely on
  // the write-side level therefore starts playback before the DAC domain has
  // the data it was promised, and a descriptor whose prefetched depth is
  // comparable to that CDC lag drains faster than the FIFO publishes and is
  // falsely reported as an underflow.
  //
  // The DAC domain cannot read the FIFO's read-side level (the IP is generated
  // without HAS_RD_DATA_COUNT), so readiness is established the only way the
  // DAC domain can actually prove it: every enabled lane must have published a
  // beat (FIFO_VALID is the true DAC-side availability signal), and that must
  // hold for CDC_SETTLE_CYCLES before the controller may leave PREFETCH.
  //
  // CDC_SETTLE_CYCLES must cover the FIFO read-pointer synchronizer
  // (C_SYNCHRONIZER_STAGE read clocks) plus the internal read/compare pipeline,
  // with margin.  It is sufficient because the guard only becomes reachable
  // once PREFETCH_SAFE is observed:
  //   * streaming descriptor (TOTAL_BEATS > FIFO_DEPTH_BEATS): PREFETCH_SAFE
  //     implies a write-side level of at least START_WATERMARK (768) beats,
  //     which exceeds the CDC lag by orders of magnitude, so the read side is
  //     never the limiting factor;
  //   * fits-in-FIFO descriptor (TOTAL_BEATS <= FIFO_DEPTH_BEATS): PREFETCH_SAFE
  //     implies the write-side level already equals TOTAL_BEATS, i.e. the whole
  //     descriptor has been written (the reader has reached done), so the write
  //     pointer stops moving and the read-side view converges to the write-side
  //     view within the settle window.
  // The counter is (re)armed on every entry to PREFETCH, so COMMIT, PLAY from
  // READY/DONE and each loop restart all re-establish publication before the
  // gate can open.  It is deliberately not held cleared by the PREFETCH state
  // itself, otherwise it could never advance.
  reg prefetch_state_dac;
  reg [7:0] fifo_settle_count_dac;
  wire prefetch_enter_dac = (state_dac == ST_PREFETCH_DAC) && !prefetch_state_dac;
  // Every enabled lane has a beat presented to the DAC domain.
  wire lanes_published_dac = &(fifo_valid | ~mask_dac);
  always @(posedge dac_clk or negedge dac_rst_n) begin
    if (!dac_rst_n) begin
      prefetch_state_dac    <= 1'b0;
      fifo_settle_count_dac <= 8'd0;
    end else begin
      prefetch_state_dac <= (state_dac == ST_PREFETCH_DAC);
      if (prefetch_enter_dac || !safe_sync[1] || !lanes_published_dac)
        fifo_settle_count_dac <= 8'd0;
      else if (fifo_settle_count_dac < CDC_SETTLE_CYCLES[7:0])
        fifo_settle_count_dac <= fifo_settle_count_dac + 8'd1;
    end
  end
  wire fifo_published_dac = (fifo_settle_count_dac >= CDC_SETTLE_CYCLES[7:0]);

  wire any_fifo_empty = |(~fifo_valid & mask_dac);
  wire stream_beat_fire, stream_beat_last, stream_underflow;
  wire [31:0] stream_beat_position, stream_underflow_count;
  wire [31:0] controller_loop_position;
  wire [7:0] trigger_event_seen, unused_trigger;
  wire loop_restart_dac;
  // The DAC stream's beat position, per-channel fire counts, first-transfer
  // flag and underflow counter belong to exactly one playback session, and a
  // session always starts from beat 0 at the beginning of a prefetch (COMMIT,
  // PLAY from READY/DONE, and loop restart all enter PREFETCH).  Clearing only
  // on STOP/PAUSE/ABORT/BEGIN/loop-restart leaves the counters of a finished
  // session in place: a PLAY issued in DONE then re-enters PLAYING with
  // beat_position already equal to total_beats, so no beat can ever fire, the
  // common position never advances and the controller stalls in PLAYING with
  // the DAC gate open.  PREFETCH is not PLAYING, so no beat can be in flight
  // while this clear is asserted.
  wire stream_clear_dac = begin_dac || abort_dac || stop_dac || pause_dac ||
                          loop_restart_dac || (state_dac == ST_PREFETCH_DAC);

  waveform_trigger_cdc u_trigger (
    .clk(dac_clk), .rst_n(dac_rst_n), .trigger_in(trigger_in),
    .wait_trigger(state_dac == ST_WAIT_TRIGGER_DAC), .trigger_event(trigger_event_seen[0]),
    .trigger_seen(unused_trigger[0]), .trigger_dropped(unused_trigger[1]),
    .trigger_seen_count(), .trigger_dropped_count()
  );
  waveform_pulse_sync u_loop_restart_sync (
    .src_clk(dac_clk), .src_rst_n(dac_rst_n), .src_pulse(loop_restart_dac),
    .dst_clk(ddr_clk), .dst_rst_n(ddr_rst_n), .dst_pulse(loop_restart_ddr)
  );
  waveform_playback_controller u_controller (
    .clk(dac_clk), .rst_n(dac_rst_n), .begin_cmd(begin_dac), .commit_cmd(commit_dac),
    .play_cmd(play_dac), .pause_cmd(pause_dac), .stop_cmd(stop_dac), .abort_cmd(abort_dac),
    // Only the PREFETCH exit is delayed until DAC-side publication is proven.
    // FIFO_SAFE keeps its original meaning so ongoing underflow/fault detection
    // is unchanged; this guard exists to stop the gate opening too early.
    .trigger_event(trigger_event_seen[0] | launch_sync),
    // Require one full DAC clock in the new PREFETCH state before a stale
    // publication flag from the preceding playback session can be observed.
    .prefetch_done(safe_sync[1] && fifo_published_dac && prefetch_state_dac),
    .fifo_safe(safe_sync[1]),
    .fifo_empty(stream_underflow || any_fifo_empty),
    .axi_error(error_sync[1]), .beat_valid(stream_beat_fire), .beat_ready(1'b1),
    .beat_last(stream_beat_last), .loop_count(descriptor_loop_count_dac),
    .state(state_dac), .dac_gate(dac_gate), .loop_restart(loop_restart_dac),
    .loop_position(controller_loop_position),
    .trigger_seen_count(trigger_seen_count), .trigger_dropped_count(trigger_dropped_count),
    .trigger_fire_count(trigger_fire_count)
  );
  waveform_dac_stream u_dac_stream (
    .clk(dac_clk), .rst_n(dac_rst_n), .playing(dac_gate),
    .clear(stream_clear_dac),
    .channel_mask(mask_dac), .total_beats(total_beats_dac), .fifo_data(fifo_data),
    .fifo_valid(fifo_valid), .fifo_ready(fifo_read_ready), .dac_data(dac_data),
    .dac_valid(dac_valid), .dac_ready(dac_ready), .dac_last(dac_last), .dac_keep(dac_keep),
    .beat_fire(stream_beat_fire), .beat_last(stream_beat_last), .underflow(stream_underflow),
    .first_transfer(output_first_transfer), .beat_position(stream_beat_position),
    .underflow_count(stream_underflow_count), .channel_fire_counts()
  );
  assign current_beat_dac = stream_beat_position;
  assign loop_position_dac = controller_loop_position;
  assign loop_count_dac = descriptor_loop_count_dac;
  assign descriptor_generation_dac = generation_dac;
  assign channel_mask_dac = mask_dac;
  assign underflow_count_dac = stream_underflow_count;
  assign output_beat_fire = stream_beat_fire;
  assign output_beat_last = stream_beat_last;
  assign output_underflow = stream_underflow;
endmodule
