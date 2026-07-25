`timescale 1ns / 1ps

module rfctrl2_udp_response_tx #(
    parameter [31:0] DEFAULT_DEST_IP = 32'hC0A8_0103,
    parameter [15:0] DEFAULT_DEST_PORT = 16'd1234,
    parameter [15:0] DEFAULT_SOURCE_PORT = 16'd1234
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        rx_header_fire,
    input  wire [31:0] rx_source_ip,
    input  wire [15:0] rx_source_port,
    input  wire [15:0] rx_dest_port,
    input  wire        rx_payload_fire,
    input  wire [63:0] rx_payload_data,

    input  wire        tx_path_enable,
    input  wire        tx_header_ready,
    input  wire        tx_payload_ready,

    input  wire        response_valid,
    input  wire [63:0] response_data,
    input  wire        response_last,
    input  wire [15:0] response_word_count,
    output wire        response_ready,

    output wire        tx_active,
    output reg         tx_header_valid,
    output reg  [31:0] tx_dest_ip,
    output reg  [15:0] tx_source_port,
    output reg  [15:0] tx_dest_port,
    output reg  [15:0] tx_length,
    output wire [63:0] tx_payload_data,
    output wire        tx_payload_valid,
    output wire        tx_payload_last,

    output wire        request_inflight,
    output wire [1:0]  dbg_state
);

  localparam [1:0] ST_IDLE = 2'd0;
  localparam [1:0] ST_HEADER = 2'd1;
  localparam [1:0] ST_PAYLOAD = 2'd2;

  reg [1:0] state = ST_IDLE;
  reg [31:0] pending_source_ip = DEFAULT_DEST_IP;
  reg [15:0] pending_source_port = DEFAULT_DEST_PORT;
  reg [15:0] pending_dest_port = DEFAULT_SOURCE_PORT;
  reg [31:0] request_source_ip = DEFAULT_DEST_IP;
  reg [15:0] request_source_port = DEFAULT_DEST_PORT;
  reg [15:0] request_dest_port = DEFAULT_SOURCE_PORT;
  reg        request_inflight_reg = 1'b0;
  reg [15:0] payload_words = 16'd0;
  reg [15:0] payload_index = 16'd0;

  wire request_magic =
      (rx_payload_data == 64'h00304C5254435652) ||
      (rx_payload_data == 64'h00314C5254435652) ||
      (rx_payload_data == 64'h00324C5254434652);
  wire response_fire = response_valid && response_ready;
  wire final_response_word = response_last ||
      (payload_words != 16'd0 && payload_index == payload_words - 16'd1);

  assign tx_active = state != ST_IDLE;
  assign response_ready = (state == ST_PAYLOAD) && tx_payload_ready;
  assign tx_payload_data = response_data;
  assign tx_payload_valid = (state == ST_PAYLOAD) && response_valid;
  assign tx_payload_last = tx_payload_valid && final_response_word;
  assign request_inflight = request_inflight_reg;
  assign dbg_state = state;

  always @(posedge clk) begin
    if (rst) begin
      state <= ST_IDLE;
      pending_source_ip <= DEFAULT_DEST_IP;
      pending_source_port <= DEFAULT_DEST_PORT;
      pending_dest_port <= DEFAULT_SOURCE_PORT;
      request_source_ip <= DEFAULT_DEST_IP;
      request_source_port <= DEFAULT_DEST_PORT;
      request_dest_port <= DEFAULT_SOURCE_PORT;
      request_inflight_reg <= 1'b0;
      payload_words <= 16'd0;
      payload_index <= 16'd0;
      tx_header_valid <= 1'b0;
      tx_dest_ip <= DEFAULT_DEST_IP;
      tx_source_port <= DEFAULT_SOURCE_PORT;
      tx_dest_port <= DEFAULT_DEST_PORT;
      tx_length <= 16'd8;
    end else begin
      if (rx_header_fire) begin
        pending_source_ip <= rx_source_ip;
        pending_source_port <= rx_source_port;
        pending_dest_port <= rx_dest_port;
      end

      if (!request_inflight_reg && rx_payload_fire && request_magic) begin
        // Some UDP pipelines present the header handshake and first payload
        // beat together. In that case the current header, not the previous
        // packet's pending context, is the response destination.
        request_source_ip <= rx_header_fire ? rx_source_ip : pending_source_ip;
        request_source_port <= rx_header_fire ? rx_source_port : pending_source_port;
        request_dest_port <= rx_header_fire ? rx_dest_port : pending_dest_port;
        request_inflight_reg <= 1'b1;
      end

      case (state)
        ST_IDLE: begin
          tx_header_valid <= 1'b0;
          payload_index <= 16'd0;
          if (tx_path_enable && response_valid && response_word_count != 16'd0) begin
            payload_words <= response_word_count;
            tx_dest_ip <= request_inflight_reg ? request_source_ip : pending_source_ip;
            tx_source_port <= request_inflight_reg ? request_dest_port : pending_dest_port;
            tx_dest_port <= request_inflight_reg ? request_source_port : pending_source_port;
            tx_length <= (response_word_count << 3) + 16'd8;
            tx_header_valid <= 1'b1;
            state <= ST_HEADER;
          end
        end

        ST_HEADER: begin
          if (tx_header_valid && tx_header_ready) begin
            tx_header_valid <= 1'b0;
            state <= ST_PAYLOAD;
          end
        end

        ST_PAYLOAD: begin
          if (response_fire) begin
            if (final_response_word) begin
              payload_index <= 16'd0;
              request_inflight_reg <= 1'b0;
              state <= ST_IDLE;
            end else begin
              payload_index <= payload_index + 16'd1;
            end
          end
        end

        default: begin
          state <= ST_IDLE;
          tx_header_valid <= 1'b0;
          payload_index <= 16'd0;
        end
      endcase
    end
  end
endmodule
