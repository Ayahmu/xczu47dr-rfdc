`timescale 1ns / 1ps

module udp_waveform_ddr_writer #(
    parameter [63:0] MAGIC = 64'h5741564544445230,
    parameter [63:0] BULK_MAGIC = 64'h5741564553545230,
    parameter [63:0] TRIGGER_WORD = 64'h3152454747495254,
    parameter [63:0] RVCTRL_MAGIC = 64'h00304C5254435652,
    parameter [63:0] RVCTRL1_MAGIC = 64'h00314C5254435652,
    parameter [63:0] RFCTRL2_MAGIC = 64'h00324C5254434652,
    parameter [63:0] LEGACY_TRIGGER_HEADER = 64'h0000000200000002,
    parameter [63:0] LEGACY_TRIGGER_GO = 64'h0000000000004F47,
    parameter [63:0] DDR_ADDR_BASE = 64'd0,
    parameter FIFO_DEPTH_LOG2 = 4
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         udp_tvalid,
    input  wire [63:0]  udp_tdata,

    output reg          instr_tvalid,
    output reg  [63:0]  instr_tdata,
    output reg          trigger_pulse,
    output reg          rvctrl_tvalid,
    output reg  [63:0]  rvctrl_tdata,
    output reg          rvctrl_tfirst,
    output reg          rvctrl_tlast,
    output reg  [31:0]  rvctrl_word_count,
    output reg  [1:0]   rvctrl_protocol,

    output reg  [63:0]  m_axi_awaddr,
    output wire [1:0]   m_axi_awburst,
    output wire [3:0]   m_axi_awcache,
    output wire [7:0]   m_axi_awlen,
    output wire [0:0]   m_axi_awlock,
    output wire [2:0]   m_axi_awprot,
    output wire [3:0]   m_axi_awqos,
    input  wire         m_axi_awready,
    output wire [2:0]   m_axi_awsize,
    output reg          m_axi_awvalid,

    output reg  [255:0] m_axi_wdata,
    output wire         m_axi_wlast,
    input  wire         m_axi_wready,
    output wire [31:0]  m_axi_wstrb,
    output reg          m_axi_wvalid,

    output wire         m_axi_bready,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,

    output reg          dbg_wave_pkt,
    output reg          dbg_instr_word,
    output reg  [3:0]   dbg_state,
    output reg  [31:0]  dbg_write_count,
    output reg  [31:0]  dbg_bresp_count,
    output wire [31:0]  dbg_drop_count_o,
    output wire [31:0]  dbg_align_error_count_o,
    output wire [15:0]  dbg_fifo_count_o,
    output reg  [31:0]  dbg_resync_count,
    output reg  [1:0]   dbg_last_bresp,
    output reg  [63:0]  dbg_last_addr,
    output reg  [255:0] dbg_last_wdata
);

  localparam [FIFO_DEPTH_LOG2:0] FIFO_DEPTH = (1 << FIFO_DEPTH_LOG2);

  localparam [3:0] ST_IDLE     = 4'd0;
  localparam [3:0] ST_ADDR     = 4'd1;
  localparam [3:0] ST_DATA_LOW = 4'd2;
  localparam [3:0] ST_DATA_1   = 4'd3;
  localparam [3:0] ST_DATA_2   = 4'd4;
  localparam [3:0] ST_DATA_3   = 4'd5;
  localparam [3:0] ST_BULK_COUNT = 4'd6;
  localparam [3:0] ST_RVCTRL_COUNT = 4'd7;
  localparam [3:0] ST_RVCTRL1_HDR0 = 4'd8;
  localparam [3:0] ST_RVCTRL1_HDR1 = 4'd9;
  localparam [3:0] ST_RVCTRL1_PAYLOAD = 4'd10;
  localparam [3:0] ST_RVCTRL1_EMIT_HDR1 = 4'd11;

  localparam [1:0] RVCTRL_PROTOCOL_LEGACY = 2'd0;
  localparam [1:0] RVCTRL_PROTOCOL_V1     = 2'd1;
  localparam [1:0] RVCTRL_PROTOCOL_RF2    = 2'd2;

  reg [63:0] write_addr;
  reg [63:0] data_word0;
  reg [63:0] data_word1;
  reg [63:0] data_word2;

  reg [63:0]  fifo_addr [0:(1 << FIFO_DEPTH_LOG2)-1];
  reg [255:0] fifo_data [0:(1 << FIFO_DEPTH_LOG2)-1];
  reg [FIFO_DEPTH_LOG2-1:0] fifo_wr_ptr;
  reg [FIFO_DEPTH_LOG2-1:0] fifo_rd_ptr;
  reg [FIFO_DEPTH_LOG2:0] fifo_count;
  reg [31:0] dbg_drop_count;
  reg [31:0] dbg_align_error_count;
  reg write_resp_pending;
  reg drop_legacy_trigger_payload;
  reg bulk_mode;
  reg [31:0] bulk_words_left;
  reg [31:0] rvctrl_words_left;
  reg [31:0] rvctrl_total_words;
  reg [31:0] rvctrl1_payload_words_left;
  reg [31:0] rvctrl1_word_count;
  reg [63:0] rvctrl1_hdr0_word;
  reg [63:0] rvctrl1_hdr1_word;
  reg [63:0] rvctrl1_skid_word;
  reg        rvctrl1_skid_valid;
  reg        rvctrl2_mode;

  wire fifo_full = fifo_count == FIFO_DEPTH;
  wire fifo_empty = fifo_count == {FIFO_DEPTH_LOG2+1{1'b0}};
  wire axi_idle = !m_axi_awvalid && !m_axi_wvalid;
  wire launch_write = axi_idle && !write_resp_pending && !fifo_empty;
  wire pop_write = launch_write;
  wire waveform_magic = (udp_tdata == MAGIC) || (udp_tdata == BULK_MAGIC);
  wire resync_word = udp_tvalid && waveform_magic && (dbg_state != ST_IDLE) &&
                     (dbg_state != ST_RVCTRL_COUNT) &&
                     (dbg_state != ST_RVCTRL1_HDR0) &&
                     (dbg_state != ST_RVCTRL1_HDR1) &&
                     (dbg_state != ST_RVCTRL1_EMIT_HDR1) &&
                     (dbg_state != ST_RVCTRL1_PAYLOAD) &&
                     (rvctrl_words_left == 32'd0) &&
                     (rvctrl1_payload_words_left == 32'd0);
  wire rvctrl_magic = (udp_tdata == RVCTRL_MAGIC);
  wire rvctrl1_magic = (udp_tdata == RVCTRL1_MAGIC);
  wire rfctrl2_magic = (udp_tdata == RFCTRL2_MAGIC);
  wire write_addr_aligned = (write_addr[4:0] == 5'd0);
  wire push_write = udp_tvalid && !resync_word && (dbg_state == ST_DATA_3) && write_addr_aligned && (!fifo_full || pop_write);
  wire trigger_word = (udp_tdata == TRIGGER_WORD) || (udp_tdata == LEGACY_TRIGGER_HEADER);
  wire trigger_word_in_idle = udp_tvalid && (dbg_state == ST_IDLE) && trigger_word;
  wire drop_legacy_go_word = udp_tvalid && (dbg_state == ST_IDLE) && drop_legacy_trigger_payload && (udp_tdata == LEGACY_TRIGGER_GO);
  wire aw_fire = m_axi_awvalid && m_axi_awready;
  wire w_fire = m_axi_wvalid && m_axi_wready;
  wire b_fire = m_axi_bvalid && m_axi_bready;

  assign m_axi_awburst = 2'b01;
  assign m_axi_awcache = 4'b0011;
  assign m_axi_awlen   = 8'd0;
  assign m_axi_awlock  = 1'b0;
  assign m_axi_awprot  = 3'b000;
  assign m_axi_awqos   = 4'b0000;
  assign m_axi_awsize  = 3'b101;

  assign m_axi_wlast   = 1'b1;
  assign m_axi_wstrb   = 32'hffff_ffff;
  assign m_axi_bready  = 1'b1;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      instr_tvalid  <= 1'b0;
      instr_tdata   <= 64'd0;
      trigger_pulse <= 1'b0;
      rvctrl_tvalid <= 1'b0;
      rvctrl_tdata <= 64'd0;
      rvctrl_tfirst <= 1'b0;
      rvctrl_tlast <= 1'b0;
      rvctrl_word_count <= 32'd0;
      rvctrl_protocol <= RVCTRL_PROTOCOL_LEGACY;
      m_axi_awaddr  <= 64'd0;
      m_axi_awvalid <= 1'b0;
      m_axi_wdata   <= 256'd0;
      m_axi_wvalid  <= 1'b0;
      dbg_wave_pkt  <= 1'b0;
      dbg_instr_word <= 1'b0;
      dbg_state     <= ST_IDLE;
      dbg_write_count <= 32'd0;
      dbg_bresp_count <= 32'd0;
      dbg_last_bresp  <= 2'd0;
      dbg_last_addr   <= 64'd0;
      dbg_last_wdata  <= 256'd0;
      fifo_wr_ptr <= {FIFO_DEPTH_LOG2{1'b0}};
      fifo_rd_ptr <= {FIFO_DEPTH_LOG2{1'b0}};
      fifo_count  <= {FIFO_DEPTH_LOG2+1{1'b0}};
      dbg_drop_count <= 32'd0;
      dbg_align_error_count <= 32'd0;
      dbg_resync_count <= 32'd0;
      write_resp_pending <= 1'b0;
      drop_legacy_trigger_payload <= 1'b0;
      bulk_mode <= 1'b0;
      bulk_words_left <= 32'd0;
      rvctrl_words_left <= 32'd0;
      rvctrl_total_words <= 32'd0;
      rvctrl1_payload_words_left <= 32'd0;
      rvctrl1_word_count <= 32'd0;
      rvctrl1_hdr0_word <= 64'd0;
      rvctrl1_hdr1_word <= 64'd0;
      rvctrl1_skid_word <= 64'd0;
      rvctrl1_skid_valid <= 1'b0;
      rvctrl2_mode <= 1'b0;
      write_addr   <= 64'd0;
      data_word0   <= 64'd0;
      data_word1   <= 64'd0;
      data_word2   <= 64'd0;
    end else begin
      instr_tvalid  <= 1'b0;
      trigger_pulse <= 1'b0;
      rvctrl_tvalid <= 1'b0;
      rvctrl_tfirst <= 1'b0;
      rvctrl_tlast <= 1'b0;
      rvctrl_protocol <= RVCTRL_PROTOCOL_LEGACY;
      dbg_wave_pkt  <= 1'b0;
      dbg_instr_word <= 1'b0;
      if (udp_tvalid && dbg_state == ST_IDLE && drop_legacy_trigger_payload && (udp_tdata != LEGACY_TRIGGER_GO)) begin
        drop_legacy_trigger_payload <= 1'b0;
      end

      if (aw_fire) begin
        m_axi_awvalid <= 1'b0;
      end
      if (w_fire) begin
        m_axi_wvalid <= 1'b0;
      end
      if (b_fire) begin
        dbg_bresp_count <= dbg_bresp_count + 32'd1;
        dbg_last_bresp  <= m_axi_bresp;
        write_resp_pending <= 1'b0;
      end

      if (launch_write) begin
        m_axi_awaddr  <= DDR_ADDR_BASE + fifo_addr[fifo_rd_ptr];
        m_axi_awvalid <= 1'b1;
        m_axi_wdata   <= fifo_data[fifo_rd_ptr];
        m_axi_wvalid  <= 1'b1;
        dbg_last_addr  <= DDR_ADDR_BASE + fifo_addr[fifo_rd_ptr];
        dbg_last_wdata <= fifo_data[fifo_rd_ptr];
        fifo_rd_ptr <= fifo_rd_ptr + {{FIFO_DEPTH_LOG2-1{1'b0}}, 1'b1};
        write_resp_pending <= 1'b1;
      end

      if (drop_legacy_go_word) begin
        drop_legacy_trigger_payload <= 1'b0;
      end else if (trigger_word_in_idle) begin
        trigger_pulse <= 1'b1;
        drop_legacy_trigger_payload <= (udp_tdata == LEGACY_TRIGGER_HEADER);
      end else if (resync_word) begin
        dbg_state <= ST_ADDR;
        dbg_wave_pkt <= 1'b1;
        dbg_resync_count <= dbg_resync_count + 32'd1;
        bulk_mode <= (udp_tdata == BULK_MAGIC);
        bulk_words_left <= 32'd0;
      end else if (dbg_state == ST_RVCTRL1_EMIT_HDR1) begin
        rvctrl_tvalid <= 1'b1;
        rvctrl_tdata <= rvctrl1_hdr1_word;
        rvctrl_tfirst <= 1'b0;
        rvctrl_tlast <= (rvctrl1_payload_words_left == 32'd0);
        rvctrl_word_count <= rvctrl1_word_count;
        rvctrl_protocol <= rvctrl2_mode ? RVCTRL_PROTOCOL_RF2 : RVCTRL_PROTOCOL_V1;
        if (rvctrl1_payload_words_left == 32'd0) begin
          rvctrl1_skid_valid <= 1'b0;
          dbg_state <= ST_IDLE;
        end else begin
          if (udp_tvalid) begin
            rvctrl1_skid_word <= udp_tdata;
            rvctrl1_skid_valid <= 1'b1;
            rvctrl1_payload_words_left <= rvctrl1_payload_words_left - 32'd1;
          end
          dbg_state <= ST_RVCTRL1_PAYLOAD;
        end
      end else if (dbg_state == ST_RVCTRL1_PAYLOAD) begin
        if (rvctrl1_skid_valid) begin
          rvctrl_tvalid <= 1'b1;
          rvctrl_tdata <= rvctrl1_skid_word;
          rvctrl_tfirst <= 1'b0;
          rvctrl_tlast <= (rvctrl1_payload_words_left == 32'd0) ||
                          ((rvctrl1_payload_words_left == 32'd1) && !udp_tvalid);
          rvctrl_word_count <= rvctrl1_word_count;
          rvctrl_protocol <= rvctrl2_mode ? RVCTRL_PROTOCOL_RF2 : RVCTRL_PROTOCOL_V1;
          if (udp_tvalid && (rvctrl1_payload_words_left != 32'd0)) begin
            rvctrl1_skid_word <= udp_tdata;
            rvctrl1_skid_valid <= 1'b1;
            rvctrl1_payload_words_left <= rvctrl1_payload_words_left - 32'd1;
            dbg_state <= ST_RVCTRL1_PAYLOAD;
          end else begin
            rvctrl1_skid_valid <= 1'b0;
            dbg_state <= (rvctrl1_payload_words_left == 32'd0) ? ST_IDLE : ST_RVCTRL1_PAYLOAD;
          end
        end else if (udp_tvalid && (rvctrl1_payload_words_left != 32'd0)) begin
          rvctrl_tvalid <= 1'b1;
          rvctrl_tdata <= udp_tdata;
          rvctrl_tfirst <= 1'b0;
          rvctrl_tlast <= (rvctrl1_payload_words_left <= 32'd1);
          rvctrl_word_count <= rvctrl1_word_count;
          rvctrl_protocol <= rvctrl2_mode ? RVCTRL_PROTOCOL_RF2 : RVCTRL_PROTOCOL_V1;
          if (rvctrl1_payload_words_left <= 32'd1) begin
            rvctrl1_payload_words_left <= 32'd0;
            dbg_state <= ST_IDLE;
          end else begin
            rvctrl1_payload_words_left <= rvctrl1_payload_words_left - 32'd1;
            dbg_state <= ST_RVCTRL1_PAYLOAD;
          end
        end
      end else if (udp_tvalid) begin
        case (dbg_state)
          ST_IDLE: begin
            if (waveform_magic) begin
              dbg_state    <= ST_ADDR;
              dbg_wave_pkt <= 1'b1;
              bulk_mode <= (udp_tdata == BULK_MAGIC);
              bulk_words_left <= 32'd0;
            end else if (rvctrl_magic) begin
              dbg_state <= ST_RVCTRL_COUNT;
              rvctrl_words_left <= 32'd0;
              rvctrl_total_words <= 32'd0;
            end else if (rvctrl1_magic) begin
              dbg_state <= ST_RVCTRL1_HDR0;
              rvctrl1_payload_words_left <= 32'd0;
              rvctrl1_word_count <= 32'd0;
              rvctrl2_mode <= 1'b0;
            end else if (rfctrl2_magic) begin
              dbg_state <= ST_RVCTRL1_HDR0;
              rvctrl1_payload_words_left <= 32'd0;
              rvctrl1_word_count <= 32'd0;
              rvctrl2_mode <= 1'b1;
            end else begin
              instr_tdata    <= udp_tdata;
              instr_tvalid   <= 1'b1;
              dbg_instr_word <= 1'b1;
            end
          end

          ST_ADDR: begin
            write_addr <= udp_tdata;
            dbg_state  <= bulk_mode ? ST_BULK_COUNT : ST_DATA_LOW;
          end

          ST_BULK_COUNT: begin
            if ((udp_tdata[63:32] != 32'd0) || (udp_tdata[31:0] == 32'd0) ||
                (udp_tdata[1:0] != 2'd0)) begin
              dbg_drop_count <= dbg_drop_count + 32'd1;
              bulk_mode <= 1'b0;
              bulk_words_left <= 32'd0;
              dbg_state <= ST_IDLE;
            end else begin
              bulk_words_left <= udp_tdata[31:0];
              dbg_state <= ST_DATA_LOW;
            end
          end

          ST_RVCTRL_COUNT: begin
            if ((udp_tdata[63:32] != 32'd0) || (udp_tdata[31:0] == 32'd0)) begin
              dbg_drop_count <= dbg_drop_count + 32'd1;
              rvctrl_words_left <= 32'd0;
              rvctrl_total_words <= 32'd0;
              dbg_state <= ST_IDLE;
            end else begin
              rvctrl_words_left <= udp_tdata[31:0];
              rvctrl_total_words <= udp_tdata[31:0];
              dbg_state <= ST_DATA_LOW;
            end
          end

          ST_RVCTRL1_HDR0: begin
            rvctrl1_hdr0_word <= udp_tdata;
            dbg_state <= ST_RVCTRL1_HDR1;
          end

          ST_RVCTRL1_HDR1: begin
            rvctrl1_hdr1_word <= udp_tdata;
            rvctrl1_payload_words_left <= (udp_tdata[63:32] + 32'd7) >> 3;
            rvctrl1_word_count <= 32'd4 + ((udp_tdata[63:32] + 32'd3) >> 2);
            // Emit buffered RVCTRL1 header word 0 after header word 1 reveals
            // the exact total payload length.
            rvctrl_tvalid <= 1'b1;
            rvctrl_tdata <= rvctrl1_hdr0_word;
            rvctrl_tfirst <= 1'b1;
            rvctrl_tlast <= 1'b0;
            rvctrl_word_count <= 32'd4 + ((udp_tdata[63:32] + 32'd3) >> 2);
            rvctrl_protocol <= rvctrl2_mode ? RVCTRL_PROTOCOL_RF2 : RVCTRL_PROTOCOL_V1;
            dbg_state <= ST_RVCTRL1_EMIT_HDR1;
          end

          ST_DATA_LOW: begin
            if (rvctrl_words_left != 32'd0) begin
              rvctrl_tvalid <= 1'b1;
              rvctrl_tdata <= udp_tdata;
              rvctrl_tfirst <= (rvctrl_words_left == rvctrl_total_words);
              rvctrl_tlast <= (rvctrl_words_left <= 32'd2);
              rvctrl_word_count <= rvctrl_total_words;
              rvctrl_protocol <= RVCTRL_PROTOCOL_LEGACY;
              if (rvctrl_words_left <= 32'd2) begin
                rvctrl_words_left <= 32'd0;
                rvctrl_total_words <= 32'd0;
                dbg_state <= ST_IDLE;
              end else begin
                rvctrl_words_left <= rvctrl_words_left - 32'd2;
                dbg_state <= ST_DATA_LOW;
              end
            end else begin
              data_word0 <= udp_tdata;
              dbg_state  <= ST_DATA_1;
            end
          end

          ST_DATA_1: begin
            data_word1 <= udp_tdata;
            dbg_state  <= ST_DATA_2;
          end

          ST_DATA_2: begin
            data_word2 <= udp_tdata;
            dbg_state  <= ST_DATA_3;
          end

          ST_DATA_3: begin
            if (!write_addr_aligned) begin
              dbg_align_error_count <= dbg_align_error_count + 32'd1;
              dbg_drop_count <= dbg_drop_count + 32'd1;
            end else if (!fifo_full || pop_write) begin
              fifo_addr[fifo_wr_ptr] <= write_addr;
              fifo_data[fifo_wr_ptr] <= {udp_tdata, data_word2, data_word1, data_word0};
              fifo_wr_ptr <= fifo_wr_ptr + {{FIFO_DEPTH_LOG2-1{1'b0}}, 1'b1};
              dbg_write_count <= dbg_write_count + 32'd1;
            end else begin
              dbg_drop_count <= dbg_drop_count + 32'd1;
            end
            if (bulk_mode && (bulk_words_left > 32'd4)) begin
              write_addr <= write_addr + 64'd32;
              bulk_words_left <= bulk_words_left - 32'd4;
              dbg_state <= ST_DATA_LOW;
            end else begin
              bulk_mode <= 1'b0;
              bulk_words_left <= 32'd0;
              dbg_state <= ST_IDLE;
            end
          end

          default: begin
            dbg_state <= ST_IDLE;
          end
        endcase
      end

      case ({push_write, pop_write})
        2'b10: fifo_count <= fifo_count + {{FIFO_DEPTH_LOG2{1'b0}}, 1'b1};
        2'b01: fifo_count <= fifo_count - {{FIFO_DEPTH_LOG2{1'b0}}, 1'b1};
        default: fifo_count <= fifo_count;
      endcase
    end
  end

  assign dbg_drop_count_o = dbg_drop_count;
  assign dbg_align_error_count_o = dbg_align_error_count;
  assign dbg_fifo_count_o = {11'd0, fifo_count};

endmodule
