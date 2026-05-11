package axidma

import chisel3._
import chisel3.util._
import chisel3.experimental.{IntParam, StringParam}
import common.axi._

class AXIL_DMA
    extends AXIL(
      ADDR_WIDTH = 10,
      DATA_WIDTH = 32
    ) {}

class AXIDmaBB(
    ADDR_WIDTH: Int,
    DATA_WIDTH: Int,
    IP_INSTANCE_NAME: String
) extends BlackBox(
      Map(
        "C_M_AXI_MM2S_ADDR_WIDTH" -> IntParam(ADDR_WIDTH),
        "C_M_AXIS_MM2S_TDATA_WIDTH" -> IntParam(DATA_WIDTH),
        "C_ADDR_WIDTH" -> IntParam(ADDR_WIDTH)
      )
    ) {

  override def desiredName = IP_INSTANCE_NAME

  val io = IO(new Bundle {
    val s_axi_lite_aclk = Input(Clock())
    val m_axi_mm2s_aclk = Input(Clock())
    val axi_resetn = Input(Bool())

    val s_axi_lite_awvalid = Input(Bool())
    val s_axi_lite_awready = Output(Bool())
    val s_axi_lite_awaddr = Input(UInt(10.W))

    val s_axi_lite_wvalid = Input(Bool())
    val s_axi_lite_wready = Output(Bool())
    val s_axi_lite_wdata = Input(UInt(32.W))

    val s_axi_lite_bresp = Output(UInt(2.W))
    val s_axi_lite_bvalid = Output(Bool())
    val s_axi_lite_bready = Input(Bool())

    val s_axi_lite_arvalid = Input(Bool())
    val s_axi_lite_arready = Output(Bool())
    val s_axi_lite_araddr = Input(UInt(10.W))

    val s_axi_lite_rvalid = Output(Bool())
    val s_axi_lite_rready = Input(Bool())
    val s_axi_lite_rdata = Output(UInt(32.W))
    val s_axi_lite_rresp = Output(UInt(2.W))

    val m_axi_mm2s_araddr = Output(UInt(ADDR_WIDTH.W))
    val m_axi_mm2s_arlen = Output(UInt(8.W))
    val m_axi_mm2s_arsize = Output(UInt(3.W))
    val m_axi_mm2s_arburst = Output(UInt(2.W))
    val m_axi_mm2s_arprot = Output(UInt(3.W))
    val m_axi_mm2s_arcache = Output(UInt(4.W))
    val m_axi_mm2s_arvalid = Output(Bool())
    val m_axi_mm2s_arready = Input(Bool())

    val m_axi_mm2s_rdata = Input(UInt(DATA_WIDTH.W))
    val m_axi_mm2s_rresp = Input(UInt(2.W))
    val m_axi_mm2s_rlast = Input(Bool())
    val m_axi_mm2s_rvalid = Input(Bool())
    val m_axi_mm2s_rready = Output(Bool())

    val m_axis_mm2s_tdata = Output(UInt(DATA_WIDTH.W))
    val m_axis_mm2s_tkeep = Output(UInt((DATA_WIDTH / 8).W))
    val m_axis_mm2s_tvalid = Output(Bool())
    val m_axis_mm2s_tready = Input(Bool())
    val m_axis_mm2s_tlast = Output(Bool())

    val mm2s_introut = Output(Bool())
  })
}

