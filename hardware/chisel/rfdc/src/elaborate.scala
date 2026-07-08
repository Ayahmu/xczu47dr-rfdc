package rfdc

import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Paths}

object elaborate extends App {
  private val outputDir = Paths.get("generated")
  Files.createDirectories(outputDir)

  private val configPath = outputDir.resolve("rfdc_custom_xczu47dr_config.tcl")
  private val config = RfdcCustomXczu47drConfig.renderTcl
  Files.write(configPath, config.getBytes(StandardCharsets.UTF_8))
  println(s"RFDC Vivado configuration generated: ${configPath.toString}")

  private val wrapperPath = outputDir.resolve("RfdcCustomXczu47dr.v")
  private val wrapper = RfdcCustomXczu47drConfig.renderWrapperVerilog
  Files.write(wrapperPath, wrapper.getBytes(StandardCharsets.UTF_8))
  println(s"RFDC Verilog blackbox wrapper generated: ${wrapperPath.toString}")
}

object RfdcCustomXczu47drConfig {
  // 8-channel DAC playback: 4 DAC tiles (228..231) x 2 DAC blocks each.
  // C2R (IQ -> Real) with fine NCO digital up-conversion.
  // Fs = 6.4 GSPS, 16x interpolation => 400 MSPS complex IQ input and
  // 50 MHz fabric/AXIS clock. The normal playback path stores 8 channels in a
  // 512-bit interleaved DDR stream and repacks every four DDR beats into one
  // 256-bit RFDC beat per enabled slice.
  // DAC2 (tile 230) owns the PLL from a 128 MHz refclk and distributes the
  // sampling clock to all four tiles (Clock_Source=6 on every tile).
  private val axisFreqHz = 50000000
  private val refclkFreqHz = 128000000
  private val outclkFreqHz = 50000000

  // Interpolation factor applied on every used DAC slice.
  private val interpolationMode = "16"

  // Used DAC slices per tile: block 0 and block 2 (the two physical DACs).
  // Vivado RFDC GUI/IP parameter encodings, not Vitis driver encodings.
  // Band=3 is Vivado's "Multi x2(all)" mode. In this configuration the IP
  // still exposes all four slice ports per tile (sX0..sX3), but only slices
  // 0 and 2 are enabled. Each enabled 256-bit AXIS port already carries
  // interleaved I/Q samples for C2R (IQ -> Real), so the wrapper must forward
  // the upstream 256-bit IQ stream directly instead of splitting it across the
  // disabled companion slice ports.
  private val dacBandMultiX2All = "3"
  private val dacMixerModeC2R = "0"
  private val dacMixerTypeFine = "2"
  private val dacDataTypeReal = "0"
  private val usedSlices = Seq("0", "2")
  private val portSlices = Seq("0", "1", "2", "3")
  private val tiles = Seq("0", "1", "2", "3")
  private val usedAxisPorts = for (t <- tiles; s <- usedSlices) yield s"s$t${s}_axis"

  private def defaultNcoFreqGHz(tile: String, slice: String): String =
    (tile, slice) match {
      case ("2", "0") => "0.0"  // CH5 Z baseband/DC
      case ("2", "2") => "0.0"  // CH6 Z baseband/DC
      case ("3", "0") => "-0.6" // CH7 readout target 5.8 GHz at Fs=6.4G
      case ("3", "2") => "-0.2" // CH8 readout target 6.2 GHz at Fs=6.4G
      case _          => "-1.9" // CH1-CH4 XY target 4.5 GHz at Fs=6.4G
    }

  private def defaultNyquist(tile: String, slice: String): String =
    (tile, slice) match {
      case ("2", _) => "0" // Z uses baseband/odd Nyquist
      case _        => "1" // XY/readout defaults use the 2nd/even Nyquist image
    }

