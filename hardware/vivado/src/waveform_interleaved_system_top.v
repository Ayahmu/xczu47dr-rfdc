`timescale 1ns / 1ps

module Waveform_Interleaved_System_Top #(
  parameter integer DM_BEAT_BYTES = 64,
  parameter integer RFDC_BEAT_BYTES = 32,
  parameter integer CHUNK_DM_BEATS = 64,
  parameter integer LOW_WM = 512,
  parameter integer HIGH_WM = 1536,
  parameter integer START_WM = 1024,
  parameter integer OUTSTANDING_BEAT_LIMIT = 1024,
  parameter [63:0] DDR_ADDR_BASE = 64'd0
)(
    input  wire         aclk,
    input  wire         aresetn,
    input  wire         trigger,
    input  wire         abort_clear,

    input  wire [127:0] s_axis_instr_tdata,
    input  wire         s_axis_instr_tvalid,
    output wire         s_axis_instr_tready,

    output reg  [103:0] m_axis_dm_cmd_tdata,
    output reg          m_axis_dm_cmd_tvalid,
    input  wire         m_axis_dm_cmd_tready,

    input  wire [511:0] s_axis_dm_data_tdata,
    input  wire         s_axis_dm_data_tvalid,
    output wire         s_axis_dm_data_tready,

    input  wire         ch1_fifo_ready,
    input  wire         ch2_fifo_ready,
    input  wire         ch3_fifo_ready,
    input  wire         ch4_fifo_ready,
    input  wire         ch5_fifo_ready,
    input  wire         ch6_fifo_ready,
    input  wire         ch7_fifo_ready,
    input  wire         ch8_fifo_ready,

    input  wire [15:0]  ch1_fifo_level_beats,
    input  wire [15:0]  ch2_fifo_level_beats,
    input  wire [15:0]  ch3_fifo_level_beats,
    input  wire [15:0]  ch4_fifo_level_beats,
    input  wire [15:0]  ch5_fifo_level_beats,
    input  wire [15:0]  ch6_fifo_level_beats,
    input  wire [15:0]  ch7_fifo_level_beats,
    input  wire [15:0]  ch8_fifo_level_beats,

    output wire [255:0] m_axis_ch1_tdata,
    output wire         m_axis_ch1_tvalid,
    output wire [255:0] m_axis_ch2_tdata,
    output wire         m_axis_ch2_tvalid,
    output wire [255:0] m_axis_ch3_tdata,
    output wire         m_axis_ch3_tvalid,
    output wire [255:0] m_axis_ch4_tdata,
    output wire         m_axis_ch4_tvalid,
    output wire [255:0] m_axis_ch5_tdata,
    output wire         m_axis_ch5_tvalid,
    output wire [255:0] m_axis_ch6_tdata,
    output wire         m_axis_ch6_tvalid,
    output wire [255:0] m_axis_ch7_tdata,
    output wire         m_axis_ch7_tvalid,
    output wire [255:0] m_axis_ch8_tdata,
    output wire         m_axis_ch8_tvalid,

    output reg  [31:0]  ch1_delay_cycles,
    output reg  [31:0]  ch2_delay_cycles,
    output reg  [31:0]  ch3_delay_cycles,
    output reg  [31:0]  ch4_delay_cycles,
    output reg  [31:0]  ch5_delay_cycles,
    output reg  [31:0]  ch6_delay_cycles,
    output reg  [31:0]  ch7_delay_cycles,
    output reg  [31:0]  ch8_delay_cycles,
    output reg  [31:0]  ch1_len_beats,
    output reg  [31:0]  ch2_len_beats,
    output reg  [31:0]  ch3_len_beats,
    output reg  [31:0]  ch4_len_beats,
    output reg  [31:0]  ch5_len_beats,
    output reg  [31:0]  ch6_len_beats,
    output reg  [31:0]  ch7_len_beats,
    output reg  [31:0]  ch8_len_beats,
    output reg          ch1_arm,
    output reg          ch2_arm,
    output reg          ch3_arm,
    output reg          ch4_arm,
    output reg          ch5_arm,
    output reg          ch6_arm,
    output reg          ch7_arm,
    output reg          ch8_arm,
    output reg          cfg_auto_start,
    output reg          cfg_loop,
    output reg          cfg_commit,
    output reg          fifo_clear,

    output wire [2:0]   dbg_st,
    output wire [1:0]   dbg_dm_st,
    output wire         dbg_dm_sel_ch1,
    output wire [31:0]  dbg_dm_chunk_beats,
    output wire [31:0]  dbg_dm_beats_sent,
    output wire [63:0]  dbg_ch1_bytes_left,
    output wire [63:0]  dbg_ch2_bytes_left,
    output wire [63:0]  dbg_ch1_base_addr,
    output wire [63:0]  dbg_ch2_base_addr,
    output wire         dbg_ch1_need_hard,
    output wire         dbg_ch2_need_hard,
    output wire         dbg_ch1_need_soft,
    output wire         dbg_ch2_need_soft,

    output wire [127:0] dbg_instr_in_tdata,
    output wire         dbg_instr_in_tvalid,
    output wire         dbg_instr_in_tready,
    output wire [127:0] dbg_main_tdata,
    output wire         dbg_main_tvalid,
    output wire         dbg_main_tready,
    output wire         dbg_prefill_ready,
    output wire         dbg_pending_valid,
    output wire         dbg_active_valid,
    output wire [31:0]  dbg_run_delay_cnt,
    output reg  [31:0]  dbg_bad_instr_count
);

  localparam ST_BUILD    = 3'd0;
  localparam ST_PREFILL  = 3'd1;
  localparam ST_WAITTRIG = 3'd2;
  localparam ST_PLAYING  = 3'd3;

  localparam CMD_DELAY = 4'd1;
  localparam CMD_PLAY  = 4'd2;
  localparam CMD_END   = 4'd3;
  localparam CH_AUTO_START = 4'hF;
  localparam [31:0] CHUNK_DM_BEATS_U32 = CHUNK_DM_BEATS;
  localparam [31:0] CHUNK_BYTES_U32 = CHUNK_DM_BEATS * DM_BEAT_BYTES;

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
  wire [3:0]  instr_ch  = main_tdata[7:4];
  wire        instr_loop = main_tdata[8];
  wire        instr_tiled_layout = main_tdata[9];
  wire        instr_interleaved_layout = main_tdata[10];
  wire [31:0] instr_value = main_tdata[63:32];
  wire [63:0] instr_addr = main_tdata[127:64];
  wire        instr_play_aligned = (instr_value[4:0] == 5'd0) && (instr_addr[5:0] == 6'd0);

  reg [2:0]  st;
  reg        active_valid;
  reg        pending_valid;
  reg        prefill_auto_start;
  reg        loop_enable;
  reg [31:0] max_ch_bytes;
  reg [63:0] inter_total_bytes;
  reg [63:0] inter_bytes_left;
  reg [63:0] inter_base_addr;
  reg [63:0] inter_rd_addr;
  reg [31:0] dm_chunk_beats;
  reg [31:0] dm_beats_sent;
  reg [31:0] run_delay_cnt;
  reg [31:0] outstanding_beats;
  reg [31:0] prefill_beats_written;
  reg        cmd_prep_valid;
  reg [63:0] cmd_prep_addr;
  reg [31:0] cmd_prep_bytes;
  reg [31:0] cmd_prep_beats;
  reg [31:0] cmd_active_bytes;
  reg [31:0] cmd_active_beats;
  reg [63:0] dbg_ch1_bytes_left_r;
  reg [63:0] dbg_ch2_bytes_left_r;

  reg [255:0] pack_ch1;
  reg [255:0] pack_ch2;
  reg [255:0] pack_ch3;
  reg [255:0] pack_ch4;
  reg [255:0] pack_ch5;
  reg [255:0] pack_ch6;
  reg [255:0] pack_ch7;
  reg [255:0] pack_ch8;
  reg [1:0]   pack_phase;
  reg         pack_valid;

  function [31:0] min_u32;
    input [31:0] a;
    input [31:0] b;
    begin min_u32 = (a < b) ? a : b; end
  endfunction

  function [31:0] bytes_to_dm_beats;
    input [31:0] bytes;
    begin bytes_to_dm_beats = (bytes + (DM_BEAT_BYTES - 1)) / DM_BEAT_BYTES; end
  endfunction

  function [31:0] bytes_to_rfdc_beats;
    input [31:0] bytes;
    begin bytes_to_rfdc_beats = (bytes + (RFDC_BEAT_BYTES - 1)) / RFDC_BEAT_BYTES; end
  endfunction

  function [103:0] make_dm_cmd;
    input [63:0] abs_addr;
    input [31:0] bytes;
    begin
      make_dm_cmd = {8'h00, abs_addr, 1'b0, 1'b1, 6'h00, 1'b1, bytes[22:0]};
    end
  endfunction

  function [31:0] max_u32;
    input [31:0] a;
    input [31:0] b;
    begin max_u32 = (a > b) ? a : b; end
  endfunction

  wire any_arm = ch1_arm | ch2_arm | ch3_arm | ch4_arm | ch5_arm | ch6_arm | ch7_arm | ch8_arm;
  wire all_enabled_ready =
      (!ch1_arm || ch1_fifo_ready) &&
      (!ch2_arm || ch2_fifo_ready) &&
      (!ch3_arm || ch3_fifo_ready) &&
      (!ch4_arm || ch4_fifo_ready) &&
      (!ch5_arm || ch5_fifo_ready) &&
      (!ch6_arm || ch6_fifo_ready) &&
      (!ch7_arm || ch7_fifo_ready) &&
      (!ch8_arm || ch8_fifo_ready);

  wire any_enabled_low =
      (ch1_arm && (ch1_fifo_level_beats < LOW_WM[15:0])) ||
      (ch2_arm && (ch2_fifo_level_beats < LOW_WM[15:0])) ||
      (ch3_arm && (ch3_fifo_level_beats < LOW_WM[15:0])) ||
      (ch4_arm && (ch4_fifo_level_beats < LOW_WM[15:0])) ||
      (ch5_arm && (ch5_fifo_level_beats < LOW_WM[15:0])) ||
      (ch6_arm && (ch6_fifo_level_beats < LOW_WM[15:0])) ||
      (ch7_arm && (ch7_fifo_level_beats < LOW_WM[15:0])) ||
      (ch8_arm && (ch8_fifo_level_beats < LOW_WM[15:0]));

  wire any_enabled_not_high =
      (ch1_arm && (ch1_fifo_level_beats < HIGH_WM[15:0])) ||
      (ch2_arm && (ch2_fifo_level_beats < HIGH_WM[15:0])) ||
      (ch3_arm && (ch3_fifo_level_beats < HIGH_WM[15:0])) ||
      (ch4_arm && (ch4_fifo_level_beats < HIGH_WM[15:0])) ||
      (ch5_arm && (ch5_fifo_level_beats < HIGH_WM[15:0])) ||
      (ch6_arm && (ch6_fifo_level_beats < HIGH_WM[15:0])) ||
      (ch7_arm && (ch7_fifo_level_beats < HIGH_WM[15:0])) ||
      (ch8_arm && (ch8_fifo_level_beats < HIGH_WM[15:0]));

  wire packer_pending = pack_valid || (pack_phase != 2'd0);
  wire rearm_safe = !m_axis_dm_cmd_tvalid && !cmd_prep_valid && (outstanding_beats == 32'd0) && !packer_pending;
  wire rearm_frame = (st != ST_BUILD) && main_tvalid && rearm_safe;
  wire read_complete = (inter_bytes_left == 64'd0) && (outstanding_beats == 32'd0) && !packer_pending;
  wire [31:0] frame_beats_w = bytes_to_rfdc_beats(max_ch_bytes);
  wire [31:0] prefill_target_beats_w = min_u32(frame_beats_w, HIGH_WM[31:0]);
  wire prefill_target_reached =
      (prefill_target_beats_w == 32'd0) ||
      (prefill_beats_written >= prefill_target_beats_w);
  wire prefill_ready = pending_valid && (prefill_target_reached || read_complete) && !packer_pending;
  wire wave_done =
      (st == ST_PLAYING) && read_complete &&
      (!ch1_arm || (ch1_fifo_level_beats == 16'd0)) &&
      (!ch2_arm || (ch2_fifo_level_beats == 16'd0)) &&
      (!ch3_arm || (ch3_fifo_level_beats == 16'd0)) &&
      (!ch4_arm || (ch4_fifo_level_beats == 16'd0)) &&
      (!ch5_arm || (ch5_fifo_level_beats == 16'd0)) &&
      (!ch6_arm || (ch6_fifo_level_beats == 16'd0)) &&
      (!ch7_arm || (ch7_fifo_level_beats == 16'd0)) &&
      (!ch8_arm || (ch8_fifo_level_beats == 16'd0));

  wire prefill_want_read = (st == ST_PREFILL) && (inter_bytes_left != 64'd0) && !prefill_target_reached;
  wire playing_want_read = (st == ST_PLAYING) && (inter_bytes_left != 64'd0);
  wire want_read = prefill_want_read || playing_want_read;
  wire loop_refill_now = (st == ST_PLAYING) && loop_enable && read_complete && any_enabled_low && any_arm;
  wire [31:0] remaining_dm_beats_w = inter_bytes_left[37:6];
  wire [31:0] chunk_beats_w = (inter_bytes_left > {32'd0, CHUNK_BYTES_U32}) ? CHUNK_DM_BEATS_U32 : remaining_dm_beats_w;
  wire [31:0] chunk_bytes_w = {chunk_beats_w[25:0], 6'd0};
  wire can_prepare_cmd = want_read && !cmd_prep_valid && !m_axis_dm_cmd_tvalid &&
                         (chunk_beats_w != 32'd0) &&
                         ((outstanding_beats + chunk_beats_w) <= OUTSTANDING_BEAT_LIMIT[31:0]);
  wire cmd_fire = m_axis_dm_cmd_tvalid && m_axis_dm_cmd_tready;
  wire cmd_launch = cmd_prep_valid && !m_axis_dm_cmd_tvalid;
  wire beat_fire = s_axis_dm_data_tvalid && s_axis_dm_data_tready;

  assign s_axis_dm_data_tready = (outstanding_beats != 32'd0) && !pack_valid;

  assign m_axis_ch1_tdata = pack_ch1;
  assign m_axis_ch2_tdata = pack_ch2;
  assign m_axis_ch3_tdata = pack_ch3;
  assign m_axis_ch4_tdata = pack_ch4;
  assign m_axis_ch5_tdata = pack_ch5;
  assign m_axis_ch6_tdata = pack_ch6;
  assign m_axis_ch7_tdata = pack_ch7;
  assign m_axis_ch8_tdata = pack_ch8;
  wire pack_issue = pack_valid && all_enabled_ready;
  assign m_axis_ch1_tvalid = pack_issue && ch1_arm;
  assign m_axis_ch2_tvalid = pack_issue && ch2_arm;
  assign m_axis_ch3_tvalid = pack_issue && ch3_arm;
  assign m_axis_ch4_tvalid = pack_issue && ch4_arm;
  assign m_axis_ch5_tvalid = pack_issue && ch5_arm;
  assign m_axis_ch6_tvalid = pack_issue && ch6_arm;
  assign m_axis_ch7_tvalid = pack_issue && ch7_arm;
  assign m_axis_ch8_tvalid = pack_issue && ch8_arm;

  assign main_tready = (st == ST_BUILD);

  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) begin
      pack_ch1 <= 256'd0; pack_ch2 <= 256'd0; pack_ch3 <= 256'd0; pack_ch4 <= 256'd0;
      pack_ch5 <= 256'd0; pack_ch6 <= 256'd0; pack_ch7 <= 256'd0; pack_ch8 <= 256'd0;
      pack_phase <= 2'd0;
      pack_valid <= 1'b0;
    end else begin
      if(fifo_clear) begin
        pack_phase <= 2'd0;
        pack_valid <= 1'b0;
      end else if(pack_valid && all_enabled_ready) begin
        pack_valid <= 1'b0;
      end

      if(!fifo_clear && beat_fire) begin
        case(pack_phase)
          2'd0: begin
            pack_ch1[63:0] <= s_axis_dm_data_tdata[63:0];
            pack_ch2[63:0] <= s_axis_dm_data_tdata[127:64];
            pack_ch3[63:0] <= s_axis_dm_data_tdata[191:128];
            pack_ch4[63:0] <= s_axis_dm_data_tdata[255:192];
            pack_ch5[63:0] <= s_axis_dm_data_tdata[319:256];
            pack_ch6[63:0] <= s_axis_dm_data_tdata[383:320];
            pack_ch7[63:0] <= s_axis_dm_data_tdata[447:384];
            pack_ch8[63:0] <= s_axis_dm_data_tdata[511:448];
            pack_phase <= 2'd1;
          end
          2'd1: begin
            pack_ch1[127:64] <= s_axis_dm_data_tdata[63:0];
            pack_ch2[127:64] <= s_axis_dm_data_tdata[127:64];
            pack_ch3[127:64] <= s_axis_dm_data_tdata[191:128];
            pack_ch4[127:64] <= s_axis_dm_data_tdata[255:192];
            pack_ch5[127:64] <= s_axis_dm_data_tdata[319:256];
            pack_ch6[127:64] <= s_axis_dm_data_tdata[383:320];
            pack_ch7[127:64] <= s_axis_dm_data_tdata[447:384];
            pack_ch8[127:64] <= s_axis_dm_data_tdata[511:448];
            pack_phase <= 2'd2;
          end
          2'd2: begin
            pack_ch1[191:128] <= s_axis_dm_data_tdata[63:0];
            pack_ch2[191:128] <= s_axis_dm_data_tdata[127:64];
            pack_ch3[191:128] <= s_axis_dm_data_tdata[191:128];
            pack_ch4[191:128] <= s_axis_dm_data_tdata[255:192];
            pack_ch5[191:128] <= s_axis_dm_data_tdata[319:256];
            pack_ch6[191:128] <= s_axis_dm_data_tdata[383:320];
            pack_ch7[191:128] <= s_axis_dm_data_tdata[447:384];
            pack_ch8[191:128] <= s_axis_dm_data_tdata[511:448];
            pack_phase <= 2'd3;
          end
          default: begin
            pack_ch1[255:192] <= s_axis_dm_data_tdata[63:0];
            pack_ch2[255:192] <= s_axis_dm_data_tdata[127:64];
            pack_ch3[255:192] <= s_axis_dm_data_tdata[191:128];
            pack_ch4[255:192] <= s_axis_dm_data_tdata[255:192];
            pack_ch5[255:192] <= s_axis_dm_data_tdata[319:256];
            pack_ch6[255:192] <= s_axis_dm_data_tdata[383:320];
            pack_ch7[255:192] <= s_axis_dm_data_tdata[447:384];
            pack_ch8[255:192] <= s_axis_dm_data_tdata[511:448];
            pack_phase <= 2'd0;
            pack_valid <= 1'b1;
          end
        endcase
      end
    end
  end

  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) begin
      st <= ST_BUILD;
      active_valid <= 1'b0;
      pending_valid <= 1'b0;
      prefill_auto_start <= 1'b0;
      loop_enable <= 1'b0;
      max_ch_bytes <= 32'd0;
      inter_total_bytes <= 64'd0;
      inter_bytes_left <= 64'd0;
      inter_base_addr <= 64'd0;
      inter_rd_addr <= 64'd0;
      dm_chunk_beats <= 32'd0;
      dm_beats_sent <= 32'd0;
      run_delay_cnt <= 32'd0;
      outstanding_beats <= 32'd0;
      prefill_beats_written <= 32'd0;
      cmd_prep_valid <= 1'b0;
      cmd_prep_addr <= 64'd0;
      cmd_prep_bytes <= 32'd0;
      cmd_prep_beats <= 32'd0;
      cmd_active_bytes <= 32'd0;
      cmd_active_beats <= 32'd0;
      dbg_ch1_bytes_left_r <= 64'd0;
      dbg_ch2_bytes_left_r <= 64'd0;
	      m_axis_dm_cmd_tdata <= 104'd0;
	      m_axis_dm_cmd_tvalid <= 1'b0;
	      cfg_commit <= 1'b0;
	      fifo_clear <= 1'b0;
      cfg_auto_start <= 1'b0;
      cfg_loop <= 1'b0;
      ch1_delay_cycles <= 32'd0; ch2_delay_cycles <= 32'd0; ch3_delay_cycles <= 32'd0; ch4_delay_cycles <= 32'd0;
      ch5_delay_cycles <= 32'd0; ch6_delay_cycles <= 32'd0; ch7_delay_cycles <= 32'd0; ch8_delay_cycles <= 32'd0;
      ch1_len_beats <= 32'd0; ch2_len_beats <= 32'd0; ch3_len_beats <= 32'd0; ch4_len_beats <= 32'd0;
      ch5_len_beats <= 32'd0; ch6_len_beats <= 32'd0; ch7_len_beats <= 32'd0; ch8_len_beats <= 32'd0;
      ch1_arm <= 1'b0; ch2_arm <= 1'b0; ch3_arm <= 1'b0; ch4_arm <= 1'b0;
      ch5_arm <= 1'b0; ch6_arm <= 1'b0; ch7_arm <= 1'b0; ch8_arm <= 1'b0;
      dbg_bad_instr_count <= 32'd0;
	    end else begin
	      cfg_commit <= 1'b0;
	      fifo_clear <= 1'b0;
	      dbg_ch1_bytes_left_r <= inter_bytes_left;
	      dbg_ch2_bytes_left_r <= inter_total_bytes;

	      if(rearm_frame || abort_clear) begin
	        st <= ST_BUILD;
	        active_valid <= 1'b0;
	        pending_valid <= 1'b0;
	        prefill_auto_start <= 1'b0;
	        loop_enable <= 1'b0;
	        max_ch_bytes <= 32'd0;
	        inter_total_bytes <= 64'd0;
	        inter_bytes_left <= 64'd0;
	        inter_base_addr <= 64'd0;
	        inter_rd_addr <= 64'd0;
	        dm_chunk_beats <= 32'd0;
	        dm_beats_sent <= 32'd0;
	        run_delay_cnt <= 32'd0;
	        outstanding_beats <= 32'd0;
	        prefill_beats_written <= 32'd0;
	        cmd_prep_valid <= 1'b0;
	        cmd_prep_addr <= 64'd0;
	        cmd_prep_bytes <= 32'd0;
	        cmd_prep_beats <= 32'd0;
	        cmd_active_bytes <= 32'd0;
	        cmd_active_beats <= 32'd0;
	        m_axis_dm_cmd_tdata <= 104'd0;
	        m_axis_dm_cmd_tvalid <= 1'b0;
        cfg_auto_start <= 1'b0;
        cfg_loop <= 1'b0;
	        fifo_clear <= 1'b1;
	        ch1_delay_cycles <= 32'd0; ch2_delay_cycles <= 32'd0; ch3_delay_cycles <= 32'd0; ch4_delay_cycles <= 32'd0;
	        ch5_delay_cycles <= 32'd0; ch6_delay_cycles <= 32'd0; ch7_delay_cycles <= 32'd0; ch8_delay_cycles <= 32'd0;
	        ch1_len_beats <= 32'd0; ch2_len_beats <= 32'd0; ch3_len_beats <= 32'd0; ch4_len_beats <= 32'd0;
	        ch5_len_beats <= 32'd0; ch6_len_beats <= 32'd0; ch7_len_beats <= 32'd0; ch8_len_beats <= 32'd0;
	        ch1_arm <= 1'b0; ch2_arm <= 1'b0; ch3_arm <= 1'b0; ch4_arm <= 1'b0;
	        ch5_arm <= 1'b0; ch6_arm <= 1'b0; ch7_arm <= 1'b0; ch8_arm <= 1'b0;
	      end else begin
	      if(cmd_fire) begin
	        m_axis_dm_cmd_tvalid <= 1'b0;
	        inter_rd_addr <= inter_rd_addr + cmd_active_bytes;
	        inter_bytes_left <= inter_bytes_left - {32'd0, cmd_active_bytes};
        dm_chunk_beats <= cmd_active_beats;
      end else if(cmd_prep_valid) begin
        m_axis_dm_cmd_tdata <= make_dm_cmd(cmd_prep_addr, cmd_prep_bytes);
        m_axis_dm_cmd_tvalid <= 1'b1;
        cmd_active_bytes <= cmd_prep_bytes;
        cmd_active_beats <= cmd_prep_beats;
        cmd_prep_valid <= 1'b0;
      end

      if(can_prepare_cmd) begin
        cmd_prep_addr <= inter_rd_addr;
        cmd_prep_bytes <= chunk_bytes_w;
        cmd_prep_beats <= chunk_beats_w;
        cmd_prep_valid <= 1'b1;
      end

      case({cmd_launch, beat_fire})
        2'b10: outstanding_beats <= outstanding_beats + cmd_prep_beats;
        2'b01: outstanding_beats <= (outstanding_beats != 32'd0) ? (outstanding_beats - 32'd1) : 32'd0;
        2'b11: outstanding_beats <= outstanding_beats + cmd_prep_beats -
                              ((outstanding_beats != 32'd0) ? 32'd1 : 32'd0);
        default: outstanding_beats <= outstanding_beats;
      endcase
      if(beat_fire) begin
        dm_beats_sent <= dm_beats_sent + 32'd1;
      end
      if(pack_issue && (st == ST_PREFILL)) begin
        prefill_beats_written <= prefill_beats_written + 32'd1;
      end

      case(st)
        ST_BUILD: begin
          run_delay_cnt <= 32'd0;
          if(main_tvalid && main_tready) begin
            if(instr_cmd == CMD_DELAY) begin
              case(instr_ch)
                4'd1: ch1_delay_cycles <= instr_value;
                4'd2: ch2_delay_cycles <= instr_value;
                4'd3: ch3_delay_cycles <= instr_value;
                4'd4: ch4_delay_cycles <= instr_value;
                4'd5: ch5_delay_cycles <= instr_value;
                4'd6: ch6_delay_cycles <= instr_value;
                4'd7: ch7_delay_cycles <= instr_value;
                4'd8: ch8_delay_cycles <= instr_value;
                default: dbg_bad_instr_count <= dbg_bad_instr_count + 32'd1;
              endcase
            end else if(instr_cmd == CMD_PLAY) begin
              if(!instr_interleaved_layout || instr_tiled_layout || !instr_play_aligned || instr_ch < 4'd1 || instr_ch > 4'd8) begin
                dbg_bad_instr_count <= dbg_bad_instr_count + 32'd1;
              end else begin
                if(!active_valid) begin
                  inter_base_addr <= DDR_ADDR_BASE + instr_addr;
                end
                active_valid <= 1'b1;
                max_ch_bytes <= max_u32(max_ch_bytes, instr_value);
                case(instr_ch)
                  4'd1: begin ch1_len_beats <= bytes_to_rfdc_beats(instr_value); ch1_arm <= (instr_value != 32'd0); end
                  4'd2: begin ch2_len_beats <= bytes_to_rfdc_beats(instr_value); ch2_arm <= (instr_value != 32'd0); end
                  4'd3: begin ch3_len_beats <= bytes_to_rfdc_beats(instr_value); ch3_arm <= (instr_value != 32'd0); end
                  4'd4: begin ch4_len_beats <= bytes_to_rfdc_beats(instr_value); ch4_arm <= (instr_value != 32'd0); end
                  4'd5: begin ch5_len_beats <= bytes_to_rfdc_beats(instr_value); ch5_arm <= (instr_value != 32'd0); end
                  4'd6: begin ch6_len_beats <= bytes_to_rfdc_beats(instr_value); ch6_arm <= (instr_value != 32'd0); end
                  4'd7: begin ch7_len_beats <= bytes_to_rfdc_beats(instr_value); ch7_arm <= (instr_value != 32'd0); end
                  4'd8: begin ch8_len_beats <= bytes_to_rfdc_beats(instr_value); ch8_arm <= (instr_value != 32'd0); end
                  default: dbg_bad_instr_count <= dbg_bad_instr_count + 32'd1;
                endcase
              end
            end else if(instr_cmd == CMD_END) begin
              prefill_auto_start <= (instr_ch == CH_AUTO_START);
              cfg_auto_start <= (instr_ch == CH_AUTO_START);
              cfg_loop <= instr_loop;
              loop_enable <= instr_loop;
              pending_valid <= active_valid;
              inter_total_bytes <= {29'd0, max_ch_bytes, 3'd0};
              inter_bytes_left <= {29'd0, max_ch_bytes, 3'd0};
              inter_rd_addr <= inter_base_addr;
              prefill_beats_written <= 32'd0;
              if(active_valid && any_arm && (max_ch_bytes != 32'd0)) begin
                st <= ST_PREFILL;
              end else begin
                cfg_commit <= 1'b1;
                st <= ST_WAITTRIG;
              end
            end else begin
              dbg_bad_instr_count <= dbg_bad_instr_count + 32'd1;
            end
          end
        end

        ST_PREFILL: begin
          if(prefill_ready) begin
            cfg_commit <= 1'b1;
            st <= prefill_auto_start ? ST_PLAYING : ST_WAITTRIG;
          end
        end

        ST_WAITTRIG: begin
          if(prefill_auto_start || trig_pulse) begin
            st <= ST_PLAYING;
          end
        end

        ST_PLAYING: begin
          run_delay_cnt <= run_delay_cnt + 32'd1;
          if(loop_refill_now) begin
            inter_bytes_left <= inter_total_bytes;
            inter_rd_addr <= inter_base_addr;
          end
          if(wave_done) begin
            if(loop_enable) begin
              inter_bytes_left <= inter_total_bytes;
              inter_rd_addr <= inter_base_addr;
              prefill_beats_written <= 32'd0;
              // Seamless loop: after the first RFCTRL2 Trigger, every refill
              // auto-commits into PLAYING. Host-side Trigger is not repeated.
              prefill_auto_start <= 1'b1;
              st <= ST_PREFILL;
            end else begin
              st <= ST_BUILD;
              active_valid <= 1'b0;
              pending_valid <= 1'b0;
              prefill_auto_start <= 1'b0;
              loop_enable <= 1'b0;
              cfg_loop <= 1'b0;
              max_ch_bytes <= 32'd0;
              inter_total_bytes <= 64'd0;
              inter_bytes_left <= 64'd0;
              ch1_arm <= 1'b0; ch2_arm <= 1'b0; ch3_arm <= 1'b0; ch4_arm <= 1'b0;
              ch5_arm <= 1'b0; ch6_arm <= 1'b0; ch7_arm <= 1'b0; ch8_arm <= 1'b0;
            end
          end
        end

	        default: begin
	          st <= ST_BUILD;
	        end
	      endcase
	      end
	    end
	  end

  assign dbg_st = st;
  assign dbg_dm_st = m_axis_dm_cmd_tvalid ? 2'd3 : ((cmd_prep_valid || want_read) ? 2'd2 : 2'd0);
  assign dbg_dm_sel_ch1 = 1'b1;
  assign dbg_dm_chunk_beats = dm_chunk_beats;
  assign dbg_dm_beats_sent = dm_beats_sent;
  assign dbg_ch1_bytes_left = dbg_ch1_bytes_left_r;
  assign dbg_ch2_bytes_left = dbg_ch2_bytes_left_r;
  assign dbg_ch1_base_addr = inter_base_addr;
  assign dbg_ch2_base_addr = inter_rd_addr;
  assign dbg_ch1_need_hard = any_enabled_low;
  assign dbg_ch2_need_hard = any_enabled_low;
  assign dbg_ch1_need_soft = any_enabled_not_high;
  assign dbg_ch2_need_soft = any_enabled_not_high;
  assign dbg_instr_in_tdata = s_axis_instr_tdata;
  assign dbg_instr_in_tvalid = s_axis_instr_tvalid;
  assign dbg_instr_in_tready = s_axis_instr_tready;
  assign dbg_main_tdata = main_tdata;
  assign dbg_main_tvalid = main_tvalid;
  assign dbg_main_tready = main_tready;
  assign dbg_prefill_ready = prefill_ready;
  assign dbg_pending_valid = pending_valid;
  assign dbg_active_valid = active_valid;
  assign dbg_run_delay_cnt = run_delay_cnt;

endmodule
