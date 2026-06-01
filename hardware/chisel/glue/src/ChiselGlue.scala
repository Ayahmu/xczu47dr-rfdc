package glue

import chisel3._

class ChiselConstLow extends RawModule {
  val io = IO(new Bundle {
    val dout = Output(Bool())
  })

  io.dout := false.B
}

class ChiselConstHigh extends RawModule {
  val io = IO(new Bundle {
    val dout = Output(Bool())
  })

  io.dout := true.B
}

class ChiselInvert1 extends RawModule {
  val io = IO(new Bundle {
    val Op1 = Input(Bool())
    val Res = Output(Bool())
  })

  io.Res := !io.Op1
}
