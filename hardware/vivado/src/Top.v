module Top (
`ifndef CUSTOM_XCZU47DR
    output [0:0] LED0,
    output [0:0] LED1,

    output [0:0] trigger_out_sma,
    output [0:0] trigger_out_loop,
`endif

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

    // 10MHz external reference clock for HMC7044 (differential)
    input  mclk_10m_p,
    input  mclk_10m_n,

    // 10G SFP+ UDP link, matching the reference project.
    input  sfp_refclkp,
    input  sfp_refclkn,
    input  sfp_rxp,
    input  sfp_rxn,
    output sfp_txp,
    output sfp_txn,
    output SFP_TX_DIS,

`ifndef CUSTOM_XCZU47DR
    input  adc2_clk_clk_n,
    input  adc2_clk_clk_p,
`endif
    input  dac2_clk_clk_n,
    input  dac2_clk_clk_p,
    input  sysref_in_diff_n,
    input  sysref_in_diff_p,
`ifndef CUSTOM_XCZU47DR
    input  adc3_clk_clk_n,
    input  adc3_clk_clk_p,
    input  dac3_clk_clk_n,
    input  dac3_clk_clk_p,
    input  vin20_v_n,
    input  vin20_v_p,
    input  vin22_v_n,
    input  vin22_v_p,
    input  vin30_v_n,
    input  vin30_v_p,
`endif
    output vout20_v_n,
    output vout20_v_p,
    output vout22_v_n,
    output vout22_v_p,
    output vout30_v_n,
    output vout30_v_p,
`ifdef CUSTOM_XCZU47DR
    output vout32_v_n,
    output vout32_v_p,
    output TRIG_1,
`endif

    input           c0_sys_clk_n,
    input           c0_sys_clk_p,
    output          c0_ddr4_act_n,
    output [16:0]   c0_ddr4_adr,
    output [1:0]    c0_ddr4_ba,
    output [0:0]    c0_ddr4_bg,
    output [0:0]    c0_ddr4_ck_c,
    output [0:0]    c0_ddr4_ck_t,
    output [0:0]    c0_ddr4_cke,
`ifdef CUSTOM_XCZU47DR
    output [0:0]    c0_ddr4_cs_n,
    inout  [7:0]    c0_ddr4_dm_n,
    inout  [63:0]   c0_ddr4_dq,
    inout  [7:0]    c0_ddr4_dqs_c,
    inout  [7:0]    c0_ddr4_dqs_t,
`else
    output [1:0]    c0_ddr4_cs_n,
    inout  [3:0]    c0_ddr4_dm_n,
    inout  [31:0]   c0_ddr4_dq,
    inout  [3:0]    c0_ddr4_dqs_c,
    inout  [3:0]    c0_ddr4_dqs_t,
`endif
    output [0:0]    c0_ddr4_odt,
    output          c0_ddr4_reset_n
);

  // ========== clocks / resets from design_1 ==========
  wire        pl_clk;
  wire        pl_aresetn;
  wire        pl_resetn0;
  wire        pl_ps_irq;
  wire        clk_dac2;
  wire        clk_dac3;
  wire        dac_axis_clk;
  wire        rfdc_irq;
  wire        clk104_aresetn;
  wire        ddr4_ui_clk;
  wire        ddr4_ui_aresetn;
  wire        ddr4_ui_clk_sync_rst;

  assign pl_ps_irq = 1'b0;

`ifdef CUSTOM_XCZU47DR
  assign dac_axis_clk = clk_dac2;
`endif
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


  reg  [1:0]  hmc7044_clk_div;
  wire        hmc7044_clk_25m;
  wire        hmc7044_set_finish;
  always @(posedge pl_clk or negedge pl_aresetn) begin
    if (!pl_aresetn) hmc7044_clk_div <= 2'b00;
    else             hmc7044_clk_div <= hmc7044_clk_div + 2'b01;
  end

  assign hmc7044_clk_25m = hmc7044_clk_div[1];

  hmc7044 hmc7044_i (
      .clk(hmc7044_clk_25m),
      .rst(pl_aresetn),
      .H7044_SLEN(H7044_SLEN_0),
      .H7044_SCLK(H7044_SCLK_0),
      .H7044_SDATA(H7044_SDATA_0),
      .SET_FINISH(hmc7044_set_finish)
  );

  assign RESET_H7044_H_0 = 1'b0;
  assign H7044_SYNC_0 = hmc7044_set_finish;

  // ========== PS 指令 AXIS（128-bit） ==========
  wire [127:0] ps_instr_tdata;
  wire         ps_instr_tvalid;
  wire         ps_instr_tready;
  wire [127:0] udp_instr_tdata;
  wire         udp_instr_tvalid;
  wire         udp_instr_tready;
  wire [127:0] instr_tdata;
  wire         instr_tvalid;
  wire         instr_tready;

  assign instr_tdata      = udp_instr_tvalid ? udp_instr_tdata : ps_instr_tdata;
  assign instr_tvalid     = udp_instr_tvalid | ps_instr_tvalid;
  assign udp_instr_tready = udp_instr_tvalid && instr_tready;
  assign ps_instr_tready  = !udp_instr_tvalid && instr_tready;

`ifdef CUSTOM_XCZU47DR
  localparam [63:0] EXT_DDR_ADDR_BASE = 64'h0000_0005_0000_0000;
`else
  localparam [63:0] EXT_DDR_ADDR_BASE = 64'd0;
`endif

  // ========== Reference 10G UDP receiver ==========
  wire        udp64_rcv_vld;
  wire [63:0] udp64_rcv_dat;
  wire        udp64_fifo_af;
  wire        udp_instr64_tvalid;
  wire [63:0] udp_instr64_tdata;

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
  wire [127:0] M_AXI_WAVE_wdata;
  wire         M_AXI_WAVE_wlast;
  wire         M_AXI_WAVE_wready;
  wire [15:0]  M_AXI_WAVE_wstrb;
  wire         M_AXI_WAVE_wvalid;
  wire         M_AXI_WAVE_bready;
  wire [1:0]   M_AXI_WAVE_bresp;
  wire         M_AXI_WAVE_bvalid;

  wire         udp_wave_pkt;
  wire         udp_instr_word;
  wire [2:0]   udp_wave_state;
  wire [31:0]  udp_wave_write_count;
  wire [31:0]  udp_wave_bresp_count;
  wire [31:0]  udp_wave_drop_count;
  wire [15:0]  udp_wave_fifo_count;
  wire [31:0]  udp_wave_resync_count;
  wire [1:0]   udp_wave_last_bresp;
  wire [63:0]  udp_wave_last_addr;
  wire [127:0] udp_wave_last_wdata;

  assign SFP_TX_DIS = 1'b0;

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
      .fifo64_wr   (1'b0),
      .fifo64_din  (64'd0),
      .fifo64_af   (udp64_fifo_af),
      .rcv_vld     (udp64_rcv_vld),
      .rcv_dat     (udp64_rcv_dat),
      .gap_num_vio (24'd0),
      .loop_en     (1'b0)
  );

  udp_waveform_ddr_writer #(
      .DDR_ADDR_BASE(EXT_DDR_ADDR_BASE)
  ) udp_waveform_ddr_writer_i (
      .clk              (ddr4_ui_clk),
      .rst_n            (ddr4_ui_aresetn),
      .udp_tvalid       (udp64_rcv_vld),
      .udp_tdata        (udp64_rcv_dat),
      .instr_tvalid     (udp_instr64_tvalid),
      .instr_tdata      (udp_instr64_tdata),
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

  // ========== DataMover ==========
  wire [103:0] dm_cmd_tdata;
  wire         dm_cmd_tvalid, dm_cmd_tready;
  wire [127:0] dm_data_tdata;
  wire         dm_data_tvalid, dm_data_tready, dm_data_tlast;
  wire         dm_mm2s_err;
  wire         dm_mm2s_sts_tvalid, dm_mm2s_sts_tlast;
  wire [7:0]   dm_mm2s_sts_tdata;
  wire         dm_mm2s_sts_tkeep;

  // ========== executor -> wave FIFO write side (DDR 域) ==========
  wire [127:0] ch1_wave_tdata, ch2_wave_tdata, ch3_wave_tdata, ch4_wave_tdata;
  wire         ch1_wave_tvalid, ch2_wave_tvalid, ch3_wave_tvalid, ch4_wave_tvalid;
  wire         ch1_wave_tready_internal, ch2_wave_tready_internal, ch3_wave_tready_internal, ch4_wave_tready_internal;
  wire [15:0]  ch1_fifo_level_beats;
  wire [15:0]  ch2_fifo_level_beats;
  wire [15:0]  ch3_fifo_level_beats;
  wire [15:0]  ch4_fifo_level_beats;

  // ========== DAC side ready from DAC IP ==========
  wire         dac_ch1_ready, dac_ch2_ready, dac_ch3_ready, dac_ch4_ready;

  // ========== DataMover AXI MM2S to DDR ==========
  wire [63:0]  M_AXI_DM_araddr;
  wire [7:0]   M_AXI_DM_arlen;
  wire [2:0]   M_AXI_DM_arsize;
  wire [1:0]   M_AXI_DM_arburst;
  wire         M_AXI_DM_arready;
  wire         M_AXI_DM_arvalid;
  wire [127:0] M_AXI_DM_rdata;
  wire         M_AXI_DM_rlast;
  wire         M_AXI_DM_rready;
  wire [1:0]   M_AXI_DM_rresp;
  wire         M_AXI_DM_rvalid;

  // ========== GPIO out ==========
  wire [31:0] gpio_out_reg;
  wire ps_trigger_raw = gpio_out_reg[0];

  // ========== trigger CDC ==========
  (* ASYNCHRONOUS_REG="TRUE" *) reg [2:0] trigger_ddr_sync_ff;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) trigger_ddr_sync_ff <= 3'b000;
    else                trigger_ddr_sync_ff <= {trigger_ddr_sync_ff[1:0], ps_trigger_raw};
  end
  wire ps_trigger_ddr_sync = trigger_ddr_sync_ff[2];

  (* ASYNCHRONOUS_REG="TRUE" *) reg [2:0] trigger_dac_sync_ff;
  always @(posedge dac_axis_clk or negedge clk104_aresetn) begin
    if(!clk104_aresetn) trigger_dac_sync_ff <= 3'b000;
    else                trigger_dac_sync_ff <= {trigger_dac_sync_ff[1:0], ps_trigger_raw};
  end
  wire ps_trigger_dac_sync = trigger_dac_sync_ff[2];

`ifndef CUSTOM_XCZU47DR
  assign trigger_out_sma  = ps_trigger_raw;
  assign trigger_out_loop = ps_trigger_raw;
`endif

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
  wire [31:0] ch1_len_beats,   ch2_len_beats,   ch3_len_beats,   ch4_len_beats;
  wire        ch1_arm,         ch2_arm,         ch3_arm,         ch4_arm;
  wire        cfg_auto_start;
  wire        cfg_commit; // 每次 END 提交一帧配置

`ifdef CUSTOM_XCZU47DR
  localparam [15:0] TRIG_1_WIDTH_CYCLES = 16'd300;
  reg [15:0] trig_1_count;

  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) begin
      trig_1_count <= 16'd0;
    end else if(cfg_commit) begin
      trig_1_count <= TRIG_1_WIDTH_CYCLES;
    end else if(trig_1_count != 16'd0) begin
      trig_1_count <= trig_1_count - 16'd1;
    end
  end

  wire trig_1_ddr = (trig_1_count != 16'd0);
  assign TRIG_1 = trig_1_ddr;
`endif

  wire [2:0]  ex_dbg_st;
  wire [1:0]  ex_dbg_dm_st;
  wire        ex_dbg_dm_sel_ch1;
  wire [31:0] ex_dbg_dm_chunk_beats;
  wire [31:0] ex_dbg_dm_beats_sent;
  wire [31:0] ex_dbg_ch1_bytes_left;
  wire [31:0] ex_dbg_ch2_bytes_left;
  wire [63:0] ex_dbg_ch1_base_addr;
  wire [63:0] ex_dbg_ch2_base_addr;
  wire        ex_dbg_ch1_need_hard, ex_dbg_ch2_need_hard;
  wire        ex_dbg_ch1_need_soft, ex_dbg_ch2_need_soft;
  
  wire [127:0] ex_dbg_instr_in_tdata;
  wire         ex_dbg_instr_in_tvalid, ex_dbg_instr_in_tready;
  wire [127:0] ex_dbg_main_tdata;
  wire         ex_dbg_main_tvalid, ex_dbg_main_tready;
  wire         ex_dbg_pending_valid, ex_dbg_active_valid;
  wire [31:0]  ex_dbg_run_delay_cnt;

  // ========== executor ==========
  Waveform_System_Top #(
    .DDR_ADDR_BASE(EXT_DDR_ADDR_BASE)
  ) executor_inst (
    .aclk(ddr4_ui_clk),
    .aresetn(ddr4_ui_aresetn),
    .trigger(ps_trigger_ddr_sync),

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

    .ch1_fifo_level_beats(ch1_fifo_level_beats),
    .ch2_fifo_level_beats(ch2_fifo_level_beats),
    .ch3_fifo_level_beats(ch3_fifo_level_beats),
    .ch4_fifo_level_beats(ch4_fifo_level_beats),

    .m_axis_ch1_tdata(ch1_wave_tdata),
    .m_axis_ch1_tvalid(ch1_wave_tvalid),
    .m_axis_ch2_tdata(ch2_wave_tdata),
    .m_axis_ch2_tvalid(ch2_wave_tvalid),
    .m_axis_ch3_tdata(ch3_wave_tdata),
    .m_axis_ch3_tvalid(ch3_wave_tvalid),
    .m_axis_ch4_tdata(ch4_wave_tdata),
    .m_axis_ch4_tvalid(ch4_wave_tvalid),

    .ch1_delay_cycles(ch1_delay_cycles),
    .ch2_delay_cycles(ch2_delay_cycles),
    .ch3_delay_cycles(ch3_delay_cycles),
    .ch4_delay_cycles(ch4_delay_cycles),
    .ch1_len_beats(ch1_len_beats),
    .ch2_len_beats(ch2_len_beats),
    .ch3_len_beats(ch3_len_beats),
    .ch4_len_beats(ch4_len_beats),
    .ch1_arm(ch1_arm),
    .ch2_arm(ch2_arm),
    .ch3_arm(ch3_arm),
    .ch4_arm(ch4_arm),
    .cfg_auto_start(cfg_auto_start),
    .cfg_commit(cfg_commit),

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
    .dbg_pending_valid  (ex_dbg_pending_valid),
    .dbg_active_valid   (ex_dbg_active_valid),
    .dbg_run_delay_cnt  (ex_dbg_run_delay_cnt)
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

`ifdef CUSTOM_XCZU47DR
  (* ASYNC_REG="TRUE" *) reg [2:0] trig_1_dac_sync_ff;
  reg trig_1_dac_sync_d;

  always @(posedge dac_axis_clk or negedge dac_rst_n) begin
    if(!dac_rst_n) begin
      trig_1_dac_sync_ff <= 3'b000;
      trig_1_dac_sync_d  <= 1'b0;
    end else begin
      trig_1_dac_sync_ff <= {trig_1_dac_sync_ff[1:0], trig_1_ddr};
      trig_1_dac_sync_d  <= trig_1_dac_sync_ff[2];
    end
  end

  wire trig_1_dac_sync  = trig_1_dac_sync_ff[2];
  wire trig_1_dac_pulse = trig_1_dac_sync & ~trig_1_dac_sync_d;
`else
  wire trig_1_dac_sync  = 1'b0;
  wire trig_1_dac_pulse = 1'b0;
`endif

  // ==========================================================
  // DDR 域：配置帧（160-bit）打包，commit 时写入 cfg FIFO
  // 关键修复：写入 FIFO 的 seq_id 使用 seq_id_next，避免第一帧=0 导致 DAC gating 卡死
  // ==========================================================
  reg [15:0] seq_id;
  wire [15:0] seq_id_next = seq_id + 16'd1;
  reg         cfg_wr_pending;
  reg [287:0] cfg_wr_payload;
  wire [287:0] cfg_payload_next = {
      ch1_delay_cycles,
      ch2_delay_cycles,
      ch3_delay_cycles,
      ch4_delay_cycles,
      ch1_len_beats,
      ch2_len_beats,
      ch3_len_beats,
      ch4_len_beats,
      11'd0,
      cfg_auto_start,
      ch1_arm,
      ch2_arm,
      ch3_arm,
      ch4_arm,
      seq_id_next
  };

  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) begin
      seq_id <= 16'd0;
      cfg_wr_pending <= 1'b0;
      cfg_wr_payload <= 288'd0;
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
  wire [287:0] cfg_rd_data;
  wire         cfg_rd_valid;
  reg          cfg_rd_ready;

  cfg_cdc_fifo_xpm #(
    .W(288),
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
  reg [31:0] ch1_len_dac, ch2_len_dac, ch3_len_dac, ch4_len_dac;
  reg        cfg_auto_start_dac;
  reg        ch1_arm_dac, ch2_arm_dac, ch3_arm_dac, ch4_arm_dac;
  reg [15:0] seq_id_dac;

  // The executor counts 128-bit DataMover/FIFO beats. RFDC S_AXIS_20/22 are
  // 64-bit AXIS ports, so the DAC gate must count twice as many output beats.
  wire [31:0] ch1_len_dac64 = {ch1_len_dac[30:0], 1'b0};
  wire [31:0] ch2_len_dac64 = {ch2_len_dac[30:0], 1'b0};
  wire [31:0] ch3_len_dac64 = {ch3_len_dac[30:0], 1'b0};
  wire [31:0] ch4_len_dac64 = {ch4_len_dac[30:0], 1'b0};

  always @(posedge dac_axis_clk or negedge dac_rst_n) begin
    if(!dac_rst_n) begin
      cfg_rd_ready  <= 1'b0;
      ch1_delay_dac <= 0; ch2_delay_dac <= 0; ch3_delay_dac <= 0; ch4_delay_dac <= 0;
      ch1_len_dac   <= 0; ch2_len_dac   <= 0; ch3_len_dac <= 0; ch4_len_dac <= 0;
      cfg_auto_start_dac <= 0;
      ch1_arm_dac   <= 0; ch2_arm_dac   <= 0; ch3_arm_dac <= 0; ch4_arm_dac <= 0;
      seq_id_dac    <= 0;
    end else begin
      cfg_rd_ready <= 1'b1; // 简化：一直准备接收

      if(cfg_rd_valid && cfg_rd_ready) begin
        ch1_delay_dac <= cfg_rd_data[287:256];
        ch2_delay_dac <= cfg_rd_data[255:224];
        ch3_delay_dac <= cfg_rd_data[223:192];
        ch4_delay_dac <= cfg_rd_data[191:160];
        ch1_len_dac   <= cfg_rd_data[159:128];
        ch2_len_dac   <= cfg_rd_data[127:96];
        ch3_len_dac   <= cfg_rd_data[95:64];
        ch4_len_dac   <= cfg_rd_data[63:32];
        cfg_auto_start_dac <= cfg_rd_data[20];
        ch1_arm_dac   <= cfg_rd_data[19];
        ch2_arm_dac   <= cfg_rd_data[18];
        ch3_arm_dac   <= cfg_rd_data[17];
        ch4_arm_dac   <= cfg_rd_data[16];
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
    .m_axis_mm2s_tvalid(dm_data_tvalid),
    .m_axis_mm2s_tready(dm_data_tready),
    .m_axis_mm2s_tlast (dm_data_tlast),

    .m_axi_mm2s_araddr (M_AXI_DM_araddr),
    .m_axi_mm2s_arlen  (M_AXI_DM_arlen),
    .m_axi_mm2s_arsize (M_AXI_DM_arsize),
    .m_axi_mm2s_arburst(M_AXI_DM_arburst),
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
  // Wave async FIFO (DDR 128-bit AXIS -> DAC 64-bit RFDC AXIS)
  // ==========================================================
  wire [127:0] dac_fifo_ch1_tdata, dac_fifo_ch2_tdata, dac_fifo_ch3_tdata, dac_fifo_ch4_tdata;
  wire         dac_fifo_ch1_tvalid, dac_fifo_ch2_tvalid, dac_fifo_ch3_tvalid, dac_fifo_ch4_tvalid;
  wire         dac_fifo_ch1_tready, dac_fifo_ch2_tready, dac_fifo_ch3_tready, dac_fifo_ch4_tready;
  wire [63:0]  dac_in_ch1_tdata, dac_in_ch2_tdata, dac_in_ch3_tdata, dac_in_ch4_tdata;
  wire         dac_in_ch1_tvalid, dac_in_ch2_tvalid, dac_in_ch3_tvalid, dac_in_ch4_tvalid;
  wire         dac_ch1_ready_gated, dac_ch2_ready_gated, dac_ch3_ready_gated, dac_ch4_ready_gated;
  wire         dac_ch1_valid_gated, dac_ch2_valid_gated, dac_ch3_valid_gated, dac_ch4_valid_gated;

  wire ch1_allow, ch2_allow, ch3_allow, ch4_allow;
  wire ch1_prog_empty, ch1_prog_full;
  wire ch2_prog_empty, ch2_prog_full;
  wire ch3_prog_empty, ch3_prog_full;
  wire ch4_prog_empty, ch4_prog_full;

  // ===== NEW: play_ctrl debug wires (接 ILA 用) =====
  wire        pc_trig_pulse, pc_new_cfg, pc_trig_start, pc_started;
  wire [15:0] pc_last_seq_id;

  dac_play_ctrl #(
    .BEAT_BYTES(16)
  ) u_play_ctrl (
    .clk(dac_axis_clk),
    .rst_n(dac_rst_n),
    .trigger(ps_trigger_dac_sync),

    .cfg_seq_id(seq_id_dac),
    .auto_start(cfg_auto_start_dac),

    .ch1_delay_cycles(ch1_delay_dac),
    .ch2_delay_cycles(ch2_delay_dac),
    .ch3_delay_cycles(ch3_delay_dac),
    .ch4_delay_cycles(ch4_delay_dac),
    .ch1_len_beats(ch1_len_dac64),
    .ch2_len_beats(ch2_len_dac64),
    .ch3_len_beats(ch3_len_dac64),
    .ch4_len_beats(ch4_len_dac64),
    .ch1_arm(ch1_arm_dac),
    .ch2_arm(ch2_arm_dac),
    .ch3_arm(ch3_arm_dac),
    .ch4_arm(ch4_arm_dac),

    .ch1_fifo_tvalid(dac_in_ch1_tvalid),
    .ch2_fifo_tvalid(dac_in_ch2_tvalid),
    .ch3_fifo_tvalid(dac_in_ch3_tvalid),
    .ch4_fifo_tvalid(dac_in_ch4_tvalid),
    .ch1_fifo_prog_empty(ch1_prog_empty),
    .ch2_fifo_prog_empty(ch2_prog_empty),
    .ch3_fifo_prog_empty(ch3_prog_empty),
    .ch4_fifo_prog_empty(ch4_prog_empty),

    .dac_ch1_ready_in(dac_ch1_ready),
    .dac_ch2_ready_in(dac_ch2_ready),
    .dac_ch3_ready_in(dac_ch3_ready),
    .dac_ch4_ready_in(dac_ch4_ready),

    .ch1_allow(ch1_allow),
    .ch2_allow(ch2_allow),
    .ch3_allow(ch3_allow),
    .ch4_allow(ch4_allow),

    .ch1_active(),
    .ch2_active(),
    .ch3_active(),
    .ch4_active(),

    .dbg_trig_pulse (pc_trig_pulse),
    .dbg_new_cfg    (pc_new_cfg),
    .dbg_trig_start (pc_trig_start),
    .dbg_started    (pc_started),
    .dbg_last_seq_id(pc_last_seq_id)
  );

  wire [31:0] ch1_wr_count, ch2_wr_count, ch3_wr_count, ch4_wr_count;

  assign ch1_fifo_level_beats = ch1_wr_count[15:0];
  assign ch2_fifo_level_beats = ch2_wr_count[15:0];
  assign ch3_fifo_level_beats = ch3_wr_count[15:0];
  assign ch4_fifo_level_beats = ch4_wr_count[15:0];

  wire ch1_wave_tlast = 1'b0;
  wire ch2_wave_tlast = 1'b0;
  wire ch3_wave_tlast = 1'b0;
  wire ch4_wave_tlast = 1'b0;
  wire dac_out_ch1_tlast, dac_out_ch2_tlast, dac_out_ch3_tlast, dac_out_ch4_tlast;

  assign dac_ch1_ready_gated = dac_ch1_ready & ch1_allow;
  assign dac_ch2_ready_gated = dac_ch2_ready & ch2_allow;
  assign dac_ch3_ready_gated = dac_ch3_ready & ch3_allow;
  assign dac_ch4_ready_gated = dac_ch4_ready & ch4_allow;
  assign dac_ch1_valid_gated = dac_in_ch1_tvalid & ch1_allow;
  assign dac_ch2_valid_gated = dac_in_ch2_tvalid & ch2_allow;
  assign dac_ch3_valid_gated = dac_in_ch3_tvalid & ch3_allow;
  assign dac_ch4_valid_gated = dac_in_ch4_tvalid & ch4_allow;

  axis_async_fifo_128 fifo_ch1_inst (
    .s_axis_aresetn(ddr4_ui_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch1_wave_tvalid),
    .s_axis_tready (ch1_wave_tready_internal),
    .s_axis_tdata  (ch1_wave_tdata),
    .s_axis_tlast  (ch1_wave_tlast),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_fifo_ch1_tvalid),
    .m_axis_tready (dac_fifo_ch1_tready),
    .m_axis_tdata  (dac_fifo_ch1_tdata),
    .m_axis_tlast  (dac_out_ch1_tlast),

    .axis_wr_data_count(ch1_wr_count),
    .prog_empty        (ch1_prog_empty),
    .prog_full         (ch1_prog_full)
  );

  axis_async_fifo_128 fifo_ch2_inst (
    .s_axis_aresetn(ddr4_ui_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch2_wave_tvalid),
    .s_axis_tready (ch2_wave_tready_internal),
    .s_axis_tdata  (ch2_wave_tdata),
    .s_axis_tlast  (ch2_wave_tlast),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_fifo_ch2_tvalid),
    .m_axis_tready (dac_fifo_ch2_tready),
    .m_axis_tdata  (dac_fifo_ch2_tdata),
    .m_axis_tlast  (dac_out_ch2_tlast),

    .axis_wr_data_count(ch2_wr_count),
    .prog_empty        (ch2_prog_empty),
    .prog_full         (ch2_prog_full)
  );


  axis_async_fifo_128 fifo_ch3_inst (
    .s_axis_aresetn(ddr4_ui_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch3_wave_tvalid),
    .s_axis_tready (ch3_wave_tready_internal),
    .s_axis_tdata  (ch3_wave_tdata),
    .s_axis_tlast  (ch3_wave_tlast),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_fifo_ch3_tvalid),
    .m_axis_tready (dac_fifo_ch3_tready),
    .m_axis_tdata  (dac_fifo_ch3_tdata),
    .m_axis_tlast  (dac_out_ch3_tlast),

    .axis_wr_data_count(ch3_wr_count),
    .prog_empty        (ch3_prog_empty),
    .prog_full         (ch3_prog_full)
  );

  axis_async_fifo_128 fifo_ch4_inst (
    .s_axis_aresetn(ddr4_ui_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch4_wave_tvalid),
    .s_axis_tready (ch4_wave_tready_internal),
    .s_axis_tdata  (ch4_wave_tdata),
    .s_axis_tlast  (ch4_wave_tlast),

    .m_axis_aclk   (dac_axis_clk),
    .m_axis_tvalid (dac_fifo_ch4_tvalid),
    .m_axis_tready (dac_fifo_ch4_tready),
    .m_axis_tdata  (dac_fifo_ch4_tdata),
    .m_axis_tlast  (dac_out_ch4_tlast),

    .axis_wr_data_count(ch4_wr_count),
    .prog_empty        (ch4_prog_empty),
    .prog_full         (ch4_prog_full)
  );

  axis_128_to_64 dac_ch1_width_i (
    .clk      (dac_axis_clk),
    .rst_n    (dac_rst_n),
    .s_tdata  (dac_fifo_ch1_tdata),
    .s_tvalid (dac_fifo_ch1_tvalid),
    .s_tready (dac_fifo_ch1_tready),
    .m_tdata  (dac_in_ch1_tdata),
    .m_tvalid (dac_in_ch1_tvalid),
    .m_tready (dac_ch1_ready_gated)
  );

  axis_128_to_64 dac_ch2_width_i (
    .clk      (dac_axis_clk),
    .rst_n    (dac_rst_n),
    .s_tdata  (dac_fifo_ch2_tdata),
    .s_tvalid (dac_fifo_ch2_tvalid),
    .s_tready (dac_fifo_ch2_tready),
    .m_tdata  (dac_in_ch2_tdata),
    .m_tvalid (dac_in_ch2_tvalid),
    .m_tready (dac_ch2_ready_gated)
  );


  axis_128_to_64 dac_ch3_width_i (
    .clk      (dac_axis_clk),
    .rst_n    (dac_rst_n),
    .s_tdata  (dac_fifo_ch3_tdata),
    .s_tvalid (dac_fifo_ch3_tvalid),
    .s_tready (dac_fifo_ch3_tready),
    .m_tdata  (dac_in_ch3_tdata),
    .m_tvalid (dac_in_ch3_tvalid),
    .m_tready (dac_ch3_ready_gated)
  );

  axis_128_to_64 dac_ch4_width_i (
    .clk      (dac_axis_clk),
    .rst_n    (dac_rst_n),
    .s_tdata  (dac_fifo_ch4_tdata),
    .s_tvalid (dac_fifo_ch4_tvalid),
    .s_tready (dac_fifo_ch4_tready),
    .m_tdata  (dac_in_ch4_tdata),
    .m_tvalid (dac_in_ch4_tvalid),
    .m_tready (dac_ch4_ready_gated)
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

`ifdef CUSTOM_XCZU47DR
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

  wire [34:0]  M_AXI_DDR4_araddr;
  wire [1:0]   M_AXI_DDR4_arburst;
  wire [3:0]   M_AXI_DDR4_arcache;
  wire [7:0]   M_AXI_DDR4_arlen;
  wire [0:0]   M_AXI_DDR4_arlock;
  wire [2:0]   M_AXI_DDR4_arprot;
  wire [3:0]   M_AXI_DDR4_arqos;
  wire         M_AXI_DDR4_arready;
  wire [2:0]   M_AXI_DDR4_arsize;
  wire         M_AXI_DDR4_arvalid;

  wire [34:0]  M_AXI_DDR4_awaddr;
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
`endif

  design_1 design_1_i (
      .pl_clk(pl_clk),
      .pl_aresetn(pl_aresetn),
      .pl_resetn0(pl_resetn0),
      .pl_ps_irq(pl_ps_irq),
`ifndef CUSTOM_XCZU47DR
      .clk_dac2(clk_dac2),
      .dac_axis_clk(dac_axis_clk),
`endif
`ifndef CUSTOM_XCZU47DR
      .clk104_aresetn(clk104_aresetn),
`endif
      .ddr4_ui_clk(ddr4_ui_clk),
`ifndef CUSTOM_XCZU47DR
      .ddr4_ui_aresetn(ddr4_ui_aresetn),
`endif
`ifndef CUSTOM_XCZU47DR
      .ddr4_ui_clk_sync_rst(ddr4_ui_clk_sync_rst),
`endif

`ifndef CUSTOM_XCZU47DR
      .adc2_clk_clk_n(adc2_clk_clk_n),
      .adc2_clk_clk_p(adc2_clk_clk_p),
`endif
`ifndef CUSTOM_XCZU47DR
      .dac2_clk_clk_n(dac2_clk_clk_n),
      .dac2_clk_clk_p(dac2_clk_clk_p),
      .sysref_in_diff_n(sysref_in_diff_n),
      .sysref_in_diff_p(sysref_in_diff_p),
`endif
`ifndef CUSTOM_XCZU47DR
       .adc3_clk_clk_n(adc3_clk_clk_n),
      .adc3_clk_clk_p(adc3_clk_clk_p),
      .dac3_clk_clk_n(dac3_clk_clk_n),
      .dac3_clk_clk_p(dac3_clk_clk_p),

      .vin20_v_n(vin20_v_n),
      .vin20_v_p(vin20_v_p),
      .vin22_v_n(vin22_v_n),
      .vin22_v_p(vin22_v_p),
      .vin30_v_n(vin30_v_n),
      .vin30_v_p(vin30_v_p),
`endif
`ifndef CUSTOM_XCZU47DR
      .vout20_v_n(vout20_v_n),
      .vout20_v_p(vout20_v_p),
      .vout22_v_n(vout22_v_n),
      .vout22_v_p(vout22_v_p),
      .vout30_v_n(vout30_v_n),
      .vout30_v_p(vout30_v_p),
`endif

`ifndef CUSTOM_XCZU47DR
      .c0_sys_clk_n(c0_sys_clk_n),
      .c0_sys_clk_p(c0_sys_clk_p),
      .c0_ddr4_act_n(c0_ddr4_act_n),
      .c0_ddr4_adr(c0_ddr4_adr),
      .c0_ddr4_ba(c0_ddr4_ba),
      .c0_ddr4_bg(c0_ddr4_bg),
      .c0_ddr4_ck_c(c0_ddr4_ck_c),
      .c0_ddr4_ck_t(c0_ddr4_ck_t),
      .c0_ddr4_cke(c0_ddr4_cke),
      .c0_ddr4_cs_n(c0_ddr4_cs_n),
      .c0_ddr4_dm_n(c0_ddr4_dm_n),
      .c0_ddr4_dq(c0_ddr4_dq),
      .c0_ddr4_dqs_c(c0_ddr4_dqs_c),
      .c0_ddr4_dqs_t(c0_ddr4_dqs_t),
      .c0_ddr4_odt(c0_ddr4_odt),
      .c0_ddr4_reset_n(c0_ddr4_reset_n),
`endif

`ifndef CUSTOM_XCZU47DR
      // DDR AXI slave for DataMover read (S_AXI_01)
      .S_AXI_01_araddr(M_AXI_DM_araddr),
      .S_AXI_01_arburst(M_AXI_DM_arburst),
      .S_AXI_01_arcache(4'b0011),
      .S_AXI_01_arlen(M_AXI_DM_arlen),
      .S_AXI_01_arlock(1'b0),
      .S_AXI_01_arprot(3'b000),
      .S_AXI_01_arqos(4'b0000),
      .S_AXI_01_arready(M_AXI_DM_arready),
      .S_AXI_01_arsize(M_AXI_DM_arsize),
      .S_AXI_01_arvalid(M_AXI_DM_arvalid),
      .S_AXI_01_rdata(M_AXI_DM_rdata),
      .S_AXI_01_rlast(M_AXI_DM_rlast),
      .S_AXI_01_rready(M_AXI_DM_rready),
      .S_AXI_01_rresp(M_AXI_DM_rresp),
      .S_AXI_01_rvalid(M_AXI_DM_rvalid),

      .S_AXI_01_awaddr(M_AXI_WAVE_awaddr),
      .S_AXI_01_awburst(M_AXI_WAVE_awburst),
      .S_AXI_01_awcache(M_AXI_WAVE_awcache),
      .S_AXI_01_awlen(M_AXI_WAVE_awlen),
      .S_AXI_01_awlock(M_AXI_WAVE_awlock),
      .S_AXI_01_awprot(M_AXI_WAVE_awprot),
      .S_AXI_01_awqos(M_AXI_WAVE_awqos),
      .S_AXI_01_awready(M_AXI_WAVE_awready),
      .S_AXI_01_awsize(M_AXI_WAVE_awsize),
      .S_AXI_01_awvalid(M_AXI_WAVE_awvalid),
      .S_AXI_01_wdata(M_AXI_WAVE_wdata),
      .S_AXI_01_wlast(M_AXI_WAVE_wlast),
      .S_AXI_01_wready(M_AXI_WAVE_wready),
      .S_AXI_01_wstrb(M_AXI_WAVE_wstrb),
      .S_AXI_01_wvalid(M_AXI_WAVE_wvalid),
      .S_AXI_01_bready(M_AXI_WAVE_bready),
      .S_AXI_01_bresp(M_AXI_WAVE_bresp),
      .S_AXI_01_bvalid(M_AXI_WAVE_bvalid),
`endif

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

`ifdef CUSTOM_XCZU47DR
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
`endif

`ifndef CUSTOM_XCZU47DR
      .S_AXIS_20_tdata(dac_in_ch1_tdata),
      .S_AXIS_20_tvalid(dac_ch1_valid_gated),
      .S_AXIS_20_tready(dac_ch1_ready),

      .S_AXIS_22_tdata(dac_in_ch2_tdata),
      .S_AXIS_22_tvalid(dac_ch2_valid_gated),
      .S_AXIS_22_tready(dac_ch2_ready),

      .S_AXIS_30_tdata(dac_in_ch3_tdata),
      .S_AXIS_30_tvalid(dac_ch3_valid_gated),
      .S_AXIS_30_tready(dac_ch3_ready),
`endif

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

`ifdef CUSTOM_XCZU47DR
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

      .S_AXI_PL_araddr(M_AXI_DM_araddr),
      .S_AXI_PL_arburst(M_AXI_DM_arburst),
      .S_AXI_PL_arcache(4'b0011),
      .S_AXI_PL_arlen(M_AXI_DM_arlen),
      .S_AXI_PL_arlock(1'b0),
      .S_AXI_PL_arprot(3'b000),
      .S_AXI_PL_arqos(4'b0000),
      .S_AXI_PL_arready(M_AXI_DM_arready),
      .S_AXI_PL_arsize(M_AXI_DM_arsize),
      .S_AXI_PL_arvalid(M_AXI_DM_arvalid),
      .S_AXI_PL_rdata(M_AXI_DM_rdata),
      .S_AXI_PL_rlast(M_AXI_DM_rlast),
      .S_AXI_PL_rready(M_AXI_DM_rready),
      .S_AXI_PL_rresp(M_AXI_DM_rresp),
      .S_AXI_PL_rvalid(M_AXI_DM_rvalid),
      .S_AXI_PL_awaddr(M_AXI_WAVE_awaddr),
      .S_AXI_PL_awburst(M_AXI_WAVE_awburst),
      .S_AXI_PL_awcache(M_AXI_WAVE_awcache),
      .S_AXI_PL_awlen(M_AXI_WAVE_awlen),
      .S_AXI_PL_awlock(M_AXI_WAVE_awlock),
      .S_AXI_PL_awprot(M_AXI_WAVE_awprot),
      .S_AXI_PL_awqos(M_AXI_WAVE_awqos),
      .S_AXI_PL_awready(M_AXI_WAVE_awready),
      .S_AXI_PL_awsize(M_AXI_WAVE_awsize),
      .S_AXI_PL_awvalid(M_AXI_WAVE_awvalid),
      .S_AXI_PL_wdata(M_AXI_WAVE_wdata),
      .S_AXI_PL_wlast(M_AXI_WAVE_wlast),
      .S_AXI_PL_wready(M_AXI_WAVE_wready),
      .S_AXI_PL_wstrb(M_AXI_WAVE_wstrb),
      .S_AXI_PL_wvalid(M_AXI_WAVE_wvalid),
      .S_AXI_PL_bready(M_AXI_WAVE_bready),
      .S_AXI_PL_bresp(M_AXI_WAVE_bresp),
      .S_AXI_PL_bvalid(M_AXI_WAVE_bvalid),

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
      .s_axi_awaddr(M_AXI_RFDC_awaddr),
      .s_axi_awvalid(M_AXI_RFDC_awvalid),
      .s_axi_awready(M_AXI_RFDC_awready),
      .s_axi_wdata(M_AXI_RFDC_wdata),
      .s_axi_wstrb(M_AXI_RFDC_wstrb),
      .s_axi_wvalid(M_AXI_RFDC_wvalid),
      .s_axi_wready(M_AXI_RFDC_wready),
      .s_axi_bresp(M_AXI_RFDC_bresp),
      .s_axi_bvalid(M_AXI_RFDC_bvalid),
      .s_axi_bready(M_AXI_RFDC_bready),
      .s_axi_araddr(M_AXI_RFDC_araddr),
      .s_axi_arvalid(M_AXI_RFDC_arvalid),
      .s_axi_arready(M_AXI_RFDC_arready),
      .s_axi_rdata(M_AXI_RFDC_rdata),
      .s_axi_rresp(M_AXI_RFDC_rresp),
      .s_axi_rvalid(M_AXI_RFDC_rvalid),
      .s_axi_rready(M_AXI_RFDC_rready),
      .sysref_in_p(sysref_in_diff_p),
      .sysref_in_n(sysref_in_diff_n),
      .dac2_clk_p(dac2_clk_clk_p),
      .dac2_clk_n(dac2_clk_clk_n),
      .clk_dac2(clk_dac2),
      .s2_axis_aclk(dac_axis_clk),
      .s2_axis_aresetn(clk104_aresetn),
      .clk_dac3(clk_dac3),
      .s3_axis_aclk(dac_axis_clk),
      .s3_axis_aresetn(clk104_aresetn),
      .vout20_p(vout20_v_p),
      .vout20_n(vout20_v_n),
      .vout22_p(vout22_v_p),
      .vout22_n(vout22_v_n),
      .vout30_p(vout30_v_p),
      .vout30_n(vout30_v_n),
      .vout32_p(vout32_v_p),
      .vout32_n(vout32_v_n),
      .s20_axis_tdata(dac_in_ch1_tdata),
      .s20_axis_tvalid(dac_ch1_valid_gated),
      .s20_axis_tready(dac_ch1_ready),
      .s22_axis_tdata(dac_in_ch2_tdata),
      .s22_axis_tvalid(dac_ch2_valid_gated),
      .s22_axis_tready(dac_ch2_ready),
      .s30_axis_tdata(dac_in_ch3_tdata),
      .s30_axis_tvalid(dac_ch3_valid_gated),
      .s30_axis_tready(dac_ch3_ready),
      .s32_axis_tdata(dac_in_ch4_tdata),
      .s32_axis_tvalid(dac_ch4_valid_gated),
      .s32_axis_tready(dac_ch4_ready),
      .irq(rfdc_irq)
  );
`endif

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

  assign M_AXI_GPIO_rdata = axigpio_rdata | {hmc7044_set_finish, 31'b0};


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
      instr_tvalid,                    // 120
      instr_tready,                    // 119
      cfg_commit,                      // 118
      dm_cmd_tvalid,                   // 117
      dm_cmd_tready,                   // 116
      dm_data_tvalid,                  // 115
      dm_data_tready,                  // 114
      dm_data_tlast,                   // 113
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
      dm_mm2s_sts_tvalid,              // 102
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
      udp_wave_state,                  // 83:81
      M_AXI_DM_rresp,                  // 80:79
      M_AXI_WAVE_bresp,                // 78:77
      udp_wave_last_bresp,             // 76:75
      dm_mm2s_sts_tdata,               // 74:67
      udp_wave_fifo_count,             // 66:51
      ch1_fifo_level_beats,            // 50:35
      ch2_fifo_level_beats,            // 34:19
      udp_wave_write_count[9:0],       // 18:9
      udp_wave_drop_count[8:0]         // 8:0
    }),
    .probe1(udp64_rcv_dat),
    .probe2(M_AXI_WAVE_wdata),
    .probe3({24'd0, dm_cmd_tdata}),
    .probe4(instr_tdata),
    .probe5(dm_cmd_tdata),
    .probe6(dm_data_tdata),
    .probe7({ex_dbg_ch1_base_addr, ex_dbg_ch2_base_addr}),
    .probe8({ex_dbg_ch1_bytes_left, ex_dbg_ch2_bytes_left, ex_dbg_dm_chunk_beats, ex_dbg_dm_beats_sent}),
    .probe9(ch1_wave_tdata),
    .probe10(ch2_wave_tdata),
    .probe11(udp_wave_last_wdata)
  );

  ila_dac_axis u_ila_dac_axis (
    .clk(dac_axis_clk),
    .probe0({
      25'd0,
      trig_1_dac_pulse,
      trig_1_dac_sync,
      ch4_prog_full,
      ch3_prog_full,
      ch2_prog_full,
      ch1_prog_full,
      ch4_prog_empty,
      ch3_prog_empty,
      ch2_prog_empty,
      ch1_prog_empty,
      cfg_rd_ready,
      cfg_rd_valid,
      pc_new_cfg,
      ch4_allow,
      ch3_allow,
      ch2_len_dac64[13:0],
      ch1_len_dac64[13:0],
      pc_last_seq_id,
      seq_id_dac,
      ch4_arm_dac,
      ch3_arm_dac,
      ch2_arm_dac,
      ch1_arm_dac,
      pc_started,
      pc_trig_start,
      cfg_auto_start_dac,
      pc_trig_pulse,
      ch2_allow,
      ch1_allow,
      dac_ch4_ready_gated,
      dac_ch3_ready_gated,
      dac_ch2_ready_gated,
      dac_ch1_ready_gated,
      dac_ch4_ready,
      dac_ch3_ready,
      dac_ch2_ready,
      dac_ch1_ready,
      dac_ch4_valid_gated,
      dac_ch3_valid_gated,
      dac_ch2_valid_gated,
      dac_ch1_valid_gated,
      dac_in_ch4_tvalid,
      dac_in_ch3_tvalid,
      dac_in_ch2_tvalid,
      dac_in_ch1_tvalid,
      ps_trigger_dac_sync,
      dac_rst_n
    }),
    .probe1({dac_in_ch2_tdata, dac_in_ch1_tdata}),
    .probe2({dac_in_ch4_tdata, dac_in_ch3_tdata}),
    .probe3(cfg_rd_data[127:0]),
    .probe4({ch1_wr_count, ch2_wr_count, ch3_wr_count, ch4_wr_count}),
    .probe5({ch1_delay_dac, ch2_delay_dac, ch3_delay_dac, ch4_delay_dac})
  );
endmodule
