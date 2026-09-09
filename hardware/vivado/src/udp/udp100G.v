 

`resetall
`timescale 1ns / 1ps
//`default_nettype none

// Vivado's project manager can auto-disable an external XXV black-box stub
// when the XCI is present.  Keeping the parent-synthesis declaration in this
// source file makes it part of the guaranteed compile order.  The module name
// intentionally remains xxv_ethernet so the synthesized cell can be replaced
// by the reference XXV OOC checkpoint during implementation.
`ifdef PARENT_RTL_SYNTH
module xxv_ethernet (
    input wire gt_rxp_in_0, input wire gt_rxn_in_0,
    output wire gt_txp_out_0, output wire gt_txn_out_0,
    input wire gt_refclk_p, input wire gt_refclk_n,
    output wire tx_clk_out_0, input wire rx_core_clk_0,
    output wire rx_clk_out_0, input wire s_axi_aclk_0,
    input wire s_axi_aresetn_0, input wire [31:0] s_axi_awaddr_0,
    input wire s_axi_awvalid_0, output wire s_axi_awready_0,
    input wire [31:0] s_axi_wdata_0, input wire [3:0] s_axi_wstrb_0,
    input wire s_axi_wvalid_0, output wire s_axi_wready_0,
    output wire [1:0] s_axi_bresp_0, output wire s_axi_bvalid_0,
    input wire s_axi_bready_0, input wire [31:0] s_axi_araddr_0,
    input wire s_axi_arvalid_0, output wire s_axi_arready_0,
    output wire [31:0] s_axi_rdata_0, output wire [1:0] s_axi_rresp_0,
    output wire s_axi_rvalid_0, input wire s_axi_rready_0,
    input wire pm_tick_0, input wire rx_reset_0, output wire user_rx_reset_0,
    output wire rx_axis_tvalid_0, output wire [63:0] rx_axis_tdata_0,
    output wire rx_axis_tlast_0, output wire [7:0] rx_axis_tkeep_0,
    output wire rx_axis_tuser_0, output wire stat_rx_block_lock_0,
    input wire tx_reset_0, output wire user_tx_reset_0,
    output wire tx_axis_tready_0, input wire tx_axis_tvalid_0,
    input wire [63:0] tx_axis_tdata_0, input wire tx_axis_tlast_0,
    input wire [7:0] tx_axis_tkeep_0, input wire tx_axis_tuser_0,
    input wire [55:0] tx_preamblein_0, input wire ctl_tx_send_lfi_0,
    input wire ctl_tx_send_rfi_0, input wire ctl_tx_send_idle_0,
    input wire gtwiz_reset_tx_datapath_0, input wire gtwiz_reset_rx_datapath_0,
    input wire [2:0] txoutclksel_in_0, input wire [2:0] rxoutclksel_in_0,
    input wire qpllreset_in_0, output wire gt_refclk_out,
    input wire sys_reset, input wire dclk
);
assign gt_txp_out_0 = 1'b0; assign gt_txn_out_0 = 1'b0;
assign tx_clk_out_0 = rx_core_clk_0; assign rx_clk_out_0 = rx_core_clk_0;
assign s_axi_awready_0 = 1'b0; assign s_axi_wready_0 = 1'b0;
assign s_axi_bresp_0 = 2'b0; assign s_axi_bvalid_0 = 1'b0;
assign s_axi_arready_0 = 1'b0; assign s_axi_rdata_0 = 32'b0;
assign s_axi_rresp_0 = 2'b0; assign s_axi_rvalid_0 = 1'b0;
assign user_rx_reset_0 = 1'b1; assign user_tx_reset_0 = 1'b1;
assign tx_axis_tready_0 = 1'b0;
assign rx_axis_tvalid_0 = 1'b0; assign rx_axis_tdata_0 = 64'b0;
assign rx_axis_tlast_0 = 1'b0; assign rx_axis_tkeep_0 = 8'b0;
assign rx_axis_tuser_0 = 1'b0; assign stat_rx_block_lock_0 = 1'b0;
assign gt_refclk_out = gt_refclk_p;
endmodule
`endif
 
