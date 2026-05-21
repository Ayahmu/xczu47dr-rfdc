`timescale 1ns / 1ps

module tb_waveform_executor;
  localparam [63:0] GOLDEN_ADDR = 64'h0000000123456000;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg [127:0] instr_tdata = 128'd0;
  reg         instr_tvalid = 1'b0;
  wire        instr_tready;

  wire [103:0] dm_cmd_tdata;
  wire         dm_cmd_tvalid;
  reg          dm_cmd_tready = 1'b1;

  reg [127:0] dm_data_tdata = 128'd0;
  reg         dm_data_tvalid = 1'b0;
  wire        dm_data_tready;

  wire [127:0] ch1_tdata;
  wire         ch1_tvalid;
  wire [127:0] ch2_tdata;
  wire         ch2_tvalid;

  wire [2:0] dbg_st;
  wire [1:0] dbg_dm_st;
  wire [31:0] dbg_dm_chunk_beats;
  wire [31:0] dbg_ch1_bytes_left;
  wire [63:0] dbg_ch1_base_addr;
  wire        cfg_commit;

  reg captured_cmd_valid = 1'b0;
  reg [103:0] captured_cmd_tdata = 104'd0;
  integer ch1_stream_count = 0;
  integer ch2_stream_count = 0;
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
    .ch1_fifo_level_beats(16'd0),
    .ch2_fifo_level_beats(16'd0),
    .m_axis_ch1_tdata(ch1_tdata),
    .m_axis_ch1_tvalid(ch1_tvalid),
    .m_axis_ch2_tdata(ch2_tdata),
    .m_axis_ch2_tvalid(ch2_tvalid),
    .ch1_delay_cycles(),
    .ch2_delay_cycles(),
    .ch1_len_beats(),
    .ch2_len_beats(),
    .ch1_arm(),
    .ch2_arm(),
    .cfg_auto_start(),
    .cfg_commit(cfg_commit),
    .dbg_st(dbg_st),
    .dbg_dm_st(dbg_dm_st),
    .dbg_dm_sel_ch1(),
    .dbg_dm_chunk_beats(dbg_dm_chunk_beats),
    .dbg_dm_beats_sent(),
    .dbg_ch1_bytes_left(dbg_ch1_bytes_left),
    .dbg_ch2_bytes_left(),
    .dbg_ch1_base_addr(dbg_ch1_base_addr),
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
    .dbg_run_delay_cnt()
  );

  always @(posedge clk) begin
    if (!rst_n) begin
      captured_cmd_valid <= 1'b0;
      captured_cmd_tdata <= 104'd0;
    end else if (dm_cmd_tvalid && dm_cmd_tready) begin
      captured_cmd_valid <= 1'b1;
      captured_cmd_tdata <= dm_cmd_tdata;
    end
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      ch1_stream_count <= 0;
      ch2_stream_count <= 0;
      cfg_commit_count <= 0;
    end else begin
      if (cfg_commit) begin
        cfg_commit_count <= cfg_commit_count + 1;
      end
      if (ch1_tvalid) begin
        ch1_stream_count <= ch1_stream_count + 1;
        check_condition(ch1_tdata == dm_data_tdata, "ch1 stream data should match DataMover data");
      end
      if (ch2_tvalid) begin
        ch2_stream_count <= ch2_stream_count + 1;
      end
    end
  end

  task send_instr(input [127:0] word);
    begin
      @(negedge clk);
      instr_tdata = word;
      instr_tvalid = 1'b1;
      while (!instr_tready) @(negedge clk);
      @(negedge clk);
      instr_tvalid = 1'b0;
      instr_tdata = 128'd0;
    end
  endtask

  task check_condition(input condition, input string message);
    begin
      if (!condition) begin
        $display("FAIL: %s", message);
        $finish;
      end
    end
  endtask

  task send_dm_beat(input [127:0] word);
    begin
      @(negedge clk);
      dm_data_tdata = word;
      dm_data_tvalid = 1'b1;
      while (!dm_data_tready) @(negedge clk);
      @(negedge clk);
      dm_data_tvalid = 1'b0;
      dm_data_tdata = 128'd0;
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(negedge clk);

    send_instr(128'h00000000000000000000000000000011);
    send_instr({GOLDEN_ADDR, 32'h00001000, 32'h00000012});
    send_instr(128'h000000000000000000000000000000f3);

    repeat (4) @(negedge clk);
    check_condition(cfg_commit_count == 0, "cfg_commit must wait until waveform prefill completes");

    repeat (16) @(negedge clk);

    check_condition(captured_cmd_valid, "executor did not issue a DataMover command for ch1 PLAY");
    check_condition(captured_cmd_tdata[22:0] == 23'd4096, "first DataMover command BTT should be one full 4096-byte waveform");
    check_condition(captured_cmd_tdata[95:32] == GOLDEN_ADDR, "first DataMover command address field should match PLAY address");
    check_condition(captured_cmd_tdata[103:96] == 8'h00, "first DataMover command tag should be 0");
    check_condition(captured_cmd_tdata[31] == 1'b0, "first DataMover command DRR should be 0");
    check_condition(captured_cmd_tdata[30] == 1'b1, "first DataMover command EOF should be 1");
    check_condition(captured_cmd_tdata[29:24] == 6'h00, "first DataMover command DSA should be 0");
    check_condition(captured_cmd_tdata[23] == 1'b1, "first DataMover command type should be incrementing address");
    check_condition(dbg_dm_chunk_beats == 32'd256, "chunk size should cover one full 4096-byte waveform");

    for (integer beat = 0; beat < 256; beat = beat + 1) begin
      send_dm_beat({64'hfeedface00000000, 32'd0, beat[31:0]});
    end

    repeat (4) @(negedge clk);
    check_condition(cfg_commit_count == 1, "cfg_commit should pulse exactly once after full waveform prefill completes");
    check_condition(ch1_stream_count == 256, "executor should route one full 4096-byte waveform to ch1");
    check_condition(ch2_stream_count == 0, "executor should not route ch1 PLAY data to ch2");
    check_condition(dbg_ch1_bytes_left == 32'd0, "executor should consume the full 4096-byte ch1 waveform");

    $display("PASS: Waveform executor emits one full DataMover command for golden PLAY");
    $finish;
  end
endmodule
