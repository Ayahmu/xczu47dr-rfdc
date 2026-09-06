// Generate a 200 MHz clock from dac_axis_clk (50 MHz) for trigger phase detection.
// Uses a fabric MMCM with 4× multiplication.  The output is phase-aligned to the
// input at power-on (no explicit phase shift), which is what the detector needs:
// it counts from the beat edge in the 200 MHz domain.

module clk_200mhz_generator (
    input  wire clk_in_50mhz,    // dac_axis_clk
    input  wire rst_n,
    output wire clk_out_200mhz,
    output wire locked
);

  wire clk_fb;
  wire clk_out_unbuf;

  // MMCM: 50 MHz × 20 / 5 = 200 MHz
  // VCO = 50 × 20 = 1000 MHz (within 800-1600 range)
  MMCME2_BASE #(
      .BANDWIDTH("OPTIMIZED"),
      .CLKFBOUT_MULT_F(20.0),       // VCO = 50 × 20 = 1000 MHz
      .CLKIN1_PERIOD(20.0),          // 50 MHz input = 20 ns
      .CLKOUT0_DIVIDE_F(5.0),        // 1000 / 5 = 200 MHz
      .CLKOUT0_PHASE(0.0),
      .CLKOUT0_DUTY_CYCLE(0.5),
      .DIVCLK_DIVIDE(1),
      .REF_JITTER1(0.010),
      .STARTUP_WAIT("FALSE")
  ) mmcm_inst (
      .CLKIN1   (clk_in_50mhz),
      .RST      (~rst_n),
      .CLKFBOUT (clk_fb),
      .CLKFBIN  (clk_fb),
      .CLKOUT0  (clk_out_unbuf),
      .LOCKED   (locked),
      .PWRDWN   (1'b0),
      // Unused outputs tied off
      .CLKOUT0B (), .CLKOUT1(), .CLKOUT1B(),
      .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
      .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
  );

  BUFG bufg_inst (
      .I (clk_out_unbuf),
      .O (clk_out_200mhz)
  );

endmodule
