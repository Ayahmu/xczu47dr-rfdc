`timescale 1ns / 1ps

module tb_waveform_executor_wave_done_hold;
  localparam [63:0] CH1_ADDR = 64'h0000000000000000;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg [127:0] instr_tdata = 128'd0;
  reg         instr_tvalid = 1'b0;
  wire        instr_tready;

  wire [103:0] dm_cmd_tdata;
  wire         dm_cmd_tvalid;
  reg          dm_cmd_tready = 1'b1;

  reg [255:0] dm_data_tdata = 256'd0;
  reg         dm_data_tvalid = 1'b0;
  wire        dm_data_tready;

  reg [15:0] ch1_fifo_level_beats = 16'd0;
  wire [31:0] ch1_len_beats;
  wire        ch1_arm;
  wire        cfg_auto_start;
  wire        cfg_commit;
  wire [2:0]  dbg_st;

  integer cfg_commit_count = 0;

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
    .s_axis_dm_data_tdata(dm_data_tdata),
    .s_axis_dm_data_tvalid(dm_data_tvalid),
    .s_axis_dm_data_tready(dm_data_tready),
    .ch1_fifo_ready(1'b1),
    .ch2_fifo_ready(1'b1),
    .ch3_fifo_ready(1'b1),
    .ch4_fifo_ready(1'b1),
    .ch5_fifo_ready(1'b1),
    .ch6_fifo_ready(1'b1),
    .ch7_fifo_ready(1'b1),
    .ch8_fifo_ready(1'b1),
    .ch1_fifo_level_beats(ch1_fifo_level_beats),
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
    .ch1_len_beats(ch1_len_beats),
    .ch2_len_beats(),
    .ch3_len_beats(),
    .ch4_len_beats(),
    .ch5_len_beats(),
    .ch6_len_beats(),
    .ch7_len_beats(),
    .ch8_len_beats(),
    .ch1_arm(ch1_arm),
    .ch2_arm(),
    .ch3_arm(),
    .ch4_arm(),
    .ch5_arm(),
    .ch6_arm(),
    .ch7_arm(),
    .ch8_arm(),
    .cfg_auto_start(cfg_auto_start),
    .cfg_commit(cfg_commit),
    .dbg_st(dbg_st),
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
    .dbg_bad_instr_count()
  );

  always @(posedge clk) begin
    if(!rst_n) begin
      cfg_commit_count <= 0;
    end else if(cfg_commit) begin
      cfg_commit_count <= cfg_commit_count + 1;
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

  task send_dm_beat(input [255:0] word);
    begin
      @(negedge clk);
      dm_data_tdata = word;
      dm_data_tvalid = 1'b1;
      while(!dm_data_tready) @(negedge clk);
      @(negedge clk);
      dm_data_tvalid = 1'b0;
      dm_data_tdata = 256'd0;
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

    send_instr({CH1_ADDR, 32'd4096, 32'h00000012});
    send_instr(128'h000000000000000000000000000000f3);

    wait(dm_cmd_tvalid && dm_cmd_tready);
    repeat(2) @(negedge clk);
    ch1_fifo_level_beats = 16'd128;

    for(integer beat = 0; beat < 128; beat = beat + 1) begin
      send_dm_beat({224'd0, beat[31:0]});
    end

    wait(cfg_commit);
    repeat(4) @(negedge clk);
    check_condition(cfg_commit_count == 1, "cfg_commit should pulse once after prefill");
    check_condition(ch1_arm == 1'b1, "ch1_arm must stay high while the DAC FIFO still contains data");
    check_condition(cfg_auto_start == 1'b1, "cfg_auto_start must stay high while the DAC FIFO still contains data");
    check_condition(ch1_len_beats == 32'd128, "ch1_len_beats must remain valid for the CDC payload");
    check_condition(dbg_st == 3'd3, "executor must remain in ST_PLAYING until the armed FIFO drains");

    ch1_fifo_level_beats = 16'd0;
    repeat(4) @(negedge clk);
    check_condition(ch1_arm == 1'b0, "ch1_arm should clear after the armed FIFO drains");
    check_condition(dbg_st == 3'd0, "executor should return to ST_BUILD after playback drains");

    $display("PASS: waveform executor holds config until armed FIFO drains");
    $finish;
  end
endmodule
