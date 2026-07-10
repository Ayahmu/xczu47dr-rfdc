`timescale 1ns / 1ps

module waveform_bandwidth_top #(
  parameter integer BEAT_BYTES   = 64,
  parameter integer CHUNK_BEATS  = 16384,
  parameter integer LOW_WM       = 128,
  parameter integer HIGH_WM      = 768,
  parameter integer START_WM     = 256,
  parameter integer OUTSTANDING_LIMIT = 15,
  parameter integer MAX_CONSECUTIVE_CHUNKS = 4,
  parameter integer INTERLEAVED_MODE = 1,
  parameter [63:0] DDR_ADDR_BASE = 64'h0000_0048_0000_0000
)(
    input  wire         aclk,
    input  wire         aresetn,
    input  wire         clear,
    input  wire         trigger,

    input  wire [127:0] s_axis_instr_tdata,
    input  wire         s_axis_instr_tvalid,
    output wire         s_axis_instr_tready,

    output reg  [103:0] m_axis_dm_cmd_tdata,
    output reg          m_axis_dm_cmd_tvalid,
    input  wire         m_axis_dm_cmd_tready,

    input  wire [511:0] s_axis_dm_data_tdata,
    input  wire         s_axis_dm_data_tvalid,
    input  wire         s_axis_dm_data_tready,

    output wire [2:0]   dm_sel_o,
    output wire [7:0]   ch_arm_o,
    input  wire [15:0]  ch1_fifo_level_beats,
    input  wire [15:0]  ch2_fifo_level_beats,
    input  wire [15:0]  ch3_fifo_level_beats,
    input  wire [15:0]  ch4_fifo_level_beats,
    input  wire [15:0]  ch5_fifo_level_beats,
    input  wire [15:0]  ch6_fifo_level_beats,
    input  wire [15:0]  ch7_fifo_level_beats,
    input  wire [15:0]  ch8_fifo_level_beats,

    output wire [31:0]  status,
    output wire [31:0]  total_bursts,
    output wire [31:0]  ch_bursts,
    input  wire [2:0]   ch_select
);

  localparam ST_BUILD    = 3'd0;
  localparam ST_PREFILL  = 3'd1;
  localparam ST_WAITTRIG = 3'd2;
  localparam ST_PLAYING  = 3'd3;

  localparam CMD_DELAY = 4'd1;
  localparam CMD_PLAY  = 4'd2;
  localparam CMD_END   = 4'd3;
  localparam CH_AUTO_START = 4'hF;

  wire [127:0] main_tdata;
  wire         main_tvalid;
  wire         main_tready;

  axis_data_fifo_1 u_main_fifo (
    .s_axis_aclk    (aclk),
    .s_axis_aresetn (aresetn),
    .s_axis_tdata   (s_axis_instr_tdata),
    .s_axis_tvalid  (s_axis_instr_tvalid),
    .s_axis_tready  (s_axis_instr_tready),
    .m_axis_tdata   (main_tdata),
    .m_axis_tvalid  (main_tvalid),
    .m_axis_tready  (main_tready)
  );

  reg trig_d;
  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) trig_d <= 1'b0;
    else         trig_d <= trigger;
  end
  wire trig_pulse = trigger & ~trig_d;

  wire [3:0]  instr_cmd = main_tdata[3:0];
  wire [3:0]  instr_ch = main_tdata[7:4];
  wire        instr_loop = main_tdata[8];
  wire [31:0] instr_value = main_tdata[63:32];
  wire [63:0] instr_addr = main_tdata[127:64];

  reg [2:0] st;
  reg pending_valid;
  reg prefill_auto_start;
  reg loop_enable;
  reg active_valid;
  reg cfg_auto_start;

  reg cur_ch1_have_play, cur_ch2_have_play, cur_ch3_have_play, cur_ch4_have_play;
  reg cur_ch5_have_play, cur_ch6_have_play, cur_ch7_have_play, cur_ch8_have_play;
  reg ch1_arm, ch2_arm, ch3_arm, ch4_arm, ch5_arm, ch6_arm, ch7_arm, ch8_arm;

  reg        ch1_load_tog, ch2_load_tog, ch3_load_tog, ch4_load_tog;
  reg        ch5_load_tog, ch6_load_tog, ch7_load_tog, ch8_load_tog;
  reg [63:0] ch1_load_addr, ch2_load_addr, ch3_load_addr, ch4_load_addr;
  reg [63:0] ch5_load_addr, ch6_load_addr, ch7_load_addr, ch8_load_addr;
  reg [31:0] ch1_load_bytes, ch2_load_bytes, ch3_load_bytes, ch4_load_bytes;
  reg [31:0] ch5_load_bytes, ch6_load_bytes, ch7_load_bytes, ch8_load_bytes;

  reg [31:0] total_burst_count;
  reg [31:0] ch_burst_count [0:7];
  reg [31:0] ch_inflight_beats [0:7];
  integer bi;
  reg [63:0] inter_load_addr;
  reg [63:0] inter_load_bytes;
  reg        inter_load_tog;
  reg        inter_load_tog_d;
  reg [63:0] inter_base_addr;
  reg [63:0] inter_bytes_left;
  reg        inter_active_valid;
  reg [2:0]  dma_req_sel_r;
  reg [63:0] dma_req_addr_r;
  reg [63:0] dma_req_abs_addr_r;
  reg [31:0] dma_req_chunk_beats_r;
  reg [31:0] dma_req_chunk_bytes_r;
  reg [2:0]  last_grant_sel;
  reg [3:0]  same_grant_count;

  localparam CMD_IDLE    = 2'd0;
  localparam CMD_STAGE   = 2'd1;
  localparam CMD_PREP    = 2'd2;
  localparam CMD_SENDCMD = 2'd3;
  reg [1:0] cmd_st;

  wire [63:0] ch1_base_addr, ch2_base_addr, ch3_base_addr, ch4_base_addr;
  wire [63:0] ch5_base_addr, ch6_base_addr, ch7_base_addr, ch8_base_addr;
  wire [31:0] ch1_bytes_left, ch2_bytes_left, ch3_bytes_left, ch4_bytes_left;
  wire [31:0] ch5_bytes_left, ch6_bytes_left, ch7_bytes_left, ch8_bytes_left;
  wire act_ch1_valid_dm, act_ch2_valid_dm, act_ch3_valid_dm, act_ch4_valid_dm;
  wire act_ch5_valid_dm, act_ch6_valid_dm, act_ch7_valid_dm, act_ch8_valid_dm;

  assign main_tready = (st == ST_BUILD);
  wire [2:0] stream_sel;
  assign dm_sel_o = stream_sel;
  assign ch_arm_o = {ch8_arm, ch7_arm, ch6_arm, ch5_arm, ch4_arm, ch3_arm, ch2_arm, ch1_arm};
  assign total_bursts = total_burst_count;
  assign ch_bursts = ch_burst_count[ch_select];

  wire [4:0] outstanding_count;
  wire prefill_done_channels = active_valid && (cmd_st == CMD_IDLE) && (outstanding_count == 5'd0) &&
                      (!cur_ch1_have_play || (ch1_bytes_left == 0)) &&
                      (!cur_ch2_have_play || (ch2_bytes_left == 0)) &&
                      (!cur_ch3_have_play || (ch3_bytes_left == 0)) &&
                      (!cur_ch4_have_play || (ch4_bytes_left == 0)) &&
                      (!cur_ch5_have_play || (ch5_bytes_left == 0)) &&
                      (!cur_ch6_have_play || (ch6_bytes_left == 0)) &&
                      (!cur_ch7_have_play || (ch7_bytes_left == 0)) &&
                      (!cur_ch8_have_play || (ch8_bytes_left == 0));
  wire prefill_done_interleaved = active_valid && (cmd_st == CMD_IDLE) && (outstanding_count == 5'd0) &&
                                  (!inter_active_valid || (inter_bytes_left == 64'd0));
  wire prefill_done = (INTERLEAVED_MODE != 0) ? prefill_done_interleaved : prefill_done_channels;

  wire beat_fire = s_axis_dm_data_tvalid && s_axis_dm_data_tready;
  wire cmd_fire = m_axis_dm_cmd_tvalid && m_axis_dm_cmd_tready;
  wire [31:0] issued_chunk_bytes = dma_req_chunk_bytes_r;
  wire prefetch_en = active_valid;

  assign status = {
      16'd0,
      cfg_auto_start,
      pending_valid,
      active_valid,
      prefill_done,
      cmd_st,
      st,
      m_axis_dm_cmd_tready,
      m_axis_dm_cmd_tvalid
  };

  Waveform_Channel_State u_ch1_state (.aclk(aclk), .aresetn(aresetn), .prefetch_en(prefetch_en), .load_tog(ch1_load_tog), .load_addr(ch1_load_addr), .load_bytes(ch1_load_bytes), .chunk_done(cmd_fire && (dma_req_sel_r == 3'd0)), .chunk_bytes(issued_chunk_bytes), .base_addr(ch1_base_addr), .bytes_left(ch1_bytes_left), .active_valid_dm(act_ch1_valid_dm));
  Waveform_Channel_State u_ch2_state (.aclk(aclk), .aresetn(aresetn), .prefetch_en(prefetch_en), .load_tog(ch2_load_tog), .load_addr(ch2_load_addr), .load_bytes(ch2_load_bytes), .chunk_done(cmd_fire && (dma_req_sel_r == 3'd1)), .chunk_bytes(issued_chunk_bytes), .base_addr(ch2_base_addr), .bytes_left(ch2_bytes_left), .active_valid_dm(act_ch2_valid_dm));
  Waveform_Channel_State u_ch3_state (.aclk(aclk), .aresetn(aresetn), .prefetch_en(prefetch_en), .load_tog(ch3_load_tog), .load_addr(ch3_load_addr), .load_bytes(ch3_load_bytes), .chunk_done(cmd_fire && (dma_req_sel_r == 3'd2)), .chunk_bytes(issued_chunk_bytes), .base_addr(ch3_base_addr), .bytes_left(ch3_bytes_left), .active_valid_dm(act_ch3_valid_dm));
  Waveform_Channel_State u_ch4_state (.aclk(aclk), .aresetn(aresetn), .prefetch_en(prefetch_en), .load_tog(ch4_load_tog), .load_addr(ch4_load_addr), .load_bytes(ch4_load_bytes), .chunk_done(cmd_fire && (dma_req_sel_r == 3'd3)), .chunk_bytes(issued_chunk_bytes), .base_addr(ch4_base_addr), .bytes_left(ch4_bytes_left), .active_valid_dm(act_ch4_valid_dm));
  Waveform_Channel_State u_ch5_state (.aclk(aclk), .aresetn(aresetn), .prefetch_en(prefetch_en), .load_tog(ch5_load_tog), .load_addr(ch5_load_addr), .load_bytes(ch5_load_bytes), .chunk_done(cmd_fire && (dma_req_sel_r == 3'd4)), .chunk_bytes(issued_chunk_bytes), .base_addr(ch5_base_addr), .bytes_left(ch5_bytes_left), .active_valid_dm(act_ch5_valid_dm));
  Waveform_Channel_State u_ch6_state (.aclk(aclk), .aresetn(aresetn), .prefetch_en(prefetch_en), .load_tog(ch6_load_tog), .load_addr(ch6_load_addr), .load_bytes(ch6_load_bytes), .chunk_done(cmd_fire && (dma_req_sel_r == 3'd5)), .chunk_bytes(issued_chunk_bytes), .base_addr(ch6_base_addr), .bytes_left(ch6_bytes_left), .active_valid_dm(act_ch6_valid_dm));
  Waveform_Channel_State u_ch7_state (.aclk(aclk), .aresetn(aresetn), .prefetch_en(prefetch_en), .load_tog(ch7_load_tog), .load_addr(ch7_load_addr), .load_bytes(ch7_load_bytes), .chunk_done(cmd_fire && (dma_req_sel_r == 3'd6)), .chunk_bytes(issued_chunk_bytes), .base_addr(ch7_base_addr), .bytes_left(ch7_bytes_left), .active_valid_dm(act_ch7_valid_dm));
  Waveform_Channel_State u_ch8_state (.aclk(aclk), .aresetn(aresetn), .prefetch_en(prefetch_en), .load_tog(ch8_load_tog), .load_addr(ch8_load_addr), .load_bytes(ch8_load_bytes), .chunk_done(cmd_fire && (dma_req_sel_r == 3'd7)), .chunk_bytes(issued_chunk_bytes), .base_addr(ch8_base_addr), .bytes_left(ch8_bytes_left), .active_valid_dm(act_ch8_valid_dm));

  wire [31:0] ch1_virtual_level_next = {16'd0, ch1_fifo_level_beats} + ch_inflight_beats[0];
  wire [31:0] ch2_virtual_level_next = {16'd0, ch2_fifo_level_beats} + ch_inflight_beats[1];
  wire [31:0] ch3_virtual_level_next = {16'd0, ch3_fifo_level_beats} + ch_inflight_beats[2];
  wire [31:0] ch4_virtual_level_next = {16'd0, ch4_fifo_level_beats} + ch_inflight_beats[3];
  wire [31:0] ch5_virtual_level_next = {16'd0, ch5_fifo_level_beats} + ch_inflight_beats[4];
  wire [31:0] ch6_virtual_level_next = {16'd0, ch6_fifo_level_beats} + ch_inflight_beats[5];
  wire [31:0] ch7_virtual_level_next = {16'd0, ch7_fifo_level_beats} + ch_inflight_beats[6];
  wire [31:0] ch8_virtual_level_next = {16'd0, ch8_fifo_level_beats} + ch_inflight_beats[7];

  wire ch1_need_hard_next  = prefetch_en && act_ch1_valid_dm && (ch1_bytes_left != 0) && (ch1_virtual_level_next < LOW_WM);
  wire ch2_need_hard_next  = prefetch_en && act_ch2_valid_dm && (ch2_bytes_left != 0) && (ch2_virtual_level_next < LOW_WM);
  wire ch3_need_hard_next  = prefetch_en && act_ch3_valid_dm && (ch3_bytes_left != 0) && (ch3_virtual_level_next < LOW_WM);
  wire ch4_need_hard_next  = prefetch_en && act_ch4_valid_dm && (ch4_bytes_left != 0) && (ch4_virtual_level_next < LOW_WM);
  wire ch5_need_hard_next  = prefetch_en && act_ch5_valid_dm && (ch5_bytes_left != 0) && (ch5_virtual_level_next < LOW_WM);
  wire ch6_need_hard_next  = prefetch_en && act_ch6_valid_dm && (ch6_bytes_left != 0) && (ch6_virtual_level_next < LOW_WM);
  wire ch7_need_hard_next  = prefetch_en && act_ch7_valid_dm && (ch7_bytes_left != 0) && (ch7_virtual_level_next < LOW_WM);
  wire ch8_need_hard_next  = prefetch_en && act_ch8_valid_dm && (ch8_bytes_left != 0) && (ch8_virtual_level_next < LOW_WM);
  wire ch1_need_start_next = prefetch_en && act_ch1_valid_dm && (ch1_bytes_left != 0) && (ch1_virtual_level_next < START_WM);
  wire ch2_need_start_next = prefetch_en && act_ch2_valid_dm && (ch2_bytes_left != 0) && (ch2_virtual_level_next < START_WM);
  wire ch3_need_start_next = prefetch_en && act_ch3_valid_dm && (ch3_bytes_left != 0) && (ch3_virtual_level_next < START_WM);
  wire ch4_need_start_next = prefetch_en && act_ch4_valid_dm && (ch4_bytes_left != 0) && (ch4_virtual_level_next < START_WM);
  wire ch5_need_start_next = prefetch_en && act_ch5_valid_dm && (ch5_bytes_left != 0) && (ch5_virtual_level_next < START_WM);
  wire ch6_need_start_next = prefetch_en && act_ch6_valid_dm && (ch6_bytes_left != 0) && (ch6_virtual_level_next < START_WM);
  wire ch7_need_start_next = prefetch_en && act_ch7_valid_dm && (ch7_bytes_left != 0) && (ch7_virtual_level_next < START_WM);
  wire ch8_need_start_next = prefetch_en && act_ch8_valid_dm && (ch8_bytes_left != 0) && (ch8_virtual_level_next < START_WM);
  wire ch1_need_soft_next  = prefetch_en && act_ch1_valid_dm && (ch1_bytes_left != 0) && (ch1_virtual_level_next < HIGH_WM);
  wire ch2_need_soft_next  = prefetch_en && act_ch2_valid_dm && (ch2_bytes_left != 0) && (ch2_virtual_level_next < HIGH_WM);
  wire ch3_need_soft_next  = prefetch_en && act_ch3_valid_dm && (ch3_bytes_left != 0) && (ch3_virtual_level_next < HIGH_WM);
  wire ch4_need_soft_next  = prefetch_en && act_ch4_valid_dm && (ch4_bytes_left != 0) && (ch4_virtual_level_next < HIGH_WM);
  wire ch5_need_soft_next  = prefetch_en && act_ch5_valid_dm && (ch5_bytes_left != 0) && (ch5_virtual_level_next < HIGH_WM);
  wire ch6_need_soft_next  = prefetch_en && act_ch6_valid_dm && (ch6_bytes_left != 0) && (ch6_virtual_level_next < HIGH_WM);
  wire ch7_need_soft_next  = prefetch_en && act_ch7_valid_dm && (ch7_bytes_left != 0) && (ch7_virtual_level_next < HIGH_WM);
  wire ch8_need_soft_next  = prefetch_en && act_ch8_valid_dm && (ch8_bytes_left != 0) && (ch8_virtual_level_next < HIGH_WM);

  reg sel_snapshot_valid;
  reg ch1_need_hard_q, ch2_need_hard_q, ch3_need_hard_q, ch4_need_hard_q;
  reg ch5_need_hard_q, ch6_need_hard_q, ch7_need_hard_q, ch8_need_hard_q;
  reg ch1_need_start_q, ch2_need_start_q, ch3_need_start_q, ch4_need_start_q;
  reg ch5_need_start_q, ch6_need_start_q, ch7_need_start_q, ch8_need_start_q;
  reg ch1_need_soft_q, ch2_need_soft_q, ch3_need_soft_q, ch4_need_soft_q;
  reg ch5_need_soft_q, ch6_need_soft_q, ch7_need_soft_q, ch8_need_soft_q;

  wire ch1_current_valid = act_ch1_valid_dm && (ch1_bytes_left != 0);
  wire ch2_current_valid = act_ch2_valid_dm && (ch2_bytes_left != 0);
  wire ch3_current_valid = act_ch3_valid_dm && (ch3_bytes_left != 0);
  wire ch4_current_valid = act_ch4_valid_dm && (ch4_bytes_left != 0);
  wire ch5_current_valid = act_ch5_valid_dm && (ch5_bytes_left != 0);
  wire ch6_current_valid = act_ch6_valid_dm && (ch6_bytes_left != 0);
  wire ch7_current_valid = act_ch7_valid_dm && (ch7_bytes_left != 0);
  wire ch8_current_valid = act_ch8_valid_dm && (ch8_bytes_left != 0);

  wire ch1_need_hard  = sel_snapshot_valid && ch1_current_valid && ch1_need_hard_q;
  wire ch2_need_hard  = sel_snapshot_valid && ch2_current_valid && ch2_need_hard_q;
  wire ch3_need_hard  = sel_snapshot_valid && ch3_current_valid && ch3_need_hard_q;
  wire ch4_need_hard  = sel_snapshot_valid && ch4_current_valid && ch4_need_hard_q;
  wire ch5_need_hard  = sel_snapshot_valid && ch5_current_valid && ch5_need_hard_q;
  wire ch6_need_hard  = sel_snapshot_valid && ch6_current_valid && ch6_need_hard_q;
  wire ch7_need_hard  = sel_snapshot_valid && ch7_current_valid && ch7_need_hard_q;
  wire ch8_need_hard  = sel_snapshot_valid && ch8_current_valid && ch8_need_hard_q;
  wire ch1_need_start = sel_snapshot_valid && ch1_current_valid && ch1_need_start_q;
  wire ch2_need_start = sel_snapshot_valid && ch2_current_valid && ch2_need_start_q;
  wire ch3_need_start = sel_snapshot_valid && ch3_current_valid && ch3_need_start_q;
  wire ch4_need_start = sel_snapshot_valid && ch4_current_valid && ch4_need_start_q;
  wire ch5_need_start = sel_snapshot_valid && ch5_current_valid && ch5_need_start_q;
  wire ch6_need_start = sel_snapshot_valid && ch6_current_valid && ch6_need_start_q;
  wire ch7_need_start = sel_snapshot_valid && ch7_current_valid && ch7_need_start_q;
  wire ch8_need_start = sel_snapshot_valid && ch8_current_valid && ch8_need_start_q;
  wire ch1_need_soft  = sel_snapshot_valid && ch1_current_valid && ch1_need_soft_q;
  wire ch2_need_soft  = sel_snapshot_valid && ch2_current_valid && ch2_need_soft_q;
  wire ch3_need_soft  = sel_snapshot_valid && ch3_current_valid && ch3_need_soft_q;
  wire ch4_need_soft  = sel_snapshot_valid && ch4_current_valid && ch4_need_soft_q;
  wire ch5_need_soft  = sel_snapshot_valid && ch5_current_valid && ch5_need_soft_q;
  wire ch6_need_soft  = sel_snapshot_valid && ch6_current_valid && ch6_need_soft_q;
  wire ch7_need_soft  = sel_snapshot_valid && ch7_current_valid && ch7_need_soft_q;
  wire ch8_need_soft  = sel_snapshot_valid && ch8_current_valid && ch8_need_soft_q;

  reg [2:0] rr;
  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) rr <= 3'd0;
    else if(clear) rr <= 3'd0;
    else if(cmd_fire) rr <= dma_req_sel_r + 3'd1;
  end

  function [31:0] min_u32;
    input [31:0] a,b;
    begin min_u32 = (a < b) ? a : b; end
  endfunction

  function [31:0] bytes_to_beats;
    input [31:0] bytes;
    begin bytes_to_beats = bytes >> 6; end
  endfunction

  function [31:0] beats_to_bytes;
    input [31:0] beats;
    begin beats_to_bytes = beats << 6; end
  endfunction

  function [31:0] bytes64_to_beats32;
    input [63:0] bytes;
    begin bytes64_to_beats32 = bytes[37:6]; end
  endfunction

  function [103:0] make_dm_cmd;
    input [63:0] abs_addr;
    input [31:0] bytes;
    begin
      make_dm_cmd = {8'h00, abs_addr, 1'b0, 1'b1, 6'h00, 1'b1, bytes[22:0]};
    end
  endfunction

  wire [31:0] ch1_chunk_beats_w = min_u32(bytes_to_beats(ch1_bytes_left), CHUNK_BEATS);
  wire [31:0] ch2_chunk_beats_w = min_u32(bytes_to_beats(ch2_bytes_left), CHUNK_BEATS);
  wire [31:0] ch3_chunk_beats_w = min_u32(bytes_to_beats(ch3_bytes_left), CHUNK_BEATS);
  wire [31:0] ch4_chunk_beats_w = min_u32(bytes_to_beats(ch4_bytes_left), CHUNK_BEATS);
  wire [31:0] ch5_chunk_beats_w = min_u32(bytes_to_beats(ch5_bytes_left), CHUNK_BEATS);
  wire [31:0] ch6_chunk_beats_w = min_u32(bytes_to_beats(ch6_bytes_left), CHUNK_BEATS);
  wire [31:0] ch7_chunk_beats_w = min_u32(bytes_to_beats(ch7_bytes_left), CHUNK_BEATS);
  wire [31:0] ch8_chunk_beats_w = min_u32(bytes_to_beats(ch8_bytes_left), CHUNK_BEATS);
  wire [31:0] inter_chunk_beats_w = (inter_bytes_left >= {32'd0, beats_to_bytes(CHUNK_BEATS)}) ?
                                    CHUNK_BEATS[31:0] : bytes64_to_beats32(inter_bytes_left);
  wire inter_dma_req_valid = (INTERLEAVED_MODE != 0) && prefetch_en && inter_active_valid &&
                             (inter_bytes_left != 64'd0) && (inter_chunk_beats_w != 32'd0);

  wire dma_req_valid;
  wire [2:0] dma_req_sel;

  Waveform_Dma_Selector u_dma_selector (
    .high_wm(HIGH_WM[15:0]),
    .last_grant_sel(last_grant_sel),
    .same_grant_count(same_grant_count),
    .max_consecutive_chunks(MAX_CONSECUTIVE_CHUNKS[3:0]),
    .rr(rr),
    .ch1_need_hard(ch1_need_hard), .ch2_need_hard(ch2_need_hard), .ch3_need_hard(ch3_need_hard), .ch4_need_hard(ch4_need_hard),
    .ch5_need_hard(ch5_need_hard), .ch6_need_hard(ch6_need_hard), .ch7_need_hard(ch7_need_hard), .ch8_need_hard(ch8_need_hard),
    .ch1_need_start(ch1_need_start), .ch2_need_start(ch2_need_start), .ch3_need_start(ch3_need_start), .ch4_need_start(ch4_need_start),
    .ch5_need_start(ch5_need_start), .ch6_need_start(ch6_need_start), .ch7_need_start(ch7_need_start), .ch8_need_start(ch8_need_start),
    .ch1_need_soft(ch1_need_soft), .ch2_need_soft(ch2_need_soft), .ch3_need_soft(ch3_need_soft), .ch4_need_soft(ch4_need_soft),
    .ch5_need_soft(ch5_need_soft), .ch6_need_soft(ch6_need_soft), .ch7_need_soft(ch7_need_soft), .ch8_need_soft(ch8_need_soft),
    .ch1_virtual_level(ch1_virtual_level_next[15:0]), .ch2_virtual_level(ch2_virtual_level_next[15:0]), .ch3_virtual_level(ch3_virtual_level_next[15:0]), .ch4_virtual_level(ch4_virtual_level_next[15:0]),
    .ch5_virtual_level(ch5_virtual_level_next[15:0]), .ch6_virtual_level(ch6_virtual_level_next[15:0]), .ch7_virtual_level(ch7_virtual_level_next[15:0]), .ch8_virtual_level(ch8_virtual_level_next[15:0]),
    .req_valid(dma_req_valid), .req_sel(dma_req_sel)
  );

  wire wave_done = (st == ST_PLAYING) && prefill_done && !loop_enable;

  localparam integer RETQ_DEPTH = 16;
  localparam integer RETQ_PTR_W = 4;
  reg [2:0]  retq_sel [0:RETQ_DEPTH-1];
  reg [31:0] retq_beats_left [0:RETQ_DEPTH-1];
  reg [RETQ_PTR_W-1:0] retq_wr_ptr;
  reg [RETQ_PTR_W-1:0] retq_rd_ptr;
  reg [4:0] retq_count;
  wire retq_full = (retq_count >= OUTSTANDING_LIMIT[4:0]);
  wire retq_empty = (retq_count == 5'd0);
  wire retq_push = cmd_fire;
  wire retq_pop = beat_fire && !retq_empty && (retq_beats_left[retq_rd_ptr] == 32'd1);
  wire [2:0] retq_stream_sel = retq_empty ? 3'd0 : retq_sel[retq_rd_ptr];
  wire inflight_same_channel = retq_push && beat_fire && !retq_empty && (dma_req_sel_r == retq_stream_sel);
  assign stream_sel = retq_stream_sel;
  assign outstanding_count = retq_count;

  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) begin
      sel_snapshot_valid <= 1'b0;
      ch1_need_hard_q <= 1'b0; ch2_need_hard_q <= 1'b0; ch3_need_hard_q <= 1'b0; ch4_need_hard_q <= 1'b0;
      ch5_need_hard_q <= 1'b0; ch6_need_hard_q <= 1'b0; ch7_need_hard_q <= 1'b0; ch8_need_hard_q <= 1'b0;
      ch1_need_start_q <= 1'b0; ch2_need_start_q <= 1'b0; ch3_need_start_q <= 1'b0; ch4_need_start_q <= 1'b0;
      ch5_need_start_q <= 1'b0; ch6_need_start_q <= 1'b0; ch7_need_start_q <= 1'b0; ch8_need_start_q <= 1'b0;
      ch1_need_soft_q <= 1'b0; ch2_need_soft_q <= 1'b0; ch3_need_soft_q <= 1'b0; ch4_need_soft_q <= 1'b0;
      ch5_need_soft_q <= 1'b0; ch6_need_soft_q <= 1'b0; ch7_need_soft_q <= 1'b0; ch8_need_soft_q <= 1'b0;
    end else if(clear || !prefetch_en) begin
      sel_snapshot_valid <= 1'b0;
      ch1_need_hard_q <= 1'b0; ch2_need_hard_q <= 1'b0; ch3_need_hard_q <= 1'b0; ch4_need_hard_q <= 1'b0;
      ch5_need_hard_q <= 1'b0; ch6_need_hard_q <= 1'b0; ch7_need_hard_q <= 1'b0; ch8_need_hard_q <= 1'b0;
      ch1_need_start_q <= 1'b0; ch2_need_start_q <= 1'b0; ch3_need_start_q <= 1'b0; ch4_need_start_q <= 1'b0;
      ch5_need_start_q <= 1'b0; ch6_need_start_q <= 1'b0; ch7_need_start_q <= 1'b0; ch8_need_start_q <= 1'b0;
      ch1_need_soft_q <= 1'b0; ch2_need_soft_q <= 1'b0; ch3_need_soft_q <= 1'b0; ch4_need_soft_q <= 1'b0;
      ch5_need_soft_q <= 1'b0; ch6_need_soft_q <= 1'b0; ch7_need_soft_q <= 1'b0; ch8_need_soft_q <= 1'b0;
    end else begin
      sel_snapshot_valid <= 1'b1;
      ch1_need_hard_q <= ch1_need_hard_next; ch2_need_hard_q <= ch2_need_hard_next; ch3_need_hard_q <= ch3_need_hard_next; ch4_need_hard_q <= ch4_need_hard_next;
      ch5_need_hard_q <= ch5_need_hard_next; ch6_need_hard_q <= ch6_need_hard_next; ch7_need_hard_q <= ch7_need_hard_next; ch8_need_hard_q <= ch8_need_hard_next;
      ch1_need_start_q <= ch1_need_start_next; ch2_need_start_q <= ch2_need_start_next; ch3_need_start_q <= ch3_need_start_next; ch4_need_start_q <= ch4_need_start_next;
      ch5_need_start_q <= ch5_need_start_next; ch6_need_start_q <= ch6_need_start_next; ch7_need_start_q <= ch7_need_start_next; ch8_need_start_q <= ch8_need_start_next;
      ch1_need_soft_q <= ch1_need_soft_next; ch2_need_soft_q <= ch2_need_soft_next; ch3_need_soft_q <= ch3_need_soft_next; ch4_need_soft_q <= ch4_need_soft_next;
      ch5_need_soft_q <= ch5_need_soft_next; ch6_need_soft_q <= ch6_need_soft_next; ch7_need_soft_q <= ch7_need_soft_next; ch8_need_soft_q <= ch8_need_soft_next;
    end
  end

  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) begin
      st <= ST_BUILD;
      pending_valid <= 1'b0;
      prefill_auto_start <= 1'b0;
      loop_enable <= 1'b0;
      active_valid <= 1'b0;
      cfg_auto_start <= 1'b0;
      cur_ch1_have_play <= 1'b0; cur_ch2_have_play <= 1'b0; cur_ch3_have_play <= 1'b0; cur_ch4_have_play <= 1'b0;
      cur_ch5_have_play <= 1'b0; cur_ch6_have_play <= 1'b0; cur_ch7_have_play <= 1'b0; cur_ch8_have_play <= 1'b0;
      ch1_arm <= 1'b0; ch2_arm <= 1'b0; ch3_arm <= 1'b0; ch4_arm <= 1'b0; ch5_arm <= 1'b0; ch6_arm <= 1'b0; ch7_arm <= 1'b0; ch8_arm <= 1'b0;
      ch1_load_tog <= 1'b0; ch2_load_tog <= 1'b0; ch3_load_tog <= 1'b0; ch4_load_tog <= 1'b0; ch5_load_tog <= 1'b0; ch6_load_tog <= 1'b0; ch7_load_tog <= 1'b0; ch8_load_tog <= 1'b0;
      ch1_load_addr <= 64'd0; ch2_load_addr <= 64'd0; ch3_load_addr <= 64'd0; ch4_load_addr <= 64'd0; ch5_load_addr <= 64'd0; ch6_load_addr <= 64'd0; ch7_load_addr <= 64'd0; ch8_load_addr <= 64'd0;
      ch1_load_bytes <= 32'd0; ch2_load_bytes <= 32'd0; ch3_load_bytes <= 32'd0; ch4_load_bytes <= 32'd0; ch5_load_bytes <= 32'd0; ch6_load_bytes <= 32'd0; ch7_load_bytes <= 32'd0; ch8_load_bytes <= 32'd0;
      inter_load_addr <= 64'd0;
      inter_load_bytes <= 64'd0;
      inter_load_tog <= 1'b0;
    end else if(clear) begin
      st <= ST_BUILD;
      pending_valid <= 1'b0;
      prefill_auto_start <= 1'b0;
      loop_enable <= 1'b0;
      active_valid <= 1'b0;
      cfg_auto_start <= 1'b0;
      cur_ch1_have_play <= 1'b0; cur_ch2_have_play <= 1'b0; cur_ch3_have_play <= 1'b0; cur_ch4_have_play <= 1'b0;
      cur_ch5_have_play <= 1'b0; cur_ch6_have_play <= 1'b0; cur_ch7_have_play <= 1'b0; cur_ch8_have_play <= 1'b0;
      ch1_arm <= 1'b0; ch2_arm <= 1'b0; ch3_arm <= 1'b0; ch4_arm <= 1'b0; ch5_arm <= 1'b0; ch6_arm <= 1'b0; ch7_arm <= 1'b0; ch8_arm <= 1'b0;
      inter_load_addr <= 64'd0;
      inter_load_bytes <= 64'd0;
      inter_load_tog <= 1'b0;
    end else begin
      if(wave_done) begin
        st <= ST_BUILD;
        pending_valid <= 1'b0;
        prefill_auto_start <= 1'b0;
        loop_enable <= 1'b0;
        active_valid <= 1'b0;
        cfg_auto_start <= 1'b0;
      end

      case(st)
        ST_BUILD: begin
          if(main_tvalid && main_tready) begin
            if(instr_cmd == CMD_PLAY) begin
              case(instr_ch)
                4'd1: if(!cur_ch1_have_play) begin cur_ch1_have_play <= 1'b1; ch1_arm <= 1'b1; ch1_load_addr <= instr_addr; ch1_load_bytes <= instr_value; ch1_load_tog <= ~ch1_load_tog; inter_load_addr <= instr_addr; inter_load_bytes <= {29'd0, instr_value, 3'b000}; inter_load_tog <= ~inter_load_tog; active_valid <= 1'b1; end
                4'd2: if(!cur_ch2_have_play) begin cur_ch2_have_play <= 1'b1; ch2_arm <= 1'b1; ch2_load_addr <= instr_addr; ch2_load_bytes <= instr_value; ch2_load_tog <= ~ch2_load_tog; active_valid <= 1'b1; end
                4'd3: if(!cur_ch3_have_play) begin cur_ch3_have_play <= 1'b1; ch3_arm <= 1'b1; ch3_load_addr <= instr_addr; ch3_load_bytes <= instr_value; ch3_load_tog <= ~ch3_load_tog; active_valid <= 1'b1; end
                4'd4: if(!cur_ch4_have_play) begin cur_ch4_have_play <= 1'b1; ch4_arm <= 1'b1; ch4_load_addr <= instr_addr; ch4_load_bytes <= instr_value; ch4_load_tog <= ~ch4_load_tog; active_valid <= 1'b1; end
                4'd5: if(!cur_ch5_have_play) begin cur_ch5_have_play <= 1'b1; ch5_arm <= 1'b1; ch5_load_addr <= instr_addr; ch5_load_bytes <= instr_value; ch5_load_tog <= ~ch5_load_tog; active_valid <= 1'b1; end
                4'd6: if(!cur_ch6_have_play) begin cur_ch6_have_play <= 1'b1; ch6_arm <= 1'b1; ch6_load_addr <= instr_addr; ch6_load_bytes <= instr_value; ch6_load_tog <= ~ch6_load_tog; active_valid <= 1'b1; end
                4'd7: if(!cur_ch7_have_play) begin cur_ch7_have_play <= 1'b1; ch7_arm <= 1'b1; ch7_load_addr <= instr_addr; ch7_load_bytes <= instr_value; ch7_load_tog <= ~ch7_load_tog; active_valid <= 1'b1; end
                4'd8: if(!cur_ch8_have_play) begin cur_ch8_have_play <= 1'b1; ch8_arm <= 1'b1; ch8_load_addr <= instr_addr; ch8_load_bytes <= instr_value; ch8_load_tog <= ~ch8_load_tog; active_valid <= 1'b1; end
                default: begin
                end
              endcase
            end else if(instr_cmd == CMD_END) begin
              if(cur_ch1_have_play || cur_ch2_have_play || cur_ch3_have_play || cur_ch4_have_play || cur_ch5_have_play || cur_ch6_have_play || cur_ch7_have_play || cur_ch8_have_play) begin
                st <= ST_PREFILL;
                pending_valid <= (instr_ch != CH_AUTO_START);
                prefill_auto_start <= (instr_ch == CH_AUTO_START);
                loop_enable <= instr_loop;
                cfg_auto_start <= 1'b0;
              end
            end
          end
        end
        ST_PREFILL: begin
          if(prefill_done) begin
            cfg_auto_start <= prefill_auto_start;
            if(prefill_auto_start) begin
              st <= ST_PLAYING;
              pending_valid <= 1'b0;
            end else begin
              st <= ST_WAITTRIG;
              pending_valid <= 1'b1;
            end
            prefill_auto_start <= 1'b0;
          end
        end
        ST_WAITTRIG: begin
          if(trig_pulse && pending_valid) begin
            st <= ST_PLAYING;
            pending_valid <= 1'b0;
          end
        end
        ST_PLAYING: begin
          if(loop_enable && prefill_done) begin
            if(INTERLEAVED_MODE != 0) begin
              inter_load_tog <= ~inter_load_tog;
            end
            if(cur_ch1_have_play) ch1_load_tog <= ~ch1_load_tog;
            if(cur_ch2_have_play) ch2_load_tog <= ~ch2_load_tog;
            if(cur_ch3_have_play) ch3_load_tog <= ~ch3_load_tog;
            if(cur_ch4_have_play) ch4_load_tog <= ~ch4_load_tog;
            if(cur_ch5_have_play) ch5_load_tog <= ~ch5_load_tog;
            if(cur_ch6_have_play) ch6_load_tog <= ~ch6_load_tog;
            if(cur_ch7_have_play) ch7_load_tog <= ~ch7_load_tog;
            if(cur_ch8_have_play) ch8_load_tog <= ~ch8_load_tog;
            st <= ST_PREFILL;
            prefill_auto_start <= 1'b1;
          end
        end
        default: st <= ST_BUILD;
      endcase
    end
  end

  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) begin
      cmd_st <= CMD_IDLE;
      m_axis_dm_cmd_tvalid <= 1'b0;
      m_axis_dm_cmd_tdata <= 104'd0;
      dma_req_sel_r <= 3'd0;
      dma_req_addr_r <= 64'd0;
      dma_req_abs_addr_r <= 64'd0;
      dma_req_chunk_beats_r <= 32'd0;
      dma_req_chunk_bytes_r <= 32'd0;
      inter_load_tog_d <= 1'b0;
      inter_base_addr <= 64'd0;
      inter_bytes_left <= 64'd0;
      inter_active_valid <= 1'b0;
      last_grant_sel <= 3'd0;
      same_grant_count <= 4'd0;
      total_burst_count <= 32'd0;
      retq_wr_ptr <= {RETQ_PTR_W{1'b0}};
      retq_rd_ptr <= {RETQ_PTR_W{1'b0}};
      retq_count <= 5'd0;
      for(bi = 0; bi < 8; bi = bi + 1) begin
        ch_burst_count[bi] <= 32'd0;
        ch_inflight_beats[bi] <= 32'd0;
      end
      for(bi = 0; bi < RETQ_DEPTH; bi = bi + 1) begin
        retq_sel[bi] <= 3'd0;
        retq_beats_left[bi] <= 32'd0;
      end
    end else if(clear || !prefetch_en) begin
      cmd_st <= CMD_IDLE;
      m_axis_dm_cmd_tvalid <= 1'b0;
      m_axis_dm_cmd_tdata <= 104'd0;
      dma_req_sel_r <= 3'd0;
      dma_req_addr_r <= 64'd0;
      dma_req_abs_addr_r <= 64'd0;
      dma_req_chunk_beats_r <= 32'd0;
      dma_req_chunk_bytes_r <= 32'd0;
      inter_load_tog_d <= inter_load_tog;
      inter_base_addr <= 64'd0;
      inter_bytes_left <= 64'd0;
      inter_active_valid <= 1'b0;
      last_grant_sel <= 3'd0;
      same_grant_count <= 4'd0;
      retq_wr_ptr <= {RETQ_PTR_W{1'b0}};
      retq_rd_ptr <= {RETQ_PTR_W{1'b0}};
      retq_count <= 5'd0;
      for(bi = 0; bi < 8; bi = bi + 1) ch_inflight_beats[bi] <= 32'd0;
      if(clear) begin
        total_burst_count <= 32'd0;
        for(bi = 0; bi < 8; bi = bi + 1) ch_burst_count[bi] <= 32'd0;
      end
    end else begin
      if((INTERLEAVED_MODE != 0) && (inter_load_tog_d != inter_load_tog)) begin
        inter_load_tog_d <= inter_load_tog;
        inter_base_addr <= inter_load_addr;
        inter_bytes_left <= inter_load_bytes;
        inter_active_valid <= (inter_load_bytes != 64'd0);
      end

      if(beat_fire && !retq_empty) begin
        if(retq_beats_left[retq_rd_ptr] == 32'd1) begin
          retq_rd_ptr <= retq_rd_ptr + {{(RETQ_PTR_W-1){1'b0}}, 1'b1};
        end else begin
          retq_beats_left[retq_rd_ptr] <= retq_beats_left[retq_rd_ptr] - 32'd1;
        end
      end

      if(retq_push) begin
        retq_sel[retq_wr_ptr] <= dma_req_sel_r;
        retq_beats_left[retq_wr_ptr] <= dma_req_chunk_beats_r;
        retq_wr_ptr <= retq_wr_ptr + {{(RETQ_PTR_W-1){1'b0}}, 1'b1};
      end

      if(retq_push && beat_fire && !retq_empty && inflight_same_channel) begin
        ch_inflight_beats[dma_req_sel_r] <= ch_inflight_beats[dma_req_sel_r] + dma_req_chunk_beats_r - 32'd1;
      end else begin
        if(beat_fire && !retq_empty) begin
          ch_inflight_beats[retq_stream_sel] <= ch_inflight_beats[retq_stream_sel] - 32'd1;
        end
        if(retq_push) begin
          ch_inflight_beats[dma_req_sel_r] <= ch_inflight_beats[dma_req_sel_r] + dma_req_chunk_beats_r;
        end
      end

      case({retq_push, retq_pop})
        2'b10: retq_count <= retq_count + 5'd1;
        2'b01: retq_count <= retq_count - 5'd1;
        default: retq_count <= retq_count;
      endcase

      case(cmd_st)
        CMD_IDLE: begin
          m_axis_dm_cmd_tvalid <= 1'b0;
          if(((INTERLEAVED_MODE != 0) ? inter_dma_req_valid : dma_req_valid) && !retq_full) begin
            dma_req_sel_r <= (INTERLEAVED_MODE != 0) ? 3'd0 : dma_req_sel;
            cmd_st <= CMD_STAGE;
          end
        end
        CMD_STAGE: begin
          if(INTERLEAVED_MODE != 0) begin
            dma_req_addr_r <= inter_base_addr;
            dma_req_abs_addr_r <= DDR_ADDR_BASE + inter_base_addr;
            dma_req_chunk_beats_r <= inter_chunk_beats_w;
            dma_req_chunk_bytes_r <= beats_to_bytes(inter_chunk_beats_w);
          end else begin
            case(dma_req_sel_r)
              3'd0: begin dma_req_addr_r <= ch1_base_addr; dma_req_abs_addr_r <= DDR_ADDR_BASE + ch1_base_addr; dma_req_chunk_beats_r <= ch1_chunk_beats_w; dma_req_chunk_bytes_r <= beats_to_bytes(ch1_chunk_beats_w); end
              3'd1: begin dma_req_addr_r <= ch2_base_addr; dma_req_abs_addr_r <= DDR_ADDR_BASE + ch2_base_addr; dma_req_chunk_beats_r <= ch2_chunk_beats_w; dma_req_chunk_bytes_r <= beats_to_bytes(ch2_chunk_beats_w); end
              3'd2: begin dma_req_addr_r <= ch3_base_addr; dma_req_abs_addr_r <= DDR_ADDR_BASE + ch3_base_addr; dma_req_chunk_beats_r <= ch3_chunk_beats_w; dma_req_chunk_bytes_r <= beats_to_bytes(ch3_chunk_beats_w); end
              3'd3: begin dma_req_addr_r <= ch4_base_addr; dma_req_abs_addr_r <= DDR_ADDR_BASE + ch4_base_addr; dma_req_chunk_beats_r <= ch4_chunk_beats_w; dma_req_chunk_bytes_r <= beats_to_bytes(ch4_chunk_beats_w); end
              3'd4: begin dma_req_addr_r <= ch5_base_addr; dma_req_abs_addr_r <= DDR_ADDR_BASE + ch5_base_addr; dma_req_chunk_beats_r <= ch5_chunk_beats_w; dma_req_chunk_bytes_r <= beats_to_bytes(ch5_chunk_beats_w); end
              3'd5: begin dma_req_addr_r <= ch6_base_addr; dma_req_abs_addr_r <= DDR_ADDR_BASE + ch6_base_addr; dma_req_chunk_beats_r <= ch6_chunk_beats_w; dma_req_chunk_bytes_r <= beats_to_bytes(ch6_chunk_beats_w); end
              3'd6: begin dma_req_addr_r <= ch7_base_addr; dma_req_abs_addr_r <= DDR_ADDR_BASE + ch7_base_addr; dma_req_chunk_beats_r <= ch7_chunk_beats_w; dma_req_chunk_bytes_r <= beats_to_bytes(ch7_chunk_beats_w); end
              default: begin dma_req_addr_r <= ch8_base_addr; dma_req_abs_addr_r <= DDR_ADDR_BASE + ch8_base_addr; dma_req_chunk_beats_r <= ch8_chunk_beats_w; dma_req_chunk_bytes_r <= beats_to_bytes(ch8_chunk_beats_w); end
            endcase
          end
          cmd_st <= CMD_PREP;
        end
        CMD_PREP: begin
          m_axis_dm_cmd_tdata <= make_dm_cmd(dma_req_abs_addr_r, dma_req_chunk_bytes_r);
          m_axis_dm_cmd_tvalid <= 1'b1;
          cmd_st <= CMD_SENDCMD;
        end
        CMD_SENDCMD: begin
          if(cmd_fire) begin
            m_axis_dm_cmd_tvalid <= 1'b0;
            total_burst_count <= total_burst_count + 32'd1;
            if(INTERLEAVED_MODE != 0) begin
              ch_burst_count[0] <= ch_burst_count[0] + 32'd1;
              ch_burst_count[1] <= ch_burst_count[1] + 32'd1;
              ch_burst_count[2] <= ch_burst_count[2] + 32'd1;
              ch_burst_count[3] <= ch_burst_count[3] + 32'd1;
              ch_burst_count[4] <= ch_burst_count[4] + 32'd1;
              ch_burst_count[5] <= ch_burst_count[5] + 32'd1;
              ch_burst_count[6] <= ch_burst_count[6] + 32'd1;
              ch_burst_count[7] <= ch_burst_count[7] + 32'd1;
              inter_base_addr <= inter_base_addr + {32'd0, dma_req_chunk_bytes_r};
              inter_bytes_left <= inter_bytes_left - {32'd0, dma_req_chunk_bytes_r};
              if(inter_bytes_left == {32'd0, dma_req_chunk_bytes_r}) inter_active_valid <= 1'b0;
            end else begin
              ch_burst_count[dma_req_sel_r] <= ch_burst_count[dma_req_sel_r] + 32'd1;
            end
            if(dma_req_sel_r == last_grant_sel) begin
              if(same_grant_count != 4'hf) same_grant_count <= same_grant_count + 4'd1;
            end else begin
              last_grant_sel <= dma_req_sel_r;
              same_grant_count <= 4'd1;
            end
            cmd_st <= CMD_IDLE;
          end
        end
        default: cmd_st <= CMD_IDLE;
      endcase
    end
  end

  wire _unused = &{1'b0, instr_loop, instr_value, s_axis_dm_data_tdata};

endmodule

module Waveform_Channel_State (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        prefetch_en,
    input  wire        load_tog,
    input  wire [63:0] load_addr,
    input  wire [31:0] load_bytes,
    input  wire        chunk_done,
    input  wire [31:0] chunk_bytes,
    output reg  [63:0] base_addr,
    output reg  [31:0] bytes_left,
    output reg         active_valid_dm
);
  reg load_tog_d;
  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) begin
      base_addr <= 64'd0;
      bytes_left <= 32'd0;
      active_valid_dm <= 1'b0;
      load_tog_d <= 1'b0;
    end else if(!prefetch_en) begin
      base_addr <= 64'd0;
      bytes_left <= 32'd0;
      active_valid_dm <= 1'b0;
      load_tog_d <= load_tog;
    end else begin
      if(load_tog_d != load_tog) begin
        load_tog_d <= load_tog;
        base_addr <= load_addr;
        bytes_left <= load_bytes;
        active_valid_dm <= (load_bytes != 0);
      end
      if(chunk_done) begin
        base_addr <= base_addr + chunk_bytes;
        bytes_left <= bytes_left - chunk_bytes;
        if(bytes_left == chunk_bytes) active_valid_dm <= 1'b0;
      end
    end
  end
endmodule

module Waveform_Dma_Selector (
    input  wire [15:0] high_wm,
    input  wire [2:0]  last_grant_sel,
    input  wire [3:0]  same_grant_count,
    input  wire [3:0]  max_consecutive_chunks,
    input  wire [2:0]  rr,
    input  wire        ch1_need_hard, input wire ch2_need_hard, input wire ch3_need_hard, input wire ch4_need_hard,
    input  wire        ch5_need_hard, input wire ch6_need_hard, input wire ch7_need_hard, input wire ch8_need_hard,
    input  wire        ch1_need_start, input wire ch2_need_start, input wire ch3_need_start, input wire ch4_need_start,
    input  wire        ch5_need_start, input wire ch6_need_start, input wire ch7_need_start, input wire ch8_need_start,
    input  wire        ch1_need_soft, input wire ch2_need_soft, input wire ch3_need_soft, input wire ch4_need_soft,
    input  wire        ch5_need_soft, input wire ch6_need_soft, input wire ch7_need_soft, input wire ch8_need_soft,
    input  wire [15:0] ch1_virtual_level, input wire [15:0] ch2_virtual_level, input wire [15:0] ch3_virtual_level, input wire [15:0] ch4_virtual_level,
    input  wire [15:0] ch5_virtual_level, input wire [15:0] ch6_virtual_level, input wire [15:0] ch7_virtual_level, input wire [15:0] ch8_virtual_level,
    output reg         req_valid,
    output reg  [2:0]  req_sel
);
  wire [7:0] need_hard = {
    ch8_need_hard,
    ch7_need_hard,
    ch6_need_hard,
    ch5_need_hard,
    ch4_need_hard,
    ch3_need_hard,
    ch2_need_hard,
    ch1_need_hard
  };
  wire [7:0] need_start = {
    ch8_need_start,
    ch7_need_start,
    ch6_need_start,
    ch5_need_start,
    ch4_need_start,
    ch3_need_start,
    ch2_need_start,
    ch1_need_start
  };
  wire [7:0] need_soft = {
    ch8_need_soft,
    ch7_need_soft,
    ch6_need_soft,
    ch5_need_soft,
    ch4_need_soft,
    ch3_need_soft,
    ch2_need_soft,
    ch1_need_soft
  };
  wire [7:0] need_any = {
    ch8_need_hard || ch8_need_start || ch8_need_soft,
    ch7_need_hard || ch7_need_start || ch7_need_soft,
    ch6_need_hard || ch6_need_start || ch6_need_soft,
    ch5_need_hard || ch5_need_start || ch5_need_soft,
    ch4_need_hard || ch4_need_start || ch4_need_soft,
    ch3_need_hard || ch3_need_start || ch3_need_soft,
    ch2_need_hard || ch2_need_start || ch2_need_soft,
    ch1_need_hard || ch1_need_start || ch1_need_soft
  };
  wire [7:0] last_grant_mask = 8'b0000_0001 << last_grant_sel;
  wire       other_need = |(need_any & ~last_grant_mask);

  reg [3:0] selected;
  reg [2:0] candidate;
  reg        candidate_need;
  integer sel_index;
  reg throttle_last;
  reg [7:0] eligible;

  task try_candidate;
    input [2:0] channel;
    input [7:0] class_need;
    begin
      candidate = channel;
      candidate_need = class_need[channel];
      if(candidate_need && !selected[3]) selected = {1'b1, channel};
    end
  endtask

  task try_class;
    input [7:0] class_need;
    begin
      for(sel_index = 0; sel_index < 8; sel_index = sel_index + 1) begin
        try_candidate(rr + sel_index[2:0], class_need);
      end
    end
  endtask

  always @* begin
    selected = 4'd0;
    candidate = 3'd0;
    candidate_need = 1'b0;
    throttle_last = (max_consecutive_chunks != 4'd0) &&
                    (same_grant_count >= max_consecutive_chunks) &&
                    other_need;
    eligible = throttle_last ? (8'hff & ~last_grant_mask) : 8'hff;

    try_class(need_hard & eligible);
    if(!selected[3]) try_class(need_start & eligible);
    if(!selected[3]) try_class(need_soft & eligible);
    if(!selected[3]) begin
      try_class(need_hard);
      if(!selected[3]) try_class(need_start);
      if(!selected[3]) try_class(need_soft);
    end

    req_valid = selected[3];
    req_sel = selected[2:0];
  end
endmodule
