`timescale 1ns / 1ps

// Two-master AXI-Lite arbiter. A grant is held from the first address/data
// request through the corresponding B or R handshake, so AW/W and response
// channels can never be split between masters.
module axilite_arbiter_2to1 #(
    parameter integer ADDR_WIDTH = 18
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [ADDR_WIDTH-1:0] s0_awaddr,
    input  wire                  s0_awvalid,
    output wire                  s0_awready,
    input  wire [31:0]           s0_wdata,
    input  wire [3:0]            s0_wstrb,
    input  wire                  s0_wvalid,
    output wire                  s0_wready,
    output wire [1:0]            s0_bresp,
    output wire                  s0_bvalid,
    input  wire                  s0_bready,
    input  wire [ADDR_WIDTH-1:0] s0_araddr,
    input  wire                  s0_arvalid,
    output wire                  s0_arready,
    output wire [31:0]           s0_rdata,
    output wire [1:0]            s0_rresp,
    output wire                  s0_rvalid,
    input  wire                  s0_rready,

    input  wire [ADDR_WIDTH-1:0] s1_awaddr,
    input  wire                  s1_awvalid,
    output wire                  s1_awready,
    input  wire [31:0]           s1_wdata,
    input  wire [3:0]            s1_wstrb,
    input  wire                  s1_wvalid,
    output wire                  s1_wready,
    output wire [1:0]            s1_bresp,
    output wire                  s1_bvalid,
    input  wire                  s1_bready,
    input  wire [ADDR_WIDTH-1:0] s1_araddr,
    input  wire                  s1_arvalid,
    output wire                  s1_arready,
    output wire [31:0]           s1_rdata,
    output wire [1:0]            s1_rresp,
    output wire                  s1_rvalid,
    input  wire                  s1_rready,

    output wire [ADDR_WIDTH-1:0] m_awaddr,
    output wire                  m_awvalid,
    input  wire                  m_awready,
    output wire [31:0]           m_wdata,
    output wire [3:0]            m_wstrb,
    output wire                  m_wvalid,
    input  wire                  m_wready,
    input  wire [1:0]            m_bresp,
    input  wire                  m_bvalid,
    output wire                  m_bready,
    output wire [ADDR_WIDTH-1:0] m_araddr,
    output wire                  m_arvalid,
    input  wire                  m_arready,
    input  wire [31:0]           m_rdata,
    input  wire [1:0]            m_rresp,
    input  wire                  m_rvalid,
    output wire                  m_rready
);

  localparam [2:0] IDLE = 3'd0;
  localparam [2:0] S0_WRITE = 3'd1;
  localparam [2:0] S0_READ = 3'd2;
  localparam [2:0] S1_WRITE = 3'd3;
  localparam [2:0] S1_READ = 3'd4;

  reg [2:0] grant;
  wire idle_s0_write = (grant == IDLE) && (s0_awvalid || s0_wvalid);
  wire idle_s0_read  = (grant == IDLE) && !idle_s0_write && s0_arvalid;
  wire idle_s1_write = (grant == IDLE) && !idle_s0_write && !idle_s0_read && (s1_awvalid || s1_wvalid);
  wire idle_s1_read  = (grant == IDLE) && !idle_s0_write && !idle_s0_read && !idle_s1_write && s1_arvalid;
  wire use_s0_write = (grant == S0_WRITE) || idle_s0_write;
  wire use_s0_read  = (grant == S0_READ) || idle_s0_read;
  wire use_s1_write = (grant == S1_WRITE) || idle_s1_write;
  wire use_s1_read  = (grant == S1_READ) || idle_s1_read;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      grant <= IDLE;
    end else begin
      case (grant)
        IDLE: begin
          if (idle_s0_write) grant <= S0_WRITE;
          else if (idle_s0_read) grant <= S0_READ;
          else if (idle_s1_write) grant <= S1_WRITE;
          else if (idle_s1_read) grant <= S1_READ;
        end
        S0_WRITE: if (m_bvalid && s0_bready) grant <= IDLE;
        S0_READ:  if (m_rvalid && s0_rready) grant <= IDLE;
        S1_WRITE: if (m_bvalid && s1_bready) grant <= IDLE;
        S1_READ:  if (m_rvalid && s1_rready) grant <= IDLE;
        default: grant <= IDLE;
      endcase
    end
  end

  assign m_awaddr  = use_s1_write ? s1_awaddr : s0_awaddr;
  assign m_awvalid = use_s0_write ? s0_awvalid : use_s1_write ? s1_awvalid : 1'b0;
  assign m_wdata   = use_s1_write ? s1_wdata : s0_wdata;
  assign m_wstrb   = use_s1_write ? s1_wstrb : s0_wstrb;
  assign m_wvalid  = use_s0_write ? s0_wvalid : use_s1_write ? s1_wvalid : 1'b0;
  assign m_bready  = use_s0_write ? s0_bready : use_s1_write ? s1_bready : 1'b0;
  assign m_araddr  = use_s1_read ? s1_araddr : s0_araddr;
  assign m_arvalid = use_s0_read ? s0_arvalid : use_s1_read ? s1_arvalid : 1'b0;
  assign m_rready  = use_s0_read ? s0_rready : use_s1_read ? s1_rready : 1'b0;

  assign s0_awready = use_s0_write ? m_awready : 1'b0;
  assign s0_wready  = use_s0_write ? m_wready : 1'b0;
  assign s0_bresp   = m_bresp;
  assign s0_bvalid  = use_s0_write ? m_bvalid : 1'b0;
  assign s0_arready = use_s0_read ? m_arready : 1'b0;
  assign s0_rdata   = m_rdata;
  assign s0_rresp   = m_rresp;
  assign s0_rvalid  = use_s0_read ? m_rvalid : 1'b0;

  assign s1_awready = use_s1_write ? m_awready : 1'b0;
  assign s1_wready  = use_s1_write ? m_wready : 1'b0;
  assign s1_bresp   = m_bresp;
  assign s1_bvalid  = use_s1_write ? m_bvalid : 1'b0;
  assign s1_arready = use_s1_read ? m_arready : 1'b0;
  assign s1_rdata   = m_rdata;
  assign s1_rresp   = m_rresp;
  assign s1_rvalid  = use_s1_read ? m_rvalid : 1'b0;

endmodule
