`timescale 1ns/1ps

// WAVECTR0 ingress in the DDR/UI clock domain.
//
// The UDP RX path presents one accepted 64-bit word per cycle and has no
// backpressure signal.  A complete DATA payload is therefore first buffered in
// a four-bank synchronous BRAM, checked for sequence/offset/CRC, and only then
// emitted as aligned 256-bit AXI writes.  This prevents a bad packet from
// partially changing the committed waveform image.
//
// A BEGIN with layout 2 opens a bulk session instead: the image arrives on the
// 512-bit bulk path (wave_bulk_ddr_writer), DATA packets are refused here, and
// this parser only arms the bulk writer, relays BULK_STATUS / BULK_CHUNK_RESET
// and gates COMMIT on the bulk writer reporting the image complete.
module waveform_upload_writer #(
    parameter [63:0] CTRL_MAGIC = 64'h5741564543545230,
    parameter [63:0] DDR_ADDR_BASE = 64'd0,
    parameter integer MAX_PAYLOAD_BYTES = 1408,
    parameter [63:0] DDR_CAPACITY_BYTES = 64'h1fff00000,
    parameter integer AXI_TIMEOUT_CYCLES = 300000
) (
    input wire clk, input wire rst_n,
    input wire response_ready,
    input wire status_request_ready,
    output reg status_request,
    input wire status_snapshot_valid,
    input wire [31:0] status_snapshot_state,
    input wire [15:0] status_snapshot_status,
    input wire [31:0] status_snapshot_error_code,
    input wire [63:0] status_snapshot_error_offset,
    // Command outputs are held until the downstream playback path can
    // accept them.  This is deliberately a level, not a pulse: the parser
    // may be stalled in ST_FINAL while the cross-domain command FIFO drains.
    input wire command_ready,
    input wire udp_tvalid, input wire [63:0] udp_tdata, input wire udp_tlast,

    output reg response_valid, output reg [31:0] response_seq,
    output reg [31:0] response_opcode, output reg [15:0] response_status,
    output reg [31:0] response_error_code,
    output reg [63:0] response_error_offset,
    output reg [31:0] response_state,
    output reg [31:0] response_ack_packet_seq,
    output reg [31:0] response_next_expected_sequence,
    output reg [63:0] response_received_bytes,
    output reg [63:0] response_first_error_offset,
    output reg [31:0] response_expected_crc, output reg [31:0] response_actual_crc,
    output reg [31:0] session, output reg [31:0] descriptor,
    input wire [31:0] playback_state,

    output reg [3:0] state,
    output reg begin_valid, output reg commit_valid, output reg play_valid,
    output reg pause_valid, output reg stop_valid, output reg abort_valid,

    output reg [63:0] ddr_base_addr, output reg [63:0] total_bytes,
    output reg [31:0] total_beats, output reg [7:0] channel_mask,
    output reg [31:0] loop_count,


    output reg [63:0] m_axi_awaddr, output reg m_axi_awvalid,
    input wire m_axi_awready, output reg [255:0] m_axi_wdata,
    output reg [31:0] m_axi_wstrb, output reg m_axi_wvalid,
    output reg m_axi_wlast, input wire m_axi_wready,
    input wire [1:0] m_axi_bresp, input wire m_axi_bvalid,
    output wire m_axi_bready,

    output reg [63:0] received_bytes, output reg [31:0] next_packet_seq,
    output reg [63:0] error_offset, output reg [31:0] error_count,

    // Bulk session control (wave_bulk_ddr_writer and the bulk RX counters).
    output wire bulk_enable,
    output reg bulk_ctl_start, output reg [1:0] bulk_ctl_cmd, output reg [20:0] bulk_ctl_arg,
    input wire bulk_ctl_busy,
    input wire bulk_complete, input wire [13:0] bulk_complete_chunks,
    input wire [31:0] bulk_first_incomplete,
    input wire [31:0] bulk_frames_ok, input wire [31:0] bulk_frames_rejected,
    input wire [31:0] bulk_frames_duplicate, input wire [31:0] bulk_frames_stale,
    input wire bulk_overrun, input wire bulk_axi_error,
    input wire [31:0] bulk_rx_frames, input wire [31:0] bulk_rx_dropped_full,
    input wire [31:0] bulk_rx_dropped_bad
);
  localparam [3:0] ST_IDLE=4'd0, ST_HDR0=4'd1, ST_HDR1=4'd2,
                   ST_PAYLOAD=4'd3, ST_WRITE=4'd4, ST_CRC=4'd5, ST_CRC_DONE=4'd6,
                   ST_FINAL=4'd7, ST_EMIT=4'd8, ST_DROP=4'd9,
                   ST_READ_WAIT=4'd10, ST_READ_LOAD=4'd11, ST_DECODE=4'd12;
  localparam [15:0] OK=16'd0, BAD_REQUEST=16'd2, INCOMPLETE=16'd4,
                    SEQUENCE=16'd5, OFFSET=16'd6, CRC=16'd7, RANGE=16'd8,
                    AXI_ERROR=16'd9, TIMEOUT=16'd10, UNSAFE=16'd11;
  localparam [31:0] OP_BEGIN=32'd1, OP_DATA=32'd2, OP_COMMIT=32'd3,
                    OP_PLAY=32'd4, OP_PAUSE=32'd5, OP_STOP=32'd6,
                    OP_ABORT=32'd7, OP_STATUS=32'd8,
                    OP_BULK_STATUS=32'd9, OP_BULK_CHUNK_RESET=32'd10;
  localparam [7:0] LAYOUT_INTERLEAVED=8'd1, LAYOUT_INTERLEAVED_BULK=8'd2;
  localparam [1:0] BULK_CMD_CLEAR=2'd1, BULK_CMD_CHUNK_RESET=2'd2, BULK_CMD_SCAN=2'd3;
  localparam integer MAX_DATA_WORDS = (MAX_PAYLOAD_BYTES + 7) / 8;

  // RX never backpressures. Track every packet boundary, including packets
  // arriving during CRC/write/response. Never resynchronize on magic inside
  // the tail of a dropped packet.
  reg rx_active;
  reg upload_active, committed, write_failed;
  reg [31:0] generation, axi_timer;
  reg [31:0] last_data_request, last_data_packet, last_data_length, last_data_crc;
  reg [63:0] last_data_offset;
  reg last_data_valid, last_play_valid;
  reg [31:0] last_play_request, last_commit_request, last_begin_request;
  reg status_requested, status_response_latched;
  reg [31:0] status_state_latched, status_error_code_latched;
  reg [15:0] status_status_latched;
  reg [63:0] status_error_offset_latched;
  wire [31:0] next_generation = generation == 32'hffffffff ? 32'd1 : generation + 1'b1;
  reg [15:0] begin_reserved;
  reg [63:0] command_session_word;
  reg [31:0] payload_bytes, payload_words, payload_index;
  reg [31:0] command_seq;
  reg [31:0] command_opcode;
  wire command_opcode_requires_admission =
      command_opcode == OP_BEGIN || command_opcode == OP_COMMIT ||
      command_opcode == OP_PLAY || command_opcode == OP_PAUSE ||
      command_opcode == OP_STOP || command_opcode == OP_ABORT;
  reg packet_error;
  reg duplicate_packet;

  reg [31:0] begin_session, begin_total_beats, begin_loop_count;
  reg [63:0] begin_total_bytes;
  reg [7:0] begin_channel_mask, begin_layout;
  reg [31:0] begin_bytes_per_beat;
  reg bulk_mode;
  reg [1:0] bulk_phase;
  wire command_is_bulk_query = command_opcode == OP_BULK_STATUS || command_opcode == OP_BULK_CHUNK_RESET;
  wire begin_is_bulk = begin_layout == LAYOUT_INTERLEAVED_BULK;
  // A bulk BEGIN arms the bulk writer, so it also waits for that writer.
  wire begin_waits_for_bulk = command_opcode == OP_BEGIN && begin_is_bulk && bulk_ctl_busy;
  assign bulk_enable = upload_active && bulk_mode;

  // Pre-register the wide DATA validation predicates so the 64-bit subtract
  // and length checks do not land on the response-status clock-enable path at
  // 300 MHz.  Mirrors crc_result_ok below.  The values are latched as soon as
  // the DATA header words are complete (payload_index==2) and are stable in
  // ST_FINAL, which reads the registered flags instead of a wide cone.
  reg data_range_ok;
  reg data_offset_ok;

  reg [31:0] data_session, data_packet_seq, data_length, data_crc_expected;
  reg [63:0] data_offset;
  reg [31:0] data_crc_running;
  reg [31:0] data_word_index;
  // CRC is checked after the complete packet is buffered.  The old design
  // expanded a 64-bit, 8-bit-at-a-time CRC function on the UDP critical path;
  // this byte-serial checker keeps packet acceptance off the 300 MHz path.
  reg [13:0] crc_check_bit_index;
  reg [14:0] crc_check_total_bits;
  // Register the CRC decision before updating response/AXI control.  This
  // keeps the variable-indexed packet RAM and CRC cone out of the response
  // register clock-enable path at 300 MHz.
  reg crc_result_ok;
  localparam integer MAX_WRITE_WORDS = (MAX_PAYLOAD_BYTES + 31) / 32;
  localparam integer RAM_ADDR_WIDTH = $clog2(MAX_WRITE_WORDS);
  reg [RAM_ADDR_WIDTH-1:0] packet_read_addr;
  reg [255:0] packet_read_data, crc_shift;
  reg reading_crc;
  wire packet_write = udp_tvalid && state == ST_PAYLOAD && command_opcode == OP_DATA &&
                      payload_index >= 3 && data_word_index < MAX_DATA_WORDS;
  // Four independent 64-bit write banks provide one registered 256-bit read.
  // No reset of RAM contents: a validated length/CRC is the only way to read
  // buffered data into AXI. All inferred RAM ports are synchronous.
  genvar bank;
  generate for (bank=0; bank<4; bank=bank+1) begin : packet_banks
    (* ram_style = "block" *) reg [63:0] data_mem [0:MAX_WRITE_WORDS-1];
    always @(posedge clk) begin
      if (packet_write && data_word_index[1:0] == bank)
        data_mem[data_word_index >> 2] <= udp_tdata;
      packet_read_data[bank*64 +: 64] <= data_mem[packet_read_addr];
    end
  end endgenerate

  // ST_FINAL acts on a complete, registered request.  The wide compares it
  // needs are registered here first, one cycle earlier (ST_DECODE), so that
  // only single-bit flags reach the clock enables of the session, response
  // and error registers at 300 MHz.  The flags are refreshed every cycle, so
  // they stay current while ST_FINAL waits for the playback path.
  reg payload_at_last;          // the word being received is the last one the header promised
  reg dec_begin_bad, dec_begin_repeat, dec_begin_mismatch;
  reg dec_session_bad, dec_commit_incomplete, dec_bulk_query_bad;
  reg dec_data_bad, dec_data_duplicate, dec_data_seq_bad;
  always @(posedge clk) begin
    dec_begin_bad <= begin_session == 0 || begin_channel_mask == 0 ||
                     (begin_layout != LAYOUT_INTERLEAVED && !begin_is_bulk) ||
                     begin_reserved != 0 || begin_bytes_per_beat != 64 || begin_loop_count == 0 ||
                     begin_total_bytes == 0 || begin_total_bytes > DDR_CAPACITY_BYTES ||
                     begin_total_bytes != {24'd0, begin_total_beats, 8'd0};
    dec_begin_repeat <= session == begin_session && last_begin_request == command_seq &&
                        (upload_active || committed);
    dec_begin_mismatch <= total_bytes != begin_total_bytes || total_beats != begin_total_beats ||
                          channel_mask != begin_channel_mask || loop_count != begin_loop_count ||
                          bulk_mode != begin_is_bulk;
    dec_session_bad <= command_session_word[63:32] != 0 ||
                       (command_session_word[31:0] != 0 && command_session_word[31:0] != session);
    dec_commit_incomplete <= bulk_mode ? !bulk_complete : received_bytes != total_bytes;
    dec_bulk_query_bad <= !bulk_mode || command_session_word[31:0] != session ||
                          (command_opcode == OP_BULK_STATUS && command_session_word[63:32] != 0) ||
                          (command_opcode == OP_BULK_CHUNK_RESET &&
                           (!upload_active || command_session_word[63:53] != 0));
    dec_data_bad <= data_session != session || !upload_active || bulk_mode || playback_state == 8;
    dec_data_duplicate <= last_data_valid && data_packet_seq == last_data_packet &&
                          command_seq == last_data_request && data_offset == last_data_offset &&
                          data_length == last_data_length && data_crc_expected == last_data_crc;
    dec_data_seq_bad <= data_packet_seq != next_packet_seq;
  end

  reg [31:0] write_index, write_words_total;
  reg [31:0] write_length;
  reg [63:0] write_offset;
  reg write_aw_done, write_w_done;


  // B may arrive on the same cycle as the final AW/W handshake. Do not
  // consume (and lose) a response merely because the old *_done FF is zero.
  wire aw_complete = write_aw_done || (m_axi_awvalid && m_axi_awready);
  wire w_complete = write_w_done || (m_axi_wvalid && m_axi_wready);
  assign m_axi_bready = state == ST_WRITE && aw_complete && w_complete;

  function [31:0] crc32_bit;
    input [31:0] crc_in;
    input        bit_value;
    reg [31:0] c;
    begin
      c = crc_in;
      if (c[0] ^ bit_value)
        crc32_bit = (c >> 1) ^ 32'hEDB88320;
      else
        crc32_bit = c >> 1;
    end
  endfunction

  task set_error;
    input [15:0] status_code;
    input [63:0] offset_value;
    begin
      if (!packet_error) begin
        response_status <= status_code;
        response_error_code <= status_code;
        error_offset <= offset_value;
        error_count <= error_count + 1'b1;
      end
      packet_error <= 1'b1;
    end
  endtask

  task emit_response;
    begin
      response_valid <= 1'b1;
      response_seq <= command_seq;
      response_opcode <= command_opcode;
      // State is sampled at the response event.  The parser state is exposed
      // during upload; the external playback controller supplies the stable
      // user-facing state for command responses.
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      rx_active <= 0; upload_active <= 0; committed <= 0; generation <= 0;
      last_data_valid <= 0; last_play_valid <= 0; begin_reserved <= 0;
      last_data_request <= 0; last_data_packet <= 0; last_data_length <= 0; last_data_crc <= 0;
      last_data_offset <= 0; last_play_request <= 0; last_commit_request <= 0; last_begin_request <= 0;
      command_session_word <= 0; axi_timer <= 0; write_failed <= 0;
      response_expected_crc <= 0; response_actual_crc <= 0;
      response_valid <= 1'b0; response_seq <= 0; response_opcode <= 0;
      status_request <= 1'b0; status_requested <= 1'b0; status_response_latched <= 1'b0;
      status_state_latched <= 0; status_status_latched <= OK;
      status_error_code_latched <= 0; status_error_offset_latched <= 0;
      response_status <= OK; response_error_code <= 0; response_error_offset <= 0;
      response_state <= 0; response_ack_packet_seq <= 0; response_next_expected_sequence <= 0;
      response_received_bytes <= 0; response_first_error_offset <= 0;
      session <= 0; descriptor <= 0;
      begin_valid <= 0; commit_valid <= 0; play_valid <= 0; pause_valid <= 0;
      stop_valid <= 0; abort_valid <= 0;
      ddr_base_addr <= DDR_ADDR_BASE; total_bytes <= 0; total_beats <= 0;
      channel_mask <= 0; loop_count <= 0; received_bytes <= 0;
      next_packet_seq <= 0; error_offset <= 0; error_count <= 0;
      payload_bytes <= 0; payload_words <= 0; payload_index <= 0;
      command_seq <= 0; command_opcode <= 0; packet_error <= 0;
      duplicate_packet <= 0; begin_session <= 0; begin_total_bytes <= 0;
      bulk_mode <= 0; bulk_phase <= 0; bulk_ctl_start <= 0; bulk_ctl_cmd <= 0; bulk_ctl_arg <= 0;
      payload_at_last <= 0;
      begin_total_beats <= 0; begin_channel_mask <= 0; begin_layout <= 0;
      begin_loop_count <= 0; begin_bytes_per_beat <= 0;
      data_session <= 0; data_packet_seq <= 0; data_length <= 0;
      data_crc_expected <= 0; data_offset <= 0; data_crc_running <= 32'hFFFFFFFF;
      data_range_ok <= 1'b0; data_offset_ok <= 1'b0;
      crc_result_ok <= 1'b0; crc_check_bit_index <= 0; crc_check_total_bits <= 0;
      packet_read_addr <= 0; crc_shift <= 0; reading_crc <= 0;
      data_word_index <= 0; write_index <= 0; write_words_total <= 0;
      write_length <= 0; write_offset <= 0; write_aw_done <= 0; write_w_done <= 0;
      m_axi_awaddr <= 0; m_axi_awvalid <= 0; m_axi_wdata <= 0;
      m_axi_wstrb <= 0; m_axi_wvalid <= 0; m_axi_wlast <= 0;
      commit_valid <= 0;
    end else begin
      if (response_valid && response_ready) response_valid <= 1'b0;
      status_request <= 1'b0;
      bulk_ctl_start <= 1'b0;
      if (udp_tvalid) rx_active <= !udp_tlast;
      begin_valid <= 1'b0; commit_valid <= 1'b0; play_valid <= 1'b0;
      pause_valid <= 1'b0; stop_valid <= 1'b0; abort_valid <= 1'b0;

      if (m_axi_awvalid && m_axi_awready) begin
        m_axi_awvalid <= 1'b0;
        write_aw_done <= 1'b1;
      end
      if (m_axi_wvalid && m_axi_wready) begin
        m_axi_wvalid <= 1'b0;
        m_axi_wlast <= 1'b0;
        write_w_done <= 1'b1;
      end
      if (state != ST_WRITE) axi_timer <= 0;
      else if ((m_axi_awvalid && m_axi_awready) || (m_axi_wvalid && m_axi_wready) ||
               (m_axi_bvalid && m_axi_bready)) axi_timer <= 0;
      else if (!write_failed) begin
        if (axi_timer == AXI_TIMEOUT_CYCLES-1) begin
          // A timeout cannot cancel AXI. Keep AW/W and B draining, invalidate
          // the upload, and refuse another session until the old B retires.
          write_failed <= 1; upload_active <= 0; committed <= 0;
          response_status <= TIMEOUT; response_error_code <= TIMEOUT;
          response_error_offset <= write_offset + (write_index << 5);
          error_offset <= write_offset + (write_index << 5);
          error_count <= error_count + 1'b1;
          response_seq <= command_seq; response_opcode <= command_opcode;
          response_state <= playback_state; response_valid <= 1;
          response_received_bytes <= received_bytes;
          response_next_expected_sequence <= next_packet_seq;
          response_first_error_offset <= write_offset + (write_index << 5);
          response_ack_packet_seq <= next_packet_seq - 1'b1;
        end else axi_timer <= axi_timer + 1'b1;
      end
      if (m_axi_bvalid && m_axi_bready) begin
        write_aw_done <= 0; write_w_done <= 0;
        if (write_failed) begin state <= ST_IDLE; end
        else if (m_axi_bresp != 0) begin
          response_status <= AXI_ERROR; response_error_code <= AXI_ERROR;
          error_offset <= write_offset + (write_index << 5);
          error_count <= error_count + 1'b1;
          upload_active <= 0; committed <= 0; state <= ST_EMIT;
        end else if (write_index + 1 >= write_words_total) begin
          received_bytes <= received_bytes + write_length;
          next_packet_seq <= next_packet_seq + 1'b1;
          last_data_valid <= 1; last_data_request <= command_seq;
          last_data_packet <= data_packet_seq; last_data_offset <= data_offset;
          last_data_length <= data_length; last_data_crc <= data_crc_expected;
          response_status <= OK; response_error_code <= 0; state <= ST_EMIT;
        end else begin
          write_index <= write_index + 1'b1;
          packet_read_addr <= packet_read_addr + 1'b1;
          state <= ST_READ_WAIT;
        end
      end

      // The explicit wait/load stages account for synchronous BRAM latency.
      // AR/CRC index changes never enter a variable-indexed RAM mux on the
      // response clock-enable path. CRC consumes a shifting register bit.
      if (state == ST_READ_WAIT) state <= ST_READ_LOAD;
      if (state == ST_READ_LOAD) begin
        if (reading_crc) begin
          crc_shift <= packet_read_data; state <= ST_CRC;
        end else begin
          m_axi_awaddr <= DDR_ADDR_BASE + write_offset + (write_index << 5);
          m_axi_awvalid <= 1;
          m_axi_wdata <= packet_read_data; m_axi_wstrb <= 32'hffffffff;
          m_axi_wvalid <= 1; m_axi_wlast <= 1;
          write_aw_done <= 0; write_w_done <= 0; state <= ST_WRITE;
        end
      end
      if (state == ST_CRC) begin
        data_crc_running <= crc32_bit(data_crc_running, crc_shift[0]);
        crc_shift <= {1'b0, crc_shift[255:1]};
        crc_check_bit_index <= crc_check_bit_index + 1'b1;
        if (crc_check_bit_index + 1 >= crc_check_total_bits) begin
          crc_result_ok <= ((crc32_bit(data_crc_running, crc_shift[0]) ^ 32'hffffffff) == data_crc_expected);
          state <= ST_CRC_DONE;
        end else if (crc_check_bit_index[7:0] == 8'hff) begin
          packet_read_addr <= packet_read_addr + 1'b1; state <= ST_READ_WAIT;
        end
      end
      if (state == ST_CRC_DONE) begin
        response_actual_crc <= data_crc_running ^ 32'hffffffff;
        if (!crc_result_ok) begin
          response_status <= CRC; response_error_code <= CRC;
          error_offset <= data_offset; error_count <= error_count + 1'b1;
          state <= ST_EMIT;
        end else if (duplicate_packet) begin
          state <= ST_EMIT;
        end else begin
          write_index <= 0; write_words_total <= data_length >> 5;
          write_length <= data_length; write_offset <= data_offset;
          write_aw_done <= 0; write_w_done <= 0; write_failed <= 0;
          packet_read_addr <= 0; reading_crc <= 0; state <= ST_READ_WAIT;
        end
      end else if (state == ST_EMIT) begin
        response_valid <= 1; response_seq <= command_seq; response_opcode <= command_opcode;
        if (command_opcode == OP_STATUS && status_response_latched) begin
          response_state <= status_state_latched;
          response_status <= status_status_latched;
          response_error_code <= status_error_code_latched;
          response_error_offset <= status_error_offset_latched;
          response_first_error_offset <= status_error_offset_latched;
        end else begin
          response_state <= playback_state;
          response_error_offset <= error_offset;
          response_first_error_offset <= error_offset;
        end
        response_ack_packet_seq <= next_packet_seq - 1'b1;
        response_next_expected_sequence <= next_packet_seq;
        response_received_bytes <= received_bytes;
        if (command_is_bulk_query) begin
          // Same wire layout as a DATA response, carrying the bulk counters.
          response_ack_packet_seq <= {committed || bulk_complete, bulk_overrun, bulk_axi_error,
                                      15'd0, bulk_complete_chunks};
          response_next_expected_sequence <= bulk_first_incomplete;
          response_received_bytes <= {bulk_frames_rejected, bulk_frames_ok};
          response_first_error_offset <= {bulk_frames_stale, bulk_frames_duplicate};
          response_error_offset <= {bulk_rx_dropped_full, bulk_rx_frames};
          response_expected_crc <= bulk_rx_dropped_bad;
          response_actual_crc <= 32'd0;
        end
        state <= ST_IDLE;
      end else if (state == ST_DECODE) begin
        // One cycle for the registered predicates to see the last word.
        state <= ST_FINAL;
      end else if (state == ST_FINAL) begin
        // All fields, including the last word, are now registered. Never
        // validate and act on a final word in the same nonblocking-assignment
        // cycle: that accepted wrong-session COMMIT and truncated DATA.
        // BEGIN/COMMIT/PLAY/PAUSE/STOP/ABORT are not complete until the
        // playback path has admitted the corresponding command.  DATA and
        // STATUS do not use this gate.  Holding ST_FINAL also holds the
        // parsed request fields stable, so a full command FIFO cannot cause
        // a silent overwrite or an optimistic response.
        if (command_opcode == OP_STATUS && !packet_error) begin
          if (!status_requested) begin
            state <= ST_FINAL;
            if (status_request_ready) begin
              status_request <= 1'b1;
              status_requested <= 1'b1;
            end
          end else if (status_snapshot_valid) begin
            status_state_latched <= status_snapshot_state;
            status_status_latched <= status_snapshot_status;
            status_error_code_latched <= status_snapshot_error_code;
            status_error_offset_latched <= status_snapshot_error_offset;
            status_response_latched <= 1'b1;
            state <= ST_EMIT;
          end else begin
            state <= ST_FINAL;
          end
        end else if (command_is_bulk_query && !packet_error) begin
          // The bulk writer runs the command; answer when it has finished.
          case (bulk_phase)
            2'd0: begin
              if (dec_bulk_query_bad) begin
                set_error(BAD_REQUEST, 0); state <= ST_EMIT;
              end else if (!bulk_ctl_busy) begin
                bulk_ctl_start <= 1'b1;
                bulk_ctl_cmd <= command_opcode == OP_BULK_STATUS ? BULK_CMD_SCAN : BULK_CMD_CHUNK_RESET;
                bulk_ctl_arg <= command_session_word[52:32];
                bulk_phase <= 2'd1;
              end
            end
            2'd1: bulk_phase <= 2'd2;
            default: if (!bulk_ctl_busy) state <= ST_EMIT;
          endcase
        end else if ((command_opcode_requires_admission && !command_ready) || begin_waits_for_bulk) begin
          state <= ST_FINAL;
        end else begin
          state <= ST_EMIT;
        end
        if (!packet_error && command_opcode != OP_STATUS && !command_is_bulk_query &&
            (!command_opcode_requires_admission || command_ready) && !begin_waits_for_bulk) begin
          if (command_opcode == OP_BEGIN) begin
            if (dec_begin_bad) begin
              set_error(BAD_REQUEST, 0);
            end else if (dec_begin_repeat) begin
              if (dec_begin_mismatch) set_error(BAD_REQUEST, 0);
            end else begin
              session <= begin_session; total_bytes <= begin_total_bytes;
              total_beats <= begin_total_beats; channel_mask <= begin_channel_mask;
              loop_count <= begin_loop_count; ddr_base_addr <= DDR_ADDR_BASE;
              received_bytes <= 0; next_packet_seq <= 0; descriptor <= 0;
              upload_active <= 1; committed <= 0; last_data_valid <= 0; last_play_valid <= 0;
              last_begin_request <= command_seq; error_offset <= 0;
              begin_valid <= 1;
              bulk_mode <= begin_is_bulk;
              if (begin_is_bulk) begin
                bulk_ctl_start <= 1'b1; bulk_ctl_cmd <= BULK_CMD_CLEAR; bulk_ctl_arg <= 21'd0;
              end
            end
          end else if (command_opcode == OP_DATA) begin
            response_expected_crc <= data_crc_expected;
            if (dec_data_bad) set_error(BAD_REQUEST, data_offset);
            else if (!data_range_ok) set_error(RANGE, data_offset);
            else if (dec_data_duplicate) begin
              duplicate_packet <= 1;
              data_crc_running <= 32'hffffffff; crc_check_bit_index <= 0;
              crc_check_total_bits <= data_length[13:0] << 3;
              packet_read_addr <= 0; reading_crc <= 1; state <= ST_READ_WAIT;
            end else if (dec_data_seq_bad) set_error(SEQUENCE, data_offset);
            else if (!data_offset_ok) set_error(OFFSET, data_offset);
            else begin
              data_crc_running <= 32'hffffffff; crc_check_bit_index <= 0;
              crc_check_total_bits <= data_length[13:0] << 3;
              packet_read_addr <= 0; reading_crc <= 1; state <= ST_READ_WAIT;
            end
          end else if (dec_session_bad) begin
            set_error(BAD_REQUEST, received_bytes);
          end else if (command_opcode == OP_COMMIT) begin
            if (committed && last_commit_request == command_seq) begin end
            else if (!upload_active || session == 0 || playback_state == 8) set_error(BAD_REQUEST, received_bytes);
            else if (dec_commit_incomplete) set_error(INCOMPLETE, received_bytes);
            else if (bulk_mode && bulk_axi_error) set_error(AXI_ERROR, 0);
            else begin
              generation <= next_generation; descriptor <= next_generation;
              committed <= 1; upload_active <= 0; last_commit_request <= command_seq;
              commit_valid <= 1;
            end
          end else if (command_opcode == OP_PLAY) begin
            if (last_play_valid && last_play_request == command_seq) begin end
            else if (!committed || !(playback_state == 2 || playback_state == 3 ||
                                    playback_state == 4 || playback_state == 7)) set_error(UNSAFE, 0);
            else begin play_valid <= 1; last_play_request <= command_seq; last_play_valid <= 1; end
          end else if (command_opcode == OP_PAUSE || command_opcode == OP_STOP) begin
            if (upload_active && command_opcode == OP_STOP) begin
              session <= 0; descriptor <= 0; upload_active <= 0; received_bytes <= 0;
              next_packet_seq <= 0; last_data_valid <= 0; stop_valid <= 1;
            end else if (!committed || playback_state == 8) set_error(UNSAFE, 0);
            else if (command_opcode == OP_STOP) stop_valid <= 1;
            else pause_valid <= 1;
          end else if (command_opcode == OP_ABORT) begin
            abort_valid <= 1; session <= 0; descriptor <= 0; received_bytes <= 0;
            next_packet_seq <= 0; error_offset <= 0; error_count <= 0;
            committed <= 0; upload_active <= 0; last_data_valid <= 0; last_play_valid <= 0;
          end
        end
      end else if (udp_tvalid && (state == ST_IDLE || state == ST_HDR0 || state == ST_HDR1 ||
                                 state == ST_PAYLOAD || state == ST_DROP)) begin
        case (state)
          ST_IDLE: if (!rx_active && !response_valid && !udp_tlast && udp_tdata == CTRL_MAGIC) begin
            state <= ST_HDR0; packet_error <= 0; response_status <= OK; response_error_code <= 0;
            response_expected_crc <= 0; response_actual_crc <= 0;
          end
          ST_HDR0: begin
            command_opcode <= udp_tdata[63:32];
            if (udp_tdata[31:0] != 32'd1 || udp_tdata[63:32] < 1 || udp_tdata[63:32] > OP_BULK_CHUNK_RESET)
              set_error(BAD_REQUEST, 0);
          bulk_phase <= 2'd0;
          status_requested <= 1'b0;
          status_response_latched <= 1'b0;
            state <= udp_tlast ? ST_IDLE : ST_HDR1;
          end
          ST_HDR1: begin
            command_seq <= udp_tdata[31:0]; payload_bytes <= udp_tdata[63:32];
            payload_words <= (udp_tdata[63:32] >> 3) + (|udp_tdata[34:32]);
            payload_index <= 0; data_word_index <= 0; duplicate_packet <= 0;
            payload_at_last <= udp_tdata[63:32] != 0 && udp_tdata[63:32] <= 32'd8;
            if (udp_tlast) begin set_error(BAD_REQUEST, 0); state <= ST_EMIT; end
            else if ((command_opcode == OP_BEGIN && udp_tdata[63:32] != 28) ||
                     (command_opcode == OP_DATA && (udp_tdata[63:32] < 56 || udp_tdata[63:32] > MAX_PAYLOAD_BYTES+24)) ||
                     (command_opcode == OP_BULK_CHUNK_RESET && udp_tdata[63:32] != 8) ||
                     (command_opcode >= OP_COMMIT && command_opcode != OP_BULK_CHUNK_RESET &&
                      udp_tdata[63:32] != 4)) begin
              set_error(BAD_REQUEST, 0); state <= ST_DROP;
            end else state <= ST_PAYLOAD;
          end
          ST_DROP: if (udp_tlast) state <= ST_EMIT;
          ST_PAYLOAD: begin
            if (command_opcode == OP_BEGIN) begin
              case (payload_index)
                0: begin begin_session <= udp_tdata[31:0]; begin_total_bytes[31:0] <= udp_tdata[63:32]; end
                1: begin begin_total_bytes[63:32] <= udp_tdata[31:0]; begin_channel_mask <= udp_tdata[39:32];
                         begin_layout <= udp_tdata[47:40]; begin_reserved <= udp_tdata[63:48]; end
                2: begin begin_total_beats <= udp_tdata[31:0]; begin_loop_count <= udp_tdata[63:32]; end
                3: begin begin_bytes_per_beat <= udp_tdata[31:0];
                         if (udp_tdata[63:32] != 0) set_error(BAD_REQUEST, 0); end
              endcase
            end else if (command_opcode == OP_DATA) begin
              case (payload_index)
                0: begin data_session <= udp_tdata[31:0]; data_packet_seq <= udp_tdata[63:32]; end
                1: data_offset <= udp_tdata;
                2: begin
                     data_length <= udp_tdata[31:0]; data_crc_expected <= udp_tdata[63:32];
                     // Latch the wide validation predicates now (headers are
                     // complete) so ST_FINAL reads registered 1-bit flags
                     // instead of a 64-bit subtract / length cone on the
                     // 300 MHz response clock-enable path.
                     data_range_ok <= (udp_tdata[31:0] != 32'd0) &&
                                      (udp_tdata[31:0] <= MAX_PAYLOAD_BYTES) &&
                                      (udp_tdata[4:0] == 5'd0) &&
                                      (payload_bytes == udp_tdata[31:0] + 32'd24);
                     data_offset_ok <= (data_offset[4:0] == 5'd0) &&
                                       (data_offset == received_bytes) &&
                                       (data_offset <= total_bytes) &&
                                       (udp_tdata[31:0] <= total_bytes - data_offset);
                   end
                default: if (data_word_index < MAX_DATA_WORDS) begin
                  data_word_index <= data_word_index + 1'b1;
                end
              endcase
            end else command_session_word <= udp_tdata;
            if (udp_tlast) begin
              if (!payload_at_last) set_error(BAD_REQUEST, 0);
              state <= ST_DECODE;
            end else if (payload_at_last) begin
              set_error(BAD_REQUEST, 0); state <= ST_DROP;
            end else begin
              payload_index <= payload_index + 1'b1;
              payload_at_last <= payload_index + 32'd2 == payload_words;
            end
          end
        endcase
      end
    end
  end
endmodule