  private val configEntries: Seq[String] = {
    val adcDisable =
      tiles.map(t => s"CONFIG.ADC${t}_Enable {0}") ++
        (for (t <- tiles; s <- Seq("0", "1", "2", "3"))
          yield s"CONFIG.ADC_Slice${t}${s}_Enable {false}")

    // Per-tile clocking. DAC2 is the distribution source.
    val tileClock = tiles.flatMap { t =>
      val base = Seq(
        s"CONFIG.DAC${t}_Enable {1}",
        s"CONFIG.DAC${t}_Sampling_Rate {6.4}",
        s"CONFIG.DAC${t}_Clock_Source {6}",
        s"CONFIG.DAC${t}_Band {$dacBandMultiX2All}"
      )
      if (t == "2")
        base ++ Seq(
          "CONFIG.DAC2_PLL_Enable {true}",
          "CONFIG.DAC2_Refclk_Freq {128.000}",
          "CONFIG.DAC2_Clock_Dist {2}",
          "CONFIG.DAC2_Link_Coupling {1}"
        )
      else
        base ++ Seq(
          s"CONFIG.DAC${t}_PLL_Enable {false}",
          s"CONFIG.DAC${t}_Clock_Dist {0}"
        )
    }

    // Per used-slice datapath: enable, 16x interpolation, I/Q input stream,
    // C2R fine-NCO mixer to real analog output, and role-specific default NCO.
    val sliceCfg = for (t <- tiles; s <- usedSlices) yield Seq(
      s"CONFIG.DAC_Slice${t}${s}_Enable {true}",
      s"CONFIG.DAC_Interpolation_Mode${t}${s} {$interpolationMode}",
      s"CONFIG.DAC_Mixer_Mode${t}${s} {$dacMixerModeC2R}",
      s"CONFIG.DAC_Mixer_Type${t}${s} {$dacMixerTypeFine}",
      s"CONFIG.DAC_Data_Type${t}${s} {$dacDataTypeReal}",
      s"CONFIG.DAC_NCO_Freq${t}${s} {${defaultNcoFreqGHz(t, s)}}",
      s"CONFIG.DAC_Nyquist${t}${s} {${defaultNyquist(t, s)}}"
    )

    val companionSliceCfg = for (t <- tiles; s <- Seq("1", "3")) yield Seq(
      s"CONFIG.DAC_Slice${t}${s}_Enable {false}",
      s"CONFIG.DAC_Interpolation_Mode${t}${s} {$interpolationMode}",
      s"CONFIG.DAC_Mixer_Mode${t}${s} {$dacMixerModeC2R}",
      s"CONFIG.DAC_Mixer_Type${t}${s} {$dacMixerTypeFine}",
      s"CONFIG.DAC_Data_Type${t}${s} {$dacDataTypeReal}"
    )

    adcDisable ++ tileClock ++ sliceCfg.flatten ++ companionSliceCfg.flatten ++ Seq(
      "CONFIG.DAC_VOP_Mode {1}",
      "CONFIG.RF_Analyzer {1}"
    )
  }

  def renderTcl: String = {
    val body = configEntries.zipWithIndex.map { case (entry, index) =>
      val suffix = if (index == configEntries.size - 1) "" else " \\"
      s"      $entry$suffix"
    }.mkString("\n")

    s"""# Generated by hardware/chisel/rfdc/src/elaborate.scala. Do not edit by hand.
# Custom XCZU47DR RFDC configuration for 128 MHz refclk, 6.4 GS/s DACs,
# 8-channel C2R (IQ->Real), 16x interpolation, 50 MHz PL stream.

namespace eval ::rfdc_custom_xczu47dr {
  proc axis_freq_hz {} { return $axisFreqHz }
  proc refclk_freq_hz {} { return $refclkFreqHz }
  proc outclk_freq_hz {} { return $outclkFreqHz }
  proc associated_busif {} { return {${usedAxisPorts.mkString(":")}} }

  proc config {} {
    return [list \\
$body]
  }
}
"""
  }

