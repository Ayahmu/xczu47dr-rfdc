`timescale 1ns/1ps

// Bulk waveform ingress in the DDR/UI clock domain.
//
// Input is a stream of complete, FCS-clean frames from the 512-bit frame
// FIFO.  The first word of a frame is the network header word; its bytes
// 42..63 are the bulk header:
//
//   42..45  "WBLK"
//   46..49  session        (little endian, like the rest of WAVECTR0)
//   50..57  byte offset into the session image, a multiple of 64
//   58..59  number of 64-byte words that follow (1..MAX_FRAME_WORDS)
//   60      chunk epoch
//   61..63  reserved
//
// Each following word is written to DDR_ADDR_BASE + offset as one 64-byte
// beat.  Bursts are split at 4 KiB boundaries as AXI requires.
//
// There is no per-frame acknowledgement.  The image is divided into 1 MiB
// chunks and a small RAM counts the words received for each chunk, so the
// host can ask which chunk is short and resend only that one:
//
//   CLEAR        arm a new session (latches session/total_bytes, zeroes the
//                counters; frames are dropped until it finishes)
//   CHUNK_RESET  zero one chunk and give it a new epoch; frames carrying an
//                older epoch for that chunk are written but not counted, so a
//                frame still in flight cannot make a resent chunk look whole
//   SCAN         report the first chunk whose count is not exactly right
//
// A frame may not cross a chunk boundary.  The host must not send the same
// frame twice within one epoch of an unfinished chunk.
module wave_bulk_ddr_writer #(
    parameter [63:0] DDR_ADDR_BASE = 64'd0,
    parameter integer MAX_FRAME_WORDS = 128
) (
    input  wire         clk,
    input  wire         rst_n,

    // Session, from the WAVECTR0 control parser.  enable is live; session and
    // total_bytes are latched by CLEAR.
    input  wire         enable,
    input  wire [31:0]  session,
    input  wire [63:0]  total_bytes,

    input  wire         ctl_start,
    input  wire [1:0]   ctl_cmd,          // 1 CLEAR, 2 CHUNK_RESET, 3 SCAN
    input  wire [20:0]  ctl_arg,          // CHUNK_RESET: {epoch[7:0], chunk[12:0]}
    output reg          ctl_busy,

    output wire         complete,
    output reg  [13:0]  complete_chunks,
    output reg  [31:0]  first_incomplete, // valid after SCAN; all ones when none
    output reg  [31:0]  frames_ok,
    output reg  [31:0]  frames_rejected,
    output reg  [31:0]  frames_duplicate,
    output reg  [31:0]  frames_stale,
    output reg          overrun,
    output reg          axi_error,

    input  wire [511:0] s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,

    output reg  [63:0]  m_axi_awaddr,
    output reg  [7:0]   m_axi_awlen,
    output reg          m_axi_awvalid,
    input  wire         m_axi_awready,
    output reg  [511:0] m_axi_wdata,
    output reg  [63:0]  m_axi_wstrb,
    output reg          m_axi_wlast,
    output reg          m_axi_wvalid,
    input  wire         m_axi_wready,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready
);
  localparam [1:0] CMD_CLEAR = 2'd1, CMD_CHUNK_RESET = 2'd2, CMD_SCAN = 2'd3;
  // 1 MiB chunks of 64-byte words; the image is below 8 GiB.
  localparam [14:0] CHUNK_FULL = 15'd16384, COUNT_OVER = 15'h7fff;

  // ------------------------------------------------------------ session
  reg        cfg_valid, clearing;
  reg [31:0] cfg_session;
  reg [33:0] cfg_total;
  reg [12:0] cfg_last_chunk;
  reg [14:0] cfg_last_words;
  reg [13:0] cfg_total_chunks;
  assign complete = cfg_valid && enable && !clearing && complete_chunks == cfg_total_chunks;

  // ------------------------------------------------------------ chunk RAM
  // {epoch[7:0], words[14:0]}.  Port A belongs to frame accounting, port B to
  // the control commands.
  (* ram_style = "block" *) reg [22:0] chunk_mem [0:8191];
  reg         a_we, b_we;
  reg  [12:0] a_waddr, b_addr;
  wire [12:0] a_addr;
  reg  [22:0] a_wdata, b_wdata, a_rdata, b_rdata;
  always @(posedge clk) begin
    if (a_we) chunk_mem[a_addr] <= a_wdata;
    a_rdata <= chunk_mem[a_addr];
  end
  always @(posedge clk) begin
    if (b_we) chunk_mem[b_addr] <= b_wdata;
    b_rdata <= chunk_mem[b_addr];
  end

  // ------------------------------------------------------------ frame path
  localparam [2:0] F_HDR = 3'd0, F_CHK0 = 3'd1, F_CHK1 = 3'd2, F_W = 3'd3,
                   F_AWNEXT = 3'd4, F_PAD = 3'd5, F_DROP = 3'd6;
  reg [2:0]  fstate;
  reg [31:0] h_session;
  reg [63:0] h_offset;
  reg [15:0] h_words;
  reg [7:0]  h_epoch;
  reg        h_tag_ok;
  reg        chk_basic;
  reg [34:0] chk_end;                   // offset + bytes
  reg [15:0] chk_chunk_end;             // word index within the chunk after the frame
  reg [33:0] cur_offset;                // byte offset of the next word to write
  reg [15:0] remaining;                 // words of the frame not yet accepted
  reg [6:0]  beats_left;                // beats of the open burst not yet accepted
  reg [6:0]  pad_left;

  // One register stage in front of the AXI W channel.
  wire w_can_push = !m_axi_wvalid || m_axi_wready;
  assign s_axis_tready = fstate == F_HDR || fstate == F_DROP || (fstate == F_W && w_can_push);
  wire s_fire = s_axis_tvalid && s_axis_tready;
  assign m_axi_bready = 1'b1;

  // Words up to the next 4 KiB boundary, at most 64.
  wire [6:0]  to_page_end = 7'd64 - {1'b0, cur_offset[11:6]};
  wire [6:0]  next_burst = (remaining < {9'd0, to_page_end}) ? remaining[6:0] : to_page_end;
  wire        aw_free = !m_axi_awvalid || m_axi_awready;

  reg         acc_valid;
  reg  [12:0] acc_chunk;
  reg  [14:0] acc_words, acc_expected;
  reg  [7:0]  acc_epoch;
  reg         acc_s1;
  assign a_addr = a_we ? a_waddr : acc_chunk;

  wire [14:0] a_count = a_rdata[14:0];
  wire [15:0] a_sum = {1'b0, a_count} + {1'b0, acc_words};
  reg         chunk_completed, chunk_uncompleted;

  // ------------------------------------------------------------ control
  localparam [2:0] C_IDLE = 3'd0, C_CLEAR = 3'd1, C_RST_RD = 3'd2, C_RST_WAIT = 3'd3,
                   C_RST_WR = 3'd4, C_SCAN_RD = 3'd5, C_SCAN_CMP = 3'd6, C_CFG = 3'd7;
  reg [2:0]  cstate;
  reg [12:0] c_index;
  reg [7:0]  c_epoch;
  reg [33:0] c_total_m1;
  wire [14:0] c_expected = (c_index == cfg_last_chunk) ? cfg_last_words : CHUNK_FULL;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fstate <= F_HDR;
      cfg_valid <= 1'b0; clearing <= 1'b0; cfg_session <= 0; cfg_total <= 0;
      cfg_last_chunk <= 0; cfg_last_words <= 0; cfg_total_chunks <= 0;
      complete_chunks <= 0; first_incomplete <= 0;
      frames_ok <= 0; frames_rejected <= 0; frames_duplicate <= 0; frames_stale <= 0;
      overrun <= 1'b0; axi_error <= 1'b0; ctl_busy <= 1'b0;
      m_axi_awaddr <= 0; m_axi_awlen <= 0; m_axi_awvalid <= 1'b0;
      m_axi_wstrb <= 0; m_axi_wlast <= 1'b0; m_axi_wvalid <= 1'b0;
      h_session <= 0; h_offset <= 0; h_words <= 0; h_epoch <= 0; h_tag_ok <= 1'b0;
      chk_basic <= 1'b0; chk_end <= 0; chk_chunk_end <= 0;
      cur_offset <= 0; remaining <= 0; beats_left <= 0; pad_left <= 0;
      acc_valid <= 1'b0; acc_chunk <= 0; acc_words <= 0; acc_expected <= 0; acc_epoch <= 0; acc_s1 <= 1'b0;
      a_we <= 1'b0; a_waddr <= 0; a_wdata <= 0; chunk_completed <= 1'b0; chunk_uncompleted <= 1'b0;
      b_we <= 1'b0; b_addr <= 0; b_wdata <= 0;
      cstate <= C_IDLE; c_index <= 0; c_epoch <= 0; c_total_m1 <= 0;
    end else begin
      // ---------------- AXI channel bookkeeping ----------------
      if (m_axi_awvalid && m_axi_awready) m_axi_awvalid <= 1'b0;
      if (m_axi_wvalid && m_axi_wready) m_axi_wvalid <= 1'b0;
      if (m_axi_bvalid && m_axi_bresp != 2'b00) axi_error <= 1'b1;

      // ---------------- frame path ----------------
      acc_valid <= 1'b0;
      case (fstate)
        F_HDR: if (s_fire) begin
          h_tag_ok  <= s_axis_tdata[42*8 +: 32] == {"K", "L", "B", "W"};
          h_session <= s_axis_tdata[46*8 +: 32];
          h_offset  <= s_axis_tdata[50*8 +: 64];
          h_words   <= s_axis_tdata[58*8 +: 16];
          h_epoch   <= s_axis_tdata[60*8 +: 8];
          if (s_axis_tlast) frames_rejected <= frames_rejected + 1'b1;
          else fstate <= F_CHK0;
        end
        // Two cycles of registered checks keep the wide compares off the
        // AXI handshake path.
        F_CHK0: begin
          chk_basic <= enable && cfg_valid && !clearing && h_tag_ok &&
                       h_session == cfg_session && h_offset[5:0] == 6'd0 &&
                       h_offset[63:34] == 30'd0 && h_words != 16'd0 &&
                       h_words <= MAX_FRAME_WORDS;
          chk_end <= {1'b0, h_offset[33:0]} + {13'd0, h_words, 6'd0};
          chk_chunk_end <= {2'b00, h_offset[19:6]} + h_words;
          fstate <= F_CHK1;
        end
        F_CHK1: begin
          if (chk_basic && chk_end <= {1'b0, cfg_total} && chk_chunk_end <= {1'b0, CHUNK_FULL}) begin
            cur_offset <= h_offset[33:0];
            remaining <= h_words;
            fstate <= F_AWNEXT;
          end else begin
            frames_rejected <= frames_rejected + 1'b1;
            fstate <= F_DROP;
          end
        end
        F_AWNEXT: if (aw_free) begin
          m_axi_awaddr <= DDR_ADDR_BASE + {30'd0, cur_offset};
          m_axi_awlen <= {1'b0, next_burst} - 8'd1;
          m_axi_awvalid <= 1'b1;
          beats_left <= next_burst;
          fstate <= F_W;
        end
        F_W: if (s_fire) begin
          m_axi_wstrb <= {64{1'b1}};
          m_axi_wlast <= beats_left == 7'd1;
          m_axi_wvalid <= 1'b1;
          cur_offset <= cur_offset + 34'd64;
          remaining <= remaining - 1'b1;
          beats_left <= beats_left - 1'b1;
          if (remaining == 16'd1) begin
            // Last word the header promised.
            if (s_axis_tlast) begin
              acc_valid <= 1'b1;
              acc_chunk <= h_offset[32:20];
              acc_words <= h_words[14:0];
              acc_epoch <= h_epoch;
              acc_expected <= (h_offset[32:20] == cfg_last_chunk) ? cfg_last_words : CHUNK_FULL;
              fstate <= F_HDR;
            end else begin
              frames_rejected <= frames_rejected + 1'b1;
              fstate <= F_DROP;
            end
          end else if (s_axis_tlast) begin
            // The frame ended early: finish the open burst with masked beats.
            frames_rejected <= frames_rejected + 1'b1;
            pad_left <= beats_left - 1'b1;
            fstate <= (beats_left == 7'd1) ? F_HDR : F_PAD;
          end else if (beats_left == 7'd1) begin
            fstate <= F_AWNEXT;
          end
        end
        F_PAD: if (w_can_push) begin
          m_axi_wstrb <= 64'd0;
          m_axi_wlast <= pad_left == 7'd1;
          m_axi_wvalid <= 1'b1;
          pad_left <= pad_left - 1'b1;
          if (pad_left == 7'd1) fstate <= F_HDR;
        end
        F_DROP: if (s_fire && s_axis_tlast) fstate <= F_HDR;
        default: fstate <= F_HDR;
      endcase

      // ---------------- chunk accounting (port A) ----------------
      // acc_valid presents the read address, acc_s1 sees the entry one cycle
      // later and registers the update, the write lands the cycle after.
      // Frames are at least four cycles apart, so the stages never overlap.
      acc_s1 <= acc_valid;
      a_we <= 1'b0; chunk_completed <= 1'b0;
      if (acc_s1) begin
        a_waddr <= acc_chunk;
        if (a_rdata[22:15] != acc_epoch) begin
          frames_stale <= frames_stale + 1'b1;
        end else if (a_count == acc_expected) begin
          frames_duplicate <= frames_duplicate + 1'b1;
        end else begin
          frames_ok <= frames_ok + 1'b1;
          a_we <= 1'b1;
          if (a_count == COUNT_OVER || a_sum > {1'b0, acc_expected}) begin
            a_wdata <= {acc_epoch, COUNT_OVER};
            overrun <= 1'b1;
          end else begin
            a_wdata <= {acc_epoch, a_sum[14:0]};
            chunk_completed <= a_sum[14:0] == acc_expected;
          end
        end
      end

      // ---------------- control commands (port B) ----------------
      b_we <= 1'b0; chunk_uncompleted <= 1'b0;
      case (cstate)
        C_IDLE: if (ctl_start) begin
          ctl_busy <= 1'b1;
          case (ctl_cmd)
            CMD_CLEAR: begin
              clearing <= 1'b1; cfg_valid <= 1'b0;
              c_index <= 13'd0; b_addr <= 13'd0; b_wdata <= 23'd0; b_we <= 1'b1;
              cstate <= C_CLEAR;
            end
            CMD_CHUNK_RESET: begin
              c_index <= ctl_arg[12:0]; c_epoch <= ctl_arg[20:13];
              b_addr <= ctl_arg[12:0];
              cstate <= C_RST_RD;
            end
            CMD_SCAN: begin
              c_index <= 13'd0; b_addr <= 13'd0;
              cstate <= C_SCAN_RD;
            end
            default: ctl_busy <= 1'b0;
          endcase
        end
        C_CLEAR: begin
          // The sweep gives session/total_bytes time to settle after BEGIN.
          c_total_m1 <= total_bytes[33:0] - 34'd1;
          if (c_index == 13'd8191) cstate <= C_CFG;
          else begin
            c_index <= c_index + 1'b1; b_addr <= c_index + 1'b1; b_wdata <= 23'd0; b_we <= 1'b1;
          end
        end
        C_CFG: begin
          cfg_session <= session;
          cfg_total <= total_bytes[33:0];
          cfg_last_chunk <= c_total_m1[32:20];
          cfg_last_words <= (total_bytes[19:6] == 14'd0) ? CHUNK_FULL : {1'b0, total_bytes[19:6]};
          cfg_total_chunks <= {1'b0, c_total_m1[32:20]} + 14'd1;
          complete_chunks <= 14'd0; first_incomplete <= 32'd0;
          frames_ok <= 0; frames_rejected <= 0; frames_duplicate <= 0; frames_stale <= 0;
          overrun <= 1'b0; axi_error <= 1'b0;
          cfg_valid <= total_bytes[63:34] == 30'd0 && total_bytes[33:0] != 34'd0;
          clearing <= 1'b0; ctl_busy <= 1'b0; cstate <= C_IDLE;
        end
        C_RST_RD: cstate <= C_RST_WAIT;
        C_RST_WAIT: begin
          chunk_uncompleted <= cfg_valid && b_rdata[14:0] == c_expected;
          b_wdata <= {c_epoch, 15'd0}; b_we <= 1'b1;
          cstate <= C_RST_WR;
        end
        C_RST_WR: begin ctl_busy <= 1'b0; cstate <= C_IDLE; end
        C_SCAN_RD: cstate <= C_SCAN_CMP;
        C_SCAN_CMP: begin
          if (!cfg_valid || b_rdata[14:0] != c_expected) begin
            first_incomplete <= {19'd0, c_index}; ctl_busy <= 1'b0; cstate <= C_IDLE;
          end else if (c_index == cfg_last_chunk) begin
            first_incomplete <= 32'hffffffff; ctl_busy <= 1'b0; cstate <= C_IDLE;
          end else begin
            c_index <= c_index + 1'b1; b_addr <= c_index + 1'b1; cstate <= C_SCAN_RD;
          end
        end
        default: cstate <= C_IDLE;
      endcase

      if (cstate != C_CFG && (chunk_completed != chunk_uncompleted))
        complete_chunks <= chunk_completed ? complete_chunks + 1'b1 : complete_chunks - 1'b1;
    end
  end

  // The 512-bit write data register carries no reset; WVALID qualifies it.
  always @(posedge clk) begin
    if (fstate == F_W && s_fire) m_axi_wdata <= s_axis_tdata;
  end
endmodule
