package memory

import chisel3._
import chisel3.util._
import chisel3.experimental.{IntParam, StringParam}
import common.axi._

class AXIB_BRAM(
    ADDR_WIDTH: Int,
    DATA_WIDTH: Int
) extends AXIB(
      ADDR_WIDTH = ADDR_WIDTH,
      DATA_WIDTH = DATA_WIDTH,
      ID_WIDTH = 0,
      USER_WIDTH = 0,
      LEN_WIDTH = 8
    ) {}

class AXIBramControllerBB(
    AXI_ADDR_WIDTH: Int,
    AXI_DATA_WIDTH: Int,
    BRAM_ADDR_WIDTH: Int,
    IP_INSTANCE_NAME: String
) extends BlackBox(
      Map(
        "C_S_AXI_ADDR_WIDTH" -> IntParam(AXI_ADDR_WIDTH),
        "C_S_AXI_DATA_WIDTH" -> IntParam(AXI_DATA_WIDTH)
      )
    ) {

  override def desiredName = IP_INSTANCE_NAME

  val io = IO(new Bundle {
    val s_axi_aclk = Input(Clock())
    val s_axi_aresetn = Input(Bool())

    val s_axi_awaddr = Input(UInt(AXI_ADDR_WIDTH.W))
    val s_axi_awlen = Input(UInt(8.W))
    val s_axi_awsize = Input(UInt(3.W))
    val s_axi_awburst = Input(UInt(2.W))
    val s_axi_awlock = Input(Bool())
    val s_axi_awcache = Input(UInt(4.W))
    val s_axi_awprot = Input(UInt(3.W))
    val s_axi_awvalid = Input(Bool())
    val s_axi_awready = Output(Bool())

    val s_axi_wdata = Input(UInt(AXI_DATA_WIDTH.W))
    val s_axi_wstrb = Input(UInt((AXI_DATA_WIDTH / 8).W))
    val s_axi_wlast = Input(Bool())
    val s_axi_wvalid = Input(Bool())
    val s_axi_wready = Output(Bool())

    val s_axi_bresp = Output(UInt(2.W))
    val s_axi_bvalid = Output(Bool())
    val s_axi_bready = Input(Bool())

    val s_axi_araddr = Input(UInt(AXI_ADDR_WIDTH.W))
    val s_axi_arlen = Input(UInt(8.W))
    val s_axi_arsize = Input(UInt(3.W))
    val s_axi_arburst = Input(UInt(2.W))
    val s_axi_arlock = Input(Bool())
    val s_axi_arcache = Input(UInt(4.W))
    val s_axi_arprot = Input(UInt(3.W))
    val s_axi_arvalid = Input(Bool())
    val s_axi_arready = Output(Bool())

    val s_axi_rdata = Output(UInt(AXI_DATA_WIDTH.W))
    val s_axi_rresp = Output(UInt(2.W))
    val s_axi_rlast = Output(Bool())
    val s_axi_rvalid = Output(Bool())
    val s_axi_rready = Input(Bool())

    val bram_clk_a = Output(Clock())
    val bram_rst_a = Output(Bool())
    val bram_en_a = Output(Bool())
    val bram_we_a = Output(UInt((AXI_DATA_WIDTH / 8).W))
    val bram_addr_a = Output(UInt(BRAM_ADDR_WIDTH.W))
    val bram_wrdata_a = Output(UInt(AXI_DATA_WIDTH.W))
    val bram_rddata_a = Input(UInt(AXI_DATA_WIDTH.W))

    val bram_clk_b = Output(Clock())
    val bram_rst_b = Output(Bool())
    val bram_en_b = Output(Bool())
    val bram_we_b = Output(UInt((AXI_DATA_WIDTH / 8).W))
    val bram_addr_b = Output(UInt(BRAM_ADDR_WIDTH.W))
    val bram_wrdata_b = Output(UInt(AXI_DATA_WIDTH.W))
    val bram_rddata_b = Input(UInt(AXI_DATA_WIDTH.W))
  })
}

class BlockRamBB(
    ADDR_WIDTH: Int,
    DATA_WIDTH: Int,
    IP_INSTANCE_NAME: String
) extends BlackBox {
  override def desiredName = IP_INSTANCE_NAME

  val io = IO(new Bundle {
    val clka = Input(Clock())
    val rsta = Input(Bool())
    val ena = Input(Bool())
    val wea = Input(UInt((DATA_WIDTH / 8).W))
    val addra = Input(UInt(ADDR_WIDTH.W))
    val dina = Input(UInt(DATA_WIDTH.W))
    val douta = Output(UInt(DATA_WIDTH.W))

    val clkb = Input(Clock())
    val rstb = Input(Bool())
    val enb = Input(Bool())
    val web = Input(UInt((DATA_WIDTH / 8).W))
    val addrb = Input(UInt(ADDR_WIDTH.W))
    val dinb = Input(UInt(DATA_WIDTH.W))
    val doutb = Output(UInt(DATA_WIDTH.W))
  })
}

