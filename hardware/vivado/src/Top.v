module Top (
    output [0:0] LED0,
    output [0:0] LED1,
    output [1:0] clk104_clk_spi_mux_sel_tri_o,

    output [0:0] trigger_out_sma,
    output [0:0] trigger_out_loop,
    input  [0:0] trigger_in,

    input  adc2_clk_clk_n,
    input  adc2_clk_clk_p,
    input  dac2_clk_clk_n,
    input  dac2_clk_clk_p,
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
    output vout20_v_n,
    output vout20_v_p,
    output vout22_v_n,
    output vout22_v_p,
    output vout30_v_n,
    output vout30_v_p,

    input           c0_sys_clk_n,
    input           c0_sys_clk_p,
    output          c0_ddr4_act_n,
    output [16:0]   c0_ddr4_adr,
    output [1:0]    c0_ddr4_ba,
    output [1:0]    c0_ddr4_bg,
    output [0:0]    c0_ddr4_ck_c,
    output [0:0]    c0_ddr4_ck_t,
    output [0:0]    c0_ddr4_cke,
    output [1:0]    c0_ddr4_cs_n,
    inout  [3:0]    c0_ddr4_dm_n,
    inout  [31:0]   c0_ddr4_dq,
    inout  [3:0]    c0_ddr4_dqs_c,
    inout  [3:0]    c0_ddr4_dqs_t,
    output [0:0]    c0_ddr4_odt,
    output          c0_ddr4_reset_n
);

  // ========== clocks / resets from design_1 ==========
  wire        pl_clk;
  wire        pl_aresetn;
  wire        pl_ps_irq;
  wire        clk_adc2;
  wire        clk_dac2;
  wire        clk104_aresetn;
  wire        ddr4_ui_clk;
  wire        ddr4_ui_aresetn;

  // ========== PS 指令 AXIS（128-bit） ==========
  wire [127:0] ps_instr_tdata;
  wire         ps_instr_tvalid;
  wire         ps_instr_tready;

  // ========== DataMover ==========
  wire [103:0] dm_cmd_tdata;
  wire         dm_cmd_tvalid, dm_cmd_tready;
  wire [127:0] dm_data_tdata;
  wire         dm_data_tvalid, dm_data_tready, dm_data_tlast;

  // ========== executor -> wave FIFO write side (DDR 域) ==========
  wire [127:0] ch1_wave_tdata, ch2_wave_tdata;
  wire         ch1_wave_tvalid, ch2_wave_tvalid;
  wire         ch1_wave_tready_internal, ch2_wave_tready_internal;
  wire [15:0]  ch1_fifo_level_beats;
  wire [15:0]  ch2_fifo_level_beats;

  // ========== DAC side ready from DAC IP ==========
  wire         dac_ch1_ready, dac_ch2_ready;

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
  always @(posedge clk_dac2 or negedge clk104_aresetn) begin
    if(!clk104_aresetn) trigger_dac_sync_ff <= 3'b000;
    else                trigger_dac_sync_ff <= {trigger_dac_sync_ff[1:0], ps_trigger_raw};
  end
  wire ps_trigger_dac_sync = trigger_dac_sync_ff[2];

  assign trigger_out_sma  = ps_trigger_raw;
  assign trigger_out_loop = ps_trigger_raw;

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
      .s_axi_arvalid (M_AXI_INST_arvalid),
      .s_axi_arready (M_AXI_INST_arready),
      .s_axi_rdata   (M_AXI_INST_rdata),
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
  wire [31:0] ch1_delay_cycles, ch2_delay_cycles;
  wire [31:0] ch1_len_beats,   ch2_len_beats;
  wire        ch1_arm,         ch2_arm;
  wire        cfg_commit; // 每次 END 提交一帧配置

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
  Waveform_System_Top executor_inst (
    .aclk(ddr4_ui_clk),
    .aresetn(ddr4_ui_aresetn),
    .trigger(ps_trigger_ddr_sync),

    .s_axis_instr_tdata(ps_instr_tdata),
    .s_axis_instr_tvalid(ps_instr_tvalid),
    .s_axis_instr_tready(ps_instr_tready),

    .m_axis_dm_cmd_tdata(dm_cmd_tdata),
    .m_axis_dm_cmd_tvalid(dm_cmd_tvalid),
    .m_axis_dm_cmd_tready(dm_cmd_tready),

    .s_axis_dm_data_tdata(dm_data_tdata),
    .s_axis_dm_data_tvalid(dm_data_tvalid),
    .s_axis_dm_data_tready(dm_data_tready),

    .ch1_fifo_ready(ch1_wave_tready_internal),
    .ch2_fifo_ready(ch2_wave_tready_internal),

    .ch1_fifo_level_beats(ch1_fifo_level_beats),
    .ch2_fifo_level_beats(ch2_fifo_level_beats),

    .m_axis_ch1_tdata(ch1_wave_tdata),
    .m_axis_ch1_tvalid(ch1_wave_tvalid),
    .m_axis_ch2_tdata(ch2_wave_tdata),
    .m_axis_ch2_tvalid(ch2_wave_tvalid),

    .ch1_delay_cycles(ch1_delay_cycles),
    .ch2_delay_cycles(ch2_delay_cycles),
    .ch1_len_beats(ch1_len_beats),
    .ch2_len_beats(ch2_len_beats),
    .ch1_arm(ch1_arm),
    .ch2_arm(ch2_arm),
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
  // DAC 域 reset（统一）—— 用 clk104_aresetn 同步到 clk_dac2
  // ==========================================================
  reg [2:0] dac_rstff;
  always @(posedge clk_dac2 or negedge clk104_aresetn) begin
    if(!clk104_aresetn) dac_rstff <= 3'b000;
    else                dac_rstff <= {dac_rstff[1:0], 1'b1};
  end
  wire dac_rst_n = dac_rstff[2];

  // ==========================================================
  // DDR 域：配置帧（160-bit）打包，commit 时写入 cfg FIFO
  // 关键修复：写入 FIFO 的 seq_id 使用 seq_id_next，避免第一帧=0 导致 DAC gating 卡死
  // ==========================================================
  reg [15:0] seq_id;
  wire [15:0] seq_id_next = seq_id + 16'd1;

  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) seq_id <= 16'd0;
    else if(cfg_commit)  seq_id <= seq_id_next;
  end

  wire [159:0] cfg_payload = {
      ch1_delay_cycles,   // [159:128]
      ch2_delay_cycles,   // [127:96]
      ch1_len_beats,      // [95:64]
      ch2_len_beats,      // [63:32]
      14'd0,
      ch1_arm,            // [17]
      ch2_arm,            // [16]
      seq_id_next         // [15:0]  ★关键：next
  };

  wire cfg_wr_valid = cfg_commit;

  // ==========================================================
  // cfg CDC FIFO (xpm_fifo_async)  DDR->DAC
  // ==========================================================
  wire [159:0] cfg_rd_data;
  wire         cfg_rd_valid;
  reg          cfg_rd_ready;

  cfg_cdc_fifo_xpm #(
    .W(160),
    .DEPTH(16)
  ) u_cfg_fifo (
    .wr_clk(ddr4_ui_clk),
    .wr_rst_n(ddr4_ui_aresetn),
    .wr_data(cfg_payload),
    .wr_valid(cfg_wr_valid),
    .wr_ready(cfg_wr_ready),

    .rd_clk(clk_dac2),
    .rd_rst_n(dac_rst_n),
    .rd_data(cfg_rd_data),
    .rd_valid(cfg_rd_valid),
    .rd_ready(cfg_rd_ready)
  );

  // DAC 域：锁存最新一帧配置
  reg [31:0] ch1_delay_dac, ch2_delay_dac, ch1_len_dac, ch2_len_dac;
  reg        ch1_arm_dac, ch2_arm_dac;
  reg [15:0] seq_id_dac;

  always @(posedge clk_dac2 or negedge dac_rst_n) begin
    if(!dac_rst_n) begin
      cfg_rd_ready  <= 1'b0;
      ch1_delay_dac <= 0; ch2_delay_dac <= 0;
      ch1_len_dac   <= 0; ch2_len_dac   <= 0;
      ch1_arm_dac   <= 0; ch2_arm_dac   <= 0;
      seq_id_dac    <= 0;
    end else begin
      cfg_rd_ready <= 1'b1; // 简化：一直准备接收

      if(cfg_rd_valid && cfg_rd_ready) begin
        ch1_delay_dac <= cfg_rd_data[159:128];
        ch2_delay_dac <= cfg_rd_data[127:96];
        ch1_len_dac   <= cfg_rd_data[95:64];
        ch2_len_dac   <= cfg_rd_data[63:32];
        ch1_arm_dac   <= cfg_rd_data[17];
        ch2_arm_dac   <= cfg_rd_data[16];
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

    .m_axis_mm2s_sts_tvalid(),
    .m_axis_mm2s_sts_tready(1'b1)
  );

  // ==========================================================
  // 波形异步 FIFO（DDR->DAC，128bit AXIS）
  // ==========================================================
  wire [127:0] dac_in_ch1_tdata, dac_in_ch2_tdata;
  wire         dac_in_ch1_tvalid, dac_in_ch2_tvalid;

  wire [127:0] rfdc_ch1_tdata, rfdc_ch2_tdata;
  wire         rfdc_ch1_tvalid, rfdc_ch2_tvalid; // 会是常1

  axis_to_rfdc_continuous #(.W(128)) u_rfdc_cont_ch1 (
    .clk(clk_dac2),
    .rst_n(dac_rst_n),

    .s_tdata(dac_in_ch1_tdata),
    .s_tvalid_gated(dac_ch1_valid_gated), // 用你原来的 gated valid

    .m_tready(dac_ch1_ready),

    .m_tdata(rfdc_ch1_tdata),
    .m_tvalid(rfdc_ch1_tvalid)
  );

  axis_to_rfdc_continuous #(.W(128)) u_rfdc_cont_ch2 (
    .clk(clk_dac2),
    .rst_n(dac_rst_n),

    .s_tdata(dac_in_ch2_tdata),
    .s_tvalid_gated(dac_ch2_valid_gated),

    .m_tready(dac_ch2_ready),

    .m_tdata(rfdc_ch2_tdata),
    .m_tvalid(rfdc_ch2_tvalid)
  );

  // === 先实例化门控控制器（需要 FIFO 输出 valid） ===
  wire ch1_allow, ch2_allow;

  // gate ready/valid
  wire dac_ch1_ready_gated;
  wire dac_ch2_ready_gated;
  wire dac_ch1_valid_gated;
  wire dac_ch2_valid_gated;

  assign dac_ch1_ready_gated = dac_ch1_ready & ch1_allow;
  assign dac_ch2_ready_gated = dac_ch2_ready & ch2_allow;

  assign dac_ch1_valid_gated = dac_in_ch1_tvalid & ch1_allow;
  assign dac_ch2_valid_gated = dac_in_ch2_tvalid & ch2_allow;

  // ===== NEW: play_ctrl debug wires (接 ILA 用) =====
  wire        pc_trig_pulse, pc_new_cfg, pc_trig_start, pc_started;
  wire [15:0] pc_last_seq_id;

  dac_play_ctrl #(
    .BEAT_BYTES(16)
  ) u_play_ctrl (
    .clk(clk_dac2),
    .rst_n(dac_rst_n),
    .trigger(ps_trigger_dac_sync),

    .cfg_seq_id(seq_id_dac),

    .ch1_delay_cycles(ch1_delay_dac),
    .ch2_delay_cycles(ch2_delay_dac),
    .ch1_len_beats(ch1_len_dac),
    .ch2_len_beats(ch2_len_dac),
    .ch1_arm(ch1_arm_dac),
    .ch2_arm(ch2_arm_dac),

    .ch1_fifo_tvalid(dac_in_ch1_tvalid),
    .ch2_fifo_tvalid(dac_in_ch2_tvalid),

    .dac_ch1_ready_in(dac_ch1_ready),
    .dac_ch2_ready_in(dac_ch2_ready),

    .ch1_allow(ch1_allow),
    .ch2_allow(ch2_allow),

    .ch1_active(),
    .ch2_active(),

    .dbg_trig_pulse (pc_trig_pulse),
    .dbg_new_cfg    (pc_new_cfg),
    .dbg_trig_start (pc_trig_start),
    .dbg_started    (pc_started),
    .dbg_last_seq_id(pc_last_seq_id)
  );

  wire [31:0] ch1_wr_count, ch2_wr_count;
  wire ch1_prog_empty, ch1_prog_full;
  wire ch2_prog_empty, ch2_prog_full;

  assign ch1_fifo_level_beats = ch1_wr_count[15:0];
  assign ch2_fifo_level_beats = ch2_wr_count[15:0];

  wire ch1_wave_tlast = 1'b0;
  wire ch2_wave_tlast = 1'b0;
  wire dac_out_ch1_tlast, dac_out_ch2_tlast;

  axis_async_fifo_128 fifo_ch1_inst (
    .s_axis_aresetn(ddr4_ui_aresetn),
    .s_axis_aclk   (ddr4_ui_clk),
    .s_axis_tvalid (ch1_wave_tvalid),
    .s_axis_tready (ch1_wave_tready_internal),
    .s_axis_tdata  (ch1_wave_tdata),
    .s_axis_tlast  (ch1_wave_tlast),

    .m_axis_aclk   (clk_dac2),
    .m_axis_tvalid (dac_in_ch1_tvalid),
    .m_axis_tready (dac_ch1_ready_gated),
    .m_axis_tdata  (dac_in_ch1_tdata),
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

    .m_axis_aclk   (clk_dac2),
    .m_axis_tvalid (dac_in_ch2_tvalid),
    .m_axis_tready (dac_ch2_ready_gated),
    .m_axis_tdata  (dac_in_ch2_tdata),
    .m_axis_tlast  (dac_out_ch2_tlast),

    .axis_wr_data_count(ch2_wr_count),
    .prog_empty        (ch2_prog_empty),
    .prog_full         (ch2_prog_full)
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
  wire        M_AXI_GPIO_rlast;
  wire        M_AXI_GPIO_rready;
  wire [1:0]  M_AXI_GPIO_rresp;
  wire        M_AXI_GPIO_rvalid;

  wire [31:0] M_AXI_GPIO_wdata;
  wire        M_AXI_GPIO_wlast;
  wire        M_AXI_GPIO_wready;
  wire [3:0]  M_AXI_GPIO_wstrb;
  wire        M_AXI_GPIO_wvalid;

  design_1 design_1_i (
      .pl_clk(pl_clk),
      .pl_aresetn(pl_aresetn),
      .pl_ps_irq(pl_ps_irq),
      .clk_adc2(clk_adc2),
      .clk_dac2(clk_dac2),
      .clk104_aresetn(clk104_aresetn),
      .ddr4_ui_clk(ddr4_ui_clk),
      .ddr4_ui_aresetn(ddr4_ui_aresetn),

      .adc2_clk_clk_n(adc2_clk_clk_n),
      .adc2_clk_clk_p(adc2_clk_clk_p),
      .dac2_clk_clk_n(dac2_clk_clk_n),
      .dac2_clk_clk_p(dac2_clk_clk_p),
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
      .vout20_v_n(vout20_v_n),
      .vout20_v_p(vout20_v_p),
      .vout22_v_n(vout22_v_n),
      .vout22_v_p(vout22_v_p),
      .vout30_v_n(vout30_v_n),
      .vout30_v_p(vout30_v_p),

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

      // DDR AXI slave for DataMover read (S_AXI_01)
      .S_AXI_01_araddr(M_AXI_DM_araddr),
      .S_AXI_01_arburst(M_AXI_DM_arburst),
      .S_AXI_01_arcache(4'b0011),
      .S_AXI_01_arlen(M_AXI_DM_arlen),
      .S_AXI_01_arprot(3'b000),
      .S_AXI_01_arready(M_AXI_DM_arready),
      .S_AXI_01_arsize(M_AXI_DM_arsize),
      .S_AXI_01_arvalid(M_AXI_DM_arvalid),
      .S_AXI_01_rdata(M_AXI_DM_rdata),
      .S_AXI_01_rlast(M_AXI_DM_rlast),
      .S_AXI_01_rready(M_AXI_DM_rready),
      .S_AXI_01_rresp(M_AXI_DM_rresp),
      .S_AXI_01_rvalid(M_AXI_DM_rvalid),

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

      .S_AXIS_20_tdata(rfdc_ch1_tdata),
      .S_AXIS_20_tvalid(rfdc_ch1_tvalid),
      .S_AXIS_20_tready(dac_ch1_ready),

      .S_AXIS_22_tdata(rfdc_ch2_tdata),
      .S_AXIS_22_tvalid(rfdc_ch2_tvalid),
      .S_AXIS_22_tready(dac_ch2_ready),

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
      .io_axi_r_bits_data(M_AXI_GPIO_rdata),
      .io_axi_r_bits_last(M_AXI_GPIO_rlast),
      .io_axi_r_bits_resp(M_AXI_GPIO_rresp),

      .io_axi_b_ready(M_AXI_GPIO_bready),
      .io_axi_b_valid(M_AXI_GPIO_bvalid),
      .io_axi_b_bits_resp(M_AXI_GPIO_bresp),

      .io_gpio(clk104_clk_spi_mux_sel_tri_o),
      .io_gpio2(gpio_out_reg)
  );

  // ==========================================================
  // LED（stub）
  // ==========================================================
  LED led_i (
      .io_CLK(clk_adc2),
      .io_CLK1(clk_dac2),
      .io_LED0(LED0),
      .io_LED1(LED1)
  );


//  ila_ctrl_ddr u_ila_ctrl_ddr (
//    .clk(ddr4_ui_clk),

//    // probe0: reset/trigger + executor state + dm state
//    .probe0({
//      // ===== existing 12 bits (keep) =====
//      ddr4_ui_aresetn,          // 1
//      ps_trigger_ddr_sync,      // 1
//      ex_dbg_st,                // 3
//      ex_dbg_dm_st,             // 2
//      ex_dbg_dm_sel_ch1,        // 1
//      ex_dbg_ch1_need_hard,     // 1
//      ex_dbg_ch2_need_hard,     // 1
//      ex_dbg_ch1_need_soft,     // 1
//      ex_dbg_ch2_need_soft,     // 1

//      // ===== NEW bits appended =====
//      ex_dbg_pending_valid,     // 1
//      ex_dbg_active_valid,      // 1
//      ex_dbg_run_delay_cnt[15:0], // 16
//      ex_dbg_main_tvalid,       // 1
//      ex_dbg_main_tready        // 1
//    }), // total = 32

//    // probe1: instruction ingress (PS->AXIS)
//    .probe1(ps_instr_tdata), // 128

//    .probe2({ps_instr_tvalid, ps_instr_tready}), // 2

//    // probe3: fifo levels + bytes_left
//    .probe3({
//      ch1_fifo_level_beats,     // 16
//      ch2_fifo_level_beats,     // 16
//      ex_dbg_ch1_bytes_left,    // 32
//      ex_dbg_ch2_bytes_left     // 32
//    }), // 96

//    // probe4: DM cmd + handshake
//    .probe4(dm_cmd_tdata), // 104
//    .probe5({dm_cmd_tvalid, dm_cmd_tready}), // 2

//    // probe6: DM data + handshake + TLAST
//    .probe6(dm_data_tdata), // 128
//    .probe7({dm_data_tvalid, dm_data_tready, dm_data_tlast}), // 3

//    // probe8: ch1/ch2 fifo write AXIS
//    .probe8({
//      ch1_wave_tvalid, ch1_wave_tready_internal,
//      ch2_wave_tvalid, ch2_wave_tready_internal,
//      ch1_wave_tdata[31:0],
//      ch2_wave_tdata[31:0]
//    }), // 1+1+1+1+32+32=68

//    // probe9: dm chunk progress + base addr low bits
//    .probe9({
//      ex_dbg_dm_chunk_beats,     // 32
//      ex_dbg_dm_beats_sent,      // 32
//      ex_dbg_ch1_base_addr[31:0],// 32
//      ex_dbg_ch2_base_addr[31:0] // 32
//    }), // 128

//    .probe10(ex_dbg_main_tdata)
//  );

//  // ================= DAC DATA ILA =================
//  ila_data_dac u_ila_data_dac (
//    .clk(clk_dac2),

//    .probe0({
//      dac_rst_n,
//      ps_trigger_dac_sync,
//      seq_id_dac,
//      pc_started,
//      pc_trig_pulse,
//      pc_new_cfg,
//      pc_trig_start,
//      pc_last_seq_id
//    }),
//    .probe1({ch1_allow, ch2_allow, dac_ch1_ready, dac_ch2_ready, dac_ch1_ready_gated, dac_ch2_ready_gated}),
//    .probe2({dac_in_ch1_tvalid, dac_ch1_ready_gated, dac_in_ch2_tvalid, dac_ch2_ready_gated}),
//    .probe3({dac_in_ch1_tdata[127:0], dac_in_ch2_tdata[127:0]}),
//    .probe4({rfdc_ch1_tvalid, rfdc_ch2_tvalid, rfdc_ch1_tdata[127:0], rfdc_ch2_tdata[127:0]}),
//    .probe5({ch1_arm_dac, ch2_arm_dac, ch1_delay_dac[15:0], ch2_delay_dac[15:0], ch1_len_dac[15:0], ch2_len_dac[15:0]})
//  );
endmodule