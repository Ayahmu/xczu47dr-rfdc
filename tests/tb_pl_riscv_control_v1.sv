`timescale 1ns / 1ps

module tb_pl_riscv_control_v1;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg         rvctrl_tvalid = 1'b0;
  reg [63:0]  rvctrl_tdata = 64'd0;
  reg         rvctrl_tfirst = 1'b0;
  reg         rvctrl_tlast = 1'b0;
  reg [31:0]  rvctrl_word_count = 32'd0;

  wire [127:0] m_instr_tdata;
  wire         m_instr_tvalid;
  reg          m_instr_tready = 1'b1;
  wire         trigger_pulse;
  wire         rfctrl2_arm_pulse;
  wire         rfctrl2_trigger_pulse;
  wire         rfctrl2_abort_mute_pulse;
  wire         rfctrl2_sync_epoch_pulse;
  wire [63:0]  rfctrl2_epoch;
  wire         rfctrl2_start_valid;
  wire [63:0]  rfctrl2_start_tick;
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
  wire [31:0] dbg_status;
  wire [31:0] dbg_last_seq;
  wire [31:0] dbg_play_count;
  wire [31:0] dbg_trigger_count;
  wire [63:0] rvresp_tdata;
  wire        rvresp_tvalid;
  reg         rvresp_tready = 1'b1;
  wire        rvresp_tlast;
  wire [15:0] rvresp_word_count;
  wire [17:0] m_axil_awaddr;
  wire        m_axil_awvalid;
  reg         m_axil_awready = 1'b1;
  wire [31:0] m_axil_wdata;
  wire [3:0]  m_axil_wstrb;
  wire        m_axil_wvalid;
  reg         m_axil_wready = 1'b1;
  reg [1:0]   m_axil_bresp = 2'b00;
  reg         m_axil_bvalid = 1'b0;
  wire        m_axil_bready;
  wire [17:0] m_axil_araddr;
  wire        m_axil_arvalid;
  reg         m_axil_arready = 1'b1;
  reg [31:0]  m_axil_rdata = 32'd0;
  reg [1:0]   m_axil_rresp = 2'b00;
  reg         m_axil_rvalid = 1'b0;
  wire        m_axil_rready;

  reg [127:0] instrs [0:8];
  reg [3:0] instr_count = 4'd0;
  reg trigger_seen = 1'b0;
  reg rfctrl2_arm_seen = 1'b0;
  reg rfctrl2_trigger_seen = 1'b0;
  reg rfctrl2_sync_seen = 1'b0;
  reg playback_prepared = 1'b0;
  reg rfdc_apply_start_seen = 1'b0;
  reg mmio_write_seen = 1'b0;
  reg mmio_read_seen = 1'b0;
  reg [17:0] mmio_write_addr = 18'd0;
  reg [31:0] mmio_write_data = 32'd0;
  reg [17:0] mmio_read_addr = 18'd0;
  reg [31:0] mmio_write_events = 32'd0;
  reg [63:0] resp_words [0:47];
  reg [5:0] resp_count = 6'd0;
  reg signed [63:0] request_nco [0:7];
  reg [31:0] request_zone [0:7];
  reg signed [31:0] request_phase [0:7];
  reg [31:0] request_current [0:7];
  integer channel;

  pl_riscv_control_v1 dut (
    .clk(clk),
    .rst_n(rst_n),
    .rvctrl_tvalid(rvctrl_tvalid),
    .rvctrl_tdata(rvctrl_tdata),
    .rvctrl_tfirst(rvctrl_tfirst),
    .rvctrl_tlast(rvctrl_tlast),
    .rvctrl_word_count(rvctrl_word_count),
    .m_instr_tdata(m_instr_tdata),
    .m_instr_tvalid(m_instr_tvalid),
    .m_instr_tready(m_instr_tready),
    .trigger_pulse(trigger_pulse),
    .rfctrl2_arm_pulse(rfctrl2_arm_pulse),
    .rfctrl2_trigger_pulse(rfctrl2_trigger_pulse),
    .rfctrl2_abort_mute_pulse(rfctrl2_abort_mute_pulse),
    .rfctrl2_sync_epoch_pulse(rfctrl2_sync_epoch_pulse),
    .rfctrl2_epoch(rfctrl2_epoch),
    .rfctrl2_start_valid(rfctrl2_start_valid),
    .rfctrl2_start_tick(rfctrl2_start_tick),
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
    .playback_armed(1'b0),
    .playback_prepared(playback_prepared),
    .playback_running(1'b0),
    .rfdc_actual_nco_hz(rfdc_actual_nco_hz),
    .rfdc_actual_nyquist_zone(rfdc_actual_nyquist_zone),
    .rfdc_actual_phase_mdeg(rfdc_actual_phase_mdeg),
    .rfdc_actual_current_ua(rfdc_actual_current_ua),
    .rfdc_channel_status(rfdc_channel_status),
    .rfdc_actual_nco_word(rfdc_actual_nco_word),
    .rfdc_actual_phase_word(rfdc_actual_phase_word),
    .rfdc_actual_vop_code(rfdc_actual_vop_code),
    .rvresp_tdata(rvresp_tdata),
    .rvresp_tvalid(rvresp_tvalid),
    .rvresp_tready(rvresp_tready),
    .rvresp_tlast(rvresp_tlast),
    .rvresp_word_count(rvresp_word_count),
    .m_axil_awaddr(m_axil_awaddr),
    .m_axil_awvalid(m_axil_awvalid),
    .m_axil_awready(m_axil_awready),
    .m_axil_wdata(m_axil_wdata),
    .m_axil_wstrb(m_axil_wstrb),
    .m_axil_wvalid(m_axil_wvalid),
    .m_axil_wready(m_axil_wready),
    .m_axil_bresp(m_axil_bresp),
    .m_axil_bvalid(m_axil_bvalid),
    .m_axil_bready(m_axil_bready),
    .m_axil_araddr(m_axil_araddr),
    .m_axil_arvalid(m_axil_arvalid),
    .m_axil_arready(m_axil_arready),
    .m_axil_rdata(m_axil_rdata),
    .m_axil_rresp(m_axil_rresp),
    .m_axil_rvalid(m_axil_rvalid),
    .m_axil_rready(m_axil_rready),
    .dbg_status(dbg_status),
    .dbg_last_seq(dbg_last_seq),
    .dbg_last_cmd(),
    .dbg_ping_count(),
    .dbg_play_count(dbg_play_count),
    .dbg_trigger_count(dbg_trigger_count),
    .dbg_mmio_write_count(),
    .dbg_error_count(),
    .dbg_scratch(),
    .dbg_state()
  );

  always @(posedge clk) begin
    if (!rst_n) begin
      instr_count <= 4'd0;
      trigger_seen <= 1'b0;
    end else begin
      if (m_instr_tvalid && m_instr_tready && instr_count < 4'd9) begin
        instrs[instr_count] <= m_instr_tdata;
        instr_count <= instr_count + 4'd1;
      end
      if (rvresp_tvalid && rvresp_tready && resp_count < 6'd48) begin
        resp_words[resp_count] <= rvresp_tdata;
        resp_count <= resp_count + 6'd1;
      end
      if (trigger_pulse) begin
        trigger_seen <= 1'b1;
      end
      if (rfctrl2_arm_pulse) begin
        rfctrl2_arm_seen <= 1'b1;
      end
      if (rfctrl2_trigger_pulse) begin
        rfctrl2_trigger_seen <= 1'b1;
      end
      if (rfctrl2_sync_epoch_pulse) begin
        rfctrl2_sync_seen <= 1'b1;
      end
      if (rfdc_apply_start) begin
        rfdc_apply_start_seen <= 1'b1;
      end
      if (m_axil_awvalid && m_axil_wvalid) begin
        mmio_write_seen <= 1'b1;
        mmio_write_addr <= m_axil_awaddr;
        mmio_write_data <= m_axil_wdata;
        mmio_write_events <= mmio_write_events + 32'd1;
        m_axil_bvalid <= 1'b1;
      end else if (m_axil_bready && m_axil_bvalid) begin
        m_axil_bvalid <= 1'b0;
      end
      if (m_axil_arvalid) begin
        mmio_read_seen <= 1'b1;
        mmio_read_addr <= m_axil_araddr;
        m_axil_rdata <= 32'hA5A500F0;
        m_axil_rvalid <= 1'b1;
      end else if (m_axil_rready && m_axil_rvalid) begin
        m_axil_rvalid <= 1'b0;
      end
    end
  end

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
      rvctrl_word_count = count;
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

  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // PLAY_INTERLEAVED, seq=0x55, bytes_per_channel=4096, auto_start=1.
    send_rv_beat(64'h0000005500000002, 1'b1, 1'b0, 32'd4);
    send_rv_beat(64'h0000000100001000, 1'b0, 1'b1, 32'd4);
    repeat (32) @(negedge clk);

    check_condition(dbg_play_count == 32'd1, "PLAY_INTERLEAVED command was not counted");
    check_condition(dbg_last_seq == 32'h55, "PLAY_INTERLEAVED seq mismatch");
    check_condition(instr_count == 4'd9, "PLAY_INTERLEAVED should emit 8 PLAY instructions plus END");
    check_condition(instrs[0] == 128'h00000000000000000000100000000412, "CH1 PLAY instruction mismatch");
    check_condition(instrs[7] == 128'h00000000000000000000100000000482, "CH8 PLAY instruction mismatch");
    check_condition(instrs[8] == 128'h000000000000000000000000000000F3, "auto-start END instruction mismatch");

    send_rv_beat(64'h0000006600000003, 1'b1, 1'b1, 32'd2);
    repeat (4) @(negedge clk);
    check_condition(trigger_seen == 1'b1, "TRIGGER command should create a trigger pulse");
    check_condition(dbg_trigger_count == 32'd1, "TRIGGER command was not counted");

    // RVCTRL1 MMIO_WRITE32: header0, header1, payload(addr,value).
    send_rv_beat(64'h0000000300000001, 1'b1, 1'b0, 32'h80000006);
    send_rv_beat(64'h0000000800000077, 1'b0, 1'b0, 32'h80000006);
    send_rv_beat(64'hCAFE123400000120, 1'b0, 1'b1, 32'h80000006);
    repeat (8) @(negedge clk);
    check_condition(mmio_write_seen == 1'b1, "RVCTRL1 MMIO_WRITE32 should create an AXI-Lite write");
    check_condition(mmio_write_addr == 18'h00120, "RVCTRL1 MMIO_WRITE32 address mismatch");
    check_condition(mmio_write_data == 32'hCAFE1234, "RVCTRL1 MMIO_WRITE32 data mismatch");
    check_condition(dbg_status == 32'h10000003, "RVCTRL1 MMIO_WRITE32 status mismatch");

    mmio_read_seen = 1'b0;
    resp_count = 6'd0;
    send_rv_beat(64'h0000000200000001, 1'b1, 1'b0, 32'h80000005);
    send_rv_beat(64'h0000000400000078, 1'b0, 1'b0, 32'h80000005);
    send_rv_beat(64'h0000000000000124, 1'b0, 1'b1, 32'h80000005);
    repeat (8) @(negedge clk);
    check_condition(mmio_read_seen == 1'b1, "RVCTRL1 MMIO_READ32 should create an AXI-Lite read");
    check_condition(mmio_read_addr == 18'h00124, "RVCTRL1 MMIO_READ32 address mismatch");
    check_condition(dbg_status == 32'h10000002, "RVCTRL1 MMIO_READ32 status mismatch");
    check_condition(resp_count == 6'd4, "RVCTRL1 MMIO_READ32 should emit a 4-word RVRESP1 packet");
    check_condition(resp_words[0] == 64'h0031505345525652, "RVRESP1 magic mismatch");
    check_condition(resp_words[1] == 64'h0000000200000001, "RVRESP1 MMIO_READ32 hdr0 mismatch");
    check_condition(resp_words[2] == 64'h0000000800000078, "RVRESP1 MMIO_READ32 hdr1 mismatch");
    check_condition(resp_words[3] == 64'hA5A500F000000124, "RVRESP1 MMIO_READ32 payload mismatch");

    mmio_write_seen = 1'b0;
    send_rv_beat(64'h0000000400000001, 1'b1, 1'b0, 32'h80000007);
    send_rv_beat(64'h0000000C00000079, 1'b0, 1'b0, 32'h80000007);
    send_rv_beat(64'h000000FF00000128, 1'b0, 1'b0, 32'h80000007);
    send_rv_beat(64'h0000000000000055, 1'b0, 1'b1, 32'h80000007);
    repeat (12) @(negedge clk);
    check_condition(mmio_write_seen == 1'b1, "RVCTRL1 MMIO_RMW32 should create a write after read");
    check_condition(mmio_write_addr == 18'h00128, "RVCTRL1 MMIO_RMW32 write address mismatch");
    check_condition(mmio_write_data == 32'hA5A50055, "RVCTRL1 MMIO_RMW32 write data mismatch");

    mmio_write_events = 32'd0;
    send_rv_beat(64'h0000000500000001, 1'b1, 1'b0, 32'h80000009);
    send_rv_beat(64'h000000140000007A, 1'b0, 1'b0, 32'h80000009);
    send_rv_beat(64'h0000013000000002, 1'b0, 1'b0, 32'h80000009);
    send_rv_beat(64'h0000014000000001, 1'b0, 1'b0, 32'h80000009);
    send_rv_beat(64'h0000000000000002, 1'b0, 1'b1, 32'h80000009);
    repeat (24) @(negedge clk);
    check_condition(mmio_write_events == 32'd2, "RVCTRL1 MMIO_BATCH should create two writes");

    // RFCTRL2 ARM: header0/version2, header1, payload(run_id, channel_mask).
    resp_count = 6'd0;
    send_rv_beat(64'h0000000600000002, 1'b1, 1'b0, 32'hA0000006);
    send_rv_beat(64'h0000000800000088, 1'b0, 1'b0, 32'hA0000006);
    send_rv_beat(64'h000000FF0000CAFE, 1'b0, 1'b1, 32'hA0000006);
    repeat (4) @(negedge clk);
    check_condition(rfctrl2_arm_seen == 1'b1, "RFCTRL2 ARM must emit an arm pulse");
    check_condition(dbg_status == 32'h20000006, "RFCTRL2 ARM status mismatch");
    repeat (4) @(negedge clk);
    check_condition(resp_count == 6'd4, "RFCTRL2 ARM should emit a 4-word RFRESP2 packet");
    check_condition(resp_words[0] == 64'h0032505345524652, "RFRESP2 ARM magic mismatch");
    check_condition(resp_words[1] == 64'h0000000600000002, "RFRESP2 ARM header mismatch");

    resp_count = 6'd0;
    send_rv_beat(64'h0000000200000002, 1'b1, 1'b0, 32'hA0000004);
    send_rv_beat(64'h000000100000008A, 1'b0, 1'b1, 32'hA0000004);
    repeat (8) @(negedge clk);
    check_condition(resp_count == 6'd7, "RFCTRL2 STATUS should emit a 7-word RFRESP2 packet");
    check_condition(resp_words[0] == 64'h0032505345524652, "RFRESP2 STATUS magic mismatch");
    check_condition(resp_words[1] == 64'h0000000200000002, "RFRESP2 STATUS header mismatch");
    check_condition(resp_words[2] == 64'h000000200000008A, "RFRESP2 STATUS sequence mismatch");

    // RFCTRL2 Trigger is rejected until the DAC-domain prepare handshake is
    // complete, then emitted on its dedicated output instead of legacy trigger_pulse.
    resp_count = 6'd0;
    send_rv_beat(64'h0000000900000002, 1'b1, 1'b0, 32'hA0000004);
    send_rv_beat(64'h0000000000000092, 1'b0, 1'b1, 32'hA0000004);
    repeat (6) @(negedge clk);
    check_condition(resp_count == 6'd3, "unprepared RFCTRL2 Trigger must receive a response");
    check_condition(resp_words[1] == 64'h0000000900060002, "unprepared RFCTRL2 Trigger must report unsafe state");
    check_condition(rfctrl2_trigger_seen == 1'b0, "unprepared RFCTRL2 Trigger must not emit a pulse");

    playback_prepared = 1'b1;
    resp_count = 6'd0;
    send_rv_beat(64'h0000000900000002, 1'b1, 1'b0, 32'hA0000004);
    send_rv_beat(64'h0000000000000093, 1'b0, 1'b1, 32'hA0000004);
    repeat (6) @(negedge clk);
    check_condition(rfctrl2_trigger_seen == 1'b1, "prepared RFCTRL2 Trigger must emit the dedicated trigger pulse");
    check_condition(resp_words[1] == 64'h0000000900000002, "prepared RFCTRL2 Trigger response mismatch");

    resp_count = 6'd0;
    send_rv_beat(64'h0000000200000002, 1'b1, 1'b0, 32'hA0000004);
    send_rv_beat(64'h0000001000000094, 1'b0, 1'b1, 32'hA0000004);
    repeat (8) @(negedge clk);
    check_condition(resp_words[3] == 64'h0000001100030000, "RFRESP2 STATUS must advertise playback PREPARED in bit 4");

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
    send_rv_beat(64'h0000000300000002, 1'b1, 1'b0, 32'hA0000036);
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
    repeat (52) @(negedge clk);
    check_condition(resp_count == 6'd47, "RFDC_APPLY should emit a 47-word RFRESP2 packet");
    check_condition(resp_words[0] == 64'h0032505345524652, "RFRESP2 RFDC_APPLY magic mismatch");
    check_condition(resp_words[1] == 64'h0000000300000002, "RFRESP2 RFDC_APPLY header mismatch");
    check_condition(resp_words[2] == 64'h0000016000000091, "RFRESP2 RFDC_APPLY length/sequence mismatch");
    check_condition(resp_words[3] == 64'h000000A500000004, "RFRESP2 RFDC_APPLY revision/applied mask mismatch");
    check_condition(resp_words[4] == 64'h000000A500000000, "RFRESP2 RFDC_APPLY error/config mask mismatch");
    check_condition(resp_words[7] == request_nco[0], "RFRESP2 RFDC_APPLY CH1 actual NCO mismatch");
    check_condition(resp_words[42] == request_nco[7], "RFRESP2 RFDC_APPLY CH8 actual NCO mismatch");

    send_rv_beat(64'h0000000700000002, 1'b1, 1'b0, 32'hA0000006);
    send_rv_beat(64'h0000000800000089, 1'b0, 1'b0, 32'hA0000006);
    send_rv_beat(64'h1122334455667788, 1'b0, 1'b1, 32'hA0000006);
    repeat (4) @(negedge clk);
    check_condition(rfctrl2_sync_seen == 1'b1, "RFCTRL2 SYNC_EPOCH must emit a sync pulse");
    check_condition(rfctrl2_epoch == 64'h1122334455667788, "RFCTRL2 SYNC_EPOCH payload mismatch");

    $display("PASS: PL control shim emits legacy commands plus RFCTRL2 ARM, RFDC_APPLY, and SYNC_EPOCH");
    $finish;
  end
endmodule
