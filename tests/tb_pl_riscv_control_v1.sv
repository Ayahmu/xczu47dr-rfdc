`timescale 1ns / 1ps

// pl_riscv_control_v1: RFCTRL2 request decode and RFRESP2 serialization.
module tb_pl_riscv_control_v1;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg         rvctrl_tvalid = 1'b0;
  reg [63:0]  rvctrl_tdata = 64'd0;
  reg         rvctrl_tfirst = 1'b0;
  reg         rvctrl_tlast = 1'b0;
  reg [31:0]  rvctrl_word_count = 32'd0;

  wire         rfdc_apply_start;
  wire [31:0]  rfdc_apply_sequence;
  wire [31:0]  rfdc_apply_revision;
  wire [7:0]   rfdc_apply_channel_mask;
  wire [511:0] rfdc_apply_nco_hz;
  wire [15:0]  rfdc_apply_nyquist_zone;
  wire [255:0] rfdc_apply_phase_mdeg;
  wire [255:0] rfdc_apply_current_ua;
  reg          rfdc_apply_busy = 1'b0;
  reg          rfdc_apply_done = 1'b0;
  reg [15:0]   rfdc_apply_status = 16'd0;
  reg [31:0]   rfdc_result_revision = 32'd0;
  reg [7:0]    rfdc_result_applied_mask = 8'd0;
  reg [7:0]    rfdc_result_error_mask = 8'd0;
  reg [7:0]    rfdc_config_valid_mask = 8'hFF;
  reg [31:0]   rfdc_failure_stage = 32'd0;
  reg [17:0]   rfdc_failure_address = 18'd0;
  reg [1:0]    rfdc_failure_axi_response = 2'd0;
  reg [511:0]  rfdc_actual_nco_hz = 512'd0;
  reg [15:0]   rfdc_actual_nyquist_zone = 16'd0;
  reg [255:0]  rfdc_actual_phase_mdeg = 256'd0;
  reg [255:0]  rfdc_actual_current_ua = 256'd0;
  reg [255:0]  rfdc_channel_status = 256'd0;
  reg [511:0]  rfdc_actual_nco_word = 512'd0;
  reg [255:0]  rfdc_actual_phase_word = 256'd0;
  reg [255:0]  rfdc_actual_vop_code = 256'd0;
  wire [63:0] rvresp_tdata;
  wire        rvresp_tvalid;
  reg         rvresp_tready = 1'b1;
  wire        rvresp_tlast;
  wire [15:0] rvresp_word_count;

  reg rfdc_apply_start_seen = 1'b0;
  integer response_packet_count = 0;
  reg [63:0] resp_words [0:47];
  reg [5:0] resp_count = 6'd0;
  reg signed [63:0] request_nco [0:7];
  reg [31:0] request_zone [0:7];
  reg signed [31:0] request_phase [0:7];
  reg [31:0] request_current [0:7];
  integer channel;
  integer packet_beat;
  wire tdc_valid, tdc_write;
  wire [15:0] tdc_address;
  wire [31:0] tdc_wdata;
  reg tdc_ready = 0;
  reg [31:0] tdc_rdata = 0;

  pl_riscv_control_v1 #(
    .TDC_REG_TIMEOUT_CYCLES(32),
    .SOURCE_COMMIT_ID(32'h89ABCDEF)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .rvctrl_tvalid(rvctrl_tvalid),
    .rvctrl_tdata(rvctrl_tdata),
    .rvctrl_tfirst(rvctrl_tfirst),
    .rvctrl_tlast(rvctrl_tlast),
    .rvctrl_word_count(rvctrl_word_count),
    .rfdc_apply_start(rfdc_apply_start),
    .rfdc_apply_sequence(rfdc_apply_sequence),
    .rfdc_apply_revision(rfdc_apply_revision),
    .rfdc_apply_channel_mask(rfdc_apply_channel_mask),
    .rfdc_apply_nco_hz(rfdc_apply_nco_hz),
    .rfdc_apply_nyquist_zone(rfdc_apply_nyquist_zone),
    .rfdc_apply_phase_mdeg(rfdc_apply_phase_mdeg),
    .rfdc_apply_current_ua(rfdc_apply_current_ua),
    .rfdc_apply_busy(rfdc_apply_busy),
    .rfdc_apply_done(rfdc_apply_done),
    .rfdc_apply_status(rfdc_apply_status),
    .rfdc_result_revision(rfdc_result_revision),
    .rfdc_result_applied_mask(rfdc_result_applied_mask),
    .rfdc_result_error_mask(rfdc_result_error_mask),
    .rfdc_config_valid_mask(rfdc_config_valid_mask),
    .rfdc_failure_stage(rfdc_failure_stage),
    .rfdc_failure_address(rfdc_failure_address),
    .rfdc_failure_axi_response(rfdc_failure_axi_response),
    .rfdc_ready(1'b1),
    .dac_mts_required(1'b1), .dac_mts_ready(1'b1), .dac_mts_failed(1'b0),
    .dac_mts_tile_mask(4'hF), .dac_mts_error(16'd0),
    .nco_sync_ready(1'b1), .nco_sync_epoch(32'd7),
    .playback_armed(1'b0),
    .playback_prepared(1'b0),
    .playback_running(1'b0),
    .ext_trigger_phase_slot(3'd2), .ext_trigger_phase_valid(1'b1),
    .ext_trigger_phase_overflow(1'b0), .ext_trigger_phase_metastable(1'b0),
    .ext_trigger_tap_index(8'd137), .ext_trigger_phase_ps_x10(16'd1234),
    .tdc_reg_valid(tdc_valid), .tdc_reg_write(tdc_write), .tdc_reg_addr(tdc_address),
    .tdc_reg_wdata(tdc_wdata), .tdc_reg_ready(tdc_ready), .tdc_reg_rdata(tdc_rdata), .tdc_reg_error(16'd0),
    .rfdc_actual_nco_hz(rfdc_actual_nco_hz),
    .rfdc_actual_nyquist_zone(rfdc_actual_nyquist_zone),
    .rfdc_actual_phase_mdeg(rfdc_actual_phase_mdeg),
    .rfdc_actual_current_ua(rfdc_actual_current_ua),
    .rfdc_channel_status(rfdc_channel_status),
    .rfdc_actual_nco_word(rfdc_actual_nco_word),
    .rfdc_actual_phase_word(rfdc_actual_phase_word),
    .rfdc_actual_vop_code(rfdc_actual_vop_code),
    .network_apply_start(),
    .network_apply_revision(),
    .network_apply_ip(),
    .network_apply_mac(),
    .network_apply_subnet(),
    .network_apply_gateway(),
    .network_apply_port(),
    .network_restart_start(),
    .network_busy(1'b0),
    .network_done(1'b0),
    .network_status(16'd0),
    .network_result_revision(32'd0),
    .network_current_ip(32'hA9FE7E42),
    .network_current_mac(64'h020000000042),
    .network_current_subnet(32'hFFFF0000),
    .network_current_gateway(32'd0),
    .network_current_port(16'd1234),
    .network_device_uid(64'h0000000047D00042),
    .network_bootstrap_mac(64'h020000000001),
    .network_bootstrap_ip(32'hC0A8FEFE),
    .network_capabilities(32'h00040000),
    .network_status_flags(32'd0),
    .network_link_state(16'h0001),
    .play_config_channel_mask(8'h03),
    .play_fifo_valid_mask(8'h02),
    .play_fifo_ready_mask(8'h0F),
    .play_prefill_ready(1'b1),
    .rvresp_tdata(rvresp_tdata),
    .rvresp_tvalid(rvresp_tvalid),
    .rvresp_tready(rvresp_tready),
    .rvresp_tlast(rvresp_tlast),
    .rvresp_word_count(rvresp_word_count)
  );

  always @(posedge clk) begin
    if (rst_n) begin
      if (rvresp_tvalid && rvresp_tready && resp_count < 6'd48) begin
        resp_words[resp_count] <= rvresp_tdata;
        resp_count <= resp_count + 6'd1;
      end
      if (rvresp_tvalid && rvresp_tready && rvresp_tlast)
        response_packet_count <= response_packet_count + 1;
      if (rfdc_apply_start) begin
        rfdc_apply_start_seen <= 1'b1;
      end
    end
  end

  // One framed request beat.  count[28:0] is the request length in 32-bit
  // words; the upper bits are ignored so the request words below can keep the
  // 0xA000_00nn annotation that marks them as RFCTRL2 frames.
  task send_rv_beat(
    input [63:0] word,
    input first,
    input last,
    input [31:0] count
  );
    begin
      @(negedge clk);
      rvctrl_tdata = word;
      rvctrl_tfirst = first;
      rvctrl_tlast = last;
      rvctrl_word_count = {3'd0, count[28:0]};
      rvctrl_tvalid = 1'b1;
      @(negedge clk);
      rvctrl_tvalid = 1'b0;
      rvctrl_tfirst = 1'b0;
      rvctrl_tlast = 1'b0;
      rvctrl_word_count = 32'd0;
      rvctrl_tdata = 64'd0;
    end
  endtask

  task check_condition(input condition, input string message);
    begin
      if (!condition) begin
        $display("FAIL: %s", message);
        $finish;
      end
    end
  endtask

  task wait_for_response_count(input integer expected_count);
    integer timeout_cycles;
    begin
      timeout_cycles = 0;
      while ((resp_count < expected_count) && (timeout_cycles < 64)) begin
        @(negedge clk);
        timeout_cycles = timeout_cycles + 1;
      end
      repeat (2) @(negedge clk);
    end
  endtask

  // A complete, well-formed request with an opcode this board does not
  // implement must be answered with UNSUPPORTED and nothing else.
  task check_unsupported_opcode(input [31:0] opcode, input [31:0] seq);
    begin
      resp_count = 6'd0;
      send_rv_beat({opcode, 32'h00000003}, 1'b1, 1'b0, 32'hA0000006);
      send_rv_beat({32'd8, seq}, 1'b0, 1'b0, 32'hA0000006);
      send_rv_beat(64'h0000000000000000, 1'b0, 1'b1, 32'hA0000006);
      wait_for_response_count(3);
      check_condition(resp_count == 6'd3, "unsupported opcode must receive a response");
      check_condition(resp_words[0] == 64'h0032505345524652, "unsupported response magic mismatch");
      check_condition(resp_words[1] == {opcode, 16'h0002, 16'h0003},
                      "unsupported opcode must report UNSUPPORTED");
      check_condition(resp_words[2] == {32'd0, seq}, "unsupported response sequence mismatch");
    end
  endtask

  initial begin
    repeat (20) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // Playback is controlled only through WAVECTR0, and the multi-board SYNC,
    // START_AT and diagnostic-snapshot operations do not exist on this board.
    check_unsupported_opcode(32'h00000006, 32'h00000088); // ARM
    check_unsupported_opcode(32'h00000007, 32'h00000089); // SYNC_EPOCH
    check_unsupported_opcode(32'h00000008, 32'h0000008A); // START_AT
    check_unsupported_opcode(32'h00000009, 32'h0000008B); // TRIGGER
    check_unsupported_opcode(32'h0000000A, 32'h0000008C); // ABORT_MUTE
    check_unsupported_opcode(32'h0000000F, 32'h0000008D); // SET_SYNC_ROLE
    check_unsupported_opcode(32'h00000010, 32'h0000008E); // EMIT_TRIGGER
    check_unsupported_opcode(32'h00000012, 32'h0000008F); // DIAG_SNAPSHOT
    check_unsupported_opcode(32'h00000013, 32'h00000090); // DIAG_CONTROL
    check_condition(!rfdc_apply_start_seen, "unsupported opcodes must not start an RFDC apply");

    // A request carrying another protocol version is rejected as BAD_VERSION.
    resp_count = 6'd0;
    send_rv_beat(64'h0000000200000002, 1'b1, 1'b0, 32'hA0000004);
    send_rv_beat(64'h0000000000000077, 1'b0, 1'b1, 32'hA0000004);
    wait_for_response_count(3);
    check_condition(resp_count == 6'd3, "bad-version request must receive a response");
    check_condition(resp_words[1] == 64'h0000000200010003, "bad-version status mismatch");

    resp_count = 6'd0;
    send_rv_beat(64'h0000000200000003, 1'b1, 1'b0, 32'hA0000004);
    send_rv_beat(64'h000000100000008A, 1'b0, 1'b1, 32'hA0000004);
    wait_for_response_count(19);
    check_condition(resp_count == 6'd19, "RFCTRL2 STATUS should emit a 19-word RFRESP2 packet");
    check_condition(resp_words[0] == 64'h0032505345524652, "RFRESP2 STATUS magic mismatch");
    check_condition(resp_words[1] == 64'h0000000200000003, "RFRESP2 STATUS header mismatch");
    check_condition(resp_words[2] == 64'h000000800000008A, "RFRESP2 STATUS sequence mismatch");
    // state flags: MTS required | NCO sync | MTS ready | RFDC ready; capabilities 0x005F0000.
    check_condition(resp_words[3] == 64'h000001A1005F0000, "RFRESP2 STATUS flags/capabilities mismatch");
    check_condition(resp_words[7] == 64'h0000000200000003, "RFRESP2 STATUS channel/fifo-valid masks mismatch");
    check_condition(resp_words[8] == 64'h000000000000000F, "RFRESP2 STATUS fifo-ready mask mismatch");
    check_condition(resp_words[9] == 64'd0, "RFRESP2 STATUS reserved word 9 must be zero");
    check_condition(resp_words[10] == 64'h0000000000000001, "RFRESP2 STATUS prefill flag mismatch");
    check_condition(resp_words[11] == 64'h00000007000000F5, "RFRESP2 STATUS MTS/NCO sync mismatch");
    // The trigger-path version occupies bits 63:32 of this word.
    check_condition(resp_words[12] == 64'h0000000300000000, "RFRESP2 STATUS trigger path version mismatch");
    check_condition(resp_words[13] == 64'd0 && resp_words[14] == 64'd0 && resp_words[15] == 64'd0,
                    "RFRESP2 STATUS reserved words 13..15 must be zero");
    check_condition(resp_words[16] == 64'h89ABCDEF00010000,
                    "RFRESP2 STATUS source commit and build profile mismatch");
    check_condition(resp_words[17] == 64'h0000000004D2890A, "RFRESP2 STATUS TDC fields mismatch");
    check_condition(resp_words[18] == 64'd0, "RFRESP2 STATUS reserved word 18 must be zero");

    // HELLO shares the status serializer.
    resp_count = 0;
    send_rv_beat(64'h0000000100000003, 1'b1, 1'b0, 32'hA0000004);
    send_rv_beat(64'h00000000000000B0, 1'b0, 1'b1, 32'hA0000004);
    wait_for_response_count(19);
    check_condition(resp_count == 19, "RFCTRL2 HELLO response length mismatch");
    check_condition(resp_words[1] == 64'h0000000100000003, "RFCTRL2 HELLO header mismatch");
    check_condition(resp_words[16] == 64'h89ABCDEF00010000, "RFCTRL2 HELLO identity mismatch");

    resp_count = 0;
    send_rv_beat(64'h0000001100000003, 1'b1, 1'b0, 32'hA0000008);
    send_rv_beat(64'h00000010000000A1, 1'b0, 1'b0, 32'hA0000008);
    send_rv_beat(64'h0000104000000000, 1'b0, 1'b0, 32'hA0000008);
    send_rv_beat(64'd0, 1'b0, 1'b1, 32'hA0000008);
    repeat (8) @(negedge clk);
    check_condition(tdc_valid && !tdc_write && tdc_address == 16'h1040,
                    "TDC register read was not dispatched");
    check_condition(resp_count == 0, "TDC response preceded register completion");
    tdc_rdata = 32'h12345678; tdc_ready = 1;
    @(negedge clk); tdc_ready = 0;
    wait_for_response_count(4);
    check_condition(resp_words[1] == 64'h0000001100000003, "TDC response opcode/status mismatch");
    check_condition(resp_words[2] == 64'h00000008000000A1, "TDC response length/sequence mismatch");
    check_condition(resp_words[3] == 64'h1234567800001040, "TDC read payload mismatch");

    resp_count = 0;
    send_rv_beat(64'h0000001100000003, 1'b1, 1'b0, 32'hA0000008);
    send_rv_beat(64'h00000010000000A2, 1'b0, 1'b0, 32'hA0000008);
    send_rv_beat(64'h0000000400000001, 1'b0, 1'b0, 32'hA0000008);
    send_rv_beat(64'h0000000000000005, 1'b0, 1'b1, 32'hA0000008);
    wait_for_response_count(4);
    check_condition(resp_words[1] == 64'h0000001100090003, "TDC timeout status mismatch");
    check_condition(!tdc_valid, "TDC timeout did not release request");

    // RFCTRL2 RFDC_APPLY: 4 header words plus a fixed 200-byte payload.
    request_nco[0] = -64'sd1900000000;
    request_nco[1] = 64'sd100000000;
    request_nco[2] = 64'sd200000000;
    request_nco[3] = 64'sd300000000;
    request_nco[4] = 64'sd0;
    request_nco[5] = 64'sd0;
    request_nco[6] = -64'sd600000000;
    request_nco[7] = -64'sd200000000;
    for (channel = 0; channel < 8; channel = channel + 1) begin
      request_zone[channel] = (channel == 0 || channel >= 6) ? 32'd2 : 32'd1;
      request_phase[channel] = -32'sd45000 + channel * 32'sd15000;
      request_current[channel] = (channel == 4 || channel == 5) ? 32'd12000 : 32'd20500;
    end
    resp_count = 6'd0;
    rfdc_apply_start_seen = 1'b0;
    send_rv_beat(64'h0000000300000003, 1'b1, 1'b0, 32'hA0000036);
    send_rv_beat(64'h000000C800000091, 1'b0, 1'b0, 32'hA0000036);
    send_rv_beat(64'h000000A500000004, 1'b0, 1'b0, 32'hA0000036);
    for (channel = 0; channel < 8; channel = channel + 1) begin
      send_rv_beat(request_nco[channel], 1'b0, 1'b0, 32'hA0000036);
      send_rv_beat({request_phase[channel], request_zone[channel]}, 1'b0, 1'b0, 32'hA0000036);
      send_rv_beat({32'd0, request_current[channel]}, 1'b0, channel == 7, 32'hA0000036);
    end
    repeat (4) @(negedge clk);
    check_condition(rfdc_apply_start_seen, "RFDC_APPLY must start the dedicated PL controller");
    check_condition(rfdc_apply_sequence == 32'h91, "RFDC_APPLY sequence mismatch");
    check_condition(rfdc_apply_revision == 32'd4, "RFDC_APPLY revision mismatch");
    check_condition(rfdc_apply_channel_mask == 8'hA5, "RFDC_APPLY channel mask mismatch");
    check_condition($signed(rfdc_apply_nco_hz[0 +: 64]) == -64'sd1900000000, "RFDC_APPLY CH1 NCO mismatch");
    check_condition($signed(rfdc_apply_nco_hz[448 +: 64]) == -64'sd200000000, "RFDC_APPLY CH8 NCO mismatch");
    check_condition(rfdc_apply_nyquist_zone[0 +: 2] == 2'd2, "RFDC_APPLY CH1 zone mismatch");
    check_condition(rfdc_apply_phase_mdeg[224 +: 32] == request_phase[7], "RFDC_APPLY CH8 phase mismatch");
    check_condition(rfdc_apply_current_ua[128 +: 32] == 32'd12000, "RFDC_APPLY CH5 current mismatch");
    check_condition(resp_count == 6'd0, "RFDC_APPLY must wait for PL register readback before replying");

    rfdc_apply_status = 16'd0;
    rfdc_result_revision = 32'd4;
    rfdc_result_applied_mask = 8'hA5;
    rfdc_result_error_mask = 8'h00;
    rfdc_config_valid_mask = 8'hA5;
    rfdc_actual_nco_hz[0 +: 64] = request_nco[0];
    rfdc_actual_nco_hz[448 +: 64] = request_nco[7];
    rfdc_actual_nyquist_zone[0 +: 2] = 2'd2;
    rfdc_actual_phase_mdeg[224 +: 32] = request_phase[7];
    rfdc_actual_current_ua[128 +: 32] = 32'd11987;
    @(negedge clk);
    rfdc_apply_done = 1'b1;
    @(negedge clk);
    rfdc_apply_done = 1'b0;
    wait_for_response_count(47);
    check_condition(resp_count == 6'd47, "RFDC_APPLY should emit a 47-word RFRESP2 packet");
    check_condition(resp_words[0] == 64'h0032505345524652, "RFRESP2 RFDC_APPLY magic mismatch");
    check_condition(resp_words[1] == 64'h0000000300000003, "RFRESP2 RFDC_APPLY header mismatch");
    check_condition(resp_words[2] == 64'h0000016000000091, "RFRESP2 RFDC_APPLY length/sequence mismatch");
    check_condition(resp_words[3] == 64'h000000A500000004, "RFRESP2 RFDC_APPLY revision/applied mask mismatch");
    check_condition(resp_words[4] == 64'h000000A500000000, "RFRESP2 RFDC_APPLY error/config mask mismatch");
    check_condition(resp_words[7] == request_nco[0], "RFRESP2 RFDC_APPLY CH1 actual NCO mismatch");
    check_condition(resp_words[42] == request_nco[7], "RFRESP2 RFDC_APPLY CH8 actual NCO mismatch");

    // A non-zero reserved word in the final channel record must be latched
    // on the last beat and reject the request before the RFDC FSM starts.
    resp_count = 6'd0;
    rfdc_apply_start_seen = 1'b0;
    send_rv_beat(64'h0000000300000003, 1'b1, 1'b0, 32'hA0000036);
    send_rv_beat(64'h000000C800000095, 1'b0, 1'b0, 32'hA0000036);
    send_rv_beat(64'h0000000100000005, 1'b0, 1'b0, 32'hA0000036);
    for (channel = 0; channel < 8; channel = channel + 1) begin
      send_rv_beat(64'd0, 1'b0, 1'b0, 32'hA0000036);
      send_rv_beat(64'h0000000000000001, 1'b0, 1'b0, 32'hA0000036);
      send_rv_beat(
          {channel == 7 ? 32'd1 : 32'd0, 32'd20000},
          1'b0,
          channel == 7,
          32'hA0000036
      );
    end
    wait_for_response_count(3);
    check_condition(!rfdc_apply_start_seen, "RFDC_APPLY must reject a non-zero final reserved word");
    check_condition(resp_words[1] == 64'h0000000300030003, "invalid RFDC_APPLY status mismatch");

    // The receive counters must accept the full 64-word request and drop an
    // oversized one without wrapping the write index.  Both carry opcode
    // 0x1234, so only the request that is processed is answered.
    resp_count = 6'd0;
    for (packet_beat = 0; packet_beat < 32; packet_beat = packet_beat + 1) begin
      send_rv_beat(
          packet_beat == 0 ? 64'h0000123400000003 :
          packet_beat == 1 ? 64'h000000F0000000D1 :
                             {32'hA5000000 + packet_beat, 32'h5A000000 + packet_beat},
          packet_beat == 0,
          packet_beat == 31,
          32'd64
      );
    end
    wait_for_response_count(3);
    check_condition(resp_count == 6'd3, "64-word boundary request must be processed");
    check_condition(resp_words[1] == 64'h0000123400020003, "64-word boundary request status mismatch");
    check_condition(resp_words[2] == 64'h00000000000000D1, "64-word boundary request sequence mismatch");

    resp_count = 6'd0;
    for (packet_beat = 0; packet_beat < 33; packet_beat = packet_beat + 1) begin
      send_rv_beat(
          packet_beat == 0 ? 64'h0000123400000003 :
          packet_beat == 1 ? 64'h000000F4000000D2 :
                             {32'hC3000000 + packet_beat, 32'h3C000000 + packet_beat},
          packet_beat == 0,
          packet_beat == 32,
          32'd65
      );
    end
    repeat (16) @(negedge clk);
    check_condition(resp_count == 6'd0, "65-word request must be dropped without index wrap");

    // Hold the first response under backpressure and issue a second STATUS.
    // The second response must be retained in the response FIFO rather than
    // being silently discarded while the first packet is still stalled.
    resp_count = 6'd0;
    response_packet_count = 0;
    rvresp_tready = 1'b0;
    send_rv_beat(64'h0000000200000003, 1'b1, 1'b0, 32'hA0000004);
    send_rv_beat(64'h000000000000AA01, 1'b0, 1'b1, 32'hA0000004);
    repeat (20) @(negedge clk);
    send_rv_beat(64'h0000000200000003, 1'b1, 1'b0, 32'hA0000004);
    send_rv_beat(64'h000000000000AA02, 1'b0, 1'b1, 32'hA0000004);
    repeat (20) @(negedge clk);
    check_condition(dut.resp_request_valid || dut.resp_request_valid2,
                    "second STATUS response must be retained while first is stalled");
    rvresp_tready = 1'b1;
    repeat (100) @(negedge clk);
    check_condition(response_packet_count == 2,
                    "both queued STATUS responses must be transmitted");

    $display("PASS: RFCTRL2 control decodes STATUS/TDC/RFDC_APPLY and rejects unsupported operations");
    $finish;
  end
endmodule
