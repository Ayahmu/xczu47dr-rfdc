module Top #(
    parameter integer IS_MASTER = 1
) (

    // HMC7044 clock chip control (SPI interface)
    output RESET_H7044_H_0,
    output H7044_SYNC_0,
    output H7044_SLEN_0,
    output H7044_SCLK_0,
    output H7044_SDATA_0,

    // PL_CLK and PL_SYSREF from HMC7044 (differential LVDS, 100 MHz)
    input  PL_CLK_P_0,
    input  PL_CLK_N_0,
    input  PL_SYSREF_P_0,
    input  PL_SYSREF_N_0,

    // HMC7044 10MHz output returned to the FPGA (differential).
    input  mclk_10m_p,
    input  mclk_10m_n,

    // X3 differential external-sync output after the on-board NB6N11 buffer.
    input  EXT_TRIGGER_P,
    input  EXT_TRIGGER_N,

    // 10G SFP+ UDP link, matching the reference project.
    input  sfp_refclkp,
    input  sfp_refclkn,
    input  sfp_rxp,
    input  sfp_rxn,
    output sfp_txp,
    output sfp_txn,
    output SFP_TX_DIS,

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
    inout  TRIG_3,

    // Legacy Type-C synchronization is deliberately not part of this board
    // interface. XS20/TRIG_3 is the sole external SYNC connection.
    input  dac_trigger_start,

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
  wire        clk_dac0;
  wire        clk_dac1;
  wire        clk_dac2;
  wire        clk_dac3;
  wire        dac_axis_clk;
  wire        rfdc_irq;
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
  // Temporary XS17 profile: a 10 MHz reference drives CLKIN1. HMC7044 R1=1
  // creates a 10 MHz PLL1 PFD; only the SYNC/trigger roles differ.
  wire        hmc_use_external_xs17 = 1'b1;

  hmc7044 hmc7044_i (
      .clk(pl_clk),
      .rst(pl_aresetn),
      .H7044_SLEN(H7044_SLEN_0),
      .H7044_SCLK(H7044_SCLK_0),
      .H7044_SDATA(H7044_SDATA_0),
      .SET_FINISH(hmc7044_set_finish),
      .USE_EXTERNAL_XS17(hmc_use_external_xs17),
      .IS_MASTER(IS_MASTER ? 1'b1 : 1'b0)
  );

  assign RESET_H7044_H_0 = 1'b0;

  wire vio_sync_request;
  wire sync_xs20_in;
  wire sync_xs20_out;
  wire sync_xs20_oe;
  wire trigger_xs18_out;
  wire trigger_link_out;
  wire sync_hmc;
  wire sync_link_out;
  wire sync_link_ready;
  wire role_trigger_raw;
  wire sync_done_pl;
  wire sync_seen;
  wire trigger_in_seen;
  wire trigger_accepted;
  wire trigger_output_active;
  wire [31:0] trigger_input_count;
  wire [31:0] trigger_accepted_count;
  wire [31:0] trigger_output_count;
  wire [31:0] gpio_out_reg;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [31:0] firmware_status_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [31:0] firmware_status_ddr;
  wire [5:0] sync_event_epoch;
  wire sync_align_busy;
  wire sync_align_failed;
  wire [5:0] sync_alignment_epoch;
  wire rfctrl2_sync_epoch_pulse;
  wire rfctrl2_trigger_pulse;
  wire rfctrl2_set_sync_role_pulse;
  wire [31:0] rfctrl2_sync_mode;
  wire rfctrl2_emit_trigger_pulse;
  wire sync_role_master_ddr = IS_MASTER ? 1'b1 : 1'b0;
  reg sync_bypass_ddr;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] sync_bypass_pl_sync;
  wire sync_role_master_pl = IS_MASTER ? 1'b1 : 1'b0;
  wire sync_bypass_pl = sync_bypass_pl_sync[1];
  wire [5:0] firmware_ack_epoch_pl = gpio_out_reg[30:25];
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] firmware_align_failed_pl_sync;
  wire firmware_align_failed_pl = firmware_align_failed_pl_sync[1];

  always @(posedge pl_clk or negedge pl_aresetn) begin
    if (!pl_aresetn)
      firmware_align_failed_pl_sync <= 2'b00;
    else
      firmware_align_failed_pl_sync <= {firmware_align_failed_pl_sync[0], firmware_status_ddr[3]};
  end

  IOBUF sync_xs20_iobuf (
      .I  (sync_xs20_out),
      .T  (~sync_xs20_oe),
      .O  (sync_xs20_in),
      .IO (TRIG_3)
  );
  assign trigger_xs18_out = trigger_link_out;
  assign TRIG_1 = trigger_xs18_out;

  // VIO is generated only for the master project. It is a local debug source;
  // physical synchronization is carried only by the XS20 IOBUF.
`ifdef CUSTOM_XCZU47DR_MASTER
  vio_0 vio_sync_i (
      .clk       (pl_clk),
      .probe_out0(vio_sync_request)
  );
`else
  assign vio_sync_request = 1'b0;