module udp_10G
(  
    input   wire      gt_rxp_in       ,
    input   wire      gt_rxn_in       ,
    output  wire      gt_txp_out      ,
    output  wire      gt_txn_out      ,

    input   wire       gt_refclk_p     ,
    input   wire       gt_refclk_n     ,
 
	input   wire       clk_100Mhz,
	output  wire       calibration_clk_out,
	/////////////////////////////	
    input  wire        clk,
    input  wire        rst,
    input  wire [47:0] network_local_mac,
    input  wire [31:0] network_local_ip,
    input  wire [31:0] network_gateway_ip,
    input  wire [31:0] network_subnet_mask,
    input  wire [15:0] network_udp_port,
    input  wire        network_clear_arp_cache,
    input  wire        network_restart_pulse,
    
    input  wire        fifo64_wr,
    input  wire[63:0]  fifo64_din,
    output wire        fifo64_af,

    input  wire        resp64_tvalid,
    input  wire[63:0]  resp64_tdata,
    input  wire        resp64_tlast,
    input  wire[15:0]  resp64_word_count,
    output wire        resp64_tready,
    output wire[7:0]   control_tx_debug,
    
    output wire        rcv_vld,
    output wire[63:0]  rcv_dat,
    output wire        rcv_last,
     
    input   wire    [23:0]       gap_num_vio       ,
    input  wire        loop_en
    
);
     

    wire 	 		clk_axis		;

    wire 			user_rx_reset_0 ;
    wire 			user_tx_reset_0 ;

    wire 			rx_axis_tvalid_0;
    wire [63:0] 	rx_axis_tdata_0 ;
    wire 	rx_axis_tuser_0 ;
    wire [7:0] 	rx_axis_tkeep_0 ;
    wire 			rx_axis_tlast_0 ;

    wire 			tx_axis_tready_0;
    wire 			tx_axis_tvalid_0;
    wire [63:0] 	tx_axis_tdata_0 ;
    wire [7:0] 	tx_axis_tkeep_0 ;
    wire 	tx_axis_tuser_0 ;
    wire  			tx_axis_tlast_0 ;

    wire 			udp_rx_axis_tvalid;
    wire [63:0] 	udp_rx_axis_tdata ;
    wire [0:0] 		udp_rx_axis_tuser ;
    wire [7:0 ] 	udp_rx_axis_tkeep ;
    wire 			udp_rx_axis_tlast ;

    wire 			udp_tx_axis_tready;
    wire 			udp_tx_axis_tvalid;
    wire [63:0] 	udp_tx_axis_tdata ;
    wire [7:0 ] 	udp_tx_axis_tkeep ;
    wire [0:0] 		udp_tx_axis_tuser ;
    wire  			udp_tx_axis_tlast ;
    
    
//axi lite signals	for xxv ethernet
wire     [10:0]   s_axi_awaddr;
wire              s_axi_awvalid;

wire              s_axi_awready;
wire     [31:0]   s_axi_wdata;
wire     [3:0]    s_axi_wstrb;
wire              s_axi_wvalid;
wire              s_axi_wready;

wire     [1:0]    s_axi_bresp;
wire              s_axi_bvalid;
wire              s_axi_bready;
wire     [10:0]   s_axi_araddr;
wire              s_axi_arvalid;
wire              s_axi_arready;

wire     [31:0]   s_axi_rdata;
wire     [1:0]    s_axi_rresp;
wire              s_axi_rvalid;
wire              s_axi_rready;	
	
wire            stat_rx_block_lock; 

    wire       tx_clk_out;    
    wire       rx_clk_out;
    assign calibration_clk_out = tx_clk_out;
    
