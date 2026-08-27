`timescale 1ns / 1ps

module tb_rfctrl2_control_path;
  localparam [63:0] RFCTRL2_MAGIC = 64'h00324C5254434652;
  localparam [63:0] RFRESP2_MAGIC = 64'h0032505345524652;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg         udp_tvalid = 1'b0;
  reg [63:0]  udp_tdata = 64'd0;
  reg         udp_tlast = 1'b0;
  wire        rvctrl_tvalid;
  wire [63:0] rvctrl_tdata;
  wire        rvctrl_tfirst;
  wire        rvctrl_tlast;
  wire [31:0] rvctrl_word_count;
  wire [1:0]  rvctrl_protocol;

  wire [63:0] rvresp_tdata;
  wire        rvresp_tvalid;
  reg         rvresp_tready = 1'b1;
  wire        rvresp_tlast;
  wire [15:0] rvresp_word_count;

  reg [63:0] responses [0:31];
  integer response_count = 0;

  udp_waveform_ddr_writer writer (
    .clk(clk),
    .rst_n(rst_n),
    .udp_tvalid(udp_tvalid),
    .udp_tdata(udp_tdata),
    .udp_tlast(udp_tlast),
    .instr_tvalid(),
    .instr_tdata(),
    .trigger_pulse(),
    .rvctrl_tvalid(rvctrl_tvalid),
    .rvctrl_tdata(rvctrl_tdata),
    .rvctrl_tfirst(rvctrl_tfirst),
    .rvctrl_tlast(rvctrl_tlast),
    .rvctrl_word_count(rvctrl_word_count),
    .rvctrl_protocol(rvctrl_protocol),
    .m_axi_awaddr(),
    .m_axi_awburst(),
    .m_axi_awcache(),
    .m_axi_awlen(),
    .m_axi_awlock(),
    .m_axi_awprot(),
    .m_axi_awqos(),
    .m_axi_awready(1'b1),
    .m_axi_awsize(),
    .m_axi_awvalid(),
    .m_axi_wdata(),
    .m_axi_wlast(),
    .m_axi_wready(1'b1),
    .m_axi_wstrb(),
    .m_axi_wvalid(),
    .m_axi_bready(),
    .m_axi_bresp(2'b00),
    .m_axi_bvalid(1'b0),
    .dbg_wave_pkt(),
    .dbg_instr_word(),
    .dbg_state(),
    .dbg_write_count(),
    .dbg_bresp_count(),
    .dbg_drop_count_o(),
    .dbg_align_error_count_o(),
    .dbg_fifo_count_o(),
    .dbg_resync_count(),
    .dbg_last_bresp(),
    .dbg_last_addr(),
    .dbg_last_wdata()
  );

  pl_riscv_control_v1 #(
    .ENABLE_UNSAFE_RFDC_MMIO(0)
  ) control (
    .clk(clk),
    .rst_n(rst_n),
    .rvctrl_tvalid(rvctrl_tvalid),
    .rvctrl_tdata(rvctrl_tdata),
    .rvctrl_tfirst(rvctrl_tfirst),
    .rvctrl_tlast(rvctrl_tlast),
    .rvctrl_word_count(rvctrl_word_count),
    .rvctrl_protocol(rvctrl_protocol),
    .m_instr_tdata(),
    .m_instr_tvalid(),
    .m_instr_tready(1'b1),
    .trigger_pulse(),
    .rfctrl2_arm_pulse(),
    .rfctrl2_trigger_pulse(),
    .rfctrl2_abort_mute_pulse(),
    .rfctrl2_sync_epoch_pulse(),
    .rfctrl2_epoch(),
    .rfctrl2_start_valid(),
    .rfctrl2_start_tick(),
    .rfdc_apply_start(),
    .rfdc_apply_sequence(),
    .rfdc_apply_revision(),
    .rfdc_apply_channel_mask(),
    .rfdc_apply_nco_hz(),
    .rfdc_apply_nyquist_zone(),
    .rfdc_apply_phase_mdeg(),
    .rfdc_apply_current_ua(),
    .rfdc_apply_busy(1'b0),
    .rfdc_apply_done(1'b0),
    .rfdc_apply_status(16'd0),
    .rfdc_result_revision(32'h12345678),
    .rfdc_result_applied_mask(8'hFF),
    .rfdc_result_error_mask(8'd0),
    .rfdc_config_valid_mask(8'hFF),
    .rfdc_failure_stage(32'd0),
    .rfdc_failure_address(18'd0),
    .rfdc_failure_axi_response(2'd0),
    .rfdc_ready(1'b1),
    .dac_mts_required(1'b1), .dac_mts_ready(1'b1), .dac_mts_failed(1'b0),
    .dac_mts_tile_mask(4'hF), .dac_mts_error(16'd0),
    .nco_sync_ready(1'b1), .nco_sync_epoch(32'd7),
    .playback_armed(1'b0),
    .playback_prepared(1'b0),
    .playback_running(1'b0),
    .rfdc_actual_nco_hz(512'd0),
    .rfdc_actual_nyquist_zone(16'd0),
    .rfdc_actual_phase_mdeg(256'd0),
    .rfdc_actual_current_ua(256'd0),
    .rfdc_channel_status(256'd0),
    .rfdc_actual_nco_word(512'd0),
    .rfdc_actual_phase_word(256'd0),
    .rfdc_actual_vop_code(256'd0),
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
    .play_executor_state(8'h05),
    .play_ddr_read_counter(32'h34),
    .play_bad_instr_count(32'h12),
    .play_prefill_ready(1'b1),
    .play_active_valid(1'b1),
    .play_pending_valid(1'b1),
    .rvresp_tdata(rvresp_tdata),
    .rvresp_tvalid(rvresp_tvalid),
    .rvresp_tready(rvresp_tready),
    .rvresp_tlast(rvresp_tlast),
    .rvresp_word_count(rvresp_word_count),
    .m_axil_awaddr(),
    .m_axil_awvalid(),
    .m_axil_awready(1'b1),
    .m_axil_wdata(),
    .m_axil_wstrb(),
    .m_axil_wvalid(),
    .m_axil_wready(1'b1),
    .m_axil_bresp(2'b00),
    .m_axil_bvalid(1'b0),
    .m_axil_bready(),
    .m_axil_araddr(),
    .m_axil_arvalid(),
    .m_axil_arready(1'b1),
    .m_axil_rdata(32'd0),
    .m_axil_rresp(2'b00),
    .m_axil_rvalid(1'b0),
    .m_axil_rready(),
    .dbg_status(),
    .dbg_last_seq(),
    .dbg_last_cmd(),
    .dbg_ping_count(),
    .dbg_play_count(),
    .dbg_trigger_count(),
    .dbg_mmio_write_count(),
    .dbg_error_count(),
    .dbg_scratch(),
    .dbg_state()
  );

  always @(posedge clk) begin
    if (rst_n && rvresp_tvalid && rvresp_tready) begin
      if (response_count < 12)
        responses[response_count] <= rvresp_tdata;
      response_count <= response_count + 1;
    end
  end

  task send_status_packet;
    begin
      @(negedge clk);
      udp_tvalid = 1'b1;
      udp_tdata = RFCTRL2_MAGIC;
      @(negedge clk);
      udp_tdata = 64'h0000000200000002;
      @(negedge clk);
      udp_tdata = 64'h0000000000510002;
      @(negedge clk);
      udp_tvalid = 1'b0;
      udp_tdata = 64'd0;
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

  task wait_for_status_response;
    integer timeout_cycles;
    begin
      timeout_cycles = 0;
      while ((response_count < 17) && (timeout_cycles < 80)) begin
        @(negedge clk);
        timeout_cycles = timeout_cycles + 1;
      end
      repeat (2) @(negedge clk);
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    send_status_packet();
    wait_for_status_response();

    check_condition(response_count == 17, "STATUS must produce seventeen RFRESP2 words");
    check_condition(rvresp_word_count == 0, "response word count must clear after the final handshake");
    check_condition(responses[0] == RFRESP2_MAGIC, "response magic mismatch");
    check_condition(responses[1] == 64'h0000000200000002, "response STATUS header mismatch");
    check_condition(responses[2] == 64'h0000007000510002, "response sequence mismatch");
    check_condition(responses[3][32] == 1'b1, "RFDC ready flag must be present in STATUS");
    check_condition(responses[4] == 64'h12345678000000FF, "RFDC revision and valid mask mismatch");
    check_condition(responses[7] == 64'h0000000200000003, "playback config/fifo-valid debug mismatch");
    check_condition(responses[8] == 64'h000000050000000F, "executor/fifo-ready debug mismatch");
    check_condition(responses[9] == 64'h0000001200000034, "playback counter debug mismatch");
    check_condition(responses[10] == 64'h0000000300000001, "prefill/active/pending debug mismatch");
    check_condition(responses[11] == 64'h00000007000000F5, "MTS/NCO synchronization debug mismatch");

    $display("PASS: full RFCTRL2 STATUS payload crosses the UDP writer and PL control response path");
    $finish;
  end
endmodule