class AXIBRAM(
    AXI_ADDR_WIDTH: Int = 13, // 2^13 = 8192 Bytes
    AXI_DATA_WIDTH: Int = 32,
    IP_NAME_CTRL: String = "axi_bram_ctrl_0",
    IP_NAME_MEM: String = "blk_mem_gen_0"
) extends Module {
  val io = IO(new Bundle {
    val axi = Flipped(
      new AXIB_BRAM(ADDR_WIDTH = AXI_ADDR_WIDTH, DATA_WIDTH = AXI_DATA_WIDTH)
    )
  })

  val byteOffset = log2Ceil(AXI_DATA_WIDTH / 8)
  val bramAddrWidth = AXI_ADDR_WIDTH - byteOffset

  def getTCL() = {
    val s1 =
      s"\ncreate_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -module_name ${IP_NAME_CTRL}\n"
    var s2 = s"set_property -dict [list "
    s2 += s"CONFIG.PROTOCOL {AXI4} "
    s2 += s"CONFIG.DATA_WIDTH {${AXI_DATA_WIDTH}} "
    s2 += s"CONFIG.SINGLE_PORT_BRAM {0} "
    s2 += s"CONFIG.MEM_DEPTH {8192} "
    s2 += s"CONFIG.ECC_TYPE {0} "
    s2 += s"] [get_ips ${IP_NAME_CTRL}]\n"

    val s3 =
      s"\ncreate_ip -name blk_mem_gen -vendor xilinx.com -library ip -module_name ${IP_NAME_MEM}\n"
    var s4 = s"set_property -dict [list "
    s4 += s"CONFIG.Memory_Type {True_Dual_Port_RAM} "
    s4 += s"CONFIG.PRIM_type_to_Implement {BRAM} "
    s4 += s"CONFIG.Enable_32bit_Address {true} "
    s4 += s"CONFIG.Use_Byte_Write_Enable {true} "
    s4 += s"CONFIG.Byte_Size {8} "
    s4 += s"CONFIG.Register_PortA_Output_of_Memory_Primitives {false} "
    s4 += s"CONFIG.Register_PortB_Output_of_Memory_Primitives {false} "
    s4 += s"CONFIG.Write_Depth_A {2048} "
    s4 += s"CONFIG.Use_RSTA_Pin {true} "
    s4 += s"CONFIG.Use_RSTB_Pin {true} "
    s4 += s"CONFIG.use_bram_block {BRAM_Controller} "
    s4 += s"] [get_ips ${IP_NAME_MEM}]\n"

    println(s1 + s2 + s3 + s4)
  }

  getTCL();

  val ctrl = Module(
    new AXIBramControllerBB(
      AXI_ADDR_WIDTH,
      AXI_DATA_WIDTH,
      AXI_ADDR_WIDTH,
      IP_NAME_CTRL
    )
  )
  val mem = Module(new BlockRamBB(32, AXI_DATA_WIDTH, IP_NAME_MEM))

  ctrl.io.s_axi_aclk := clock
  ctrl.io.s_axi_aresetn := !reset.asBool

  ctrl.io.s_axi_awaddr := io.axi.aw.bits.addr
  ctrl.io.s_axi_awlen := io.axi.aw.bits.len
  ctrl.io.s_axi_awsize := io.axi.aw.bits.size
  ctrl.io.s_axi_awburst := io.axi.aw.bits.burst
  ctrl.io.s_axi_awlock := io.axi.aw.bits.lock
  ctrl.io.s_axi_awcache := io.axi.aw.bits.cache
  ctrl.io.s_axi_awprot := io.axi.aw.bits.prot
  ctrl.io.s_axi_awvalid := io.axi.aw.valid
  io.axi.aw.ready := ctrl.io.s_axi_awready

  ctrl.io.s_axi_wdata := io.axi.w.bits.data
  ctrl.io.s_axi_wstrb := io.axi.w.bits.strb
  ctrl.io.s_axi_wlast := io.axi.w.bits.last
  ctrl.io.s_axi_wvalid := io.axi.w.valid
  io.axi.w.ready := ctrl.io.s_axi_wready

  io.axi.b.bits.resp := ctrl.io.s_axi_bresp
  io.axi.b.bits.id := 0.U
  io.axi.b.bits.user := 0.U
  io.axi.b.valid := ctrl.io.s_axi_bvalid
  ctrl.io.s_axi_bready := io.axi.b.ready

  ctrl.io.s_axi_araddr := io.axi.ar.bits.addr
  ctrl.io.s_axi_arlen := io.axi.ar.bits.len
  ctrl.io.s_axi_arsize := io.axi.ar.bits.size
  ctrl.io.s_axi_arburst := io.axi.ar.bits.burst
  ctrl.io.s_axi_arlock := io.axi.ar.bits.lock
  ctrl.io.s_axi_arcache := io.axi.ar.bits.cache
  ctrl.io.s_axi_arprot := io.axi.ar.bits.prot
  ctrl.io.s_axi_arvalid := io.axi.ar.valid
  io.axi.ar.ready := ctrl.io.s_axi_arready

  io.axi.r.bits.data := ctrl.io.s_axi_rdata
  io.axi.r.bits.resp := ctrl.io.s_axi_rresp
  io.axi.r.bits.id := 0.U
  io.axi.r.bits.last := ctrl.io.s_axi_rlast
  io.axi.r.bits.user := 0.U
  io.axi.r.valid := ctrl.io.s_axi_rvalid
  ctrl.io.s_axi_rready := io.axi.r.ready

  mem.io.clka := ctrl.io.bram_clk_a
  mem.io.rsta := ctrl.io.bram_rst_a
  mem.io.ena := ctrl.io.bram_en_a
  mem.io.wea := ctrl.io.bram_we_a
  mem.io.addra := ctrl.io.bram_addr_a
  mem.io.dina := ctrl.io.bram_wrdata_a
  ctrl.io.bram_rddata_a := mem.io.douta

  mem.io.clkb := ctrl.io.bram_clk_b
  mem.io.rstb := ctrl.io.bram_rst_b
  mem.io.enb := ctrl.io.bram_en_b
  mem.io.web := ctrl.io.bram_we_b
  mem.io.addrb := ctrl.io.bram_addr_b
  mem.io.dinb := ctrl.io.bram_wrdata_b
  ctrl.io.bram_rddata_b := mem.io.doutb
}
