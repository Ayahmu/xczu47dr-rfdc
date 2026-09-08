`timescale 1ns/1ps

// Leading-zero counter for thermometer-to-binary conversion in TDC encoder.
//
// Finds the index of the first '1' in a thermometer code (e.g. 00000111111 -> 5).
// Thermometer code: bits [i-1:0] = 0, bits [WIDTH-1:i] = 1, returns i.
// Uses priority encoder with pipelining for timing closure at 200+ MHz.

module tdc_leading_zero_counter #(
    parameter WIDTH = 256
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire [WIDTH-1:0]          thermometer_in,
    input  wire                      valid_in,
    output reg  [$clog2(WIDTH)-1:0]  zero_count,    // index of first '1'
    output reg                       valid_out,
    output reg                       overflow       // all zeros (no '1' found)
);

  // Pipeline stage 0: find first '1' using priority encoder
  // Scan from LSB to MSB, return index of first '1' bit
  reg [$clog2(WIDTH)-1:0] s0_index;
  reg s0_valid;
  reg s0_overflow;

  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s0_index <= {$clog2(WIDTH){1'b0}};
      s0_valid <= 1'b0;
      s0_overflow <= 1'b0;
    end else if (valid_in) begin
      s0_overflow <= (thermometer_in == {WIDTH{1'b0}});
      s0_valid <= (thermometer_in != {WIDTH{1'b0}});

      // Priority encoder: find highest bit that is '1' (thermometer tail)
      // Thermometer code has all low bits = 1 up to some index, then 0s above
      // Example: 0000_0111 has 3 ones, highest '1' at index 2 -> zero_count = 2
      // Scan from LSB up, keep updating index as long as we see '1'
      s0_index <= {$clog2(WIDTH){1'b0}};
      for (i = 0; i < WIDTH; i = i + 1) begin
        if (thermometer_in[i]) begin
          s0_index <= i[$clog2(WIDTH)-1:0];
        end
      end
    end else begin
      s0_valid <= 1'b0;
      s0_overflow <= 1'b0;
    end
  end

  // Pipeline stage 1: register output
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      zero_count <= {$clog2(WIDTH){1'b0}};
      valid_out  <= 1'b0;
      overflow   <= 1'b0;
    end else begin
      zero_count <= s0_index;
      valid_out  <= s0_valid;
      overflow   <= s0_overflow;
    end
  end

endmodule
