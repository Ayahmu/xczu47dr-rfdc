`timescale 1ns/1ps

// Splits the CMAC 512-bit RX stream into bulk waveform frames and everything
// else, in the CMAC user clock domain.
//
// A bulk frame is IPv4/UDP, unfragmented, without IP options, addressed to
// the board's MAC, IP and bulk UDP port, and carries the "WBLK" tag right
// after the UDP header.  Ethernet (14) + IPv4 (20) + UDP (8) + the 22-byte
// bulk header fill the first 512-bit word exactly, so every following word is
// one 64-byte DDR beat.
//
// The CMAC cannot be backpressured, so this is a pure two-stage pipeline: the
// field compares are registered separately (stage 1) and reduced to the
// routing decision one cycle later (stage 2).  Neither output has tready.
//
// local_mac / local_ip / bulk_port / enable are quasi-static and must already
// be synchronous to clk.
module wave_bulk_rx_classifier (
    input  wire         clk,
    input  wire         rst,
    input  wire         enable,
    input  wire [47:0]  local_mac,
    input  wire [31:0]  local_ip,
    input  wire [15:0]  bulk_port,

    input  wire [511:0] s_axis_tdata,
    input  wire [63:0]  s_axis_tkeep,
    input  wire         s_axis_tvalid,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tuser,

    output reg  [511:0] m_ctl_axis_tdata,
    output reg  [63:0]  m_ctl_axis_tkeep,
    output reg          m_ctl_axis_tvalid,
    output reg          m_ctl_axis_tlast,
    output reg          m_ctl_axis_tuser,

    output reg  [511:0] m_bulk_axis_tdata,
    output reg          m_bulk_axis_tvalid,
    output reg          m_bulk_axis_tlast,
    output reg          m_bulk_axis_tuser
);
  // Byte n of the frame (n = 0 first on the wire) is s_axis_tdata[8n +: 8].
  `define WBULK_BYTE(n) s_axis_tdata[8*(n) +: 8]

  reg in_frame;                 // a frame is open at the input
  reg [511:0] d1_tdata;
  reg [63:0]  d1_tkeep;
  reg         d1_tvalid, d1_tlast, d1_tuser, d1_first;
  reg [9:0]   d1_match;
  reg         bulk_hold;        // routing decision of the frame open at stage 1

  wire frame_is_bulk = d1_first ? (&d1_match) && enable : bulk_hold;

  always @(posedge clk) begin
    if (rst) begin
      in_frame <= 1'b0;
      d1_tvalid <= 1'b0; d1_tlast <= 1'b0; d1_tuser <= 1'b0; d1_first <= 1'b0;
      bulk_hold <= 1'b0;
      m_ctl_axis_tvalid <= 1'b0; m_bulk_axis_tvalid <= 1'b0;
    end else begin
      if (s_axis_tvalid) in_frame <= !s_axis_tlast;
      d1_tvalid <= s_axis_tvalid;
      d1_tlast  <= s_axis_tlast;
      d1_tuser  <= s_axis_tuser;
      d1_first  <= s_axis_tvalid && !in_frame;

      if (d1_tvalid && d1_first) bulk_hold <= frame_is_bulk;
      m_ctl_axis_tvalid  <= d1_tvalid && !frame_is_bulk;
      m_bulk_axis_tvalid <= d1_tvalid && frame_is_bulk;
    end
  end

  // Datapath and compare flags carry no reset: they are qualified by tvalid.
  always @(posedge clk) begin
    d1_tdata <= s_axis_tdata;
    d1_tkeep <= s_axis_tkeep;
    d1_match[0] <= {`WBULK_BYTE(0), `WBULK_BYTE(1)} == local_mac[47:32];
    d1_match[1] <= {`WBULK_BYTE(2), `WBULK_BYTE(3)} == local_mac[31:16];
    d1_match[2] <= {`WBULK_BYTE(4), `WBULK_BYTE(5)} == local_mac[15:0];
    d1_match[3] <= {`WBULK_BYTE(12), `WBULK_BYTE(13)} == 16'h0800;            // IPv4
    d1_match[4] <= `WBULK_BYTE(14) == 8'h45 && `WBULK_BYTE(23) == 8'd17;      // no options, UDP
    d1_match[5] <= ({`WBULK_BYTE(20), `WBULK_BYTE(21)} & 16'h3fff) == 16'h0000; // not a fragment
    d1_match[6] <= {`WBULK_BYTE(30), `WBULK_BYTE(31)} == local_ip[31:16];
    d1_match[7] <= {`WBULK_BYTE(32), `WBULK_BYTE(33)} == local_ip[15:0];
    d1_match[8] <= {`WBULK_BYTE(36), `WBULK_BYTE(37)} == bulk_port;
    d1_match[9] <= {`WBULK_BYTE(42), `WBULK_BYTE(43), `WBULK_BYTE(44), `WBULK_BYTE(45)} == "WBLK";

    m_ctl_axis_tdata <= d1_tdata;
    m_ctl_axis_tkeep <= d1_tkeep;
    m_ctl_axis_tlast <= d1_tlast;
    m_ctl_axis_tuser <= d1_tuser;
    m_bulk_axis_tdata <= d1_tdata;
    m_bulk_axis_tlast <= d1_tlast;
    m_bulk_axis_tuser <= d1_tuser;
  end
  `undef WBULK_BYTE
endmodule
