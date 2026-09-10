`timescale 1ns/1ps

// ============================================================
//  DAC 域播放门控控制器（输出 allow，不直接改 FIFO ready）
//  - cfg_seq_id gating：每个配置帧只会启动一次
//  - 第一帧也能启动（cfg_seen=0 时视为 new_cfg）
//  - trigger 用上升沿
// ============================================================
module dac_play_ctrl #(
    parameter integer BEAT_BYTES = 32
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        trigger,      // 旧 GPIO/RVCTRL 路径的 DAC 域同步 trigger 电平
    input  wire        rfctrl2_trigger, // RFCTRL2 专用、DAC 域单周期 trigger
    input  wire        prepare,      // RFCTRL2 ARM 到达 DAC 域后的单周期 prepare
    input  wire        abort,        // DAC 域同步后的 emergency mute pulse
    input  wire        armed,        // RFCTRL2 ARM 会话保持到 ABORT_MUTE
    input  wire [15:0] cfg_seq_id,   // DAC 域锁存配置帧编号
    input  wire        auto_start,   // END ch=15：配置到达后直接启动
    input  wire        loop_enable,  // loop refill 后自动继续输出，不等待下一次 Trigger
    input  wire [31:0] repeat_limit,
    input  wire        debug_alternate,

    input  wire [31:0] ch1_delay_cycles,
    input  wire [31:0] ch2_delay_cycles,
    input  wire [31:0] ch3_delay_cycles,
    input  wire [31:0] ch4_delay_cycles,
    input  wire [31:0] ch5_delay_cycles,
    input  wire [31:0] ch6_delay_cycles,
    input  wire [31:0] ch7_delay_cycles,
    input  wire [31:0] ch8_delay_cycles,
    input  wire [31:0] ch1_len_beats,
    input  wire [31:0] ch2_len_beats,
    input  wire [31:0] ch3_len_beats,
    input  wire [31:0] ch4_len_beats,
    input  wire [31:0] ch5_len_beats,
    input  wire [31:0] ch6_len_beats,
    input  wire [31:0] ch7_len_beats,
    input  wire [31:0] ch8_len_beats,
    input  wire        ch1_arm,
    input  wire        ch2_arm,
    input  wire        ch3_arm,
    input  wire        ch4_arm,
    input  wire        ch5_arm,
    input  wire        ch6_arm,
    input  wire        ch7_arm,
    input  wire        ch8_arm,

    input  wire        ch1_fifo_tvalid,
    input  wire        ch2_fifo_tvalid,
    input  wire        ch3_fifo_tvalid,
    input  wire        ch4_fifo_tvalid,
    input  wire        ch5_fifo_tvalid,
    input  wire        ch6_fifo_tvalid,
    input  wire        ch7_fifo_tvalid,
    input  wire        ch8_fifo_tvalid,
    input  wire        ch1_fifo_prog_empty,
    input  wire        ch2_fifo_prog_empty,
    input  wire        ch3_fifo_prog_empty,
    input  wire        ch4_fifo_prog_empty,
    input  wire        ch5_fifo_prog_empty,
    input  wire        ch6_fifo_prog_empty,
    input  wire        ch7_fifo_prog_empty,
    input  wire        ch8_fifo_prog_empty,

    input  wire        dac_ch1_ready_in,
    input  wire        dac_ch2_ready_in,
    input  wire        dac_ch3_ready_in,
    input  wire        dac_ch4_ready_in,
    input  wire        dac_ch5_ready_in,
    input  wire        dac_ch6_ready_in,
    input  wire        dac_ch7_ready_in,
    input  wire        dac_ch8_ready_in,

    output wire        ch1_allow,
    output wire        ch2_allow,
    output wire        ch3_allow,
    output wire        ch4_allow,
    output wire        ch5_allow,
    output wire        ch6_allow,
    output wire        ch7_allow,
    output wire        ch8_allow,

    output reg         ch1_active,
    output reg         ch2_active,
    output reg         ch3_active,
    output reg         ch4_active,
    output reg         ch5_active,
    output reg         ch6_active,
    output reg         ch7_active,
    output reg         ch8_active,
    output reg         prepared,

    // ===== debug (可选接 ILA) =====
    output wire        dbg_trig_pulse,
    output wire        dbg_new_cfg,
    output wire        dbg_trig_start,
    output wire        dbg_started,
    output wire [15:0] dbg_last_seq_id,
    output reg         dbg_done_pulse,
    output reg  [7:0]  dbg_underflow_seen,
    output reg  [31:0] dbg_ch1_fire_count,
    output reg  [31:0] dbg_ch2_fire_count,
    output reg  [31:0] dbg_ch3_fire_count,
    output reg  [31:0] dbg_ch4_fire_count,
    output reg  [31:0] dbg_ch5_fire_count,
    output reg  [31:0] dbg_ch6_fire_count,
    output reg  [31:0] dbg_ch7_fire_count,
    output reg  [31:0] dbg_ch8_fire_count,
    output reg  [31:0] dbg_trigger_admitted_count,
    output reg  [31:0] dbg_trigger_skipped_count
);

  reg started;
  reg start_pending;
  reg trigger_pending;
  reg prepare_wait_cfg;
  reg prepare_wait_warm;
  reg loop_refill_pending;
  reg burst_complete_pending;
  reg debug_phase;
  reg [31:0] repeat_limit_latched;
  reg [31:0] repeat_index;
  wire [31:0] repeat_limit_clean = (^repeat_limit === 1'bx) ? 32'd0 : repeat_limit;
  wire debug_alternate_clean = (debug_alternate === 1'b1);
  reg [31:0] dly1, dly2, dly3, dly4, dly5, dly6, dly7, dly8;
  reg [31:0] beats1, beats2, beats3, beats4, beats5, beats6, beats7, beats8;

  // ---------- trigger edge detect ----------
  reg trig_d;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) trig_d <= 1'b0;
    else       trig_d <= trigger;
  end
  wire trig_pulse = trigger & ~trig_d;

  // ---------- seq_id gating（第一帧也能启动） ----------
  reg        cfg_seen;
  reg [15:0] last_seq_id;

  wire new_cfg = (!cfg_seen) || (cfg_seq_id != last_seq_id);

  // 普通帧等 GPIO/UDP trigger；trigger 可能比 cfg CDC 晚到/早到几个周期，
  // 因此先锁存为 pending，等下一帧 cfg_seq_id 到 DAC 域后再启动。
  wire prepare_active = prepare_wait_cfg || prepare_wait_warm || prepared;
  wire trigger_seen = trig_pulse || trigger_pending;
  wire start_req = trigger_seen || auto_start;
  wire debug_trigger_admit = (!debug_alternate_clean) || debug_phase;
  wire trig_start = start_req && new_cfg && !started && !start_pending && !prepare_active &&
                    debug_trigger_admit &&
                    (ch1_arm || ch2_arm || ch3_arm || ch4_arm || ch5_arm || ch6_arm || ch7_arm || ch8_arm);

  // DDR 域已经在整帧预取完成后才提交 cfg；DAC 域只需等首个 FIFO beat 可读。
  // 短帧可能小于 prog_empty 阈值，不能用 prog_empty 作为启动条件。
  wire start_warm = (!ch1_arm || ch1_fifo_tvalid) && (!ch2_arm || ch2_fifo_tvalid) &&
                    (!ch3_arm || ch3_fifo_tvalid) && (!ch4_arm || ch4_fifo_tvalid) &&
                    (!ch5_arm || ch5_fifo_tvalid) && (!ch6_arm || ch6_fifo_tvalid) &&
                    (!ch7_arm || ch7_fifo_tvalid) && (!ch8_arm || ch8_fifo_tvalid);

  localparam [31:0] LOOP_SAFE_BEATS = 32'd128;
  wire ch1_loop_short = (ch1_len_beats <= LOOP_SAFE_BEATS);
  wire ch2_loop_short = (ch2_len_beats <= LOOP_SAFE_BEATS);
  wire ch3_loop_short = (ch3_len_beats <= LOOP_SAFE_BEATS);
  wire ch4_loop_short = (ch4_len_beats <= LOOP_SAFE_BEATS);
  wire ch5_loop_short = (ch5_len_beats <= LOOP_SAFE_BEATS);
  wire ch6_loop_short = (ch6_len_beats <= LOOP_SAFE_BEATS);
  wire ch7_loop_short = (ch7_len_beats <= LOOP_SAFE_BEATS);
  wire ch8_loop_short = (ch8_len_beats <= LOOP_SAFE_BEATS);
  wire loop_boundary_warm = (!ch1_arm || (ch1_fifo_tvalid && !ch1_fifo_prog_empty)) &&
                            (!ch2_arm || (ch2_fifo_tvalid && !ch2_fifo_prog_empty)) &&
                            (!ch3_arm || (ch3_fifo_tvalid && !ch3_fifo_prog_empty)) &&
                            (!ch4_arm || (ch4_fifo_tvalid && !ch4_fifo_prog_empty)) &&
                            (!ch5_arm || (ch5_fifo_tvalid && !ch5_fifo_prog_empty)) &&
                            (!ch6_arm || (ch6_fifo_tvalid && !ch6_fifo_prog_empty)) &&
                            (!ch7_arm || (ch7_fifo_tvalid && !ch7_fifo_prog_empty)) &&
                            (!ch8_arm || (ch8_fifo_tvalid && !ch8_fifo_prog_empty));
  wire loop_refill_warm = (!ch1_arm || (ch1_fifo_tvalid && (ch1_loop_short || !ch1_fifo_prog_empty))) &&
                          (!ch2_arm || (ch2_fifo_tvalid && (ch2_loop_short || !ch2_fifo_prog_empty))) &&
                          (!ch3_arm || (ch3_fifo_tvalid && (ch3_loop_short || !ch3_fifo_prog_empty))) &&
                          (!ch4_arm || (ch4_fifo_tvalid && (ch4_loop_short || !ch4_fifo_prog_empty))) &&
                          (!ch5_arm || (ch5_fifo_tvalid && (ch5_loop_short || !ch5_fifo_prog_empty))) &&
                          (!ch6_arm || (ch6_fifo_tvalid && (ch6_loop_short || !ch6_fifo_prog_empty))) &&
                          (!ch7_arm || (ch7_fifo_tvalid && (ch7_loop_short || !ch7_fifo_prog_empty))) &&
                          (!ch8_arm || (ch8_fifo_tvalid && (ch8_loop_short || !ch8_fifo_prog_empty)));

  // allow：started 且 delay==0 且 beats!=0 且 arm
  assign ch1_allow = started && ch1_arm && (dly1 == 0) && (beats1 != 0);
  assign ch2_allow = started && ch2_arm && (dly2 == 0) && (beats2 != 0);
  assign ch3_allow = started && ch3_arm && (dly3 == 0) && (beats3 != 0);
  assign ch4_allow = started && ch4_arm && (dly4 == 0) && (beats4 != 0);
  assign ch5_allow = started && ch5_arm && (dly5 == 0) && (beats5 != 0);
  assign ch6_allow = started && ch6_arm && (dly6 == 0) && (beats6 != 0);
  assign ch7_allow = started && ch7_arm && (dly7 == 0) && (beats7 != 0);
  assign ch8_allow = started && ch8_arm && (dly8 == 0) && (beats8 != 0);

  // fire：allow 且 FIFO 有效 且 DAC ready
  wire ch1_fire = ch1_allow && ch1_fifo_tvalid && dac_ch1_ready_in;
  wire ch2_fire = ch2_allow && ch2_fifo_tvalid && dac_ch2_ready_in;
  wire ch3_fire = ch3_allow && ch3_fifo_tvalid && dac_ch3_ready_in;
  wire ch4_fire = ch4_allow && ch4_fifo_tvalid && dac_ch4_ready_in;
  wire ch5_fire = ch5_allow && ch5_fifo_tvalid && dac_ch5_ready_in;
  wire ch6_fire = ch6_allow && ch6_fifo_tvalid && dac_ch6_ready_in;
  wire ch7_fire = ch7_allow && ch7_fifo_tvalid && dac_ch7_ready_in;
  wire ch8_fire = ch8_allow && ch8_fifo_tvalid && dac_ch8_ready_in;

  // underflow：门已开、DAC 已 ready，但 FIFO 当拍无数据。
  // RF-DAC AXIS 不用 tvalid 选通，这一拍会被当成显式零样本送进 RFDC，
  // 落在 fabric beat 节拍上，因此必须 fail closed 而不是继续播放。
  wire ch1_underflow_now = ch1_allow && dac_ch1_ready_in && !ch1_fifo_tvalid;
  wire ch2_underflow_now = ch2_allow && dac_ch2_ready_in && !ch2_fifo_tvalid;
  wire ch3_underflow_now = ch3_allow && dac_ch3_ready_in && !ch3_fifo_tvalid;
  wire ch4_underflow_now = ch4_allow && dac_ch4_ready_in && !ch4_fifo_tvalid;
  wire ch5_underflow_now = ch5_allow && dac_ch5_ready_in && !ch5_fifo_tvalid;
  wire ch6_underflow_now = ch6_allow && dac_ch6_ready_in && !ch6_fifo_tvalid;
  wire ch7_underflow_now = ch7_allow && dac_ch7_ready_in && !ch7_fifo_tvalid;
  wire ch8_underflow_now = ch8_allow && dac_ch8_ready_in && !ch8_fifo_tvalid;
  wire any_underflow_now = ch1_underflow_now || ch2_underflow_now ||
                           ch3_underflow_now || ch4_underflow_now ||
                           ch5_underflow_now || ch6_underflow_now ||
                           ch7_underflow_now || ch8_underflow_now;

  wire ch1_done_after = !ch1_arm || (beats1 == 32'd0) || (ch1_fire && (beats1 == 32'd1));
  wire ch2_done_after = !ch2_arm || (beats2 == 32'd0) || (ch2_fire && (beats2 == 32'd1));
  wire ch3_done_after = !ch3_arm || (beats3 == 32'd0) || (ch3_fire && (beats3 == 32'd1));
  wire ch4_done_after = !ch4_arm || (beats4 == 32'd0) || (ch4_fire && (beats4 == 32'd1));
  wire ch5_done_after = !ch5_arm || (beats5 == 32'd0) || (ch5_fire && (beats5 == 32'd1));
  wire ch6_done_after = !ch6_arm || (beats6 == 32'd0) || (ch6_fire && (beats6 == 32'd1));
  wire ch7_done_after = !ch7_arm || (beats7 == 32'd0) || (ch7_fire && (beats7 == 32'd1));
  wire ch8_done_after = !ch8_arm || (beats8 == 32'd0) || (ch8_fire && (beats8 == 32'd1));
  wire frame_done_after = ch1_done_after && ch2_done_after && ch3_done_after && ch4_done_after &&
                          ch5_done_after && ch6_done_after && ch7_done_after && ch8_done_after;

  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      started     <= 1'b0;
      start_pending <= 1'b0;
      trigger_pending <= 1'b0;
      prepare_wait_cfg <= 1'b0;
      prepare_wait_warm <= 1'b0;
      loop_refill_pending <= 1'b0;
      burst_complete_pending <= 1'b0;
      debug_phase <= 1'b0;
      repeat_limit_latched <= 32'd0;
      repeat_index <= 32'd0;
      prepared <= 1'b0;
      dly1        <= 32'd0;
      dly2        <= 32'd0;
      dly3        <= 32'd0;
      dly4        <= 32'd0;
      dly5        <= 32'd0;
      dly6        <= 32'd0;
      dly7        <= 32'd0;
      dly8        <= 32'd0;
      beats1      <= 32'd0;
      beats2      <= 32'd0;
      beats3      <= 32'd0;
      beats4      <= 32'd0;
      beats5      <= 32'd0;
      beats6      <= 32'd0;
      beats7      <= 32'd0;
      beats8      <= 32'd0;
      ch1_active  <= 1'b0;
      ch2_active  <= 1'b0;
      ch3_active  <= 1'b0;
      ch4_active  <= 1'b0;
      ch5_active  <= 1'b0;
      ch6_active  <= 1'b0;
      ch7_active  <= 1'b0;
      ch8_active  <= 1'b0;
      dbg_done_pulse <= 1'b0;
      dbg_underflow_seen <= 8'd0;
      dbg_ch1_fire_count <= 32'd0;
      dbg_ch2_fire_count <= 32'd0;
      dbg_ch3_fire_count <= 32'd0;
      dbg_ch4_fire_count <= 32'd0;
      dbg_ch5_fire_count <= 32'd0;
      dbg_ch6_fire_count <= 32'd0;
      dbg_ch7_fire_count <= 32'd0;
      dbg_ch8_fire_count <= 32'd0;
      dbg_trigger_admitted_count <= 32'd0;
      dbg_trigger_skipped_count <= 32'd0;

      cfg_seen    <= 1'b0;
      last_seq_id <= 16'd0;
    end else if(abort) begin
      started       <= 1'b0;
      start_pending <= 1'b0;
      trigger_pending <= 1'b0;
      prepare_wait_cfg <= 1'b0;
      prepare_wait_warm <= 1'b0;
      loop_refill_pending <= 1'b0;
      burst_complete_pending <= 1'b0;
      debug_phase <= 1'b0;
      repeat_limit_latched <= 32'd0;
      repeat_index <= 32'd0;
      prepared <= 1'b0;
      dly1 <= 32'd0; dly2 <= 32'd0; dly3 <= 32'd0; dly4 <= 32'd0;
      dly5 <= 32'd0; dly6 <= 32'd0; dly7 <= 32'd0; dly8 <= 32'd0;
      beats1 <= 32'd0; beats2 <= 32'd0; beats3 <= 32'd0; beats4 <= 32'd0;
      beats5 <= 32'd0; beats6 <= 32'd0; beats7 <= 32'd0; beats8 <= 32'd0;
      dbg_trigger_admitted_count <= 32'd0;
      dbg_trigger_skipped_count <= 32'd0;
      ch1_active <= 1'b0; ch2_active <= 1'b0; ch3_active <= 1'b0; ch4_active <= 1'b0;
      ch5_active <= 1'b0; ch6_active <= 1'b0; ch7_active <= 1'b0; ch8_active <= 1'b0;
      dbg_done_pulse <= 1'b0;
    end else begin
      dbg_done_pulse <= 1'b0;
      // RFCTRL2 ARM begins a new prepare transaction. The waveform executor
      // is already prefetching in the DDR domain; do not open any DAC gate
      // until this controller has locked the new configuration and observed
      // one readable beat for every enabled channel.
      if(prepare) begin
        started <= 1'b0;
        start_pending <= 1'b0;
        trigger_pending <= 1'b0;
        prepare_wait_cfg <= 1'b1;
        prepare_wait_warm <= 1'b0;
        loop_refill_pending <= 1'b0;
        prepared <= 1'b0;
      end else begin
        if(prepare_wait_cfg && new_cfg &&
           (ch1_arm || ch2_arm || ch3_arm || ch4_arm || ch5_arm || ch6_arm || ch7_arm || ch8_arm)) begin
          dly1 <= ch1_delay_cycles; dly2 <= ch2_delay_cycles;
          dly3 <= ch3_delay_cycles; dly4 <= ch4_delay_cycles;
          dly5 <= ch5_delay_cycles; dly6 <= ch6_delay_cycles;
          dly7 <= ch7_delay_cycles; dly8 <= ch8_delay_cycles;
          beats1 <= ch1_len_beats; beats2 <= ch2_len_beats;
          beats3 <= ch3_len_beats; beats4 <= ch4_len_beats;
          beats5 <= ch5_len_beats; beats6 <= ch6_len_beats;
          beats7 <= ch7_len_beats; beats8 <= ch8_len_beats;
          dbg_underflow_seen <= 8'd0;
          dbg_ch1_fire_count <= 32'd0; dbg_ch2_fire_count <= 32'd0;
          dbg_ch3_fire_count <= 32'd0; dbg_ch4_fire_count <= 32'd0;
          dbg_ch5_fire_count <= 32'd0; dbg_ch6_fire_count <= 32'd0;
          dbg_ch7_fire_count <= 32'd0; dbg_ch8_fire_count <= 32'd0;
          cfg_seen <= 1'b1;
          last_seq_id <= cfg_seq_id;
          prepare_wait_cfg <= 1'b0;
          prepare_wait_warm <= 1'b1;
          repeat_limit_latched <= repeat_limit_clean;
          repeat_index <= 32'd0;
        end else if(armed && cfg_seen && new_cfg && !started &&
                    !prepare_wait_cfg && !prepare_wait_warm && !prepared &&
                    (ch1_arm || ch2_arm || ch3_arm || ch4_arm || ch5_arm || ch6_arm || ch7_arm || ch8_arm)) begin
          // A loop refill commits a new cfg_seq_id without issuing another
          // ARM. In seamless loop mode the warmup immediately reopens the
          // gate; otherwise it reports PREPARED for expert/manual trigger.
          dly1 <= ch1_delay_cycles; dly2 <= ch2_delay_cycles;
          dly3 <= ch3_delay_cycles; dly4 <= ch4_delay_cycles;
          dly5 <= ch5_delay_cycles; dly6 <= ch6_delay_cycles;
          dly7 <= ch7_delay_cycles; dly8 <= ch8_delay_cycles;
          beats1 <= ch1_len_beats; beats2 <= ch2_len_beats;
          beats3 <= ch3_len_beats; beats4 <= ch4_len_beats;
          beats5 <= ch5_len_beats; beats6 <= ch6_len_beats;
          beats7 <= ch7_len_beats; beats8 <= ch8_len_beats;
          dbg_underflow_seen <= 8'd0;
          dbg_ch1_fire_count <= 32'd0; dbg_ch2_fire_count <= 32'd0;
          dbg_ch3_fire_count <= 32'd0; dbg_ch4_fire_count <= 32'd0;
          dbg_ch5_fire_count <= 32'd0; dbg_ch6_fire_count <= 32'd0;
          dbg_ch7_fire_count <= 32'd0; dbg_ch8_fire_count <= 32'd0;
          cfg_seen <= 1'b1;
          last_seq_id <= cfg_seq_id;
          prepare_wait_warm <= 1'b1;
          loop_refill_pending <= loop_enable;
          repeat_limit_latched <= repeat_limit_clean;
          repeat_index <= 32'd0;
        end

        if(prepare_wait_warm && start_warm) begin
          prepare_wait_warm <= 1'b0;
          if(loop_refill_pending) begin
            started <= 1'b1;
            prepared <= 1'b0;
            loop_refill_pending <= 1'b0;
          end else begin
            prepared <= 1'b1;
          end
        end

        // In the RFCTRL2 path all launch state was loaded while PREPARED.
        // Trigger therefore only opens the output gates; it never waits for
        // FIFO data or reloads delay/beat counters.
        if((trig_pulse || rfctrl2_trigger) && debug_alternate_clean) begin
          if(!debug_phase) begin
            debug_phase <= 1'b1;
            dbg_trigger_skipped_count <= dbg_trigger_skipped_count + 32'd1;
          end else begin
            debug_phase <= 1'b0;
            dbg_trigger_admitted_count <= dbg_trigger_admitted_count + 32'd1;
          end
        end else if(trig_pulse || rfctrl2_trigger) begin
          dbg_trigger_admitted_count <= dbg_trigger_admitted_count + 32'd1;
        end

        if(rfctrl2_trigger && prepared && !started && debug_trigger_admit) begin
          started <= 1'b1;
          prepared <= 1'b0;
        end

        if(trig_pulse && !started && !start_pending && !prepare_active && debug_trigger_admit) begin
          trigger_pending <= 1'b1;
        end

        // 旧 GPIO/RVCTRL 路径保持原行为：Trigger 可以早于配置，且要等
        // FIFO 首拍就绪后再启动。RFCTRL2 预取路径不会进入这里。
        if(trig_start) begin
          start_pending <= 1'b1;
          trigger_pending <= 1'b0;
        end

        if(start_pending && start_warm) begin
          started       <= 1'b1;
          start_pending <= 1'b0;
          dly1          <= ch1_delay_cycles;
          dly2          <= ch2_delay_cycles;
          dly3          <= ch3_delay_cycles;
          dly4          <= ch4_delay_cycles;
          dly5          <= ch5_delay_cycles;
          dly6          <= ch6_delay_cycles;
          dly7          <= ch7_delay_cycles;
          dly8          <= ch8_delay_cycles;
          beats1        <= ch1_len_beats;
          beats2        <= ch2_len_beats;
          beats3        <= ch3_len_beats;
          beats4        <= ch4_len_beats;
          beats5        <= ch5_len_beats;
          beats6        <= ch6_len_beats;
          beats7        <= ch7_len_beats;
          beats8        <= ch8_len_beats;
          dbg_underflow_seen <= 8'd0;
          dbg_ch1_fire_count <= 32'd0;
          dbg_ch2_fire_count <= 32'd0;
          dbg_ch3_fire_count <= 32'd0;
          dbg_ch4_fire_count <= 32'd0;
          dbg_ch5_fire_count <= 32'd0;
          dbg_ch6_fire_count <= 32'd0;
          dbg_ch7_fire_count <= 32'd0;
          dbg_ch8_fire_count <= 32'd0;

          cfg_seen      <= 1'b1;
          last_seq_id   <= cfg_seq_id;
        end

        if(loop_refill_pending && !started && loop_refill_warm) begin
          started <= !burst_complete_pending;
          start_pending <= 1'b0;
          trigger_pending <= 1'b0;
          loop_refill_pending <= 1'b0;
          prepared <= burst_complete_pending;
          dly1 <= 32'd0; dly2 <= 32'd0; dly3 <= 32'd0; dly4 <= 32'd0;
          dly5 <= 32'd0; dly6 <= 32'd0; dly7 <= 32'd0; dly8 <= 32'd0;
          beats1 <= ch1_len_beats; beats2 <= ch2_len_beats;
          beats3 <= ch3_len_beats; beats4 <= ch4_len_beats;
          beats5 <= ch5_len_beats; beats6 <= ch6_len_beats;
          beats7 <= ch7_len_beats; beats8 <= ch8_len_beats;
          burst_complete_pending <= 1'b0;
          repeat_index <= 32'd0;
        end
      end

      if(started) begin
        if(dly1 != 0) dly1 <= dly1 - 1;
        if(dly2 != 0) dly2 <= dly2 - 1;
        if(dly3 != 0) dly3 <= dly3 - 1;
        if(dly4 != 0) dly4 <= dly4 - 1;
        if(dly5 != 0) dly5 <= dly5 - 1;
        if(dly6 != 0) dly6 <= dly6 - 1;
        if(dly7 != 0) dly7 <= dly7 - 1;
        if(dly8 != 0) dly8 <= dly8 - 1;

        if(ch1_fire && beats1 != 0) beats1 <= beats1 - 1;
        if(ch2_fire && beats2 != 0) beats2 <= beats2 - 1;
        if(ch3_fire && beats3 != 0) beats3 <= beats3 - 1;
        if(ch4_fire && beats4 != 0) beats4 <= beats4 - 1;
        if(ch5_fire && beats5 != 0) beats5 <= beats5 - 1;
        if(ch6_fire && beats6 != 0) beats6 <= beats6 - 1;
        if(ch7_fire && beats7 != 0) beats7 <= beats7 - 1;
        if(ch8_fire && beats8 != 0) beats8 <= beats8 - 1;
        if(ch1_fire) dbg_ch1_fire_count <= dbg_ch1_fire_count + 32'd1;
        if(ch2_fire) dbg_ch2_fire_count <= dbg_ch2_fire_count + 32'd1;
        if(ch3_fire) dbg_ch3_fire_count <= dbg_ch3_fire_count + 32'd1;
        if(ch4_fire) dbg_ch4_fire_count <= dbg_ch4_fire_count + 32'd1;
        if(ch5_fire) dbg_ch5_fire_count <= dbg_ch5_fire_count + 32'd1;
        if(ch6_fire) dbg_ch6_fire_count <= dbg_ch6_fire_count + 32'd1;
        if(ch7_fire) dbg_ch7_fire_count <= dbg_ch7_fire_count + 32'd1;
        if(ch8_fire) dbg_ch8_fire_count <= dbg_ch8_fire_count + 32'd1;

        if(ch1_underflow_now) dbg_underflow_seen[0] <= 1'b1;
        if(ch2_underflow_now) dbg_underflow_seen[1] <= 1'b1;
        if(ch3_underflow_now) dbg_underflow_seen[2] <= 1'b1;
        if(ch4_underflow_now) dbg_underflow_seen[3] <= 1'b1;
        if(ch5_underflow_now) dbg_underflow_seen[4] <= 1'b1;
        if(ch6_underflow_now) dbg_underflow_seen[5] <= 1'b1;
        if(ch7_underflow_now) dbg_underflow_seen[6] <= 1'b1;
        if(ch8_underflow_now) dbg_underflow_seen[7] <= 1'b1;

        // 所有启用通道都发完才结束。Loop 模式仍使用同一配置续播；
        // executor 的低水位续读不会提交新的 cfg_seq_id。边界处只有在
        // FIFO 超过 prog_empty 阈值时才无缝重装；否则先关门等待 refill。
        // 这样不会把当前最后一拍 tvalid 误判为下一轮已有数据。
        if(frame_done_after) begin
          if(loop_enable) begin
            if((repeat_limit_latched != 32'd0) &&
               (repeat_index + 32'd1 >= repeat_limit_latched)) begin
              started <= 1'b0;
              start_pending <= 1'b0;
              loop_refill_pending <= 1'b1;
              burst_complete_pending <= 1'b1;
            end else if(loop_boundary_warm) begin
              started <= 1'b1;
              start_pending <= 1'b0;
              loop_refill_pending <= 1'b0;
              beats1 <= ch1_len_beats; beats2 <= ch2_len_beats;
              beats3 <= ch3_len_beats; beats4 <= ch4_len_beats;
              beats5 <= ch5_len_beats; beats6 <= ch6_len_beats;
              beats7 <= ch7_len_beats; beats8 <= ch8_len_beats;
              dly1 <= 32'd0; dly2 <= 32'd0; dly3 <= 32'd0; dly4 <= 32'd0;
              dly5 <= 32'd0; dly6 <= 32'd0; dly7 <= 32'd0; dly8 <= 32'd0;
              repeat_index <= repeat_index + 32'd1;
            end else begin
              started <= 1'b0;
              start_pending <= 1'b0;
              loop_refill_pending <= 1'b1;
            end
            dbg_done_pulse <= 1'b1;
          end else begin
            started <= 1'b0;
            start_pending <= 1'b0;
            loop_refill_pending <= 1'b0;
            burst_complete_pending <= 1'b1;
            dbg_done_pulse <= 1'b1;
          end
        end

        // Fail closed on an active-frame underflow. This block is intentionally
        // last so it overrides the loop reload above: once an enabled channel
        // has been starved mid-frame the gate must shut instead of continuing
        // to present beats the FIFO cannot back. Leaving the gate open turns
        // every starved cycle into an explicit zero beat at the RFDC fabric
        // rate, which modulates the RF output instead of simply truncating it.
        if(any_underflow_now) begin
          started        <= 1'b0;
          start_pending  <= 1'b0;
          trigger_pending <= 1'b0;
          prepared       <= 1'b0;
          loop_refill_pending <= 1'b0;
          prepare_wait_warm   <= 1'b0;
          dbg_done_pulse <= 1'b0;
          dly1 <= 32'd0; dly2 <= 32'd0; dly3 <= 32'd0; dly4 <= 32'd0;
          dly5 <= 32'd0; dly6 <= 32'd0; dly7 <= 32'd0; dly8 <= 32'd0;
          beats1 <= 32'd0; beats2 <= 32'd0; beats3 <= 32'd0; beats4 <= 32'd0;
          beats5 <= 32'd0; beats6 <= 32'd0; beats7 <= 32'd0; beats8 <= 32'd0;
        end
      end

      ch1_active <= ch1_allow;
      ch2_active <= ch2_allow;
      ch3_active <= ch3_allow;
      ch4_active <= ch4_allow;
      ch5_active <= ch5_allow;
      ch6_active <= ch6_allow;
      ch7_active <= ch7_allow;
      ch8_active <= ch8_allow;
    end
  end

  // ===== debug outputs =====
  assign dbg_trig_pulse  = trig_pulse;
  assign dbg_new_cfg     = new_cfg;
  assign dbg_trig_start  = trig_start;
  assign dbg_started     = started;
  assign dbg_last_seq_id = last_seq_id;

endmodule
