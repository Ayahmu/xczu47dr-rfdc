package reset

import chisel3._
import chisel3.experimental.{annotate, ChiselAnnotation}
import chisel3.util._
import firrtl.AttributeAnnotation

object VerilogAttr {
  def apply(signal: Data, attr: String): Unit = {
    annotate(new ChiselAnnotation {
      override def toFirrtl: AttributeAnnotation = AttributeAnnotation(signal.toTarget, attr)
    })
  }
}

class ChiselProcSysReset(RELEASE_CYCLES: Int = 16) extends RawModule {
  val io = IO(new Bundle {
    val slowest_sync_clk = Input(Clock())
    val ext_reset_in = Input(Bool())
    val aux_reset_in = Input(Bool())
    val dcm_locked = Input(Bool())
    val peripheral_aresetn = Output(Bool())
  })

  require(RELEASE_CYCLES >= 2, "RELEASE_CYCLES must allow a visible synchronous reset stretch")

  VerilogAttr(
    io.slowest_sync_clk,
    "X_INTERFACE_INFO = \"xilinx.com:signal:clock:1.0 io_slowest_sync_clk CLK\""
  )
  VerilogAttr(
    io.slowest_sync_clk,
    "X_INTERFACE_PARAMETER = \"ASSOCIATED_RESET io_peripheral_aresetn\""
  )
  VerilogAttr(
    io.peripheral_aresetn,
    "X_INTERFACE_INFO = \"xilinx.com:signal:reset:1.0 io_peripheral_aresetn RST\""
  )
  VerilogAttr(
    io.peripheral_aresetn,
    "X_INTERFACE_PARAMETER = \"POLARITY ACTIVE_LOW\""
  )

  val rawReset = !io.ext_reset_in || io.aux_reset_in || !io.dcm_locked

  withClockAndReset(io.slowest_sync_clk, rawReset) {
    val extResetSync = RegInit(VecInit(Seq.fill(2)(false.B)))
    val auxResetSync = RegInit(VecInit(Seq.fill(2)(true.B)))
    val dcmLockedSync = RegInit(VecInit(Seq.fill(2)(false.B)))

    extResetSync(0) := io.ext_reset_in
    extResetSync(1) := extResetSync(0)
    auxResetSync(0) := io.aux_reset_in
    auxResetSync(1) := auxResetSync(0)
    dcmLockedSync(0) := io.dcm_locked
    dcmLockedSync(1) := dcmLockedSync(0)

    val resetAsserted = !extResetSync(1) || auxResetSync(1) || !dcmLockedSync(1)
    val counterWidth = log2Ceil(RELEASE_CYCLES + 1).W
    val releaseCount = RegInit(0.U(counterWidth))
    val released = RegInit(false.B)

    when(resetAsserted) {
      releaseCount := 0.U
      released := false.B
    }.elsewhen(!released) {
      releaseCount := releaseCount + 1.U
      when(releaseCount === (RELEASE_CYCLES - 1).U) {
        released := true.B
      }
    }

    io.peripheral_aresetn := released
  }
}
