module Top #(
    // External XS17 reference frequency in MHz (250 or 10).  Selects the HMC7044
    // R1 divider so PLL1 always closes on a 10 MHz PFD.
    parameter integer REFERENCE_MHZ = 250
) (

    // HMC7044 clock chip control (SPI interface)
    output RESET_H7044_H_0,
    output H7044_SYNC_0,
    output H7044_SLEN_0,
    output H7044_SCLK_0,
    inout  H7044_SDATA_0,
    input  H7044_GPIO1_0,

    // PL_SYSREF from HMC7044 (differential LVDS)
    input  PL_SYSREF_P_0,
    input  PL_SYSREF_N_0,

    // 100G QSFP28 UDP link (CMAC CAUI-4, RS-FEC) on BANK 128.
    input  qsfp_refclk_p,
    input  qsfp_refclk_n,
    input  [3:0] qsfp_rxp,
    input  [3:0] qsfp_rxn,
    output [3:0] qsfp_txp,
    output [3:0] qsfp_txn,
    output qsfp_lpmode,
    output qsfp_resetn,

    input  dac2_clk_clk_n,
    input  dac2_clk_clk_p,
    input  sysref_in_diff_n,
    input  sysref_in_diff_p,
    output vout00_v_n,
    output vout00_v_p,
    output vout02_v_n,
    output vout02_v_p,
    output vout10_v_n,
    output vout10_v_p,
    output vout12_v_n,
    output vout12_v_p,
    output vout20_v_n,
    output vout20_v_p,
    output vout22_v_n,
    output vout22_v_p,
    output vout30_v_n,
    output vout30_v_p,
    output vout32_v_n,
    output vout32_v_p,
    output TRIG_1,
    input  TRIG_2,

    input           c0_sys_clk_n,
    input           c0_sys_clk_p,
    output          c0_ddr4_act_n,
    output [16:0]   c0_ddr4_adr,
    output [1:0]    c0_ddr4_ba,
    output [0:0]    c0_ddr4_bg,
    output [0:0]    c0_ddr4_ck_c,
    output [0:0]    c0_ddr4_ck_t,
    output [0:0]    c0_ddr4_cke,
    output [0:0]    c0_ddr4_cs_n,
    inout  [7:0]    c0_ddr4_dm_n,
    inout  [63:0]   c0_ddr4_dq,
    inout  [7:0]    c0_ddr4_dqs_c,
    inout  [7:0]    c0_ddr4_dqs_t,
    output [0:0]    c0_ddr4_odt,
    output          c0_ddr4_reset_n
);

  // ========== clocks / resets from design_1 ==========
  wire        pl_clk;
  wire        pl_aresetn;
  wire        pl_resetn0;
  wire        pl_ps_irq;
  wire        clk_dac2;
  wire        dac_axis_clk;
  wire        clk104_aresetn;
  wire        ddr4_ui_clk;
  wire        ddr4_ui_aresetn;
  wire        ddr4_ui_clk_sync_rst;

  assign pl_ps_irq = 1'b0;

  assign dac_axis_clk = clk_dac2;
  ChiselProcSysReset u_pl_reset (
    .io_slowest_sync_clk(pl_clk),
    .io_ext_reset_in(pl_resetn0),
    .io_aux_reset_in(1'b0),
    .io_dcm_locked(1'b1),
    .io_peripheral_aresetn(pl_aresetn)
  );

  ChiselProcSysReset u_clk104_reset (
    .io_slowest_sync_clk(dac_axis_clk),
    .io_ext_reset_in(pl_resetn0),
    .io_aux_reset_in(1'b0),
    .io_dcm_locked(1'b1),
    .io_peripheral_aresetn(clk104_aresetn)
  );

  ChiselProcSysReset u_ddr4_ui_reset (
    .io_slowest_sync_clk(ddr4_ui_clk),
    .io_ext_reset_in(pl_resetn0),
    .io_aux_reset_in(ddr4_ui_clk_sync_rst),
    .io_dcm_locked(1'b1),
    .io_peripheral_aresetn(ddr4_ui_aresetn)
  );


  wire        hmc7044_set_finish;
  wire        hmc7044_sdata_o, hmc7044_sdata_oe, hmc7044_sdata_i;
  wire [5:0]  hmc7044_rb_index;
  wire [31:0] hmc7044_rb_word;
  wire [15:0] hmc7044_rb_sweeps;
  // External XS17 reference profile: XS17 drives CLKIN1.  HMC7044 divides it by
  // REFERENCE_MHZ/10 (250 MHz -> R1=25, 10 MHz -> R1=1) to obtain the 10 MHz
  // PLL1 PFD.

  hmc7044 #(
      .REFERENCE_MHZ(REFERENCE_MHZ)
  ) hmc7044_i (
      .clk(pl_clk),
      .rst(pl_aresetn),
      .H7044_SLEN(H7044_SLEN_0),
      .H7044_SCLK(H7044_SCLK_0),
      .H7044_SDATA(hmc7044_sdata_o),
      .H7044_SDATA_OE(hmc7044_sdata_oe),
      .H7044_SDATA_IN(hmc7044_sdata_i),
      .SET_FINISH(hmc7044_set_finish),
      .RB_WORD_INDEX(hmc7044_rb_index),
      .RB_WORD(hmc7044_rb_word),
      .RB_SWEEPS(hmc7044_rb_sweeps)
  );

  // SDATA is the 3-wire SPI data line: the FPGA drives it except during the
  // data phase of a register readback, where the HMC7044 pulls it low (open
  // drain) against the pad pull-up.
  IOBUF hmc7044_sdata_iobuf (
      .I (hmc7044_sdata_o),
      .O (hmc7044_sdata_i),
      .T (~hmc7044_sdata_oe),
      .IO(H7044_SDATA_0)
  );

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] hmc7044_gpio1_sync;
  always @(posedge pl_clk)
    hmc7044_gpio1_sync <= {hmc7044_gpio1_sync[0], H7044_GPIO1_0};

  assign RESET_H7044_H_0 = 1'b0;
  // HMC7044 SYNC is not used by the single-board target; hold the pin low.
  assign H7044_SYNC_0 = 1'b0;

  wire new_output_first_transfer;
  wire [31:0] wave_path_current_beat_dac, wave_path_loop_position_dac;
  wire [31:0] wave_path_loop_count_dac, wave_path_generation_dac;
  wire [7:0] wave_path_channel_mask_dac;
  wire [31:0] wave_path_underflow_count_dac;
  wire [31:0] wave_path_trigger_seen_count_dac;
  wire [31:0] wave_path_trigger_dropped_count_dac;
  wire [31:0] wave_path_trigger_fire_count_dac;
  wire new_prefetch_safe_ddr;
  wire [31:0] firmware_status_word;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [31:0] firmware_status_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [31:0] firmware_status_ddr;
  wire waveform_prepared_dac;

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] hmc_done_ddr_sync;
  wire hmc_done_ddr = hmc_done_ddr_sync[1];
  // Synchronized reset release for the DAC AXIS domain.
  wire dac_rst_n;

  // XS18 marks the first actual RFDC data transfer of a playback (and of every
  // loop pass), not command receipt or a prefetch edge.  The one-cycle marker
  // is registered and held for 1 us (50 cycles of the 50 MHz DAC fabric clock)
  // so it can start another instrument through a level shifter and a cable.
  marker_pulse_stretcher #(.WIDTH(50)) xs18_marker (
      .clk(dac_axis_clk), .rst_n(dac_rst_n), .marker(new_output_first_transfer), .out(TRIG_1));

  localparam [63:0] EXT_DDR_ADDR_BASE = 64'h0000_0048_0000_0000;

  // ========== 100G UDP receiver (CMAC + 512-bit adapter) ==========
  wire        udp64_rcv_vld;
  wire [63:0] udp64_rcv_dat;
  wire        udp64_rcv_last;
  wire        rvctrl64_tvalid;
  wire [63:0] rvctrl64_tdata;
  wire        rvctrl64_tfirst;
  wire        rvctrl64_tlast;
  wire [31:0] rvctrl64_word_count;
  wire        rvresp64_tvalid;
  wire [63:0] rvresp64_tdata;
  wire        rvresp64_tready;
  wire        rvresp64_tlast;
  wire [15:0] rvresp64_word_count;

  wire [63:0]  M_AXI_WAVE_awaddr;
  wire [1:0]   M_AXI_WAVE_awburst;
  wire [3:0]   M_AXI_WAVE_awcache;
  wire [7:0]   M_AXI_WAVE_awlen;
  wire [2:0]   M_AXI_WAVE_awprot;
  wire [0:0]   M_AXI_WAVE_awlock;
  wire [3:0]   M_AXI_WAVE_awqos;
  wire         M_AXI_WAVE_awready;
  wire [2:0]   M_AXI_WAVE_awsize;
  wire         M_AXI_WAVE_awvalid;
  wire [255:0] M_AXI_WAVE_wdata;
  wire         M_AXI_WAVE_wlast;
  wire         M_AXI_WAVE_wready;
  wire [31:0]  M_AXI_WAVE_wstrb;
  wire         M_AXI_WAVE_wvalid;
  wire         M_AXI_WAVE_bready;
  wire [1:0]   M_AXI_WAVE_bresp;
  wire         M_AXI_WAVE_bvalid;

  // 512-bit bulk waveform write port (wave_bulk_ddr_writer).
  wire [63:0]  M_AXI_BULK_awaddr;
  wire [7:0]   M_AXI_BULK_awlen;
  wire         M_AXI_BULK_awready;
  wire         M_AXI_BULK_awvalid;
  wire [511:0] M_AXI_BULK_wdata;
  wire         M_AXI_BULK_wlast;
  wire         M_AXI_BULK_wready;
  wire [63:0]  M_AXI_BULK_wstrb;
  wire         M_AXI_BULK_wvalid;
  wire         M_AXI_BULK_bready;
  wire [1:0]   M_AXI_BULK_bresp;
  wire         M_AXI_BULK_bvalid;
  wire [511:0] bulk_axis_tdata;
  wire         bulk_axis_tvalid, bulk_axis_tready, bulk_axis_tlast;
  wire [31:0]  bulk_rx_frames, bulk_rx_dropped_full, bulk_rx_dropped_bad;
  wire         bulk_enable, bulk_ctl_start, bulk_ctl_busy, bulk_complete, bulk_overrun, bulk_axi_error;
  wire [1:0]   bulk_ctl_cmd;
  wire [20:0]  bulk_ctl_arg;
  wire [13:0]  bulk_complete_chunks;
  wire [31:0]  bulk_first_incomplete;
  wire [31:0]  bulk_frames_ok, bulk_frames_rejected, bulk_frames_duplicate, bulk_frames_stale;

  // The WAVECTR0 writer is the sole owner of the waveform DDR write port:
  // descriptor commit is the only way to publish waveform storage.
  wire [63:0] wave_awaddr_new; wire wave_awvalid_new, wave_awready_new;
  wire [255:0] wave_wdata_new; wire [31:0] wave_wstrb_new;
  wire wave_wvalid_new, wave_wready_new, wave_wlast_new; wire wave_bready_new;
  wire wave_resp_valid, wave_resp_ready, wave_resp_last, wave_resp_valid_ser;
  wire [63:0] wave_resp_data, wave_resp_error_offset;
  wire [15:0] wave_resp_word_count, wave_resp_status;
  wire [31:0] wave_resp_seq, wave_resp_opcode, wave_resp_error_code;
  wire [31:0] wave_resp_session, wave_resp_state, wave_resp_descriptor;
  wire [31:0] wave_resp_ack_seq, wave_resp_next_seq;
  wire [63:0] wave_resp_received, wave_resp_first_error;
  wire [31:0] wave_resp_expected_crc, wave_resp_actual_crc;
  wire wave_status_request;
  wire wave_status_request_ready;
  wire wave_status_snapshot_valid;
  wire [295:0] wave_status_snapshot_data;
  wire [31:0] wave_status_current_beat_ddr = wave_status_snapshot_data[31:0];
  wire [31:0] wave_status_loop_position_ddr = wave_status_snapshot_data[63:32];
  wire [31:0] wave_status_loop_count_ddr = wave_status_snapshot_data[95:64];
  wire [31:0] wave_status_underflow_count_ddr = wave_status_snapshot_data[159:128];
  wire [31:0] wave_status_trigger_seen_count_ddr = wave_status_snapshot_data[191:160];
  wire [31:0] wave_status_trigger_dropped_count_ddr = wave_status_snapshot_data[223:192];
  wire [31:0] wave_status_trigger_fire_count_ddr = wave_status_snapshot_data[255:224];
  wire [7:0] wave_status_channel_mask_ddr = wave_status_snapshot_data[263:256];
  wire [31:0] wave_status_state_ddr = wave_status_snapshot_data[295:264];
  wire [31:0] ch1_wr_count, ch2_wr_count, ch3_wr_count, ch4_wr_count;
  wire [31:0] ch5_wr_count, ch6_wr_count, ch7_wr_count, ch8_wr_count;

  wire [127:0] wave_status_fifo_levels_ddr = {
      ch8_wr_count[15:0], ch7_wr_count[15:0], ch6_wr_count[15:0], ch5_wr_count[15:0],
      ch4_wr_count[15:0], ch3_wr_count[15:0], ch2_wr_count[15:0], ch1_wr_count[15:0]
  };
  wire [31:0] wave_writer_error_count;
  wire [63:0] wave_writer_error_offset;
  wire [31:0] wave_reader_error_count_ddr;
  wire [15:0] wave_status_result_status_ddr;
  wire [31:0] wave_status_result_error_code_ddr;
  wire [63:0] wave_status_result_error_offset_ddr;
  wire [63:0] wave_descriptor_base;
  wire [63:0] wave_descriptor_total_bytes;
  wire [31:0] wave_descriptor_total_beats, wave_descriptor_loop_count;
  wire [7:0] wave_descriptor_channel_mask;
  wire [31:0] wave_descriptor_generation = wave_resp_descriptor;
  wire wave_command_ready_ddr;
  wire [3:0] wave_new_state;
  wire new_reader_error_ddr, new_fifo_clear_ddr;

  wire [295:0] wave_status_source_dac = {
      wave_new_state, wave_path_channel_mask_dac,
      wave_path_trigger_fire_count_dac, wave_path_trigger_dropped_count_dac,
      wave_path_trigger_seen_count_dac, wave_path_underflow_count_dac,
      wave_path_generation_dac, wave_path_loop_count_dac,
      wave_path_loop_position_dac, wave_path_current_beat_dac
  };
  wire wave_new_dac_gate;
  wire wave_resp_busy;
  wire wave_begin_valid, wave_commit_valid, wave_play_valid, wave_pause_valid;
  wire wave_stop_valid, wave_abort_valid;
  wire         pc_started;
  wire         pc_source_started;
  wire         waveform_armed_dac;
  // DDR-domain command/state shadow used by the upload parser for admission
  // checks and response framing.  The DAC controller remains authoritative;
  // this shadow deliberately avoids routing its multi-bit state bus directly
  // into the DDR clock domain.  STATUS uses waveform_status_cdc for a coherent
  // DAC snapshot and corrects the shadow whenever such a snapshot arrives.
  reg [31:0] wave_playback_state_ddr;
  reg wave_play_pending_ddr;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn) begin
      wave_playback_state_ddr <= 32'd0;
      wave_play_pending_ddr <= 1'b0;
    end else if (new_reader_error_ddr) begin
      wave_playback_state_ddr <= 32'd8;
      wave_play_pending_ddr <= 1'b0;
    end else begin
      if (wave_begin_valid) begin
        wave_playback_state_ddr <= 32'd1;
        wave_play_pending_ddr <= 1'b0;
      end else if (wave_abort_valid) begin
        wave_playback_state_ddr <= 32'd0;
        wave_play_pending_ddr <= 1'b0;
      end else if (wave_stop_valid || wave_pause_valid) begin
        wave_playback_state_ddr <= (wave_playback_state_ddr == 32'd1) ? 32'd0 : 32'd2;
        wave_play_pending_ddr <= 1'b0;
      end else if (wave_commit_valid) begin
        wave_playback_state_ddr <= 32'd3;
        wave_play_pending_ddr <= 1'b0;
      end else if (wave_play_valid) begin
        if (wave_playback_state_ddr == 32'd4)
          wave_playback_state_ddr <= 32'd5;
        else if (wave_playback_state_ddr == 32'd2 || wave_playback_state_ddr == 32'd7)
          wave_playback_state_ddr <= 32'd3;
        wave_play_pending_ddr <= 1'b1;
      end else if (wave_playback_state_ddr == 32'd3 && new_prefetch_safe_ddr) begin
        wave_playback_state_ddr <= wave_play_pending_ddr ? 32'd5 : 32'd4;
        wave_play_pending_ddr <= 1'b0;
      end
      if (wave_status_snapshot_valid)
        wave_playback_state_ddr <= wave_status_state_ddr;
    end
  end

  wire         waveform_start_pending_dac;
  // These source-domain status levels are registered before crossing into the
  // DDR clock domain.  Decoding wave_new_state directly in the synchronizer
  // input made the CDC boundary depend on state decode combinational logic.
  reg          waveform_armed_dac_reg;
  reg          waveform_prepared_dac_reg;
  reg          waveform_start_pending_dac_reg;
  reg          pc_started_dac_reg;
  reg          waveform_armed_meta;
  reg          waveform_armed_ddr;
  reg          waveform_prepared_meta;
  reg          waveform_prepared_ddr;
  reg          waveform_pending_meta;
  reg          waveform_pending_ddr;
  reg          pc_started_meta;
  reg          pc_started_ddr;
  wire         rfdc_apply_start;
  wire [31:0]  rfdc_apply_sequence;
  wire [31:0]  rfdc_apply_revision;
  wire [7:0]   rfdc_apply_channel_mask;
  wire [511:0] rfdc_apply_nco_hz;
  wire [15:0]  rfdc_apply_nyquist_zone;
  wire [255:0] rfdc_apply_phase_mdeg;
  wire [255:0] rfdc_apply_current_ua;
  wire         rfdc_apply_busy;
  wire         rfdc_apply_done;
  wire [15:0]  rfdc_apply_status;
  wire [31:0]  rfdc_result_revision;
  wire [7:0]   rfdc_result_applied_mask;
  wire [7:0]   rfdc_result_error_mask;
  wire [7:0]   rfdc_config_valid_mask;
  wire [31:0]  rfdc_failure_stage;
  wire [17:0]  rfdc_failure_address;
  wire [1:0]   rfdc_failure_axi_response;
  wire         rfdc_runtime_ready;
  wire [511:0] rfdc_actual_nco_hz;
  wire [15:0]  rfdc_actual_nyquist_zone;
  wire [255:0] rfdc_actual_phase_mdeg;
  wire [255:0] rfdc_actual_current_ua;
  wire [255:0] rfdc_channel_status;
  wire [511:0] rfdc_actual_nco_word;
  wire [255:0] rfdc_actual_phase_word;
  wire [255:0] rfdc_actual_vop_code;
  wire         rfdc_nco_commit_start;
  wire [7:0]   rfdc_nco_commit_mask;
  wire [383:0] rfdc_nco_commit_freq_words;
  wire [143:0] rfdc_nco_commit_phase_words;
  wire         rfdc_nco_commit_busy;
  wire         rfdc_nco_commit_done;
  wire [1:0]   rfdc_nco_commit_error;
  wire         rfdc_nco_runtime_sync_ready;
  wire [31:0]  rfdc_nco_runtime_sync_epoch;
  wire [383:0] rfdc_dac_nco_freq;
  wire [143:0] rfdc_dac_nco_phase;
  wire [7:0]   rfdc_dac_nco_phase_reset;
  wire [47:0]  rfdc_dac_nco_update_enable;
  wire [3:0]   rfdc_dac_tile_update_req;
  // RFDC NCO RTS busy widths are asymmetric: Tile 0 exposes DRP and
  // SYSREF-gate busy bits; Tiles 1-3 expose one DRP busy bit each.
  wire [1:0]   rfdc_dac0_nco_update_busy;
  wire         rfdc_dac1_nco_update_busy;
  wire         rfdc_dac2_nco_update_busy;
  wire         rfdc_dac3_nco_update_busy;
  wire [4:0]   rfdc_dac_tile_update_busy = {
      rfdc_dac3_nco_update_busy,
      rfdc_dac2_nco_update_busy,
      rfdc_dac1_nco_update_busy,
      rfdc_dac0_nco_update_busy[1],
      rfdc_dac0_nco_update_busy[0]
  };
  wire         rfdc_dac0_sysref_int_gating;
  wire         rfdc_dac0_sysref_int_reenable;
  wire         pl_sysref_dac;
  wire         dac_mts_required = firmware_status_ddr[1];
  wire         dac_mts_ready = firmware_status_ddr[2];
  wire         dac_mts_failed = firmware_status_ddr[3];
  wire [3:0]   dac_mts_tile_mask = firmware_status_ddr[7:4];
  wire [15:0]  dac_mts_error = firmware_status_ddr[23:8];
  wire         firmware_nco_sync_ready = firmware_status_ddr[24];
  reg          rfdc_nco_runtime_required;
  wire         rfdc_nco_sync_ready = rfdc_nco_runtime_required ?
                                      rfdc_nco_runtime_sync_ready :
                                      firmware_nco_sync_ready;
  wire [31:0]  rfdc_nco_sync_epoch = rfdc_nco_runtime_required ?
                                       rfdc_nco_runtime_sync_epoch :
                                       (firmware_nco_sync_ready ? 32'd1 : 32'd0);
  wire         rfdc_operational_ready = rfdc_runtime_ready && dac_mts_required &&
                                          dac_mts_ready && !dac_mts_failed;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] rfdc_output_permitted_dac_sync;
  wire         rfdc_output_permitted_dac = rfdc_output_permitted_dac_sync[1];
  wire         network_apply_start;
  wire [31:0]  network_apply_revision;
  wire [31:0]  network_apply_ip;
  wire [63:0]  network_apply_mac;
  wire [31:0]  network_apply_subnet;
  wire [31:0]  network_apply_gateway;
  wire [15:0]  network_apply_port;
  wire         network_restart_start;
  wire         network_busy;
  wire         network_done;
  wire [15:0]  network_status;
  wire [31:0]  network_result_revision;
  wire [31:0]  network_current_ip;
  wire [63:0]  network_current_mac;
  wire [31:0]  network_current_subnet;
  wire [31:0]  network_current_gateway;
  wire [15:0]  network_current_port;
  wire [63:0]  network_device_uid;
  wire [63:0]  network_bootstrap_mac;
  wire [31:0]  network_bootstrap_ip;
  wire [31:0]  network_capabilities;
  wire [31:0]  network_status_flags;
  wire [15:0]  network_link_state;
  wire         network_identity_ready;
  wire         network_clear_arp_cache;
  wire         network_restart_pulse;
  // Network identity changes are infrequent. A clocked boundary keeps the
  // high-fanout UDP/IP configuration bus off the critical timing path.
  reg  [47:0] udp_network_mac;
  reg  [31:0] udp_network_ip;
  reg  [31:0] udp_network_gateway;
  reg  [31:0] udp_network_subnet;
  reg  [15:0] udp_network_port;
  wire [17:0]  RFDC_CFG_AXI_awaddr;
  wire         RFDC_CFG_AXI_awvalid;
  wire         RFDC_CFG_AXI_awready;
  wire [31:0]  RFDC_CFG_AXI_wdata;
  wire [3:0]   RFDC_CFG_AXI_wstrb;
  wire         RFDC_CFG_AXI_wvalid;
  wire         RFDC_CFG_AXI_wready;
  wire [1:0]   RFDC_CFG_AXI_bresp;
  wire         RFDC_CFG_AXI_bvalid;
  wire         RFDC_CFG_AXI_bready;
  wire [17:0]  RFDC_CFG_AXI_araddr;
  wire         RFDC_CFG_AXI_arvalid;
  wire         RFDC_CFG_AXI_arready;
  wire [31:0]  RFDC_CFG_AXI_rdata;
  wire [1:0]   RFDC_CFG_AXI_rresp;
  wire         RFDC_CFG_AXI_rvalid;
  wire         RFDC_CFG_AXI_rready;
  wire [17:0]  RV_AXI_RFDC_awaddr;
  wire         RV_AXI_RFDC_awvalid;
  wire         RV_AXI_RFDC_awready;
  wire [31:0]  RV_AXI_RFDC_wdata;
  wire [3:0]   RV_AXI_RFDC_wstrb;
  wire         RV_AXI_RFDC_wvalid;
  wire         RV_AXI_RFDC_wready;
  wire [1:0]   RV_AXI_RFDC_bresp;
  wire         RV_AXI_RFDC_bvalid;
  wire         RV_AXI_RFDC_bready;
  wire [17:0]  RV_AXI_RFDC_araddr;
  wire         RV_AXI_RFDC_arvalid;
  wire         RV_AXI_RFDC_arready;
  wire [31:0]  RV_AXI_RFDC_rdata;
  wire [1:0]   RV_AXI_RFDC_rresp;
  wire         RV_AXI_RFDC_rvalid;
  wire         RV_AXI_RFDC_rready;

  assign network_bootstrap_ip = 32'hC0A8FEFE;
  assign network_capabilities = 32'h00040000;
`ifdef RF2_BUILD_PROFILE_ID
  localparam [31:0] RF2_BUILD_PROFILE_ID = `RF2_BUILD_PROFILE_ID;
`else
  localparam [31:0] RF2_BUILD_PROFILE_ID = 32'd1;
`endif
`ifdef RF2_SOURCE_COMMIT_ID
  localparam [31:0] RF2_SOURCE_COMMIT_ID = `RF2_SOURCE_COMMIT_ID;
`else
  localparam [31:0] RF2_SOURCE_COMMIT_ID = 32'h00000000;
`endif
  // RFCTRL2 v3 identity: the trigger-path contract is a hardware constant.
  // It must not be changed by a stale project define or an ad-hoc build.
  localparam [31:0] RF2_TRIGGER_PATH_VERSION = 32'd3;
  assign network_status_flags = {
      26'd0,
      hmc_done_ddr,
      waveform_prepared_ddr,
      pc_started_ddr,
      (waveform_armed_ddr | waveform_pending_ddr),
      network_busy,
      network_identity_ready
  };
  assign network_link_state = 16'h0001;

  localparam [47:0] NETWORK_RESET_MAC = 48'h02_00_00_00_00_FE;
  localparam [31:0] NETWORK_RESET_IP = 32'hA9FE_FEFE;

  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn) begin
      udp_network_mac     <= NETWORK_RESET_MAC;
      udp_network_ip      <= NETWORK_RESET_IP;
      udp_network_gateway <= 32'h0000_0000;
      udp_network_subnet  <= 32'hFFFF_0000;
      udp_network_port    <= 16'd1234;
    end else begin
      udp_network_mac     <= network_current_mac[47:0];
      udp_network_ip      <= network_current_ip;
      udp_network_gateway <= network_current_gateway;
      udp_network_subnet  <= network_current_subnet;
      udp_network_port    <= network_current_port;
    end
  end

  network_config_pl #(
      .BOOTSTRAP_IP(32'hC0A8FEFE),
      .INITIALIZE_FROM_DNA(1'b1)
  ) network_config_pl_i (
      .clk(ddr4_ui_clk),
      .rst_n(ddr4_ui_aresetn),
      .apply_start(network_apply_start),
      .apply_revision(network_apply_revision),
      .apply_ip(network_apply_ip),
      .apply_mac(network_apply_mac),
      .apply_subnet(network_apply_subnet),
      .apply_gateway(network_apply_gateway),
      .apply_port(network_apply_port),
      .restart_start(network_restart_start),
      .playback_armed(waveform_armed_ddr | waveform_pending_ddr),
      .playback_prepared(waveform_prepared_ddr),
      .playback_running(pc_started_ddr),
      .busy(network_busy),
      .done(network_done),
      .status(network_status),
      .result_revision(network_result_revision),
      .current_ip(network_current_ip),
      .current_mac(network_current_mac),
      .current_subnet(network_current_subnet),
      .current_gateway(network_current_gateway),
      .current_port(network_current_port),
      .clear_arp_cache(network_clear_arp_cache),
      .network_restart_pulse(network_restart_pulse),
      .device_uid(network_device_uid),
      .bootstrap_mac(network_bootstrap_mac),
      .identity_ready(network_identity_ready)
  );

  wire tdc_async_calibration_clk;
  wire udp_resp_tvalid, udp_resp_tready, udp_resp_tlast;
  wire [63:0] udp_resp_tdata; wire [15:0] udp_resp_word_count;
  assign udp_resp_tvalid = wave_resp_valid_ser ? 1'b1 : rvresp64_tvalid;
  assign udp_resp_tdata = wave_resp_valid_ser ? wave_resp_data : rvresp64_tdata;
  assign udp_resp_tlast = wave_resp_valid_ser ? wave_resp_last : rvresp64_tlast;
  assign udp_resp_word_count = wave_resp_valid_ser ? wave_resp_word_count : rvresp64_word_count;
  assign wave_resp_ready = wave_resp_valid_ser && udp_resp_tready;
  assign rvresp64_tready = !wave_resp_valid_ser && udp_resp_tready;

  udp_100G udp_100g_i (
      .gt_rxp_in   (qsfp_rxp),
      .gt_rxn_in   (qsfp_rxn),
      .gt_txp_out  (qsfp_txp),
      .gt_txn_out  (qsfp_txn),
      .gt_refclk_p (qsfp_refclk_p),
      .gt_refclk_n (qsfp_refclk_n),
      .qsfp_lpmode (qsfp_lpmode),
      .qsfp_resetn (qsfp_resetn),
      .clk_100Mhz  (pl_clk),
      .calibration_clk_out(tdc_async_calibration_clk),
      .clk         (ddr4_ui_clk),
      .rst         (~ddr4_ui_aresetn),
      .network_local_mac(udp_network_mac),
      .network_local_ip(udp_network_ip),
      .network_gateway_ip(udp_network_gateway),
      .network_subnet_mask(udp_network_subnet),
      .network_udp_port(udp_network_port),
      .network_clear_arp_cache(network_clear_arp_cache | network_restart_pulse),
      .network_restart_pulse(network_restart_pulse),
      .resp64_tvalid(udp_resp_tvalid),
      .resp64_tdata (udp_resp_tdata),
      .resp64_tlast (udp_resp_tlast),
      .resp64_word_count(udp_resp_word_count),
      .resp64_tready(udp_resp_tready),
      .rcv_vld     (udp64_rcv_vld),
      .rcv_dat     (udp64_rcv_dat),
      .rcv_last    (udp64_rcv_last),
      .m_bulk_axis_tdata (bulk_axis_tdata),
      .m_bulk_axis_tvalid(bulk_axis_tvalid),
      .m_bulk_axis_tready(bulk_axis_tready),
      .m_bulk_axis_tlast (bulk_axis_tlast),
      .bulk_rx_frames(bulk_rx_frames),
      .bulk_rx_dropped_full(bulk_rx_dropped_full),
      .bulk_rx_dropped_bad(bulk_rx_dropped_bad)
  );

  // Keep the 300 MHz UDP parser local to its input registers. This preserves
  // one-word-per-cycle throughput while removing the long high-fanout path
  // from the 100G RX path directly into the packet state machine.
  reg        udp_writer_tvalid;
  reg [63:0] udp_writer_tdata;
  reg        udp_writer_tlast;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn) begin
      udp_writer_tvalid <= 1'b0;
      udp_writer_tdata <= 64'd0;
      udp_writer_tlast <= 1'b0;
    end else begin
      udp_writer_tvalid <= udp64_rcv_vld;
      udp_writer_tdata <= udp64_rcv_dat;
      udp_writer_tlast <= udp64_rcv_last;
    end
  end

  // RFCTRL2 control-plane packet framer.  Drives the rvctrl64_* stream into
  // pl_riscv_control_v1 for NETWORK_GET/HELLO/STATUS/TDC_REG/RFDC_APPLY, in
  // the same ddr4_ui_clk domain as the parser and the control FSM.
  udp_rvctrl_framer udp_rvctrl_framer_i (
      .clk(ddr4_ui_clk), .rst_n(ddr4_ui_aresetn),
      .udp_tvalid(udp_writer_tvalid), .udp_tdata(udp_writer_tdata), .udp_tlast(udp_writer_tlast),
      .rvctrl_tvalid(rvctrl64_tvalid), .rvctrl_tdata(rvctrl64_tdata),
      .rvctrl_tfirst(rvctrl64_tfirst), .rvctrl_tlast(rvctrl64_tlast),
      .rvctrl_word_count(rvctrl64_word_count)
  );

  // WAVECTR0 owns the entire waveform AXI write channel.  Packets are
  // classified by their first accepted UDP word, so control packets of the
  // other protocol never reach the upload parser.
  reg udp_packet_active;
  reg udp_packet_is_wave;
  wire udp_demux_is_wave = udp_packet_active ? udp_packet_is_wave :
                           (udp_writer_tdata == 64'h5741564543545230);
  wire udp_wave_tvalid_new = udp_writer_tvalid && udp_demux_is_wave;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn) begin
      udp_packet_active <= 1'b0;
      udp_packet_is_wave <= 1'b0;
    end else if (udp_writer_tvalid) begin
      if (udp_writer_tlast) begin
        udp_packet_active <= 1'b0;
        udp_packet_is_wave <= 1'b0;
      end else if (!udp_packet_active) begin
        udp_packet_active <= 1'b1;
        udp_packet_is_wave <= (udp_writer_tdata == 64'h5741564543545230);
      end
    end
  end

  assign M_AXI_WAVE_awaddr  = wave_awaddr_new;
  assign M_AXI_WAVE_awvalid = wave_awvalid_new;
  assign wave_awready_new   = M_AXI_WAVE_awready;
  assign M_AXI_WAVE_wdata   = wave_wdata_new;
  assign M_AXI_WAVE_wstrb   = wave_wstrb_new;
  assign M_AXI_WAVE_wvalid  = wave_wvalid_new;
  assign M_AXI_WAVE_wlast   = wave_wlast_new;
  assign wave_wready_new    = M_AXI_WAVE_wready;
  assign M_AXI_WAVE_bready  = wave_bready_new;
  // waveform_upload_writer emits single-beat 256-bit writes (one 32-byte
  // DAC beat per AXI transaction).  The writer drives addr/valid/data but not
  // the burst qualifiers; leaving them undriven presents Z to the DDR
  // smartconnect, which answers DECERR and the writer reports AXI_ERROR.
  // Pin them to the writer's contract: INCR burst, single transfer, 32-byte
  // (256-bit) beats.
  assign M_AXI_WAVE_awburst = 2'b01;
  assign M_AXI_WAVE_awcache = 4'b0011;
  assign M_AXI_WAVE_awlen   = 8'd0;
  assign M_AXI_WAVE_awlock  = 1'b0;
  assign M_AXI_WAVE_awprot  = 3'b000;
  assign M_AXI_WAVE_awqos   = 4'd0;
  assign M_AXI_WAVE_awsize  = 3'b101;

  waveform_upload_writer #(.DDR_ADDR_BASE(EXT_DDR_ADDR_BASE)) waveform_upload_writer_i (
      .clk(ddr4_ui_clk), .rst_n(ddr4_ui_aresetn),
      .status_request_ready(wave_status_request_ready), .status_request(wave_status_request),
      .status_snapshot_valid(wave_status_snapshot_valid), .status_snapshot_state(wave_status_state_ddr),
      .status_snapshot_status(wave_status_result_status_ddr),
      .status_snapshot_error_code(wave_status_result_error_code_ddr),
      .status_snapshot_error_offset(wave_status_result_error_offset_ddr),
      .command_ready(wave_command_ready_ddr),
      .udp_tvalid(udp_wave_tvalid_new), .udp_tdata(udp_writer_tdata), .udp_tlast(udp_writer_tlast),
      .response_ready(!wave_resp_busy), .response_valid(wave_resp_valid), .response_seq(wave_resp_seq), .response_opcode(wave_resp_opcode),
      .response_status(wave_resp_status), .response_error_code(wave_resp_error_code),
      .response_error_offset(wave_resp_error_offset), .response_state(wave_resp_state),
      .response_ack_packet_seq(wave_resp_ack_seq), .response_next_expected_sequence(wave_resp_next_seq),
      .response_received_bytes(wave_resp_received), .response_first_error_offset(wave_resp_first_error),
      .response_expected_crc(wave_resp_expected_crc), .response_actual_crc(wave_resp_actual_crc),
      .session(wave_resp_session), .descriptor(wave_resp_descriptor), .playback_state(wave_playback_state_ddr),
      .state(),
      .begin_valid(wave_begin_valid), .commit_valid(wave_commit_valid), .play_valid(wave_play_valid),
      .pause_valid(wave_pause_valid), .stop_valid(wave_stop_valid), .abort_valid(wave_abort_valid),
      .ddr_base_addr(wave_descriptor_base), .total_bytes(wave_descriptor_total_bytes),
      .total_beats(wave_descriptor_total_beats), .channel_mask(wave_descriptor_channel_mask),
      .loop_count(wave_descriptor_loop_count),
      .m_axi_awaddr(wave_awaddr_new), .m_axi_awvalid(wave_awvalid_new), .m_axi_awready(wave_awready_new),
      .m_axi_wdata(wave_wdata_new), .m_axi_wstrb(wave_wstrb_new), .m_axi_wvalid(wave_wvalid_new),
      .m_axi_wlast(wave_wlast_new), .m_axi_wready(wave_wready_new),
      .m_axi_bresp(M_AXI_WAVE_bresp), .m_axi_bvalid(M_AXI_WAVE_bvalid), .m_axi_bready(wave_bready_new),
      .received_bytes(), .next_packet_seq(), .error_offset(wave_writer_error_offset), .error_count(wave_writer_error_count),
      .bulk_enable(bulk_enable), .bulk_ctl_start(bulk_ctl_start), .bulk_ctl_cmd(bulk_ctl_cmd),
      .bulk_ctl_arg(bulk_ctl_arg), .bulk_ctl_busy(bulk_ctl_busy), .bulk_complete(bulk_complete),
      .bulk_complete_chunks(bulk_complete_chunks), .bulk_first_incomplete(bulk_first_incomplete),
      .bulk_frames_ok(bulk_frames_ok), .bulk_frames_rejected(bulk_frames_rejected),
      .bulk_frames_duplicate(bulk_frames_duplicate), .bulk_frames_stale(bulk_frames_stale),
      .bulk_overrun(bulk_overrun), .bulk_axi_error(bulk_axi_error),
      .bulk_rx_frames(bulk_rx_frames), .bulk_rx_dropped_full(bulk_rx_dropped_full),
      .bulk_rx_dropped_bad(bulk_rx_dropped_bad));

  // Bulk waveform image: 512-bit frames from the CMAC straight into DDR.  The
  // WAVECTR0 parser above owns the session; this writer owns the data and the
  // per-chunk accounting the host uses to resend what was lost.
  wave_bulk_ddr_writer #(.DDR_ADDR_BASE(EXT_DDR_ADDR_BASE)) wave_bulk_ddr_writer_i (
      .clk(ddr4_ui_clk), .rst_n(ddr4_ui_aresetn),
      .enable(bulk_enable), .session(wave_resp_session), .total_bytes(wave_descriptor_total_bytes),
      .ctl_start(bulk_ctl_start), .ctl_cmd(bulk_ctl_cmd), .ctl_arg(bulk_ctl_arg), .ctl_busy(bulk_ctl_busy),
      .complete(bulk_complete), .complete_chunks(bulk_complete_chunks),
      .first_incomplete(bulk_first_incomplete),
      .frames_ok(bulk_frames_ok), .frames_rejected(bulk_frames_rejected),
      .frames_duplicate(bulk_frames_duplicate), .frames_stale(bulk_frames_stale),
      .overrun(bulk_overrun), .axi_error(bulk_axi_error),
      .s_axis_tdata(bulk_axis_tdata), .s_axis_tvalid(bulk_axis_tvalid),
      .s_axis_tready(bulk_axis_tready), .s_axis_tlast(bulk_axis_tlast),
      .m_axi_awaddr(M_AXI_BULK_awaddr), .m_axi_awlen(M_AXI_BULK_awlen),
      .m_axi_awvalid(M_AXI_BULK_awvalid), .m_axi_awready(M_AXI_BULK_awready),
      .m_axi_wdata(M_AXI_BULK_wdata), .m_axi_wstrb(M_AXI_BULK_wstrb), .m_axi_wlast(M_AXI_BULK_wlast),
      .m_axi_wvalid(M_AXI_BULK_wvalid), .m_axi_wready(M_AXI_BULK_wready),
      .m_axi_bresp(M_AXI_BULK_bresp), .m_axi_bvalid(M_AXI_BULK_bvalid), .m_axi_bready(M_AXI_BULK_bready));

  waveform_response_serializer waveform_response_serializer_i (
      .clk(ddr4_ui_clk), .rst_n(ddr4_ui_aresetn), .event_valid(wave_resp_valid),
      .event_seq(wave_resp_seq), .event_opcode(wave_resp_opcode), .event_status(wave_resp_status),
      .event_error_code(wave_resp_error_code), .event_session(wave_resp_session),
      .event_state(wave_resp_state), .event_descriptor(wave_resp_descriptor),
      .event_error_offset(wave_resp_error_offset), .event_ack_packet_seq(wave_resp_ack_seq),
      .event_next_expected_sequence(wave_resp_next_seq), .event_received_bytes(wave_resp_received),
      .event_first_error_offset(wave_resp_first_error),
      .event_expected_crc(wave_resp_expected_crc), .event_actual_crc(wave_resp_actual_crc),
      .event_current_beat(wave_status_current_beat_ddr), .event_loop_position(wave_status_loop_position_ddr),
      .event_loop_count(wave_status_loop_count_ddr), .event_channel_mask(wave_status_channel_mask_ddr),
      .event_layout(8'd1), .event_fifo_levels(wave_status_fifo_levels_ddr),
      .event_error_count(wave_writer_error_count + wave_reader_error_count_ddr),
      .event_underflow_count(wave_status_underflow_count_ddr),
      .event_trigger_seen_count(wave_status_trigger_seen_count_ddr),
      .event_trigger_dropped_count(wave_status_trigger_dropped_count_ddr),
      .event_trigger_fire_count(wave_status_trigger_fire_count_ddr),
      .response_valid(wave_resp_valid_ser),
      .response_data(wave_resp_data), .response_last(wave_resp_last),
      .response_word_count(wave_resp_word_count), .response_ready(wave_resp_ready), .busy(wave_resp_busy));

  // Signals reported through RFCTRL2 STATUS must be declared before the
  // control module instance; otherwise Verilog implicit nets can hide widths.
  wire        dac_in_ch1_tvalid, dac_in_ch2_tvalid, dac_in_ch3_tvalid, dac_in_ch4_tvalid;
  wire        dac_in_ch5_tvalid, dac_in_ch6_tvalid, dac_in_ch7_tvalid, dac_in_ch8_tvalid;
  wire        ch1_wave_tready_internal, ch2_wave_tready_internal, ch3_wave_tready_internal, ch4_wave_tready_internal;
  wire        ch5_wave_tready_internal, ch6_wave_tready_internal, ch7_wave_tready_internal, ch8_wave_tready_internal;
  reg [2:0]   ext_trig_slot_ddr;
  reg         ext_trig_valid_ddr;
  reg         ext_trig_overflow_ddr;
  reg         ext_trig_metastable_ddr;
  reg [7:0]   ext_trig_tap_index_ddr;
  reg [15:0]  ext_trig_phase_ps_x10_ddr;
  wire tdc_reg_valid, tdc_reg_write, tdc_reg_ready;
  wire [15:0] tdc_reg_addr, tdc_reg_error;
  wire [31:0] tdc_reg_wdata, tdc_reg_rdata;

  pl_riscv_control_v1 #(
      .BUILD_PROFILE_ID(RF2_BUILD_PROFILE_ID),
      .TRIGGER_PATH_VERSION(RF2_TRIGGER_PATH_VERSION),
      .SOURCE_COMMIT_ID(RF2_SOURCE_COMMIT_ID)
  ) pl_riscv_control_v1_i (
      .clk                 (ddr4_ui_clk),
      .rst_n               (ddr4_ui_aresetn),
      .rvctrl_tvalid       (rvctrl64_tvalid),
      .rvctrl_tdata        (rvctrl64_tdata),
      .rvctrl_tfirst       (rvctrl64_tfirst),
      .rvctrl_tlast        (rvctrl64_tlast),
      .rvctrl_word_count   (rvctrl64_word_count),
      .rfdc_apply_start    (rfdc_apply_start),
      .rfdc_apply_sequence (rfdc_apply_sequence),
      .rfdc_apply_revision (rfdc_apply_revision),
      .rfdc_apply_channel_mask(rfdc_apply_channel_mask),
      .rfdc_apply_nco_hz   (rfdc_apply_nco_hz),
      .rfdc_apply_nyquist_zone(rfdc_apply_nyquist_zone),
      .rfdc_apply_phase_mdeg(rfdc_apply_phase_mdeg),
      .rfdc_apply_current_ua(rfdc_apply_current_ua),
      .rfdc_apply_busy     (rfdc_apply_busy),
      .rfdc_apply_done     (rfdc_apply_done),
      .rfdc_apply_status   (rfdc_apply_status),
      .rfdc_result_revision(rfdc_result_revision),
      .rfdc_result_applied_mask(rfdc_result_applied_mask),
      .rfdc_result_error_mask(rfdc_result_error_mask),
      .rfdc_config_valid_mask(rfdc_config_valid_mask),
      .rfdc_failure_stage  (rfdc_failure_stage),
      .rfdc_failure_address(rfdc_failure_address),
      .rfdc_failure_axi_response(rfdc_failure_axi_response),
      .rfdc_ready          (rfdc_operational_ready),
      .dac_mts_required    (dac_mts_required),
      .dac_mts_ready       (dac_mts_ready),
      .dac_mts_failed      (dac_mts_failed),
      .dac_mts_tile_mask   (dac_mts_tile_mask),
      .dac_mts_error       (dac_mts_error),
      .nco_sync_ready      (rfdc_nco_sync_ready),
      .nco_sync_epoch      (rfdc_nco_sync_epoch),
      .playback_armed      (waveform_armed_ddr | waveform_pending_ddr),
      .playback_prepared   (waveform_prepared_ddr),
      .playback_running    (pc_started_ddr),
      .ext_trigger_phase_slot(ext_trig_slot_ddr),
      .ext_trigger_phase_valid(ext_trig_valid_ddr),
      .ext_trigger_phase_overflow(ext_trig_overflow_ddr),
      .ext_trigger_phase_metastable(ext_trig_metastable_ddr),
      .ext_trigger_tap_index(ext_trig_tap_index_ddr),
      .ext_trigger_phase_ps_x10(ext_trig_phase_ps_x10_ddr),
      .tdc_reg_valid(tdc_reg_valid), .tdc_reg_write(tdc_reg_write),
      .tdc_reg_addr(tdc_reg_addr), .tdc_reg_wdata(tdc_reg_wdata),
      .tdc_reg_ready(tdc_reg_ready), .tdc_reg_rdata(tdc_reg_rdata),
      .tdc_reg_error(tdc_reg_error),
      .rfdc_actual_nco_hz  (rfdc_actual_nco_hz),
      .rfdc_actual_nyquist_zone(rfdc_actual_nyquist_zone),
      .rfdc_actual_phase_mdeg(rfdc_actual_phase_mdeg),
      .rfdc_actual_current_ua(rfdc_actual_current_ua),
      .rfdc_channel_status (rfdc_channel_status),
      .rfdc_actual_nco_word(rfdc_actual_nco_word),
      .rfdc_actual_phase_word(rfdc_actual_phase_word),
      .rfdc_actual_vop_code(rfdc_actual_vop_code),
      .network_apply_start(network_apply_start),
      .network_apply_revision(network_apply_revision),
      .network_apply_ip(network_apply_ip),
      .network_apply_mac(network_apply_mac),
      .network_apply_subnet(network_apply_subnet),
      .network_apply_gateway(network_apply_gateway),
      .network_apply_port(network_apply_port),
      .network_restart_start(network_restart_start),
      .network_busy(network_busy),
      .network_done(network_done),
      .network_status(network_status),
      .network_result_revision(network_result_revision),
      .network_current_ip(network_current_ip),
      .network_current_mac(network_current_mac),
      .network_current_subnet(network_current_subnet),
      .network_current_gateway(network_current_gateway),
      .network_current_port(network_current_port),
      .network_device_uid(network_device_uid),
      .network_bootstrap_mac(network_bootstrap_mac),
      .network_bootstrap_ip(network_bootstrap_ip),
      .network_capabilities(network_capabilities),
      .network_status_flags(network_status_flags),
      .network_link_state(network_link_state),
      .play_config_channel_mask(wave_descriptor_channel_mask),
      .play_fifo_valid_mask({dac_in_ch8_tvalid, dac_in_ch7_tvalid, dac_in_ch6_tvalid, dac_in_ch5_tvalid,
                             dac_in_ch4_tvalid, dac_in_ch3_tvalid, dac_in_ch2_tvalid, dac_in_ch1_tvalid}),
      .play_fifo_ready_mask({ch8_wave_tready_internal, ch7_wave_tready_internal, ch6_wave_tready_internal, ch5_wave_tready_internal,
                             ch4_wave_tready_internal, ch3_wave_tready_internal, ch2_wave_tready_internal, ch1_wave_tready_internal}),
      .play_prefill_ready(new_prefetch_safe_ddr),
      .rvresp_tdata        (rvresp64_tdata),
      .rvresp_tvalid       (rvresp64_tvalid),
      .rvresp_tready       (rvresp64_tready),
      .rvresp_tlast        (rvresp64_tlast),
      .rvresp_word_count   (rvresp64_word_count)
  );

  rfdc_runtime_config_pl #(
      // DDR4 UI clock: 1200.48 MHz memory clock / 4 (833 ps, 4:1).
      .CLOCK_HZ(300120048),
      .AXI_TIMEOUT_CYCLES(100000)
  ) rfdc_runtime_config_pl_i (
      .clk(ddr4_ui_clk), .rst_n(ddr4_ui_aresetn),
      .start(rfdc_apply_start), .cmd_sequence(rfdc_apply_sequence),
      .cmd_revision(rfdc_apply_revision), .cmd_channel_mask(rfdc_apply_channel_mask),
      .cmd_nco_hz(rfdc_apply_nco_hz), .cmd_nyquist_zone(rfdc_apply_nyquist_zone),
      .cmd_phase_mdeg(rfdc_apply_phase_mdeg), .cmd_current_ua(rfdc_apply_current_ua),
      .playback_armed(waveform_armed_ddr | waveform_pending_ddr),
      .playback_running(pc_started_ddr),
      .busy(rfdc_apply_busy), .done(rfdc_apply_done),
      .status(rfdc_apply_status), .revision(rfdc_result_revision),
      .applied_mask(rfdc_result_applied_mask), .error_mask(rfdc_result_error_mask),
      .config_valid_mask(rfdc_config_valid_mask), .failure_stage(rfdc_failure_stage),
      .failure_address(rfdc_failure_address), .failure_axi_response(rfdc_failure_axi_response),
      .rfdc_ready(rfdc_runtime_ready), .actual_nco_hz(rfdc_actual_nco_hz),
      .actual_nyquist_zone(rfdc_actual_nyquist_zone), .actual_phase_mdeg(rfdc_actual_phase_mdeg),
      .actual_current_ua(rfdc_actual_current_ua), .channel_status(rfdc_channel_status),
      .actual_nco_word(rfdc_actual_nco_word), .actual_phase_word(rfdc_actual_phase_word),
      .actual_vop_code(rfdc_actual_vop_code),
      .nco_commit_start(rfdc_nco_commit_start), .nco_commit_mask(rfdc_nco_commit_mask),
      .nco_commit_freq_words(rfdc_nco_commit_freq_words),
      .nco_commit_phase_words(rfdc_nco_commit_phase_words),
      .nco_commit_busy(rfdc_nco_commit_busy), .nco_commit_done(rfdc_nco_commit_done),
      .nco_commit_error(rfdc_nco_commit_error),
      .m_axil_awaddr(RFDC_CFG_AXI_awaddr), .m_axil_awvalid(RFDC_CFG_AXI_awvalid),
      .m_axil_awready(RFDC_CFG_AXI_awready), .m_axil_wdata(RFDC_CFG_AXI_wdata),
      .m_axil_wstrb(RFDC_CFG_AXI_wstrb), .m_axil_wvalid(RFDC_CFG_AXI_wvalid),
      .m_axil_wready(RFDC_CFG_AXI_wready), .m_axil_bresp(RFDC_CFG_AXI_bresp),
      .m_axil_bvalid(RFDC_CFG_AXI_bvalid), .m_axil_bready(RFDC_CFG_AXI_bready),
      .m_axil_araddr(RFDC_CFG_AXI_araddr), .m_axil_arvalid(RFDC_CFG_AXI_arvalid),
      .m_axil_arready(RFDC_CFG_AXI_arready), .m_axil_rdata(RFDC_CFG_AXI_rdata),
      .m_axil_rresp(RFDC_CFG_AXI_rresp), .m_axil_rvalid(RFDC_CFG_AXI_rvalid),
      .m_axil_rready(RFDC_CFG_AXI_rready)
  );

  rfdc_nco_rts_bridge #(
      .TIMEOUT_CYCLES(500000)
  ) rfdc_nco_rts_bridge_i (
      .src_clk(ddr4_ui_clk), .src_rst_n(ddr4_ui_aresetn),
      .src_start(rfdc_nco_commit_start), .src_channel_mask(rfdc_nco_commit_mask),
      .src_nco_freq(rfdc_nco_commit_freq_words), .src_nco_phase(rfdc_nco_commit_phase_words),
      .src_busy(rfdc_nco_commit_busy), .src_done(rfdc_nco_commit_done),
      .src_error(rfdc_nco_commit_error), .src_sync_ready(rfdc_nco_runtime_sync_ready),
      .src_sync_epoch(rfdc_nco_runtime_sync_epoch),
      .rfdc_clk(pl_clk), .rfdc_rst_n(pl_aresetn),
      .rfdc_tile_update_busy(rfdc_dac_tile_update_busy),
      .dac_nco_freq(rfdc_dac_nco_freq), .dac_nco_phase(rfdc_dac_nco_phase),
      .dac_nco_phase_reset(rfdc_dac_nco_phase_reset),
      .dac_nco_update_enable(rfdc_dac_nco_update_enable),
      .dac_tile_update_req(rfdc_dac_tile_update_req),
      .dac_sysref_int_gating(rfdc_dac0_sysref_int_gating),
      .dac_sysref_int_reenable(rfdc_dac0_sysref_int_reenable)
  );

  // Firmware performs the baseline SYSREF NCO reset during startup. Once a
  // runtime RFDC_APPLY begins, only the RTS bridge may restore readiness.
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn)
      rfdc_nco_runtime_required <= 1'b0;
    else if (rfdc_apply_start)
      rfdc_nco_runtime_required <= 1'b1;
  end

  IBUFDS #(
      .IBUF_LOW_PWR("FALSE")
  ) pl_sysref_ibufds_i (
      .I(PL_SYSREF_P_0),
      .IB(PL_SYSREF_N_0),
      .O(pl_sysref_dac)
  );

  // PL RFDC configuration master (ddr4_ui_clk) into the RFDC AXI-Lite clock.
  axilite_cdc_simple rv_rfdc_axil_cdc_i (
      .s_clk      (ddr4_ui_clk),
      .s_rst_n    (ddr4_ui_aresetn),
      .s_awaddr   (RFDC_CFG_AXI_awaddr),
      .s_awvalid  (RFDC_CFG_AXI_awvalid),
      .s_awready  (RFDC_CFG_AXI_awready),
      .s_wdata    (RFDC_CFG_AXI_wdata),
      .s_wstrb    (RFDC_CFG_AXI_wstrb),
      .s_wvalid   (RFDC_CFG_AXI_wvalid),
      .s_wready   (RFDC_CFG_AXI_wready),
      .s_bresp    (RFDC_CFG_AXI_bresp),
      .s_bvalid   (RFDC_CFG_AXI_bvalid),
      .s_bready   (RFDC_CFG_AXI_bready),
      .s_araddr   (RFDC_CFG_AXI_araddr),
      .s_arvalid  (RFDC_CFG_AXI_arvalid),
      .s_arready  (RFDC_CFG_AXI_arready),
      .s_rdata    (RFDC_CFG_AXI_rdata),
      .s_rresp    (RFDC_CFG_AXI_rresp),
      .s_rvalid   (RFDC_CFG_AXI_rvalid),
      .s_rready   (RFDC_CFG_AXI_rready),
      .m_clk      (pl_clk),
      .m_rst_n    (pl_aresetn),
      .m_awaddr   (RV_AXI_RFDC_awaddr),
      .m_awvalid  (RV_AXI_RFDC_awvalid),
      .m_awready  (RV_AXI_RFDC_awready),
      .m_wdata    (RV_AXI_RFDC_wdata),
      .m_wstrb    (RV_AXI_RFDC_wstrb),
      .m_wvalid   (RV_AXI_RFDC_wvalid),
      .m_wready   (RV_AXI_RFDC_wready),
      .m_bresp    (RV_AXI_RFDC_bresp),
      .m_bvalid   (RV_AXI_RFDC_bvalid),
      .m_bready   (RV_AXI_RFDC_bready),
      .m_araddr   (RV_AXI_RFDC_araddr),
      .m_arvalid  (RV_AXI_RFDC_arvalid),
      .m_arready  (RV_AXI_RFDC_arready),
      .m_rdata    (RV_AXI_RFDC_rdata),
      .m_rresp    (RV_AXI_RFDC_rresp),
      .m_rvalid   (RV_AXI_RFDC_rvalid),
      .m_rready   (RV_AXI_RFDC_rready)
  );

  // ========== reader -> wave FIFO write side (DDR domain) ==========
  wire [255:0] ch1_wave_tdata, ch2_wave_tdata, ch3_wave_tdata, ch4_wave_tdata;
  wire [255:0] ch5_wave_tdata, ch6_wave_tdata, ch7_wave_tdata, ch8_wave_tdata;
  wire         ch1_wave_tvalid, ch2_wave_tvalid, ch3_wave_tvalid, ch4_wave_tvalid;
  wire         ch5_wave_tvalid, ch6_wave_tvalid, ch7_wave_tvalid, ch8_wave_tvalid;

  // ========== DAC side ready from DAC IP ==========
  wire         dac_ch1_ready, dac_ch2_ready, dac_ch3_ready, dac_ch4_ready;
  wire         dac_ch5_ready, dac_ch6_ready, dac_ch7_ready, dac_ch8_ready;

  // ========== waveform reader AXI read channel to DDR ==========
  wire [63:0]  M_AXI_DM_araddr;
  wire [7:0]   M_AXI_DM_arlen;
  wire [2:0]   M_AXI_DM_arsize;
  wire [1:0]   M_AXI_DM_arburst;
  wire         M_AXI_DM_arready;
  wire         M_AXI_DM_arvalid;
  wire [511:0] M_AXI_DM_rdata;
  wire         M_AXI_DM_rlast;
  wire         M_AXI_DM_rready;
  wire [1:0]   M_AXI_DM_rresp;
  wire         M_AXI_DM_rvalid;

  // ========== firmware status word (GPIO2) and HMC7044 done ==========
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn) begin
      firmware_status_meta <= 32'd0;
      firmware_status_ddr <= 32'd0;
      hmc_done_ddr_sync <= 2'b00;
    end else begin
      firmware_status_meta <= firmware_status_word;
      firmware_status_ddr <= firmware_status_meta;
      hmc_done_ddr_sync <= {hmc_done_ddr_sync[0], hmc7044_set_finish};
    end
  end

  always @(posedge dac_axis_clk or negedge clk104_aresetn) begin
    if (!clk104_aresetn)
      rfdc_output_permitted_dac_sync <= 2'b00;
    else
      rfdc_output_permitted_dac_sync <= {
          rfdc_output_permitted_dac_sync[0],
          rfdc_operational_ready && rfdc_nco_sync_ready
      };
  end
  // ========== PAUSE/STOP into the DAC domain ==========
  // Each command toggles a level in the DDR domain; the DAC domain turns the
  // synchronized edge back into a one-cycle pulse.
  reg wave_pause_toggle_ddr, wave_stop_toggle_ddr;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] wave_pause_toggle_dac_sync_ff;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] wave_stop_toggle_dac_sync_ff;
  reg wave_pause_toggle_dac_seen, wave_stop_toggle_dac_seen;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) begin
      wave_pause_toggle_ddr <= 1'b0;
      wave_stop_toggle_ddr <= 1'b0;
    end else begin
      if (wave_pause_valid)
        wave_pause_toggle_ddr <= ~wave_pause_toggle_ddr;
      if (wave_stop_valid)
        wave_stop_toggle_ddr <= ~wave_stop_toggle_ddr;
    end
  end
  always @(posedge dac_axis_clk or negedge clk104_aresetn) begin
    if(!clk104_aresetn) begin
      wave_pause_toggle_dac_sync_ff <= 3'b000;
      wave_stop_toggle_dac_sync_ff <= 3'b000;
      wave_pause_toggle_dac_seen <= 1'b0;
      wave_stop_toggle_dac_seen <= 1'b0;
    end else begin
      wave_pause_toggle_dac_sync_ff <= {wave_pause_toggle_dac_sync_ff[1:0], wave_pause_toggle_ddr};
      wave_stop_toggle_dac_sync_ff <= {wave_stop_toggle_dac_sync_ff[1:0], wave_stop_toggle_ddr};
      wave_pause_toggle_dac_seen <= wave_pause_toggle_dac_sync_ff[2];
      wave_stop_toggle_dac_seen <= wave_stop_toggle_dac_sync_ff[2];
    end
  end
  wire wave_pause_dac_pulse = wave_pause_toggle_dac_sync_ff[2] != wave_pause_toggle_dac_seen;
  wire wave_stop_dac_pulse = wave_stop_toggle_dac_sync_ff[2] != wave_stop_toggle_dac_seen;
  wire wave_control_abort_dac = wave_pause_dac_pulse | wave_stop_dac_pulse;

  wire waveform_play_abort;
  reg tdc_mode_dac;

  // ========== Calibrated event timestamps and eight-channel compensation ==========
  wire       clk_200mhz;
  wire       clk_200mhz_locked;
  wire pc_done_pulse;
  tdc_clk_gen_200mhz tdc_clk_gen_200mhz_i (
      .clk_50mhz  (dac_axis_clk),
      .rst_n      (clk104_aresetn),
      .clk_200mhz (clk_200mhz),
      .locked     (clk_200mhz_locked)
  );
  wire tdc_reset_async_n = clk104_aresetn && clk_200mhz_locked;
  (* ASYNC_REG = "TRUE" *) reg [3:0] tdc_reset_sync;
  always @(posedge clk_200mhz or negedge tdc_reset_async_n) begin
    if (!tdc_reset_async_n) tdc_reset_sync <= 0;
    else tdc_reset_sync <= {tdc_reset_sync[2:0], 1'b1};
  end
  wire tdc_rst_n = tdc_reset_sync[3];
  reg [31:0] tdc_dac_epoch;
  reg [31:0] tdc_ref_epoch;
  reg tdc_ref_toggle;
  always @(posedge dac_axis_clk or negedge clk104_aresetn) begin
    if (!clk104_aresetn) tdc_dac_epoch <= 0;
    else tdc_dac_epoch <= tdc_dac_epoch + 1'b1;
  end
  always @(negedge dac_axis_clk or negedge clk104_aresetn) begin
    if (!clk104_aresetn) begin tdc_ref_epoch <= 0; tdc_ref_toggle <= 0; end
    else begin tdc_ref_epoch <= tdc_dac_epoch; tdc_ref_toggle <= !tdc_ref_toggle; end
  end

  wire tdc_mode_sample, tdc_calibration_source, tdc_carrier_enable_sample;
  // The CMAC TX user clock provides an independent
  // code-density phase source; the control crossing only selects this pulse.
  wire tdc_calibration_level;
  tdc_calibration_source u_tdc_calibration_source (
      .async_clk(tdc_async_calibration_clk), .rst_n(pl_resetn0),
      .pulse(tdc_calibration_level)
  );
  wire tdc_calibrated_sample, tdc_reference_ready;
  wire signed [15:0] tdc_offset_sample;
  wire tdc_stats_clear_toggle;
  wire tdc_calib_wr;
  wire [10:0] tdc_calib_wr_addr, tdc_calib_rd_addr;
  wire [15:0] tdc_calib_wr_data, tdc_calib_rd_data;
  wire tdc_event_valid, tdc_event_good, tdc_event_overflow, tdc_event_bubble;
  wire [31:0] tdc_event_epoch;
  wire [10:0] tdc_event_phase;
  wire [10:0] tdc_event_tap;
  tdc_event_capture u_tdc_capture (
      .sample_clk(clk_200mhz), .rst_n(tdc_rst_n),
      .trigger_in(tdc_calibration_source ? tdc_calibration_level : TRIG_2),
      .ref_toggle(tdc_ref_toggle), .ref_epoch(tdc_ref_epoch),
      .calib_wr_en(tdc_calib_wr), .calib_wr_addr(tdc_calib_wr_addr),
      .calib_wr_data(tdc_calib_wr_data), .calib_rd_addr(tdc_calib_rd_addr),
      .calib_rd_data(tdc_calib_rd_data), .ready(tdc_reference_ready),
      .event_valid(tdc_event_valid), .event_good(tdc_event_good),
      .event_overflow(tdc_event_overflow), .event_bubble(tdc_event_bubble),
      .event_epoch(tdc_event_epoch), .event_phase_10ps(tdc_event_phase),
      .event_tap(tdc_event_tap)
  );
  wire [56:0] tdc_fifo_data;
  wire tdc_fifo_valid, tdc_fifo_ready;
  tdc_async_fifo #(.WIDTH(57)) u_tdc_events (
      .wr_clk(clk_200mhz), .rd_clk(dac_axis_clk), .rst_n(tdc_rst_n && dac_rst_n),
      .wr_data({tdc_event_epoch, tdc_event_phase, tdc_event_tap,
                tdc_event_good, tdc_event_overflow, tdc_event_bubble}),
      .wr_valid(tdc_event_valid && !tdc_calibration_source), .wr_ready(tdc_fifo_ready),
      .rd_data(tdc_fifo_data), .rd_valid(tdc_fifo_valid), .rd_ready(1'b1)
  );
  reg tdc_fifo_loss;
  always @(posedge clk_200mhz or negedge tdc_rst_n) begin
    if (!tdc_rst_n) tdc_fifo_loss <= 0;
    else if (tdc_event_valid && !tdc_calibration_source && !tdc_fifo_ready) tdc_fifo_loss <= 1;
    else if (!tdc_mode_sample) tdc_fifo_loss <= 0;
  end
  (* ASYNC_REG = "TRUE" *) reg [2:0] tdc_mode_sync, tdc_ready_sync, tdc_valid_sync;
  (* ASYNC_REG = "TRUE" *) reg [2:0] tdc_clear_sync, tdc_loss_sync, tdc_carrier_sync;
  reg tdc_clear_seen;
  reg tdc_carrier_enable_dac;
  reg signed [15:0] tdc_offset_meta, tdc_offset_dac;
  always @(posedge dac_axis_clk or negedge dac_rst_n) begin
    if (!dac_rst_n) begin
      tdc_mode_sync <= 0; tdc_ready_sync <= 0; tdc_valid_sync <= 0;
      tdc_clear_sync <= 0; tdc_clear_seen <= 0; tdc_loss_sync <= 0;
      tdc_carrier_sync <= 0; tdc_carrier_enable_dac <= 0;
      tdc_mode_dac <= 0; tdc_offset_meta <= 0; tdc_offset_dac <= 0;
    end else begin
      tdc_mode_sync <= {tdc_mode_sync[1:0], tdc_mode_sample};
      tdc_ready_sync <= {tdc_ready_sync[1:0], tdc_reference_ready && tdc_rst_n};
      tdc_valid_sync <= {tdc_valid_sync[1:0], tdc_calibrated_sample};
      tdc_clear_sync <= {tdc_clear_sync[1:0], tdc_stats_clear_toggle};
      tdc_loss_sync <= {tdc_loss_sync[1:0], tdc_fifo_loss};
      tdc_carrier_sync <= {tdc_carrier_sync[1:0], tdc_carrier_enable_sample};
      tdc_clear_seen <= tdc_clear_sync[2];
      tdc_offset_meta <= tdc_offset_sample;
      if (!waveform_armed_dac) begin
        tdc_offset_dac <= tdc_offset_meta;
        tdc_mode_dac <= tdc_mode_sync[2];
        tdc_carrier_enable_dac <= tdc_carrier_sync[2];
      end
    end
  end

  wire tdc_launch, tdc_config_valid, tdc_pending, tdc_active, tdc_fault;
  wire [2:0] tdc_delay_samples;
  wire [5:0] tdc_fractional_phase;
  wire [7:0] tdc_filter_busy, tdc_clip_pulse;
  wire [7:0] tdc_fir_busy, tdc_fir_clip, tdc_rotation_clip;
  assign tdc_clip_pulse = tdc_fir_clip | tdc_rotation_clip;
  wire [31:0] tdc_accepted, tdc_completed, tdc_rejected, tdc_late, tdc_fault_bits;
  wire [7:0] tdc_clipped;
  wire [31:0] tdc_accepted_epoch;
  wire [10:0] tdc_accepted_phase;
  wire tdc_runtime_fault;
  wire tdc_clear = waveform_play_abort;
  wire tdc_output_mute = tdc_mode_dac &&
      (tdc_fault || tdc_runtime_fault || !tdc_ready_sync[2] || !tdc_valid_sync[2] || tdc_clear);
  // The scheduler takes every timestamped external Trigger straight from the
  // event FIFO; tdc_fifo_data is {epoch, phase, tap, good, overflow, bubble}.
  tdc_compensating_trigger u_tdc_scheduler (
      .clk(dac_axis_clk), .rst_n(dac_rst_n), .clear(tdc_clear),
      .enable(tdc_mode_dac), .calibrated(tdc_valid_sync[2]),
      .reference_ready(tdc_ready_sync[2]), .prepared(waveform_prepared_dac),
      .source_running(pc_source_started), .output_busy(|tdc_filter_busy),
      // loop_enable tracks the descriptor loop count the controller actually
      // loops on (waveform_playback_controller loops while loop_count>1), not
      // the standalone cfg bit, so scheduler drain/complete stays in step.
      .source_done(pc_done_pulse), .loop_enable(wave_path_loop_count_dac > 32'd1),
      .runtime_fault(tdc_runtime_fault), .clip_pulse(tdc_clip_pulse),
      .current_epoch(tdc_dac_epoch), .event_valid(tdc_fifo_valid),
      .event_good(tdc_fifo_data[2]), .event_epoch(tdc_fifo_data[56:25]),
      .event_phase_10ps(tdc_fifo_data[24:14]), .phase_offset_10ps(tdc_offset_dac),
      .clear_statistics(tdc_clear_sync[2] != tdc_clear_seen),
      .launch(tdc_launch), .config_valid(tdc_config_valid),
      .delay_samples(tdc_delay_samples), .fractional_phase(tdc_fractional_phase),
      .pending(tdc_pending), .active(tdc_active), .fault(tdc_fault),
      .accepted_count(tdc_accepted), .completed_count(tdc_completed),
      .rejected_count(tdc_rejected), .late_count(tdc_late), .fault_bits(tdc_fault_bits),
      .clipped_channels(tdc_clipped), .accepted_epoch(tdc_accepted_epoch),
      .accepted_phase_10ps(tdc_accepted_phase)
  );
  reg [3:0] tdc_monitor_divider;
  reg tdc_monitor_toggle;
  reg [255:0] tdc_monitor_hold;
  always @(posedge dac_axis_clk or negedge dac_rst_n) begin
    if (!dac_rst_n) begin
      tdc_monitor_divider <= 0; tdc_monitor_toggle <= 0; tdc_monitor_hold <= 0;
    end else begin
      tdc_monitor_divider <= tdc_monitor_divider + 1'b1;
      if (tdc_monitor_divider == 0) begin
        tdc_monitor_hold <= {
            23'd0, tdc_delay_samples, tdc_fractional_phase,
            26'd0, tdc_mode_dac, tdc_ready_sync[2], tdc_valid_sync[2], tdc_fault, tdc_active, tdc_pending,
            24'd0, tdc_clipped, tdc_fault_bits, tdc_late, tdc_rejected, tdc_completed, tdc_accepted};
        tdc_monitor_toggle <= !tdc_monitor_toggle;
      end
    end
  end
  tdc_register_service u_tdc_registers (
      .ddr_clk(ddr4_ui_clk), .ddr_rst_n(ddr4_ui_aresetn),
      .sample_clk(clk_200mhz), .sample_rst_n(tdc_rst_n),
      .reg_valid(tdc_reg_valid), .reg_write(tdc_reg_write), .reg_addr(tdc_reg_addr),
      .reg_wdata(tdc_reg_wdata), .reg_ready(tdc_reg_ready),
      .reg_rdata(tdc_reg_rdata), .reg_error(tdc_reg_error),
      .armed_dac(waveform_armed_dac), .reference_ready(tdc_reference_ready),
      .monitor_toggle(tdc_monitor_toggle), .monitor_data(tdc_monitor_hold),
      .event_valid(tdc_event_valid), .event_good(tdc_event_good),
      .event_overflow(tdc_event_overflow), .event_bubble(tdc_event_bubble),
      .event_epoch(tdc_event_epoch), .event_phase_10ps(tdc_event_phase), .event_tap(tdc_event_tap),
      .calib_wr_en(tdc_calib_wr), .calib_wr_addr(tdc_calib_wr_addr), .calib_wr_data(tdc_calib_wr_data),
      .calib_rd_addr(tdc_calib_rd_addr), .calib_rd_data(tdc_calib_rd_data),
      .compensation_enable(tdc_mode_sample), .calibration_source(tdc_calibration_source),
      .carrier_correction_enable(tdc_carrier_enable_sample), .calibration_valid(tdc_calibrated_sample),
      .phase_offset_10ps(tdc_offset_sample), .clear_statistics_toggle(tdc_stats_clear_toggle)
  );

  // A held status snapshot crosses at a bounded rate, independently of events.
  reg [31:0] tdc_status_hold;
  reg tdc_status_toggle;
  reg [7:0] tdc_status_divider;
  wire [2:0] tdc_compat_slot = tdc_event_phase < 500 ? 3'd0 :
      tdc_event_phase < 1000 ? 3'd1 : tdc_event_phase < 1500 ? 3'd2 : 3'd3;
  always @(posedge clk_200mhz or negedge tdc_rst_n) begin
    if (!tdc_rst_n) begin tdc_status_hold <= 0; tdc_status_toggle <= 0; tdc_status_divider <= 0; end
    else begin
      tdc_status_divider <= tdc_status_divider + 1'b1;
      if (tdc_status_divider == 0) begin
        tdc_status_hold <= {5'd0, tdc_event_phase, tdc_event_tap[7:0], 2'd0,
                            tdc_event_bubble, tdc_event_overflow,
                            tdc_event_good && tdc_calibrated_sample, tdc_compat_slot};
        tdc_status_toggle <= !tdc_status_toggle;
      end
    end
  end
  (* ASYNC_REG = "TRUE" *) reg [2:0] tdc_status_sync_toggle, tdc_live_ddr;
  reg [31:0] tdc_status_meta_ddr, tdc_status_data_ddr;
  reg tdc_status_seen;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn) begin
      tdc_status_sync_toggle <= 0; tdc_live_ddr <= 0;
      tdc_status_meta_ddr <= 0; tdc_status_data_ddr <= 0; tdc_status_seen <= 0;
      ext_trig_slot_ddr <= 3'd0;
      ext_trig_valid_ddr <= 1'b0;
      ext_trig_overflow_ddr <= 1'b0;
      ext_trig_metastable_ddr <= 1'b0;
      ext_trig_tap_index_ddr <= 8'd0;
      ext_trig_phase_ps_x10_ddr <= 16'd0;
    end else begin
      tdc_live_ddr <= {tdc_live_ddr[1:0], tdc_rst_n && tdc_reference_ready};
      tdc_status_sync_toggle <= {tdc_status_sync_toggle[1:0], tdc_status_toggle};
      tdc_status_meta_ddr <= tdc_status_hold;
      tdc_status_data_ddr <= tdc_status_meta_ddr;
      if (!tdc_live_ddr[2]) begin
        ext_trig_valid_ddr <= 0;
      end else if (tdc_status_sync_toggle[2] != tdc_status_seen) begin
        tdc_status_seen <= tdc_status_sync_toggle[2];
        ext_trig_phase_ps_x10_ddr <= tdc_status_data_ddr[31:16];
        ext_trig_tap_index_ddr <= tdc_status_data_ddr[15:8];
        ext_trig_slot_ddr <= tdc_status_data_ddr[2:0];
        ext_trig_metastable_ddr <= tdc_status_data_ddr[5];
        ext_trig_overflow_ddr <= tdc_status_data_ddr[4];
        ext_trig_valid_ddr <= tdc_status_data_ddr[3];
      end
    end
  end

  // ==========================================================
  // DAC AXIS domain reset: synchronize clk104_aresetn to dac_axis_clk.
  // ==========================================================
  reg [2:0] dac_rstff;
  always @(posedge dac_axis_clk or negedge clk104_aresetn) begin
    if(!clk104_aresetn) dac_rstff <= 3'b000;
    else                dac_rstff <= {dac_rstff[1:0], 1'b1};
  end
  assign dac_rst_n = dac_rstff[2];

  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn) begin
      waveform_armed_meta <= 1'b0;
      waveform_armed_ddr <= 1'b0;
      waveform_prepared_meta <= 1'b0;
      waveform_prepared_ddr <= 1'b0;
      waveform_pending_meta <= 1'b0;
      waveform_pending_ddr <= 1'b0;
      pc_started_meta <= 1'b0;
      pc_started_ddr <= 1'b0;
    end else begin
      waveform_armed_meta <= waveform_armed_dac;
      waveform_armed_ddr <= waveform_armed_meta;
      waveform_prepared_meta <= waveform_prepared_dac;
      waveform_prepared_ddr <= waveform_prepared_meta;
      waveform_pending_meta <= waveform_start_pending_dac;
      waveform_pending_ddr <= waveform_pending_meta;
      pc_started_meta <= pc_started;
      pc_started_ddr <= pc_started_meta;
    end
  end

  // The waveform playback path owns command admission and DAC gating.  It also
  // owns the DDR read channel (the M_AXI_DM slot of the DDR smartconnect).
  assign M_AXI_DM_arsize = 3'd6;
  assign M_AXI_DM_arburst = 2'b01;

  // ==========================================================
  // Wave async FIFO (DDR 256-bit AXIS -> DAC 256-bit RFDC AXIS).
  // ==========================================================
  wire [255:0] dac_in_ch1_tdata, dac_in_ch2_tdata, dac_in_ch3_tdata, dac_in_ch4_tdata;
  wire [255:0] dac_in_ch5_tdata, dac_in_ch6_tdata, dac_in_ch7_tdata, dac_in_ch8_tdata;
  wire [2047:0] new_fifo_write_data, new_dac_data;
  wire new_fifo_write_valid;
  wire [7:0] new_fifo_write_ready;
  wire [7:0] new_fifo_read_ready, new_dac_valid;
  wire [31:0] new_reader_error_code_ddr;
  wire [63:0] new_reader_error_offset_ddr;
  wire [15:0] new_fifo_reader_credit;
  wire [7:0] wave_fifo_ready_actual = {ch8_wave_tready_internal, ch7_wave_tready_internal,
      ch6_wave_tready_internal, ch5_wave_tready_internal, ch4_wave_tready_internal,
      ch3_wave_tready_internal, ch2_wave_tready_internal, ch1_wave_tready_internal};
  wire [255:0] wave_fifo_wr_counts = {ch8_wr_count, ch7_wr_count, ch6_wr_count, ch5_wr_count,
      ch4_wr_count, ch3_wr_count, ch2_wr_count, ch1_wr_count};
  wire [7:0] wave_fifo_ready_path;
  wire [7:0] wave_fifo_valid_lane;

  // Keep the FIFO-credit reduction off the upload writer's high-fanout
  // descriptor-mask register.  The mask is already stable before COMMIT is
  // accepted; this one-cycle DDR-domain shadow is therefore both sufficient
  // for reader admission and an explicit timing boundary.  The playback path
  // itself continues to use the authoritative descriptor mask.
  reg [7:0] wave_fifo_credit_mask_ddr_reg;
  reg [15:0] wave_fifo_reader_credit_ddr_reg;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn) begin
      wave_fifo_credit_mask_ddr_reg <= 8'd0;
      wave_fifo_reader_credit_ddr_reg <= 16'd0;
    end else begin
      wave_fifo_credit_mask_ddr_reg <= wave_descriptor_channel_mask;
      // reader_credit is the real write-side free depth, already produced by
      // the mask adapter's four-stage pipeline.  This extra register is a
      // final timing buffer before the 300 MHz AR-reservation logic.  A write
      // reaches this credit 6 cycles later (XPM count register, four adapter
      // stages, this register); the reader holds each written frame's credit
      // for READER_CREDIT_LATENCY (8) cycles to cover that.  Adding a stage
      // here or in the adapter must stay within that hold.
      wave_fifo_reader_credit_ddr_reg <= new_fifo_reader_credit;
    end
  end

  waveform_fifo_mask_adapter #(.FIFO_DEPTH(1024)) waveform_fifo_mask_adapter_i (
      .clk(ddr4_ui_clk), .rst_n(ddr4_ui_aresetn),
      .channel_mask(wave_fifo_credit_mask_ddr_reg),
      .reader_valid(new_fifo_write_valid),
      .fifo_ready_actual(wave_fifo_ready_actual),
      .fifo_wr_counts(wave_fifo_wr_counts),
      .fifo_ready_path(wave_fifo_ready_path),
      .fifo_valid_lane(wave_fifo_valid_lane),
      .reader_credit(new_fifo_reader_credit));

  waveform_playback_path waveform_playback_path_i (
      .ddr_clk(ddr4_ui_clk), .ddr_rst_n(ddr4_ui_aresetn),
      .begin_cmd(wave_begin_valid), .commit_cmd(wave_commit_valid), .play_cmd(wave_play_valid),
      .pause_cmd(wave_pause_valid), .stop_cmd(wave_stop_valid), .abort_cmd(wave_abort_valid),
      .descriptor_base(wave_descriptor_base), .descriptor_total_beats(wave_descriptor_total_beats),
      .descriptor_channel_mask(wave_descriptor_channel_mask), .descriptor_loop_count(wave_descriptor_loop_count),
      .descriptor_generation(wave_descriptor_generation),
      .command_ready_ddr(wave_command_ready_ddr),
      .fifo_free_beats(wave_fifo_reader_credit_ddr_reg), .fifo_write_data(new_fifo_write_data),
      .fifo_write_valid(new_fifo_write_valid), .fifo_write_ready(new_fifo_write_ready),
      .fifo_write_last(), .prefetch_safe_ddr(new_prefetch_safe_ddr),
      .fifo_clear_ddr(new_fifo_clear_ddr), .reader_busy_ddr(), .reader_done_ddr(),
      .reader_error_ddr(new_reader_error_ddr), .reader_error_code_ddr(new_reader_error_code_ddr),
      .reader_error_offset_ddr(new_reader_error_offset_ddr), .m_axi_araddr(M_AXI_DM_araddr),
      .m_axi_arlen(M_AXI_DM_arlen), .m_axi_arvalid(M_AXI_DM_arvalid), .m_axi_arready(M_AXI_DM_arready),
      .m_axi_rdata(M_AXI_DM_rdata), .m_axi_rresp(M_AXI_DM_rresp), .m_axi_rvalid(M_AXI_DM_rvalid),
      .m_axi_rlast(M_AXI_DM_rlast), .m_axi_rready(M_AXI_DM_rready), .dac_clk(dac_axis_clk),
      .dac_rst_n(dac_rst_n),
      // Launch source: in TDC-compensation mode the FSM starts on the
      // scheduler's deterministic launch pulse (launch_sync=tdc_launch) and the
      // raw pad capture is disabled; otherwise it starts on the async external
      // TRIG_2 pad. TRIG_2 always still feeds tdc_event_capture for timestamps.
      .trigger_in(tdc_mode_dac ? 1'b0 : TRIG_2),
      .launch_sync(tdc_mode_dac ? tdc_launch : 1'b0),
      .fifo_data({dac_in_ch8_tdata,dac_in_ch7_tdata,dac_in_ch6_tdata,dac_in_ch5_tdata,dac_in_ch4_tdata,dac_in_ch3_tdata,dac_in_ch2_tdata,dac_in_ch1_tdata}),
      .fifo_valid({dac_in_ch8_tvalid,dac_in_ch7_tvalid,dac_in_ch6_tvalid,dac_in_ch5_tvalid,dac_in_ch4_tvalid,dac_in_ch3_tvalid,dac_in_ch2_tvalid,dac_in_ch1_tvalid}),
      .fifo_read_ready(new_fifo_read_ready), .dac_ready({dac_ch8_ready,dac_ch7_ready,dac_ch6_ready,dac_ch5_ready,dac_ch4_ready,dac_ch3_ready,dac_ch2_ready,dac_ch1_ready}),
      .dac_data(new_dac_data), .dac_valid(new_dac_valid), .dac_last(), .dac_keep(),
      .state_dac(wave_new_state), .dac_gate(wave_new_dac_gate),
      .trigger_seen_count(wave_path_trigger_seen_count_dac),
      .trigger_dropped_count(wave_path_trigger_dropped_count_dac),
      .trigger_fire_count(wave_path_trigger_fire_count_dac),
      .current_beat_dac(wave_path_current_beat_dac), .loop_position_dac(wave_path_loop_position_dac),
      .loop_count_dac(wave_path_loop_count_dac), .descriptor_generation_dac(wave_path_generation_dac),
      .channel_mask_dac(wave_path_channel_mask_dac), .underflow_count_dac(wave_path_underflow_count_dac),
      .output_first_transfer(new_output_first_transfer), .output_beat_fire(),
      .output_beat_last(), .output_underflow()
  );

  waveform_status_cdc #(.WIDTH(296)) waveform_status_cdc_i (
      .ddr_clk(ddr4_ui_clk), .ddr_rst_n(ddr4_ui_aresetn),
      .request_ddr(wave_status_request), .request_ready_ddr(wave_status_request_ready),
      .snapshot_valid_ddr(wave_status_snapshot_valid), .snapshot_data_ddr(wave_status_snapshot_data),
      .dac_clk(dac_axis_clk), .dac_rst_n(dac_rst_n), .source_data_dac(wave_status_source_dac)
  );

  reg wave_reader_error_seen_ddr;
  reg [31:0] wave_reader_error_count_reg_ddr;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn) begin
      wave_reader_error_seen_ddr <= 1'b0;
      wave_reader_error_count_reg_ddr <= 32'd0;
    end else begin
      wave_reader_error_seen_ddr <= new_reader_error_ddr;
      if (new_reader_error_ddr && !wave_reader_error_seen_ddr &&
          wave_reader_error_count_reg_ddr != 32'hffffffff)
        wave_reader_error_count_reg_ddr <= wave_reader_error_count_reg_ddr + 1'b1;
    end
  end
  assign wave_reader_error_count_ddr = wave_reader_error_count_reg_ddr;
  assign wave_status_result_status_ddr = new_reader_error_ddr ? 16'd9 :
      ((wave_status_state_ddr == 32'd8) ? 16'd11 : 16'd0);
  assign wave_status_result_error_code_ddr = new_reader_error_ddr ? new_reader_error_code_ddr :
      ((wave_status_state_ddr == 32'd8 && wave_status_underflow_count_ddr != 0) ? 32'd1 : 32'd0);
  assign wave_status_result_error_offset_ddr = new_reader_error_ddr ? new_reader_error_offset_ddr :
      wave_writer_error_offset;
  assign {ch8_wave_tdata,ch7_wave_tdata,ch6_wave_tdata,ch5_wave_tdata,ch4_wave_tdata,ch3_wave_tdata,ch2_wave_tdata,ch1_wave_tdata} = new_fifo_write_data;
  assign {ch8_wave_tvalid,ch7_wave_tvalid,ch6_wave_tvalid,ch5_wave_tvalid,ch4_wave_tvalid,ch3_wave_tvalid,ch2_wave_tvalid,ch1_wave_tvalid} = wave_fifo_valid_lane;
  assign new_fifo_write_ready = wave_fifo_ready_path;

  // Playback status levels for RFCTRL2 STATUS, the network controller and
  // the TDC scheduler, decoded from the playback FSM state.  They are
  // registered in the DAC domain before the DDR-domain synchronizers so the
  // CDC boundary does not depend on state-decode combinational logic.
  always @(posedge dac_axis_clk or negedge clk104_aresetn) begin
    if (!clk104_aresetn) begin
      waveform_armed_dac_reg <= 1'b0;
      waveform_prepared_dac_reg <= 1'b0;
      waveform_start_pending_dac_reg <= 1'b0;
      pc_started_dac_reg <= 1'b0;
    end else begin
      waveform_armed_dac_reg <= (wave_new_state != 4'd0) && (wave_new_state != 4'd8);
      waveform_prepared_dac_reg <= (wave_new_state == 4'd4) ||
                                   (wave_new_state == 4'd5) ||
                                   (wave_new_state == 4'd6) ||
                                   (wave_new_state == 4'd7);
      waveform_start_pending_dac_reg <= (wave_new_state == 4'd3);
      pc_started_dac_reg <= wave_new_dac_gate;
    end
  end
  assign waveform_armed_dac = waveform_armed_dac_reg;
  assign waveform_prepared_dac = waveform_prepared_dac_reg;
  assign waveform_start_pending_dac = waveform_start_pending_dac_reg;
  assign waveform_play_abort = wave_control_abort_dac || (wave_new_state == 4'd8);
  assign pc_source_started = pc_started_dac_reg;
  assign pc_started = pc_started_dac_reg;

  // source_done for the compensating-trigger scheduler: one dac_axis_clk
  // pulse when the playback FSM enters ST_DONE (wave_new_state == 7).  Without
  // it the scheduler never drains and rejects the next Trigger.
  reg wave_done_prev_dac;
  reg pc_done_pulse_reg;
  always @(posedge dac_axis_clk or negedge dac_rst_n) begin
    if (!dac_rst_n) begin
      wave_done_prev_dac <= 1'b0;
      pc_done_pulse_reg  <= 1'b0;
    end else begin
      wave_done_prev_dac <= (wave_new_state == 4'd7);
      pc_done_pulse_reg  <= (wave_new_state == 4'd7) && !wave_done_prev_dac;
    end
  end
  assign pc_done_pulse = pc_done_pulse_reg;

  reg [4:0] wave_fifo_reset_cnt;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) begin
      wave_fifo_reset_cnt <= 5'd0;
    end else if(new_fifo_clear_ddr) begin
      // The playback path is the only FIFO-clear authority: it waits for the
      // DDR reader to retire and, for BEGIN/PAUSE/STOP, for the DAC FSM to
      // acknowledge the command, so the DAC side never sees its FIFOs vanish
      // while it is still PLAYING or WAIT_TRIGGER.
      wave_fifo_reset_cnt <= 5'd16;
    end else if(wave_fifo_reset_cnt != 5'd0) begin
      wave_fifo_reset_cnt <= wave_fifo_reset_cnt - 5'd1;
    end
  end
  wire wave_fifo_aresetn = ddr4_ui_aresetn & (wave_fifo_reset_cnt == 5'd0);

  wire [2047:0] tdc_input_data = new_dac_data;
  wire [7:0] tdc_input_valid = new_dac_valid;
  wire [7:0] tdc_channel_allow = wave_path_channel_mask_dac;
  wire [7:0] tdc_channel_ready = {dac_ch8_ready, dac_ch7_ready, dac_ch6_ready, dac_ch5_ready,
      dac_ch4_ready, dac_ch3_ready, dac_ch2_ready, dac_ch1_ready};
  assign tdc_runtime_fault = tdc_mode_dac && tdc_active &&
      ((|(tdc_channel_allow & ~tdc_input_valid)) || !rfdc_output_permitted_dac || tdc_loss_sync[2]);
  wire [2047:0] tdc_filtered_data;
  wire [2047:0] tdc_corrected_data;
  // RFDC feed selects the TDC-compensated stream when tdc_mode_dac is set
  // (deterministic-trigger path: fractional delay + carrier phase rotation),
  // otherwise the raw playback stream. The compensated branch must NOT be
  // masked by the instantaneous wave_new_dac_gate so the FIR(7)+rotator(3)
  // pipeline can fill on launch and flush its tail at end-of-frame; it gates
  // only on rfdc_output_permitted_dac and tdc_output_mute. The raw branch keeps
  // the wave_new_dac_gate mask so no stale FIFO payload leaks while gated. Both
  // branches present valid zero samples outside a permitted play. Per-channel
  // selects are assigned in the tdc_channels generate loop below.
  wire [2047:0] rfdc_all_data;
  wire [7:0] rfdc_all_valid;
  genvar tdc_channel;
  generate
    for (tdc_channel = 0; tdc_channel < 8; tdc_channel = tdc_channel + 1) begin : tdc_channels
      iq_fractional_delay_8ppc u_delay (
          .clk(dac_axis_clk), .rst_n(dac_rst_n), .clear(tdc_clear || tdc_output_mute),
          .config_valid(tdc_config_valid), .delay_samples(tdc_delay_samples),
          .fractional_phase(tdc_fractional_phase),
          .source_data(tdc_input_data[tdc_channel*256 +: 256]),
          .source_valid(tdc_mode_dac && tdc_channel_allow[tdc_channel] &&
                        tdc_input_valid[tdc_channel] && tdc_channel_ready[tdc_channel] && !tdc_output_mute),
          .out_data(tdc_filtered_data[tdc_channel*256 +: 256]),
          .busy(tdc_fir_busy[tdc_channel]), .clip_pulse(tdc_fir_clip[tdc_channel])
      );
      iq_event_phase_rotator u_phase (
          .clk(dac_axis_clk), .rst_n(dac_rst_n), .clear(tdc_clear || tdc_output_mute),
          .config_valid(tdc_config_valid), .armed(waveform_armed_dac), .enable(tdc_carrier_enable_dac),
          .frequency_word(rfdc_actual_nco_word[tdc_channel*64 +: 48]),
          .current_epoch(tdc_dac_epoch), .event_epoch(tdc_accepted_epoch),
          .event_phase_10ps(tdc_accepted_phase),
          .in_data(tdc_filtered_data[tdc_channel*256 +: 256]), .in_busy(tdc_fir_busy[tdc_channel]),
          .out_data(tdc_corrected_data[tdc_channel*256 +: 256]),
          .busy(tdc_filter_busy[tdc_channel]), .clip_pulse(tdc_rotation_clip[tdc_channel])
      );
      // Compensated (tdc_mode_dac=1): fill/flush on permit+mute only. Raw
      // (tdc_mode_dac=0): identical to the previous rfdc_all_data behaviour,
      // masked by wave_new_dac_gate so no stale FIFO payload leaks while gated.
      assign rfdc_all_data[tdc_channel*256 +: 256] = !rfdc_output_permitted_dac ? 256'd0 :
          tdc_mode_dac ? (tdc_output_mute ? 256'd0 : tdc_corrected_data[tdc_channel*256 +: 256]) :
          (wave_new_dac_gate ? tdc_input_data[tdc_channel*256 +: 256] : 256'd0);
      assign rfdc_all_valid[tdc_channel] = tdc_mode_dac ? 1'b1 :
          ((rfdc_output_permitted_dac && wave_new_dac_gate) ? tdc_input_valid[tdc_channel] : 1'b1);
    end
  endgenerate
  wire [255:0] rfdc_ch1_tdata = rfdc_all_data[0 +: 256];
  wire [255:0] rfdc_ch2_tdata = rfdc_all_data[256 +: 256];
  wire [255:0] rfdc_ch3_tdata = rfdc_all_data[512 +: 256];
  wire [255:0] rfdc_ch4_tdata = rfdc_all_data[768 +: 256];
  wire [255:0] rfdc_ch5_tdata = rfdc_all_data[1024 +: 256];
  wire [255:0] rfdc_ch6_tdata = rfdc_all_data[1280 +: 256];
  wire [255:0] rfdc_ch7_tdata = rfdc_all_data[1536 +: 256];
  wire [255:0] rfdc_ch8_tdata = rfdc_all_data[1792 +: 256];
  wire rfdc_ch1_tvalid = rfdc_all_valid[0];
  wire rfdc_ch2_tvalid = rfdc_all_valid[1];
  wire rfdc_ch3_tvalid = rfdc_all_valid[2];
  wire rfdc_ch4_tvalid = rfdc_all_valid[3];
  wire rfdc_ch5_tvalid = rfdc_all_valid[4];
  wire rfdc_ch6_tvalid = rfdc_all_valid[5];
  wire rfdc_ch7_tvalid = rfdc_all_valid[6];
  wire rfdc_ch8_tvalid = rfdc_all_valid[7];

  axis_async_fifo_256 fifo_ch1_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch1_wave_tvalid),
    .s_axis_tready (ch1_wave_tready_internal),
    .s_axis_tdata  (ch1_wave_tdata),
    .s_axis_tlast  (1'b0),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch1_tvalid),
    .m_axis_tready (new_fifo_read_ready[0]),
    .m_axis_tdata  (dac_in_ch1_tdata),
    .m_axis_tlast  (),

    .axis_wr_data_count(ch1_wr_count),
    .prog_empty        (),
    .prog_full         ()
  );

  axis_async_fifo_256 fifo_ch2_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch2_wave_tvalid),
    .s_axis_tready (ch2_wave_tready_internal),
    .s_axis_tdata  (ch2_wave_tdata),
    .s_axis_tlast  (1'b0),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch2_tvalid),
    .m_axis_tready (new_fifo_read_ready[1]),
    .m_axis_tdata  (dac_in_ch2_tdata),
    .m_axis_tlast  (),

    .axis_wr_data_count(ch2_wr_count),
    .prog_empty        (),
    .prog_full         ()
  );


  axis_async_fifo_256 fifo_ch3_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch3_wave_tvalid),
    .s_axis_tready (ch3_wave_tready_internal),
    .s_axis_tdata  (ch3_wave_tdata),
    .s_axis_tlast  (1'b0),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch3_tvalid),
    .m_axis_tready (new_fifo_read_ready[2]),
    .m_axis_tdata  (dac_in_ch3_tdata),
    .m_axis_tlast  (),

    .axis_wr_data_count(ch3_wr_count),
    .prog_empty        (),
    .prog_full         ()
  );

  axis_async_fifo_256 fifo_ch4_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch4_wave_tvalid),
    .s_axis_tready (ch4_wave_tready_internal),
    .s_axis_tdata  (ch4_wave_tdata),
    .s_axis_tlast  (1'b0),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch4_tvalid),
    .m_axis_tready (new_fifo_read_ready[3]),
    .m_axis_tdata  (dac_in_ch4_tdata),
    .m_axis_tlast  (),

    .axis_wr_data_count(ch4_wr_count),
    .prog_empty        (),
    .prog_full         ()
  );

  axis_async_fifo_256 fifo_ch5_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch5_wave_tvalid),
    .s_axis_tready (ch5_wave_tready_internal),
    .s_axis_tdata  (ch5_wave_tdata),
    .s_axis_tlast  (1'b0),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch5_tvalid),
    .m_axis_tready (new_fifo_read_ready[4]),
    .m_axis_tdata  (dac_in_ch5_tdata),
    .m_axis_tlast  (),

    .axis_wr_data_count(ch5_wr_count),
    .prog_empty        (),
    .prog_full         ()
  );

  axis_async_fifo_256 fifo_ch6_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch6_wave_tvalid),
    .s_axis_tready (ch6_wave_tready_internal),
    .s_axis_tdata  (ch6_wave_tdata),
    .s_axis_tlast  (1'b0),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch6_tvalid),
    .m_axis_tready (new_fifo_read_ready[5]),
    .m_axis_tdata  (dac_in_ch6_tdata),
    .m_axis_tlast  (),

    .axis_wr_data_count(ch6_wr_count),
    .prog_empty        (),
    .prog_full         ()
  );

  axis_async_fifo_256 fifo_ch7_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch7_wave_tvalid),
    .s_axis_tready (ch7_wave_tready_internal),
    .s_axis_tdata  (ch7_wave_tdata),
    .s_axis_tlast  (1'b0),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch7_tvalid),
    .m_axis_tready (new_fifo_read_ready[6]),
    .m_axis_tdata  (dac_in_ch7_tdata),
    .m_axis_tlast  (),

    .axis_wr_data_count(ch7_wr_count),
    .prog_empty        (),
    .prog_full         ()
  );

  axis_async_fifo_256 fifo_ch8_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch8_wave_tvalid),
    .s_axis_tready (ch8_wave_tready_internal),
    .s_axis_tdata  (ch8_wave_tdata),
    .s_axis_tlast  (1'b0),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch8_tvalid),
    .m_axis_tready (new_fifo_read_ready[7]),
    .m_axis_tdata  (dac_in_ch8_tdata),
    .m_axis_tlast  (),

    .axis_wr_data_count(ch8_wr_count),
    .prog_empty        (),
    .prog_full         ()
  );

  // ==========================================================
  // PS AXI masters out of design_1
  // ==========================================================
  // M_AXI_GPIO (AXI4-Lite): firmware status register
  wire [31:0] M_AXI_GPIO_araddr;
  wire        M_AXI_GPIO_arready;
  wire        M_AXI_GPIO_arvalid;

  wire [31:0] M_AXI_GPIO_awaddr;
  wire        M_AXI_GPIO_awready;
  wire        M_AXI_GPIO_awvalid;

  wire        M_AXI_GPIO_bready;
  wire [1:0]  M_AXI_GPIO_bresp;
  wire        M_AXI_GPIO_bvalid;

  wire [31:0] M_AXI_GPIO_rdata;
  wire        M_AXI_GPIO_rready;
  wire [1:0]  M_AXI_GPIO_rresp;
  wire        M_AXI_GPIO_rvalid;

  wire [31:0] M_AXI_GPIO_wdata;
  wire        M_AXI_GPIO_wready;
  wire [3:0]  M_AXI_GPIO_wstrb;
  wire        M_AXI_GPIO_wvalid;

  wire [31:0] M_AXI_RFDC_araddr;
  wire        M_AXI_RFDC_arready;
  wire        M_AXI_RFDC_arvalid;

  wire [31:0] M_AXI_RFDC_awaddr;
  wire        M_AXI_RFDC_awready;
  wire        M_AXI_RFDC_awvalid;

  wire        M_AXI_RFDC_bready;
  wire [1:0]  M_AXI_RFDC_bresp;
  wire        M_AXI_RFDC_bvalid;

  wire [31:0] M_AXI_RFDC_rdata;
  wire        M_AXI_RFDC_rready;
  wire [1:0]  M_AXI_RFDC_rresp;
  wire        M_AXI_RFDC_rvalid;

  wire [31:0] M_AXI_RFDC_wdata;
  wire        M_AXI_RFDC_wready;
  wire [3:0]  M_AXI_RFDC_wstrb;
  wire        M_AXI_RFDC_wvalid;

  wire [17:0] RFDC_S_AXI_araddr;
  wire        RFDC_S_AXI_arready;
  wire        RFDC_S_AXI_arvalid;
  wire [17:0] RFDC_S_AXI_awaddr;
  wire        RFDC_S_AXI_awready;
  wire        RFDC_S_AXI_awvalid;
  wire        RFDC_S_AXI_bready;
  wire [1:0]  RFDC_S_AXI_bresp;
  wire        RFDC_S_AXI_bvalid;
  wire [31:0] RFDC_S_AXI_rdata;
  wire        RFDC_S_AXI_rready;
  wire [1:0]  RFDC_S_AXI_rresp;
  wire        RFDC_S_AXI_rvalid;
  wire [31:0] RFDC_S_AXI_wdata;
  wire        RFDC_S_AXI_wready;
  wire [3:0]  RFDC_S_AXI_wstrb;
  wire        RFDC_S_AXI_wvalid;
  axilite_arbiter_2to1 #(.ADDR_WIDTH(18)) ps_pl_rfdc_axil_arbiter_i (
      .clk(pl_clk), .rst_n(pl_aresetn),
      .s0_awaddr(M_AXI_RFDC_awaddr[17:0]), .s0_awvalid(M_AXI_RFDC_awvalid), .s0_awready(M_AXI_RFDC_awready),
      .s0_wdata(M_AXI_RFDC_wdata), .s0_wstrb(M_AXI_RFDC_wstrb), .s0_wvalid(M_AXI_RFDC_wvalid), .s0_wready(M_AXI_RFDC_wready),
      .s0_bresp(M_AXI_RFDC_bresp), .s0_bvalid(M_AXI_RFDC_bvalid), .s0_bready(M_AXI_RFDC_bready),
      .s0_araddr(M_AXI_RFDC_araddr[17:0]), .s0_arvalid(M_AXI_RFDC_arvalid), .s0_arready(M_AXI_RFDC_arready),
      .s0_rdata(M_AXI_RFDC_rdata), .s0_rresp(M_AXI_RFDC_rresp), .s0_rvalid(M_AXI_RFDC_rvalid), .s0_rready(M_AXI_RFDC_rready),
      .s1_awaddr(RV_AXI_RFDC_awaddr), .s1_awvalid(RV_AXI_RFDC_awvalid), .s1_awready(RV_AXI_RFDC_awready),
      .s1_wdata(RV_AXI_RFDC_wdata), .s1_wstrb(RV_AXI_RFDC_wstrb), .s1_wvalid(RV_AXI_RFDC_wvalid), .s1_wready(RV_AXI_RFDC_wready),
      .s1_bresp(RV_AXI_RFDC_bresp), .s1_bvalid(RV_AXI_RFDC_bvalid), .s1_bready(RV_AXI_RFDC_bready),
      .s1_araddr(RV_AXI_RFDC_araddr), .s1_arvalid(RV_AXI_RFDC_arvalid), .s1_arready(RV_AXI_RFDC_arready),
      .s1_rdata(RV_AXI_RFDC_rdata), .s1_rresp(RV_AXI_RFDC_rresp), .s1_rvalid(RV_AXI_RFDC_rvalid), .s1_rready(RV_AXI_RFDC_rready),
      .m_awaddr(RFDC_S_AXI_awaddr), .m_awvalid(RFDC_S_AXI_awvalid), .m_awready(RFDC_S_AXI_awready),
      .m_wdata(RFDC_S_AXI_wdata), .m_wstrb(RFDC_S_AXI_wstrb), .m_wvalid(RFDC_S_AXI_wvalid), .m_wready(RFDC_S_AXI_wready),
      .m_bresp(RFDC_S_AXI_bresp), .m_bvalid(RFDC_S_AXI_bvalid), .m_bready(RFDC_S_AXI_bready),
      .m_araddr(RFDC_S_AXI_araddr), .m_arvalid(RFDC_S_AXI_arvalid), .m_arready(RFDC_S_AXI_arready),
      .m_rdata(RFDC_S_AXI_rdata), .m_rresp(RFDC_S_AXI_rresp), .m_rvalid(RFDC_S_AXI_rvalid), .m_rready(RFDC_S_AXI_rready)
  );

  wire [39:0]  M_AXI_DDR4_araddr;
  wire [1:0]   M_AXI_DDR4_arburst;
  wire [3:0]   M_AXI_DDR4_arcache;
  wire [7:0]   M_AXI_DDR4_arlen;
  wire [0:0]   M_AXI_DDR4_arlock;
  wire [2:0]   M_AXI_DDR4_arprot;
  wire [3:0]   M_AXI_DDR4_arqos;
  wire         M_AXI_DDR4_arready;
  wire [2:0]   M_AXI_DDR4_arsize;
  wire         M_AXI_DDR4_arvalid;

  wire [39:0]  M_AXI_DDR4_awaddr;
  wire [1:0]   M_AXI_DDR4_awburst;
  wire [3:0]   M_AXI_DDR4_awcache;
  wire [7:0]   M_AXI_DDR4_awlen;
  wire [0:0]   M_AXI_DDR4_awlock;
  wire [2:0]   M_AXI_DDR4_awprot;
  wire [3:0]   M_AXI_DDR4_awqos;
  wire         M_AXI_DDR4_awready;
  wire [2:0]   M_AXI_DDR4_awsize;
  wire         M_AXI_DDR4_awvalid;

  wire         M_AXI_DDR4_bready;
  wire [1:0]   M_AXI_DDR4_bresp;
  wire         M_AXI_DDR4_bvalid;

  wire [511:0] M_AXI_DDR4_rdata;
  wire         M_AXI_DDR4_rlast;
  wire         M_AXI_DDR4_rready;
  wire [1:0]   M_AXI_DDR4_rresp;
  wire         M_AXI_DDR4_rvalid;

  wire [511:0] M_AXI_DDR4_wdata;
  wire         M_AXI_DDR4_wlast;
  wire         M_AXI_DDR4_wready;
  wire [63:0]  M_AXI_DDR4_wstrb;
  wire         M_AXI_DDR4_wvalid;

  wire [39:0]  M_AXI_PS_DDR_araddr;
  wire [1:0]   M_AXI_PS_DDR_arburst;
  wire [3:0]   M_AXI_PS_DDR_arcache;
  wire [15:0]  M_AXI_PS_DDR_arid;
  wire [7:0]   M_AXI_PS_DDR_arlen;
  wire         M_AXI_PS_DDR_arlock;
  wire [2:0]   M_AXI_PS_DDR_arprot;
  wire [3:0]   M_AXI_PS_DDR_arqos;
  wire         M_AXI_PS_DDR_arready;
  wire [2:0]   M_AXI_PS_DDR_arsize;
  wire [15:0]  M_AXI_PS_DDR_aruser;
  wire         M_AXI_PS_DDR_arvalid;

  wire [39:0]  M_AXI_PS_DDR_awaddr;
  wire [1:0]   M_AXI_PS_DDR_awburst;
  wire [3:0]   M_AXI_PS_DDR_awcache;
  wire [15:0]  M_AXI_PS_DDR_awid;
  wire [7:0]   M_AXI_PS_DDR_awlen;
  wire         M_AXI_PS_DDR_awlock;
  wire [2:0]   M_AXI_PS_DDR_awprot;
  wire [3:0]   M_AXI_PS_DDR_awqos;
  wire         M_AXI_PS_DDR_awready;
  wire [2:0]   M_AXI_PS_DDR_awsize;
  wire [15:0]  M_AXI_PS_DDR_awuser;
  wire         M_AXI_PS_DDR_awvalid;

  wire [15:0]  M_AXI_PS_DDR_bid;
  wire         M_AXI_PS_DDR_bready;
  wire [1:0]   M_AXI_PS_DDR_bresp;
  wire         M_AXI_PS_DDR_bvalid;

  wire [127:0] M_AXI_PS_DDR_rdata;
  wire [15:0]  M_AXI_PS_DDR_rid;
  wire         M_AXI_PS_DDR_rlast;
  wire         M_AXI_PS_DDR_rready;
  wire [1:0]   M_AXI_PS_DDR_rresp;
  wire         M_AXI_PS_DDR_rvalid;

  wire [127:0] M_AXI_PS_DDR_wdata;
  wire         M_AXI_PS_DDR_wlast;
  wire         M_AXI_PS_DDR_wready;
  wire [15:0]  M_AXI_PS_DDR_wstrb;
  wire         M_AXI_PS_DDR_wvalid;


  design_1 design_1_i (
      .pl_clk(pl_clk),
      .pl_aresetn(pl_aresetn),
      .pl_resetn0(pl_resetn0),
      .pl_ps_irq(pl_ps_irq),
      .ddr4_ui_clk(ddr4_ui_clk),




      .M_AXI_RFDC_araddr(M_AXI_RFDC_araddr),
      .M_AXI_RFDC_arready(M_AXI_RFDC_arready),
      .M_AXI_RFDC_arvalid(M_AXI_RFDC_arvalid),
      .M_AXI_RFDC_awaddr(M_AXI_RFDC_awaddr),
      .M_AXI_RFDC_awready(M_AXI_RFDC_awready),
      .M_AXI_RFDC_awvalid(M_AXI_RFDC_awvalid),
      .M_AXI_RFDC_bready(M_AXI_RFDC_bready),
      .M_AXI_RFDC_bresp(M_AXI_RFDC_bresp),
      .M_AXI_RFDC_bvalid(M_AXI_RFDC_bvalid),
      .M_AXI_RFDC_rdata(M_AXI_RFDC_rdata),
      .M_AXI_RFDC_rready(M_AXI_RFDC_rready),
      .M_AXI_RFDC_rresp(M_AXI_RFDC_rresp),
      .M_AXI_RFDC_rvalid(M_AXI_RFDC_rvalid),
      .M_AXI_RFDC_wdata(M_AXI_RFDC_wdata),
      .M_AXI_RFDC_wready(M_AXI_RFDC_wready),
      .M_AXI_RFDC_wstrb(M_AXI_RFDC_wstrb),
      .M_AXI_RFDC_wvalid(M_AXI_RFDC_wvalid),

      .M_AXI_PS_DDR_araddr(M_AXI_PS_DDR_araddr),
      .M_AXI_PS_DDR_arburst(M_AXI_PS_DDR_arburst),
      .M_AXI_PS_DDR_arcache(M_AXI_PS_DDR_arcache),
      .M_AXI_PS_DDR_arid(M_AXI_PS_DDR_arid),
      .M_AXI_PS_DDR_arlen(M_AXI_PS_DDR_arlen),
      .M_AXI_PS_DDR_arlock(M_AXI_PS_DDR_arlock),
      .M_AXI_PS_DDR_arprot(M_AXI_PS_DDR_arprot),
      .M_AXI_PS_DDR_arqos(M_AXI_PS_DDR_arqos),
      .M_AXI_PS_DDR_arready(M_AXI_PS_DDR_arready),
      .M_AXI_PS_DDR_arsize(M_AXI_PS_DDR_arsize),
      .M_AXI_PS_DDR_aruser(M_AXI_PS_DDR_aruser),
      .M_AXI_PS_DDR_arvalid(M_AXI_PS_DDR_arvalid),
      .M_AXI_PS_DDR_awaddr(M_AXI_PS_DDR_awaddr),
      .M_AXI_PS_DDR_awburst(M_AXI_PS_DDR_awburst),
      .M_AXI_PS_DDR_awcache(M_AXI_PS_DDR_awcache),
      .M_AXI_PS_DDR_awid(M_AXI_PS_DDR_awid),
      .M_AXI_PS_DDR_awlen(M_AXI_PS_DDR_awlen),
      .M_AXI_PS_DDR_awlock(M_AXI_PS_DDR_awlock),
      .M_AXI_PS_DDR_awprot(M_AXI_PS_DDR_awprot),
      .M_AXI_PS_DDR_awqos(M_AXI_PS_DDR_awqos),
      .M_AXI_PS_DDR_awready(M_AXI_PS_DDR_awready),
      .M_AXI_PS_DDR_awsize(M_AXI_PS_DDR_awsize),
      .M_AXI_PS_DDR_awuser(M_AXI_PS_DDR_awuser),
      .M_AXI_PS_DDR_awvalid(M_AXI_PS_DDR_awvalid),
      .M_AXI_PS_DDR_bid(M_AXI_PS_DDR_bid),
      .M_AXI_PS_DDR_bready(M_AXI_PS_DDR_bready),
      .M_AXI_PS_DDR_bresp(M_AXI_PS_DDR_bresp),
      .M_AXI_PS_DDR_bvalid(M_AXI_PS_DDR_bvalid),
      .M_AXI_PS_DDR_rdata(M_AXI_PS_DDR_rdata),
      .M_AXI_PS_DDR_rid(M_AXI_PS_DDR_rid),
      .M_AXI_PS_DDR_rlast(M_AXI_PS_DDR_rlast),
      .M_AXI_PS_DDR_rready(M_AXI_PS_DDR_rready),
      .M_AXI_PS_DDR_rresp(M_AXI_PS_DDR_rresp),
      .M_AXI_PS_DDR_rvalid(M_AXI_PS_DDR_rvalid),
      .M_AXI_PS_DDR_wdata(M_AXI_PS_DDR_wdata),
      .M_AXI_PS_DDR_wlast(M_AXI_PS_DDR_wlast),
      .M_AXI_PS_DDR_wready(M_AXI_PS_DDR_wready),
      .M_AXI_PS_DDR_wstrb(M_AXI_PS_DDR_wstrb),
      .M_AXI_PS_DDR_wvalid(M_AXI_PS_DDR_wvalid),


      .M_AXI_GPIO_araddr (M_AXI_GPIO_araddr),
      .M_AXI_GPIO_arready(M_AXI_GPIO_arready),
      .M_AXI_GPIO_arvalid(M_AXI_GPIO_arvalid),
      .M_AXI_GPIO_awaddr (M_AXI_GPIO_awaddr),
      .M_AXI_GPIO_awready(M_AXI_GPIO_awready),
      .M_AXI_GPIO_awvalid(M_AXI_GPIO_awvalid),
      .M_AXI_GPIO_bready (M_AXI_GPIO_bready),
      .M_AXI_GPIO_bresp  (M_AXI_GPIO_bresp),
      .M_AXI_GPIO_bvalid (M_AXI_GPIO_bvalid),
      .M_AXI_GPIO_rdata  (M_AXI_GPIO_rdata),
      .M_AXI_GPIO_rready (M_AXI_GPIO_rready),
      .M_AXI_GPIO_rresp  (M_AXI_GPIO_rresp),
      .M_AXI_GPIO_rvalid (M_AXI_GPIO_rvalid),
      .M_AXI_GPIO_wdata  (M_AXI_GPIO_wdata),
      .M_AXI_GPIO_wready (M_AXI_GPIO_wready),
      .M_AXI_GPIO_wstrb  (M_AXI_GPIO_wstrb),
      .M_AXI_GPIO_wvalid (M_AXI_GPIO_wvalid)
  );

  ddr_axi_smartconnect_wrapper ddr_axi_smartconnect_i (
      .aclk(ddr4_ui_clk),
      .aresetn(ddr4_ui_aresetn),

      .S_AXI_PS_araddr(M_AXI_PS_DDR_araddr),
      .S_AXI_PS_arburst(M_AXI_PS_DDR_arburst),
      .S_AXI_PS_arcache(M_AXI_PS_DDR_arcache),
      .S_AXI_PS_arid(M_AXI_PS_DDR_arid),
      .S_AXI_PS_arlen(M_AXI_PS_DDR_arlen),
      .S_AXI_PS_arlock(M_AXI_PS_DDR_arlock),
      .S_AXI_PS_arprot(M_AXI_PS_DDR_arprot),
      .S_AXI_PS_arqos(M_AXI_PS_DDR_arqos),
      .S_AXI_PS_arready(M_AXI_PS_DDR_arready),
      .S_AXI_PS_arsize(M_AXI_PS_DDR_arsize),
      .S_AXI_PS_aruser(M_AXI_PS_DDR_aruser),
      .S_AXI_PS_arvalid(M_AXI_PS_DDR_arvalid),
      .S_AXI_PS_awaddr(M_AXI_PS_DDR_awaddr),
      .S_AXI_PS_awburst(M_AXI_PS_DDR_awburst),
      .S_AXI_PS_awcache(M_AXI_PS_DDR_awcache),
      .S_AXI_PS_awid(M_AXI_PS_DDR_awid),
      .S_AXI_PS_awlen(M_AXI_PS_DDR_awlen),
      .S_AXI_PS_awlock(M_AXI_PS_DDR_awlock),
      .S_AXI_PS_awprot(M_AXI_PS_DDR_awprot),
      .S_AXI_PS_awqos(M_AXI_PS_DDR_awqos),
      .S_AXI_PS_awready(M_AXI_PS_DDR_awready),
      .S_AXI_PS_awsize(M_AXI_PS_DDR_awsize),
      .S_AXI_PS_awuser(M_AXI_PS_DDR_awuser),
      .S_AXI_PS_awvalid(M_AXI_PS_DDR_awvalid),
      .S_AXI_PS_bid(M_AXI_PS_DDR_bid),
      .S_AXI_PS_bready(M_AXI_PS_DDR_bready),
      .S_AXI_PS_bresp(M_AXI_PS_DDR_bresp),
      .S_AXI_PS_bvalid(M_AXI_PS_DDR_bvalid),
      .S_AXI_PS_rdata(M_AXI_PS_DDR_rdata),
      .S_AXI_PS_rid(M_AXI_PS_DDR_rid),
      .S_AXI_PS_rlast(M_AXI_PS_DDR_rlast),
      .S_AXI_PS_rready(M_AXI_PS_DDR_rready),
      .S_AXI_PS_rresp(M_AXI_PS_DDR_rresp),
      .S_AXI_PS_rvalid(M_AXI_PS_DDR_rvalid),
      .S_AXI_PS_wdata(M_AXI_PS_DDR_wdata),
      .S_AXI_PS_wlast(M_AXI_PS_DDR_wlast),
      .S_AXI_PS_wready(M_AXI_PS_DDR_wready),
      .S_AXI_PS_wstrb(M_AXI_PS_DDR_wstrb),
      .S_AXI_PS_wvalid(M_AXI_PS_DDR_wvalid),

      .S_AXI_DM_araddr(M_AXI_DM_araddr),
      .S_AXI_DM_arburst(M_AXI_DM_arburst),
      .S_AXI_DM_arcache(4'b0011),
      .S_AXI_DM_arlen(M_AXI_DM_arlen),
      .S_AXI_DM_arlock(1'b0),
      .S_AXI_DM_arprot(3'b000),
      .S_AXI_DM_arqos(4'b0000),
      .S_AXI_DM_arready(M_AXI_DM_arready),
      .S_AXI_DM_arsize(M_AXI_DM_arsize),
      .S_AXI_DM_arvalid(M_AXI_DM_arvalid),
      .S_AXI_DM_rdata(M_AXI_DM_rdata),
      .S_AXI_DM_rlast(M_AXI_DM_rlast),
      .S_AXI_DM_rready(M_AXI_DM_rready),
      .S_AXI_DM_rresp(M_AXI_DM_rresp),
      .S_AXI_DM_rvalid(M_AXI_DM_rvalid),
      .S_AXI_WAVE_awaddr(M_AXI_WAVE_awaddr),
      .S_AXI_WAVE_awburst(M_AXI_WAVE_awburst),
      .S_AXI_WAVE_awcache(M_AXI_WAVE_awcache),
      .S_AXI_WAVE_awlen(M_AXI_WAVE_awlen),
      .S_AXI_WAVE_awlock(M_AXI_WAVE_awlock),
      .S_AXI_WAVE_awprot(M_AXI_WAVE_awprot),
      .S_AXI_WAVE_awqos(M_AXI_WAVE_awqos),
      .S_AXI_WAVE_awready(M_AXI_WAVE_awready),
      .S_AXI_WAVE_awsize(M_AXI_WAVE_awsize),
      .S_AXI_WAVE_awvalid(M_AXI_WAVE_awvalid),
      .S_AXI_WAVE_wdata(M_AXI_WAVE_wdata),
      .S_AXI_WAVE_wlast(M_AXI_WAVE_wlast),
      .S_AXI_WAVE_wready(M_AXI_WAVE_wready),
      .S_AXI_WAVE_wstrb(M_AXI_WAVE_wstrb),
      .S_AXI_WAVE_wvalid(M_AXI_WAVE_wvalid),
      .S_AXI_WAVE_bready(M_AXI_WAVE_bready),
      .S_AXI_WAVE_bresp(M_AXI_WAVE_bresp),
      .S_AXI_WAVE_bvalid(M_AXI_WAVE_bvalid),

      .S_AXI_BULK_awaddr(M_AXI_BULK_awaddr),
      .S_AXI_BULK_awburst(2'b01),
      .S_AXI_BULK_awcache(4'b0011),
      .S_AXI_BULK_awlen(M_AXI_BULK_awlen),
      .S_AXI_BULK_awlock(1'b0),
      .S_AXI_BULK_awprot(3'b000),
      .S_AXI_BULK_awqos(4'd0),
      .S_AXI_BULK_awready(M_AXI_BULK_awready),
      .S_AXI_BULK_awsize(3'b110),
      .S_AXI_BULK_awvalid(M_AXI_BULK_awvalid),
      .S_AXI_BULK_wdata(M_AXI_BULK_wdata),
      .S_AXI_BULK_wlast(M_AXI_BULK_wlast),
      .S_AXI_BULK_wready(M_AXI_BULK_wready),
      .S_AXI_BULK_wstrb(M_AXI_BULK_wstrb),
      .S_AXI_BULK_wvalid(M_AXI_BULK_wvalid),
      .S_AXI_BULK_bready(M_AXI_BULK_bready),
      .S_AXI_BULK_bresp(M_AXI_BULK_bresp),
      .S_AXI_BULK_bvalid(M_AXI_BULK_bvalid),

      .M_AXI_DDR_araddr(M_AXI_DDR4_araddr),
      .M_AXI_DDR_arburst(M_AXI_DDR4_arburst),
      .M_AXI_DDR_arcache(M_AXI_DDR4_arcache),
      .M_AXI_DDR_arlen(M_AXI_DDR4_arlen),
      .M_AXI_DDR_arlock(M_AXI_DDR4_arlock),
      .M_AXI_DDR_arprot(M_AXI_DDR4_arprot),
      .M_AXI_DDR_arqos(M_AXI_DDR4_arqos),
      .M_AXI_DDR_arready(M_AXI_DDR4_arready),
      .M_AXI_DDR_arsize(M_AXI_DDR4_arsize),
      .M_AXI_DDR_arvalid(M_AXI_DDR4_arvalid),
      .M_AXI_DDR_awaddr(M_AXI_DDR4_awaddr),
      .M_AXI_DDR_awburst(M_AXI_DDR4_awburst),
      .M_AXI_DDR_awcache(M_AXI_DDR4_awcache),
      .M_AXI_DDR_awlen(M_AXI_DDR4_awlen),
      .M_AXI_DDR_awlock(M_AXI_DDR4_awlock),
      .M_AXI_DDR_awprot(M_AXI_DDR4_awprot),
      .M_AXI_DDR_awqos(M_AXI_DDR4_awqos),
      .M_AXI_DDR_awready(M_AXI_DDR4_awready),
      .M_AXI_DDR_awsize(M_AXI_DDR4_awsize),
      .M_AXI_DDR_awvalid(M_AXI_DDR4_awvalid),
      .M_AXI_DDR_bready(M_AXI_DDR4_bready),
      .M_AXI_DDR_bresp(M_AXI_DDR4_bresp),
      .M_AXI_DDR_bvalid(M_AXI_DDR4_bvalid),
      .M_AXI_DDR_rdata(M_AXI_DDR4_rdata),
      .M_AXI_DDR_rlast(M_AXI_DDR4_rlast),
      .M_AXI_DDR_rready(M_AXI_DDR4_rready),
      .M_AXI_DDR_rresp(M_AXI_DDR4_rresp),
      .M_AXI_DDR_rvalid(M_AXI_DDR4_rvalid),
      .M_AXI_DDR_wdata(M_AXI_DDR4_wdata),
      .M_AXI_DDR_wlast(M_AXI_DDR4_wlast),
      .M_AXI_DDR_wready(M_AXI_DDR4_wready),
      .M_AXI_DDR_wstrb(M_AXI_DDR4_wstrb),
      .M_AXI_DDR_wvalid(M_AXI_DDR4_wvalid)
  );

  Ddr4CustomXczu47dr ddr4_custom_i (
      .sys_rst(~pl_resetn0),
      .c0_sys_clk_p(c0_sys_clk_p),
      .c0_sys_clk_n(c0_sys_clk_n),
      .c0_ddr4_act_n(c0_ddr4_act_n),
      .c0_ddr4_adr(c0_ddr4_adr),
      .c0_ddr4_ba(c0_ddr4_ba),
      .c0_ddr4_bg(c0_ddr4_bg),
      .c0_ddr4_cke(c0_ddr4_cke),
      .c0_ddr4_odt(c0_ddr4_odt),
      .c0_ddr4_cs_n(c0_ddr4_cs_n),
      .c0_ddr4_ck_t(c0_ddr4_ck_t),
      .c0_ddr4_ck_c(c0_ddr4_ck_c),
      .c0_ddr4_reset_n(c0_ddr4_reset_n),
      .c0_ddr4_dm_n(c0_ddr4_dm_n),
      .c0_ddr4_dq(c0_ddr4_dq),
      .c0_ddr4_dqs_c(c0_ddr4_dqs_c),
      .c0_ddr4_dqs_t(c0_ddr4_dqs_t),
      .c0_init_calib_complete(),
      .c0_ddr4_ui_clk(ddr4_ui_clk),
      .c0_ddr4_ui_clk_sync_rst(ddr4_ui_clk_sync_rst),
      .c0_ddr4_aresetn(ddr4_ui_aresetn),
      .s_axi_awaddr(M_AXI_DDR4_awaddr),
      .s_axi_awlen(M_AXI_DDR4_awlen),
      .s_axi_awsize(M_AXI_DDR4_awsize),
      .s_axi_awburst(M_AXI_DDR4_awburst),
      .s_axi_awlock(M_AXI_DDR4_awlock),
      .s_axi_awcache(M_AXI_DDR4_awcache),
      .s_axi_awprot(M_AXI_DDR4_awprot),
      .s_axi_awqos(M_AXI_DDR4_awqos),
      .s_axi_awvalid(M_AXI_DDR4_awvalid),
      .s_axi_awready(M_AXI_DDR4_awready),
      .s_axi_wdata(M_AXI_DDR4_wdata),
      .s_axi_wstrb(M_AXI_DDR4_wstrb),
      .s_axi_wlast(M_AXI_DDR4_wlast),
      .s_axi_wvalid(M_AXI_DDR4_wvalid),
      .s_axi_wready(M_AXI_DDR4_wready),
      .s_axi_bready(M_AXI_DDR4_bready),
      .s_axi_bresp(M_AXI_DDR4_bresp),
      .s_axi_bvalid(M_AXI_DDR4_bvalid),
      .s_axi_araddr(M_AXI_DDR4_araddr),
      .s_axi_arlen(M_AXI_DDR4_arlen),
      .s_axi_arsize(M_AXI_DDR4_arsize),
      .s_axi_arburst(M_AXI_DDR4_arburst),
      .s_axi_arlock(M_AXI_DDR4_arlock),
      .s_axi_arcache(M_AXI_DDR4_arcache),
      .s_axi_arprot(M_AXI_DDR4_arprot),
      .s_axi_arqos(M_AXI_DDR4_arqos),
      .s_axi_arvalid(M_AXI_DDR4_arvalid),
      .s_axi_arready(M_AXI_DDR4_arready),
      .s_axi_rready(M_AXI_DDR4_rready),
      .s_axi_rdata(M_AXI_DDR4_rdata),
      .s_axi_rresp(M_AXI_DDR4_rresp),
      .s_axi_rlast(M_AXI_DDR4_rlast),
      .s_axi_rvalid(M_AXI_DDR4_rvalid)
  );

  RfdcCustomXczu47dr rfdc_custom_i (
      .s_axi_aclk(pl_clk),
      .s_axi_aresetn(pl_aresetn),
      .s_axi_awaddr(RFDC_S_AXI_awaddr),
      .s_axi_awvalid(RFDC_S_AXI_awvalid),
      .s_axi_awready(RFDC_S_AXI_awready),
      .s_axi_wdata(RFDC_S_AXI_wdata),
      .s_axi_wstrb(RFDC_S_AXI_wstrb),
      .s_axi_wvalid(RFDC_S_AXI_wvalid),
      .s_axi_wready(RFDC_S_AXI_wready),
      .s_axi_bresp(RFDC_S_AXI_bresp),
      .s_axi_bvalid(RFDC_S_AXI_bvalid),
      .s_axi_bready(RFDC_S_AXI_bready),
      .s_axi_araddr(RFDC_S_AXI_araddr),
      .s_axi_arvalid(RFDC_S_AXI_arvalid),
      .s_axi_arready(RFDC_S_AXI_arready),
      .s_axi_rdata(RFDC_S_AXI_rdata),
      .s_axi_rresp(RFDC_S_AXI_rresp),
      .s_axi_rvalid(RFDC_S_AXI_rvalid),
      .s_axi_rready(RFDC_S_AXI_rready),
      .sysref_in_p(sysref_in_diff_p),
      .sysref_in_n(sysref_in_diff_n),
      .user_sysref_dac(pl_sysref_dac),
      .dac2_clk_p(dac2_clk_clk_p),
      .dac2_clk_n(dac2_clk_clk_n),
      .clk_dac0(),
      .s0_axis_aclk(dac_axis_clk),
      .s0_axis_aresetn(clk104_aresetn),
      .clk_dac1(),
      .s1_axis_aclk(dac_axis_clk),
      .s1_axis_aresetn(clk104_aresetn),
      .clk_dac2(clk_dac2),
      .s2_axis_aclk(dac_axis_clk),
      .s2_axis_aresetn(clk104_aresetn),
      .clk_dac3(),
      .s3_axis_aclk(dac_axis_clk),
      .s3_axis_aresetn(clk104_aresetn),
      .dac00_nco_freq(rfdc_dac_nco_freq[0 +: 48]),
      .dac00_nco_phase(rfdc_dac_nco_phase[0 +: 18]),
      .dac00_nco_phase_rst(rfdc_dac_nco_phase_reset[0]),
      .dac00_nco_update_en(rfdc_dac_nco_update_enable[0 +: 6]),
      .dac02_nco_freq(rfdc_dac_nco_freq[48 +: 48]),
      .dac02_nco_phase(rfdc_dac_nco_phase[18 +: 18]),
      .dac02_nco_phase_rst(rfdc_dac_nco_phase_reset[1]),
      .dac02_nco_update_en(rfdc_dac_nco_update_enable[6 +: 6]),
      .dac0_nco_update_req(rfdc_dac_tile_update_req[0]),
      .dac0_nco_update_busy(rfdc_dac0_nco_update_busy),
      .dac0_sysref_int_gating(rfdc_dac0_sysref_int_gating),
      .dac0_sysref_int_reenable(rfdc_dac0_sysref_int_reenable),
      .dac10_nco_freq(rfdc_dac_nco_freq[96 +: 48]),
      .dac10_nco_phase(rfdc_dac_nco_phase[36 +: 18]),
      .dac10_nco_phase_rst(rfdc_dac_nco_phase_reset[2]),
      .dac10_nco_update_en(rfdc_dac_nco_update_enable[12 +: 6]),
      .dac12_nco_freq(rfdc_dac_nco_freq[144 +: 48]),
      .dac12_nco_phase(rfdc_dac_nco_phase[54 +: 18]),
      .dac12_nco_phase_rst(rfdc_dac_nco_phase_reset[3]),
      .dac12_nco_update_en(rfdc_dac_nco_update_enable[18 +: 6]),
      .dac1_nco_update_req(rfdc_dac_tile_update_req[1]),
      .dac1_nco_update_busy(rfdc_dac1_nco_update_busy),
      .dac20_nco_freq(rfdc_dac_nco_freq[192 +: 48]),
      .dac20_nco_phase(rfdc_dac_nco_phase[72 +: 18]),
      .dac20_nco_phase_rst(rfdc_dac_nco_phase_reset[4]),
      .dac20_nco_update_en(rfdc_dac_nco_update_enable[24 +: 6]),
      .dac22_nco_freq(rfdc_dac_nco_freq[240 +: 48]),
      .dac22_nco_phase(rfdc_dac_nco_phase[90 +: 18]),
      .dac22_nco_phase_rst(rfdc_dac_nco_phase_reset[5]),
      .dac22_nco_update_en(rfdc_dac_nco_update_enable[30 +: 6]),
      .dac2_nco_update_req(rfdc_dac_tile_update_req[2]),
      .dac2_nco_update_busy(rfdc_dac2_nco_update_busy),
      .dac30_nco_freq(rfdc_dac_nco_freq[288 +: 48]),
      .dac30_nco_phase(rfdc_dac_nco_phase[108 +: 18]),
      .dac30_nco_phase_rst(rfdc_dac_nco_phase_reset[6]),
      .dac30_nco_update_en(rfdc_dac_nco_update_enable[36 +: 6]),
      .dac32_nco_freq(rfdc_dac_nco_freq[336 +: 48]),
      .dac32_nco_phase(rfdc_dac_nco_phase[126 +: 18]),
      .dac32_nco_phase_rst(rfdc_dac_nco_phase_reset[7]),
      .dac32_nco_update_en(rfdc_dac_nco_update_enable[42 +: 6]),
      .dac3_nco_update_req(rfdc_dac_tile_update_req[3]),
      .dac3_nco_update_busy(rfdc_dac3_nco_update_busy),
      .vout00_p(vout00_v_p),
      .vout00_n(vout00_v_n),
      .vout02_p(vout02_v_p),
      .vout02_n(vout02_v_n),
      .vout10_p(vout10_v_p),
      .vout10_n(vout10_v_n),
      .vout12_p(vout12_v_p),
      .vout12_n(vout12_v_n),
      .vout20_p(vout20_v_p),
      .vout20_n(vout20_v_n),
      .vout22_p(vout22_v_p),
      .vout22_n(vout22_v_n),
      .vout30_p(vout30_v_p),
      .vout30_n(vout30_v_n),
      .vout32_p(vout32_v_p),
      .vout32_n(vout32_v_n),
      .s00_axis_tdata(rfdc_ch1_tdata),
      .s00_axis_tvalid(rfdc_ch1_tvalid),
      .s00_axis_tready(dac_ch1_ready),
      .s02_axis_tdata(rfdc_ch2_tdata),
      .s02_axis_tvalid(rfdc_ch2_tvalid),
      .s02_axis_tready(dac_ch2_ready),
      .s10_axis_tdata(rfdc_ch3_tdata),
      .s10_axis_tvalid(rfdc_ch3_tvalid),
      .s10_axis_tready(dac_ch3_ready),
      .s12_axis_tdata(rfdc_ch4_tdata),
      .s12_axis_tvalid(rfdc_ch4_tvalid),
      .s12_axis_tready(dac_ch4_ready),
      .s20_axis_tdata(rfdc_ch5_tdata),
      .s20_axis_tvalid(rfdc_ch5_tvalid),
      .s20_axis_tready(dac_ch5_ready),
      .s22_axis_tdata(rfdc_ch6_tdata),
      .s22_axis_tvalid(rfdc_ch6_tvalid),
      .s22_axis_tready(dac_ch6_ready),
      .s30_axis_tdata(rfdc_ch7_tdata),
      .s30_axis_tvalid(rfdc_ch7_tvalid),
      .s30_axis_tready(dac_ch7_ready),
      .s32_axis_tdata(rfdc_ch8_tdata),
      .s32_axis_tvalid(rfdc_ch8_tvalid),
      .s32_axis_tready(dac_ch8_ready),
      .irq()
  );

  // Firmware status word (DAC MTS / NCO sync results) into the PL; the
  // firmware reads the HMC7044 configuration-done flag back in bit 31.
  firmware_status_reg firmware_status_reg_i (
      .s_axi_aclk   (pl_clk),
      .s_axi_aresetn(pl_aresetn),
      .s_axi_awaddr (M_AXI_GPIO_awaddr[8:0]),
      .s_axi_awvalid(M_AXI_GPIO_awvalid),
      .s_axi_awready(M_AXI_GPIO_awready),
      .s_axi_wdata  (M_AXI_GPIO_wdata),
      .s_axi_wstrb  (M_AXI_GPIO_wstrb),
      .s_axi_wvalid (M_AXI_GPIO_wvalid),
      .s_axi_wready (M_AXI_GPIO_wready),
      .s_axi_bresp  (M_AXI_GPIO_bresp),
      .s_axi_bvalid (M_AXI_GPIO_bvalid),
      .s_axi_bready (M_AXI_GPIO_bready),
      .s_axi_araddr (M_AXI_GPIO_araddr[8:0]),
      .s_axi_arvalid(M_AXI_GPIO_arvalid),
      .s_axi_arready(M_AXI_GPIO_arready),
      .s_axi_rdata  (M_AXI_GPIO_rdata),
      .s_axi_rresp  (M_AXI_GPIO_rresp),
      .s_axi_rvalid (M_AXI_GPIO_rvalid),
      .s_axi_rready (M_AXI_GPIO_rready),
      .hmc_done     (hmc7044_set_finish),
      .hmc_gpio1    (hmc7044_gpio1_sync[1]),
      .hmc_rb_sweeps(hmc7044_rb_sweeps),
      .hmc_rb_index (hmc7044_rb_index),
      .hmc_rb_word  (hmc7044_rb_word),
      .status       (firmware_status_word)
  );

endmodule
