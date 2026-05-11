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

    input  wire [31:0] ch1_delay_cycles,
    input  wire [31:0] ch2_delay_cycles,
    input  wire [31:0] ch1_len_beats,
    input  wire [31:0] ch2_len_beats,
    input  wire        ch1_arm,
    input  wire        ch2_arm,

    input  wire        ch1_fifo_tvalid,
    input  wire        ch2_fifo_tvalid,

    input  wire        dac_ch1_ready_in,
    input  wire        dac_ch2_ready_in,

    output wire        ch1_allow,
    output wire        ch2_allow,

    output reg         ch1_active,
    output reg         ch2_active,

    // ===== debug (可选接 ILA) =====
    output wire        dbg_trig_pulse,
    output wire        dbg_new_cfg,
    output wire        dbg_trig_start,
    output wire        dbg_started,
    output wire [15:0] dbg_last_seq_id
);

  reg started;
  reg [31:0] dly1, dly2;
  reg [31:0] beats1, beats2;

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

  // 只有：trigger 上升沿 + 新配置帧 + 未 started + 至少一路 arm，才启动
  wire trig_start = trig_pulse && new_cfg && !started && (ch1_arm || ch2_arm);

  // allow：started 且 delay==0 且 beats!=0 且 arm
  assign ch1_allow = started && ch1_arm && (dly1 == 0) && (beats1 != 0);
  assign ch2_allow = started && ch2_arm && (dly2 == 0) && (beats2 != 0);

  // fire：allow 且 FIFO 有效 且 DAC ready
  wire ch1_fire = ch1_allow && ch1_fifo_tvalid && dac_ch1_ready_in;
  wire ch2_fire = ch2_allow && ch2_fifo_tvalid && dac_ch2_ready_in;

  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      started     <= 1'b0;
      dly1        <= 32'd0;
      dly2        <= 32'd0;
      beats1      <= 32'd0;
      beats2      <= 32'd0;
      ch1_active  <= 1'b0;
      ch2_active  <= 1'b0;

      cfg_seen    <= 1'b0;
      last_seq_id <= 16'd0;
    end else begin
      // 启动：锁存配置，并“消费掉”该 seq_id
      if(trig_start) begin
        started     <= 1'b1;
        dly1        <= ch1_delay_cycles;
        dly2        <= ch2_delay_cycles;
        beats1      <= ch1_len_beats;
        beats2      <= ch2_len_beats;

        cfg_seen    <= 1'b1;
        last_seq_id <= cfg_seq_id;
      end

      if(started) begin
        if(dly1 != 0) dly1 <= dly1 - 1;
        if(dly2 != 0) dly2 <= dly2 - 1;

        if(ch1_fire && beats1 != 0) beats1 <= beats1 - 1;
        if(ch2_fire && beats2 != 0) beats2 <= beats2 - 1;

        // 两路都发完才结束
        if((beats1 == 0) && (beats2 == 0)) begin
          started <= 1'b0;
        end
      end

      ch1_active <= ch1_allow;
      ch2_active <= ch2_allow;
    end
  end

  // ===== debug outputs =====
  assign dbg_trig_pulse  = trig_pulse;
  assign dbg_new_cfg     = new_cfg;
  assign dbg_trig_start  = trig_start;
  assign dbg_started     = started;
  assign dbg_last_seq_id = last_seq_id;

endmodule