`endif

  sync_trigger_link #(
      .IS_MASTER(IS_MASTER),
      .WAIT_CYCLES(100000),
      .HIGH_CYCLES(100)
  ) sync_trigger_link_i (
      .ddr_clk             (ddr4_ui_clk),
      .ddr_rst_n           (ddr4_ui_aresetn),
      .pl_clk              (pl_clk),
      .pl_rst_n            (pl_aresetn),
      .sync_request_ddr   (rfctrl2_sync_epoch_pulse),
      .trigger_request_ddr(rfctrl2_emit_trigger_pulse |
                           rfctrl2_master_launch_pulse),
      .sync_request_vio_pl(vio_sync_request),
      .sync_in            (sync_xs20_in),
      .trigger_in         (TRIG_2),
      .dac_trigger_start  (dac_trigger_start),
      .role_master        (sync_role_master_pl),
      .sync_bypass       (sync_bypass_pl),
      .firmware_ack_epoch (firmware_ack_epoch_pl),
      .firmware_align_failed(firmware_align_failed_pl),
      .hmc_sync           (sync_hmc),
      .sync_link_out      (sync_link_out),
      .trigger_link_out   (trigger_link_out),
      .role_trigger_raw   (role_trigger_raw),
      .sync_done          (sync_done_pl),
      .sync_seen          (sync_seen),
      .sync_link_ready    (sync_link_ready),
      .sync_event_epoch   (sync_event_epoch),
      .sync_align_busy    (sync_align_busy),
      .sync_align_failed  (sync_align_failed),
      .sync_alignment_epoch(sync_alignment_epoch),
      .trigger_in_seen    (trigger_in_seen),
      .trigger_accepted   (trigger_accepted),
      .trigger_output_active(trigger_output_active),
      .trigger_input_count(trigger_input_count),
      .trigger_accepted_count(trigger_accepted_count),
      .trigger_output_count(trigger_output_count)
  );

  assign sync_xs20_out = sync_link_out;
  assign sync_xs20_oe = sync_role_master_pl;

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] hmc_done_ddr_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] sync_seen_ddr_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] sync_ready_ddr_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] sync_align_busy_ddr_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] sync_align_failed_ddr_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [5:0] sync_alignment_epoch_ddr_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [5:0] sync_alignment_epoch_ddr;
  reg [31:0] trigger_input_count_ddr_meta;
  reg [31:0] trigger_input_count_ddr;
  reg [31:0] trigger_accepted_count_ddr_meta;
  reg [31:0] trigger_accepted_count_ddr;
  reg [31:0] trigger_output_count_ddr_meta;
  reg [31:0] trigger_output_count_ddr;
  wire hmc_done_ddr = hmc_done_ddr_sync[1];
  wire sync_seen_ddr = sync_seen_ddr_sync[1];
  wire sync_link_ready_ddr = sync_ready_ddr_sync[1];
  wire sync_align_busy_ddr = sync_align_busy_ddr_sync[1];
  wire sync_align_failed_ddr = sync_align_failed_ddr_sync[1];
  // One RFCTRL2 TRIGGER is the master launch event: it starts the local
  // player and, in the same DDR clock domain, requests the XS18 pulse.
  // EMIT_TRIGGER remains a separate diagnostic-only physical trigger.
  wire rfctrl2_master_launch_pulse = rfctrl2_trigger_pulse &&
                                     sync_link_ready_ddr &&
                                     sync_role_master_ddr;

  assign H7044_SYNC_0 = sync_hmc;

  // ========== PS 指令 AXIS（128-bit） ==========
  wire [127:0] ps_instr_tdata;
  wire         ps_instr_tvalid;
  wire         ps_instr_tready;
  wire [127:0] udp_instr_tdata;
  wire         udp_instr_tvalid;
  wire         udp_instr_tready;
  wire [127:0] rv_instr_tdata;
  wire         rv_instr_tvalid;
  wire         rv_instr_tready;
  wire [127:0] instr_tdata;
  wire         instr_tvalid;
  wire         instr_tready;

  assign instr_tdata      = udp_instr_tvalid ? udp_instr_tdata : (rv_instr_tvalid ? rv_instr_tdata : ps_instr_tdata);
  assign instr_tvalid     = udp_instr_tvalid | rv_instr_tvalid | ps_instr_tvalid;
  assign udp_instr_tready = udp_instr_tvalid && instr_tready;
  assign rv_instr_tready  = !udp_instr_tvalid && rv_instr_tvalid && instr_tready;
  assign ps_instr_tready  = !udp_instr_tvalid && !rv_instr_tvalid && instr_tready;

  localparam [63:0] EXT_DDR_ADDR_BASE = 64'h0000_0048_0000_0000;

  // ========== Reference 10G UDP receiver ==========
  wire        udp64_rcv_vld;
  wire [63:0] udp64_rcv_dat;
  wire        udp64_rcv_last;
  wire        udp64_fifo_af;
  wire        udp_instr64_tvalid;
  wire [63:0] udp_instr64_tdata;
  wire        rvctrl64_tvalid;
  wire [63:0] rvctrl64_tdata;
  wire        rvctrl64_tfirst;
  wire        rvctrl64_tlast;
  wire [31:0] rvctrl64_word_count;
  wire [1:0]  rvctrl64_protocol;
  wire        rvresp64_tvalid;
  wire [63:0] rvresp64_tdata;
  wire        rvresp64_tready;
  wire        rvresp64_tlast;
  wire [15:0] rvresp64_word_count;
  wire [7:0]  udp_control_tx_debug;

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

  wire         udp_wave_pkt;
  wire         udp_instr_word;
  wire         udp_trigger_pulse;
  wire         rv_trigger_pulse;
  wire         rfctrl2_arm_pulse;
  wire         rfctrl2_abort_mute_pulse;
  wire [63:0]  rfctrl2_epoch;
  wire         rfctrl2_start_valid;
  wire [63:0]  rfctrl2_start_tick;
  wire         rfctrl2_armed_dac;
  wire         rfctrl2_prepared_dac;
  wire         rfctrl2_start_pending_dac;
  wire         pc_started;
  reg          rfctrl2_armed_meta;
  reg          rfctrl2_armed_ddr;
  reg          rfctrl2_prepared_meta;
  reg          rfctrl2_prepared_ddr;
  reg          rfctrl2_pending_meta;
  reg          rfctrl2_pending_ddr;
  reg          pc_started_meta;
  reg          pc_started_ddr;

  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn) begin
      sync_bypass_ddr <= 1'b0;
    end else if (rfctrl2_set_sync_role_pulse) begin
      sync_bypass_ddr <= (rfctrl2_sync_mode == 32'd1);
    end
  end

  always @(posedge pl_clk or negedge pl_aresetn) begin
    if (!pl_aresetn) begin
      sync_bypass_pl_sync <= 2'b00;
    end else begin
      sync_bypass_pl_sync <= {sync_bypass_pl_sync[0], sync_bypass_ddr};
    end
  end
  wire         control_trigger_pulse;
  wire [31:0]  rv_dbg_status;
  wire [31:0]  rv_dbg_last_seq;
  wire [31:0]  rv_dbg_last_cmd;
  wire [31:0]  rv_dbg_ping_count;
  wire [31:0]  rv_dbg_play_count;
  wire [31:0]  rv_dbg_trigger_count;
  wire [31:0]  rv_dbg_mmio_write_count;
  wire [31:0]  rv_dbg_error_count;
  wire [31:0]  rv_dbg_scratch;
  wire [3:0]   rv_dbg_state;
  wire [3:0]   udp_wave_state;
  wire [17:0]  RV_CTRL_AXI_awaddr;
  wire         RV_CTRL_AXI_awvalid;
  wire         RV_CTRL_AXI_awready;
  wire [31:0]  RV_CTRL_AXI_wdata;
  wire [3:0]   RV_CTRL_AXI_wstrb;
  wire         RV_CTRL_AXI_wvalid;
  wire         RV_CTRL_AXI_wready;
  wire [1:0]   RV_CTRL_AXI_bresp;
  wire         RV_CTRL_AXI_bvalid;
  wire         RV_CTRL_AXI_bready;
  wire [17:0]  RV_CTRL_AXI_araddr;
  wire         RV_CTRL_AXI_arvalid;
  wire         RV_CTRL_AXI_arready;
  wire [31:0]  RV_CTRL_AXI_rdata;
  wire [1:0]   RV_CTRL_AXI_rresp;
  wire         RV_CTRL_AXI_rvalid;
  wire         RV_CTRL_AXI_rready;
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
  wire         rfdc_force_mute_pulse;
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
  wire [17:0]  PL_CTRL_AXI_awaddr;
  wire         PL_CTRL_AXI_awvalid;
  wire         PL_CTRL_AXI_awready;
  wire [31:0]  PL_CTRL_AXI_wdata;
  wire [3:0]   PL_CTRL_AXI_wstrb;
  wire         PL_CTRL_AXI_wvalid;
  wire         PL_CTRL_AXI_wready;
  wire [1:0]   PL_CTRL_AXI_bresp;
  wire         PL_CTRL_AXI_bvalid;
  wire         PL_CTRL_AXI_bready;
  wire [17:0]  PL_CTRL_AXI_araddr;
  wire         PL_CTRL_AXI_arvalid;
  wire         PL_CTRL_AXI_arready;
  wire [31:0]  PL_CTRL_AXI_rdata;
  wire [1:0]   PL_CTRL_AXI_rresp;
  wire         PL_CTRL_AXI_rvalid;
  wire         PL_CTRL_AXI_rready;
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
  wire [31:0]  udp_wave_write_count;
  wire [31:0]  udp_wave_bresp_count;
  wire [31:0]  udp_wave_drop_count;
  wire [31:0]  udp_wave_align_error_count;
  wire [15:0]  udp_wave_fifo_count;
  wire [31:0]  udp_wave_resync_count;
  wire [1:0]   udp_wave_last_bresp;
  wire [63:0]  udp_wave_last_addr;
  wire [255:0] udp_wave_last_wdata;

  assign SFP_TX_DIS = 1'b0;

  assign network_bootstrap_ip = 32'hC0A8FEFE;
  assign network_capabilities = 32'h00040000;
  localparam [31:0] RF2_BUILD_PROFILE_ID = 32'd1;
  assign network_status_flags = {
      25'd0,
      sync_seen_ddr,
      hmc_done_ddr,
      rfctrl2_prepared_ddr,
      pc_started_ddr,
      (rfctrl2_armed_ddr | rfctrl2_pending_ddr),
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
      .playback_armed(rfctrl2_armed_ddr | rfctrl2_pending_ddr),
      .playback_prepared(rfctrl2_prepared_ddr),
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

  udp_10G udp_10g_i (
      .gt_rxp_in   (sfp_rxp),
      .gt_rxn_in   (sfp_rxn),
      .gt_txp_out  (sfp_txp),
      .gt_txn_out  (sfp_txn),
      .gt_refclk_p (sfp_refclkp),
      .gt_refclk_n (sfp_refclkn),
      .clk_100Mhz  (pl_clk),
      .clk         (ddr4_ui_clk),
      .rst         (~ddr4_ui_aresetn),
      .network_local_mac(udp_network_mac),
      .network_local_ip(udp_network_ip),
      .network_gateway_ip(udp_network_gateway),
      .network_subnet_mask(udp_network_subnet),
      .network_udp_port(udp_network_port),
      .network_clear_arp_cache(network_clear_arp_cache | network_restart_pulse),
      .network_restart_pulse(network_restart_pulse),
      .fifo64_wr   (1'b0),
      .fifo64_din  (64'd0),
      .fifo64_af   (udp64_fifo_af),
      .resp64_tvalid(rvresp64_tvalid),
      .resp64_tdata (rvresp64_tdata),
      .resp64_tlast (rvresp64_tlast),
      .resp64_word_count(rvresp64_word_count),
      .resp64_tready(rvresp64_tready),
      .control_tx_debug(udp_control_tx_debug),
      .rcv_vld     (udp64_rcv_vld),
      .rcv_dat     (udp64_rcv_dat),
      .rcv_last    (udp64_rcv_last),
      .gap_num_vio (24'd0),
      .loop_en     (1'b0)
  );

  // Keep the 300 MHz UDP parser local to its input registers. This preserves
  // one-word-per-cycle throughput while removing the long high-fanout path
  // from the 10G RX core directly into the packet state machine.
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

  udp_waveform_ddr_writer #(
      .DDR_ADDR_BASE(EXT_DDR_ADDR_BASE)
  ) udp_waveform_ddr_writer_i (
      .clk              (ddr4_ui_clk),
      .rst_n            (ddr4_ui_aresetn),
      .udp_tvalid       (udp_writer_tvalid),
      .udp_tdata        (udp_writer_tdata),
      .udp_tlast        (udp_writer_tlast),
      .instr_tvalid     (udp_instr64_tvalid),
      .instr_tdata      (udp_instr64_tdata),
      .trigger_pulse    (udp_trigger_pulse),
      .rvctrl_tvalid    (rvctrl64_tvalid),
      .rvctrl_tdata     (rvctrl64_tdata),
      .rvctrl_tfirst    (rvctrl64_tfirst),
      .rvctrl_tlast     (rvctrl64_tlast),
      .rvctrl_word_count(rvctrl64_word_count),
      .rvctrl_protocol  (rvctrl64_protocol),
      .m_axi_awaddr     (M_AXI_WAVE_awaddr),
      .m_axi_awburst    (M_AXI_WAVE_awburst),
      .m_axi_awcache    (M_AXI_WAVE_awcache),
      .m_axi_awlen      (M_AXI_WAVE_awlen),
      .m_axi_awprot     (M_AXI_WAVE_awprot),
      .m_axi_awlock     (M_AXI_WAVE_awlock),
      .m_axi_awqos      (M_AXI_WAVE_awqos),
      .m_axi_awready    (M_AXI_WAVE_awready),
      .m_axi_awsize     (M_AXI_WAVE_awsize),
      .m_axi_awvalid    (M_AXI_WAVE_awvalid),
      .m_axi_wdata      (M_AXI_WAVE_wdata),
      .m_axi_wlast      (M_AXI_WAVE_wlast),
      .m_axi_wready     (M_AXI_WAVE_wready),
      .m_axi_wstrb      (M_AXI_WAVE_wstrb),
      .m_axi_wvalid     (M_AXI_WAVE_wvalid),
      .m_axi_bready     (M_AXI_WAVE_bready),
      .m_axi_bresp      (M_AXI_WAVE_bresp),
      .m_axi_bvalid     (M_AXI_WAVE_bvalid),
      .dbg_wave_pkt     (udp_wave_pkt),
      .dbg_instr_word   (udp_instr_word),
      .dbg_state        (udp_wave_state),
      .dbg_write_count  (udp_wave_write_count),
      .dbg_bresp_count  (udp_wave_bresp_count),
      .dbg_drop_count_o (udp_wave_drop_count),
      .dbg_align_error_count_o(udp_wave_align_error_count),
      .dbg_fifo_count_o (udp_wave_fifo_count),
      .dbg_resync_count (udp_wave_resync_count),
      .dbg_last_bresp   (udp_wave_last_bresp),
      .dbg_last_addr    (udp_wave_last_addr),
      .dbg_last_wdata   (udp_wave_last_wdata)
  );

  udp64_to_axis128_instr udp_instr_adapter_i (
      .clk           (ddr4_ui_clk),
      .rst_n         (ddr4_ui_aresetn),
      .udp_tvalid    (udp_instr64_tvalid),
      .udp_tdata     (udp_instr64_tdata),
      .m_axis_tdata  (udp_instr_tdata),
      .m_axis_tvalid (udp_instr_tvalid),
      .m_axis_tready (udp_instr_tready)
  );

  // Signals reported through RFCTRL2 STATUS must be declared before the
  // control module instance; otherwise Verilog implicit nets can hide widths.
  wire        ch1_arm, ch2_arm, ch3_arm, ch4_arm;
  wire        ch5_arm, ch6_arm, ch7_arm, ch8_arm;
  wire        dac_in_ch1_tvalid, dac_in_ch2_tvalid, dac_in_ch3_tvalid, dac_in_ch4_tvalid;
  wire        dac_in_ch5_tvalid, dac_in_ch6_tvalid, dac_in_ch7_tvalid, dac_in_ch8_tvalid;
  wire        ch1_wave_tready_internal, ch2_wave_tready_internal, ch3_wave_tready_internal, ch4_wave_tready_internal;
  wire        ch5_wave_tready_internal, ch6_wave_tready_internal, ch7_wave_tready_internal, ch8_wave_tready_internal;
  wire [2:0]  ex_dbg_st;
  wire [1:0]  ex_dbg_dm_st;
  wire        ex_dbg_dm_sel_ch1;
  wire [31:0] ex_dbg_dm_chunk_beats;
  wire [31:0] ex_dbg_dm_beats_sent;
  wire [63:0] ex_dbg_ch1_bytes_left;
  wire [63:0] ex_dbg_ch2_bytes_left;
  wire [63:0] ex_dbg_ch1_base_addr;
  wire [63:0] ex_dbg_ch2_base_addr;
  wire        ex_dbg_ch1_need_hard, ex_dbg_ch2_need_hard;
  wire        ex_dbg_ch1_need_soft, ex_dbg_ch2_need_soft;
  wire [127:0] ex_dbg_instr_in_tdata;
  wire        ex_dbg_instr_in_tvalid, ex_dbg_instr_in_tready;
  wire [127:0] ex_dbg_main_tdata;
  wire        ex_dbg_main_tvalid, ex_dbg_main_tready;
  wire        ex_dbg_prefill_ready, ex_dbg_pending_valid, ex_dbg_active_valid;
  wire [31:0] ex_dbg_run_delay_cnt;
  wire [31:0] ex_dbg_bad_instr_count;

  pl_riscv_control_v1 #(
      .ENABLE_UNSAFE_RFDC_MMIO(0),
      .BUILD_PROFILE_ID(RF2_BUILD_PROFILE_ID)
  ) pl_riscv_control_v1_i (
      .clk                 (ddr4_ui_clk),
      .rst_n               (ddr4_ui_aresetn),
      .rvctrl_tvalid       (rvctrl64_tvalid),
      .rvctrl_tdata        (rvctrl64_tdata),
      .rvctrl_tfirst       (rvctrl64_tfirst),
      .rvctrl_tlast        (rvctrl64_tlast),
      .rvctrl_word_count   (rvctrl64_word_count),
      .rvctrl_protocol     (rvctrl64_protocol),
      .m_instr_tdata       (rv_instr_tdata),
      .m_instr_tvalid      (rv_instr_tvalid),
      .m_instr_tready      (rv_instr_tready),
      .trigger_pulse       (rv_trigger_pulse),
      .rfctrl2_arm_pulse   (rfctrl2_arm_pulse),
      .rfctrl2_trigger_pulse(rfctrl2_trigger_pulse),
      .rfctrl2_abort_mute_pulse(rfctrl2_abort_mute_pulse),
      .rfctrl2_sync_epoch_pulse(rfctrl2_sync_epoch_pulse),
      .rfctrl2_epoch       (rfctrl2_epoch),
      .rfctrl2_set_sync_role_pulse(rfctrl2_set_sync_role_pulse),
      .rfctrl2_sync_role   (),
      .rfctrl2_sync_mode   (rfctrl2_sync_mode),
      .rfctrl2_emit_trigger_pulse(rfctrl2_emit_trigger_pulse),
      .rfctrl2_start_valid (rfctrl2_start_valid),
      .rfctrl2_start_tick  (rfctrl2_start_tick),
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
      .playback_armed      (rfctrl2_armed_ddr | rfctrl2_pending_ddr),
      .playback_prepared   (rfctrl2_prepared_ddr),
      .playback_running    (pc_started_ddr),
      .sync_role_master    (sync_role_master_ddr),
      .sync_bypass         (sync_bypass_ddr),
      .sync_seen           (sync_seen_ddr),
      .sync_link_ready     (sync_link_ready_ddr),
      .sync_align_busy     (sync_align_busy_ddr),
      .sync_align_failed   (sync_align_failed_ddr),
      .sync_alignment_epoch(sync_alignment_epoch_ddr),
      .sync_alignment_error(dac_mts_error),
      .trigger_input_count (trigger_input_count_ddr),
      .trigger_accepted_count(trigger_accepted_count_ddr),
      .trigger_output_count(trigger_output_count_ddr),
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
      .play_config_channel_mask({ch8_arm, ch7_arm, ch6_arm, ch5_arm, ch4_arm, ch3_arm, ch2_arm, ch1_arm}),
      .play_fifo_valid_mask({dac_in_ch8_tvalid, dac_in_ch7_tvalid, dac_in_ch6_tvalid, dac_in_ch5_tvalid,
                             dac_in_ch4_tvalid, dac_in_ch3_tvalid, dac_in_ch2_tvalid, dac_in_ch1_tvalid}),
      .play_fifo_ready_mask({ch8_wave_tready_internal, ch7_wave_tready_internal, ch6_wave_tready_internal, ch5_wave_tready_internal,
                             ch4_wave_tready_internal, ch3_wave_tready_internal, ch2_wave_tready_internal, ch1_wave_tready_internal}),
      .play_executor_state({5'd0, ex_dbg_st}),
      .play_ddr_read_counter(ex_dbg_dm_beats_sent),
      .play_bad_instr_count(ex_dbg_bad_instr_count),
      .play_prefill_ready(ex_dbg_prefill_ready),
      .play_active_valid(ex_dbg_active_valid),
      .play_pending_valid(ex_dbg_pending_valid),
      .rvresp_tdata        (rvresp64_tdata),
      .rvresp_tvalid       (rvresp64_tvalid),
      .rvresp_tready       (rvresp64_tready),
      .rvresp_tlast        (rvresp64_tlast),
      .rvresp_word_count   (rvresp64_word_count),
      .m_axil_awaddr       (RV_CTRL_AXI_awaddr),
      .m_axil_awvalid      (RV_CTRL_AXI_awvalid),
      .m_axil_awready      (RV_CTRL_AXI_awready),
      .m_axil_wdata        (RV_CTRL_AXI_wdata),
      .m_axil_wstrb        (RV_CTRL_AXI_wstrb),
      .m_axil_wvalid       (RV_CTRL_AXI_wvalid),
      .m_axil_wready       (RV_CTRL_AXI_wready),
      .m_axil_bresp        (RV_CTRL_AXI_bresp),
      .m_axil_bvalid       (RV_CTRL_AXI_bvalid),
      .m_axil_bready       (RV_CTRL_AXI_bready),
      .m_axil_araddr       (RV_CTRL_AXI_araddr),
      .m_axil_arvalid      (RV_CTRL_AXI_arvalid),
      .m_axil_arready      (RV_CTRL_AXI_arready),
      .m_axil_rdata        (RV_CTRL_AXI_rdata),
      .m_axil_rresp        (RV_CTRL_AXI_rresp),
      .m_axil_rvalid       (RV_CTRL_AXI_rvalid),
      .m_axil_rready       (RV_CTRL_AXI_rready),
      .dbg_status          (rv_dbg_status),
      .dbg_last_seq        (rv_dbg_last_seq),
      .dbg_last_cmd        (rv_dbg_last_cmd),
      .dbg_ping_count      (rv_dbg_ping_count),
      .dbg_play_count      (rv_dbg_play_count),
      .dbg_trigger_count   (rv_dbg_trigger_count),
      .dbg_mmio_write_count(rv_dbg_mmio_write_count),
      .dbg_error_count     (rv_dbg_error_count),
      .dbg_scratch         (rv_dbg_scratch),
      .dbg_state           (rv_dbg_state)
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
      .playback_armed(rfctrl2_armed_ddr | rfctrl2_pending_ddr),
      .playback_running(pc_started_ddr),
      .busy(rfdc_apply_busy), .done(rfdc_apply_done), .force_mute_pulse(rfdc_force_mute_pulse),
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

  axilite_arbiter_2to1 #(.ADDR_WIDTH(18)) pl_rfdc_axil_arbiter_i (
      .clk(ddr4_ui_clk), .rst_n(ddr4_ui_aresetn),
      .s0_awaddr(RV_CTRL_AXI_awaddr), .s0_awvalid(RV_CTRL_AXI_awvalid), .s0_awready(RV_CTRL_AXI_awready),
      .s0_wdata(RV_CTRL_AXI_wdata), .s0_wstrb(RV_CTRL_AXI_wstrb), .s0_wvalid(RV_CTRL_AXI_wvalid), .s0_wready(RV_CTRL_AXI_wready),
      .s0_bresp(RV_CTRL_AXI_bresp), .s0_bvalid(RV_CTRL_AXI_bvalid), .s0_bready(RV_CTRL_AXI_bready),
      .s0_araddr(RV_CTRL_AXI_araddr), .s0_arvalid(RV_CTRL_AXI_arvalid), .s0_arready(RV_CTRL_AXI_arready),
      .s0_rdata(RV_CTRL_AXI_rdata), .s0_rresp(RV_CTRL_AXI_rresp), .s0_rvalid(RV_CTRL_AXI_rvalid), .s0_rready(RV_CTRL_AXI_rready),
      .s1_awaddr(RFDC_CFG_AXI_awaddr), .s1_awvalid(RFDC_CFG_AXI_awvalid), .s1_awready(RFDC_CFG_AXI_awready),
      .s1_wdata(RFDC_CFG_AXI_wdata), .s1_wstrb(RFDC_CFG_AXI_wstrb), .s1_wvalid(RFDC_CFG_AXI_wvalid), .s1_wready(RFDC_CFG_AXI_wready),
      .s1_bresp(RFDC_CFG_AXI_bresp), .s1_bvalid(RFDC_CFG_AXI_bvalid), .s1_bready(RFDC_CFG_AXI_bready),
      .s1_araddr(RFDC_CFG_AXI_araddr), .s1_arvalid(RFDC_CFG_AXI_arvalid), .s1_arready(RFDC_CFG_AXI_arready),
      .s1_rdata(RFDC_CFG_AXI_rdata), .s1_rresp(RFDC_CFG_AXI_rresp), .s1_rvalid(RFDC_CFG_AXI_rvalid), .s1_rready(RFDC_CFG_AXI_rready),
      .m_awaddr(PL_CTRL_AXI_awaddr), .m_awvalid(PL_CTRL_AXI_awvalid), .m_awready(PL_CTRL_AXI_awready),
      .m_wdata(PL_CTRL_AXI_wdata), .m_wstrb(PL_CTRL_AXI_wstrb), .m_wvalid(PL_CTRL_AXI_wvalid), .m_wready(PL_CTRL_AXI_wready),
      .m_bresp(PL_CTRL_AXI_bresp), .m_bvalid(PL_CTRL_AXI_bvalid), .m_bready(PL_CTRL_AXI_bready),
      .m_araddr(PL_CTRL_AXI_araddr), .m_arvalid(PL_CTRL_AXI_arvalid), .m_arready(PL_CTRL_AXI_arready),
      .m_rdata(PL_CTRL_AXI_rdata), .m_rresp(PL_CTRL_AXI_rresp), .m_rvalid(PL_CTRL_AXI_rvalid), .m_rready(PL_CTRL_AXI_rready)
  );

  axilite_cdc_simple rv_rfdc_axil_cdc_i (
      .s_clk      (ddr4_ui_clk),
      .s_rst_n    (ddr4_ui_aresetn),
      .s_awaddr   (PL_CTRL_AXI_awaddr),
      .s_awvalid  (PL_CTRL_AXI_awvalid),
      .s_awready  (PL_CTRL_AXI_awready),
      .s_wdata    (PL_CTRL_AXI_wdata),
      .s_wstrb    (PL_CTRL_AXI_wstrb),
      .s_wvalid   (PL_CTRL_AXI_wvalid),
      .s_wready   (PL_CTRL_AXI_wready),
      .s_bresp    (PL_CTRL_AXI_bresp),
      .s_bvalid   (PL_CTRL_AXI_bvalid),
      .s_bready   (PL_CTRL_AXI_bready),
      .s_araddr   (PL_CTRL_AXI_araddr),
      .s_arvalid  (PL_CTRL_AXI_arvalid),
      .s_arready  (PL_CTRL_AXI_arready),
      .s_rdata    (PL_CTRL_AXI_rdata),
      .s_rresp    (PL_CTRL_AXI_rresp),
      .s_rvalid   (PL_CTRL_AXI_rvalid),
      .s_rready   (PL_CTRL_AXI_rready),
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

  assign control_trigger_pulse = udp_trigger_pulse | rv_trigger_pulse;

  // ========== DataMover ==========
  wire [103:0] dm_cmd_tdata;
  wire         dm_cmd_tvalid, dm_cmd_tready;
  wire [511:0] dm_data_tdata;
  wire         dm_data_tvalid, dm_data_tready, dm_data_tlast;
  wire         dm_mm2s_err;
  wire         dm_mm2s_sts_tvalid, dm_mm2s_sts_tlast;
  wire [7:0]   dm_mm2s_sts_tdata;
  wire         dm_mm2s_sts_tkeep;

  // ========== executor -> wave FIFO write side (DDR 域) ==========
  wire [255:0] ch1_wave_tdata, ch2_wave_tdata, ch3_wave_tdata, ch4_wave_tdata;
  wire [255:0] ch5_wave_tdata, ch6_wave_tdata, ch7_wave_tdata, ch8_wave_tdata;
  wire         ch1_wave_tvalid, ch2_wave_tvalid, ch3_wave_tvalid, ch4_wave_tvalid;
  wire         ch5_wave_tvalid, ch6_wave_tvalid, ch7_wave_tvalid, ch8_wave_tvalid;
  wire [15:0]  ch1_fifo_level_beats;
  wire [15:0]  ch2_fifo_level_beats;
  wire [15:0]  ch3_fifo_level_beats;
  wire [15:0]  ch4_fifo_level_beats;
  wire [15:0]  ch5_fifo_level_beats;
  wire [15:0]  ch6_fifo_level_beats;
  wire [15:0]  ch7_fifo_level_beats;
  wire [15:0]  ch8_fifo_level_beats;

  // ========== DAC side ready from DAC IP ==========
  wire         dac_ch1_ready, dac_ch2_ready, dac_ch3_ready, dac_ch4_ready;
  wire         dac_ch5_ready, dac_ch6_ready, dac_ch7_ready, dac_ch8_ready;

  // ========== DataMover AXI MM2S to DDR ==========
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
  wire [63:0]  dm_data_tkeep;

  // ========== GPIO out ==========
  wire ps_trigger_raw = gpio_out_reg[0];
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn) begin
      firmware_status_meta <= 32'd0;
      firmware_status_ddr <= 32'd0;
      hmc_done_ddr_sync <= 2'b00;
      sync_seen_ddr_sync <= 2'b00;
      sync_ready_ddr_sync <= 2'b00;
      sync_align_busy_ddr_sync <= 2'b00;
      sync_align_failed_ddr_sync <= 2'b00;
      sync_alignment_epoch_ddr_meta <= 6'd0;
      sync_alignment_epoch_ddr <= 6'd0;
      trigger_input_count_ddr_meta <= 32'd0;
      trigger_input_count_ddr <= 32'd0;
      trigger_accepted_count_ddr_meta <= 32'd0;
      trigger_accepted_count_ddr <= 32'd0;
      trigger_output_count_ddr_meta <= 32'd0;
      trigger_output_count_ddr <= 32'd0;
    end else begin
      firmware_status_meta <= gpio_out_reg;
      firmware_status_ddr <= firmware_status_meta;
      hmc_done_ddr_sync <= {hmc_done_ddr_sync[0], hmc7044_set_finish};
      sync_seen_ddr_sync <= {sync_seen_ddr_sync[0], sync_seen};
      sync_ready_ddr_sync <= {sync_ready_ddr_sync[0], sync_link_ready};
      sync_align_busy_ddr_sync <= {sync_align_busy_ddr_sync[0], sync_align_busy};
      sync_align_failed_ddr_sync <= {sync_align_failed_ddr_sync[0], sync_align_failed};
      sync_alignment_epoch_ddr_meta <= sync_alignment_epoch;
      sync_alignment_epoch_ddr <= sync_alignment_epoch_ddr_meta;
      // Counters are monotonic snapshots. Two DDR-domain samples avoid
      // exposing the PL-domain bus directly to RFCTRL2 STATUS.
      trigger_input_count_ddr_meta <= trigger_input_count;
      trigger_input_count_ddr <= trigger_input_count_ddr_meta;
      trigger_accepted_count_ddr_meta <= trigger_accepted_count;
      trigger_accepted_count_ddr <= trigger_accepted_count_ddr_meta;
      trigger_output_count_ddr_meta <= trigger_output_count;
      trigger_output_count_ddr <= trigger_output_count_ddr_meta;
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
  reg [7:0] udp_trigger_stretch_cnt;
  reg       udp_trigger_stretched;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) begin
      udp_trigger_stretch_cnt <= 8'd0;
      udp_trigger_stretched <= 1'b0;
    end else if(control_trigger_pulse) begin
      udp_trigger_stretch_cnt <= 8'd64;
      udp_trigger_stretched <= 1'b1;
    end else if(udp_trigger_stretch_cnt != 8'd0) begin
      udp_trigger_stretch_cnt <= udp_trigger_stretch_cnt - 8'd1;
      udp_trigger_stretched <= 1'b1;
    end else begin
      udp_trigger_stretched <= 1'b0;
    end
  end
  // ========== trigger CDC ==========
  // XS18/XS19 carry the independent playback Trigger. The sync_trigger_link
  // module gates both the dedicated input and the legacy fallback behind the
  // external XS20 SYNC state (or the explicit runtime bypass).
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] role_trigger_ddr_sync_ff;
  // XS19 is asynchronous to the DAC fabric. Transfer its accepted event with
  // a toggle rather than a one-cycle level: a short input pulse can be seen
  // and counted in pl_clk yet still be missed by an unrelated DAC clock.
  reg role_trigger_toggle_pl;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] role_trigger_dac_toggle_sync_ff;
  reg role_trigger_dac_toggle_seen;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn)
      role_trigger_ddr_sync_ff <= 3'b000;
    else
      role_trigger_ddr_sync_ff <= {role_trigger_ddr_sync_ff[1:0], role_trigger_raw};
  end
  always @(posedge pl_clk or negedge pl_aresetn) begin
    if(!pl_aresetn)
      role_trigger_toggle_pl <= 1'b0;
    else if(role_trigger_raw)
      role_trigger_toggle_pl <= ~role_trigger_toggle_pl;
  end
  always @(posedge dac_axis_clk or negedge clk104_aresetn) begin
    if(!clk104_aresetn) begin
      role_trigger_dac_toggle_sync_ff <= 3'b000;
      role_trigger_dac_toggle_seen <= 1'b0;
    end else begin
      role_trigger_dac_toggle_sync_ff <= {
          role_trigger_dac_toggle_sync_ff[1:0], role_trigger_toggle_pl
      };
      role_trigger_dac_toggle_seen <= role_trigger_dac_toggle_sync_ff[2];
    end
  end
  wire role_trigger_ddr_sync = role_trigger_ddr_sync_ff[2];
  wire role_trigger_dac_pulse =
      role_trigger_dac_toggle_sync_ff[2] != role_trigger_dac_toggle_seen;

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] ps_trigger_ddr_sync_ff;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) ps_trigger_ddr_sync_ff <= 3'b000;
    else                 ps_trigger_ddr_sync_ff <= {ps_trigger_ddr_sync_ff[1:0], ps_trigger_raw};
  end
  wire ps_trigger_ddr_sync = ps_trigger_ddr_sync_ff[2] |
                              udp_trigger_stretched |
                              role_trigger_ddr_sync;

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] ps_trigger_dac_sync_ff;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] udp_trigger_dac_sync_ff;
  always @(posedge dac_axis_clk or negedge clk104_aresetn) begin
    if(!clk104_aresetn) begin
      ps_trigger_dac_sync_ff <= 3'b000;
      udp_trigger_dac_sync_ff <= 3'b000;
    end else begin
      ps_trigger_dac_sync_ff <= {ps_trigger_dac_sync_ff[1:0], ps_trigger_raw};
      udp_trigger_dac_sync_ff <= {udp_trigger_dac_sync_ff[1:0], udp_trigger_stretched};
    end
  end
  wire ps_trigger_dac_sync = ps_trigger_dac_sync_ff[2] |
                              udp_trigger_dac_sync_ff[2];


  // ========== AXI-lite -> AXIS 指令 FIFO 接口（stub/IP替换） ==========
  // M_AXI_INST signals
  wire [31:0]  M_AXI_INST_araddr;
  wire [1:0]   M_AXI_INST_arburst;
  wire [3:0]   M_AXI_INST_arcache;
  wire [7:0]   M_AXI_INST_arlen;
  wire [0:0]   M_AXI_INST_arlock;
  wire [2:0]   M_AXI_INST_arprot;
  wire [3:0]   M_AXI_INST_arqos;
  wire         M_AXI_INST_arready;
  wire [2:0]   M_AXI_INST_arsize;
  wire [15:0]  M_AXI_INST_aruser;
  wire         M_AXI_INST_arvalid;

  wire [31:0]  M_AXI_INST_awaddr;
  wire [1:0]   M_AXI_INST_awburst;
  wire [3:0]   M_AXI_INST_awcache;
  wire [7:0]   M_AXI_INST_awlen;
  wire [0:0]   M_AXI_INST_awlock;
  wire [2:0]   M_AXI_INST_awprot;
  wire [3:0]   M_AXI_INST_awqos;
  wire         M_AXI_INST_awready;
  wire [2:0]   M_AXI_INST_awsize;
  wire [15:0]  M_AXI_INST_awuser;
  wire         M_AXI_INST_awvalid;

  wire         M_AXI_INST_bready;
  wire [1:0]   M_AXI_INST_bresp;
  wire         M_AXI_INST_bvalid;

  wire [31:0]  M_AXI_INST_rdata;
  wire         M_AXI_INST_rlast;
  wire         M_AXI_INST_rready;
  wire [1:0]   M_AXI_INST_rresp;
  wire         M_AXI_INST_rvalid;

  wire [31:0]  M_AXI_INST_wdata;
  wire         M_AXI_INST_wlast;
  wire         M_AXI_INST_wready;
  wire [3:0]   M_AXI_INST_wstrb;
  wire         M_AXI_INST_wvalid;

  axi_fifo_interface #(
      .AXI_DATA_WIDTH(32),
      .FIFO_DATA_WIDTH(128),
      .FIFO_DEPTH_LOG2(4)
  ) axi_fifo_inst (
      .s_axi_aclk    (pl_clk),
      .s_axi_aresetn (pl_aresetn),

      .s_axi_awaddr  (M_AXI_INST_awaddr),
      .s_axi_awlen   (M_AXI_INST_awlen),
      .s_axi_awvalid (M_AXI_INST_awvalid),
      .s_axi_awready (M_AXI_INST_awready),
      .s_axi_wdata   (M_AXI_INST_wdata),
      .s_axi_wstrb   (M_AXI_INST_wstrb),
      .s_axi_wvalid  (M_AXI_INST_wvalid),
      .s_axi_wready  (M_AXI_INST_wready),
      .s_axi_bvalid  (M_AXI_INST_bvalid),
      .s_axi_bready  (M_AXI_INST_bready),
      .s_axi_bresp   (M_AXI_INST_bresp),

      .s_axi_araddr  (M_AXI_INST_araddr),
      .s_axi_arlen   (M_AXI_INST_arlen),
      .s_axi_arvalid (M_AXI_INST_arvalid),
      .s_axi_arready (M_AXI_INST_arready),
      .s_axi_rdata   (M_AXI_INST_rdata),
      .s_axi_rlast   (M_AXI_INST_rlast),
      .s_axi_rvalid  (M_AXI_INST_rvalid),
      .s_axi_rready  (M_AXI_INST_rready),
      .s_axi_rresp   (M_AXI_INST_rresp),

      .m_aclk        (ddr4_ui_clk),
      .m_aresetn     (ddr4_ui_aresetn),
      .m_axis_tdata  (ps_instr_tdata),
      .m_axis_tvalid (ps_instr_tvalid),
      .m_axis_tready (ps_instr_tready)
  );

  // ========== executor outputs config ==========
  wire [31:0] ch1_delay_cycles, ch2_delay_cycles, ch3_delay_cycles, ch4_delay_cycles;
  wire [31:0] ch5_delay_cycles, ch6_delay_cycles, ch7_delay_cycles, ch8_delay_cycles;
  wire [31:0] ch1_len_beats,   ch2_len_beats,   ch3_len_beats,   ch4_len_beats;
  wire [31:0] ch5_len_beats,   ch6_len_beats,   ch7_len_beats,   ch8_len_beats;
  wire        cfg_auto_start;
  wire        cfg_loop;
  wire        cfg_commit; // 每次 END 提交一帧配置

  localparam [15:0] TRIG_1_WIDTH_CYCLES = 16'd300;

  wire         ex_fifo_clear;

  // ========== executor ==========
  Waveform_Interleaved_System_Top #(
    .DDR_ADDR_BASE(EXT_DDR_ADDR_BASE),
    .LOW_WM(256),
    .START_WM(512),
    .HIGH_WM(768)
  ) executor_inst (
    .aclk(ddr4_ui_clk),
    .aresetn(ddr4_ui_aresetn),
    // ARM only prepares/prefills playback. A real trigger releases output.
    .trigger(ps_trigger_ddr_sync | (rfctrl2_trigger_pulse && sync_link_ready_ddr)),
    .abort_clear(rfctrl2_abort_mute_pulse | rfdc_force_mute_pulse),

    .s_axis_instr_tdata(instr_tdata),
    .s_axis_instr_tvalid(instr_tvalid),
    .s_axis_instr_tready(instr_tready),

    .m_axis_dm_cmd_tdata(dm_cmd_tdata),
    .m_axis_dm_cmd_tvalid(dm_cmd_tvalid),
    .m_axis_dm_cmd_tready(dm_cmd_tready),

    .s_axis_dm_data_tdata(dm_data_tdata),
    .s_axis_dm_data_tvalid(dm_data_tvalid),
    .s_axis_dm_data_tready(dm_data_tready),

    .ch1_fifo_ready(ch1_wave_tready_internal),
    .ch2_fifo_ready(ch2_wave_tready_internal),
    .ch3_fifo_ready(ch3_wave_tready_internal),
    .ch4_fifo_ready(ch4_wave_tready_internal),
    .ch5_fifo_ready(ch5_wave_tready_internal),
    .ch6_fifo_ready(ch6_wave_tready_internal),
    .ch7_fifo_ready(ch7_wave_tready_internal),
    .ch8_fifo_ready(ch8_wave_tready_internal),

    .ch1_fifo_level_beats(ch1_fifo_level_beats),
    .ch2_fifo_level_beats(ch2_fifo_level_beats),
    .ch3_fifo_level_beats(ch3_fifo_level_beats),
    .ch4_fifo_level_beats(ch4_fifo_level_beats),
    .ch5_fifo_level_beats(ch5_fifo_level_beats),
    .ch6_fifo_level_beats(ch6_fifo_level_beats),
    .ch7_fifo_level_beats(ch7_fifo_level_beats),
    .ch8_fifo_level_beats(ch8_fifo_level_beats),

    .m_axis_ch1_tdata(ch1_wave_tdata),
    .m_axis_ch1_tvalid(ch1_wave_tvalid),
    .m_axis_ch2_tdata(ch2_wave_tdata),
    .m_axis_ch2_tvalid(ch2_wave_tvalid),
    .m_axis_ch3_tdata(ch3_wave_tdata),
    .m_axis_ch3_tvalid(ch3_wave_tvalid),
    .m_axis_ch4_tdata(ch4_wave_tdata),
    .m_axis_ch4_tvalid(ch4_wave_tvalid),
    .m_axis_ch5_tdata(ch5_wave_tdata),
    .m_axis_ch5_tvalid(ch5_wave_tvalid),
    .m_axis_ch6_tdata(ch6_wave_tdata),
    .m_axis_ch6_tvalid(ch6_wave_tvalid),
    .m_axis_ch7_tdata(ch7_wave_tdata),
    .m_axis_ch7_tvalid(ch7_wave_tvalid),
    .m_axis_ch8_tdata(ch8_wave_tdata),
    .m_axis_ch8_tvalid(ch8_wave_tvalid),

    .ch1_delay_cycles(ch1_delay_cycles),
    .ch2_delay_cycles(ch2_delay_cycles),
    .ch3_delay_cycles(ch3_delay_cycles),
    .ch4_delay_cycles(ch4_delay_cycles),
    .ch5_delay_cycles(ch5_delay_cycles),
    .ch6_delay_cycles(ch6_delay_cycles),
    .ch7_delay_cycles(ch7_delay_cycles),
    .ch8_delay_cycles(ch8_delay_cycles),
    .ch1_len_beats(ch1_len_beats),
    .ch2_len_beats(ch2_len_beats),
    .ch3_len_beats(ch3_len_beats),
    .ch4_len_beats(ch4_len_beats),
    .ch5_len_beats(ch5_len_beats),
    .ch6_len_beats(ch6_len_beats),
    .ch7_len_beats(ch7_len_beats),
    .ch8_len_beats(ch8_len_beats),
    .ch1_arm(ch1_arm),
    .ch2_arm(ch2_arm),
    .ch3_arm(ch3_arm),
    .ch4_arm(ch4_arm),
    .ch5_arm(ch5_arm),
    .ch6_arm(ch6_arm),
    .ch7_arm(ch7_arm),
    .ch8_arm(ch8_arm),
    .cfg_auto_start(cfg_auto_start),
    .cfg_loop(cfg_loop),
    .cfg_commit(cfg_commit),
    .fifo_clear(ex_fifo_clear),

    .dbg_st            (ex_dbg_st),
    .dbg_dm_st         (ex_dbg_dm_st),
    .dbg_dm_sel_ch1    (ex_dbg_dm_sel_ch1),
    .dbg_dm_chunk_beats(ex_dbg_dm_chunk_beats),
    .dbg_dm_beats_sent (ex_dbg_dm_beats_sent),
    .dbg_ch1_bytes_left(ex_dbg_ch1_bytes_left),
    .dbg_ch2_bytes_left(ex_dbg_ch2_bytes_left),
    .dbg_ch1_base_addr (ex_dbg_ch1_base_addr),
    .dbg_ch2_base_addr (ex_dbg_ch2_base_addr),
    .dbg_ch1_need_hard (ex_dbg_ch1_need_hard),
    .dbg_ch2_need_hard (ex_dbg_ch2_need_hard),
    .dbg_ch1_need_soft (ex_dbg_ch1_need_soft),
    .dbg_ch2_need_soft (ex_dbg_ch2_need_soft),
    .dbg_instr_in_tdata (ex_dbg_instr_in_tdata),
    .dbg_instr_in_tvalid(ex_dbg_instr_in_tvalid),
    .dbg_instr_in_tready(ex_dbg_instr_in_tready),
    .dbg_main_tdata     (ex_dbg_main_tdata),
    .dbg_main_tvalid    (ex_dbg_main_tvalid),
    .dbg_main_tready    (ex_dbg_main_tready),
    .dbg_prefill_ready  (ex_dbg_prefill_ready),
    .dbg_pending_valid  (ex_dbg_pending_valid),
    .dbg_active_valid   (ex_dbg_active_valid),
    .dbg_run_delay_cnt  (ex_dbg_run_delay_cnt),
    .dbg_bad_instr_count(ex_dbg_bad_instr_count)
  );

  // ==========================================================
  // DAC AXIS domain reset: synchronize clk104_aresetn to dac_axis_clk.
  // ==========================================================
  reg [2:0] dac_rstff;
  always @(posedge dac_axis_clk or negedge clk104_aresetn) begin
    if(!clk104_aresetn) dac_rstff <= 3'b000;
    else                dac_rstff <= {dac_rstff[1:0], 1'b1};
  end
  wire dac_rst_n = dac_rstff[2];

  wire rfctrl2_play_trigger;
  wire rfctrl2_play_prepare;
  wire rfctrl2_play_abort;
  wire dac_hw_rfctrl2_trigger = rfctrl2_play_trigger | role_trigger_dac_pulse;
  wire unused_single_board_inputs = mclk_10m_p | mclk_10m_n | EXT_TRIGGER_P | EXT_TRIGGER_N |
      rfctrl2_start_valid | ^rfctrl2_epoch | ^rfctrl2_start_tick;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if (!ddr4_ui_aresetn) begin
      rfctrl2_armed_meta <= 1'b0;
      rfctrl2_armed_ddr <= 1'b0;
      rfctrl2_prepared_meta <= 1'b0;
      rfctrl2_prepared_ddr <= 1'b0;
      rfctrl2_pending_meta <= 1'b0;
      rfctrl2_pending_ddr <= 1'b0;
      pc_started_meta <= 1'b0;
      pc_started_ddr <= 1'b0;
    end else begin
      rfctrl2_armed_meta <= rfctrl2_armed_dac;
      rfctrl2_armed_ddr <= rfctrl2_armed_meta;
      rfctrl2_prepared_meta <= rfctrl2_prepared_dac;
      rfctrl2_prepared_ddr <= rfctrl2_prepared_meta;
      rfctrl2_pending_meta <= rfctrl2_start_pending_dac;
      rfctrl2_pending_ddr <= rfctrl2_pending_meta;
      pc_started_meta <= pc_started;
      pc_started_ddr <= pc_started_meta;
    end
  end

  rfctrl2_playback_controller u_rfctrl2_playback (
    .ddr_clk                 (ddr4_ui_clk),
    .ddr_rst_n               (ddr4_ui_aresetn),
    .rfctrl2_arm_pulse       (rfctrl2_arm_pulse),
    .rfctrl2_trigger_pulse   (rfctrl2_trigger_pulse && sync_link_ready_ddr),
    .rfctrl2_abort_mute_pulse(rfctrl2_abort_mute_pulse | rfdc_force_mute_pulse),
    .dac_clk                 (dac_axis_clk),
    .dac_rst_n               (dac_rst_n),
    .play_prepare_pulse      (rfctrl2_play_prepare),
    .play_trigger_pulse      (rfctrl2_play_trigger),
    .play_abort_pulse        (rfctrl2_play_abort),
    .armed                   (rfctrl2_armed_dac),
    .hardware_tick           (),
    .start_pending           (rfctrl2_start_pending_dac)
  );

  // ==========================================================
  // DDR 域：配置帧打包，commit 时写入 cfg FIFO
  // 关键修复：写入 FIFO 的 seq_id 使用 seq_id_next，避免第一帧=0 导致 DAC gating 卡死
  // ==========================================================
  reg [15:0] seq_id;
  wire [15:0] seq_id_next = seq_id + 16'd1;
  reg         cfg_wr_pending;
  wire        cfg_wr_ready;
  reg [543:0] cfg_wr_payload;
  wire [543:0] cfg_payload_next = {
      ch1_delay_cycles,
      ch2_delay_cycles,
      ch3_delay_cycles,
      ch4_delay_cycles,
      ch5_delay_cycles,
      ch6_delay_cycles,
      ch7_delay_cycles,
      ch8_delay_cycles,
      ch1_len_beats,
      ch2_len_beats,
      ch3_len_beats,
      ch4_len_beats,
      ch5_len_beats,
      ch6_len_beats,
      ch7_len_beats,
      ch8_len_beats,
      6'd0,
      cfg_loop,
      cfg_auto_start,
      ch1_arm,
      ch2_arm,
      ch3_arm,
      ch4_arm,
      ch5_arm,
      ch6_arm,
      ch7_arm,
      ch8_arm,
      seq_id_next
  };

  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) begin
      seq_id <= 16'd0;
      cfg_wr_pending <= 1'b0;
      cfg_wr_payload <= 544'd0;
    end else begin
      if(cfg_commit && !cfg_wr_pending) begin
        cfg_wr_pending <= 1'b1;
        cfg_wr_payload <= cfg_payload_next;
      end

      if(cfg_wr_pending && cfg_wr_ready) begin
        seq_id <= seq_id_next;
        cfg_wr_pending <= 1'b0;
      end
    end
  end

  wire cfg_wr_valid = cfg_wr_pending;

  // ==========================================================
  // cfg CDC FIFO (xpm_fifo_async)  DDR->DAC
  // ==========================================================
  wire [543:0] cfg_rd_data;
  wire         cfg_rd_valid;
  reg          cfg_rd_ready;

  cfg_cdc_fifo_xpm #(
    .W(544),
    .DEPTH(16)
  ) u_cfg_fifo (
    .wr_clk(ddr4_ui_clk),
    .wr_rst_n(ddr4_ui_aresetn),
    .wr_data(cfg_wr_payload),
    .wr_valid(cfg_wr_valid),
    .wr_ready(cfg_wr_ready),

    .rd_clk(dac_axis_clk),
    .rd_rst_n(dac_rst_n),
    .rd_data(cfg_rd_data),
    .rd_valid(cfg_rd_valid),
    .rd_ready(cfg_rd_ready)
  );

  // DAC 域：锁存最新一帧配置
  reg [31:0] ch1_delay_dac, ch2_delay_dac, ch3_delay_dac, ch4_delay_dac;
  reg [31:0] ch5_delay_dac, ch6_delay_dac, ch7_delay_dac, ch8_delay_dac;
  reg [31:0] ch1_len_dac, ch2_len_dac, ch3_len_dac, ch4_len_dac;
  reg [31:0] ch5_len_dac, ch6_len_dac, ch7_len_dac, ch8_len_dac;
  reg        cfg_auto_start_dac;
  reg        cfg_loop_dac;
  reg        ch1_arm_dac, ch2_arm_dac, ch3_arm_dac, ch4_arm_dac;
  reg        ch5_arm_dac, ch6_arm_dac, ch7_arm_dac, ch8_arm_dac;
  reg [15:0] seq_id_dac;

  always @(posedge dac_axis_clk or negedge dac_rst_n) begin
    if(!dac_rst_n) begin
      cfg_rd_ready  <= 1'b0;
      ch1_delay_dac <= 0; ch2_delay_dac <= 0; ch3_delay_dac <= 0; ch4_delay_dac <= 0;
      ch5_delay_dac <= 0; ch6_delay_dac <= 0; ch7_delay_dac <= 0; ch8_delay_dac <= 0;
      ch1_len_dac   <= 0; ch2_len_dac   <= 0; ch3_len_dac <= 0; ch4_len_dac <= 0;
      ch5_len_dac   <= 0; ch6_len_dac   <= 0; ch7_len_dac <= 0; ch8_len_dac <= 0;
      cfg_auto_start_dac <= 0;
      cfg_loop_dac <= 0;
      ch1_arm_dac   <= 0; ch2_arm_dac   <= 0; ch3_arm_dac <= 0; ch4_arm_dac <= 0;
      ch5_arm_dac   <= 0; ch6_arm_dac   <= 0; ch7_arm_dac <= 0; ch8_arm_dac <= 0;
      seq_id_dac    <= 0;
    end else begin
      cfg_rd_ready <= 1'b1; // 简化：一直准备接收

      if(cfg_rd_valid && cfg_rd_ready) begin
        ch1_delay_dac <= cfg_rd_data[543:512];
        ch2_delay_dac <= cfg_rd_data[511:480];
        ch3_delay_dac <= cfg_rd_data[479:448];
        ch4_delay_dac <= cfg_rd_data[447:416];
        ch5_delay_dac <= cfg_rd_data[415:384];
        ch6_delay_dac <= cfg_rd_data[383:352];
        ch7_delay_dac <= cfg_rd_data[351:320];
        ch8_delay_dac <= cfg_rd_data[319:288];
        ch1_len_dac   <= cfg_rd_data[287:256];
        ch2_len_dac   <= cfg_rd_data[255:224];
        ch3_len_dac   <= cfg_rd_data[223:192];
        ch4_len_dac   <= cfg_rd_data[191:160];
        ch5_len_dac   <= cfg_rd_data[159:128];
        ch6_len_dac   <= cfg_rd_data[127:96];
        ch7_len_dac   <= cfg_rd_data[95:64];
        ch8_len_dac   <= cfg_rd_data[63:32];
        cfg_loop_dac <= cfg_rd_data[25];
        cfg_auto_start_dac <= cfg_rd_data[24];
        ch1_arm_dac   <= cfg_rd_data[23];
        ch2_arm_dac   <= cfg_rd_data[22];
        ch3_arm_dac   <= cfg_rd_data[21];
        ch4_arm_dac   <= cfg_rd_data[20];
        ch5_arm_dac   <= cfg_rd_data[19];
        ch6_arm_dac   <= cfg_rd_data[18];
        ch7_arm_dac   <= cfg_rd_data[17];
        ch8_arm_dac   <= cfg_rd_data[16];
        seq_id_dac    <= cfg_rd_data[15:0];
      end
    end
  end

  // ==========================================================
  // DataMover（stub/IP替换）
  // ==========================================================
  axi_datamover_0 datamover_i (
    .m_axi_mm2s_aclk    (ddr4_ui_clk),
    .m_axi_mm2s_aresetn (ddr4_ui_aresetn),
    .mm2s_err           (dm_mm2s_err),

    .m_axis_mm2s_cmdsts_aclk   (ddr4_ui_clk),
    .m_axis_mm2s_cmdsts_aresetn(ddr4_ui_aresetn),

    .s_axis_mm2s_cmd_tdata (dm_cmd_tdata),
    .s_axis_mm2s_cmd_tvalid(dm_cmd_tvalid),
    .s_axis_mm2s_cmd_tready(dm_cmd_tready),

    .m_axis_mm2s_tdata (dm_data_tdata),
    .m_axis_mm2s_tkeep (dm_data_tkeep),
    .m_axis_mm2s_tvalid(dm_data_tvalid),
    .m_axis_mm2s_tready(dm_data_tready),
    .m_axis_mm2s_tlast (dm_data_tlast),

    .m_axi_mm2s_arid   (),
    .m_axi_mm2s_araddr (M_AXI_DM_araddr),
    .m_axi_mm2s_arlen  (M_AXI_DM_arlen),
    .m_axi_mm2s_arsize (M_AXI_DM_arsize),
    .m_axi_mm2s_arburst(M_AXI_DM_arburst),
    .m_axi_mm2s_arprot (),
    .m_axi_mm2s_arcache(),
    .m_axi_mm2s_aruser (),
    .m_axi_mm2s_arvalid(M_AXI_DM_arvalid),
    .m_axi_mm2s_arready(M_AXI_DM_arready),
    .m_axi_mm2s_rdata  (M_AXI_DM_rdata),
    .m_axi_mm2s_rresp  (M_AXI_DM_rresp),
    .m_axi_mm2s_rlast  (M_AXI_DM_rlast),
    .m_axi_mm2s_rvalid (M_AXI_DM_rvalid),
    .m_axi_mm2s_rready (M_AXI_DM_rready),

    .m_axis_mm2s_sts_tvalid(dm_mm2s_sts_tvalid),
    .m_axis_mm2s_sts_tready(1'b1),
    .m_axis_mm2s_sts_tdata (dm_mm2s_sts_tdata),
    .m_axis_mm2s_sts_tkeep (dm_mm2s_sts_tkeep),
    .m_axis_mm2s_sts_tlast (dm_mm2s_sts_tlast)
  );

  // ==========================================================
  // Wave async FIFO (DDR 256-bit AXIS -> DAC 256-bit RFDC AXIS).
  // ==========================================================
  wire [255:0] dac_in_ch1_tdata, dac_in_ch2_tdata, dac_in_ch3_tdata, dac_in_ch4_tdata;
  wire [255:0] dac_in_ch5_tdata, dac_in_ch6_tdata, dac_in_ch7_tdata, dac_in_ch8_tdata;
  wire         dac_ch1_ready_gated, dac_ch2_ready_gated, dac_ch3_ready_gated, dac_ch4_ready_gated;
  wire         dac_ch5_ready_gated, dac_ch6_ready_gated, dac_ch7_ready_gated, dac_ch8_ready_gated;
  wire         dac_ch1_valid_gated, dac_ch2_valid_gated, dac_ch3_valid_gated, dac_ch4_valid_gated;
  wire         dac_ch5_valid_gated, dac_ch6_valid_gated, dac_ch7_valid_gated, dac_ch8_valid_gated;

  wire ch1_allow, ch2_allow, ch3_allow, ch4_allow;
  wire ch5_allow, ch6_allow, ch7_allow, ch8_allow;
  wire ch1_prog_empty, ch1_prog_full;
  wire ch2_prog_empty, ch2_prog_full;
  wire ch3_prog_empty, ch3_prog_full;
  wire ch4_prog_empty, ch4_prog_full;
  wire ch5_prog_empty, ch5_prog_full;
  wire ch6_prog_empty, ch6_prog_full;
  wire ch7_prog_empty, ch7_prog_full;
  wire ch8_prog_empty, ch8_prog_full;

  // ===== NEW: play_ctrl debug wires (接 ILA 用) =====
  wire        pc_trig_pulse, pc_new_cfg, pc_trig_start;
  wire [15:0] pc_last_seq_id;
  wire        pc_done_pulse;
  wire [7:0]  pc_underflow_seen;
  wire [31:0] pc_ch1_fire_count, pc_ch2_fire_count, pc_ch3_fire_count, pc_ch4_fire_count;
  wire [31:0] pc_ch5_fire_count, pc_ch6_fire_count, pc_ch7_fire_count, pc_ch8_fire_count;

  dac_play_ctrl #(
    .BEAT_BYTES(32)
  ) u_play_ctrl (
    .clk(dac_axis_clk),
    .rst_n(dac_rst_n),
    .trigger(ps_trigger_dac_sync),
    .rfctrl2_trigger(dac_hw_rfctrl2_trigger),
    .prepare(rfctrl2_play_prepare),
    .abort(rfctrl2_play_abort),
    .armed(rfctrl2_armed_dac),

    .cfg_seq_id(seq_id_dac),
    .auto_start(cfg_auto_start_dac),
    .loop_enable(cfg_loop_dac),

    .ch1_delay_cycles(ch1_delay_dac),
    .ch2_delay_cycles(ch2_delay_dac),
    .ch3_delay_cycles(ch3_delay_dac),
    .ch4_delay_cycles(ch4_delay_dac),
    .ch5_delay_cycles(ch5_delay_dac),
    .ch6_delay_cycles(ch6_delay_dac),
    .ch7_delay_cycles(ch7_delay_dac),
    .ch8_delay_cycles(ch8_delay_dac),
    .ch1_len_beats(ch1_len_dac),
    .ch2_len_beats(ch2_len_dac),
    .ch3_len_beats(ch3_len_dac),
    .ch4_len_beats(ch4_len_dac),
    .ch5_len_beats(ch5_len_dac),
    .ch6_len_beats(ch6_len_dac),
    .ch7_len_beats(ch7_len_dac),
    .ch8_len_beats(ch8_len_dac),
    .ch1_arm(ch1_arm_dac),
    .ch2_arm(ch2_arm_dac),
    .ch3_arm(ch3_arm_dac),
    .ch4_arm(ch4_arm_dac),
    .ch5_arm(ch5_arm_dac),
    .ch6_arm(ch6_arm_dac),
    .ch7_arm(ch7_arm_dac),
    .ch8_arm(ch8_arm_dac),

    .ch1_fifo_tvalid(dac_in_ch1_tvalid),
    .ch2_fifo_tvalid(dac_in_ch2_tvalid),
    .ch3_fifo_tvalid(dac_in_ch3_tvalid),
    .ch4_fifo_tvalid(dac_in_ch4_tvalid),
    .ch5_fifo_tvalid(dac_in_ch5_tvalid),
    .ch6_fifo_tvalid(dac_in_ch6_tvalid),
    .ch7_fifo_tvalid(dac_in_ch7_tvalid),
    .ch8_fifo_tvalid(dac_in_ch8_tvalid),
    .ch1_fifo_prog_empty(ch1_prog_empty),
    .ch2_fifo_prog_empty(ch2_prog_empty),
    .ch3_fifo_prog_empty(ch3_prog_empty),
    .ch4_fifo_prog_empty(ch4_prog_empty),
    .ch5_fifo_prog_empty(ch5_prog_empty),
    .ch6_fifo_prog_empty(ch6_prog_empty),
    .ch7_fifo_prog_empty(ch7_prog_empty),
    .ch8_fifo_prog_empty(ch8_prog_empty),

    .dac_ch1_ready_in(dac_ch1_ready),
    .dac_ch2_ready_in(dac_ch2_ready),
    .dac_ch3_ready_in(dac_ch3_ready),
    .dac_ch4_ready_in(dac_ch4_ready),
    .dac_ch5_ready_in(dac_ch5_ready),
    .dac_ch6_ready_in(dac_ch6_ready),
    .dac_ch7_ready_in(dac_ch7_ready),
    .dac_ch8_ready_in(dac_ch8_ready),

    .ch1_allow(ch1_allow),
    .ch2_allow(ch2_allow),
    .ch3_allow(ch3_allow),
    .ch4_allow(ch4_allow),
    .ch5_allow(ch5_allow),
    .ch6_allow(ch6_allow),
    .ch7_allow(ch7_allow),
    .ch8_allow(ch8_allow),

    .ch1_active(),
    .ch2_active(),
    .ch3_active(),
    .ch4_active(),
    .ch5_active(),
    .ch6_active(),
    .ch7_active(),
    .ch8_active(),
    .prepared(rfctrl2_prepared_dac),

    .dbg_trig_pulse (pc_trig_pulse),
    .dbg_new_cfg    (pc_new_cfg),
    .dbg_trig_start (pc_trig_start),
    .dbg_started    (pc_started),
    .dbg_last_seq_id(pc_last_seq_id),
    .dbg_done_pulse(pc_done_pulse),
    .dbg_underflow_seen(pc_underflow_seen),
    .dbg_ch1_fire_count(pc_ch1_fire_count),
    .dbg_ch2_fire_count(pc_ch2_fire_count),
    .dbg_ch3_fire_count(pc_ch3_fire_count),
    .dbg_ch4_fire_count(pc_ch4_fire_count),
    .dbg_ch5_fire_count(pc_ch5_fire_count),
    .dbg_ch6_fire_count(pc_ch6_fire_count),
    .dbg_ch7_fire_count(pc_ch7_fire_count),
    .dbg_ch8_fire_count(pc_ch8_fire_count)
  );

  wire [31:0] ch1_wr_count, ch2_wr_count, ch3_wr_count, ch4_wr_count;
  wire [31:0] ch5_wr_count, ch6_wr_count, ch7_wr_count, ch8_wr_count;

  assign ch1_fifo_level_beats = ch1_wr_count[15:0];
  assign ch2_fifo_level_beats = ch2_wr_count[15:0];
  assign ch3_fifo_level_beats = ch3_wr_count[15:0];
  assign ch4_fifo_level_beats = ch4_wr_count[15:0];
  assign ch5_fifo_level_beats = ch5_wr_count[15:0];
  assign ch6_fifo_level_beats = ch6_wr_count[15:0];
  assign ch7_fifo_level_beats = ch7_wr_count[15:0];
  assign ch8_fifo_level_beats = ch8_wr_count[15:0];

  wire ch1_wave_tlast = 1'b0;
  wire ch2_wave_tlast = 1'b0;
  wire ch3_wave_tlast = 1'b0;
  wire ch4_wave_tlast = 1'b0;
  wire ch5_wave_tlast = 1'b0;
  wire ch6_wave_tlast = 1'b0;
  wire ch7_wave_tlast = 1'b0;
  wire ch8_wave_tlast = 1'b0;
  wire dac_out_ch1_tlast, dac_out_ch2_tlast, dac_out_ch3_tlast, dac_out_ch4_tlast;
  wire dac_out_ch5_tlast, dac_out_ch6_tlast, dac_out_ch7_tlast, dac_out_ch8_tlast;

  reg [4:0] wave_fifo_reset_cnt;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) begin
      wave_fifo_reset_cnt <= 5'd0;
    end else if(ex_fifo_clear) begin
      wave_fifo_reset_cnt <= 5'd16;
    end else if(wave_fifo_reset_cnt != 5'd0) begin
      wave_fifo_reset_cnt <= wave_fifo_reset_cnt - 5'd1;
    end
  end
  wire wave_fifo_aresetn = ddr4_ui_aresetn & (wave_fifo_reset_cnt == 5'd0);

  assign dac_ch1_ready_gated = dac_ch1_ready & ch1_allow;
  assign dac_ch2_ready_gated = dac_ch2_ready & ch2_allow;
  assign dac_ch3_ready_gated = dac_ch3_ready & ch3_allow;
  assign dac_ch4_ready_gated = dac_ch4_ready & ch4_allow;
  assign dac_ch5_ready_gated = dac_ch5_ready & ch5_allow;
  assign dac_ch6_ready_gated = dac_ch6_ready & ch6_allow;
  assign dac_ch7_ready_gated = dac_ch7_ready & ch7_allow;
  assign dac_ch8_ready_gated = dac_ch8_ready & ch8_allow;
  assign dac_ch1_valid_gated = dac_in_ch1_tvalid & ch1_allow;
  assign dac_ch2_valid_gated = dac_in_ch2_tvalid & ch2_allow;
  assign dac_ch3_valid_gated = dac_in_ch3_tvalid & ch3_allow;
  assign dac_ch4_valid_gated = dac_in_ch4_tvalid & ch4_allow;
  assign dac_ch5_valid_gated = dac_in_ch5_tvalid & ch5_allow;
  assign dac_ch6_valid_gated = dac_in_ch6_tvalid & ch6_allow;
  assign dac_ch7_valid_gated = dac_in_ch7_tvalid & ch7_allow;
  assign dac_ch8_valid_gated = dac_in_ch8_tvalid & ch8_allow;

  wire [255:0] rfdc_ch1_tdata = (rfdc_output_permitted_dac && ch1_allow) ? dac_in_ch1_tdata : 256'd0;
  wire [255:0] rfdc_ch2_tdata = (rfdc_output_permitted_dac && ch2_allow) ? dac_in_ch2_tdata : 256'd0;
  wire [255:0] rfdc_ch3_tdata = (rfdc_output_permitted_dac && ch3_allow) ? dac_in_ch3_tdata : 256'd0;
  wire [255:0] rfdc_ch4_tdata = (rfdc_output_permitted_dac && ch4_allow) ? dac_in_ch4_tdata : 256'd0;
  wire [255:0] rfdc_ch5_tdata = (rfdc_output_permitted_dac && ch5_allow) ? dac_in_ch5_tdata : 256'd0;
  wire [255:0] rfdc_ch6_tdata = (rfdc_output_permitted_dac && ch6_allow) ? dac_in_ch6_tdata : 256'd0;
  wire [255:0] rfdc_ch7_tdata = (rfdc_output_permitted_dac && ch7_allow) ? dac_in_ch7_tdata : 256'd0;
  wire [255:0] rfdc_ch8_tdata = (rfdc_output_permitted_dac && ch8_allow) ? dac_in_ch8_tdata : 256'd0;
  wire         rfdc_ch1_tvalid = (rfdc_output_permitted_dac && ch1_allow) ? dac_in_ch1_tvalid : 1'b1;
  wire         rfdc_ch2_tvalid = (rfdc_output_permitted_dac && ch2_allow) ? dac_in_ch2_tvalid : 1'b1;
  wire         rfdc_ch3_tvalid = (rfdc_output_permitted_dac && ch3_allow) ? dac_in_ch3_tvalid : 1'b1;
  wire         rfdc_ch4_tvalid = (rfdc_output_permitted_dac && ch4_allow) ? dac_in_ch4_tvalid : 1'b1;
  wire         rfdc_ch5_tvalid = (rfdc_output_permitted_dac && ch5_allow) ? dac_in_ch5_tvalid : 1'b1;
  wire         rfdc_ch6_tvalid = (rfdc_output_permitted_dac && ch6_allow) ? dac_in_ch6_tvalid : 1'b1;
  wire         rfdc_ch7_tvalid = (rfdc_output_permitted_dac && ch7_allow) ? dac_in_ch7_tvalid : 1'b1;
  wire         rfdc_ch8_tvalid = (rfdc_output_permitted_dac && ch8_allow) ? dac_in_ch8_tvalid : 1'b1;

  wire dac_any_valid_gated = dac_ch1_valid_gated | dac_ch2_valid_gated |
                             dac_ch3_valid_gated | dac_ch4_valid_gated |
                             dac_ch5_valid_gated | dac_ch6_valid_gated |
                             dac_ch7_valid_gated | dac_ch8_valid_gated;
  reg        dac_any_valid_gated_d;
  reg [15:0] trig_1_dac_valid_count;

  always @(posedge dac_axis_clk or negedge dac_rst_n) begin
    if(!dac_rst_n) begin
      dac_any_valid_gated_d  <= 1'b0;
      trig_1_dac_valid_count <= 16'd0;
    end else begin
      dac_any_valid_gated_d <= dac_any_valid_gated;
      if(dac_any_valid_gated & ~dac_any_valid_gated_d) begin
        trig_1_dac_valid_count <= TRIG_1_WIDTH_CYCLES;
      end else if(trig_1_dac_valid_count != 16'd0) begin
        trig_1_dac_valid_count <= trig_1_dac_valid_count - 16'd1;
      end
    end
  end

  wire trig_1_dac_valid = (trig_1_dac_valid_count != 16'd0);
  wire trig_1_dac_valid_pulse = dac_any_valid_gated & ~dac_any_valid_gated_d;
  // TRIG_1 is the dedicated XS18 Trigger output. The old DAC-valid debug
  // pulse remains available internally as trig_1_dac_valid.

  axis_async_fifo_256 fifo_ch1_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch1_wave_tvalid),
    .s_axis_tready (ch1_wave_tready_internal),
    .s_axis_tdata  (ch1_wave_tdata),
    .s_axis_tlast  (ch1_wave_tlast),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch1_tvalid),
    .m_axis_tready (dac_ch1_ready_gated),
    .m_axis_tdata  (dac_in_ch1_tdata),
    .m_axis_tlast  (dac_out_ch1_tlast),

    .axis_wr_data_count(ch1_wr_count),
    .prog_empty        (ch1_prog_empty),
    .prog_full         (ch1_prog_full)
  );

  axis_async_fifo_256 fifo_ch2_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch2_wave_tvalid),
    .s_axis_tready (ch2_wave_tready_internal),
    .s_axis_tdata  (ch2_wave_tdata),
    .s_axis_tlast  (ch2_wave_tlast),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch2_tvalid),
    .m_axis_tready (dac_ch2_ready_gated),
    .m_axis_tdata  (dac_in_ch2_tdata),
    .m_axis_tlast  (dac_out_ch2_tlast),

    .axis_wr_data_count(ch2_wr_count),
    .prog_empty        (ch2_prog_empty),
    .prog_full         (ch2_prog_full)
  );


  axis_async_fifo_256 fifo_ch3_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch3_wave_tvalid),
    .s_axis_tready (ch3_wave_tready_internal),
    .s_axis_tdata  (ch3_wave_tdata),
    .s_axis_tlast  (ch3_wave_tlast),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch3_tvalid),
    .m_axis_tready (dac_ch3_ready_gated),
    .m_axis_tdata  (dac_in_ch3_tdata),
    .m_axis_tlast  (dac_out_ch3_tlast),

    .axis_wr_data_count(ch3_wr_count),
    .prog_empty        (ch3_prog_empty),
    .prog_full         (ch3_prog_full)
  );

  axis_async_fifo_256 fifo_ch4_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch4_wave_tvalid),
    .s_axis_tready (ch4_wave_tready_internal),
    .s_axis_tdata  (ch4_wave_tdata),
    .s_axis_tlast  (ch4_wave_tlast),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch4_tvalid),
    .m_axis_tready (dac_ch4_ready_gated),
    .m_axis_tdata  (dac_in_ch4_tdata),
    .m_axis_tlast  (dac_out_ch4_tlast),

    .axis_wr_data_count(ch4_wr_count),
    .prog_empty        (ch4_prog_empty),
    .prog_full         (ch4_prog_full)
  );

  axis_async_fifo_256 fifo_ch5_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch5_wave_tvalid),
    .s_axis_tready (ch5_wave_tready_internal),
    .s_axis_tdata  (ch5_wave_tdata),
    .s_axis_tlast  (ch5_wave_tlast),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch5_tvalid),
    .m_axis_tready (dac_ch5_ready_gated),
    .m_axis_tdata  (dac_in_ch5_tdata),
    .m_axis_tlast  (dac_out_ch5_tlast),

    .axis_wr_data_count(ch5_wr_count),
    .prog_empty        (ch5_prog_empty),
    .prog_full         (ch5_prog_full)
  );

  axis_async_fifo_256 fifo_ch6_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch6_wave_tvalid),
    .s_axis_tready (ch6_wave_tready_internal),
    .s_axis_tdata  (ch6_wave_tdata),
    .s_axis_tlast  (ch6_wave_tlast),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch6_tvalid),
    .m_axis_tready (dac_ch6_ready_gated),
    .m_axis_tdata  (dac_in_ch6_tdata),
    .m_axis_tlast  (dac_out_ch6_tlast),

    .axis_wr_data_count(ch6_wr_count),
    .prog_empty        (ch6_prog_empty),
    .prog_full         (ch6_prog_full)
  );

  axis_async_fifo_256 fifo_ch7_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch7_wave_tvalid),
    .s_axis_tready (ch7_wave_tready_internal),
    .s_axis_tdata  (ch7_wave_tdata),
    .s_axis_tlast  (ch7_wave_tlast),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch7_tvalid),
    .m_axis_tready (dac_ch7_ready_gated),
    .m_axis_tdata  (dac_in_ch7_tdata),
    .m_axis_tlast  (dac_out_ch7_tlast),

    .axis_wr_data_count(ch7_wr_count),
    .prog_empty        (ch7_prog_empty),
    .prog_full         (ch7_prog_full)
  );

  axis_async_fifo_256 fifo_ch8_inst (
    .s_axis_aresetn(wave_fifo_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch8_wave_tvalid),
    .s_axis_tready (ch8_wave_tready_internal),
    .s_axis_tdata  (ch8_wave_tdata),
    .s_axis_tlast  (ch8_wave_tlast),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_in_ch8_tvalid),
    .m_axis_tready (dac_ch8_ready_gated),
    .m_axis_tdata  (dac_in_ch8_tdata),
    .m_axis_tlast  (dac_out_ch8_tlast),

    .axis_wr_data_count(ch8_wr_count),
    .prog_empty        (ch8_prog_empty),
    .prog_full         (ch8_prog_full)
  );

  // ==========================================================
  // design_1（Block Design stub/IP替换）
  // 注意：送入 DAC 的 tvalid 必须用 gated valid！
  // ==========================================================
  // M_AXI_GPIO (stub)
  wire [31:0] M_AXI_GPIO_araddr;
  wire [1:0]  M_AXI_GPIO_arburst;
  wire [3:0]  M_AXI_GPIO_arcache;
  wire [7:0]  M_AXI_GPIO_arlen;
  wire [0:0]  M_AXI_GPIO_arlock;
  wire [2:0]  M_AXI_GPIO_arprot;
  wire [3:0]  M_AXI_GPIO_arqos;
  wire        M_AXI_GPIO_arready;
  wire [2:0]  M_AXI_GPIO_arsize;
  wire [15:0] M_AXI_GPIO_aruser;
  wire        M_AXI_GPIO_arvalid;

  wire [31:0] M_AXI_GPIO_awaddr;
  wire [1:0]  M_AXI_GPIO_awburst;
  wire [3:0]  M_AXI_GPIO_awcache;
  wire [7:0]  M_AXI_GPIO_awlen;
  wire [0:0]  M_AXI_GPIO_awlock;
  wire [2:0]  M_AXI_GPIO_awprot;
  wire [3:0]  M_AXI_GPIO_awqos;
  wire        M_AXI_GPIO_awready;
  wire [2:0]  M_AXI_GPIO_awsize;
  wire [15:0] M_AXI_GPIO_awuser;
  wire        M_AXI_GPIO_awvalid;

  wire        M_AXI_GPIO_bready;
  wire [1:0]  M_AXI_GPIO_bresp;
  wire        M_AXI_GPIO_bvalid;

  wire [31:0] M_AXI_GPIO_rdata;
  wire [31:0] axigpio_rdata;
  wire        M_AXI_GPIO_rlast;
  wire        M_AXI_GPIO_rready;
  wire [1:0]  M_AXI_GPIO_rresp;
  wire        M_AXI_GPIO_rvalid;

  wire [31:0] M_AXI_GPIO_wdata;
  wire        M_AXI_GPIO_wlast;
  wire        M_AXI_GPIO_wready;
  wire [3:0]  M_AXI_GPIO_wstrb;
  wire        M_AXI_GPIO_wvalid;

  wire [17:0] M_AXI_RFDC_araddr;
  wire        M_AXI_RFDC_arready;
  wire        M_AXI_RFDC_arvalid;

  wire [17:0] M_AXI_RFDC_awaddr;
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
      .s0_awaddr(M_AXI_RFDC_awaddr), .s0_awvalid(M_AXI_RFDC_awvalid), .s0_awready(M_AXI_RFDC_awready),
      .s0_wdata(M_AXI_RFDC_wdata), .s0_wstrb(M_AXI_RFDC_wstrb), .s0_wvalid(M_AXI_RFDC_wvalid), .s0_wready(M_AXI_RFDC_wready),
      .s0_bresp(M_AXI_RFDC_bresp), .s0_bvalid(M_AXI_RFDC_bvalid), .s0_bready(M_AXI_RFDC_bready),
      .s0_araddr(M_AXI_RFDC_araddr), .s0_arvalid(M_AXI_RFDC_arvalid), .s0_arready(M_AXI_RFDC_arready),
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

  wire         ddr4_init_calib_complete;

  design_1 design_1_i (
      .pl_clk(pl_clk),
      .pl_aresetn(pl_aresetn),
      .pl_resetn0(pl_resetn0),
      .pl_ps_irq(pl_ps_irq),
      .ddr4_ui_clk(ddr4_ui_clk),




      // PS AXI master for instruction fifo (M_AXI_INST)
      .M_AXI_INST_araddr(M_AXI_INST_araddr),
      .M_AXI_INST_arburst(M_AXI_INST_arburst),
      .M_AXI_INST_arcache(M_AXI_INST_arcache),
      .M_AXI_INST_arlen(M_AXI_INST_arlen),
      .M_AXI_INST_arlock(M_AXI_INST_arlock),
      .M_AXI_INST_arprot(M_AXI_INST_arprot),
      .M_AXI_INST_arqos(M_AXI_INST_arqos),
      .M_AXI_INST_arready(M_AXI_INST_arready),
      .M_AXI_INST_arsize(M_AXI_INST_arsize),
      .M_AXI_INST_aruser(M_AXI_INST_aruser),
      .M_AXI_INST_arvalid(M_AXI_INST_arvalid),

      .M_AXI_INST_awaddr(M_AXI_INST_awaddr),
      .M_AXI_INST_awburst(M_AXI_INST_awburst),
      .M_AXI_INST_awcache(M_AXI_INST_awcache),
      .M_AXI_INST_awlen(M_AXI_INST_awlen),
      .M_AXI_INST_awlock(M_AXI_INST_awlock),
      .M_AXI_INST_awprot(M_AXI_INST_awprot),
      .M_AXI_INST_awqos(M_AXI_INST_awqos),
      .M_AXI_INST_awready(M_AXI_INST_awready),
      .M_AXI_INST_awsize(M_AXI_INST_awsize),
      .M_AXI_INST_awuser(M_AXI_INST_awuser),
      .M_AXI_INST_awvalid(M_AXI_INST_awvalid),

      .M_AXI_INST_bready(M_AXI_INST_bready),
      .M_AXI_INST_bresp(M_AXI_INST_bresp),
      .M_AXI_INST_bvalid(M_AXI_INST_bvalid),

      .M_AXI_INST_rdata(M_AXI_INST_rdata),
      .M_AXI_INST_rlast(M_AXI_INST_rlast),
      .M_AXI_INST_rready(M_AXI_INST_rready),
      .M_AXI_INST_rresp(M_AXI_INST_rresp),
      .M_AXI_INST_rvalid(M_AXI_INST_rvalid),

      .M_AXI_INST_wdata(M_AXI_INST_wdata),
      .M_AXI_INST_wlast(M_AXI_INST_wlast),
      .M_AXI_INST_wready(M_AXI_INST_wready),
      .M_AXI_INST_wstrb(M_AXI_INST_wstrb),
      .M_AXI_INST_wvalid(M_AXI_INST_wvalid),

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


      // GPIO AXI master (M_AXI_GPIO) - stub pass-through in this file
      .M_AXI_GPIO_araddr (M_AXI_GPIO_araddr),
      .M_AXI_GPIO_arburst(M_AXI_GPIO_arburst),
      .M_AXI_GPIO_arcache(M_AXI_GPIO_arcache),
      .M_AXI_GPIO_arlen  (M_AXI_GPIO_arlen),
      .M_AXI_GPIO_arlock (M_AXI_GPIO_arlock),
      .M_AXI_GPIO_arprot (M_AXI_GPIO_arprot),
      .M_AXI_GPIO_arqos  (M_AXI_GPIO_arqos),
      .M_AXI_GPIO_arready(M_AXI_GPIO_arready),
      .M_AXI_GPIO_arsize (M_AXI_GPIO_arsize),
      .M_AXI_GPIO_aruser (M_AXI_GPIO_aruser),
      .M_AXI_GPIO_arvalid(M_AXI_GPIO_arvalid),

      .M_AXI_GPIO_awaddr (M_AXI_GPIO_awaddr),
      .M_AXI_GPIO_awburst(M_AXI_GPIO_awburst),
      .M_AXI_GPIO_awcache(M_AXI_GPIO_awcache),
      .M_AXI_GPIO_awlen  (M_AXI_GPIO_awlen),
      .M_AXI_GPIO_awlock (M_AXI_GPIO_awlock),
      .M_AXI_GPIO_awprot (M_AXI_GPIO_awprot),
      .M_AXI_GPIO_awqos  (M_AXI_GPIO_awqos),
      .M_AXI_GPIO_awready(M_AXI_GPIO_awready),
      .M_AXI_GPIO_awsize (M_AXI_GPIO_awsize),
      .M_AXI_GPIO_awuser (M_AXI_GPIO_awuser),
      .M_AXI_GPIO_awvalid(M_AXI_GPIO_awvalid),

      .M_AXI_GPIO_bready (M_AXI_GPIO_bready),
      .M_AXI_GPIO_bresp  (M_AXI_GPIO_bresp),
      .M_AXI_GPIO_bvalid (M_AXI_GPIO_bvalid),

      .M_AXI_GPIO_rdata  (M_AXI_GPIO_rdata),
      .M_AXI_GPIO_rlast  (M_AXI_GPIO_rlast),
      .M_AXI_GPIO_rready (M_AXI_GPIO_rready),
      .M_AXI_GPIO_rresp  (M_AXI_GPIO_rresp),
      .M_AXI_GPIO_rvalid (M_AXI_GPIO_rvalid),

      .M_AXI_GPIO_wdata  (M_AXI_GPIO_wdata),
      .M_AXI_GPIO_wlast  (M_AXI_GPIO_wlast),
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
      .c0_init_calib_complete(ddr4_init_calib_complete),
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
      .clk_dac0(clk_dac0),
      .s0_axis_aclk(dac_axis_clk),
      .s0_axis_aresetn(clk104_aresetn),
      .clk_dac1(clk_dac1),
      .s1_axis_aclk(dac_axis_clk),
      .s1_axis_aresetn(clk104_aresetn),
      .clk_dac2(clk_dac2),
      .s2_axis_aclk(dac_axis_clk),
      .s2_axis_aresetn(clk104_aresetn),
      .clk_dac3(clk_dac3),
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
      .irq(rfdc_irq)
  );

  // ==========================================================
  // GPIO IP（stub）—— 输出 gpio_out_reg
  // ==========================================================
  AXIGPIO axigpio_i (
      .clock(pl_clk),
      .reset(~pl_aresetn),
      .io_axi_aw_ready(M_AXI_GPIO_awready),
      .io_axi_aw_valid(M_AXI_GPIO_awvalid),
      .io_axi_aw_bits_addr(M_AXI_GPIO_awaddr[8:0]),
      .io_axi_aw_bits_burst(M_AXI_GPIO_awburst),
      .io_axi_aw_bits_cache(M_AXI_GPIO_awcache),
      .io_axi_aw_bits_lock(M_AXI_GPIO_awlock),
      .io_axi_aw_bits_prot(M_AXI_GPIO_awprot),
      .io_axi_aw_bits_qos(M_AXI_GPIO_awqos),
      .io_axi_aw_bits_region(4'b0000),
      .io_axi_aw_bits_size(M_AXI_GPIO_awsize),

      .io_axi_ar_ready(M_AXI_GPIO_arready),
      .io_axi_ar_valid(M_AXI_GPIO_arvalid),
      .io_axi_ar_bits_addr(M_AXI_GPIO_araddr[8:0]),
      .io_axi_ar_bits_burst(M_AXI_GPIO_arburst),
      .io_axi_ar_bits_cache(M_AXI_GPIO_arcache),
      .io_axi_ar_bits_lock(M_AXI_GPIO_arlock),
      .io_axi_ar_bits_prot(M_AXI_GPIO_arprot),
      .io_axi_ar_bits_qos(M_AXI_GPIO_arqos),
      .io_axi_ar_bits_region(4'b0000),
      .io_axi_ar_bits_size(M_AXI_GPIO_arsize),

      .io_axi_w_ready(M_AXI_GPIO_wready),
      .io_axi_w_valid(M_AXI_GPIO_wvalid),
      .io_axi_w_bits_data(M_AXI_GPIO_wdata),
      .io_axi_w_bits_last(M_AXI_GPIO_wlast),
      .io_axi_w_bits_strb(M_AXI_GPIO_wstrb),

      .io_axi_r_ready(M_AXI_GPIO_rready),
      .io_axi_r_valid(M_AXI_GPIO_rvalid),
      .io_axi_r_bits_data(axigpio_rdata),
      .io_axi_r_bits_last(M_AXI_GPIO_rlast),
      .io_axi_r_bits_resp(M_AXI_GPIO_rresp),

      .io_axi_b_ready(M_AXI_GPIO_bready),
      .io_axi_b_valid(M_AXI_GPIO_bvalid),
      .io_axi_b_bits_resp(M_AXI_GPIO_bresp),

      .io_gpio(),
      .io_gpio2(gpio_out_reg)
  );

  // GPIO2 readback keeps the legacy HMC done bit and exposes the six-bit
  // runtime SYNC event epoch in bits 30:25.  Firmware acknowledges the same
  // epoch by writing those bits back in its GPIO2 status word.
  // GPIO2 is bidirectional from the firmware's point of view: writes carry
  // the ACK epoch, while reads must return the PL event epoch.  Do not OR the
  // two epoch values together (for example, old ACK 1 OR new event 2 is 3).
  assign M_AXI_GPIO_rdata =
      {hmc7044_set_finish, sync_event_epoch, axigpio_rdata[24:0]};


  ila_s_axi_01 u_ila_s_axi_01 (
    .clk(ddr4_ui_clk),
    .probe0(M_AXI_DM_araddr),
    .probe1(M_AXI_DM_arlen),
    .probe2(M_AXI_DM_arsize),
    .probe3({M_AXI_DM_arvalid, M_AXI_DM_arready, M_AXI_DM_rvalid, M_AXI_DM_rready}),
    .probe4(M_AXI_DM_rdata),
    .probe5(M_AXI_DM_rresp),
    .probe6(M_AXI_WAVE_awaddr),
    .probe7(M_AXI_WAVE_awlen),
    .probe8(M_AXI_WAVE_awsize),
    .probe9({M_AXI_WAVE_awvalid, M_AXI_WAVE_awready, M_AXI_WAVE_wvalid, M_AXI_WAVE_wready}),
    .probe10(M_AXI_WAVE_wdata),
    .probe11({M_AXI_WAVE_bvalid, M_AXI_WAVE_bready, M_AXI_WAVE_bresp})
  );

  ila_udp_ddr u_ila_udp_ddr (
    .clk(ddr4_ui_clk),
    .probe0({
      ddr4_ui_aresetn,                 // 127
      ps_trigger_ddr_sync,             // 126
      udp64_rcv_vld,                   // 125
      udp_wave_pkt,                    // 124
      udp_instr_word,                  // 123
      udp_instr_tvalid,                // 122
      udp_instr_tready,                // 121
      rvctrl64_tvalid,                 // 120
      rvctrl64_tfirst,                 // 119
      rvctrl64_tlast,                  // 118
      rv_instr_tvalid,                 // 117
      rv_instr_tready,                 // 116
      instr_tvalid,                    // 115
      instr_tready,                    // 114
      cfg_commit,                      // 113
      ch1_wave_tvalid,                 // 112
      ch1_wave_tready_internal,        // 111
      ch2_wave_tvalid,                 // 110
      ch2_wave_tready_internal,        // 109
      M_AXI_DM_arvalid,                // 108
      M_AXI_DM_arready,                // 107
      M_AXI_DM_rvalid,                 // 106
      M_AXI_DM_rready,                 // 105
      M_AXI_DM_rlast,                  // 104
      dm_mm2s_err,                     // 103
      control_trigger_pulse,           // 102
      M_AXI_WAVE_awvalid,              // 101
      M_AXI_WAVE_awready,              // 100
      M_AXI_WAVE_wvalid,               // 99
      M_AXI_WAVE_wready,               // 98
      M_AXI_WAVE_bvalid,               // 97
      M_AXI_WAVE_bready,               // 96
      ex_dbg_active_valid,             // 95
      ex_dbg_pending_valid,            // 94
      ex_dbg_ch1_need_hard,            // 93
      ex_dbg_ch2_need_hard,            // 92
      ex_dbg_ch1_need_soft,            // 91
      ex_dbg_ch2_need_soft,            // 90
      ex_dbg_dm_sel_ch1,               // 89
      ex_dbg_dm_st,                    // 88:87
      ex_dbg_st,                       // 86:84
      udp_wave_state[2:0],             // 83:81
      M_AXI_DM_rresp,                  // 80:79
      M_AXI_WAVE_bresp,                // 78:77
      udp_wave_last_bresp,             // 76:75
      rv_dbg_state,                    // 74:71
      dm_mm2s_sts_tdata[3:0],          // 70:67
      udp_wave_fifo_count[7:0],        // 66:59
      ch1_fifo_level_beats,            // 58:43
      ch2_fifo_level_beats,            // 42:27
      udp_wave_write_count[8:0],       // 26:18
      udp_wave_drop_count[8:0],        // 17:9
      {rfctrl2_trigger_pulse,          // 8
       rfctrl2_arm_pulse,              // 7
       rfctrl2_prepared_ddr,           // 6
       rfctrl2_armed_ddr,              // 5
       rfctrl2_abort_mute_pulse,       // 4
       udp_wave_align_error_count[3:0]} // 3:0
    }),
    .probe1(udp64_rcv_dat),
    .probe2(M_AXI_WAVE_wdata),
    .probe3({
      rv_dbg_state,                    // 127:124
      rv_dbg_status,                   // 123:92
      rv_dbg_last_seq,                 // 91:60
      rv_dbg_last_cmd,                 // 59:28
      rvctrl64_protocol,                // 27:26
      rvctrl64_word_count[6:0],         // 25:19
      rv_dbg_scratch[10:0],             // 18:8
      udp_control_tx_debug             // 7:0
    }),
    .probe4(instr_tdata),
    .probe5(dm_cmd_tdata),
    .probe6(dm_data_tdata),
    .probe7({
      rvresp64_word_count[10:0],       // 127:117
      rvresp64_tlast,                  // 116
      rvresp64_tready,                 // 115
      rvresp64_tvalid,                 // 114
      RV_AXI_RFDC_awvalid,             // 113
      RV_AXI_RFDC_awready,             // 112
      RV_AXI_RFDC_wvalid,              // 111
      RV_AXI_RFDC_wready,              // 110
      RV_AXI_RFDC_bvalid,              // 109
      RV_AXI_RFDC_bready,              // 108
      RV_AXI_RFDC_arvalid,             // 107
      RV_AXI_RFDC_arready,             // 106
      RV_AXI_RFDC_rvalid,              // 105
      RV_AXI_RFDC_rready,              // 104
      RV_AXI_RFDC_bresp,               // 103:102
      RV_AXI_RFDC_rresp,               // 101:100
      RV_AXI_RFDC_awaddr,              // 99:82
      RV_AXI_RFDC_wdata,               // 81:50
      RV_AXI_RFDC_araddr,              // 49:32
      RV_AXI_RFDC_rdata                // 31:0
    }),
    .probe8({rvresp64_tdata, ex_dbg_ch1_bytes_left}),
    .probe9(ch1_wave_tdata),
    .probe10(ch2_wave_tdata),
    .probe11(udp_wave_last_wdata)
  );

  ila_dac_axis u_ila_dac_axis (
    .clk(dac_axis_clk),
    .probe0({
      7'd0,
      rfctrl2_play_prepare,
      rfctrl2_play_trigger,
      rfctrl2_play_abort,
      rfctrl2_prepared_dac,
      rfctrl2_armed_dac,
      pc_done_pulse,
      pc_underflow_seen,
      trig_1_dac_valid_pulse,
      trig_1_dac_valid,
      ps_trigger_dac_sync,
      pc_trig_pulse,
      pc_trig_start,
      pc_started,
      pc_new_cfg,
      cfg_auto_start_dac,
      cfg_rd_ready,
      cfg_rd_valid,
      pc_last_seq_id,
      seq_id_dac,
      ch8_prog_full, ch7_prog_full, ch6_prog_full, ch5_prog_full,
      ch4_prog_full, ch3_prog_full, ch2_prog_full, ch1_prog_full,
      ch8_prog_empty, ch7_prog_empty, ch6_prog_empty, ch5_prog_empty,
      ch4_prog_empty, ch3_prog_empty, ch2_prog_empty, ch1_prog_empty,
      ch8_arm_dac, ch7_arm_dac, ch6_arm_dac, ch5_arm_dac,
      ch4_arm_dac, ch3_arm_dac, ch2_arm_dac, ch1_arm_dac,
      ch8_allow, ch7_allow, ch6_allow, ch5_allow,
      ch4_allow, ch3_allow, ch2_allow, ch1_allow,
      dac_ch8_ready_gated,
      dac_ch7_ready_gated,
      dac_ch6_ready_gated,
      dac_ch5_ready_gated,
      dac_ch4_ready_gated,
      dac_ch3_ready_gated,
      dac_ch2_ready_gated,
      dac_ch1_ready_gated,
      dac_ch8_ready,
      dac_ch7_ready,
      dac_ch6_ready,
      dac_ch5_ready,
      dac_ch4_ready,
      dac_ch3_ready,
      dac_ch2_ready,
      dac_ch1_ready,
      dac_ch8_valid_gated,
      dac_ch7_valid_gated,
      dac_ch6_valid_gated,
      dac_ch5_valid_gated,
      dac_ch4_valid_gated,
      dac_ch3_valid_gated,
      dac_ch2_valid_gated,
      dac_ch1_valid_gated,
      dac_in_ch8_tvalid,
      dac_in_ch7_tvalid,
      dac_in_ch6_tvalid,
      dac_in_ch5_tvalid,
      dac_in_ch4_tvalid,
      dac_in_ch3_tvalid,
      dac_in_ch2_tvalid,
      dac_in_ch1_tvalid,
      dac_rst_n
    }),
    .probe1(dac_in_ch1_tdata),
    .probe2(dac_in_ch2_tdata),
    .probe3(dac_in_ch3_tdata),
    .probe4(dac_in_ch4_tdata),
    .probe5(dac_in_ch5_tdata),
    .probe6(dac_in_ch6_tdata),
    .probe7(dac_in_ch7_tdata),
    .probe8(dac_in_ch8_tdata),
    .probe9({ch1_wr_count, ch2_wr_count, ch3_wr_count, ch4_wr_count,
             ch5_wr_count, ch6_wr_count, ch7_wr_count, ch8_wr_count}),
    .probe10({ch1_len_dac, ch2_len_dac, ch3_len_dac, ch4_len_dac,
              ch5_len_dac, ch6_len_dac, ch7_len_dac, ch8_len_dac}),
    .probe11({pc_ch1_fire_count, pc_ch2_fire_count, pc_ch3_fire_count, pc_ch4_fire_count,
              pc_ch5_fire_count, pc_ch6_fire_count, pc_ch7_fire_count, pc_ch8_fire_count})
  );
endmodule
