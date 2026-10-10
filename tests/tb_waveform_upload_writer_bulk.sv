`timescale 1ns/1ps
// WAVECTR0 control side of the bulk upload path.
//
// BEGIN with layout 2 opens a bulk session: DATA packets are refused, the
// bulk writer is armed with CLEAR, BULK_STATUS (9) runs a SCAN and returns the
// bulk writer's counters, BULK_CHUNK_RESET (10) forwards {epoch, chunk}, and
// COMMIT is accepted only when the bulk writer reports the image complete.
module tb_waveform_upload_writer_bulk;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, udp_tvalid=0, udp_tlast=0; reg [63:0] udp_tdata=0;
  wire response_valid; wire [31:0] response_seq, response_opcode, response_error_code;
  wire [15:0] response_status; wire [63:0] response_error_offset;
  wire [31:0] response_state, response_ack_packet_seq, response_next_expected_sequence;
  wire [63:0] response_received_bytes, response_first_error_offset;
  wire [31:0] response_expected_crc, response_actual_crc;
  wire [31:0] session, descriptor; reg [31:0] playback_state=0;
  wire [3:0] state; wire begin_valid, commit_valid, play_valid, pause_valid, stop_valid, abort_valid;
  wire [63:0] ddr_base_addr, total_bytes; wire [31:0] total_beats, loop_count; wire [7:0] channel_mask;
  wire [63:0] m_axi_awaddr; wire m_axi_awvalid; wire [255:0] m_axi_wdata; wire [31:0] m_axi_wstrb;
  wire m_axi_wvalid, m_axi_wlast, m_axi_bready, status_request;
  wire [63:0] received_bytes, error_offset; wire [31:0] next_packet_seq, error_count;

  wire bulk_enable, bulk_ctl_start; wire [1:0] bulk_ctl_cmd; wire [20:0] bulk_ctl_arg;
  reg bulk_ctl_busy=0, bulk_complete=0, bulk_overrun=0, bulk_axi_error=0;
  reg [13:0] bulk_complete_chunks=0; reg [31:0] bulk_first_incomplete=0;
  reg [31:0] bulk_frames_ok=0, bulk_frames_rejected=0, bulk_frames_duplicate=0, bulk_frames_stale=0;
  reg [31:0] bulk_rx_frames=0, bulk_rx_dropped_full=0, bulk_rx_dropped_bad=0;

  waveform_upload_writer dut (
    .clk(clk), .rst_n(rst_n), .response_ready(1'b1),
    .status_request_ready(1'b1), .status_request(status_request), .status_snapshot_valid(1'b1),
    .status_snapshot_state(32'd0), .status_snapshot_status(16'd0), .status_snapshot_error_code(32'd0),
    .status_snapshot_error_offset(64'd0), .command_ready(1'b1),
    .udp_tvalid(udp_tvalid), .udp_tdata(udp_tdata), .udp_tlast(udp_tlast),
    .response_valid(response_valid), .response_seq(response_seq), .response_opcode(response_opcode),
    .response_status(response_status), .response_error_code(response_error_code),
    .response_error_offset(response_error_offset), .response_state(response_state),
    .response_ack_packet_seq(response_ack_packet_seq),
    .response_next_expected_sequence(response_next_expected_sequence),
    .response_received_bytes(response_received_bytes), .response_first_error_offset(response_first_error_offset),
    .response_expected_crc(response_expected_crc), .response_actual_crc(response_actual_crc),
    .session(session), .descriptor(descriptor), .playback_state(playback_state), .state(state),
    .begin_valid(begin_valid), .commit_valid(commit_valid), .play_valid(play_valid),
    .pause_valid(pause_valid), .stop_valid(stop_valid), .abort_valid(abort_valid),
    .ddr_base_addr(ddr_base_addr), .total_bytes(total_bytes), .total_beats(total_beats),
    .channel_mask(channel_mask), .loop_count(loop_count),
    .m_axi_awaddr(m_axi_awaddr), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(1'b1),
    .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wvalid(m_axi_wvalid),
    .m_axi_wlast(m_axi_wlast), .m_axi_wready(1'b1), .m_axi_bresp(2'b00), .m_axi_bvalid(1'b0),
    .m_axi_bready(m_axi_bready),
    .received_bytes(received_bytes), .next_packet_seq(next_packet_seq),
    .error_offset(error_offset), .error_count(error_count),
    .bulk_enable(bulk_enable), .bulk_ctl_start(bulk_ctl_start), .bulk_ctl_cmd(bulk_ctl_cmd),
    .bulk_ctl_arg(bulk_ctl_arg), .bulk_ctl_busy(bulk_ctl_busy), .bulk_complete(bulk_complete),
    .bulk_complete_chunks(bulk_complete_chunks), .bulk_first_incomplete(bulk_first_incomplete),
    .bulk_frames_ok(bulk_frames_ok), .bulk_frames_rejected(bulk_frames_rejected),
    .bulk_frames_duplicate(bulk_frames_duplicate), .bulk_frames_stale(bulk_frames_stale),
    .bulk_overrun(bulk_overrun), .bulk_axi_error(bulk_axi_error),
    .bulk_rx_frames(bulk_rx_frames), .bulk_rx_dropped_full(bulk_rx_dropped_full),
    .bulk_rx_dropped_bad(bulk_rx_dropped_bad));

  // ---- bulk writer stand-in: busy for a while after every command ----
  integer ctl_count [0:3]; reg [20:0] last_arg; integer busy_left = 0; integer busy_cycles = 30;
  integer begins = 0, commits = 0, axi_writes = 0, responses = 0;
  reg [15:0] last_status;
  initial begin ctl_count[0]=0; ctl_count[1]=0; ctl_count[2]=0; ctl_count[3]=0; end
  reg hold_busy = 0;
  always @(posedge clk) if (rst_n) begin
    if (bulk_ctl_start) begin
      if (bulk_ctl_busy) $fatal(1, "bulk command issued while the bulk writer was busy");
      ctl_count[bulk_ctl_cmd] = ctl_count[bulk_ctl_cmd] + 1; last_arg = bulk_ctl_arg;
      busy_left = busy_cycles; bulk_ctl_busy <= 1;
    end else if (busy_left > 0) busy_left = busy_left - 1;
    else if (!hold_busy) bulk_ctl_busy <= 0;
    if (begin_valid) begins = begins + 1;
    if (commit_valid) commits = commits + 1;
    if (m_axi_awvalid) axi_writes = axi_writes + 1;
    if (response_valid) begin last_status = response_status; responses = responses + 1; end
  end

  task word(input [63:0] data, input bit last); begin
    @(negedge clk); udp_tvalid=1; udp_tdata=data; udp_tlast=last;
    @(negedge clk); udp_tvalid=0; udp_tlast=0;
  end endtask
  task header(input integer op, input integer seq, input integer size); begin
    word(64'h5741564543545230, 0); word({op[31:0], 16'd0, 16'd1}, 0); word({size[31:0], seq[31:0]}, 0);
  end endtask
  // 3 MiB image, all eight channels, given layout.
  task begin_packet(input integer seq, input integer sess, input [7:0] layout); begin
    header(1, seq, 28); word({32'd3145728, sess[31:0]}, 0); word({16'd0, layout, 8'hff, 32'd0}, 0);
    word({32'd1, 32'd12288}, 0); word(64'd64, 1);
  end endtask
  task command(input integer op, input integer seq, input integer sess); begin header(op, seq, 4); word({32'd0, sess[31:0]}, 1); end endtask
  task response(input integer prior, input integer expected); integer timeout; begin
    timeout = 0; while (responses == prior && timeout < 20000) begin @(negedge clk); timeout++; end
    if (responses == prior) $fatal(1, "no response (state=%0d)", state);
    if (last_status !== expected) $fatal(1, "response status %0d, expected %0d", last_status, expected);
    repeat (3) @(negedge clk);
  end endtask

  integer n;
  initial begin
    repeat (3) @(negedge clk); rst_n = 1;

    // BULK_STATUS and BULK_CHUNK_RESET mean nothing without a bulk session.
    n = responses; command(9, 1, 0); response(n, 2);
    if (ctl_count[3] != 0) $fatal(1, "SCAN without a bulk session");

    // A bulk BEGIN waits for the bulk writer, then arms it exactly once.
    hold_busy = 1; bulk_ctl_busy = 1;
    n = responses; begin_packet(2, 7, 8'd2); repeat (20) @(negedge clk);
    if (responses != n || begins != 0) $fatal(1, "bulk BEGIN did not wait for the bulk writer");
    hold_busy = 0; response(n, 0);
    if (begins != 1 || !bulk_enable || total_bytes != 3145728) $fatal(1, "bulk BEGIN not applied");
    if (ctl_count[1] != 1) $fatal(1, "CLEAR issued %0d times", ctl_count[1]);
    n = responses; begin_packet(2, 7, 8'd2); response(n, 0);
    if (ctl_count[1] != 1 || begins != 1) $fatal(1, "retransmitted BEGIN re-armed the bulk writer");

    // The 64-bit DATA path is closed while the session is bulk.
    n = responses; header(2, 3, 24 + 64); word({32'd0, 32'd7}, 0); word(64'd0, 0); word({32'd0, 32'd64}, 0);
    repeat (7) word(64'd0, 0); word(64'd0, 1); response(n, 2);
    if (axi_writes != 0) $fatal(1, "DATA wrote DDR in a bulk session");

    // BULK_STATUS: one SCAN, response only after it finished, counters mapped.
    bulk_complete_chunks = 14'd2; bulk_first_incomplete = 32'd1; bulk_overrun = 1;
    bulk_frames_ok = 32'h0000_1111; bulk_frames_rejected = 32'h0000_2222;
    bulk_frames_duplicate = 32'h0000_3333; bulk_frames_stale = 32'h0000_4444;
    bulk_rx_frames = 32'h0000_5555; bulk_rx_dropped_full = 32'h0000_6666; bulk_rx_dropped_bad = 32'h0000_7777;
    busy_cycles = 200;
    n = responses; command(9, 4, 7); repeat (100) @(negedge clk);
    if (responses != n) $fatal(1, "BULK_STATUS answered before the scan finished");
    response(n, 0);
    if (ctl_count[3] != 1) $fatal(1, "SCAN issued %0d times", ctl_count[3]);
    if (response_opcode !== 9 || response_ack_packet_seq !== {1'b0, 1'b1, 1'b0, 15'd0, 14'd2})
      $fatal(1, "flags/complete_chunks field %h", response_ack_packet_seq);
    if (response_next_expected_sequence !== 32'd1) $fatal(1, "first_incomplete field");
    if (response_received_bytes !== {32'h2222, 32'h1111}) $fatal(1, "frames_rejected/frames_ok field");
    if (response_first_error_offset !== {32'h4444, 32'h3333}) $fatal(1, "stale/duplicate field");
    if (response_error_offset !== {32'h6666, 32'h5555}) $fatal(1, "rx_dropped_full/rx_frames field");
    if (response_expected_crc !== 32'h7777) $fatal(1, "rx_dropped_bad field");
    busy_cycles = 30;

    // COMMIT needs a complete image and no DDR write error.
    n = responses; command(3, 5, 7); response(n, 4);
    if (commits != 0) $fatal(1, "incomplete bulk COMMIT accepted");

    // BULK_CHUNK_RESET forwards {epoch, chunk}; a foreign session is refused.
    n = responses; header(10, 6, 8); word({11'd0, 8'd3, 13'd2, 32'd9}, 1); response(n, 2);
    if (ctl_count[2] != 0) $fatal(1, "CHUNK_RESET for a foreign session reached the bulk writer");
    n = responses; header(10, 7, 8); word({11'd0, 8'd3, 13'd2, 32'd7}, 1); response(n, 0);
    if (ctl_count[2] != 1 || last_arg !== {8'd3, 13'd2}) $fatal(1, "CHUNK_RESET arg %h", last_arg);

    bulk_complete = 1; bulk_axi_error = 1; bulk_overrun = 0;
    n = responses; command(3, 8, 7); response(n, 9);
    if (commits != 0) $fatal(1, "COMMIT accepted after a DDR write error");
    bulk_axi_error = 0;
    n = responses; command(3, 9, 7); response(n, 0);
    if (commits != 1) $fatal(1, "complete bulk COMMIT refused");
    if (bulk_enable) $fatal(1, "bulk writer still enabled after COMMIT");
    // The committed session can still be inspected.
    n = responses; command(9, 10, 7); response(n, 0);
    if (response_ack_packet_seq[31] !== 1'b1) $fatal(1, "complete flag missing after COMMIT");

    // An ordinary session afterwards is not a bulk session.
    n = responses; command(7, 11, 0); response(n, 0);
    n = responses; begin_packet(12, 8, 8'd1); response(n, 0);
    if (bulk_enable || ctl_count[1] != 1) $fatal(1, "layout 1 BEGIN armed the bulk writer");
    n = responses; command(9, 13, 8); response(n, 2);
    n = responses; begin_packet(14, 9, 8'd3); response(n, 2);

    $display("tb_waveform_upload_writer_bulk PASS");
    $finish;
  end
  initial begin #5_000_000; $display("tb_waveform_upload_writer_bulk FAIL (timeout)"); $finish; end
endmodule
