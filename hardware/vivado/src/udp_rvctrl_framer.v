`timescale 1ns/1ps

// RFCTRL2 control-plane packet framer (restored).
//
// The unified waveform refactor split the old udp_waveform_ddr_writer into
// waveform_upload_writer (WAVECTR0 upload path) but dropped the RFCTRL2
// classification/framing branch, leaving pl_riscv_control_v1's rvctrl_* input
// undriven.  That FSM is the only handler for NETWORK_GET / HELLO / STATUS /
// TDC_REG / RFDC_APPLY, so board discovery and identity silently died.
//
// This module re-adds exactly that branch: it recognizes the RFCTRL2 magic,
// strips it, and re-frames the remaining 64-bit words into the tfirst/tlast/
// word_count/protocol contract pl_riscv_control_v1 expects.  It is a faithful
// port of the ST_RVCTRL1_* state machine from udp_waveform_ddr_writer.v, with
// the waveform/instruction/legacy paths removed and rvctrl2_mode hardwired so
// protocol is always RF2 (2'd2).
//
// Wire format (RFCTRL2, see software/dr47/protocol.py pack_rfctrl2_packet):
//   word0 = 64'h00324C5254434652 (magic)
//   word1 = hdr0 = {opcode[63:32], flags[31:16], version[15:0]}
//   word2 = hdr1 = {payload_bytes[63:32], seq[31:0]}
//   word3.. = payload (zero-padded to 8-byte boundary)
//
// Emitted stream (one 64-bit word/cycle, no ready handshake — the consumer
// pl_riscv_control_v1 accepts whenever it is not mid-response):
//   tfirst cycle: hdr0, tfirst=1
//   next:         hdr1
//   then:         payload words, tlast on the final word
//   word_count    = 4 + ceil(payload_bytes/4)   (32-bit units; parser fills
//                  two 32-bit slots per 64-bit word)
module udp_rvctrl_framer (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         udp_tvalid,
    input  wire [63:0]  udp_tdata,
    input  wire         udp_tlast,
    output reg          rvctrl_tvalid,
    output reg  [63:0]  rvctrl_tdata,
    output reg          rvctrl_tfirst,
    output reg          rvctrl_tlast,
    output reg  [31:0]  rvctrl_word_count,
    output reg  [1:0]   rvctrl_protocol
);
  localparam [63:0] RFCTRL2_MAGIC = 64'h00324C5254434652;
  localparam [1:0]  RVCTRL_PROTOCOL_RF2 = 2'd2;

  localparam [3:0] ST_IDLE      = 4'd0;
  localparam [3:0] ST_HDR0      = 4'd1;
  localparam [3:0] ST_HDR1      = 4'd2;
  localparam [3:0] ST_EMIT_HDR1 = 4'd3;
  localparam [3:0] ST_PAYLOAD   = 4'd4;
  localparam [3:0] ST_DROP      = 4'd5;

  reg [3:0]  state;
  reg [63:0] hdr0_word;
  reg [63:0] hdr1_word;
  reg [63:0] skid_word;
  reg        skid_valid;
  reg [31:0] payload_words_left;
  reg [31:0] word_count;
  reg        nonzero;
  reg        more_than_one;

  // payload_bytes from the INCOMING hdr1 word (udp_tdata[63:32]), not the
  // registered hdr1_word — the old framer used udp_tdata here for the same
  // reason: hdr1_word is still the previous value during ST_HDR1.
  wire [31:0] payload_bytes      = udp_tdata[63:32];
  wire [31:0] rounded_bytes      = payload_bytes + 32'd7;
  wire [31:0] loaded_words       = rounded_bytes >> 3;   // ceil(payload_bytes/8)
  wire [31:0] framed_word_count  = 32'd4 + ((payload_bytes + 32'd3) >> 2);

  wire rfctrl2_magic = (udp_tdata == RFCTRL2_MAGIC);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state           <= ST_IDLE;
      rvctrl_tvalid   <= 1'b0;
      rvctrl_tdata    <= 64'd0;
      rvctrl_tfirst   <= 1'b0;
      rvctrl_tlast    <= 1'b0;
      rvctrl_word_count <= 32'd0;
      rvctrl_protocol <= 2'd0;
      hdr0_word       <= 64'd0;
      hdr1_word       <= 64'd0;
      skid_word       <= 64'd0;
      skid_valid      <= 1'b0;
      payload_words_left <= 32'd0;
      word_count      <= 32'd0;
      nonzero         <= 1'b0;
      more_than_one   <= 1'b0;
    end else begin
      // Default: no emit this cycle.
      rvctrl_tvalid <= 1'b0;
      rvctrl_tfirst <= 1'b0;
      rvctrl_tlast  <= 1'b0;

      case (state)
        ST_IDLE: begin
          if (udp_tvalid && rfctrl2_magic && !udp_tlast) begin
            state <= ST_HDR0;
          end
        end

        ST_HDR0: begin
          if (udp_tvalid) begin
            hdr0_word <= udp_tdata;
            state <= udp_tlast ? ST_DROP : ST_HDR1;
          end
        end

        ST_HDR1: begin
          if (udp_tvalid) begin
            hdr1_word <= udp_tdata;
            payload_words_left <= loaded_words;
            nonzero <= (loaded_words != 32'd0);
            more_than_one <= (loaded_words > 32'd1);
            word_count <= framed_word_count;
            // Emit buffered hdr0 now that hdr1 reveals the exact payload length.
            rvctrl_tvalid <= 1'b1;
            rvctrl_tdata  <= hdr0_word;
            rvctrl_tfirst <= 1'b1;
            rvctrl_tlast  <= 1'b0;
            rvctrl_word_count <= framed_word_count;
            rvctrl_protocol <= RVCTRL_PROTOCOL_RF2;
            state <= ST_EMIT_HDR1;
          end
        end

        ST_EMIT_HDR1: begin
          rvctrl_tvalid <= 1'b1;
          rvctrl_tdata  <= hdr1_word;
          rvctrl_tfirst <= 1'b0;
          rvctrl_tlast  <= !nonzero;
          rvctrl_word_count <= word_count;
          rvctrl_protocol <= RVCTRL_PROTOCOL_RF2;
          if (!nonzero) begin
            skid_valid <= 1'b0;
            state <= ST_IDLE;
          end else begin
            if (udp_tvalid) begin
              // First payload word already arrived; skid it.
              skid_word <= udp_tdata;
              skid_valid <= 1'b1;
              payload_words_left <= payload_words_left - 32'd1;
              nonzero <= more_than_one;
              more_than_one <= (payload_words_left > 32'd2);
            end
            state <= ST_PAYLOAD;
          end
        end

        ST_PAYLOAD: begin
          if (skid_valid) begin
            rvctrl_tvalid <= 1'b1;
            rvctrl_tdata  <= skid_word;
            rvctrl_tfirst <= 1'b0;
            rvctrl_tlast  <= !nonzero || (!more_than_one && !udp_tvalid);
            rvctrl_word_count <= word_count;
            rvctrl_protocol <= RVCTRL_PROTOCOL_RF2;
            if (udp_tvalid && nonzero) begin
              skid_word <= udp_tdata;
              skid_valid <= 1'b1;
              payload_words_left <= payload_words_left - 32'd1;
              nonzero <= more_than_one;
              more_than_one <= (payload_words_left > 32'd2);
              state <= ST_PAYLOAD;
            end else begin
              skid_valid <= 1'b0;
              state <= !nonzero ? ST_IDLE : ST_PAYLOAD;
            end
          end else if (udp_tvalid && nonzero) begin
            rvctrl_tvalid <= 1'b1;
            rvctrl_tdata  <= udp_tdata;
            rvctrl_tfirst <= 1'b0;
            rvctrl_tlast  <= !more_than_one;
            rvctrl_word_count <= word_count;
            rvctrl_protocol <= RVCTRL_PROTOCOL_RF2;
            if (!more_than_one) begin
              payload_words_left <= 32'd0;
              nonzero <= 1'b0;
              more_than_one <= 1'b0;
              state <= ST_IDLE;
            end else begin
              payload_words_left <= payload_words_left - 32'd1;
              nonzero <= 1'b1;
              more_than_one <= (payload_words_left > 32'd2);
              state <= ST_PAYLOAD;
            end
          end
        end

        ST_DROP: begin
          // Truncated/errant packet: drain to end of frame.
          if (udp_tvalid && udp_tlast)
            state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end
endmodule
