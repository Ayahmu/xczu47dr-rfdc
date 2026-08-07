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

    input  wire        trigger,      // DAC 域同步后的 trigger 电平
    input  wire [15:0] cfg_seq_id,   // DAC 域锁存配置帧编号
    input  wire        auto_start,   // END ch=15：配置到达后直接启动
    input  trigger_start,

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

    // ===== debug (可选接 ILA) =====
    output wire        dbg_trig_pulse,
    output wire        dbg_new_cfg,
    output wire        dbg_trig_start,
    output wire        dbg_started,
    output wire [15:0] dbg_last_seq_id
);

  reg started;
  reg start_pending;
  reg trigger_pending;
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
  wire trigger_seen = trig_pulse || trigger_pending;
  wire start_req = trigger_seen || auto_start;
  wire trig_start = start_req && new_cfg && !started && !start_pending && (ch1_arm || ch2_arm || ch3_arm || ch4_arm || ch5_arm || ch6_arm || ch7_arm || ch8_arm);

  // DDR 域已经在整帧预取完成后才提交 cfg；DAC 域只需等首个 FIFO beat 可读。
  // 短帧可能小于 prog_empty 阈值，不能用 prog_empty 作为启动条件。
  wire start_warm = (!ch1_arm || ch1_fifo_tvalid) && (!ch2_arm || ch2_fifo_tvalid) &&
                    (!ch3_arm || ch3_fifo_tvalid) && (!ch4_arm || ch4_fifo_tvalid) &&
                    (!ch5_arm || ch5_fifo_tvalid) && (!ch6_arm || ch6_fifo_tvalid) &&
                    (!ch7_arm || ch7_fifo_tvalid) && (!ch8_arm || ch8_fifo_tvalid);

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

  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      started     <= 1'b0;
      start_pending <= 1'b0;
      trigger_pending <= 1'b0;
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

      cfg_seen    <= 1'b0;
      last_seq_id <= 16'd0;
    end else begin
      if(trig_pulse && !started && !start_pending) begin
        trigger_pending <= 1'b1;
      end

      // 启动请求先挂起，直到 FIFO 预填达到阈值后才真正开始消耗。
      if(trig_start) begin
        start_pending <= 1'b1;
        trigger_pending <= 1'b0;
      end

      if(/*start_pending && start_warm*/trigger_start) begin
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

        cfg_seen      <= 1'b1;
        last_seq_id   <= cfg_seq_id;
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

        // 所有启用通道都发完才结束
        if((beats1 == 0) && (beats2 == 0) && (beats3 == 0) && (beats4 == 0) &&
           (beats5 == 0) && (beats6 == 0) && (beats7 == 0) && (beats8 == 0)) begin
          started <= 1'b0;
          start_pending <= 1'b0;
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
