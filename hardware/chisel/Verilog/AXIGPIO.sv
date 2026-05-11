module AXIGPIO(
  input         clock,
  input         reset,
  output        io_axi_aw_ready,
  input         io_axi_aw_valid,
  input  [8:0]  io_axi_aw_bits_addr,
  input  [1:0]  io_axi_aw_bits_burst,
  input  [3:0]  io_axi_aw_bits_cache,
  input         io_axi_aw_bits_lock,
  input  [2:0]  io_axi_aw_bits_prot,
  input  [3:0]  io_axi_aw_bits_qos,
  input  [3:0]  io_axi_aw_bits_region,
  input  [2:0]  io_axi_aw_bits_size,
  output        io_axi_ar_ready,
  input         io_axi_ar_valid,
  input  [8:0]  io_axi_ar_bits_addr,
  input  [1:0]  io_axi_ar_bits_burst,
  input  [3:0]  io_axi_ar_bits_cache,
  input         io_axi_ar_bits_lock,
  input  [2:0]  io_axi_ar_bits_prot,
  input  [3:0]  io_axi_ar_bits_qos,
  input  [3:0]  io_axi_ar_bits_region,
  input  [2:0]  io_axi_ar_bits_size,
  output        io_axi_w_ready,
  input         io_axi_w_valid,
  input  [31:0] io_axi_w_bits_data,
  input         io_axi_w_bits_last,
  input  [3:0]  io_axi_w_bits_strb,
  input         io_axi_r_ready,
  output        io_axi_r_valid,
  output [31:0] io_axi_r_bits_data,
  output        io_axi_r_bits_last,
  output [1:0]  io_axi_r_bits_resp,
  input         io_axi_b_ready,
  output        io_axi_b_valid,
  output [1:0]  io_axi_b_bits_resp,
  output [1:0]  io_gpio,
  output [31:0] io_gpio2
);
  wire  ip_s_axi_aclk; // @[GPIO.scala 71:18]
  wire  ip_s_axi_aresetn; // @[GPIO.scala 71:18]
  wire [8:0] ip_s_axi_awaddr; // @[GPIO.scala 71:18]
  wire  ip_s_axi_awvalid; // @[GPIO.scala 71:18]
  wire  ip_s_axi_awready; // @[GPIO.scala 71:18]
  wire [31:0] ip_s_axi_wdata; // @[GPIO.scala 71:18]
  wire [3:0] ip_s_axi_wstrb; // @[GPIO.scala 71:18]
  wire  ip_s_axi_wvalid; // @[GPIO.scala 71:18]
  wire  ip_s_axi_wready; // @[GPIO.scala 71:18]
  wire [1:0] ip_s_axi_bresp; // @[GPIO.scala 71:18]
  wire  ip_s_axi_bvalid; // @[GPIO.scala 71:18]
  wire  ip_s_axi_bready; // @[GPIO.scala 71:18]
  wire [8:0] ip_s_axi_araddr; // @[GPIO.scala 71:18]
  wire  ip_s_axi_arvalid; // @[GPIO.scala 71:18]
  wire  ip_s_axi_arready; // @[GPIO.scala 71:18]
  wire [31:0] ip_s_axi_rdata; // @[GPIO.scala 71:18]
  wire [1:0] ip_s_axi_rresp; // @[GPIO.scala 71:18]
  wire  ip_s_axi_rvalid; // @[GPIO.scala 71:18]
  wire  ip_s_axi_rready; // @[GPIO.scala 71:18]
  wire [1:0] ip_gpio_io_o; // @[GPIO.scala 71:18]
  wire [31:0] ip_gpio2_io_o; // @[GPIO.scala 71:18]
  AXIGPIOBlackBox ip ( // @[GPIO.scala 71:18]
    .s_axi_aclk(ip_s_axi_aclk),
    .s_axi_aresetn(ip_s_axi_aresetn),
    .s_axi_awaddr(ip_s_axi_awaddr),
    .s_axi_awvalid(ip_s_axi_awvalid),
    .s_axi_awready(ip_s_axi_awready),
    .s_axi_wdata(ip_s_axi_wdata),
    .s_axi_wstrb(ip_s_axi_wstrb),
    .s_axi_wvalid(ip_s_axi_wvalid),
    .s_axi_wready(ip_s_axi_wready),
    .s_axi_bresp(ip_s_axi_bresp),
    .s_axi_bvalid(ip_s_axi_bvalid),
    .s_axi_bready(ip_s_axi_bready),
    .s_axi_araddr(ip_s_axi_araddr),
    .s_axi_arvalid(ip_s_axi_arvalid),
    .s_axi_arready(ip_s_axi_arready),
    .s_axi_rdata(ip_s_axi_rdata),
    .s_axi_rresp(ip_s_axi_rresp),
    .s_axi_rvalid(ip_s_axi_rvalid),
    .s_axi_rready(ip_s_axi_rready),
    .gpio_io_o(ip_gpio_io_o),
    .gpio2_io_o(ip_gpio2_io_o)
  );
  assign io_axi_aw_ready = ip_s_axi_awready; // @[GPIO.scala 92:19]
  assign io_axi_ar_ready = ip_s_axi_arready; // @[GPIO.scala 122:19]
  assign io_axi_w_ready = ip_s_axi_wready; // @[GPIO.scala 102:18]
  assign io_axi_r_valid = ip_s_axi_rvalid; // @[GPIO.scala 130:18]
  assign io_axi_r_bits_data = ip_s_axi_rdata; // @[GPIO.scala 128:22]
  assign io_axi_r_bits_last = 1'h1; // @[GPIO.scala 135:22]
  assign io_axi_r_bits_resp = ip_s_axi_rresp; // @[GPIO.scala 129:22]
  assign io_axi_b_valid = ip_s_axi_bvalid; // @[GPIO.scala 109:18]
  assign io_axi_b_bits_resp = ip_s_axi_bresp; // @[GPIO.scala 108:22]
  assign io_gpio = ip_gpio_io_o; // @[GPIO.scala 141:11]
  assign io_gpio2 = ip_gpio2_io_o; // @[GPIO.scala 142:12]
  assign ip_s_axi_aclk = clock; // @[GPIO.scala 82:20]
  assign ip_s_axi_aresetn = ~reset; // @[GPIO.scala 83:26]
  assign ip_s_axi_awaddr = io_axi_aw_bits_addr; // @[GPIO.scala 89:22]
  assign ip_s_axi_awvalid = io_axi_aw_valid; // @[GPIO.scala 90:23]
  assign ip_s_axi_wdata = io_axi_w_bits_data; // @[GPIO.scala 98:21]
  assign ip_s_axi_wstrb = io_axi_w_bits_strb; // @[GPIO.scala 99:21]
  assign ip_s_axi_wvalid = io_axi_w_valid; // @[GPIO.scala 100:22]
  assign ip_s_axi_bready = io_axi_b_ready; // @[GPIO.scala 111:22]
  assign ip_s_axi_araddr = io_axi_ar_bits_addr; // @[GPIO.scala 119:22]
  assign ip_s_axi_arvalid = io_axi_ar_valid; // @[GPIO.scala 120:23]
  assign ip_s_axi_rready = io_axi_r_ready; // @[GPIO.scala 132:22]
endmodule
