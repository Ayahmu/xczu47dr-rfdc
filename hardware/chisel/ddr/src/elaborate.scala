package ddr

import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Paths}

object elaborate extends App {
  private val outputDir = Paths.get("generated")
  Files.createDirectories(outputDir)

  private val configPath = outputDir.resolve("ddr_custom_xczu47dr_config.tcl")
  private val config = Ddr4CustomXczu47drConfig.renderTcl
  Files.write(configPath, config.getBytes(StandardCharsets.UTF_8))
  println(s"DDR4 Vivado configuration generated: ${configPath.toString}")

  private val wrapperPath = outputDir.resolve("Ddr4CustomXczu47dr.v")
  private val wrapper = Ddr4CustomXczu47drConfig.renderWrapperVerilog
  Files.write(wrapperPath, wrapper.getBytes(StandardCharsets.UTF_8))
  println(s"DDR4 Verilog blackbox wrapper generated: ${wrapperPath.toString}")
}

object Ddr4CustomXczu47drConfig {
  private val configEntries = Seq(
    "CONFIG.RESET_BOARD_INTERFACE {Custom}",
    "CONFIG.C0_CLOCK_BOARD_INTERFACE {Custom}",
    "CONFIG.C0_DDR4_BOARD_INTERFACE {Custom}",
    "CONFIG.C0.DDR4_CLKOUT0_DIVIDE {5}",
    "CONFIG.C0.DDR4_InputClockPeriod {4998}",
    "CONFIG.C0.DDR4_MemoryPart {MT40A1G16RC-062E}",
    "CONFIG.C0.DDR4_DataWidth {64}",
    "CONFIG.C0.DDR4_AxiSelection {true}",
    "CONFIG.C0.DDR4_AxiDataWidth {512}",
    "CONFIG.C0.DDR4_AxiAddressWidth {33}",
    "CONFIG.C0.DDR4_AxiIDWidth {1}",
    "CONFIG.C0.DDR4_TimePeriod {833}"
  )

  def renderTcl: String = {
    val body = configEntries.map(entry => s"    $entry \\").mkString("\n")
    s"""namespace eval ddr_custom_xczu47dr {
  proc config {} {
    return [list \\
$body
    ]
  }
}
"""
  }