/* Instantiate 10G axi configuration module */	
 xxv_ethernet_0_axi4_lite_user_if i_xxv_ethernet_0_axi4_lite_user_if (
 .s_axi_aclk 		(clk_100Mhz),
 .s_axi_sreset 		(rst ),
 .stat_rx_aligned 	(stat_rx_block_lock),
 .stat_reg_compare 	(),
 .rx_gt_locked		(1'b1),
 .restart 			(),
 .completion_status (0),
 .s_axi_pm_tick 	(1'b0),
 .s_axi_awaddr 		(s_axi_awaddr),
 .s_axi_awvalid 	(s_axi_awvalid),
 .s_axi_awready 	(s_axi_awready),
 .s_axi_wdata 		(s_axi_wdata),
 .s_axi_wstrb 		(s_axi_wstrb),
 .s_axi_wvalid 		(s_axi_wvalid),
 .s_axi_wready 		(s_axi_wready),
 .s_axi_bresp 		(s_axi_bresp),
 .s_axi_bvalid 		(s_axi_bvalid),
 .s_axi_bready 		(s_axi_bready),
 .s_axi_araddr 		(s_axi_araddr),
 .s_axi_arvalid 	(s_axi_arvalid),
 .s_axi_arready 	(s_axi_arready),
 .s_axi_rdata 		(s_axi_rdata),
 .s_axi_rresp 		(s_axi_rresp),
 .s_axi_rvalid 		(s_axi_rvalid),
 .s_axi_rready 		(s_axi_rready)
);
 
// The parent synthesis flow uses a uniquely named black box so Vivado does
// not auto-disable it as a duplicate of the managed XXV XCI.  Implementation
// replaces this preserved cell with the reference XXV Ethernet DCP.
wire gt_refclk_out;

`ifdef PARENT_XXV_BLACKBOX
xxv_ethernet_parent_blackbox DUT
`else
xxv_ethernet DUT
`endif
(
    .gt_rxp_in_0 	(gt_rxp_in ),
    .gt_rxn_in_0 	(gt_rxn_in ),
    .gt_txp_out_0 	(gt_txp_out),
    .gt_txn_out_0 	(gt_txn_out),
    .gt_refclk_p 	(gt_refclk_p),
    .gt_refclk_n 	(gt_refclk_n),
    
    .tx_clk_out_0 	(tx_clk_out),
    .rx_core_clk_0 	(rx_clk_out),//in
    .rx_clk_out_0 	(rx_clk_out), 
 
    .s_axi_aclk_0 		(clk_100Mhz),
    .s_axi_aresetn_0 	(~rst),
    // The XXV IP has a 32-bit AXI-Lite address port; this controller only
    // addresses its 2 KiB register window.
    .s_axi_awaddr_0 	({21'b0, s_axi_awaddr}),
    .s_axi_awvalid_0 	(s_axi_awvalid),
    .s_axi_awready_0 	(s_axi_awready),
    .s_axi_wdata_0 		(s_axi_wdata),
    .s_axi_wstrb_0 		(s_axi_wstrb),
    .s_axi_wvalid_0 	(s_axi_wvalid),
    .s_axi_wready_0 	(s_axi_wready),
    .s_axi_bresp_0 		(s_axi_bresp),
    .s_axi_bvalid_0 	(s_axi_bvalid),
    .s_axi_bready_0 	(s_axi_bready),
    .s_axi_araddr_0 	({21'b0, s_axi_araddr}),
    .s_axi_arvalid_0 	(s_axi_arvalid),
    .s_axi_arready_0 	(s_axi_arready),
    .s_axi_rdata_0 		(s_axi_rdata),
    .s_axi_rresp_0 		(s_axi_rresp),
    .s_axi_rvalid_0 	(s_axi_rvalid),
    .s_axi_rready_0 	(s_axi_rready), 
	
    .pm_tick_0 			(1'b0),
    .rx_reset_0 		(1'b0),
    .user_rx_reset_0 	(user_rx_reset_0),  
        
//// RX User Interface Signals
    .rx_axis_tvalid_0 	(rx_axis_tvalid_0),
    .rx_axis_tdata_0 	(rx_axis_tdata_0),
    .rx_axis_tlast_0 	(rx_axis_tlast_0),
    .rx_axis_tkeep_0 	(rx_axis_tkeep_0),
    .rx_axis_tuser_0 	(rx_axis_tuser_0), 

//// RX Stats Signals
	.stat_rx_block_lock_0 (stat_rx_block_lock),

	.tx_reset_0 		(1'b0),
	.user_tx_reset_0 	(user_tx_reset_0),
//// TX User Interface Signals
    .tx_axis_tready_0 	(tx_axis_tready_0),
    .tx_axis_tvalid_0 	(tx_axis_tvalid_0),
    .tx_axis_tdata_0 	(tx_axis_tdata_0 ),
    .tx_axis_tlast_0 	(tx_axis_tlast_0 ),
    .tx_axis_tkeep_0 	(tx_axis_tkeep_0 ),
    .tx_axis_tuser_0 	(tx_axis_tuser_0 ), 
    .tx_preamblein_0 	(56'b0),

//// TX Control Signals
    .ctl_tx_send_lfi_0 	(1'b0),
    .ctl_tx_send_rfi_0 	(1'b0),
    .ctl_tx_send_idle_0 (1'b0),

    .gtwiz_reset_tx_datapath_0 	(1'b0),
    .gtwiz_reset_rx_datapath_0 	(1'b0), 
    .txoutclksel_in_0 			(3'b101),
    .rxoutclksel_in_0 			(3'b101),
    .qpllreset_in_0 			( 1'b0),
    .gt_refclk_out 				(gt_refclk_out),
    .sys_reset 					(rst ),
    .dclk 						(clk_100Mhz)
);
	
    ethernet_adapter inst_ethernet_adapter (
        //-------------------------------------------------------------------------
        // Ethernet adapter
        //  . Clock and Reset 
    .tx_clk  	(tx_clk_out), 
    .rx_clk  	(rx_clk_out), 
        .rst         (rst),

        .user_rx_reset_0 (user_rx_reset_0),
        .user_tx_reset_0 (user_tx_reset_0),
        //-------------------------------------------------------------------------
        // MAC AXIS Interface
        //  . RX
        .rx_axis_tvalid_0 (rx_axis_tvalid_0),
        .rx_axis_tdata_0  (rx_axis_tdata_0  ),
        .rx_axis_tuser_0  (rx_axis_tuser_0  ),
        .rx_axis_tkeep_0  (rx_axis_tkeep_0),
        .rx_axis_tlast_0  (rx_axis_tlast_0),
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
        .network_udp_port(network_udp_port),
        .network_clear_arp_cache(network_clear_arp_cache),
        .network_restart_pulse(network_restart_pulse),
         
        .loop_en   (loop_en   ),           
        .gap_num_vio(gap_num_vio), 
                 
        .fifo64_wr (fifo64_wr ),
        .fifo64_din(fifo64_din),
        .fifo64_af (fifo64_af ),

        .resp64_tvalid(resp64_tvalid),
        .resp64_tdata(resp64_tdata),
        .resp64_tlast(resp64_tlast),
        .resp64_word_count(resp64_word_count),
        .resp64_tready(resp64_tready),
        .control_tx_debug(control_tx_debug),
        
        .rcv_vld   (rcv_vld),
        .rcv_dat   (rcv_dat),
        .rcv_last  (rcv_last),
        
        .sfp0_tx_clk        (tx_clk_out),
        .sfp0_tx_rst        (user_tx_reset_0),
        .tx_fifo_axis_tdata (udp_tx_axis_tdata),
        .tx_fifo_axis_tkeep (udp_tx_axis_tkeep),
        .tx_fifo_axis_tvalid(udp_tx_axis_tvalid),
        .tx_fifo_axis_tready(udp_tx_axis_tready),
        .tx_fifo_axis_tlast (udp_tx_axis_tlast),
        .tx_fifo_axis_tuser (udp_tx_axis_tuser),

        .sfp0_rx_clk        (rx_clk_out),
        .sfp0_rx_rst        (user_rx_reset_0),
        .rx_fifo_axis_tdata (udp_rx_axis_tdata ),
        .rx_fifo_axis_tkeep (udp_rx_axis_tkeep ),
        .rx_fifo_axis_tvalid(udp_rx_axis_tvalid ),
        .rx_fifo_axis_tlast (udp_rx_axis_tlast ),
        .rx_fifo_axis_tuser (udp_rx_axis_tuser )
    );


endmodule

`resetall
