`timescale 1ns / 1ps

module pl_riscv_control_v1 #(
    parameter integer MAX_PAYLOAD_WORDS = 16
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         rvctrl_tvalid,
    input  wire [63:0]  rvctrl_tdata,
    input  wire         rvctrl_tfirst,
    input  wire         rvctrl_tlast,
    input  wire [31:0]  rvctrl_word_count,

    output reg  [127:0] m_instr_tdata,
    output reg          m_instr_tvalid,
    input  wire         m_instr_tready,

    output reg          trigger_pulse,

    output reg  [31:0]  dbg_status,
    output reg  [31:0]  dbg_last_seq,
    output reg  [31:0]  dbg_last_cmd,
    output reg  [31:0]  dbg_ping_count,
    output reg  [31:0]  dbg_play_count,
    output reg  [31:0]  dbg_trigger_count,
    output reg  [31:0]  dbg_mmio_write_count,
    output reg  [31:0]  dbg_error_count,
    output reg  [31:0]  dbg_scratch,
    output reg  [3:0]   dbg_state
);

  localparam [31:0] RV_CMD_PING             = 32'h00000001;
  localparam [31:0] RV_CMD_PLAY_INTERLEAVED = 32'h00000002;
  localparam [31:0] RV_CMD_TRIGGER          = 32'h00000003;
  localparam [31:0] RV_CMD_WRITE_MMIO       = 32'h00000004;

  localparam [3:0] CMD_PLAY = 4'h2;
  localparam [3:0] CMD_END  = 4'h3;
  localparam [3:0] CH_AUTO_START = 4'hF;
  localparam [2:0] PLAY_FLAG_LOOP        = 3'h1;
  localparam [2:0] PLAY_FLAG_INTERLEAVED = 3'h4;

  localparam [3:0] ST_IDLE     = 4'd0;
  localparam [3:0] ST_RECEIVE  = 4'd1;
  localparam [3:0] ST_PROCESS  = 4'd2;
  localparam [3:0] ST_OUT_PLAY = 4'd3;
  localparam [31:0] MAX_PAYLOAD_WORDS_U32 = MAX_PAYLOAD_WORDS;

  reg [31:0] payload_words [0:MAX_PAYLOAD_WORDS-1];
  reg [31:0] rx_index;
  reg [31:0] rx_expected_words;
  reg        rx_drop;
  reg        process_pending;

  reg [31:0] play_bytes_per_channel;
  reg [31:0] play_flags;
  reg [3:0]  play_out_index;

  wire instr_fire = m_instr_tvalid && m_instr_tready;
  wire out_can_load = !m_instr_tvalid || instr_fire;
  wire [31:0] active_rx_index = rvctrl_tfirst ? 32'd0 : rx_index;
  wire [31:0] active_expected_words = rvctrl_tfirst ? rvctrl_word_count : rx_expected_words;
  wire        active_count_ok = (active_expected_words <= MAX_PAYLOAD_WORDS_U32);
  wire        active_drop = rvctrl_tfirst ? !active_count_ok : rx_drop;

  integer i;

  function [127:0] pack_instr;
    input [31:0] word0;
    input [31:0] word1;
    input [31:0] word2;
    input [31:0] word3;
    begin
      pack_instr = {word3, word2, word1, word0};
    end
  endfunction

  function [31:0] play_word0;
    input [3:0] channel;
    begin
      play_word0 = {21'd0, PLAY_FLAG_INTERLEAVED, channel, CMD_PLAY};
    end
  endfunction

  function [31:0] end_word0;
    input auto_start;
    input loop_en;
    reg [2:0] flags;
    begin
      flags = loop_en ? PLAY_FLAG_LOOP : 3'd0;
      end_word0 = {21'd0, flags, (auto_start ? CH_AUTO_START : 4'd0), CMD_END};
    end
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_instr_tdata <= 128'd0;
      m_instr_tvalid <= 1'b0;
      trigger_pulse <= 1'b0;
      dbg_status <= 32'd0;
      dbg_last_seq <= 32'd0;
      dbg_last_cmd <= 32'd0;
      dbg_ping_count <= 32'd0;
      dbg_play_count <= 32'd0;
      dbg_trigger_count <= 32'd0;
      dbg_mmio_write_count <= 32'd0;
      dbg_error_count <= 32'd0;
      dbg_scratch <= 32'd0;
      dbg_state <= ST_IDLE;
      rx_index <= 32'd0;
      rx_expected_words <= 32'd0;
      rx_drop <= 1'b0;
      process_pending <= 1'b0;
      play_bytes_per_channel <= 32'd0;
      play_flags <= 32'd0;
      play_out_index <= 4'd0;
      for (i = 0; i < MAX_PAYLOAD_WORDS; i = i + 1) begin
        payload_words[i] <= 32'd0;
      end
    end else begin
      trigger_pulse <= 1'b0;

      if (instr_fire) begin
        m_instr_tvalid <= 1'b0;
      end

      if (rvctrl_tvalid) begin
        dbg_state <= ST_RECEIVE;
        if (rvctrl_tfirst) begin
          rx_index <= 32'd0;
          rx_expected_words <= rvctrl_word_count;
          rx_drop <= (rvctrl_word_count > MAX_PAYLOAD_WORDS_U32);
          if (rvctrl_word_count > MAX_PAYLOAD_WORDS_U32) begin
            dbg_error_count <= dbg_error_count + 32'd1;
          end
        end

        if (active_count_ok && (active_rx_index < MAX_PAYLOAD_WORDS_U32)) begin
          payload_words[active_rx_index] <= rvctrl_tdata[31:0];
        end
        if (active_count_ok &&
            ((active_rx_index + 32'd1) < active_expected_words) &&
            ((active_rx_index + 32'd1) < MAX_PAYLOAD_WORDS_U32)) begin
          payload_words[active_rx_index + 32'd1] <= rvctrl_tdata[63:32];
        end
        rx_index <= active_rx_index + 32'd2;
        if (rvctrl_tlast) begin
          process_pending <= active_count_ok && !active_drop;
        end
      end else if (process_pending) begin
        process_pending <= 1'b0;
        dbg_state <= ST_PROCESS;
        dbg_last_cmd <= payload_words[0];
        dbg_last_seq <= payload_words[1];
        case (payload_words[0])
          RV_CMD_PING: begin
            dbg_status <= 32'h0000_0001;
            dbg_ping_count <= dbg_ping_count + 32'd1;
          end

          RV_CMD_PLAY_INTERLEAVED: begin
            if (payload_words[2][4:0] != 5'd0) begin
              dbg_status <= 32'hBAD0_0002;
              dbg_error_count <= dbg_error_count + 32'd1;
            end else begin
              play_bytes_per_channel <= payload_words[2];
              play_flags <= payload_words[3];
              play_out_index <= 4'd0;
              dbg_play_count <= dbg_play_count + 32'd1;
              dbg_status <= 32'h0000_0002;
              dbg_state <= ST_OUT_PLAY;
            end
          end

          RV_CMD_TRIGGER: begin
            trigger_pulse <= 1'b1;
            dbg_trigger_count <= dbg_trigger_count + 32'd1;
            dbg_status <= 32'h0000_0003;
          end

          RV_CMD_WRITE_MMIO: begin
            dbg_scratch <= payload_words[3];
            dbg_mmio_write_count <= dbg_mmio_write_count + 32'd1;
            dbg_status <= 32'h0000_0004;
          end

          default: begin
            dbg_status <= 32'hBAD0_0001;
            dbg_error_count <= dbg_error_count + 32'd1;
          end
        endcase
      end else if (dbg_state == ST_OUT_PLAY) begin
        if (out_can_load) begin
          if (play_out_index < 4'd8) begin
            m_instr_tdata <= pack_instr(
                play_word0(play_out_index + 4'd1),
                play_bytes_per_channel,
                32'd0,
                32'd0
            );
            m_instr_tvalid <= 1'b1;
            play_out_index <= play_out_index + 4'd1;
          end else begin
            m_instr_tdata <= pack_instr(
                end_word0(play_flags[0], play_flags[1]),
                32'd0,
                32'd0,
                32'd0
            );
            m_instr_tvalid <= 1'b1;
            play_out_index <= 4'd0;
            dbg_state <= ST_IDLE;
          end
        end
      end else begin
        dbg_state <= ST_IDLE;
      end
    end
  end

endmodule
