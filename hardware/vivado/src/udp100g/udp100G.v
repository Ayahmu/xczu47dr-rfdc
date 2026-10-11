`resetall
`timescale 1ns / 1ps
//`default_nettype none

// 100G QSFP28 UDP wrapper for the XCZU47DR RFSoC board.
//
// This module mirrors the reference 100G example's udp_100G top but targets
// the 47DR QSFP28 cage (BANK 128, GT quad X0Y4~X0Y7) instead of the VU13P
// card and carries the board's control-plane interface (network identity,
// response stream, packet classifier outputs):
//
//   CMAC (512-bit, RS-FEC) -> ethernet_adapter_100g (512<->64) -> fpga_core
//
// Bulk waveform frames (UDP port network_udp_port + 1, "WBLK" tag) are taken
// off the CMAC RX stream before the width adapter and leave on m_bulk_axis_*
// at the full 512 bits, already in the clk domain:
//
//   CMAC RX -> wave_bulk_rx_path -+-> ethernet_adapter_100g -> fpga_core
//                                 +-> m_bulk_axis_* (frame FIFO, clk)
//
// The UDP/IP/ARP stack in fpga_core is 64 bits wide; the adapter converts
// between it and the CMAC's 512-bit segments in the CMAC user clock domain.
module udp_100G
(
    input   wire    [3:0]       gt_rxp_in       ,
    input   wire    [3:0]       gt_rxn_in       ,
    output  wire    [3:0]       gt_txp_out      ,
    output  wire    [3:0]       gt_txn_out      ,

    input   wire                gt_refclk_p     ,
    input   wire                gt_refclk_n     ,

    output  wire                qsfp_lpmode     ,
    output  wire                qsfp_resetn     ,
    input   wire                clk_100Mhz      ,

    // CMAC TX user clock, exported for the TDC code-density calibration
    // source.
    output  wire                calibration_clk_out,

    // 64-bit UDP stack / control plane domain (DDR UI clock on this board)
    input  wire         clk,
    input  wire         rst,

    input  wire [47:0]  network_local_mac,
    input  wire [31:0]  network_local_ip,
    input  wire [31:0]  network_gateway_ip,
    input  wire [31:0]  network_subnet_mask,
    input  wire [15:0]  network_udp_port,
    input  wire         network_clear_arp_cache,
    input  wire         network_restart_pulse,

    input  wire         resp64_tvalid,
    input  wire[63:0]   resp64_tdata,
    input  wire         resp64_tlast,
    input  wire[15:0]   resp64_word_count,
    output wire         resp64_tready,

    output wire         rcv_vld,
    output wire[63:0]   rcv_dat,
    output wire         rcv_last,

    // Bulk waveform frames, clk domain.  Whole FCS-clean frames only.
    output wire [511:0] m_bulk_axis_tdata,
    output wire         m_bulk_axis_tvalid,
    input  wire         m_bulk_axis_tready,
    output wire         m_bulk_axis_tlast,
    output wire [31:0]  bulk_rx_frames,
    output wire [31:0]  bulk_rx_dropped_full,
    output wire [31:0]  bulk_rx_dropped_bad
);

    assign qsfp_lpmode = 1'b0;
    assign qsfp_resetn = 1'b1;

    wire            clk_axis        ;
    // The CMAC TX user clock (clk_axis) is the natural code-density phase
    // source for the TDC calibration path; it is independent of the DDR
    // and DAC clocks.
    assign calibration_clk_out = clk_axis;

    wire            user_rx_reset_0 ;
    wire            user_tx_reset_0 ;

    wire            rx_axis_tvalid_0;
    wire [511:0]    rx_axis_tdata_0 ;
    wire [0:0]      rx_axis_tuser_0 ;
    wire [63:0]     rx_axis_tkeep_0 ;
    wire            rx_axis_tlast_0 ;

    wire            tx_axis_tready_0;
    wire            tx_axis_tvalid_0;
    wire [511:0]    tx_axis_tdata_0 ;
    wire [63:0]     tx_axis_tkeep_0 ;
    wire [0:0]      tx_axis_tuser_0 ;
    wire            tx_axis_tlast_0 ;

    wire            udp_rx_axis_tvalid;
    wire [63:0]     udp_rx_axis_tdata ;
    wire [0:0]      udp_rx_axis_tuser ;
    wire [7:0 ]     udp_rx_axis_tkeep ;
    wire            udp_rx_axis_tlast ;

    wire            udp_tx_axis_tready;
    wire            udp_tx_axis_tvalid;
    wire [63:0]     udp_tx_axis_tdata ;
    wire [7:0 ]     udp_tx_axis_tkeep ;
    wire [0:0]      udp_tx_axis_tuser ;
    wire            udp_tx_axis_tlast ;

    cmac_usplus_wrapper inst_cmac_usplus_wrapper(
        .init_clk         ( clk_100Mhz       ),
        .drp_clk          ( clk_100Mhz       ),

        .sys_reset        ( rst              ),

        .clk_axis         ( clk_axis         ),

        .usr_rx_reset     ( user_rx_reset_0  ),
        .usr_tx_reset     ( user_tx_reset_0  ),

        .rx_axis_tvalid   ( rx_axis_tvalid_0 ),
        .rx_axis_tdata    ( rx_axis_tdata_0  ),
        .rx_axis_tuser    ( rx_axis_tuser_0  ),
        .rx_axis_tkeep    ( rx_axis_tkeep_0  ),
        .rx_axis_tlast    ( rx_axis_tlast_0  ),

        .tx_axis_tready   ( tx_axis_tready_0 ),
        .tx_axis_tvalid   ( tx_axis_tvalid_0 ),
        .tx_axis_tdata    ( tx_axis_tdata_0  ),
        .tx_axis_tkeep    ( tx_axis_tkeep_0  ),
        .tx_axis_tuser    ( tx_axis_tuser_0  ),
        .tx_axis_tlast    ( tx_axis_tlast_0  ),

        .gt_ref_clk_p     ( gt_refclk_p      ),
        .gt_ref_clk_n     ( gt_refclk_n      ),
        .gt_rxp_in        ( gt_rxp_in        ),
        .gt_rxn_in        ( gt_rxn_in        ),
        .gt_txp_out       ( gt_txp_out       ),
        .gt_txn_out       ( gt_txn_out       )
    );

    // Bulk frames leave the stream here; the 64-bit stack sees the rest.
    wire            ctl_rx_axis_tvalid;
    wire [511:0]    ctl_rx_axis_tdata ;
    wire [0:0]      ctl_rx_axis_tuser ;
    wire [63:0]     ctl_rx_axis_tkeep ;
    wire            ctl_rx_axis_tlast ;
    reg  [15:0]     bulk_udp_port = 16'd0;
    always @(posedge clk) bulk_udp_port <= network_udp_port + 16'd1;

    wave_bulk_rx_path bulk_rx_path_i (
        .rx_clk(clk_axis), .rx_rst(user_rx_reset_0),
        .s_axis_tdata(rx_axis_tdata_0), .s_axis_tkeep(rx_axis_tkeep_0), .s_axis_tvalid(rx_axis_tvalid_0),
        .s_axis_tlast(rx_axis_tlast_0), .s_axis_tuser(rx_axis_tuser_0),
        .m_ctl_axis_tdata(ctl_rx_axis_tdata), .m_ctl_axis_tkeep(ctl_rx_axis_tkeep),
        .m_ctl_axis_tvalid(ctl_rx_axis_tvalid), .m_ctl_axis_tlast(ctl_rx_axis_tlast),
        .m_ctl_axis_tuser(ctl_rx_axis_tuser),
        .clk(clk), .rst(rst), .enable(1'b1),
        .local_mac(network_local_mac), .local_ip(network_local_ip), .bulk_port(bulk_udp_port),
        .m_bulk_axis_tdata(m_bulk_axis_tdata), .m_bulk_axis_tvalid(m_bulk_axis_tvalid),
        .m_bulk_axis_tready(m_bulk_axis_tready), .m_bulk_axis_tlast(m_bulk_axis_tlast),
        .stat_frames(bulk_rx_frames), .stat_dropped_full(bulk_rx_dropped_full),
        .stat_dropped_bad(bulk_rx_dropped_bad)
    );

    ethernet_adapter_100g inst_ethernet_adapter (
        //-------------------------------------------------------------------------
        // Ethernet adapter
        //  . Clock and Reset
        .clk         (clk_axis),
        .user_rx_reset_0 (user_rx_reset_0),
        .user_tx_reset_0 (user_tx_reset_0),
        //-------------------------------------------------------------------------
        // MAC AXIS Interface
        //  . RX
        .rx_axis_tvalid_0 (ctl_rx_axis_tvalid),
        .rx_axis_tdata_0  (ctl_rx_axis_tdata ),
        .rx_axis_tuser_0  (ctl_rx_axis_tuser ),
        .rx_axis_tkeep_0  (ctl_rx_axis_tkeep ),
        .rx_axis_tlast_0  (ctl_rx_axis_tlast ),
        //  . TX
        .tx_axis_tready_0 (tx_axis_tready_0),
        .tx_axis_tvalid_0 (tx_axis_tvalid_0),
        .tx_axis_tdata_0  (tx_axis_tdata_0  ),
        .tx_axis_tkeep_0  (tx_axis_tkeep_0  ),
        .tx_axis_tuser_0  (tx_axis_tuser_0  ),
        .tx_axis_tlast_0  (tx_axis_tlast_0  ),

        //-------------------------------------------------------------------------
        // Axis 64bit data
        // . RX
        .udp_rx_axis_tvalid(udp_rx_axis_tvalid),
        .udp_rx_axis_tdata(udp_rx_axis_tdata),
        .udp_rx_axis_tuser(udp_rx_axis_tuser),
        .udp_rx_axis_tkeep(udp_rx_axis_tkeep),
        .udp_rx_axis_tlast(udp_rx_axis_tlast),
        // . TX
        .udp_tx_axis_tready(udp_tx_axis_tready),
        .udp_tx_axis_tvalid(udp_tx_axis_tvalid),
        .udp_tx_axis_tdata(udp_tx_axis_tdata),
        .udp_tx_axis_tkeep(udp_tx_axis_tkeep),
        .udp_tx_axis_tuser(udp_tx_axis_tuser),
        .udp_tx_axis_tlast(udp_tx_axis_tlast)
    );

    fpga_core core_inst (
        .clk(clk),
        .rst(rst),
        .network_local_mac(network_local_mac),
        .network_local_ip(network_local_ip),
        .network_gateway_ip(network_gateway_ip),
        .network_subnet_mask(network_subnet_mask),
        .network_clear_arp_cache(network_clear_arp_cache),
        .network_restart_pulse(network_restart_pulse),

        .resp64_tvalid(resp64_tvalid),
        .resp64_tdata(resp64_tdata),
        .resp64_tlast(resp64_tlast),
        .resp64_word_count(resp64_word_count),
        .resp64_tready(resp64_tready),

        .rcv_vld   (rcv_vld),
        .rcv_dat   (rcv_dat),
        .rcv_last  (rcv_last),

        .sfp0_tx_clk        (clk_axis),
        .sfp0_tx_rst        (user_tx_reset_0),
        .tx_fifo_axis_tdata (udp_tx_axis_tdata),
        .tx_fifo_axis_tkeep (udp_tx_axis_tkeep),
        .tx_fifo_axis_tvalid(udp_tx_axis_tvalid),
        .tx_fifo_axis_tready(udp_tx_axis_tready),
        .tx_fifo_axis_tlast (udp_tx_axis_tlast),
        .tx_fifo_axis_tuser (udp_tx_axis_tuser),

        .sfp0_rx_clk        (clk_axis),
        .sfp0_rx_rst        (user_rx_reset_0),
        .rx_fifo_axis_tdata (udp_rx_axis_tdata ),
        .rx_fifo_axis_tkeep (udp_rx_axis_tkeep ),
        .rx_fifo_axis_tvalid(udp_rx_axis_tvalid ),
        .rx_fifo_axis_tlast (udp_rx_axis_tlast ),
        .rx_fifo_axis_tuser (udp_rx_axis_tuser )
    );

endmodule

`resetall
