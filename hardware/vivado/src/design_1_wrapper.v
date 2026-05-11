`timescale 1 ps / 1 ps

module design_1_wrapper (
    output [0:0] LED0,
    output [0:0] LED1,
    output [1:0] clk104_clk_spi_mux_sel_tri_o,

    input  adc2_clk_clk_n,
    input  adc2_clk_clk_p,
    input  dac2_clk_clk_n,
    input  dac2_clk_clk_p,
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
    output vout30_v_p
);

  wire        pl_clk;
  wire        pl_aresetn;
  wire        clk_adc2;
  wire        clk_dac2;
  wire        clk104_aresetn;

  wire [31:0] M_AXI_GPIO_araddr;
  wire [ 1:0] M_AXI_GPIO_arburst;
  wire [ 3:0] M_AXI_GPIO_arcache;
  wire [ 7:0] M_AXI_GPIO_arlen;
  wire [ 0:0] M_AXI_GPIO_arlock;
  wire [ 2:0] M_AXI_GPIO_arprot;
  wire [ 3:0] M_AXI_GPIO_arqos;
  wire        M_AXI_GPIO_arready;
  wire [ 2:0] M_AXI_GPIO_arsize;
  wire [15:0] M_AXI_GPIO_aruser;
  wire        M_AXI_GPIO_arvalid;
  wire [31:0] M_AXI_GPIO_awaddr;
  wire [ 1:0] M_AXI_GPIO_awburst;
  wire [ 3:0] M_AXI_GPIO_awcache;
  wire [ 7:0] M_AXI_GPIO_awlen;
  wire [ 0:0] M_AXI_GPIO_awlock;
  wire [ 2:0] M_AXI_GPIO_awprot;
  wire [ 3:0] M_AXI_GPIO_awqos;
  wire        M_AXI_GPIO_awready;
  wire [ 2:0] M_AXI_GPIO_awsize;
  wire [15:0] M_AXI_GPIO_awuser;
  wire        M_AXI_GPIO_awvalid;
  wire        M_AXI_GPIO_bready;
  wire [ 1:0] M_AXI_GPIO_bresp;
  wire        M_AXI_GPIO_bvalid;
  wire [31:0] M_AXI_GPIO_rdata;
  wire        M_AXI_GPIO_rlast;
  wire        M_AXI_GPIO_rready;
  wire [ 1:0] M_AXI_GPIO_rresp;
  wire        M_AXI_GPIO_rvalid;
  wire [31:0] M_AXI_GPIO_wdata;
  wire        M_AXI_GPIO_wlast;
  wire        M_AXI_GPIO_wready;
  wire [ 3:0] M_AXI_GPIO_wstrb;
  wire        M_AXI_GPIO_wvalid;

  wire [31:0] M_AXI_BRAM_araddr;
  wire [ 1:0] M_AXI_BRAM_arburst;
  wire [ 3:0] M_AXI_BRAM_arcache;
  wire [ 7:0] M_AXI_BRAM_arlen;
  wire [ 0:0] M_AXI_BRAM_arlock;
  wire [ 2:0] M_AXI_BRAM_arprot;
  wire [ 3:0] M_AXI_BRAM_arqos;
  wire        M_AXI_BRAM_arready;
  wire [ 2:0] M_AXI_BRAM_arsize;
  wire [15:0] M_AXI_BRAM_aruser;
  wire        M_AXI_BRAM_arvalid;
  wire [31:0] M_AXI_BRAM_awaddr;
  wire [ 1:0] M_AXI_BRAM_awburst;
  wire [ 3:0] M_AXI_BRAM_awcache;
  wire [ 7:0] M_AXI_BRAM_awlen;
  wire [ 0:0] M_AXI_BRAM_awlock;
  wire [ 2:0] M_AXI_BRAM_awprot;
  wire [ 3:0] M_AXI_BRAM_awqos;
  wire        M_AXI_BRAM_awready;
  wire [ 2:0] M_AXI_BRAM_awsize;
  wire [15:0] M_AXI_BRAM_awuser;
  wire        M_AXI_BRAM_awvalid;
  wire        M_AXI_BRAM_bready;
  wire [ 1:0] M_AXI_BRAM_bresp;
  wire        M_AXI_BRAM_bvalid;
  wire [31:0] M_AXI_BRAM_rdata;
  wire        M_AXI_BRAM_rlast;
  wire        M_AXI_BRAM_rready;
  wire [ 1:0] M_AXI_BRAM_rresp;
  wire        M_AXI_BRAM_rvalid;
  wire [31:0] M_AXI_BRAM_wdata;
  wire        M_AXI_BRAM_wlast;
  wire        M_AXI_BRAM_wready;
  wire [ 3:0] M_AXI_BRAM_wstrb;
  wire        M_AXI_BRAM_wvalid;

  design_1 design_1_i (
      .pl_clk(pl_clk),
      .pl_aresetn(pl_aresetn),
      .clk_adc2(clk_adc2),
      .clk_dac2(clk_dac2),
      .clk104_aresetn(clk104_aresetn),

      .adc2_clk_clk_n(adc2_clk_clk_n),
      .adc2_clk_clk_p(adc2_clk_clk_p),
      .dac2_clk_clk_n(dac2_clk_clk_n),
      .dac2_clk_clk_p(dac2_clk_clk_p),
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
      .M_AXI_GPIO_wvalid (M_AXI_GPIO_wvalid),

      .M_AXI_BRAM_araddr (M_AXI_BRAM_araddr),
      .M_AXI_BRAM_arburst(M_AXI_BRAM_arburst),
      .M_AXI_BRAM_arcache(M_AXI_BRAM_arcache),
      .M_AXI_BRAM_arlen  (M_AXI_BRAM_arlen),
      .M_AXI_BRAM_arlock (M_AXI_BRAM_arlock),
      .M_AXI_BRAM_arprot (M_AXI_BRAM_arprot),
      .M_AXI_BRAM_arqos  (M_AXI_BRAM_arqos),
      .M_AXI_BRAM_arready(M_AXI_BRAM_arready),
      .M_AXI_BRAM_arsize (M_AXI_BRAM_arsize),
      .M_AXI_BRAM_aruser (M_AXI_BRAM_aruser),
      .M_AXI_BRAM_arvalid(M_AXI_BRAM_arvalid),
      .M_AXI_BRAM_awaddr (M_AXI_BRAM_awaddr),
      .M_AXI_BRAM_awburst(M_AXI_BRAM_awburst),
      .M_AXI_BRAM_awcache(M_AXI_BRAM_awcache),
      .M_AXI_BRAM_awlen  (M_AXI_BRAM_awlen),
      .M_AXI_BRAM_awlock (M_AXI_BRAM_awlock),
      .M_AXI_BRAM_awprot (M_AXI_BRAM_awprot),
      .M_AXI_BRAM_awqos  (M_AXI_BRAM_awqos),
      .M_AXI_BRAM_awready(M_AXI_BRAM_awready),
      .M_AXI_BRAM_awsize (M_AXI_BRAM_awsize),
      .M_AXI_BRAM_awuser (M_AXI_BRAM_awuser),
      .M_AXI_BRAM_awvalid(M_AXI_BRAM_awvalid),
      .M_AXI_BRAM_bready (M_AXI_BRAM_bready),
      .M_AXI_BRAM_bresp  (M_AXI_BRAM_bresp),
      .M_AXI_BRAM_bvalid (M_AXI_BRAM_bvalid),
      .M_AXI_BRAM_rdata  (M_AXI_BRAM_rdata),
      .M_AXI_BRAM_rlast  (M_AXI_BRAM_rlast),
      .M_AXI_BRAM_rready (M_AXI_BRAM_rready),
      .M_AXI_BRAM_rresp  (M_AXI_BRAM_rresp),
      .M_AXI_BRAM_rvalid (M_AXI_BRAM_rvalid),
      .M_AXI_BRAM_wdata  (M_AXI_BRAM_wdata),
      .M_AXI_BRAM_wlast  (M_AXI_BRAM_wlast),
      .M_AXI_BRAM_wready (M_AXI_BRAM_wready),
      .M_AXI_BRAM_wstrb  (M_AXI_BRAM_wstrb),
      .M_AXI_BRAM_wvalid (M_AXI_BRAM_wvalid)
  );

  AXIGPIO axigpio_i (
      .clock(pl_clk),
      .reset(~pl_aresetn),
      // AW
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
      // AR
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
      // W
      .io_axi_w_ready(M_AXI_GPIO_wready),
      .io_axi_w_valid(M_AXI_GPIO_wvalid),
      .io_axi_w_bits_data(M_AXI_GPIO_wdata),
      .io_axi_w_bits_last(M_AXI_GPIO_wlast),
      .io_axi_w_bits_strb(M_AXI_GPIO_wstrb),
      // R
      .io_axi_r_ready(M_AXI_GPIO_rready),
      .io_axi_r_valid(M_AXI_GPIO_rvalid),
      .io_axi_r_bits_data(M_AXI_GPIO_rdata),
      .io_axi_r_bits_last(M_AXI_GPIO_rlast),
      .io_axi_r_bits_resp(M_AXI_GPIO_rresp),
      // B
      .io_axi_b_ready(M_AXI_GPIO_bready),
      .io_axi_b_valid(M_AXI_GPIO_bvalid),
      .io_axi_b_bits_resp(M_AXI_GPIO_bresp),
      // GPIO Pin
      .io_gpio(clk104_clk_spi_mux_sel_tri_o)
  );

  LED led_i (
      .io_CLK (clk_adc2),
      .io_CLK1(clk_dac2),
      .io_LED0(LED0),
      .io_LED1(LED1)
  );

  AXIBRAM axibram_i (
      .clock(clk_dac2),
      .reset(~clk104_aresetn),

      .io_axi_aw_ready(M_AXI_BRAM_awready),
      .io_axi_aw_valid(M_AXI_BRAM_awvalid),
      .io_axi_aw_bits_addr(M_AXI_BRAM_awaddr[12:0]),
      .io_axi_aw_bits_burst(M_AXI_BRAM_awburst),
      .io_axi_aw_bits_cache(M_AXI_BRAM_awcache),
      .io_axi_aw_bits_len(M_AXI_BRAM_awlen),
      .io_axi_aw_bits_lock(M_AXI_BRAM_awlock),
      .io_axi_aw_bits_prot(M_AXI_BRAM_awprot),
      .io_axi_aw_bits_qos(M_AXI_BRAM_awqos),
      .io_axi_aw_bits_region(4'b0000),
      .io_axi_aw_bits_size(M_AXI_BRAM_awsize),

      .io_axi_ar_ready(M_AXI_BRAM_arready),
      .io_axi_ar_valid(M_AXI_BRAM_arvalid),
      .io_axi_ar_bits_addr(M_AXI_BRAM_araddr[12:0]),
      .io_axi_ar_bits_burst(M_AXI_BRAM_arburst),
      .io_axi_ar_bits_cache(M_AXI_BRAM_arcache),
      .io_axi_ar_bits_len(M_AXI_BRAM_arlen),
      .io_axi_ar_bits_lock(M_AXI_BRAM_arlock),
      .io_axi_ar_bits_prot(M_AXI_BRAM_arprot),
      .io_axi_ar_bits_qos(M_AXI_BRAM_arqos),
      .io_axi_ar_bits_region(4'b0000),
      .io_axi_ar_bits_size(M_AXI_BRAM_arsize),

      .io_axi_w_ready(M_AXI_BRAM_wready),
      .io_axi_w_valid(M_AXI_BRAM_wvalid),
      .io_axi_w_bits_data(M_AXI_BRAM_wdata),
      .io_axi_w_bits_last(M_AXI_BRAM_wlast),
      .io_axi_w_bits_strb(M_AXI_BRAM_wstrb),

      .io_axi_r_ready(M_AXI_BRAM_rready),
      .io_axi_r_valid(M_AXI_BRAM_rvalid),
      .io_axi_r_bits_data(M_AXI_BRAM_rdata),
      .io_axi_r_bits_last(M_AXI_BRAM_rlast),
      .io_axi_r_bits_resp(M_AXI_BRAM_rresp),

      .io_axi_b_ready(M_AXI_BRAM_bready),
      .io_axi_b_valid(M_AXI_BRAM_bvalid),
      .io_axi_b_bits_resp(M_AXI_BRAM_bresp)
  );

endmodule
