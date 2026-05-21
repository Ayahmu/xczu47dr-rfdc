/*

Copyright (c) 2015-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * 10G Ethernet MAC with TX and RX FIFOs
 */
module eth_mac_10g_fifo #
(
    parameter DATA_WIDTH = 64,
    parameter KEEP_WIDTH = DATA_WIDTH/8,
    parameter CTRL_WIDTH = (DATA_WIDTH/8),
    parameter AXIS_DATA_WIDTH = DATA_WIDTH,
    parameter AXIS_KEEP_ENABLE = (AXIS_DATA_WIDTH>8),
    parameter AXIS_KEEP_WIDTH = (AXIS_DATA_WIDTH/8),
    parameter ENABLE_PADDING = 1,
    parameter ENABLE_DIC = 1,
    parameter MIN_FRAME_LENGTH = 64,
    parameter TX_FIFO_DEPTH = 4096,
    parameter TX_FIFO_RAM_PIPELINE = 1,
    parameter TX_FRAME_FIFO = 1,
    parameter TX_DROP_OVERSIZE_FRAME = TX_FRAME_FIFO,
    parameter TX_DROP_BAD_FRAME = TX_DROP_OVERSIZE_FRAME,
    parameter TX_DROP_WHEN_FULL = 0,
    parameter RX_FIFO_DEPTH = 4096,
    parameter RX_FIFO_RAM_PIPELINE = 1,
    parameter RX_FRAME_FIFO = 1,
    parameter RX_DROP_OVERSIZE_FRAME = RX_FRAME_FIFO,
    parameter RX_DROP_BAD_FRAME = RX_DROP_OVERSIZE_FRAME,
    parameter RX_DROP_WHEN_FULL = RX_DROP_OVERSIZE_FRAME,
    parameter PTP_TS_ENABLE = 0,
    parameter PTP_TS_FMT_TOD = 1,
    parameter PTP_TS_WIDTH = PTP_TS_FMT_TOD ? 96 : 64,
    parameter TX_PTP_TS_CTRL_IN_TUSER = 0,
    parameter TX_PTP_TS_FIFO_DEPTH = 64,
    parameter TX_PTP_TAG_ENABLE = PTP_TS_ENABLE,
    parameter PTP_TAG_WIDTH = 16,
    parameter TX_USER_WIDTH = (PTP_TS_ENABLE ? (TX_PTP_TAG_ENABLE ? PTP_TAG_WIDTH : 0) + (TX_PTP_TS_CTRL_IN_TUSER ? 1 : 0) : 0) + 1,
    parameter RX_USER_WIDTH = (PTP_TS_ENABLE ? PTP_TS_WIDTH : 0) + 1
)
(
    input  wire                       rx_clk,
    input  wire                       rx_rst,
    input  wire                       tx_clk,
    input  wire                       tx_rst,
    input  wire                       logic_clk,
    input  wire                       logic_rst,
    input  wire                       ptp_sample_clk,

    /*
     * AXI input
     */
    input  wire [AXIS_DATA_WIDTH-1:0] tx_axis_tdata,
    input  wire [AXIS_KEEP_WIDTH-1:0] tx_axis_tkeep,
    input  wire                       tx_axis_tvalid,
    output wire                       tx_axis_tready,
    input  wire                       tx_axis_tlast,
    input  wire [TX_USER_WIDTH-1:0]   tx_axis_tuser,

    output wire [DATA_WIDTH-1:0]      tx_fifo_axis_tdata,
    output wire [KEEP_WIDTH-1:0]      tx_fifo_axis_tkeep,
    output wire                       tx_fifo_axis_tvalid,
    input  wire                       tx_fifo_axis_tready,
    output wire                       tx_fifo_axis_tlast,
    output wire [TX_USER_WIDTH-1:0]   tx_fifo_axis_tuser,

    /*
     * AXI output
     */
    output wire [AXIS_DATA_WIDTH-1:0] rx_axis_tdata,
    output wire [AXIS_KEEP_WIDTH-1:0] rx_axis_tkeep,
    output wire                       rx_axis_tvalid,
    input  wire                       rx_axis_tready,
    output wire                       rx_axis_tlast,
    output wire [RX_USER_WIDTH-1:0]   rx_axis_tuser,

    input  wire [DATA_WIDTH-1:0]      rx_fifo_axis_tdata,
    input  wire [KEEP_WIDTH-1:0]      rx_fifo_axis_tkeep,
    input  wire                       rx_fifo_axis_tvalid,
    input  wire                       rx_fifo_axis_tlast,
    input  wire [RX_USER_WIDTH-1:0]   rx_fifo_axis_tuser
);



    axis_async_fifo_adapter #(
        .DEPTH(TX_FIFO_DEPTH),
        .S_DATA_WIDTH(AXIS_DATA_WIDTH),
        .S_KEEP_ENABLE(AXIS_KEEP_ENABLE),
        .S_KEEP_WIDTH(AXIS_KEEP_WIDTH),
        .M_DATA_WIDTH(DATA_WIDTH),
        .M_KEEP_ENABLE(1),
        .M_KEEP_WIDTH(KEEP_WIDTH),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(TX_USER_WIDTH),
        .RAM_PIPELINE(TX_FIFO_RAM_PIPELINE),
        .FRAME_FIFO(TX_FRAME_FIFO),
        .USER_BAD_FRAME_VALUE(1'b1),
        .USER_BAD_FRAME_MASK(1'b1),
        .DROP_OVERSIZE_FRAME(TX_DROP_OVERSIZE_FRAME),
        .DROP_BAD_FRAME(TX_DROP_BAD_FRAME),
        .DROP_WHEN_FULL(TX_DROP_WHEN_FULL)
    )
    tx_fifo (
        // AXI input
        .s_clk(logic_clk),
        .s_rst(logic_rst),
        .s_axis_tdata(tx_axis_tdata),
        .s_axis_tkeep(tx_axis_tkeep),
        .s_axis_tvalid(tx_axis_tvalid),
        .s_axis_tready(tx_axis_tready),
        .s_axis_tlast(tx_axis_tlast),
        .s_axis_tid(0),
        .s_axis_tdest(0),
        .s_axis_tuser(tx_axis_tuser),
        // AXI output
        .m_clk(tx_clk),
        .m_rst(tx_rst),
        .m_axis_tdata(tx_fifo_axis_tdata),
        .m_axis_tkeep(tx_fifo_axis_tkeep),
        .m_axis_tvalid(tx_fifo_axis_tvalid),
        .m_axis_tready(tx_fifo_axis_tready),
        .m_axis_tlast(tx_fifo_axis_tlast),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(tx_fifo_axis_tuser),
        // Status
        .s_status_overflow(),
        .s_status_bad_frame(),
        .s_status_good_frame(),
        .m_status_overflow(),
        .m_status_bad_frame(),
        .m_status_good_frame()
    );


    

    axis_async_fifo_adapter #(
        .DEPTH(RX_FIFO_DEPTH),
        .S_DATA_WIDTH(DATA_WIDTH),
        .S_KEEP_ENABLE(1),
        .S_KEEP_WIDTH(KEEP_WIDTH),
        .M_DATA_WIDTH(AXIS_DATA_WIDTH),
        .M_KEEP_ENABLE(AXIS_KEEP_ENABLE),
        .M_KEEP_WIDTH(AXIS_KEEP_WIDTH),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(RX_USER_WIDTH),
        .RAM_PIPELINE(RX_FIFO_RAM_PIPELINE),
        .FRAME_FIFO(RX_FRAME_FIFO),
        .USER_BAD_FRAME_VALUE(1'b1),
        .USER_BAD_FRAME_MASK(1'b1),
        .DROP_OVERSIZE_FRAME(RX_DROP_OVERSIZE_FRAME),
        .DROP_BAD_FRAME(RX_DROP_BAD_FRAME),
        .DROP_WHEN_FULL(RX_DROP_WHEN_FULL)
    )
    rx_fifo (
        // AXI input
        .s_clk(rx_clk),
        .s_rst(rx_rst),
        .s_axis_tdata(rx_fifo_axis_tdata),
        .s_axis_tkeep(rx_fifo_axis_tkeep),
        .s_axis_tvalid(rx_fifo_axis_tvalid),
        .s_axis_tready(),
        .s_axis_tlast(rx_fifo_axis_tlast),
        .s_axis_tid(0),
        .s_axis_tdest(0),
        .s_axis_tuser(rx_fifo_axis_tuser),
        // AXI output
        .m_clk(logic_clk),
        .m_rst(logic_rst),
        .m_axis_tdata(rx_axis_tdata),
        .m_axis_tkeep(rx_axis_tkeep),
        .m_axis_tvalid(rx_axis_tvalid),
        .m_axis_tready(rx_axis_tready),
        .m_axis_tlast(rx_axis_tlast),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(rx_axis_tuser),
        // Status
        .s_status_overflow(),
        .s_status_bad_frame(),
        .s_status_good_frame(),
        .m_status_overflow(),
        .m_status_bad_frame(),
        .m_status_good_frame()
    );

endmodule

`resetall