  def renderWrapperVerilog: String =
    """module Ddr4CustomXczu47dr (
    input           sys_rst,
    input           c0_sys_clk_p,
    input           c0_sys_clk_n,
    output          c0_ddr4_act_n,
    output [16:0]   c0_ddr4_adr,
    output [1:0]    c0_ddr4_ba,
    output [0:0]    c0_ddr4_bg,
    output [0:0]    c0_ddr4_cke,
    output [0:0]    c0_ddr4_odt,
    output [0:0]    c0_ddr4_cs_n,
    output [0:0]    c0_ddr4_ck_t,
    output [0:0]    c0_ddr4_ck_c,
    output          c0_ddr4_reset_n,
    inout  [7:0]    c0_ddr4_dm_n,
    inout  [63:0]   c0_ddr4_dq,
    inout  [7:0]    c0_ddr4_dqs_c,
    inout  [7:0]    c0_ddr4_dqs_t,
    output          c0_init_calib_complete,
    output          c0_ddr4_ui_clk,
    output          c0_ddr4_ui_clk_sync_rst,
    input           c0_ddr4_aresetn,

    input  [34:0]   s_axi_awaddr,
    input  [7:0]    s_axi_awlen,
    input  [2:0]    s_axi_awsize,
    input  [1:0]    s_axi_awburst,
    input  [0:0]    s_axi_awlock,
    input  [3:0]    s_axi_awcache,
    input  [2:0]    s_axi_awprot,
    input  [3:0]    s_axi_awqos,
    input           s_axi_awvalid,
    output          s_axi_awready,
    input  [511:0]  s_axi_wdata,
    input  [63:0]   s_axi_wstrb,
    input           s_axi_wlast,
    input           s_axi_wvalid,
    output          s_axi_wready,
    input           s_axi_bready,
    output [1:0]    s_axi_bresp,
    output          s_axi_bvalid,
    input  [34:0]   s_axi_araddr,
    input  [7:0]    s_axi_arlen,
    input  [2:0]    s_axi_arsize,
    input  [1:0]    s_axi_arburst,
    input  [0:0]    s_axi_arlock,
    input  [3:0]    s_axi_arcache,
    input  [2:0]    s_axi_arprot,
    input  [3:0]    s_axi_arqos,
    input           s_axi_arvalid,
    output          s_axi_arready,
    input           s_axi_rready,
    output [511:0]  s_axi_rdata,
    output [1:0]    s_axi_rresp,
    output          s_axi_rlast,
    output          s_axi_rvalid
);

  wire        dbg_clk;
  wire [511:0] dbg_bus;
  wire [0:0]  s_axi_bid;
  wire [0:0]  s_axi_rid;
  wire [34:0] s_axi_awaddr_local = s_axi_awaddr - 35'h5_0000_0000;
  wire [34:0] s_axi_araddr_local = s_axi_araddr - 35'h5_0000_0000;

  ddr_custom_xczu47dr_ip ddr4_i (
      .sys_rst(sys_rst),
      .c0_sys_clk_p(c0_sys_clk_p),
      .c0_sys_clk_n(c0_sys_clk_n),
      .c0_ddr4_act_n(c0_ddr4_act_n),
      .c0_ddr4_adr(c0_ddr4_adr),
      .c0_ddr4_ba(c0_ddr4_ba),
      .c0_ddr4_bg(c0_ddr4_bg),
      .c0_ddr4_cke(c0_ddr4_cke),
      .c0_ddr4_odt(c0_ddr4_odt),
      .c0_ddr4_cs_n(c0_ddr4_cs_n),
      .c0_ddr4_ck_t(c0_ddr4_ck_t),
      .c0_ddr4_ck_c(c0_ddr4_ck_c),
      .c0_ddr4_reset_n(c0_ddr4_reset_n),
      .c0_ddr4_dm_dbi_n(c0_ddr4_dm_n),
      .c0_ddr4_dq(c0_ddr4_dq),
      .c0_ddr4_dqs_c(c0_ddr4_dqs_c),
      .c0_ddr4_dqs_t(c0_ddr4_dqs_t),
      .c0_init_calib_complete(c0_init_calib_complete),
      .c0_ddr4_ui_clk(c0_ddr4_ui_clk),
      .c0_ddr4_ui_clk_sync_rst(c0_ddr4_ui_clk_sync_rst),
      .dbg_clk(dbg_clk),
      .c0_ddr4_aresetn(c0_ddr4_aresetn),
      .c0_ddr4_s_axi_awid(1'b0),
      .c0_ddr4_s_axi_awaddr(s_axi_awaddr_local[32:0]),
      .c0_ddr4_s_axi_awlen(s_axi_awlen),
      .c0_ddr4_s_axi_awsize(s_axi_awsize),
      .c0_ddr4_s_axi_awburst(s_axi_awburst),
      .c0_ddr4_s_axi_awlock(s_axi_awlock),
      .c0_ddr4_s_axi_awcache(s_axi_awcache),
      .c0_ddr4_s_axi_awprot(s_axi_awprot),
      .c0_ddr4_s_axi_awqos(s_axi_awqos),
      .c0_ddr4_s_axi_awvalid(s_axi_awvalid),
      .c0_ddr4_s_axi_awready(s_axi_awready),
      .c0_ddr4_s_axi_wdata(s_axi_wdata),
      .c0_ddr4_s_axi_wstrb(s_axi_wstrb),
      .c0_ddr4_s_axi_wlast(s_axi_wlast),
      .c0_ddr4_s_axi_wvalid(s_axi_wvalid),
      .c0_ddr4_s_axi_wready(s_axi_wready),
      .c0_ddr4_s_axi_bready(s_axi_bready),
      .c0_ddr4_s_axi_bid(s_axi_bid),
      .c0_ddr4_s_axi_bresp(s_axi_bresp),
      .c0_ddr4_s_axi_bvalid(s_axi_bvalid),
      .c0_ddr4_s_axi_arid(1'b0),
      .c0_ddr4_s_axi_araddr(s_axi_araddr_local[32:0]),
      .c0_ddr4_s_axi_arlen(s_axi_arlen),
      .c0_ddr4_s_axi_arsize(s_axi_arsize),
      .c0_ddr4_s_axi_arburst(s_axi_arburst),
      .c0_ddr4_s_axi_arlock(s_axi_arlock),
      .c0_ddr4_s_axi_arcache(s_axi_arcache),
      .c0_ddr4_s_axi_arprot(s_axi_arprot),
      .c0_ddr4_s_axi_arqos(s_axi_arqos),
      .c0_ddr4_s_axi_arvalid(s_axi_arvalid),
      .c0_ddr4_s_axi_arready(s_axi_arready),
      .c0_ddr4_s_axi_rready(s_axi_rready),
      .c0_ddr4_s_axi_rid(s_axi_rid),
      .c0_ddr4_s_axi_rdata(s_axi_rdata),
      .c0_ddr4_s_axi_rresp(s_axi_rresp),
      .c0_ddr4_s_axi_rlast(s_axi_rlast),
      .c0_ddr4_s_axi_rvalid(s_axi_rvalid),
      .dbg_bus(dbg_bus)
  );

endmodule
"""
}
