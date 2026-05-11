package led

import chisel3._
import chisel3.util._

class LED extends RawModule {
  val io = IO(new Bundle {
    val CLK = Input(Clock())
    val CLK1 = Input(Clock())

    val LED0 = Output(UInt(1.W))
    val LED1 = Output(UInt(1.W))
  })

  withClock(io.CLK) {
    val counter0 = Reg(UInt(27.W))
    counter0 := counter0 + 1.U

    io.LED0 := counter0(26)
  }

  withClock(io.CLK1) {
    val counter1 = Reg(UInt(27.W))
    counter1 := counter1 + 1.U

    io.LED1 := counter1(26)
  }
}