  def renderWrapperVerilog: String = {
    """// Generated by hardware/chisel/rfdc/src/elaborate.scala. Do not edit by hand.
// Top-level blackbox wrapper for the Vivado-managed RFDC IP.

module RfdcCustomXczu47dr (
    input          s_axi_aclk,
    input          s_axi_aresetn,
    input  [17:0]  s_axi_awaddr,
    input          s_axi_awvalid,
    output         s_axi_awready,
    input  [31:0]  s_axi_wdata,
    input  [3:0]   s_axi_wstrb,
    input          s_axi_wvalid,
    output         s_axi_wready,
    output [1:0]   s_axi_bresp,
    output         s_axi_bvalid,
    input          s_axi_bready,
    input  [17:0]  s_axi_araddr,
    input          s_axi_arvalid,
    output         s_axi_arready,
    output [31:0]  s_axi_rdata,
    output [1:0]   s_axi_rresp,
    output         s_axi_rvalid,
    input          s_axi_rready,
    input          sysref_in_p,
    input          sysref_in_n,
    input          dac2_clk_p,
    input          dac2_clk_n,
    output         clk_dac0,
    output         clk_dac1,
    output         clk_dac2,
    output         clk_dac3,
    input          s0_axis_aclk,
    input          s0_axis_aresetn,
    input          s1_axis_aclk,
    input          s1_axis_aresetn,
    input          s2_axis_aclk,
    input          s2_axis_aresetn,
    input          s3_axis_aclk,
    input          s3_axis_aresetn,
    output         vout00_p,
    output         vout00_n,
    output         vout02_p,
    output         vout02_n,
    output         vout10_p,
    output         vout10_n,
    output         vout12_p,
    output         vout12_n,
    output         vout20_p,
    output         vout20_n,
    output         vout22_p,
    output         vout22_n,
    output         vout30_p,
    output         vout30_n,
    output         vout32_p,
    output         vout32_n,
    input  [255:0] s00_axis_tdata,
    input          s00_axis_tvalid,
    output         s00_axis_tready,
    input  [255:0] s02_axis_tdata,
    input          s02_axis_tvalid,
    output         s02_axis_tready,
    input  [255:0] s10_axis_tdata,
    input          s10_axis_tvalid,
    output         s10_axis_tready,
    input  [255:0] s12_axis_tdata,
    input          s12_axis_tvalid,
    output         s12_axis_tready,
    input  [255:0] s20_axis_tdata,
    input          s20_axis_tvalid,
    output         s20_axis_tready,
    input  [255:0] s22_axis_tdata,
    input          s22_axis_tvalid,
    output         s22_axis_tready,
    input  [255:0] s30_axis_tdata,
    input          s30_axis_tvalid,
    output         s30_axis_tready,
    input  [255:0] s32_axis_tdata,
    input          s32_axis_tvalid,
    output         s32_axis_tready,
    output         irq
);

  wire [255:0] disabled_axis_tdata = 256'b0;
  wire         disabled_axis_tvalid = 1'b0;
  wire         ch1_axis_tready_unused;
  wire         ch2_axis_tready_unused;
  wire         ch3_axis_tready_unused;
  wire         ch4_axis_tready_unused;
  wire         ch5_axis_tready_unused;
  wire         ch6_axis_tready_unused;
  wire         ch7_axis_tready_unused;
  wire         ch8_axis_tready_unused;

  rfdc_custom_xczu47dr_ip rfdc_custom_xczu47dr_ip_i (
      .s_axi_aclk(s_axi_aclk),
      .s_axi_aresetn(s_axi_aresetn),
      .s_axi_awaddr(s_axi_awaddr),
      .s_axi_awvalid(s_axi_awvalid),
      .s_axi_awready(s_axi_awready),
      .s_axi_wdata(s_axi_wdata),
      .s_axi_wstrb(s_axi_wstrb),
      .s_axi_wvalid(s_axi_wvalid),
      .s_axi_wready(s_axi_wready),
      .s_axi_bresp(s_axi_bresp),
      .s_axi_bvalid(s_axi_bvalid),
      .s_axi_bready(s_axi_bready),
      .s_axi_araddr(s_axi_araddr),
      .s_axi_arvalid(s_axi_arvalid),
      .s_axi_arready(s_axi_arready),
      .s_axi_rdata(s_axi_rdata),
      .s_axi_rresp(s_axi_rresp),
      .s_axi_rvalid(s_axi_rvalid),
      .s_axi_rready(s_axi_rready),
      .sysref_in_p(sysref_in_p),
      .sysref_in_n(sysref_in_n),
      .dac2_clk_p(dac2_clk_p),
      .dac2_clk_n(dac2_clk_n),
      .clk_dac0(clk_dac0),
      .clk_dac1(clk_dac1),
      .clk_dac2(clk_dac2),
      .clk_dac3(clk_dac3),
      .s0_axis_aclk(s0_axis_aclk),
      .s0_axis_aresetn(s0_axis_aresetn),
      .s1_axis_aclk(s1_axis_aclk),
      .s1_axis_aresetn(s1_axis_aresetn),
      .s2_axis_aclk(s2_axis_aclk),
      .s2_axis_aresetn(s2_axis_aresetn),
      .s3_axis_aclk(s3_axis_aclk),
      .s3_axis_aresetn(s3_axis_aresetn),
      .vout00_p(vout00_p),
      .vout00_n(vout00_n),
      .vout02_p(vout02_p),
      .vout02_n(vout02_n),
      .vout10_p(vout10_p),
      .vout10_n(vout10_n),
      .vout12_p(vout12_p),
      .vout12_n(vout12_n),
      .vout20_p(vout20_p),
      .vout20_n(vout20_n),
      .vout22_p(vout22_p),
      .vout22_n(vout22_n),
      .vout30_p(vout30_p),
      .vout30_n(vout30_n),
      .vout32_p(vout32_p),
      .vout32_n(vout32_n),
      .s00_axis_tdata(s00_axis_tdata),
      .s00_axis_tvalid(s00_axis_tvalid),
      .s00_axis_tready(s00_axis_tready),
      .s01_axis_tdata(disabled_axis_tdata),
      .s01_axis_tvalid(disabled_axis_tvalid),
      .s01_axis_tready(ch1_axis_tready_unused),
      .s02_axis_tdata(s02_axis_tdata),
      .s02_axis_tvalid(s02_axis_tvalid),
      .s02_axis_tready(s02_axis_tready),
      .s03_axis_tdata(disabled_axis_tdata),
      .s03_axis_tvalid(disabled_axis_tvalid),
      .s03_axis_tready(ch2_axis_tready_unused),
      .s10_axis_tdata(s10_axis_tdata),
      .s10_axis_tvalid(s10_axis_tvalid),
      .s10_axis_tready(s10_axis_tready),
      .s11_axis_tdata(disabled_axis_tdata),
      .s11_axis_tvalid(disabled_axis_tvalid),
      .s11_axis_tready(ch3_axis_tready_unused),
      .s12_axis_tdata(s12_axis_tdata),
      .s12_axis_tvalid(s12_axis_tvalid),
      .s12_axis_tready(s12_axis_tready),
      .s13_axis_tdata(disabled_axis_tdata),
      .s13_axis_tvalid(disabled_axis_tvalid),
      .s13_axis_tready(ch4_axis_tready_unused),
      .s20_axis_tdata(s20_axis_tdata),
      .s20_axis_tvalid(s20_axis_tvalid),
      .s20_axis_tready(s20_axis_tready),
      .s21_axis_tdata(disabled_axis_tdata),
      .s21_axis_tvalid(disabled_axis_tvalid),
      .s21_axis_tready(ch5_axis_tready_unused),
      .s22_axis_tdata(s22_axis_tdata),
      .s22_axis_tvalid(s22_axis_tvalid),
      .s22_axis_tready(s22_axis_tready),
      .s23_axis_tdata(disabled_axis_tdata),
      .s23_axis_tvalid(disabled_axis_tvalid),
      .s23_axis_tready(ch6_axis_tready_unused),
      .s30_axis_tdata(s30_axis_tdata),
      .s30_axis_tvalid(s30_axis_tvalid),
      .s30_axis_tready(s30_axis_tready),
      .s31_axis_tdata(disabled_axis_tdata),
      .s31_axis_tvalid(disabled_axis_tvalid),
      .s31_axis_tready(ch7_axis_tready_unused),
      .s32_axis_tdata(s32_axis_tdata),
      .s32_axis_tvalid(s32_axis_tvalid),
      .s32_axis_tready(s32_axis_tready),
      .s33_axis_tdata(disabled_axis_tdata),
      .s33_axis_tvalid(disabled_axis_tvalid),
      .s33_axis_tready(ch8_axis_tready_unused),
      .irq(irq)
  );

endmodule
"""
  }
}
