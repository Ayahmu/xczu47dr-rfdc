`timescale 1ns / 1ps

module udp_waveform_ddr_writer #(
    parameter [63:0] MAGIC = 64'h5741564544445230,
    parameter FIFO_DEPTH_LOG2 = 4
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         udp_tvalid,
    input  wire [63:0]  udp_tdata,

    output reg          instr_tvalid,
    output reg  [63:0]  instr_tdata,

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

    output reg  [127:0] m_axi_wdata,
    output wire         m_axi_wlast,
    input  wire         m_axi_wready,
    output wire [15:0]  m_axi_wstrb,
    output reg          m_axi_wvalid,

    output wire         m_axi_bready,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,

    output reg          dbg_wave_pkt,
    output reg          dbg_instr_word,
    output reg  [2:0]   dbg_state,
    output reg  [31:0]  dbg_write_count,
    output reg  [31:0]  dbg_bresp_count,
    output wire [31:0]  dbg_drop_count_o,
    output wire [15:0]  dbg_fifo_count_o,
    output reg  [31:0]  dbg_resync_count,
    output reg  [1:0]   dbg_last_bresp,
    output reg  [63:0]  dbg_last_addr,
    output reg  [127:0] dbg_last_wdata
);

  localparam [FIFO_DEPTH_LOG2:0] FIFO_DEPTH = (1 << FIFO_DEPTH_LOG2);

  localparam [2:0] ST_IDLE     = 3'd0;
  localparam [2:0] ST_ADDR     = 3'd1;
  localparam [2:0] ST_DATA_LOW = 3'd2;
  localparam [2:0] ST_DATA_HI  = 3'd3;

  reg [63:0] write_addr;
  reg [63:0] data_low;

  reg [63:0]  fifo_addr [0:(1 << FIFO_DEPTH_LOG2)-1];
  reg [127:0] fifo_data [0:(1 << FIFO_DEPTH_LOG2)-1];
  reg [FIFO_DEPTH_LOG2-1:0] fifo_wr_ptr;
  reg [FIFO_DEPTH_LOG2-1:0] fifo_rd_ptr;
  reg [FIFO_DEPTH_LOG2:0] fifo_count;
  reg [31:0] dbg_drop_count;
  reg write_resp_pending;

  wire fifo_full = fifo_count == FIFO_DEPTH;
  wire fifo_empty = fifo_count == {FIFO_DEPTH_LOG2+1{1'b0}};
  wire axi_idle = !m_axi_awvalid && !m_axi_wvalid;
  wire launch_write = axi_idle && !write_resp_pending && !fifo_empty;
  wire pop_write = launch_write;
  wire resync_word = udp_tvalid && (udp_tdata == MAGIC) && (dbg_state != ST_IDLE);
  wire push_write = udp_tvalid && !resync_word && (dbg_state == ST_DATA_HI) && (!fifo_full || pop_write);
  wire aw_fire = m_axi_awvalid && m_axi_awready;
  wire w_fire = m_axi_wvalid && m_axi_wready;
  wire b_fire = m_axi_bvalid && m_axi_bready;

  assign m_axi_awburst = 2'b01;
  assign m_axi_awcache = 4'b0011;
  assign m_axi_awlen   = 8'd0;
  assign m_axi_awlock  = 1'b0;
  assign m_axi_awprot  = 3'b000;
  assign m_axi_awqos   = 4'b0000;
  assign m_axi_awsize  = 3'b100;

  assign m_axi_wlast   = 1'b1;
  assign m_axi_wstrb   = 16'hffff;
  assign m_axi_bready  = 1'b1;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      instr_tvalid  <= 1'b0;
      instr_tdata   <= 64'd0;
      m_axi_awaddr  <= 64'd0;
      m_axi_awvalid <= 1'b0;
      m_axi_wdata   <= 128'd0;
      m_axi_wvalid  <= 1'b0;
      dbg_wave_pkt  <= 1'b0;
      dbg_instr_word <= 1'b0;
      dbg_state     <= ST_IDLE;
      dbg_write_count <= 32'd0;
      dbg_bresp_count <= 32'd0;
      dbg_last_bresp  <= 2'd0;
      dbg_last_addr   <= 64'd0;
      dbg_last_wdata  <= 128'd0;
      fifo_wr_ptr <= {FIFO_DEPTH_LOG2{1'b0}};
      fifo_rd_ptr <= {FIFO_DEPTH_LOG2{1'b0}};
      fifo_count  <= {FIFO_DEPTH_LOG2+1{1'b0}};
      dbg_drop_count <= 32'd0;
      dbg_resync_count <= 32'd0;
      write_resp_pending <= 1'b0;
      write_addr   <= 64'd0;
      data_low     <= 64'd0;
    end else begin
      instr_tvalid  <= 1'b0;
      dbg_wave_pkt  <= 1'b0;
      dbg_instr_word <= 1'b0;

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
        m_axi_awaddr  <= fifo_addr[fifo_rd_ptr];
        m_axi_awvalid <= 1'b1;
        m_axi_wdata   <= fifo_data[fifo_rd_ptr];
        m_axi_wvalid  <= 1'b1;
        dbg_last_addr  <= fifo_addr[fifo_rd_ptr];
        dbg_last_wdata <= fifo_data[fifo_rd_ptr];
        fifo_rd_ptr <= fifo_rd_ptr + {{FIFO_DEPTH_LOG2-1{1'b0}}, 1'b1};
        write_resp_pending <= 1'b1;
      end

      if (resync_word) begin
        dbg_state <= ST_ADDR;
        dbg_wave_pkt <= 1'b1;
        dbg_resync_count <= dbg_resync_count + 32'd1;
      end else if (udp_tvalid) begin
        case (dbg_state)
          ST_IDLE: begin
            if (udp_tdata == MAGIC) begin
              dbg_state    <= ST_ADDR;
              dbg_wave_pkt <= 1'b1;
            end else begin
              instr_tdata    <= udp_tdata;
              instr_tvalid   <= 1'b1;
              dbg_instr_word <= 1'b1;
            end
          end

          ST_ADDR: begin
            write_addr <= udp_tdata;
            dbg_state  <= ST_DATA_LOW;
          end

          ST_DATA_LOW: begin
            data_low  <= udp_tdata;
            dbg_state <= ST_DATA_HI;
          end

          ST_DATA_HI: begin
            if (!fifo_full || pop_write) begin
              fifo_addr[fifo_wr_ptr] <= write_addr;
              fifo_data[fifo_wr_ptr] <= {udp_tdata, data_low};
              fifo_wr_ptr <= fifo_wr_ptr + {{FIFO_DEPTH_LOG2-1{1'b0}}, 1'b1};
              dbg_write_count <= dbg_write_count + 32'd1;
            end else begin
              dbg_drop_count <= dbg_drop_count + 32'd1;
            end
            dbg_state <= ST_IDLE;
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
  assign dbg_fifo_count_o = {11'd0, fifo_count};

endmodule
