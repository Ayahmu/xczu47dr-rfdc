circuit AXIGPIO :
  extmodule AXIGPIOBlackBox :
    input s_axi_aclk : Clock
    input s_axi_aresetn : UInt<1>
    input s_axi_awaddr : UInt<9>
    input s_axi_awvalid : UInt<1>
    output s_axi_awready : UInt<1>
    input s_axi_wdata : UInt<32>
    input s_axi_wstrb : UInt<4>
    input s_axi_wvalid : UInt<1>
    output s_axi_wready : UInt<1>
    output s_axi_bresp : UInt<2>
    output s_axi_bvalid : UInt<1>
    input s_axi_bready : UInt<1>
    input s_axi_araddr : UInt<9>
    input s_axi_arvalid : UInt<1>
    output s_axi_arready : UInt<1>
    output s_axi_rdata : UInt<32>
    output s_axi_rresp : UInt<2>
    output s_axi_rvalid : UInt<1>
    input s_axi_rready : UInt<1>
    output gpio_io_o : UInt<2>
    output gpio2_io_o : UInt<32>
    defname = AXIGPIOBlackBox

  module AXIGPIO :
    input clock : Clock
    input reset : UInt<1>
    output io : { flip axi : { aw : { flip ready : UInt<1>, valid : UInt<1>, bits : { addr : UInt<9>, burst : UInt<2>, cache : UInt<4>, id : UInt<0>, len : UInt<0>, lock : UInt<1>, prot : UInt<3>, qos : UInt<4>, region : UInt<4>, size : UInt<3>, user : UInt<0>}}, ar : { flip ready : UInt<1>, valid : UInt<1>, bits : { addr : UInt<9>, burst : UInt<2>, cache : UInt<4>, id : UInt<0>, len : UInt<0>, lock : UInt<1>, prot : UInt<3>, qos : UInt<4>, region : UInt<4>, size : UInt<3>, user : UInt<0>}}, w : { flip ready : UInt<1>, valid : UInt<1>, bits : { data : UInt<32>, user : UInt<0>, last : UInt<1>, strb : UInt<4>}}, flip r : { flip ready : UInt<1>, valid : UInt<1>, bits : { data : UInt<32>, user : UInt<0>, last : UInt<1>, resp : UInt<2>, id : UInt<0>}}, flip b : { flip ready : UInt<1>, valid : UInt<1>, bits : { id : UInt<0>, resp : UInt<2>, user : UInt<0>}}}, gpio : UInt<2>, gpio2 : UInt<32>}

    io.axi.b.bits.user <= UInt<1>("h0") @[GPIO.scala 64:22]
    io.axi.r.bits.user <= UInt<1>("h0") @[GPIO.scala 65:22]
    inst ip of AXIGPIOBlackBox @[GPIO.scala 71:18]
    ip.gpio2_io_o is invalid
    ip.gpio_io_o is invalid
    ip.s_axi_rready is invalid
    ip.s_axi_rvalid is invalid
    ip.s_axi_rresp is invalid
    ip.s_axi_rdata is invalid
    ip.s_axi_arready is invalid
    ip.s_axi_arvalid is invalid
    ip.s_axi_araddr is invalid
    ip.s_axi_bready is invalid
    ip.s_axi_bvalid is invalid
    ip.s_axi_bresp is invalid
    ip.s_axi_wready is invalid
    ip.s_axi_wvalid is invalid
    ip.s_axi_wstrb is invalid
    ip.s_axi_wdata is invalid
    ip.s_axi_awready is invalid
    ip.s_axi_awvalid is invalid
    ip.s_axi_awaddr is invalid
    ip.s_axi_aresetn is invalid
    ip.s_axi_aclk is invalid
    ip.s_axi_aclk <= clock @[GPIO.scala 82:20]
    node _ip_io_s_axi_aresetn_T = bits(reset, 0, 0) @[GPIO.scala 83:33]
    node _ip_io_s_axi_aresetn_T_1 = eq(_ip_io_s_axi_aresetn_T, UInt<1>("h0")) @[GPIO.scala 83:26]
    ip.s_axi_aresetn <= _ip_io_s_axi_aresetn_T_1 @[GPIO.scala 83:23]
    ip.s_axi_awaddr <= io.axi.aw.bits.addr @[GPIO.scala 89:22]
    ip.s_axi_awvalid <= io.axi.aw.valid @[GPIO.scala 90:23]
    io.axi.aw.ready <= ip.s_axi_awready @[GPIO.scala 92:19]
    ip.s_axi_wdata <= io.axi.w.bits.data @[GPIO.scala 98:21]
    ip.s_axi_wstrb <= io.axi.w.bits.strb @[GPIO.scala 99:21]
    ip.s_axi_wvalid <= io.axi.w.valid @[GPIO.scala 100:22]
    io.axi.w.ready <= ip.s_axi_wready @[GPIO.scala 102:18]
    io.axi.b.bits.resp <= ip.s_axi_bresp @[GPIO.scala 108:22]
    io.axi.b.valid <= ip.s_axi_bvalid @[GPIO.scala 109:18]
    ip.s_axi_bready <= io.axi.b.ready @[GPIO.scala 111:22]
    io.axi.b.bits.id <= UInt<1>("h0") @[GPIO.scala 113:20]
    ip.s_axi_araddr <= io.axi.ar.bits.addr @[GPIO.scala 119:22]
    ip.s_axi_arvalid <= io.axi.ar.valid @[GPIO.scala 120:23]
    io.axi.ar.ready <= ip.s_axi_arready @[GPIO.scala 122:19]
    io.axi.r.bits.data <= ip.s_axi_rdata @[GPIO.scala 128:22]
    io.axi.r.bits.resp <= ip.s_axi_rresp @[GPIO.scala 129:22]
    io.axi.r.valid <= ip.s_axi_rvalid @[GPIO.scala 130:18]
    ip.s_axi_rready <= io.axi.r.ready @[GPIO.scala 132:22]
    io.axi.r.bits.id <= UInt<1>("h0") @[GPIO.scala 134:20]
    io.axi.r.bits.last <= UInt<1>("h1") @[GPIO.scala 135:22]
    io.gpio <= ip.gpio_io_o @[GPIO.scala 141:11]
    io.gpio2 <= ip.gpio2_io_o @[GPIO.scala 142:12]

