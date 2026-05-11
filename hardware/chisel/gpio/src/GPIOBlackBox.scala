package gpio

import chisel3._
import chisel3.util._
import common._
import common.axi._

class AXIGPIOBlackBox(
    GPIO_WIDTH: Int = 2,
    GPIO2_WIDTH: Int = 32
) extends BlackBox {

  val io = IO(new Bundle {

    // AXI Lite Clock & Reset
    val s_axi_aclk = Input(Clock())
    val s_axi_aresetn = Input(Bool())

    // Write Address Channel
    val s_axi_awaddr = Input(UInt(9.W))
    val s_axi_awvalid = Input(Bool())
    val s_axi_awready = Output(Bool())

    // Write Data Channel
    val s_axi_wdata = Input(UInt(32.W))
    val s_axi_wstrb = Input(UInt(4.W))
    val s_axi_wvalid = Input(Bool())
    val s_axi_wready = Output(Bool())

    // Write Response Channel
    val s_axi_bresp = Output(UInt(2.W))
    val s_axi_bvalid = Output(Bool())
    val s_axi_bready = Input(Bool())

    // Read Address Channel
    val s_axi_araddr = Input(UInt(9.W))
    val s_axi_arvalid = Input(Bool())
    val s_axi_arready = Output(Bool())

    // Read Data Channel
    val s_axi_rdata = Output(UInt(32.W))
    val s_axi_rresp = Output(UInt(2.W))
    val s_axi_rvalid = Output(Bool())
    val s_axi_rready = Input(Bool())

    // GPIO Outputs
    val gpio_io_o = Output(UInt(GPIO_WIDTH.W))
    val gpio2_io_o = Output(UInt(GPIO2_WIDTH.W))
  })
}