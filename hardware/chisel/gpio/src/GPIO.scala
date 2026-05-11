package gpio

import chisel3._
import chisel3.util._
import common._
import common.storage._
import common.axi._

class AXIL_GPIO
    extends AXIL(
      ADDR_WIDTH = 9,
      DATA_WIDTH = 32
    ) {}

class AXIGPIO(
    GPIO_WIDTH: Int = 2,
    GPIO2_WIDTH: Int = 32,
    IP_INSTANCE_NAME: String = "AXIGPIOBlackBox"
) extends Module {

  val io = IO(new Bundle {
    val axi = Flipped(new AXIL_GPIO)

    val gpio = Output(UInt(GPIO_WIDTH.W))
    val gpio2 = Output(UInt(GPIO2_WIDTH.W))
  })

  // ------------------------------------------------------------
  // Vivado TCL Generator
  // ------------------------------------------------------------

  def getTCL() = {

    var s = ""

    s += s"\ncreate_ip -name axi_gpio "
    s += s"-vendor xilinx.com "
    s += s"-library ip "
    s += s"-version 2.0 "
    s += s"-module_name ${IP_INSTANCE_NAME}\n"

    s += s"\nset_property -dict [list "

    s += s"CONFIG.C_GPIO_WIDTH {${GPIO_WIDTH}} "
    s += s"CONFIG.C_ALL_OUTPUTS {1} "
    s += s"CONFIG.C_IS_DUAL {1} "
    s += s"CONFIG.C_GPIO2_WIDTH {${GPIO2_WIDTH}} "
    s += s"CONFIG.C_ALL_OUTPUTS_2 {1} "
    s += s"CONFIG.C_ALL_INPUTS {0} "
    s += s"CONFIG.C_DOUT_DEFAULT {0x00000000} "
    s += s"CONFIG.C_TRI_DEFAULT {0xFFFFFFFF} "

    s += s"] [get_ips ${IP_INSTANCE_NAME}]\n"

    println(s)
  }

  getTCL()

  // ------------------------------------------------------------
  // AXI Default
  // ------------------------------------------------------------

  io.axi.b.bits.user := 0.U
  io.axi.r.bits.user := 0.U

  // ------------------------------------------------------------
  // Instantiate Vivado IP
  // ------------------------------------------------------------

  val ip = Module(
    new AXIGPIOBlackBox(
      GPIO_WIDTH = GPIO_WIDTH,
      GPIO2_WIDTH = GPIO2_WIDTH
    )
  )

  // ------------------------------------------------------------
  // Clock & Reset
  // ------------------------------------------------------------

  ip.io.s_axi_aclk := clock
  ip.io.s_axi_aresetn := !reset.asBool

  // ------------------------------------------------------------
  // AXI Write Address
  // ------------------------------------------------------------

  ip.io.s_axi_awaddr := io.axi.aw.bits.addr
  ip.io.s_axi_awvalid := io.axi.aw.valid

  io.axi.aw.ready := ip.io.s_axi_awready

  // ------------------------------------------------------------
  // AXI Write Data
  // ------------------------------------------------------------

  ip.io.s_axi_wdata := io.axi.w.bits.data
  ip.io.s_axi_wstrb := io.axi.w.bits.strb
  ip.io.s_axi_wvalid := io.axi.w.valid

  io.axi.w.ready := ip.io.s_axi_wready

  // ------------------------------------------------------------
  // AXI Write Response
  // ------------------------------------------------------------

  io.axi.b.bits.resp := ip.io.s_axi_bresp
  io.axi.b.valid := ip.io.s_axi_bvalid

  ip.io.s_axi_bready := io.axi.b.ready

  io.axi.b.bits.id := 0.U

  // ------------------------------------------------------------
  // AXI Read Address
  // ------------------------------------------------------------

  ip.io.s_axi_araddr := io.axi.ar.bits.addr
  ip.io.s_axi_arvalid := io.axi.ar.valid

  io.axi.ar.ready := ip.io.s_axi_arready

  // ------------------------------------------------------------
  // AXI Read Data
  // ------------------------------------------------------------

  io.axi.r.bits.data := ip.io.s_axi_rdata
  io.axi.r.bits.resp := ip.io.s_axi_rresp
  io.axi.r.valid := ip.io.s_axi_rvalid

  ip.io.s_axi_rready := io.axi.r.ready

  io.axi.r.bits.id := 0.U
  io.axi.r.bits.last := 1.U

  // ------------------------------------------------------------
  // GPIO Outputs
  // ------------------------------------------------------------

  io.gpio := ip.io.gpio_io_o
  io.gpio2 := ip.io.gpio2_io_o
}