module TopBandwidthCore (
    output          TRIG_1,
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

  localparam [63:0] EXT_DDR_ADDR_BASE = 64'h0000_0048_0000_0000;

  wire pl_clk;
  wire pl_resetn0;
  wire pl_aresetn;
  wire ddr4_ui_clk;
  wire ddr4_ui_clk_sync_rst;
  wire ddr4_ui_aresetn;
  wire ddr_init_calib_complete;

  ChiselProcSysReset u_pl_reset (
    .io_slowest_sync_clk(pl_clk),
    .io_ext_reset_in(pl_resetn0),
    .io_aux_reset_in(1'b0),
    .io_dcm_locked(1'b1),
    .io_peripheral_aresetn(pl_aresetn)
  );

  ChiselProcSysReset u_ddr4_ui_reset (
    .io_slowest_sync_clk(ddr4_ui_clk),
    .io_ext_reset_in(pl_resetn0),
    .io_aux_reset_in(ddr4_ui_clk_sync_rst),
    .io_dcm_locked(ddr_init_calib_complete),
    .io_peripheral_aresetn(ddr4_ui_aresetn)
  );

  wire [31:0] M_AXI_CTRL_awaddr;
  wire [2:0]  M_AXI_CTRL_awprot;
  wire        M_AXI_CTRL_awready;
  wire        M_AXI_CTRL_awvalid;
  wire [31:0] M_AXI_CTRL_wdata;
  wire        M_AXI_CTRL_wready;
  wire [3:0]  M_AXI_CTRL_wstrb;
  wire        M_AXI_CTRL_wvalid;
  wire        M_AXI_CTRL_bready;
  wire [1:0]  M_AXI_CTRL_bresp;
  wire        M_AXI_CTRL_bvalid;
  wire [31:0] M_AXI_CTRL_araddr;
  wire [2:0]  M_AXI_CTRL_arprot;
  wire        M_AXI_CTRL_arready;
  wire        M_AXI_CTRL_arvalid;
  wire [31:0] M_AXI_CTRL_rdata;
  wire        M_AXI_CTRL_rready;
  wire [1:0]  M_AXI_CTRL_rresp;
  wire        M_AXI_CTRL_rvalid;

  wire [31:0] M_AXI_INST_awaddr;
  wire [1:0]  M_AXI_INST_awburst;
  wire [3:0]  M_AXI_INST_awcache;
  wire [7:0]  M_AXI_INST_awlen;
  wire [0:0]  M_AXI_INST_awlock;
  wire [2:0]  M_AXI_INST_awprot;
  wire [3:0]  M_AXI_INST_awqos;
  wire        M_AXI_INST_awready;
  wire [2:0]  M_AXI_INST_awsize;
  wire [15:0] M_AXI_INST_awuser;
  wire        M_AXI_INST_awvalid;
  wire [31:0] M_AXI_INST_wdata;
  wire        M_AXI_INST_wlast;
  wire        M_AXI_INST_wready;
  wire [3:0]  M_AXI_INST_wstrb;
  wire        M_AXI_INST_wvalid;
  wire        M_AXI_INST_bready;
  wire [1:0]  M_AXI_INST_bresp;
  wire        M_AXI_INST_bvalid;
  wire [31:0] M_AXI_INST_araddr;
  wire [1:0]  M_AXI_INST_arburst;
  wire [3:0]  M_AXI_INST_arcache;
  wire [7:0]  M_AXI_INST_arlen;
  wire [0:0]  M_AXI_INST_arlock;
  wire [2:0]  M_AXI_INST_arprot;
  wire [3:0]  M_AXI_INST_arqos;
  wire        M_AXI_INST_arready;
  wire [2:0]  M_AXI_INST_arsize;
  wire [15:0] M_AXI_INST_aruser;
  wire        M_AXI_INST_arvalid;
  wire [31:0] M_AXI_INST_rdata;
  wire        M_AXI_INST_rlast;
  wire        M_AXI_INST_rready;
  wire [1:0]  M_AXI_INST_rresp;
  wire        M_AXI_INST_rvalid;

  wire [39:0]  M_AXI_PS_DDR_awaddr;
  wire [1:0]   M_AXI_PS_DDR_awburst;
  wire [3:0]   M_AXI_PS_DDR_awcache;
  wire [15:0]  M_AXI_PS_DDR_awid;
  wire [7:0]   M_AXI_PS_DDR_awlen;
  wire [0:0]   M_AXI_PS_DDR_awlock;
  wire [2:0]   M_AXI_PS_DDR_awprot;
  wire [3:0]   M_AXI_PS_DDR_awqos;
  wire         M_AXI_PS_DDR_awready;
  wire [2:0]   M_AXI_PS_DDR_awsize;
  wire [15:0]  M_AXI_PS_DDR_awuser;
  wire         M_AXI_PS_DDR_awvalid;
  wire [127:0] M_AXI_PS_DDR_wdata;
  wire         M_AXI_PS_DDR_wlast;
  wire         M_AXI_PS_DDR_wready;
  wire [15:0]  M_AXI_PS_DDR_wstrb;
  wire         M_AXI_PS_DDR_wvalid;
  wire         M_AXI_PS_DDR_bready;
  wire [15:0]  M_AXI_PS_DDR_bid;
  wire [1:0]   M_AXI_PS_DDR_bresp;
  wire         M_AXI_PS_DDR_bvalid;
  wire [39:0]  M_AXI_PS_DDR_araddr;
  wire [1:0]   M_AXI_PS_DDR_arburst;
  wire [3:0]   M_AXI_PS_DDR_arcache;
  wire [15:0]  M_AXI_PS_DDR_arid;
  wire [7:0]   M_AXI_PS_DDR_arlen;
  wire [0:0]   M_AXI_PS_DDR_arlock;
  wire [2:0]   M_AXI_PS_DDR_arprot;
  wire [3:0]   M_AXI_PS_DDR_arqos;
  wire         M_AXI_PS_DDR_arready;
  wire [2:0]   M_AXI_PS_DDR_arsize;
  wire [15:0]  M_AXI_PS_DDR_aruser;
  wire         M_AXI_PS_DDR_arvalid;
  wire [127:0] M_AXI_PS_DDR_rdata;
  wire [15:0]  M_AXI_PS_DDR_rid;
  wire         M_AXI_PS_DDR_rlast;
  wire         M_AXI_PS_DDR_rready;
  wire [1:0]   M_AXI_PS_DDR_rresp;
  wire         M_AXI_PS_DDR_rvalid;

  design_1_wrapper ps_i (
    .M_AXI_CTRL_araddr(M_AXI_CTRL_araddr), .M_AXI_CTRL_arprot(M_AXI_CTRL_arprot), .M_AXI_CTRL_arready(M_AXI_CTRL_arready), .M_AXI_CTRL_arvalid(M_AXI_CTRL_arvalid),
    .M_AXI_CTRL_awaddr(M_AXI_CTRL_awaddr), .M_AXI_CTRL_awprot(M_AXI_CTRL_awprot), .M_AXI_CTRL_awready(M_AXI_CTRL_awready), .M_AXI_CTRL_awvalid(M_AXI_CTRL_awvalid),
    .M_AXI_CTRL_bready(M_AXI_CTRL_bready), .M_AXI_CTRL_bresp(M_AXI_CTRL_bresp), .M_AXI_CTRL_bvalid(M_AXI_CTRL_bvalid),
    .M_AXI_CTRL_rdata(M_AXI_CTRL_rdata), .M_AXI_CTRL_rready(M_AXI_CTRL_rready), .M_AXI_CTRL_rresp(M_AXI_CTRL_rresp), .M_AXI_CTRL_rvalid(M_AXI_CTRL_rvalid),
    .M_AXI_CTRL_wdata(M_AXI_CTRL_wdata), .M_AXI_CTRL_wready(M_AXI_CTRL_wready), .M_AXI_CTRL_wstrb(M_AXI_CTRL_wstrb), .M_AXI_CTRL_wvalid(M_AXI_CTRL_wvalid),
    .M_AXI_INST_araddr(M_AXI_INST_araddr), .M_AXI_INST_arburst(M_AXI_INST_arburst), .M_AXI_INST_arcache(M_AXI_INST_arcache), .M_AXI_INST_arlen(M_AXI_INST_arlen), .M_AXI_INST_arlock(M_AXI_INST_arlock), .M_AXI_INST_arprot(M_AXI_INST_arprot), .M_AXI_INST_arqos(M_AXI_INST_arqos), .M_AXI_INST_arready(M_AXI_INST_arready), .M_AXI_INST_arsize(M_AXI_INST_arsize), .M_AXI_INST_aruser(M_AXI_INST_aruser), .M_AXI_INST_arvalid(M_AXI_INST_arvalid),
    .M_AXI_INST_awaddr(M_AXI_INST_awaddr), .M_AXI_INST_awburst(M_AXI_INST_awburst), .M_AXI_INST_awcache(M_AXI_INST_awcache), .M_AXI_INST_awlen(M_AXI_INST_awlen), .M_AXI_INST_awlock(M_AXI_INST_awlock), .M_AXI_INST_awprot(M_AXI_INST_awprot), .M_AXI_INST_awqos(M_AXI_INST_awqos), .M_AXI_INST_awready(M_AXI_INST_awready), .M_AXI_INST_awsize(M_AXI_INST_awsize), .M_AXI_INST_awuser(M_AXI_INST_awuser), .M_AXI_INST_awvalid(M_AXI_INST_awvalid),
    .M_AXI_INST_bready(M_AXI_INST_bready), .M_AXI_INST_bresp(M_AXI_INST_bresp), .M_AXI_INST_bvalid(M_AXI_INST_bvalid),
    .M_AXI_INST_rdata(M_AXI_INST_rdata), .M_AXI_INST_rlast(M_AXI_INST_rlast), .M_AXI_INST_rready(M_AXI_INST_rready), .M_AXI_INST_rresp(M_AXI_INST_rresp), .M_AXI_INST_rvalid(M_AXI_INST_rvalid),
    .M_AXI_INST_wdata(M_AXI_INST_wdata), .M_AXI_INST_wlast(M_AXI_INST_wlast), .M_AXI_INST_wready(M_AXI_INST_wready), .M_AXI_INST_wstrb(M_AXI_INST_wstrb), .M_AXI_INST_wvalid(M_AXI_INST_wvalid),
    .M_AXI_PS_DDR_araddr(M_AXI_PS_DDR_araddr), .M_AXI_PS_DDR_arburst(M_AXI_PS_DDR_arburst), .M_AXI_PS_DDR_arcache(M_AXI_PS_DDR_arcache), .M_AXI_PS_DDR_arid(M_AXI_PS_DDR_arid), .M_AXI_PS_DDR_arlen(M_AXI_PS_DDR_arlen), .M_AXI_PS_DDR_arlock(M_AXI_PS_DDR_arlock), .M_AXI_PS_DDR_arprot(M_AXI_PS_DDR_arprot), .M_AXI_PS_DDR_arqos(M_AXI_PS_DDR_arqos), .M_AXI_PS_DDR_arready(M_AXI_PS_DDR_arready), .M_AXI_PS_DDR_arsize(M_AXI_PS_DDR_arsize), .M_AXI_PS_DDR_aruser(M_AXI_PS_DDR_aruser), .M_AXI_PS_DDR_arvalid(M_AXI_PS_DDR_arvalid),
    .M_AXI_PS_DDR_awaddr(M_AXI_PS_DDR_awaddr), .M_AXI_PS_DDR_awburst(M_AXI_PS_DDR_awburst), .M_AXI_PS_DDR_awcache(M_AXI_PS_DDR_awcache), .M_AXI_PS_DDR_awid(M_AXI_PS_DDR_awid), .M_AXI_PS_DDR_awlen(M_AXI_PS_DDR_awlen), .M_AXI_PS_DDR_awlock(M_AXI_PS_DDR_awlock), .M_AXI_PS_DDR_awprot(M_AXI_PS_DDR_awprot), .M_AXI_PS_DDR_awqos(M_AXI_PS_DDR_awqos), .M_AXI_PS_DDR_awready(M_AXI_PS_DDR_awready), .M_AXI_PS_DDR_awsize(M_AXI_PS_DDR_awsize), .M_AXI_PS_DDR_awuser(M_AXI_PS_DDR_awuser), .M_AXI_PS_DDR_awvalid(M_AXI_PS_DDR_awvalid),
    .M_AXI_PS_DDR_bid(M_AXI_PS_DDR_bid), .M_AXI_PS_DDR_bready(M_AXI_PS_DDR_bready), .M_AXI_PS_DDR_bresp(M_AXI_PS_DDR_bresp), .M_AXI_PS_DDR_bvalid(M_AXI_PS_DDR_bvalid),
    .M_AXI_PS_DDR_rdata(M_AXI_PS_DDR_rdata), .M_AXI_PS_DDR_rid(M_AXI_PS_DDR_rid), .M_AXI_PS_DDR_rlast(M_AXI_PS_DDR_rlast), .M_AXI_PS_DDR_rready(M_AXI_PS_DDR_rready), .M_AXI_PS_DDR_rresp(M_AXI_PS_DDR_rresp), .M_AXI_PS_DDR_rvalid(M_AXI_PS_DDR_rvalid),
    .M_AXI_PS_DDR_wdata(M_AXI_PS_DDR_wdata), .M_AXI_PS_DDR_wlast(M_AXI_PS_DDR_wlast), .M_AXI_PS_DDR_wready(M_AXI_PS_DDR_wready), .M_AXI_PS_DDR_wstrb(M_AXI_PS_DDR_wstrb), .M_AXI_PS_DDR_wvalid(M_AXI_PS_DDR_wvalid),
    .ddr4_ui_clk(ddr4_ui_clk), .pl_aresetn(pl_aresetn), .pl_clk(pl_clk), .pl_resetn0(pl_resetn0)
  );

  wire soft_reset_pl;
  wire trigger_pl;
  wire [31:0] sample_period_pl;
  wire [2:0] ch_select_pl;
  wire [127:0] unused_instr_tdata;
  wire unused_instr_tvalid;

  wire [31:0] sink_status, exec_status;
  wire [31:0] total_bytes_low, total_bytes_high, total_bursts;
  wire [31:0] total_stall_cycles, total_underflows;
  wire [31:0] sample_index, sample_bytes_low, sample_bytes_high, sample_stalls, sample_underflows;
  wire        sample_valid_bit;
  wire [31:0] sample_valid = {31'd0, sample_valid_bit};
  wire [31:0] ch_bytes_low, ch_bytes_high, ch_bursts, ch_stalls, ch_underflows, ch_fifo_min, ch_fifo_max;
  wire [31:0] sink_total_bytes_low, sink_total_bytes_high;
  wire [31:0] sink_sample_index, sink_sample_bytes_low, sink_sample_bytes_high;
  wire        sink_sample_valid_bit;

  bandwidth_axi_regs ctrl_i (
    .s_axi_aclk(pl_clk), .s_axi_aresetn(pl_aresetn),
    .s_axi_awaddr(M_AXI_CTRL_awaddr[11:0]), .s_axi_awvalid(M_AXI_CTRL_awvalid), .s_axi_awready(M_AXI_CTRL_awready),
    .s_axi_wdata(M_AXI_CTRL_wdata), .s_axi_wstrb(M_AXI_CTRL_wstrb), .s_axi_wvalid(M_AXI_CTRL_wvalid), .s_axi_wready(M_AXI_CTRL_wready),
    .s_axi_bresp(M_AXI_CTRL_bresp), .s_axi_bvalid(M_AXI_CTRL_bvalid), .s_axi_bready(M_AXI_CTRL_bready),
    .s_axi_araddr(M_AXI_CTRL_araddr[11:0]), .s_axi_arvalid(M_AXI_CTRL_arvalid), .s_axi_arready(M_AXI_CTRL_arready),
    .s_axi_rdata(M_AXI_CTRL_rdata), .s_axi_rresp(M_AXI_CTRL_rresp), .s_axi_rvalid(M_AXI_CTRL_rvalid), .s_axi_rready(M_AXI_CTRL_rready),
    .soft_reset(soft_reset_pl), .trigger(trigger_pl), .sample_period_cycles(sample_period_pl),
    .instr_tdata(unused_instr_tdata), .instr_tvalid(unused_instr_tvalid), .instr_tready(1'b1),
    .status(exec_status ^ sink_status), .total_bytes_low(total_bytes_low), .total_bytes_high(total_bytes_high), .total_bursts(total_bursts),
    .total_stall_cycles(total_stall_cycles), .total_underflows(total_underflows),
    .sample_index(sample_index), .sample_bytes_low(sample_bytes_low), .sample_bytes_high(sample_bytes_high), .sample_stalls(sample_stalls), .sample_underflows(sample_underflows), .sample_valid(sample_valid),
    .ch_bytes_low(ch_bytes_low), .ch_bytes_high(ch_bytes_high), .ch_bursts(ch_bursts), .ch_stalls(ch_stalls), .ch_underflows(ch_underflows), .ch_fifo_min(ch_fifo_min), .ch_fifo_max(ch_fifo_max),
    .ch_select(ch_select_pl)
  );

  wire [127:0] instr_tdata;
  wire instr_tvalid;
  wire instr_tready;

  axi_fifo_interface axi_fifo_inst (
      .s_axi_aclk(pl_clk), .s_axi_aresetn(pl_aresetn),
      .s_axi_awaddr(M_AXI_INST_awaddr), .s_axi_awlen(M_AXI_INST_awlen), .s_axi_awvalid(M_AXI_INST_awvalid), .s_axi_awready(M_AXI_INST_awready),
      .s_axi_wdata(M_AXI_INST_wdata), .s_axi_wstrb(M_AXI_INST_wstrb), .s_axi_wvalid(M_AXI_INST_wvalid), .s_axi_wready(M_AXI_INST_wready),
      .s_axi_bvalid(M_AXI_INST_bvalid), .s_axi_bready(M_AXI_INST_bready), .s_axi_bresp(M_AXI_INST_bresp),
      .s_axi_araddr(M_AXI_INST_araddr), .s_axi_arlen(M_AXI_INST_arlen), .s_axi_arvalid(M_AXI_INST_arvalid), .s_axi_arready(M_AXI_INST_arready),
      .s_axi_rdata(M_AXI_INST_rdata), .s_axi_rlast(M_AXI_INST_rlast), .s_axi_rvalid(M_AXI_INST_rvalid), .s_axi_rready(M_AXI_INST_rready), .s_axi_rresp(M_AXI_INST_rresp),
      .m_aclk(ddr4_ui_clk), .m_aresetn(ddr4_ui_aresetn),
      .m_axis_tdata(instr_tdata), .m_axis_tvalid(instr_tvalid), .m_axis_tready(instr_tready)
  );

  reg [2:0] soft_reset_sync;
  reg [2:0] trigger_sync;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) begin
      soft_reset_sync <= 3'b000;
      trigger_sync <= 3'b000;
    end else begin
      soft_reset_sync <= {soft_reset_sync[1:0], soft_reset_pl};
      trigger_sync <= {trigger_sync[1:0], trigger_pl};
    end
  end
  wire soft_reset_ddr = soft_reset_sync[2] & ~soft_reset_sync[1];
  wire trigger_ddr = trigger_sync[2] & ~trigger_sync[1];

  reg [31:0] sample_period_ddr;
  reg [2:0] ch_select_ddr;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) begin
      sample_period_ddr <= 32'd100000000;
      ch_select_ddr <= 3'd0;
    end else begin
      sample_period_ddr <= sample_period_pl;
      ch_select_ddr <= ch_select_pl;
    end
  end

  wire [103:0] dm_cmd_tdata;
  wire dm_cmd_tvalid, dm_cmd_tready;
  wire [511:0] dm_data_tdata;
  wire dm_data_tvalid, dm_data_tready, dm_data_tlast;
  wire dm_mm2s_err;
  wire dm_mm2s_sts_tvalid, dm_mm2s_sts_tlast;
  wire [7:0] dm_mm2s_sts_tdata;
  wire dm_mm2s_sts_tkeep;

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

  wire [2:0] dm_sel;
  wire [7:0] ch_arm;
  wire [15:0] ch1_level, ch2_level, ch3_level, ch4_level, ch5_level, ch6_level, ch7_level, ch8_level;

  waveform_bandwidth_top #(.DDR_ADDR_BASE(EXT_DDR_ADDR_BASE)) executor_i (
    .aclk(ddr4_ui_clk), .aresetn(ddr4_ui_aresetn), .clear(soft_reset_ddr), .trigger(trigger_ddr),
    .s_axis_instr_tdata(instr_tdata), .s_axis_instr_tvalid(instr_tvalid), .s_axis_instr_tready(instr_tready),
    .m_axis_dm_cmd_tdata(dm_cmd_tdata), .m_axis_dm_cmd_tvalid(dm_cmd_tvalid), .m_axis_dm_cmd_tready(dm_cmd_tready),
    .s_axis_dm_data_tdata(dm_data_tdata), .s_axis_dm_data_tvalid(dm_data_tvalid), .s_axis_dm_data_tready(dm_data_tready),
    .dm_sel_o(dm_sel), .ch_arm_o(ch_arm),
    .ch1_fifo_level_beats(ch1_level), .ch2_fifo_level_beats(ch2_level), .ch3_fifo_level_beats(ch3_level), .ch4_fifo_level_beats(ch4_level),
    .ch5_fifo_level_beats(ch5_level), .ch6_fifo_level_beats(ch6_level), .ch7_fifo_level_beats(ch7_level), .ch8_fifo_level_beats(ch8_level),
    .status(exec_status), .total_bursts(total_bursts), .ch_bursts(ch_bursts), .ch_select(ch_select_ddr)
  );

  bandwidth_sink sink_i (
    .clk(ddr4_ui_clk), .rst_n(ddr4_ui_aresetn), .clear(soft_reset_ddr), .dm_sel(dm_sel),
    .s_axis_tdata(dm_data_tdata), .s_axis_tvalid(dm_data_tvalid), .s_axis_tready(dm_data_tready),
    .ch_arm(ch_arm), .sample_period_cycles(sample_period_ddr),
    .ch1_level(ch1_level), .ch2_level(ch2_level), .ch3_level(ch3_level), .ch4_level(ch4_level),
    .ch5_level(ch5_level), .ch6_level(ch6_level), .ch7_level(ch7_level), .ch8_level(ch8_level),
    .status(sink_status), .total_bytes_low(sink_total_bytes_low), .total_bytes_high(sink_total_bytes_high),
    .total_stall_cycles(total_stall_cycles), .total_underflows(total_underflows),
    .sample_index(sink_sample_index), .sample_bytes_low(sink_sample_bytes_low), .sample_bytes_high(sink_sample_bytes_high),
    .sample_stalls(sample_stalls), .sample_underflows(sample_underflows), .sample_valid(sink_sample_valid_bit),
    .ch_select(ch_select_ddr), .ch_bytes_low(ch_bytes_low), .ch_bytes_high(ch_bytes_high),
    .ch_stalls(ch_stalls), .ch_underflows(ch_underflows), .ch_fifo_min(ch_fifo_min), .ch_fifo_max(ch_fifo_max)
  );

  axi_datamover_0 datamover_i (
    .m_axi_mm2s_aclk(ddr4_ui_clk), .m_axi_mm2s_aresetn(ddr4_ui_aresetn), .mm2s_err(dm_mm2s_err),
    .m_axis_mm2s_cmdsts_aclk(ddr4_ui_clk), .m_axis_mm2s_cmdsts_aresetn(ddr4_ui_aresetn),
    .s_axis_mm2s_cmd_tdata(dm_cmd_tdata), .s_axis_mm2s_cmd_tvalid(dm_cmd_tvalid), .s_axis_mm2s_cmd_tready(dm_cmd_tready),
    .m_axis_mm2s_tdata(dm_data_tdata), .m_axis_mm2s_tvalid(dm_data_tvalid), .m_axis_mm2s_tready(dm_data_tready), .m_axis_mm2s_tlast(dm_data_tlast),
    .m_axi_mm2s_araddr(M_AXI_DM_araddr), .m_axi_mm2s_arlen(M_AXI_DM_arlen), .m_axi_mm2s_arsize(M_AXI_DM_arsize), .m_axi_mm2s_arburst(M_AXI_DM_arburst), .m_axi_mm2s_arvalid(M_AXI_DM_arvalid), .m_axi_mm2s_arready(M_AXI_DM_arready),
    .m_axi_mm2s_rdata(M_AXI_DM_rdata), .m_axi_mm2s_rresp(M_AXI_DM_rresp), .m_axi_mm2s_rlast(M_AXI_DM_rlast), .m_axi_mm2s_rvalid(M_AXI_DM_rvalid), .m_axi_mm2s_rready(M_AXI_DM_rready),
    .m_axis_mm2s_sts_tvalid(dm_mm2s_sts_tvalid), .m_axis_mm2s_sts_tready(1'b1), .m_axis_mm2s_sts_tdata(dm_mm2s_sts_tdata), .m_axis_mm2s_sts_tkeep(dm_mm2s_sts_tkeep), .m_axis_mm2s_sts_tlast(dm_mm2s_sts_tlast)
  );

  wire [39:0] DDR_awaddr;
  wire [7:0] DDR_awlen;
  wire [2:0] DDR_awsize;
  wire [1:0] DDR_awburst;
  wire [0:0] DDR_awlock;
  wire [3:0] DDR_awcache;
  wire [2:0] DDR_awprot;
  wire [3:0] DDR_awqos;
  wire DDR_awvalid, DDR_awready;
  wire [511:0] DDR_wdata;
  wire [63:0] DDR_wstrb;
  wire DDR_wlast, DDR_wvalid, DDR_wready;
  wire DDR_bready;
  wire [1:0] DDR_bresp;
  wire DDR_bvalid;
  wire [39:0] DDR_araddr;
  wire [7:0] DDR_arlen;
  wire [2:0] DDR_arsize;
  wire [1:0] DDR_arburst;
  wire [0:0] DDR_arlock;
  wire [3:0] DDR_arcache;
  wire [2:0] DDR_arprot;
  wire [3:0] DDR_arqos;
  wire [15:0] DDR_awuser;
  wire [15:0] DDR_aruser;
  wire DDR_arvalid, DDR_arready;
  wire DDR_rready;
  wire [511:0] DDR_rdata;
  wire [1:0] DDR_rresp;
  wire DDR_rlast, DDR_rvalid;

  reg [63:0] ddr_read_total_bytes;
  reg [63:0] ddr_read_sample_bytes_accum;
  reg [31:0] ddr_read_sample_cycle_count;
  reg [31:0] ddr_read_sample_index;
  reg [31:0] ddr_read_sample_bytes_low;
  reg [31:0] ddr_read_sample_bytes_high;
  reg        ddr_read_sample_valid;
  wire       ddr_read_fire = DDR_rvalid && DDR_rready;
  wire [63:0] ddr_read_sample_bytes_next = ddr_read_sample_bytes_accum + (ddr_read_fire ? 64'd64 : 64'd0);

  assign total_bytes_low = ddr_read_total_bytes[31:0];
  assign total_bytes_high = ddr_read_total_bytes[63:32];
  assign sample_index = ddr_read_sample_index;
  assign sample_bytes_low = ddr_read_sample_bytes_low;
  assign sample_bytes_high = ddr_read_sample_bytes_high;
  assign sample_valid_bit = ddr_read_sample_valid;

  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) begin
      ddr_read_total_bytes <= 64'd0;
      ddr_read_sample_bytes_accum <= 64'd0;
      ddr_read_sample_cycle_count <= 32'd0;
      ddr_read_sample_index <= 32'd0;
      ddr_read_sample_bytes_low <= 32'd0;
      ddr_read_sample_bytes_high <= 32'd0;
      ddr_read_sample_valid <= 1'b0;
    end else if(soft_reset_ddr) begin
      ddr_read_total_bytes <= 64'd0;
      ddr_read_sample_bytes_accum <= 64'd0;
      ddr_read_sample_cycle_count <= 32'd0;
      ddr_read_sample_index <= 32'd0;
      ddr_read_sample_bytes_low <= 32'd0;
      ddr_read_sample_bytes_high <= 32'd0;
      ddr_read_sample_valid <= 1'b0;
    end else begin
      ddr_read_sample_valid <= 1'b0;
      if(ddr_read_fire) begin
        ddr_read_total_bytes <= ddr_read_total_bytes + 64'd64;
        ddr_read_sample_bytes_accum <= ddr_read_sample_bytes_accum + 64'd64;
      end
      if(sample_period_ddr != 32'd0) begin
        if(ddr_read_sample_cycle_count + 32'd1 >= sample_period_ddr) begin
          ddr_read_sample_cycle_count <= 32'd0;
          ddr_read_sample_index <= ddr_read_sample_index + 32'd1;
          ddr_read_sample_bytes_low <= ddr_read_sample_bytes_next[31:0];
          ddr_read_sample_bytes_high <= ddr_read_sample_bytes_next[63:32];
          ddr_read_sample_bytes_accum <= 64'd0;
          ddr_read_sample_valid <= 1'b1;
        end else begin
          ddr_read_sample_cycle_count <= ddr_read_sample_cycle_count + 32'd1;
        end
      end
    end
  end

  ddr_axi_smartconnect_wrapper ddr_axi_i (
    .S_AXI_PS_araddr(M_AXI_PS_DDR_araddr), .S_AXI_PS_arburst(M_AXI_PS_DDR_arburst), .S_AXI_PS_arcache(M_AXI_PS_DDR_arcache), .S_AXI_PS_arid(M_AXI_PS_DDR_arid), .S_AXI_PS_arlen(M_AXI_PS_DDR_arlen), .S_AXI_PS_arlock(M_AXI_PS_DDR_arlock), .S_AXI_PS_arprot(M_AXI_PS_DDR_arprot), .S_AXI_PS_arqos(M_AXI_PS_DDR_arqos), .S_AXI_PS_arready(M_AXI_PS_DDR_arready), .S_AXI_PS_arsize(M_AXI_PS_DDR_arsize), .S_AXI_PS_aruser(M_AXI_PS_DDR_aruser), .S_AXI_PS_arvalid(M_AXI_PS_DDR_arvalid),
    .S_AXI_PS_awaddr(M_AXI_PS_DDR_awaddr), .S_AXI_PS_awburst(M_AXI_PS_DDR_awburst), .S_AXI_PS_awcache(M_AXI_PS_DDR_awcache), .S_AXI_PS_awid(M_AXI_PS_DDR_awid), .S_AXI_PS_awlen(M_AXI_PS_DDR_awlen), .S_AXI_PS_awlock(M_AXI_PS_DDR_awlock), .S_AXI_PS_awprot(M_AXI_PS_DDR_awprot), .S_AXI_PS_awqos(M_AXI_PS_DDR_awqos), .S_AXI_PS_awready(M_AXI_PS_DDR_awready), .S_AXI_PS_awsize(M_AXI_PS_DDR_awsize), .S_AXI_PS_awuser(M_AXI_PS_DDR_awuser), .S_AXI_PS_awvalid(M_AXI_PS_DDR_awvalid),
    .S_AXI_PS_bid(M_AXI_PS_DDR_bid), .S_AXI_PS_bready(M_AXI_PS_DDR_bready), .S_AXI_PS_bresp(M_AXI_PS_DDR_bresp), .S_AXI_PS_bvalid(M_AXI_PS_DDR_bvalid),
    .S_AXI_PS_rdata(M_AXI_PS_DDR_rdata), .S_AXI_PS_rid(M_AXI_PS_DDR_rid), .S_AXI_PS_rlast(M_AXI_PS_DDR_rlast), .S_AXI_PS_rready(M_AXI_PS_DDR_rready), .S_AXI_PS_rresp(M_AXI_PS_DDR_rresp), .S_AXI_PS_rvalid(M_AXI_PS_DDR_rvalid),
    .S_AXI_PS_wdata(M_AXI_PS_DDR_wdata), .S_AXI_PS_wlast(M_AXI_PS_DDR_wlast), .S_AXI_PS_wready(M_AXI_PS_DDR_wready), .S_AXI_PS_wstrb(M_AXI_PS_DDR_wstrb), .S_AXI_PS_wvalid(M_AXI_PS_DDR_wvalid),
    .S_AXI_PL_araddr(M_AXI_DM_araddr), .S_AXI_PL_arburst(M_AXI_DM_arburst), .S_AXI_PL_arcache(4'b0011), .S_AXI_PL_arlen(M_AXI_DM_arlen), .S_AXI_PL_arlock(1'b0), .S_AXI_PL_arprot(3'b000), .S_AXI_PL_arqos(4'b0000), .S_AXI_PL_arready(M_AXI_DM_arready), .S_AXI_PL_arsize(M_AXI_DM_arsize), .S_AXI_PL_arvalid(M_AXI_DM_arvalid),
    .S_AXI_PL_awaddr(64'd0), .S_AXI_PL_awburst(2'b01), .S_AXI_PL_awcache(4'b0011), .S_AXI_PL_awlen(8'd0), .S_AXI_PL_awlock(1'b0), .S_AXI_PL_awprot(3'b000), .S_AXI_PL_awqos(4'b0000), .S_AXI_PL_awready(), .S_AXI_PL_awsize(3'd4), .S_AXI_PL_awvalid(1'b0),
    .S_AXI_PL_bready(1'b1), .S_AXI_PL_bresp(), .S_AXI_PL_bvalid(),
    .S_AXI_PL_rdata(M_AXI_DM_rdata), .S_AXI_PL_rlast(M_AXI_DM_rlast), .S_AXI_PL_rready(M_AXI_DM_rready), .S_AXI_PL_rresp(M_AXI_DM_rresp), .S_AXI_PL_rvalid(M_AXI_DM_rvalid),
    .S_AXI_PL_wdata(512'd0), .S_AXI_PL_wlast(1'b1), .S_AXI_PL_wready(), .S_AXI_PL_wstrb(64'd0), .S_AXI_PL_wvalid(1'b0),
    .M_AXI_DDR_araddr(DDR_araddr), .M_AXI_DDR_arburst(DDR_arburst), .M_AXI_DDR_arcache(DDR_arcache), .M_AXI_DDR_arlen(DDR_arlen), .M_AXI_DDR_arlock(DDR_arlock), .M_AXI_DDR_arprot(DDR_arprot), .M_AXI_DDR_arqos(DDR_arqos), .M_AXI_DDR_arready(DDR_arready), .M_AXI_DDR_arsize(DDR_arsize), .M_AXI_DDR_aruser(DDR_aruser), .M_AXI_DDR_arvalid(DDR_arvalid),
    .M_AXI_DDR_awaddr(DDR_awaddr), .M_AXI_DDR_awburst(DDR_awburst), .M_AXI_DDR_awcache(DDR_awcache), .M_AXI_DDR_awlen(DDR_awlen), .M_AXI_DDR_awlock(DDR_awlock), .M_AXI_DDR_awprot(DDR_awprot), .M_AXI_DDR_awqos(DDR_awqos), .M_AXI_DDR_awready(DDR_awready), .M_AXI_DDR_awsize(DDR_awsize), .M_AXI_DDR_awuser(DDR_awuser), .M_AXI_DDR_awvalid(DDR_awvalid),
    .M_AXI_DDR_bready(DDR_bready), .M_AXI_DDR_bresp(DDR_bresp), .M_AXI_DDR_bvalid(DDR_bvalid),
    .M_AXI_DDR_rdata(DDR_rdata), .M_AXI_DDR_rlast(DDR_rlast), .M_AXI_DDR_rready(DDR_rready), .M_AXI_DDR_rresp(DDR_rresp), .M_AXI_DDR_rvalid(DDR_rvalid),
    .M_AXI_DDR_wdata(DDR_wdata), .M_AXI_DDR_wlast(DDR_wlast), .M_AXI_DDR_wready(DDR_wready), .M_AXI_DDR_wstrb(DDR_wstrb), .M_AXI_DDR_wvalid(DDR_wvalid),
    .aclk(ddr4_ui_clk), .aresetn(ddr4_ui_aresetn)
  );

  Ddr4CustomXczu47dr ddr4_i (
      .sys_rst(~pl_resetn0), .c0_sys_clk_p(c0_sys_clk_p), .c0_sys_clk_n(c0_sys_clk_n),
      .c0_ddr4_act_n(c0_ddr4_act_n), .c0_ddr4_adr(c0_ddr4_adr), .c0_ddr4_ba(c0_ddr4_ba), .c0_ddr4_bg(c0_ddr4_bg), .c0_ddr4_cke(c0_ddr4_cke), .c0_ddr4_odt(c0_ddr4_odt), .c0_ddr4_cs_n(c0_ddr4_cs_n), .c0_ddr4_ck_t(c0_ddr4_ck_t), .c0_ddr4_ck_c(c0_ddr4_ck_c), .c0_ddr4_reset_n(c0_ddr4_reset_n), .c0_ddr4_dm_n(c0_ddr4_dm_n), .c0_ddr4_dq(c0_ddr4_dq), .c0_ddr4_dqs_c(c0_ddr4_dqs_c), .c0_ddr4_dqs_t(c0_ddr4_dqs_t),
      .c0_init_calib_complete(ddr_init_calib_complete), .c0_ddr4_ui_clk(ddr4_ui_clk), .c0_ddr4_ui_clk_sync_rst(ddr4_ui_clk_sync_rst), .c0_ddr4_aresetn(ddr4_ui_aresetn),
      .s_axi_awaddr(DDR_awaddr), .s_axi_awlen(DDR_awlen), .s_axi_awsize(DDR_awsize), .s_axi_awburst(DDR_awburst), .s_axi_awlock(DDR_awlock), .s_axi_awcache(DDR_awcache), .s_axi_awprot(DDR_awprot), .s_axi_awqos(DDR_awqos), .s_axi_awvalid(DDR_awvalid), .s_axi_awready(DDR_awready),
      .s_axi_wdata(DDR_wdata), .s_axi_wstrb(DDR_wstrb), .s_axi_wlast(DDR_wlast), .s_axi_wvalid(DDR_wvalid), .s_axi_wready(DDR_wready),
      .s_axi_bready(DDR_bready), .s_axi_bresp(DDR_bresp), .s_axi_bvalid(DDR_bvalid),
      .s_axi_araddr(DDR_araddr), .s_axi_arlen(DDR_arlen), .s_axi_arsize(DDR_arsize), .s_axi_arburst(DDR_arburst), .s_axi_arlock(DDR_arlock), .s_axi_arcache(DDR_arcache), .s_axi_arprot(DDR_arprot), .s_axi_arqos(DDR_arqos), .s_axi_arvalid(DDR_arvalid), .s_axi_arready(DDR_arready),
      .s_axi_rready(DDR_rready), .s_axi_rdata(DDR_rdata), .s_axi_rresp(DDR_rresp), .s_axi_rlast(DDR_rlast), .s_axi_rvalid(DDR_rvalid)
  );

  reg [23:0] alive_count;
  always @(posedge ddr4_ui_clk or negedge ddr4_ui_aresetn) begin
    if(!ddr4_ui_aresetn) alive_count <= 24'd0;
    else alive_count <= alive_count + 24'd1;
  end
  assign TRIG_1 = alive_count[23];

  wire _unused = &{1'b0, M_AXI_CTRL_awprot, M_AXI_CTRL_arprot, M_AXI_INST_awburst, M_AXI_INST_awcache, M_AXI_INST_awlock, M_AXI_INST_awprot, M_AXI_INST_awqos, M_AXI_INST_awsize, M_AXI_INST_awuser, M_AXI_INST_wlast, M_AXI_INST_arburst, M_AXI_INST_arcache, M_AXI_INST_arlock, M_AXI_INST_arprot, M_AXI_INST_arqos, M_AXI_INST_arsize, M_AXI_INST_aruser, M_AXI_PS_DDR_awid, M_AXI_PS_DDR_bid, M_AXI_PS_DDR_arid, M_AXI_PS_DDR_rid, dm_mm2s_err, dm_data_tlast, dm_mm2s_sts_tvalid, dm_mm2s_sts_tlast, dm_mm2s_sts_tdata, dm_mm2s_sts_tkeep, unused_instr_tdata, unused_instr_tvalid};

endmodule
