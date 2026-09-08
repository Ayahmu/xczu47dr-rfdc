`timescale 1ns / 1ps

// Clock generator: 50 MHz -> 200 MHz using MMCM.
//
// Used for oversampling the external trigger to resolve 250 MHz grid phase.
// Input: dac_axis_clk (50 MHz)
// Output: clk_200mhz (200 MHz, locked to input)
//
// MMCM configuration:
//   CLKIN = 50 MHz
//   VCO = 50 × 20 = 1000 MHz (within 600–1440 MHz range for -2 speed grade)
//   CLKOUT0 = 1000 / 5 = 200 MHz

module tdc_clk_gen_200mhz (
    input  wire clk_50mhz,       // dac_axis_clk
    input  wire rst_n,           // Active-low reset
    output wire clk_200mhz,      // 200 MHz output
    output wire locked           // MMCM locked indicator
);

  wire clk_200mhz_unbuf;
  wire clkfbout;
  wire clkfbout_buf;

  // MMCM primitive
  MMCME3_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKFBOUT_MULT_F(20.0),        // VCO = 50 × 20 = 1000 MHz
    .CLKIN1_PERIOD(20.0),          // 50 MHz input = 20 ns period
    .CLKOUT0_DIVIDE_F(5.0),        // 1000 / 5 = 200 MHz
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKOUT0_PHASE(0.0),
    .DIVCLK_DIVIDE(1),
    .REF_JITTER1(0.010),
    .STARTUP_WAIT("FALSE")
  ) mmcm_inst (
    .CLKIN1(clk_50mhz),
    .CLKFBIN(clkfbout_buf),
    .CLKOUT0(clk_200mhz_unbuf),
    .CLKFBOUT(clkfbout),
    .LOCKED(locked),
    .PWRDWN(1'b0),
    .RST(~rst_n),
    .CLKOUT0B(),
    .CLKOUT1(),
    .CLKOUT1B(),
    .CLKOUT2(),
    .CLKOUT2B(),
    .CLKOUT3(),
    .CLKOUT3B(),
    .CLKOUT4(),
    .CLKOUT5(),
    .CLKOUT6(),
    .CLKFBOUTB()
  );

  // Feedback buffer
  BUFG bufg_fb (
    .I(clkfbout),
    .O(clkfbout_buf)
  );

  // Output buffer
  BUFG bufg_out (
    .I(clk_200mhz_unbuf),
    .O(clk_200mhz)
  );

endmodule
