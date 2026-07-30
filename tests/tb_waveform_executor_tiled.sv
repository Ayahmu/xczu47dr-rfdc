`timescale 1ns / 1ps

module tb_waveform_executor_tiled;
  localparam [63:0] CH1_TILE0_ADDR = 64'h0000000000000000;
  localparam [63:0] CH1_TILE1_ADDR = 64'h0000000000008000;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg [127:0] instr_tdata = 128'd0;
  reg         instr_tvalid = 1'b0;
  wire        instr_tready;

  wire [103:0] dm_cmd_tdata;
  wire         dm_cmd_tvalid;
  reg          dm_cmd_tready = 1'b1;
  wire [31:0]  bad_instr_count;

  integer cmd_count = 0;
  reg [63:0] cmd_addr [0:1];

  Waveform_System_Top dut (
    .aclk(clk),
    .aresetn(rst_n),
    .trigger(1'b0),
    .s_axis_instr_tdata(instr_tdata),
    .s_axis_instr_tvalid(instr_tvalid),
    .s_axis_instr_tready(instr_tready),
    .m_axis_dm_cmd_tdata(dm_cmd_tdata),
    .m_axis_dm_cmd_tvalid(dm_cmd_tvalid),
    .m_axis_dm_cmd_tready(dm_cmd_tready),
    .s_axis_dm_data_tdata(256'd0),
    .s_axis_dm_data_tvalid(1'b0),
    .s_axis_dm_data_tready(),
    .ch1_fifo_ready(1'b1),
    .ch2_fifo_ready(1'b1),
    .ch3_fifo_ready(1'b1),
    .ch4_fifo_ready(1'b1),
    .ch5_fifo_ready(1'b1),
    .ch6_fifo_ready(1'b1),
    .ch7_fifo_ready(1'b1),
    .ch8_fifo_ready(1'b1),
    .ch1_fifo_level_beats(16'd0),
    .ch2_fifo_level_beats(16'd0),
    .ch3_fifo_level_beats(16'd0),
    .ch4_fifo_level_beats(16'd0),
    .ch5_fifo_level_beats(16'd0),
    .ch6_fifo_level_beats(16'd0),
    .ch7_fifo_level_beats(16'd0),
    .ch8_fifo_level_beats(16'd0),
    .m_axis_ch1_tdata(),
    .m_axis_ch1_tvalid(),
    .m_axis_ch2_tdata(),
    .m_axis_ch2_tvalid(),
    .m_axis_ch3_tdata(),
    .m_axis_ch3_tvalid(),
    .m_axis_ch4_tdata(),
    .m_axis_ch4_tvalid(),
    .m_axis_ch5_tdata(),
    .m_axis_ch5_tvalid(),
    .m_axis_ch6_tdata(),
    .m_axis_ch6_tvalid(),
    .m_axis_ch7_tdata(),
    .m_axis_ch7_tvalid(),
    .m_axis_ch8_tdata(),
    .m_axis_ch8_tvalid(),
    .ch1_delay_cycles(),
    .ch2_delay_cycles(),
    .ch3_delay_cycles(),
    .ch4_delay_cycles(),
    .ch5_delay_cycles(),
    .ch6_delay_cycles(),
    .ch7_delay_cycles(),
    .ch8_delay_cycles(),
    .ch1_len_beats(),
    .ch2_len_beats(),
    .ch3_len_beats(),
    .ch4_len_beats(),
    .ch5_len_beats(),
    .ch6_len_beats(),
    .ch7_len_beats(),
    .ch8_len_beats(),
    .ch1_arm(),
    .ch2_arm(),
    .ch3_arm(),
    .ch4_arm(),
    .ch5_arm(),
    .ch6_arm(),
    .ch7_arm(),
    .ch8_arm(),
    .cfg_auto_start(),
    .cfg_loop(),
    .cfg_commit(),
    .dbg_st(),
    .dbg_dm_st(),
    .dbg_dm_sel_ch1(),
    .dbg_dm_chunk_beats(),
    .dbg_dm_beats_sent(),
    .dbg_ch1_bytes_left(),
    .dbg_ch2_bytes_left(),
    .dbg_ch1_base_addr(),
    .dbg_ch2_base_addr(),
    .dbg_ch1_need_hard(),
    .dbg_ch2_need_hard(),
    .dbg_ch1_need_soft(),
    .dbg_ch2_need_soft(),
    .dbg_instr_in_tdata(),
    .dbg_instr_in_tvalid(),
    .dbg_instr_in_tready(),
    .dbg_main_tdata(),
    .dbg_main_tvalid(),
    .dbg_main_tready(),
    .dbg_pending_valid(),
    .dbg_active_valid(),
    .dbg_run_delay_cnt(),
    .dbg_bad_instr_count(bad_instr_count)
  );

  always @(posedge clk) begin
    if(!rst_n) begin
      cmd_count <= 0;
      cmd_addr[0] <= 64'd0;
      cmd_addr[1] <= 64'd0;
    end else if(dm_cmd_tvalid && dm_cmd_tready) begin
      if(cmd_count < 2) cmd_addr[cmd_count] <= dm_cmd_tdata[95:32];
      cmd_count <= cmd_count + 1;
      if(dm_cmd_tdata[22:0] != 23'd4096) begin
        $display("FAIL: tiled command BTT should stay at 4096 bytes");
        $finish;
      end
    end
  end

  task send_instr(input [127:0] word);
    begin
      @(negedge clk);
      instr_tdata = word;
      instr_tvalid = 1'b1;
      while(!instr_tready) @(negedge clk);
      @(negedge clk);
      instr_tvalid = 1'b0;
      instr_tdata = 128'd0;
    end
  endtask

  task check_condition(input condition, input string message);
    begin
      if(!condition) begin
        $display("FAIL: %s", message);
        $finish;
      end
    end
  endtask

  initial begin
    repeat(4) @(negedge clk);
    rst_n = 1'b1;
    repeat(4) @(negedge clk);

    send_instr({64'd0, 32'd4097, 32'h00000212});
    repeat(4) @(negedge clk);
    check_condition(cmd_count == 0, "unaligned tiled PLAY should not issue a DataMover command");
    check_condition(bad_instr_count == 1, "unaligned tiled PLAY should increment bad instruction count");

    send_instr({CH1_TILE0_ADDR, 32'd8192, 32'h00000212});
    send_instr(128'h000000000000000000000000000000f3);

    repeat(50) @(negedge clk);
    check_condition(cmd_count == 2, "tiled CH1 8192B playback should issue two commands");
    check_condition(cmd_addr[0] == CH1_TILE0_ADDR, "first tiled command should read CH1 tile0");
    check_condition(cmd_addr[1] == CH1_TILE1_ADDR, "second tiled command should jump to CH1 tile1 in next superblock");

    $display("PASS: waveform executor tiled mode strides by one 8-channel superblock");
    $finish;
  end
endmodule
