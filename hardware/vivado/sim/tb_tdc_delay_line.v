`timescale 1ns/1ps

module tb_tdc_delay_line;

  localparam integer TAPS = 256;

  reg                  signal_in;
  wire [TAPS-1:0]      taps_out;

  tdc_delay_line #(
      .TAPS(TAPS)
  ) dut (
      .signal_in(signal_in),
      .taps_out (taps_out)
  );

  initial begin
    signal_in = 1'b0;
    #1;
    if (taps_out !== {TAPS{1'b0}}) begin
      $fatal(1, "TDC delay line must be all zero when signal_in is low");
    end

    signal_in = 1'b1;
    #1;
    if (taps_out !== {TAPS{1'b1}}) begin
      $fatal(1, "TDC delay line must propagate signal_in through every tap");
    end

    signal_in = 1'b0;
    #1;
    if (taps_out !== {TAPS{1'b0}}) begin
      $fatal(1, "TDC delay line must return low after signal_in falls");
    end

    $display("PASS: TDC delay line propagates both logic levels");
    $finish;
  end

endmodule
