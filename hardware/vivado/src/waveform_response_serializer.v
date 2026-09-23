`timescale 1ns/1ps

// One immutable WAVERSP0 snapshot. event_valid is accepted only while !busy;
// the producer holds its event until then. The output index advances exactly
// on VALID && READY. Combinationally reading the registered word bank avoids
// the old one-cycle-late output register (which duplicated the first word and
// omitted the last word under back-to-back READY).
module waveform_response_serializer (
    input wire clk, input wire rst_n,
    input wire event_valid,
    input wire [31:0] event_seq, input wire [31:0] event_opcode,
    input wire [15:0] event_status, input wire [31:0] event_error_code,
    input wire [31:0] event_session, input wire [31:0] event_state,
    input wire [31:0] event_descriptor, input wire [63:0] event_error_offset,
    input wire [31:0] event_ack_packet_seq,
    input wire [31:0] event_next_expected_sequence,
    input wire [63:0] event_received_bytes,
    input wire [63:0] event_first_error_offset,
    input wire [31:0] event_expected_crc, input wire [31:0] event_actual_crc,
    input wire [31:0] event_current_beat, input wire [31:0] event_loop_position,
    input wire [31:0] event_loop_count, input wire [7:0] event_channel_mask,
    input wire [7:0] event_layout, input wire [127:0] event_fifo_levels,
    input wire [31:0] event_error_count, input wire [31:0] event_underflow_count,
    input wire [31:0] event_trigger_seen_count,
    input wire [31:0] event_trigger_dropped_count,
    input wire [31:0] event_trigger_fire_count,
    output wire response_valid, output wire [63:0] response_data,
    output wire response_last, output wire [15:0] response_word_count,
    input wire response_ready, output wire busy
);
  reg [63:0] words [0:12];
  reg [4:0] word_count;
  reg [4:0] word_index;
  reg active;
  integer i;
  assign busy = active;
  assign response_valid = active;
  assign response_data = active ? words[word_index] : 64'd0;
  assign response_last = active && word_index == word_count - 1'b1;
  assign response_word_count = active ? {12'd0, word_count} : 16'd0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active <= 0; word_count <= 0; word_index <= 0;
      for (i=0;i<13;i=i+1) words[i] <= 0;
    end else if (!active && event_valid) begin
      words[0] <= 64'h5741564552535030;
      words[1] <= {event_opcode, event_status, 16'd1};
      words[2] <= {(event_opcode == 2 ? 32'd60 : event_opcode == 8 ? 32'd80 : 32'd28), event_seq};
      words[3] <= {event_state, event_session};
      words[4] <= {event_error_code, 16'd0, event_status};
      words[5] <= {event_error_offset[31:0], event_descriptor};
      if (event_opcode == 2) begin
        words[6] <= {event_ack_packet_seq, event_error_offset[63:32]};
        words[7] <= {event_received_bytes[31:0], event_next_expected_sequence};
        words[8] <= {event_first_error_offset[31:0], event_received_bytes[63:32]};
        words[9] <= {event_expected_crc, event_first_error_offset[63:32]};
        words[10] <= {32'd0, event_actual_crc};
        word_count <= 5'd11;
      end else if (event_opcode == 8) begin
        // The common payload is 28 bytes, so current_beat starts in the
        // upper half of words[6]. The status extension then uses thirteen
        // little-endian 32-bit fields through words[12], for 80 payload
        // bytes including the common fields.
        words[6] <= {event_current_beat, event_error_offset[63:32]};
        words[7] <= {event_loop_count, event_loop_position};
        words[8] <= {{event_fifo_levels[31:16], event_fifo_levels[15:0]},
                     16'd0, event_layout, event_channel_mask};
        words[9] <= {event_fifo_levels[95:64], event_fifo_levels[63:32]};
        words[10] <= {event_error_count, event_fifo_levels[127:96]};
        words[11] <= {event_trigger_seen_count, event_underflow_count};
        words[12] <= {event_trigger_fire_count, event_trigger_dropped_count};
        word_count <= 5'd13;
      end else begin
        words[6] <= {32'd0, event_error_offset[63:32]};
        word_count <= 5'd7;
      end
      word_index <= 0; active <= 1;
    end else if (active && response_ready) begin
      if (word_index == word_count - 1'b1) begin
        active <= 0; word_index <= 0;
      end else word_index <= word_index + 1'b1;
    end
  end
endmodule
