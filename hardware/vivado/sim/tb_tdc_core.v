`timescale 1ns/1ps

module tb_tdc_core;

  localparam integer TAPS = 256;
  localparam integer CALIB_ADDR_WIDTH = 10;
  localparam integer CLK_PERIOD_PS = 5000;

  reg         clk;
  reg         rst_n;
  reg         trigger_in;
  reg         calib_wr_en;
  reg  [9:0]  calib_wr_addr;
  reg  [15:0] calib_wr_data;
  reg  [TAPS-1:0] forced_samples;
  reg  [1:0] forced_slot;
  wire [15:0] phase_ps_x10;
  wire        phase_valid;
  wire        phase_overflow;
  wire        phase_metastable;
  wire [1:0]  phase_slot;
  wire [7:0]  tap_index_raw_dbg;
  wire        measurement_toggle;
  reg         previous_toggle;

  tdc_core #(
      .TAPS(TAPS),
      .CALIB_ADDR_WIDTH(CALIB_ADDR_WIDTH)
  ) dut (
      .clk_sample_200mhz  (clk),
      .rst_n              (rst_n),
      .trigger_in         (trigger_in),
      .calib_wr_en        (calib_wr_en),
      .calib_wr_addr      (calib_wr_addr),
      .calib_wr_data      (calib_wr_data),
      .phase_ps_x10       (phase_ps_x10),
      .phase_valid        (phase_valid),
      .phase_overflow     (phase_overflow),
      .phase_metastable   (phase_metastable),
      .phase_slot         (phase_slot),
      .tap_index_raw_dbg  (tap_index_raw_dbg),
      .measurement_toggle (measurement_toggle)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD_PS/2 * 1ps) clk = ~clk;
  end

  task drive_sample;
    input [TAPS-1:0] pattern;
    input [1:0] slot;
    begin
      @(negedge clk);
      forced_samples = pattern;
      forced_slot = slot;
    end
  endtask

  task wait_for_toggle;
    integer timeout;
    begin
      timeout = 0;
      while (measurement_toggle === previous_toggle && timeout < 16) begin
        @(posedge clk);
        #1ps;
        timeout = timeout + 1;
      end
      if (measurement_toggle === previous_toggle) begin
        $fatal(1, "TDC core did not publish a measurement event");
      end
      previous_toggle = measurement_toggle;
    end
  endtask

  initial begin
    rst_n = 1'b0;
    trigger_in = 1'b0;
    calib_wr_en = 1'b0;
    calib_wr_addr = 10'd0;
    calib_wr_data = 16'd0;
    forced_samples = {TAPS{1'b0}};
    forced_slot = 2'd0;

    force dut.delay_samples = forced_samples;
    force dut.delay_sample_slot = forced_slot;

    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);
    previous_toggle = measurement_toggle;

    @(negedge clk);
    calib_wr_en = 1'b1;
    calib_wr_addr = 10'd10;
    calib_wr_data = 16'd42;
    @(negedge clk);
    calib_wr_en = 1'b0;

    drive_sample({{(TAPS-11){1'b0}}, 11'h7ff}, 2'd3);
    wait_for_toggle();
    if (!phase_valid || phase_overflow || phase_metastable) begin
      $fatal(1, "Valid thermometer snapshot was classified incorrectly");
    end
    if (tap_index_raw_dbg !== 8'd10 || phase_ps_x10 !== 16'd42 || phase_slot !== 2'd3) begin
      $fatal(1, "Core did not keep tap, calibrated time, and slot aligned");
    end

    drive_sample({TAPS{1'b0}}, 2'd0);
    repeat (4) @(posedge clk);
    drive_sample({TAPS{1'b1}}, 2'd1);
    wait_for_toggle();
    if (phase_valid || !phase_overflow || phase_metastable || phase_slot !== 2'd1) begin
      $fatal(1, "Saturated delay line was not published as overflow");
    end

    drive_sample({TAPS{1'b0}}, 2'd0);
    repeat (4) @(posedge clk);
    drive_sample({{(TAPS-6){1'b0}}, 6'b11_1011}, 2'd2);
    wait_for_toggle();
    if (phase_valid || phase_overflow || !phase_metastable || phase_slot !== 2'd2) begin
      $fatal(1, "Thermometer bubble was not published as metastability");
    end

    repeat (4) @(posedge clk);
    if (!phase_metastable || phase_slot !== 2'd2) begin
      $fatal(1, "Latest TDC status must remain stable for software CDC/readback");
    end

    $display("PASS: TDC core measurement alignment and sticky status verified");
    $finish;
  end

  initial begin
    #2us;
    $fatal(1, "TIMEOUT");
  end

endmodule
