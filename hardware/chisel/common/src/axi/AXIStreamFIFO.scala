package common.axi

import chisel3._
import chisel3.util._
import chisel3.experimental.{IntParam, StringParam}

class AXISBundle(val dataWidth: Int) extends Bundle {
  val tdata = UInt(dataWidth.W)
  val tkeep = UInt((dataWidth / 8).W)
  val tlast = Bool()
}

class AXISDataFifoBB(
    DATA_WIDTH: Int,
    DEPTH: Int,
    IP_INSTANCE_NAME: String
) extends BlackBox {

  override def desiredName = IP_INSTANCE_NAME

  val io = IO(new Bundle {
    val s_axis_aclk = Input(Clock())
    val s_axis_aresetn = Input(Bool())
    val s_axis_tvalid = Input(Bool())
    val s_axis_tready = Output(Bool())
    val s_axis_tdata = Input(UInt(DATA_WIDTH.W))
    val s_axis_tkeep = Input(UInt((DATA_WIDTH / 8).W))
    val s_axis_tlast = Input(Bool())

    val m_axis_aclk = Input(Clock())
    val m_axis_tvalid = Output(Bool())
    val m_axis_tready = Input(Bool())
    val m_axis_tdata = Output(UInt(DATA_WIDTH.W))
    val m_axis_tkeep = Output(UInt((DATA_WIDTH / 8).W))
    val m_axis_tlast = Output(Bool())
  })
}

class AXISDataFIFO(
    DATA_BYTES: Int = 16,
    DEPTH: Int = 4096,
    IS_ASYNC: Boolean = true,
    FIFO_MODE: Int = 1,
    IP_NAME: String = "axis_data_fifo_0"
) extends Module {

  val dataWidth = DATA_BYTES * 8

  val io = IO(new Bundle {
    val s_aclk = Input(Clock())
    val m_aclk = Input(Clock())
    val resetn = Input(Bool())

    val s_axis = Flipped(Decoupled(new AXISBundle(dataWidth)))
    val m_axis = Decoupled(new AXISBundle(dataWidth))
  })

  def getTCL() = {
    val asyncVal = if (IS_ASYNC) 1 else 0

    val createCmd =
      s"\ncreate_ip -name axis_data_fifo -vendor xilinx.com -library ip -version 2.0 -module_name ${IP_NAME}\n"

    var propCmd = s"set_property -dict [list "
    propCmd += s"CONFIG.FIFO_DEPTH {${DEPTH}} "
    propCmd += s"CONFIG.FIFO_MODE {${FIFO_MODE}} "
    propCmd += s"CONFIG.IS_ACLK_ASYNC {${asyncVal}} "
    propCmd += s"CONFIG.TDATA_NUM_BYTES {${DATA_BYTES}} "
    propCmd += s"CONFIG.HAS_TKEEP {1} "
    propCmd += s"CONFIG.HAS_TLAST {1} "
    propCmd += s"] [get_ips ${IP_NAME}]\n"

    println(createCmd + propCmd)
  }

  getTCL()

  val fifo_ip = Module(new AXISDataFifoBB(dataWidth, DEPTH, IP_NAME))

  fifo_ip.io.s_axis_aclk := io.s_aclk
  fifo_ip.io.s_axis_aresetn := io.resetn

  if (IS_ASYNC) {
    fifo_ip.io.m_axis_aclk := io.m_aclk
  } else {
    fifo_ip.io.m_axis_aclk := io.s_aclk
  }

  fifo_ip.io.s_axis_tvalid := io.s_axis.valid
  fifo_ip.io.s_axis_tdata := io.s_axis.bits.tdata
  fifo_ip.io.s_axis_tkeep := io.s_axis.bits.tkeep
  fifo_ip.io.s_axis_tlast := io.s_axis.bits.tlast
  io.s_axis.ready := fifo_ip.io.s_axis_tready

  io.m_axis.valid := fifo_ip.io.m_axis_tvalid
  io.m_axis.bits.tdata := fifo_ip.io.m_axis_tdata
  io.m_axis.bits.tkeep := fifo_ip.io.m_axis_tkeep
  io.m_axis.bits.tlast := fifo_ip.io.m_axis_tlast
  fifo_ip.io.m_axis_tready := io.m_axis.ready
}
