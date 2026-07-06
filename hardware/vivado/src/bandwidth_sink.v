`timescale 1ns / 1ps

module bandwidth_sink #(
    parameter integer CHANNELS   = 8,
    parameter integer DATA_WIDTH = 512,
    parameter integer FIFO_DEPTH = 1024,
    parameter integer LOW_WM     = 128,
    parameter integer HIGH_WM    = 768,
    parameter integer INTERLEAVED_MODE = 1,
    parameter integer PRESSURE_MODE = 1,
    parameter integer CH1_DRAIN_DIV = 8,
    parameter integer CH2_DRAIN_DIV = 9,
    parameter integer CH3_DRAIN_DIV = 10,
    parameter integer CH4_DRAIN_DIV = 11,
    parameter integer CH5_DRAIN_DIV = 12,
    parameter integer CH6_DRAIN_DIV = 13,
    parameter integer CH7_DRAIN_DIV = 14,
    parameter integer CH8_DRAIN_DIV = 15
)(
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         clear,
    input  wire [2:0]                   dm_sel,
    input  wire [DATA_WIDTH-1:0]        s_axis_tdata,
    input  wire                         s_axis_tvalid,
    output wire                         s_axis_tready,
    input  wire [CHANNELS-1:0]          ch_arm,
    input  wire [31:0]                  sample_period_cycles,

    output reg  [15:0]                  ch1_level,
    output reg  [15:0]                  ch2_level,
    output reg  [15:0]                  ch3_level,
    output reg  [15:0]                  ch4_level,
    output reg  [15:0]                  ch5_level,
    output reg  [15:0]                  ch6_level,
    output reg  [15:0]                  ch7_level,
    output reg  [15:0]                  ch8_level,

    output wire [31:0]                  status,
    output wire [31:0]                  total_bytes_low,
    output wire [31:0]                  total_bytes_high,
    output reg  [31:0]                  total_stall_cycles,
    output reg  [31:0]                  total_underflows,
    output reg  [31:0]                  sample_index,
    output reg  [31:0]                  sample_bytes_low,
    output reg  [31:0]                  sample_bytes_high,
    output reg  [31:0]                  sample_stalls,
    output reg  [31:0]                  sample_underflows,
    output reg                          sample_valid,

    input  wire [2:0]                   ch_select,
    output wire [31:0]                  ch_bytes_low,
    output wire [31:0]                  ch_bytes_high,
    output wire [31:0]                  ch_stalls,
    output wire [31:0]                  ch_underflows,
    output wire [31:0]                  ch_fifo_min,
    output wire [31:0]                  ch_fifo_max
);

  localparam integer BEAT_BYTES = DATA_WIDTH / 8;
  localparam [63:0] BEAT_BYTES_U64 = DATA_WIDTH / 8;
  localparam integer LANE_BYTES = BEAT_BYTES / CHANNELS;
  localparam [63:0] LANE_BYTES_U64 = BEAT_BYTES / CHANNELS;
  localparam integer LEVEL_WIDTH = 16;

  reg [63:0] ch_bytes [0:CHANNELS-1];
  reg [31:0] ch_stall_count [0:CHANNELS-1];
  reg [31:0] ch_underflow_count [0:CHANNELS-1];
  reg [15:0] ch_level [0:CHANNELS-1];
  reg [15:0] ch_min_level [0:CHANNELS-1];
  reg [15:0] ch_max_level [0:CHANNELS-1];
  reg [15:0] ch_drain_count [0:CHANNELS-1];
  reg [63:0] total_bytes;
  reg [31:0] sample_cycle_count;
  reg [63:0] sample_bytes_accum;
  reg [31:0] sample_stalls_accum;
  reg [31:0] sample_underflows_accum;
  reg [CHANNELS-1:0] underflow_seen;
  integer i;
  reg consume_due;
  reg fill_due;
  reg [15:0] next_level;

  wire selected_ready = (ch_level[dm_sel] < FIFO_DEPTH[15:0]);
  reg interleaved_ready;
  wire beat_fire = s_axis_tvalid && s_axis_tready;

  assign s_axis_tready = ((INTERLEAVED_MODE != 0) && (PRESSURE_MODE != 0)) ? 1'b1 :
                         ((INTERLEAVED_MODE != 0) ? interleaved_ready : selected_ready);
  assign total_bytes_low = total_bytes[31:0];
  assign total_bytes_high = total_bytes[63:32];
  assign status = {
      7'd0,
      sample_valid,
      underflow_seen,
      5'd0,
      dm_sel,
      s_axis_tready,
      s_axis_tvalid,
      1'b0
  };

  assign ch_bytes_low  = ch_bytes[ch_select][31:0];
  assign ch_bytes_high = ch_bytes[ch_select][63:32];
  assign ch_stalls     = ch_stall_count[ch_select];
  assign ch_underflows = ch_underflow_count[ch_select];
  assign ch_fifo_min   = {16'd0, ch_min_level[ch_select]};
  assign ch_fifo_max   = {16'd0, ch_max_level[ch_select]};

  function [15:0] drain_div;
    input integer channel;
    begin
      case(channel)
        0: drain_div = (CH1_DRAIN_DIV <= 1) ? 16'd1 : CH1_DRAIN_DIV[15:0];
        1: drain_div = (CH2_DRAIN_DIV <= 1) ? 16'd1 : CH2_DRAIN_DIV[15:0];
        2: drain_div = (CH3_DRAIN_DIV <= 1) ? 16'd1 : CH3_DRAIN_DIV[15:0];
        3: drain_div = (CH4_DRAIN_DIV <= 1) ? 16'd1 : CH4_DRAIN_DIV[15:0];
        4: drain_div = (CH5_DRAIN_DIV <= 1) ? 16'd1 : CH5_DRAIN_DIV[15:0];
        5: drain_div = (CH6_DRAIN_DIV <= 1) ? 16'd1 : CH6_DRAIN_DIV[15:0];
        6: drain_div = (CH7_DRAIN_DIV <= 1) ? 16'd1 : CH7_DRAIN_DIV[15:0];
        default: drain_div = (CH8_DRAIN_DIV <= 1) ? 16'd1 : CH8_DRAIN_DIV[15:0];
      endcase
    end
  endfunction

  always @* begin
    interleaved_ready = 1'b1;
    for(i = 0; i < CHANNELS; i = i + 1) begin
      if(ch_arm[i] && (ch_level[i] >= FIFO_DEPTH[15:0])) interleaved_ready = 1'b0;
    end
  end

  always @* begin
    ch1_level = ch_level[0];
    ch2_level = ch_level[1];
    ch3_level = ch_level[2];
    ch4_level = ch_level[3];
    ch5_level = ch_level[4];
    ch6_level = ch_level[5];
    ch7_level = ch_level[6];
    ch8_level = ch_level[7];
  end

  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      total_bytes <= 64'd0;
      total_stall_cycles <= 32'd0;
      total_underflows <= 32'd0;
      sample_index <= 32'd0;
      sample_cycle_count <= 32'd0;
      sample_bytes_accum <= 64'd0;
      sample_stalls_accum <= 32'd0;
      sample_underflows_accum <= 32'd0;
      sample_bytes_low <= 32'd0;
      sample_bytes_high <= 32'd0;
      sample_stalls <= 32'd0;
      sample_underflows <= 32'd0;
      sample_valid <= 1'b0;
      underflow_seen <= {CHANNELS{1'b0}};
      for(i = 0; i < CHANNELS; i = i + 1) begin
        ch_bytes[i] <= 64'd0;
        ch_stall_count[i] <= 32'd0;
        ch_underflow_count[i] <= 32'd0;
        ch_level[i] <= 16'd0;
        ch_min_level[i] <= FIFO_DEPTH[15:0];
        ch_max_level[i] <= 16'd0;
        ch_drain_count[i] <= 16'd0;
      end
    end else if(clear) begin
      total_bytes <= 64'd0;
      total_stall_cycles <= 32'd0;
      total_underflows <= 32'd0;
      sample_index <= 32'd0;
      sample_cycle_count <= 32'd0;
      sample_bytes_accum <= 64'd0;
      sample_stalls_accum <= 32'd0;
      sample_underflows_accum <= 32'd0;
      sample_bytes_low <= 32'd0;
      sample_bytes_high <= 32'd0;
      sample_stalls <= 32'd0;
      sample_underflows <= 32'd0;
      sample_valid <= 1'b0;
      underflow_seen <= {CHANNELS{1'b0}};
      for(i = 0; i < CHANNELS; i = i + 1) begin
        ch_bytes[i] <= 64'd0;
        ch_stall_count[i] <= 32'd0;
        ch_underflow_count[i] <= 32'd0;
        ch_level[i] <= 16'd0;
        ch_min_level[i] <= FIFO_DEPTH[15:0];
        ch_max_level[i] <= 16'd0;
        ch_drain_count[i] <= 16'd0;
      end
    end else begin
      sample_valid <= 1'b0;

      if(sample_period_cycles != 32'd0) begin
        if(sample_cycle_count + 32'd1 >= sample_period_cycles) begin
          sample_cycle_count <= 32'd0;
          sample_index <= sample_index + 32'd1;
          sample_bytes_low <= sample_bytes_accum[31:0];
          sample_bytes_high <= sample_bytes_accum[63:32];
          sample_stalls <= sample_stalls_accum;
          sample_underflows <= sample_underflows_accum;
          sample_bytes_accum <= 64'd0;
          sample_stalls_accum <= 32'd0;
          sample_underflows_accum <= 32'd0;
          sample_valid <= 1'b1;
        end else begin
          sample_cycle_count <= sample_cycle_count + 32'd1;
        end
      end

      if(s_axis_tvalid && !s_axis_tready) begin
        if(INTERLEAVED_MODE != 0) begin
          for(i = 0; i < CHANNELS; i = i + 1) begin
            if(ch_arm[i] && (ch_level[i] >= FIFO_DEPTH[15:0])) ch_stall_count[i] <= ch_stall_count[i] + 32'd1;
          end
        end else begin
          ch_stall_count[dm_sel] <= ch_stall_count[dm_sel] + 32'd1;
        end
        total_stall_cycles <= total_stall_cycles + 32'd1;
        sample_stalls_accum <= sample_stalls_accum + 32'd1;
      end

      if(beat_fire) begin
        if(INTERLEAVED_MODE != 0) begin
          for(i = 0; i < CHANNELS; i = i + 1) begin
            if(ch_arm[i]) ch_bytes[i] <= ch_bytes[i] + LANE_BYTES_U64;
          end
        end else begin
          ch_bytes[dm_sel] <= ch_bytes[dm_sel] + BEAT_BYTES_U64;
        end
        total_bytes <= total_bytes + BEAT_BYTES_U64;
        sample_bytes_accum <= sample_bytes_accum + BEAT_BYTES_U64;
      end

      for(i = 0; i < CHANNELS; i = i + 1) begin
        consume_due = 1'b0;
        fill_due = (INTERLEAVED_MODE != 0) ? (beat_fire && ch_arm[i]) : (beat_fire && (dm_sel == i[2:0]));
        next_level = ch_level[i];

        if(ch_arm[i]) begin
          if(ch_drain_count[i] + 16'd1 >= drain_div(i)) begin
            ch_drain_count[i] <= 16'd0;
            consume_due = 1'b1;
          end else begin
            ch_drain_count[i] <= ch_drain_count[i] + 16'd1;
          end
        end else begin
          ch_drain_count[i] <= 16'd0;
        end

        if(consume_due && fill_due) begin
          next_level = ch_level[i];
        end else if(consume_due) begin
          if(ch_level[i] != 16'd0) begin
            next_level = ch_level[i] - 16'd1;
          end else begin
            ch_underflow_count[i] <= ch_underflow_count[i] + 32'd1;
            total_underflows <= total_underflows + 32'd1;
            sample_underflows_accum <= sample_underflows_accum + 32'd1;
            underflow_seen[i] <= 1'b1;
          end
        end else if(fill_due && (ch_level[i] != FIFO_DEPTH[15:0])) begin
          next_level = ch_level[i] + 16'd1;
        end

        ch_level[i] <= next_level;
        if(next_level < ch_min_level[i]) ch_min_level[i] <= next_level;
        if(next_level > ch_max_level[i]) ch_max_level[i] <= next_level;
      end
    end
  end

  wire _unused = &{1'b0, s_axis_tdata};

endmodule
