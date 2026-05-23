// ============================================================
//  DAC 域播放门控控制器（输出 allow，不直接改 FIFO ready）
//  - cfg_seq_id gating：每个配置帧只会启动一次
//  - 第一帧也能启动（cfg_seen=0 时视为 new_cfg）
//  - trigger 用上升沿
// ============================================================
module dac_play_ctrl #(
    parameter integer BEAT_BYTES = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        trigger,      // DAC 域同步后的 trigger 电平
    input  wire [15:0] cfg_seq_id,   // DAC 域锁存配置帧编号
    input  wire        auto_start,   // END ch=15：配置到达后直接启动

    input  wire [31:0] ch1_delay_cycles,
    input  wire [31:0] ch2_delay_cycles,
    input  wire [31:0] ch3_delay_cycles,
    input  wire [31:0] ch4_delay_cycles,
    input  wire [31:0] ch1_len_beats,
    input  wire [31:0] ch2_len_beats,
    input  wire [31:0] ch3_len_beats,
    input  wire [31:0] ch4_len_beats,
    input  wire        ch1_arm,
    input  wire        ch2_arm,
    input  wire        ch3_arm,
    input  wire        ch4_arm,

    input  wire        ch1_fifo_tvalid,
    input  wire        ch2_fifo_tvalid,
    input  wire        ch3_fifo_tvalid,
    input  wire        ch4_fifo_tvalid,
    input  wire        ch1_fifo_prog_empty,
    input  wire        ch2_fifo_prog_empty,
    input  wire        ch3_fifo_prog_empty,
    input  wire        ch4_fifo_prog_empty,

    input  wire        dac_ch1_ready_in,
    input  wire        dac_ch2_ready_in,
    input  wire        dac_ch3_ready_in,
    input  wire        dac_ch4_ready_in,

    output wire        ch1_allow,
    output wire        ch2_allow,
    output wire        ch3_allow,
    output wire        ch4_allow,

    output reg         ch1_active,
    output reg         ch2_active,
    output reg         ch3_active,
    output reg         ch4_active,

    // ===== debug (可选接 ILA) =====
    output wire        dbg_trig_pulse,
    output wire        dbg_new_cfg,
    output wire        dbg_trig_start,
    output wire        dbg_started,
    output wire [15:0] dbg_last_seq_id
);

  reg started;
  reg start_pending;
  reg [31:0] dly1, dly2, dly3, dly4;
  reg [31:0] beats1, beats2, beats3, beats4;

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

  // 普通帧等 GPIO trigger；END ch=15 帧在配置到达 DAC 域后直接启动。
  wire start_req = trig_pulse || auto_start;
  wire trig_start = start_req && new_cfg && !started && !start_pending && (ch1_arm || ch2_arm || ch3_arm || ch4_arm);

  // 启动前等待已启用通道 FIFO 达到 programmable-empty 以上水位。
  wire start_warm = (!ch1_arm || !ch1_fifo_prog_empty) && (!ch2_arm || !ch2_fifo_prog_empty) &&
                    (!ch3_arm || !ch3_fifo_prog_empty) && (!ch4_arm || !ch4_fifo_prog_empty);

  // allow：started 且 delay==0 且 beats!=0 且 arm
  assign ch1_allow = started && ch1_arm && (dly1 == 0) && (beats1 != 0);
  assign ch2_allow = started && ch2_arm && (dly2 == 0) && (beats2 != 0);
  assign ch3_allow = started && ch3_arm && (dly3 == 0) && (beats3 != 0);
  assign ch4_allow = started && ch4_arm && (dly4 == 0) && (beats4 != 0);

  // fire：allow 且 FIFO 有效 且 DAC ready
  wire ch1_fire = ch1_allow && ch1_fifo_tvalid && dac_ch1_ready_in;
  wire ch2_fire = ch2_allow && ch2_fifo_tvalid && dac_ch2_ready_in;
  wire ch3_fire = ch3_allow && ch3_fifo_tvalid && dac_ch3_ready_in;
  wire ch4_fire = ch4_allow && ch4_fifo_tvalid && dac_ch4_ready_in;

  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      started     <= 1'b0;
      start_pending <= 1'b0;
      dly1        <= 32'd0;
      dly2        <= 32'd0;
      dly3        <= 32'd0;
      dly4        <= 32'd0;
      beats1      <= 32'd0;
      beats2      <= 32'd0;
      beats3      <= 32'd0;
      beats4      <= 32'd0;
      ch1_active  <= 1'b0;
      ch2_active  <= 1'b0;
      ch3_active  <= 1'b0;
      ch4_active  <= 1'b0;

      cfg_seen    <= 1'b0;
      last_seq_id <= 16'd0;
    end else begin
      // 启动请求先挂起，直到 FIFO 预填达到阈值后才真正开始消耗。
      if(trig_start) begin
        start_pending <= 1'b1;
      end

      if(start_pending && start_warm) begin
        started       <= 1'b1;
        start_pending <= 1'b0;
        dly1          <= ch1_delay_cycles;
        dly2          <= ch2_delay_cycles;
        dly3          <= ch3_delay_cycles;
        dly4          <= ch4_delay_cycles;
        beats1        <= ch1_len_beats;
        beats2        <= ch2_len_beats;
        beats3        <= ch3_len_beats;
        beats4        <= ch4_len_beats;

        cfg_seen      <= 1'b1;
        last_seq_id   <= cfg_seq_id;
      end

      if(started) begin
        if(dly1 != 0) dly1 <= dly1 - 1;
        if(dly2 != 0) dly2 <= dly2 - 1;
        if(dly3 != 0) dly3 <= dly3 - 1;
        if(dly4 != 0) dly4 <= dly4 - 1;

        if(ch1_fire && beats1 != 0) beats1 <= beats1 - 1;
        if(ch2_fire && beats2 != 0) beats2 <= beats2 - 1;
        if(ch3_fire && beats3 != 0) beats3 <= beats3 - 1;
        if(ch4_fire && beats4 != 0) beats4 <= beats4 - 1;

        // 所有启用通道都发完才结束
        if((beats1 == 0) && (beats2 == 0) && (beats3 == 0) && (beats4 == 0)) begin
          started <= 1'b0;
          start_pending <= 1'b0;
        end
      end

      ch1_active <= ch1_allow;
      ch2_active <= ch2_allow;
      ch3_active <= ch3_allow;
      ch4_active <= ch4_allow;
    end
  end

  // ===== debug outputs =====
  assign dbg_trig_pulse  = trig_pulse;
  assign dbg_new_cfg     = new_cfg;
  assign dbg_trig_start  = trig_start;
  assign dbg_started     = started;
  assign dbg_last_seq_id = last_seq_id;

endmodule