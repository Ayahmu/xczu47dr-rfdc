import mill._, scalalib._, publish._
import mill.scalalib._
import mill.scalalib.scalafmt.ScalafmtModule
import scala.util._
import mill.bsp._

object Setting {
  def scalacOptions = Seq(
    "-Xsource:2.11",
    "-language:reflectiveCalls",
    "-deprecation",
    "-feature",
    "-Xcheckinit",
    "-P:chiselplugin:useBundlePlugin"
  )
  def scalacPluginIvyDeps = Agg(
    ivy"edu.berkeley.cs:::chisel3-plugin:3.4.4",
    ivy"org.scalamacros:::paradise:2.1.1"
  )
}

object common extends ScalaModule {
  override def scalaVersion = "2.12.13"
  override def scalacOptions = Setting.scalacOptions
  override def scalacPluginIvyDeps = Setting.scalacPluginIvyDeps
  override def ivyDeps = Agg(
    ivy"edu.berkeley.cs::chisel3:3.4.4"
  )

  def mainClass = Some("common.elaborate")
}

object qdma extends ScalaModule {
  override def scalaVersion = "2.12.13"
  override def scalacOptions = Setting.scalacOptions
  override def scalacPluginIvyDeps = Setting.scalacPluginIvyDeps
  override def ivyDeps = Agg(
    ivy"edu.berkeley.cs::chisel3:3.4.4"
  )
  def moduleDeps = Seq(common)
  def mainClass = Some("qdma.elaborate")
}

object gpio extends ScalaModule {
  override def scalaVersion = "2.12.13"
  override def scalacOptions = Setting.scalacOptions
  override def scalacPluginIvyDeps = Setting.scalacPluginIvyDeps
  override def ivyDeps = Agg(
    ivy"edu.berkeley.cs::chisel3:3.4.4"
  )
  def moduleDeps = Seq(common)
  def mainClass = Some("gpio.elaborate")
}

object led extends ScalaModule {
  override def scalaVersion = "2.12.13"
  override def scalacOptions = Setting.scalacOptions
  override def scalacPluginIvyDeps = Setting.scalacPluginIvyDeps
  override def ivyDeps = Agg(
    ivy"edu.berkeley.cs::chisel3:3.4.4"
  )
  def mainClass = Some("led.elaborate")
}

object memory extends ScalaModule {
  override def scalaVersion = "2.12.13"
  override def scalacOptions = Setting.scalacOptions
  override def scalacPluginIvyDeps = Setting.scalacPluginIvyDeps
  override def ivyDeps = Agg(
    ivy"edu.berkeley.cs::chisel3:3.4.4"
  )
  def moduleDeps = Seq(common)
  def mainClass = Some("memory.elaborate")
}

object axidma extends ScalaModule {
  override def scalaVersion = "2.12.13"
  override def scalacOptions = Setting.scalacOptions
  override def scalacPluginIvyDeps = Setting.scalacPluginIvyDeps
  override def ivyDeps = Agg(
    ivy"edu.berkeley.cs::chisel3:3.4.4"
  )
  def moduleDeps = Seq(common)
  def mainClass = Some("axi_dma.elaborate")
}

object project_foo extends ScalaModule {
  override def scalaVersion = "2.12.13"
  override def scalacOptions = Setting.scalacOptions
  override def scalacPluginIvyDeps = Setting.scalacPluginIvyDeps
  override def ivyDeps = Agg(
    ivy"edu.berkeley.cs::chisel3:3.4.4"
  )
  def moduleDeps = Seq(common, qdma, gpio, led, memory, axidma)
  def mainClass = Some("project_foo.elaborate")
}
