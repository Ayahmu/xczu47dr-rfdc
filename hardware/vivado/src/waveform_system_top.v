module Waveform_System_Top #(
  parameter integer BEAT_BYTES   = 16,
  parameter integer CHUNK_BEATS  = 256,
  parameter integer LOW_WM       = 128,
  parameter integer HIGH_WM      = 512,
  parameter integer START_WM     = 256,
  parameter [63:0] DDR_ADDR_BASE = 64'd0
)(
    input  wire         aclk,
    input  wire         aresetn,
    input  wire         trigger,

    input  wire [127:0] s_axis_instr_tdata,
    input  wire         s_axis_instr_tvalid,
    output wire         s_axis_instr_tready,

    output reg  [103:0] m_axis_dm_cmd_tdata,
    output reg          m_axis_dm_cmd_tvalid,
    input  wire         m_axis_dm_cmd_tready,

    input  wire [127:0] s_axis_dm_data_tdata,
    input  wire         s_axis_dm_data_tvalid,
    output wire         s_axis_dm_data_tready,

    input  wire         ch1_fifo_ready,
    input  wire         ch2_fifo_ready,
    input  wire         ch3_fifo_ready,
    input  wire         ch4_fifo_ready,

    input  wire [15:0]  ch1_fifo_level_beats,
    input  wire [15:0]  ch2_fifo_level_beats,
    input  wire [15:0]  ch3_fifo_level_beats,
    input  wire [15:0]  ch4_fifo_level_beats,

    output wire [127:0] m_axis_ch1_tdata,
    output wire         m_axis_ch1_tvalid,
    output wire [127:0] m_axis_ch2_tdata,
    output wire         m_axis_ch2_tvalid,
    output wire [127:0] m_axis_ch3_tdata,
    output wire         m_axis_ch3_tvalid,
    output wire [127:0] m_axis_ch4_tdata,
    output wire         m_axis_ch4_tvalid,

    output reg  [31:0]  ch1_delay_cycles,
    output reg  [31:0]  ch2_delay_cycles,
    output reg  [31:0]  ch3_delay_cycles,
    output reg  [31:0]  ch4_delay_cycles,
    output reg  [31:0]  ch1_len_beats,
    output reg  [31:0]  ch2_len_beats,
    output reg  [31:0]  ch3_len_beats,
    output reg  [31:0]  ch4_len_beats,
    output reg          ch1_arm,        // 本波通道是否有效（PLAY过）；供 DAC 域门控使用
    output reg          ch2_arm,
    output reg          ch3_arm,
    output reg          ch4_arm,
    output reg          cfg_auto_start, // END ch=15：无需 GPIO trigger，DAC 域收到配置后直接放行
    output reg          cfg_commit,     // END 时 pulse（提交一帧配置到 DAC 域）

    // ===== debug ports =====
    output wire [2:0]   dbg_st,
    output wire [1:0]   dbg_dm_st,
    output wire         dbg_dm_sel_ch1,
    output wire [31:0]  dbg_dm_chunk_beats,
    output wire [31:0]  dbg_dm_beats_sent,
    output wire [31:0]  dbg_ch1_bytes_left,
    output wire [31:0]  dbg_ch2_bytes_left,
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
    output wire         dbg_pending_valid,
    output wire         dbg_active_valid,
    output wire [31:0]  dbg_run_delay_cnt
);

  // =========================================================
  // 0) 指令入口 FIFO（弹性）
  // =========================================================
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

  // =========================================================
  // 1) trigger 上升沿脉冲
  // =========================================================
  reg trig_d;
  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) trig_d <= 1'b0;
    else         trig_d <= trigger;
  end
  wire trig_pulse = trigger & ~trig_d;

  // =========================================================
  // 2) 状态机
  // =========================================================
  localparam ST_BUILD    = 3'd0; // 接收指令；PLAY 到就启动预取
  localparam ST_PREFILL  = 3'd1; // END 后暂停取指令，等待本帧 DDR 数据全部进入 FIFO
  localparam ST_WAITTRIG = 3'd2; // 预填完成后等待 trigger
  localparam ST_PLAYING  = 3'd3; // trigger 到，DAC 在放行读；等待 FIFO 读空

  (* MARK_DEBUG="TRUE" *) reg [2:0] st;

  // 当前波配置（在 BUILD 时由指令更新，END 后冻结直到波结束）
  reg [31:0] cur_ch1_delay, cur_ch2_delay, cur_ch3_delay, cur_ch4_delay;
  reg        cur_ch1_have_play, cur_ch2_have_play, cur_ch3_have_play, cur_ch4_have_play;

  // 仅用于 ILA 观察
  reg [127:0] inst_dbg;
  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) inst_dbg <= 128'd0;
    else if(main_tvalid && main_tready) inst_dbg <= main_tdata;
  end

  // END 后置 1（debug 用）
  reg pending_valid;
  reg prefill_auto_start;
  reg loop_enable;

  // active_valid：一旦任一路 PLAY 到来就置 1，直到波结束清掉
  reg active_valid;

  // 观测用（你 Top ILA 已在抓）
  reg [31:0] run_delay_cnt;
  reg        cfg_commit_pending;

  // 允许从 main_fifo 取指令：只有 BUILD 才取；END 后暂停取指令
  assign main_tready = (st == ST_BUILD);

  // =========================================================
  // 3) 给 DMA 的“PLAY load 请求”（toggle 方式，保证 DMA 单写者）
  // =========================================================
  reg        ch1_load_tog, ch2_load_tog, ch3_load_tog, ch4_load_tog;
  reg [63:0] ch1_load_addr, ch2_load_addr, ch3_load_addr, ch4_load_addr;
  reg [31:0] ch1_load_bytes, ch2_load_bytes, ch3_load_bytes, ch4_load_bytes;

  // =========================================================
  // 4) DMA 调度器（单 DataMover，分块搬运）
  // =========================================================
  (* MARK_DEBUG="TRUE" *) reg [1:0]  dm_sel;
  wire dm_sel_ch1 = (dm_sel == 2'd0);
  (* MARK_DEBUG="TRUE" *) reg [31:0] dm_chunk_beats;
  (* MARK_DEBUG="TRUE" *) reg [31:0] dm_beats_sent;

  localparam DM_IDLE    = 2'd0;
  localparam DM_SENDCMD = 2'd1;
  localparam DM_STREAM  = 2'd2;

  (* MARK_DEBUG="TRUE" *) reg [1:0] dm_st;

  (* MARK_DEBUG="TRUE" *) reg [63:0] ch1_base_addr, ch2_base_addr, ch3_base_addr, ch4_base_addr;
  (* MARK_DEBUG="TRUE" *) reg [31:0] ch1_bytes_left, ch2_bytes_left, ch3_bytes_left, ch4_bytes_left;

  reg act_ch1_valid_dm, act_ch2_valid_dm, act_ch3_valid_dm, act_ch4_valid_dm;
  reg ch1_load_tog_d, ch2_load_tog_d, ch3_load_tog_d, ch4_load_tog_d;

  wire prefill_done = active_valid && (dm_st == DM_IDLE) &&
                      (!cur_ch1_have_play || (ch1_bytes_left == 0)) &&
                      (!cur_ch2_have_play || (ch2_bytes_left == 0)) &&
                      (!cur_ch3_have_play || (ch3_bytes_left == 0)) &&
                      (!cur_ch4_have_play || (ch4_bytes_left == 0));

  // Data routing（写 FIFO）
  assign m_axis_ch1_tdata  = s_axis_dm_data_tdata;
  assign m_axis_ch2_tdata  = s_axis_dm_data_tdata;
  assign m_axis_ch3_tdata  = s_axis_dm_data_tdata;
  assign m_axis_ch4_tdata  = s_axis_dm_data_tdata;

  assign m_axis_ch1_tvalid = s_axis_dm_data_tvalid && (dm_sel == 2'd0);
  assign m_axis_ch2_tvalid = s_axis_dm_data_tvalid && (dm_sel == 2'd1);
  assign m_axis_ch3_tvalid = s_axis_dm_data_tvalid && (dm_sel == 2'd2);
  assign m_axis_ch4_tvalid = s_axis_dm_data_tvalid && (dm_sel == 2'd3);

  assign s_axis_dm_data_tready = (dm_sel == 2'd0) ? ch1_fifo_ready :
                                 (dm_sel == 2'd1) ? ch2_fifo_ready :
                                 (dm_sel == 2'd2) ? ch3_fifo_ready : ch4_fifo_ready;
  wire beat_fire = s_axis_dm_data_tvalid && s_axis_dm_data_tready;

  // 预取使能：只要 active_valid=1 就允许预取（即 PLAY 到就能预取）
  wire prefetch_en = active_valid;

  // need：水位策略（避免溢出）
  wire ch1_need_hard  = (prefetch_en && act_ch1_valid_dm && (ch1_bytes_left != 0) && (ch1_fifo_level_beats < LOW_WM));
  wire ch2_need_hard  = (prefetch_en && act_ch2_valid_dm && (ch2_bytes_left != 0) && (ch2_fifo_level_beats < LOW_WM));
  wire ch3_need_hard  = (prefetch_en && act_ch3_valid_dm && (ch3_bytes_left != 0) && (ch3_fifo_level_beats < LOW_WM));
  wire ch4_need_hard  = (prefetch_en && act_ch4_valid_dm && (ch4_bytes_left != 0) && (ch4_fifo_level_beats < LOW_WM));

  wire ch1_need_soft  = (prefetch_en && act_ch1_valid_dm && (ch1_bytes_left != 0) && (ch1_fifo_level_beats < HIGH_WM));
  wire ch2_need_soft  = (prefetch_en && act_ch2_valid_dm && (ch2_bytes_left != 0) && (ch2_fifo_level_beats < HIGH_WM));
  wire ch3_need_soft  = (prefetch_en && act_ch3_valid_dm && (ch3_bytes_left != 0) && (ch3_fifo_level_beats < HIGH_WM));
  wire ch4_need_soft  = (prefetch_en && act_ch4_valid_dm && (ch4_bytes_left != 0) && (ch4_fifo_level_beats < HIGH_WM));

  wire ch1_need_start = (prefetch_en && act_ch1_valid_dm && (ch1_bytes_left != 0) && (ch1_fifo_level_beats < START_WM));
  wire ch2_need_start = (prefetch_en && act_ch2_valid_dm && (ch2_bytes_left != 0) && (ch2_fifo_level_beats < START_WM));
  wire ch3_need_start = (prefetch_en && act_ch3_valid_dm && (ch3_bytes_left != 0) && (ch3_fifo_level_beats < START_WM));
  wire ch4_need_start = (prefetch_en && act_ch4_valid_dm && (ch4_bytes_left != 0) && (ch4_fifo_level_beats < START_WM));

  // round-robin
  reg [1:0] rr;
  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) rr <= 2'd0;
    else if(dm_st == DM_IDLE) rr <= rr + 2'd1;
  end

  function [31:0] min_u32;
    input [31:0] a,b;
    begin min_u32 = (a < b) ? a : b; end
  endfunction

  function [31:0] bytes_to_beats;
    input [31:0] bytes;
    begin bytes_to_beats = bytes >> 4; end
  endfunction

  function [103:0] make_dm_cmd;
    input [63:0] addr;
    input [31:0] bytes;
    begin
      make_dm_cmd = {8'h00, DDR_ADDR_BASE + addr, 1'b0, 1'b1, 6'h00, 1'b1, bytes[22:0]};
    end
  endfunction

  wire [31:0] ch1_chunk_beats_w = min_u32(bytes_to_beats(ch1_bytes_left), CHUNK_BEATS);
  wire [31:0] ch2_chunk_beats_w = min_u32(bytes_to_beats(ch2_bytes_left), CHUNK_BEATS);
  wire [31:0] ch3_chunk_beats_w = min_u32(bytes_to_beats(ch3_bytes_left), CHUNK_BEATS);
  wire [31:0] ch4_chunk_beats_w = min_u32(bytes_to_beats(ch4_bytes_left), CHUNK_BEATS);
  wire [31:0] ch1_chunk_bytes_w = ch1_chunk_beats_w << 4;
  wire [31:0] ch2_chunk_bytes_w = ch2_chunk_beats_w << 4;
  wire [31:0] ch3_chunk_bytes_w = ch3_chunk_beats_w << 4;
  wire [31:0] ch4_chunk_bytes_w = ch4_chunk_beats_w << 4;

  function channel_need;
    input [1:0] channel;
    input hard;
    input start;
    begin
      case(channel)
        2'd0: channel_need = hard ? ch1_need_hard : (start ? ch1_need_start : ch1_need_soft);
        2'd1: channel_need = hard ? ch2_need_hard : (start ? ch2_need_start : ch2_need_soft);
        2'd2: channel_need = hard ? ch3_need_hard : (start ? ch3_need_start : ch3_need_soft);
        2'd3: channel_need = hard ? ch4_need_hard : (start ? ch4_need_start : ch4_need_soft);
      endcase
    end
  endfunction

  function [1:0] rr_add;
    input [1:0] base;
    input [1:0] offset;
    begin rr_add = base + offset; end
  endfunction

  reg [1:0] sel_next;
  reg [1:0] sel_candidate;
  always @* begin
    sel_next = dm_sel;
    sel_candidate = rr_add(rr, 2'd3);
    if(channel_need(sel_candidate, 1'b1, 1'b0)) sel_next = sel_candidate;
    sel_candidate = rr_add(rr, 2'd2);
    if(channel_need(sel_candidate, 1'b1, 1'b0)) sel_next = sel_candidate;
    sel_candidate = rr_add(rr, 2'd1);
    if(channel_need(sel_candidate, 1'b1, 1'b0)) sel_next = sel_candidate;
    sel_candidate = rr_add(rr, 2'd0);
    if(channel_need(sel_candidate, 1'b1, 1'b0)) sel_next = sel_candidate;

    if(!channel_need(sel_next, 1'b1, 1'b0)) begin
      sel_candidate = rr_add(rr, 2'd3);
      if(channel_need(sel_candidate, 1'b0, 1'b1)) sel_next = sel_candidate;
      sel_candidate = rr_add(rr, 2'd2);
      if(channel_need(sel_candidate, 1'b0, 1'b1)) sel_next = sel_candidate;
      sel_candidate = rr_add(rr, 2'd1);
      if(channel_need(sel_candidate, 1'b0, 1'b1)) sel_next = sel_candidate;
      sel_candidate = rr_add(rr, 2'd0);
      if(channel_need(sel_candidate, 1'b0, 1'b1)) sel_next = sel_candidate;
    end

    if(!channel_need(sel_next, 1'b1, 1'b0) && !channel_need(sel_next, 1'b0, 1'b1)) begin
      sel_candidate = rr_add(rr, 2'd3);
      if(channel_need(sel_candidate, 1'b0, 1'b0)) sel_next = sel_candidate;
      sel_candidate = rr_add(rr, 2'd2);
      if(channel_need(sel_candidate, 1'b0, 1'b0)) sel_next = sel_candidate;
      sel_candidate = rr_add(rr, 2'd1);
      if(channel_need(sel_candidate, 1'b0, 1'b0)) sel_next = sel_candidate;
      sel_candidate = rr_add(rr, 2'd0);
      if(channel_need(sel_candidate, 1'b0, 1'b0)) sel_next = sel_candidate;
    end
  end

  // =========================================================
  // 5) wave_done：只在 PLAYING 状态判断结束
  // =========================================================
  wire ch1_done = (!act_ch1_valid_dm) || ((ch1_bytes_left == 0) && (ch1_fifo_level_beats == 0));
  wire ch2_done = (!act_ch2_valid_dm) || ((ch2_bytes_left == 0) && (ch2_fifo_level_beats == 0));
  wire ch3_done = (!act_ch3_valid_dm) || ((ch3_bytes_left == 0) && (ch3_fifo_level_beats == 0));
  wire ch4_done = (!act_ch4_valid_dm) || ((ch4_bytes_left == 0) && (ch4_fifo_level_beats == 0));
  wire wave_done = (st == ST_PLAYING) && ch1_done && ch2_done && ch3_done && ch4_done;

  // =========================================================
  // 6) 控制器：解析指令 + END 锁住 + trigger 切换 + done 复位
  // =========================================================
  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) begin
      st <= ST_BUILD;
      pending_valid <= 1'b0;
      prefill_auto_start <= 1'b0;
      loop_enable <= 1'b0;
      active_valid  <= 1'b0;
      run_delay_cnt <= 32'd0;

      cur_ch1_delay <= 0; cur_ch2_delay <= 0; cur_ch3_delay <= 0; cur_ch4_delay <= 0;
      cur_ch1_have_play <= 1'b0;
      cur_ch2_have_play <= 1'b0;
      cur_ch3_have_play <= 1'b0;
      cur_ch4_have_play <= 1'b0;

      ch1_delay_cycles <= 0; ch2_delay_cycles <= 0; ch3_delay_cycles <= 0; ch4_delay_cycles <= 0;
      ch1_len_beats    <= 0; ch2_len_beats    <= 0; ch3_len_beats <= 0; ch4_len_beats <= 0;
      ch1_arm          <= 1'b0;
      ch2_arm          <= 1'b0;
      ch3_arm          <= 1'b0;
      ch4_arm          <= 1'b0;
      cfg_auto_start   <= 1'b0;
      cfg_commit       <= 1'b0;
      cfg_commit_pending <= 1'b0;

      ch1_load_tog <= 1'b0; ch2_load_tog <= 1'b0; ch3_load_tog <= 1'b0; ch4_load_tog <= 1'b0;
      ch1_load_addr <= 64'd0; ch2_load_addr <= 64'd0; ch3_load_addr <= 64'd0; ch4_load_addr <= 64'd0;
      ch1_load_bytes<= 32'd0; ch2_load_bytes<= 32'd0; ch3_load_bytes <= 32'd0; ch4_load_bytes <= 32'd0;
    end else begin
      cfg_commit <= cfg_commit_pending;
      cfg_commit_pending <= 1'b0;

      // 播放完成：清空并回到 BUILD
      if(wave_done) begin
        if(loop_enable) begin
          st <= ST_PREFILL;
          pending_valid <= 1'b0;
          prefill_auto_start <= 1'b1;
          active_valid  <= 1'b1;
          run_delay_cnt <= 32'd0;

          if(cur_ch1_have_play) ch1_load_tog <= ~ch1_load_tog;
          if(cur_ch2_have_play) ch2_load_tog <= ~ch2_load_tog;
          if(cur_ch3_have_play) ch3_load_tog <= ~ch3_load_tog;
          if(cur_ch4_have_play) ch4_load_tog <= ~ch4_load_tog;
        end else begin
          st <= ST_BUILD;
          pending_valid <= 1'b0;
          prefill_auto_start <= 1'b0;
          loop_enable <= 1'b0;
          active_valid  <= 1'b0;
          run_delay_cnt <= 32'd0;

          cur_ch1_delay <= 0; cur_ch2_delay <= 0; cur_ch3_delay <= 0; cur_ch4_delay <= 0;
          cur_ch1_have_play <= 1'b0;
          cur_ch2_have_play <= 1'b0;
          cur_ch3_have_play <= 1'b0;
          cur_ch4_have_play <= 1'b0;

          ch1_arm <= 1'b0;
          ch2_arm <= 1'b0;
          ch3_arm <= 1'b0;
          ch4_arm <= 1'b0;
          cfg_auto_start <= 1'b0;
        end
      end

      case(st)
        ST_BUILD: begin
          // 来指令就处理；PLAY 立刻启动预取
          if(main_tvalid && main_tready) begin
            // IDLE
            if(main_tdata[3:0] == 4'd1) begin
              if(main_tdata[7:4] == 4'd1) cur_ch1_delay <= main_tdata[63:32];
              if(main_tdata[7:4] == 4'd2) cur_ch2_delay <= main_tdata[63:32];
              if(main_tdata[7:4] == 4'd3) cur_ch3_delay <= main_tdata[63:32];
              if(main_tdata[7:4] == 4'd4) cur_ch4_delay <= main_tdata[63:32];

            end
            // PLAY
            else if(main_tdata[3:0] == 4'd2) begin
              if(main_tdata[7:4] == 4'd1) begin
                // 只允许本波第一次 PLAY 配置 ch1（避免覆盖已预取的数据）
                if(!cur_ch1_have_play) begin
                  cur_ch1_have_play <= 1'b1;
                  ch1_len_beats <= (main_tdata[63:32] >> 4);

                  // 发 load 请求给 DMA（toggle + payload）
                  ch1_load_addr  <= main_tdata[127:64];
                  ch1_load_bytes <= main_tdata[63:32];
                  ch1_load_tog   <= ~ch1_load_tog;

                  // 有 PLAY 就 active_valid=1（允许预取）
                  active_valid <= 1'b1;
                end
              end
              if(main_tdata[7:4] == 4'd2) begin
                if(!cur_ch2_have_play) begin
                  cur_ch2_have_play <= 1'b1;
                  ch2_len_beats <= (main_tdata[63:32] >> 4);

                  ch2_load_addr  <= main_tdata[127:64];
                  ch2_load_bytes <= main_tdata[63:32];
                  ch2_load_tog   <= ~ch2_load_tog;

                  active_valid <= 1'b1;
                end
              end
              if(main_tdata[7:4] == 4'd3) begin
                if(!cur_ch3_have_play) begin
                  cur_ch3_have_play <= 1'b1;
                  ch3_len_beats <= (main_tdata[63:32] >> 4);

                  ch3_load_addr  <= main_tdata[127:64];
                  ch3_load_bytes <= main_tdata[63:32];
                  ch3_load_tog   <= ~ch3_load_tog;

                  active_valid <= 1'b1;
                end
              end
              if(main_tdata[7:4] == 4'd4) begin
                if(!cur_ch4_have_play) begin
                  cur_ch4_have_play <= 1'b1;
                  ch4_len_beats <= (main_tdata[63:32] >> 4);

                  ch4_load_addr  <= main_tdata[127:64];
                  ch4_load_bytes <= main_tdata[63:32];
                  ch4_load_tog   <= ~ch4_load_tog;

                  active_valid <= 1'b1;
                end
              end
            end
            // END
            else if(main_tdata[3:0] == 4'd3) begin
              // 如果本波没有任何 PLAY，则忽略（不进入等待触发）
              if(cur_ch1_have_play || cur_ch2_have_play || cur_ch3_have_play || cur_ch4_have_play) begin
                st <= ST_PREFILL;
                pending_valid <= (main_tdata[7:4] != 4'hF);
                prefill_auto_start <= (main_tdata[7:4] == 4'hF);
                loop_enable <= main_tdata[8];
                cfg_auto_start <= 1'b0;

                // END 时冻结最终 delay/arm，等预填完成后再写 DAC cfg FIFO
                ch1_delay_cycles <= cur_ch1_delay;
                ch2_delay_cycles <= cur_ch2_delay;
                ch3_delay_cycles <= cur_ch3_delay;
                ch4_delay_cycles <= cur_ch4_delay;

                ch1_arm <= cur_ch1_have_play;
                ch2_arm <= cur_ch2_have_play;
                ch3_arm <= cur_ch3_have_play;
                ch4_arm <= cur_ch4_have_play;

                run_delay_cnt <= (cur_ch1_delay > cur_ch2_delay) ?
                                 ((cur_ch1_delay > cur_ch3_delay) ? ((cur_ch1_delay > cur_ch4_delay) ? cur_ch1_delay : cur_ch4_delay) : ((cur_ch3_delay > cur_ch4_delay) ? cur_ch3_delay : cur_ch4_delay)) :
                                 ((cur_ch2_delay > cur_ch3_delay) ? ((cur_ch2_delay > cur_ch4_delay) ? cur_ch2_delay : cur_ch4_delay) : ((cur_ch3_delay > cur_ch4_delay) ? cur_ch3_delay : cur_ch4_delay));
              end
            end
          end
        end

        ST_PREFILL: begin
          if(prefill_done) begin
            cfg_auto_start <= prefill_auto_start;
            cfg_commit_pending <= 1'b1;
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
          // 等 trigger，上升沿到就进入 PLAYING
          if(trig_pulse && pending_valid) begin
            st <= ST_PLAYING;
            pending_valid <= 1'b0;
          end
        end

        ST_PLAYING: begin
          // no-op，等待 wave_done
        end

        default: st <= ST_BUILD;
      endcase
    end
  end

  // =========================================================
  // 7) DMA always（单写者：段寄存器 + dm 状态机）
  // =========================================================
  always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) begin
      dm_st <= DM_IDLE;

      m_axis_dm_cmd_tvalid <= 1'b0;
      m_axis_dm_cmd_tdata  <= 104'd0;

      dm_sel         <= 2'd0;
      dm_chunk_beats <= 32'd0;
      dm_beats_sent  <= 32'd0;

      ch1_base_addr  <= 64'd0;
      ch2_base_addr  <= 64'd0;
      ch3_base_addr  <= 64'd0;
      ch4_base_addr  <= 64'd0;
      ch1_bytes_left <= 32'd0;
      ch2_bytes_left <= 32'd0;
      ch3_bytes_left <= 32'd0;
      ch4_bytes_left <= 32'd0;

      act_ch1_valid_dm <= 1'b0;
      act_ch2_valid_dm <= 1'b0;
      act_ch3_valid_dm <= 1'b0;
      act_ch4_valid_dm <= 1'b0;

      ch1_load_tog_d <= 1'b0;
      ch2_load_tog_d <= 1'b0;
      ch3_load_tog_d <= 1'b0;
      ch4_load_tog_d <= 1'b0;
    end else begin
      // active_valid=0：清空 DMA 段状态
      if(!prefetch_en) begin
        dm_st <= DM_IDLE;
        m_axis_dm_cmd_tvalid <= 1'b0;
        m_axis_dm_cmd_tdata  <= 104'd0;
        dm_beats_sent <= 0;

        ch1_base_addr  <= 64'd0;
        ch2_base_addr  <= 64'd0;
        ch3_base_addr  <= 64'd0;
        ch4_base_addr  <= 64'd0;
        ch1_bytes_left <= 32'd0;
        ch2_bytes_left <= 32'd0;
        ch3_bytes_left <= 32'd0;
        ch4_bytes_left <= 32'd0;

        act_ch1_valid_dm <= 1'b0;
        act_ch2_valid_dm <= 1'b0;
        act_ch3_valid_dm <= 1'b0;
        act_ch4_valid_dm <= 1'b0;

        ch1_load_tog_d <= ch1_load_tog;
        ch2_load_tog_d <= ch2_load_tog;
        ch3_load_tog_d <= ch3_load_tog;
        ch4_load_tog_d <= ch4_load_tog;
      end else begin
        // 捕获 PLAY load 请求（toggle edge detect）
        if(ch1_load_tog_d != ch1_load_tog) begin
          ch1_load_tog_d <= ch1_load_tog;
          ch1_base_addr  <= ch1_load_addr;
          ch1_bytes_left <= ch1_load_bytes;
          act_ch1_valid_dm <= (ch1_load_bytes != 0);
        end
        if(ch2_load_tog_d != ch2_load_tog) begin
          ch2_load_tog_d <= ch2_load_tog;
          ch2_base_addr  <= ch2_load_addr;
          ch2_bytes_left <= ch2_load_bytes;
          act_ch2_valid_dm <= (ch2_load_bytes != 0);
        end
        if(ch3_load_tog_d != ch3_load_tog) begin
          ch3_load_tog_d <= ch3_load_tog;
          ch3_base_addr  <= ch3_load_addr;
          ch3_bytes_left <= ch3_load_bytes;
          act_ch3_valid_dm <= (ch3_load_bytes != 0);
        end
        if(ch4_load_tog_d != ch4_load_tog) begin
          ch4_load_tog_d <= ch4_load_tog;
          ch4_base_addr  <= ch4_load_addr;
          ch4_bytes_left <= ch4_load_bytes;
          act_ch4_valid_dm <= (ch4_load_bytes != 0);
        end

        // DMA 状态机
        case(dm_st)
          DM_IDLE: begin
            m_axis_dm_cmd_tvalid <= 1'b0;
            dm_beats_sent <= 0;

            dm_sel <= sel_next;

            if((sel_next == 2'd0) && ch1_need_soft) begin
              dm_chunk_beats       <= ch1_chunk_beats_w;
              m_axis_dm_cmd_tdata  <= make_dm_cmd(ch1_base_addr, ch1_chunk_bytes_w);
              m_axis_dm_cmd_tvalid <= 1'b1;
              dm_st <= DM_SENDCMD;
            end else if((sel_next == 2'd1) && ch2_need_soft) begin
              dm_chunk_beats       <= ch2_chunk_beats_w;
              m_axis_dm_cmd_tdata  <= make_dm_cmd(ch2_base_addr, ch2_chunk_bytes_w);
              m_axis_dm_cmd_tvalid <= 1'b1;
              dm_st <= DM_SENDCMD;
            end else if((sel_next == 2'd2) && ch3_need_soft) begin
              dm_chunk_beats       <= ch3_chunk_beats_w;
              m_axis_dm_cmd_tdata  <= make_dm_cmd(ch3_base_addr, ch3_chunk_bytes_w);
              m_axis_dm_cmd_tvalid <= 1'b1;
              dm_st <= DM_SENDCMD;
            end else if((sel_next == 2'd3) && ch4_need_soft) begin
              dm_chunk_beats       <= ch4_chunk_beats_w;
              m_axis_dm_cmd_tdata  <= make_dm_cmd(ch4_base_addr, ch4_chunk_bytes_w);
              m_axis_dm_cmd_tvalid <= 1'b1;
              dm_st <= DM_SENDCMD;
            end else begin
              m_axis_dm_cmd_tdata <= 104'd0;
            end
          end

          DM_SENDCMD: begin
            if(m_axis_dm_cmd_tvalid && m_axis_dm_cmd_tready) begin
              m_axis_dm_cmd_tvalid <= 1'b0;
              dm_beats_sent <= 0;
              dm_st <= DM_STREAM;
            end
          end

          DM_STREAM: begin
            if(beat_fire) begin
              dm_beats_sent <= dm_beats_sent + 1;

              if(dm_beats_sent + 1 == dm_chunk_beats) begin
                // chunk 完成：更新 base/left（方案A）
                if(dm_sel == 2'd0) begin
                  ch1_base_addr  <= ch1_base_addr  + (dm_chunk_beats << 4);
                  ch1_bytes_left <= ch1_bytes_left - (dm_chunk_beats << 4);
                end else if(dm_sel == 2'd1) begin
                  ch2_base_addr  <= ch2_base_addr  + (dm_chunk_beats << 4);
                  ch2_bytes_left <= ch2_bytes_left - (dm_chunk_beats << 4);
                end else if(dm_sel == 2'd2) begin
                  ch3_base_addr  <= ch3_base_addr  + (dm_chunk_beats << 4);
                  ch3_bytes_left <= ch3_bytes_left - (dm_chunk_beats << 4);
                end else begin
                  ch4_base_addr  <= ch4_base_addr  + (dm_chunk_beats << 4);
                  ch4_bytes_left <= ch4_bytes_left - (dm_chunk_beats << 4);
                end
                dm_st <= DM_IDLE;
              end
            end
          end

          default: dm_st <= DM_IDLE;
        endcase
      end
    end
  end

  // =========================================================
  // debug assigns
  // =========================================================
  assign dbg_st             = st;
  assign dbg_dm_st          = dm_st;
  assign dbg_dm_sel_ch1     = dm_sel_ch1;
  assign dbg_dm_chunk_beats = dm_chunk_beats;
  assign dbg_dm_beats_sent  = dm_beats_sent;

  assign dbg_ch1_bytes_left = ch1_bytes_left;
  assign dbg_ch2_bytes_left = ch2_bytes_left;
  assign dbg_ch1_base_addr  = ch1_base_addr;
  assign dbg_ch2_base_addr  = ch2_base_addr;

  assign dbg_ch1_need_hard  = ch1_need_hard;
  assign dbg_ch2_need_hard  = ch2_need_hard;
  assign dbg_ch1_need_soft  = ch1_need_soft;
  assign dbg_ch2_need_soft  = ch2_need_soft;

  assign dbg_instr_in_tdata  = s_axis_instr_tdata;
  assign dbg_instr_in_tvalid = s_axis_instr_tvalid;
  assign dbg_instr_in_tready = s_axis_instr_tready;

  assign dbg_main_tdata  = main_tdata;
  assign dbg_main_tvalid = main_tvalid;
  assign dbg_main_tready = main_tready;

  assign dbg_pending_valid = pending_valid;
  assign dbg_active_valid  = active_valid;
  assign dbg_run_delay_cnt = run_delay_cnt;

endmodule
