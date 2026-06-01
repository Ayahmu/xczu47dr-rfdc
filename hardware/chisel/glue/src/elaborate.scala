package glue

import chisel3.stage.{ChiselGeneratorAnnotation, ChiselStage}
import firrtl.options.TargetDirAnnotation

object elaborate extends App {
  val stage = new ChiselStage
  val stageArgs = Array("-X", "verilog", "--full-stacktrace")
  val targetDir = TargetDirAnnotation("generated")

  Seq(
    () => new ChiselConstLow,
    () => new ChiselConstHigh,
    () => new ChiselInvert1
  ).foreach { generator =>
    stage.execute(stageArgs, Seq(ChiselGeneratorAnnotation(generator), targetDir))
  }

  println("Glue Verilog generated successfully")
}
