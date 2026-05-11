module LED(
  input   io_CLK,
  input   io_CLK1,
  output  io_LED0,
  output  io_LED1
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
  reg [31:0] _RAND_1;
`endif // RANDOMIZE_REG_INIT
  reg [26:0] counter0; // @[LED.scala 16:23]
  reg [26:0] counter1; // @[LED.scala 23:23]
  assign io_LED0 = counter0[26]; // @[LED.scala 19:24]
  assign io_LED1 = counter1[26]; // @[LED.scala 26:24]
  always @(posedge io_CLK) begin
    counter0 <= counter0 + 27'h1; // @[LED.scala 17:26]
  end
  always @(posedge io_CLK1) begin
    counter1 <= counter1 + 27'h1; // @[LED.scala 24:26]
  end
// Register and memory initialization
`ifdef RANDOMIZE_GARBAGE_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_INVALID_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_REG_INIT
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_MEM_INIT
`define RANDOMIZE
`endif
`ifndef RANDOM
`define RANDOM $random
`endif
`ifdef RANDOMIZE_MEM_INIT
  integer initvar;
`endif
`ifndef SYNTHESIS
`ifdef FIRRTL_BEFORE_INITIAL
`FIRRTL_BEFORE_INITIAL
`endif
initial begin
  `ifdef RANDOMIZE
    `ifdef INIT_RANDOM
      `INIT_RANDOM
    `endif
    `ifndef VERILATOR
      `ifdef RANDOMIZE_DELAY
        #`RANDOMIZE_DELAY begin end
      `else
        #0.002 begin end
      `endif
    `endif
`ifdef RANDOMIZE_REG_INIT
  _RAND_0 = {1{`RANDOM}};
  counter0 = _RAND_0[26:0];
  _RAND_1 = {1{`RANDOM}};
  counter1 = _RAND_1[26:0];
`endif // RANDOMIZE_REG_INIT
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
