`timescale 1ns/1ps

module tb_dac_play_ctrl;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg trigger = 1'b0;
  reg rfctrl2_trigger = 1'b0;
  reg prepare = 1'b0;
  reg abort = 1'b0;
  reg armed = 1'b0;
  reg [15:0] cfg_seq_id = 16'd1;
  reg auto_start = 1'b1;
  reg [31:0] ch1_len_beats = 32'd8;
  reg ch1_arm = 1'b1;
  reg ch1_fifo_tvalid = 1'b1;
  reg ch1_fifo_prog_empty = 1'b1;
  reg dac_ch1_ready_in = 1'b1;

  wire ch1_allow;
  wire dbg_started;
  wire prepared;
  wire dbg_trig_start;
  wire dbg_done_pulse;
  wire [7:0] dbg_underflow_seen;
  wire [31:0] dbg_ch1_fire_count;

  always #5 clk = ~clk;

  dac_play_ctrl #(
    .BEAT_BYTES(32)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .trigger(trigger),
    .rfctrl2_trigger(rfctrl2_trigger),
    .prepare(prepare),
    .abort(abort),
    .armed(armed),
    .cfg_seq_id(cfg_seq_id),
    .auto_start(auto_start),
    .ch1_delay_cycles(32'd0),
    .ch2_delay_cycles(32'd0),
    .ch3_delay_cycles(32'd0),
    .ch4_delay_cycles(32'd0),
    .ch5_delay_cycles(32'd0),
    .ch6_delay_cycles(32'd0),
    .ch7_delay_cycles(32'd0),
    .ch8_delay_cycles(32'd0),
    .ch1_len_beats(ch1_len_beats),
    .ch2_len_beats(32'd0),
    .ch3_len_beats(32'd0),
    .ch4_len_beats(32'd0),
    .ch5_len_beats(32'd0),
    .ch6_len_beats(32'd0),
    .ch7_len_beats(32'd0),
    .ch8_len_beats(32'd0),
    .ch1_arm(ch1_arm),
    .ch2_arm(1'b0),
    .ch3_arm(1'b0),
    .ch4_arm(1'b0),
    .ch5_arm(1'b0),
    .ch6_arm(1'b0),
    .ch7_arm(1'b0),
    .ch8_arm(1'b0),
    .ch1_fifo_tvalid(ch1_fifo_tvalid),
    .ch2_fifo_tvalid(1'b0),
    .ch3_fifo_tvalid(1'b0),
    .ch4_fifo_tvalid(1'b0),
    .ch5_fifo_tvalid(1'b0),
    .ch6_fifo_tvalid(1'b0),
    .ch7_fifo_tvalid(1'b0),
    .ch8_fifo_tvalid(1'b0),
    .ch1_fifo_prog_empty(ch1_fifo_prog_empty),
    .ch2_fifo_prog_empty(1'b1),
    .ch3_fifo_prog_empty(1'b1),
    .ch4_fifo_prog_empty(1'b1),
    .ch5_fifo_prog_empty(1'b1),
    .ch6_fifo_prog_empty(1'b1),
    .ch7_fifo_prog_empty(1'b1),
    .ch8_fifo_prog_empty(1'b1),
    .dac_ch1_ready_in(dac_ch1_ready_in),
    .dac_ch2_ready_in(1'b0),
    .dac_ch3_ready_in(1'b0),
    .dac_ch4_ready_in(1'b0),
    .dac_ch5_ready_in(1'b0),
    .dac_ch6_ready_in(1'b0),
    .dac_ch7_ready_in(1'b0),
    .dac_ch8_ready_in(1'b0),
    .ch1_allow(ch1_allow),
    .ch2_allow(),
    .ch3_allow(),
    .ch4_allow(),
    .ch5_allow(),
    .ch6_allow(),
    .ch7_allow(),
    .ch8_allow(),
    .ch1_active(),
    .ch2_active(),
    .ch3_active(),
    .ch4_active(),
    .ch5_active(),
    .ch6_active(),
    .ch7_active(),
    .ch8_active(),
    .prepared(prepared),
    .dbg_trig_pulse(),
    .dbg_new_cfg(),
    .dbg_trig_start(dbg_trig_start),
    .dbg_started(dbg_started),
    .dbg_last_seq_id(),
    .dbg_done_pulse(dbg_done_pulse),
    .dbg_underflow_seen(dbg_underflow_seen),
    .dbg_ch1_fire_count(dbg_ch1_fire_count),
    .dbg_ch2_fire_count(),
    .dbg_ch3_fire_count(),
    .dbg_ch4_fire_count(),
    .dbg_ch5_fire_count(),
    .dbg_ch6_fire_count(),
    .dbg_ch7_fire_count(),
    .dbg_ch8_fire_count()
  );

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);
    if (!dbg_started || !ch1_allow) begin
      $error("dac_play_ctrl must start when FIFO tvalid=1 even if short-frame prog_empty remains asserted");
      $finish;
    end

    wait (dbg_started == 1'b0);
    if (!dbg_done_pulse || dbg_ch1_fire_count != 32'd8 || dbg_underflow_seen != 8'd0) begin
      $error("dac_play_ctrl completion counters must report exactly eight clean CH1 handshakes");
      $finish;
    end

    auto_start = 1'b0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    trigger = 1'b1;
    @(negedge clk);
    trigger = 1'b0;
    repeat (4) @(posedge clk);
    if (dbg_started || dbg_trig_start) begin
      $error("dac_play_ctrl must not restart an already consumed cfg_seq_id");
      $finish;
    end

    @(negedge clk);
    cfg_seq_id = 16'd2;
    repeat (4) @(posedge clk);
    if (!dbg_started || !ch1_allow) begin
      $error("dac_play_ctrl must preserve an early trigger until the next cfg_seq_id arrives");
      $finish;
    end

    @(negedge clk);
    ch1_fifo_tvalid = 1'b0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    ch1_fifo_tvalid = 1'b1;
    repeat (2) @(posedge clk);
    if (!dbg_underflow_seen[0]) begin
      $error("dac_play_ctrl must retain a sticky underflow indication when an allowed channel has no data");
      $finish;
    end

    // RFCTRL2 ARM prepares the next configuration before Trigger. The FIFO is
    // intentionally empty first so PREPARED cannot be reported prematurely.
    @(negedge clk); abort = 1'b1;
    @(negedge clk); abort = 1'b0;
    @(negedge clk);
    auto_start = 1'b0;
    cfg_seq_id = 16'd3;
    ch1_len_beats = 32'd4;
    ch1_fifo_tvalid = 1'b0;
    armed = 1'b1;
    prepare = 1'b1;
    @(negedge clk); prepare = 1'b0;
    repeat (3) @(posedge clk);
    if (prepared || dbg_started || ch1_allow) begin
      $error("RFCTRL2 PREPARED must wait for the first FIFO beat with all output gates closed");
      $finish;
    end

    @(negedge clk); ch1_fifo_tvalid = 1'b1;
    wait (prepared == 1'b1);
    #1;
    if (dbg_started || ch1_allow || dbg_ch1_fire_count != 32'd0) begin
      $error("RFCTRL2 PREPARED must latch launch state without consuming samples");
      $finish;
    end

    @(negedge clk); rfctrl2_trigger = 1'b1;
    @(negedge clk); rfctrl2_trigger = 1'b0;
    #1;
    if (!dbg_started || !ch1_allow || prepared) begin
      $error("RFCTRL2 Trigger must open the already prepared output gate immediately");
      $finish;
    end
    @(posedge clk);
    #1;
    if (dbg_ch1_fire_count != 32'd1) begin
      $error("the first RFCTRL2 sample must handshake on the first DAC cycle after the gate opens");
      $finish;
    end

    // A loop refill has a new configuration sequence but remains in the same
    // RFCTRL2 ARM session. It must become PREPARED and remain gated until a
    // second, independent Trigger arrives.
    wait (dbg_started == 1'b0);
    @(negedge clk); cfg_seq_id = 16'd4;
    wait (prepared == 1'b1);
    repeat (2) @(posedge clk);
    if (dbg_started || ch1_allow || dbg_ch1_fire_count != 32'd0) begin
      $error("a refilled loop frame must wait in PREPARED for another RFCTRL2 Trigger");
      $finish;
    end
    @(negedge clk); rfctrl2_trigger = 1'b1;
    @(negedge clk); rfctrl2_trigger = 1'b0;
    #1;
    if (!dbg_started || !ch1_allow || prepared) begin
      $error("the next loop frame must start only after its own RFCTRL2 Trigger");
      $finish;
    end

    $display("PASS: dac_play_ctrl preserves legacy startup and requires a fresh RFCTRL2 Trigger for every loop frame");
    $finish;
  end
endmodule