class AXIDMA(
    ADDR_WIDTH: Int = 64,
    DATA_WIDTH: Int = 128,
    BURST_SIZE: Int = 256,
    IP_NAME: String = "axi_dma_0"
) extends Module {

  val io = IO(new Bundle {
    val m_axi_mm2s_aclk = Input(Clock())

    val ctrl = Flipped(new AXIL_DMA())

    val mem_rd = new Bundle {
      val ar = Decoupled(new Bundle {
        val addr = UInt(ADDR_WIDTH.W)
        val len = UInt(8.W)
        val size = UInt(3.W)
        val burst = UInt(2.W)
        val lock = Bool()
        val cache = UInt(4.W)
        val prot = UInt(3.W)
      })
      val r = Flipped(Decoupled(new Bundle {
        val data = UInt(DATA_WIDTH.W)
        val resp = UInt(2.W)
        val last = Bool()
      }))
    }

    val stream = Decoupled(new Bundle {
      val data = UInt(DATA_WIDTH.W)
      val keep = UInt((DATA_WIDTH / 8).W)
      val last = Bool()
    })

    val irq = Output(Bool())
  })

  def getTCL() = {
    val createCmd =
      s"\ncreate_ip -name axi_dma -vendor xilinx.com -library ip -version 7.1 -module_name ${IP_NAME}\n"

    var propCmd = s"set_property -dict [list "
    propCmd += s"CONFIG.c_addr_width {${ADDR_WIDTH}} "
    propCmd += s"CONFIG.c_include_mm2s_dre {0} "
    propCmd += s"CONFIG.c_include_s2mm {0} "
    propCmd += s"CONFIG.c_include_sg {0} "
    propCmd += s"CONFIG.c_m_axis_mm2s_tdata_width {${DATA_WIDTH}} "
    propCmd += s"CONFIG.c_m_axi_mm2s_data_width {${DATA_WIDTH}} "
    propCmd += s"CONFIG.c_mm2s_burst_size {${BURST_SIZE}} "
    propCmd += s"CONFIG.c_sg_length_width {26} "
    propCmd += s"CONFIG.c_prmry_is_aclk_async {1} "
    propCmd += s"] [get_ips ${IP_NAME}]\n"

    println(createCmd + propCmd)
  }

  getTCL()

  val dma_ip = Module(new AXIDmaBB(ADDR_WIDTH, DATA_WIDTH, IP_NAME))

  dma_ip.io.s_axi_lite_aclk := clock
  dma_ip.io.m_axi_mm2s_aclk := io.m_axi_mm2s_aclk
  dma_ip.io.axi_resetn := !reset.asBool

  dma_ip.io.s_axi_lite_awvalid := io.ctrl.aw.valid
  dma_ip.io.s_axi_lite_awaddr := io.ctrl.aw.bits.addr
  io.ctrl.aw.ready := dma_ip.io.s_axi_lite_awready

  dma_ip.io.s_axi_lite_wvalid := io.ctrl.w.valid
  dma_ip.io.s_axi_lite_wdata := io.ctrl.w.bits.data
  io.ctrl.w.ready := dma_ip.io.s_axi_lite_wready

  io.ctrl.b.valid := dma_ip.io.s_axi_lite_bvalid
  io.ctrl.b.bits.resp := dma_ip.io.s_axi_lite_bresp
  dma_ip.io.s_axi_lite_bready := io.ctrl.b.ready

  io.ctrl.b.bits.id := 0.U
  io.ctrl.b.bits.user := 0.U

  dma_ip.io.s_axi_lite_arvalid := io.ctrl.ar.valid
  dma_ip.io.s_axi_lite_araddr := io.ctrl.ar.bits.addr
  io.ctrl.ar.ready := dma_ip.io.s_axi_lite_arready

  io.ctrl.r.valid := dma_ip.io.s_axi_lite_rvalid
  io.ctrl.r.bits.data := dma_ip.io.s_axi_lite_rdata
  io.ctrl.r.bits.resp := dma_ip.io.s_axi_lite_rresp
  dma_ip.io.s_axi_lite_rready := io.ctrl.r.ready

  io.ctrl.r.bits.id := 0.U
  io.ctrl.r.bits.user := 0.U
  io.ctrl.r.bits.last := true.B

  io.mem_rd.ar.valid := dma_ip.io.m_axi_mm2s_arvalid
  io.mem_rd.ar.bits.addr := dma_ip.io.m_axi_mm2s_araddr
  io.mem_rd.ar.bits.len := dma_ip.io.m_axi_mm2s_arlen
  io.mem_rd.ar.bits.size := dma_ip.io.m_axi_mm2s_arsize
  io.mem_rd.ar.bits.burst := dma_ip.io.m_axi_mm2s_arburst
  io.mem_rd.ar.bits.prot := dma_ip.io.m_axi_mm2s_arprot
  io.mem_rd.ar.bits.cache := dma_ip.io.m_axi_mm2s_arcache
  io.mem_rd.ar.bits.lock := false.B
  dma_ip.io.m_axi_mm2s_arready := io.mem_rd.ar.ready

  dma_ip.io.m_axi_mm2s_rvalid := io.mem_rd.r.valid
  dma_ip.io.m_axi_mm2s_rdata := io.mem_rd.r.bits.data
  dma_ip.io.m_axi_mm2s_rresp := io.mem_rd.r.bits.resp
  dma_ip.io.m_axi_mm2s_rlast := io.mem_rd.r.bits.last
  io.mem_rd.r.ready := dma_ip.io.m_axi_mm2s_rready

  io.stream.valid := dma_ip.io.m_axis_mm2s_tvalid
  io.stream.bits.data := dma_ip.io.m_axis_mm2s_tdata
  io.stream.bits.keep := dma_ip.io.m_axis_mm2s_tkeep
  io.stream.bits.last := dma_ip.io.m_axis_mm2s_tlast
  dma_ip.io.m_axis_mm2s_tready := io.stream.ready

  io.irq := dma_ip.io.mm2s_introut
}
