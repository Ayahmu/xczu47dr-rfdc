 

`resetall
`timescale 1ns / 1ps
//`default_nettype none
 
module udp_100G  
(  
    input   wire    [3:0]       gt_rxp_in       ,
    input   wire    [3:0]       gt_rxn_in       ,
    output  wire    [3:0]       gt_txp_out      ,
    output  wire    [3:0]       gt_txn_out      ,

    input   wire                gt_refclk_p     ,
    input   wire                gt_refclk_n     ,

    output  wire				qsfp_lpmode	    ,
	output  wire				qsfp_resetn	,
	input   wire                clk_100Mhz,
	/////////////////////////////	
    input  wire        clk,
    input  wire        rst, 
    
    input  wire        fifo64_wr,
    input  wire[63:0]  fifo64_din,
    output wire        fifo64_af,
    
    output wire        rcv_vld,
    output wire[63:0]  rcv_dat,
     
    input  wire        loop_en
    
);
    
    assign qsfp_lpmode=1'b0;
    assign qsfp_resetn=1'b1;


    wire 	 		clk_axis		;

    wire 			user_rx_reset_0 ;
    wire 			user_tx_reset_0 ;

    wire 			rx_axis_tvalid_0;
    wire [511:0] 	rx_axis_tdata_0 ;
    wire [0:0] 		rx_axis_tuser_0 ;
    wire [63:0] 	rx_axis_tkeep_0 ;
    wire 			rx_axis_tlast_0 ;

    wire 			tx_axis_tready_0;
    wire 			tx_axis_tvalid_0;
    wire [511:0] 	tx_axis_tdata_0 ;
    wire [63:0] 	tx_axis_tkeep_0 ;
    wire [0:0] 		tx_axis_tuser_0 ;
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


    ethernet_adapter inst_ethernet_adapter (
        //-------------------------------------------------------------------------
        // Ethernet adapter
        //  . Clock and Reset
        .clk         (clk_axis),
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

      

    fpga_core    core_inst ( 
        .clk(clk_312mhz_int),
        .rst(rst),         
         
        .loop_en   (loop_en   ),            
                 
        .fifo64_wr (fifo64_wr ),
        .fifo64_din(fifo64_din),
        .fifo64_af (fifo64_af ),
        
        .rcv_vld   (rcv_vld),
        .rcv_dat   (rcv_dat), 
        
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


//wire rst_vio, send_en, loop_en; 
//vio_0 vio_i (
//  .clk(clk),                // input wire clk
//  .probe_out0(rst_vio),  // output wire [0 : 0] probe_out0
//  .probe_out1(send_en),  // output wire [0 : 0] probe_out1
//  .probe_out2(loop_en)  // output wire [0 : 0] probe_out2 
//);


//reg         fifo64_wr = 0;
//reg [63:0]  fifo64_din = 0;
//wire        fifo64_af;

//always @(posedge clk) begin
//    if (rst | rst_vio) begin
//        fifo64_wr   <= 0;
//        fifo64_din  <= 64'hffffffff_fffffffe;
//    end else begin
//        if (send_en & ~fifo64_af ) begin   //& ~fifo64_wr_rst_busy
//            fifo64_wr   <= 1;
//            fifo64_din[31:0]   <= fifo64_din[31:0] + 2'd2; 
//            fifo64_din[63:32]  <= fifo64_din[63:32] + 2'd2; 
//        end else begin
//            fifo64_wr   <= 0;
//        end
//    end
//end   


endmodule

`resetall
