`timescale 1 ns/1 ps

module ethernet_adapter (
    //-------------------------------------------------------------------------
    // Ethernet adapter
    //  . Clock and Reset
    input   wire                    tx_clk         ,
    input   wire                    rx_clk         ,
    input   wire                    rst         ,

    input	wire 			        user_rx_reset_0 ,
	input	wire 			        user_tx_reset_0 ,

    //-------------------------------------------------------------------------
    // MAC AXIS Interface
    //  . RX
	input	wire 			        rx_axis_tvalid_0,
	input	wire [63:0] 	        rx_axis_tdata_0 ,
	input	wire [0:0] 		        rx_axis_tuser_0 ,
	input	wire [7:0] 	            rx_axis_tkeep_0 ,
	input	wire 			        rx_axis_tlast_0 ,
    //  . TX
	input 	wire 			        tx_axis_tready_0,
	output	wire 			        tx_axis_tvalid_0,
	output	wire [63:0] 	        tx_axis_tdata_0 ,
	output	wire [7:0] 	            tx_axis_tkeep_0 ,
	output	wire [0:0] 		        tx_axis_tuser_0 ,
	output	wire  			        tx_axis_tlast_0 ,

    //-------------------------------------------------------------------------
    // Axis 64bit data
    // . RX
    output	wire 			        udp_rx_axis_tvalid,
	output	wire [63:0] 	        udp_rx_axis_tdata ,
	output	wire [0:0] 		        udp_rx_axis_tuser ,
	output	wire [7:0] 	            udp_rx_axis_tkeep ,
	output	wire 			        udp_rx_axis_tlast , 
    // . TX
    output 	wire 			        udp_tx_axis_tready,
	input	wire 			        udp_tx_axis_tvalid,
	input	wire [63:0] 	        udp_tx_axis_tdata ,
	input	wire [7:0] 	            udp_tx_axis_tkeep ,
	input	wire [0:0] 		        udp_tx_axis_tuser ,
	input	wire  			        udp_tx_axis_tlast 
    
    );

    axis_fifo_adapter #
    (
        .DEPTH(9216),
        .S_DATA_WIDTH(64),
        .M_DATA_WIDTH(64),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(1),
        .RAM_PIPELINE (1),
        .OUTPUT_FIFO_ENABLE (0),
        .FRAME_FIFO (0),
        .USER_BAD_FRAME_VALUE (1),
        .USER_BAD_FRAME_MASK (1),
        .DROP_OVERSIZE_FRAME (0),
        .DROP_BAD_FRAME (0),
        .DROP_WHEN_FULL (0),
        .MARK_WHEN_FULL (0),
        .PAUSE_ENABLE (0),
        .FRAME_PAUSE (0)
    )
    inst_axis_fifo_adapter_rx
    (
        .clk(rx_clk),
        .rst(user_rx_reset_0),

        /*
        * AXI input
        */
        .s_axis_tdata(rx_axis_tdata_0),
        .s_axis_tkeep(rx_axis_tkeep_0),
        .s_axis_tvalid(rx_axis_tvalid_0),
        .s_axis_tready(),
        .s_axis_tlast(rx_axis_tlast_0),
        .s_axis_tid('d0),
        .s_axis_tdest('d0),
        .s_axis_tuser(rx_axis_tuser_0),

        /*
        * AXI output
        */
        .m_axis_tdata(udp_rx_axis_tdata),
        .m_axis_tkeep(udp_rx_axis_tkeep),
        .m_axis_tvalid(udp_rx_axis_tvalid),
        .m_axis_tready(1'b1),
        .m_axis_tlast(udp_rx_axis_tlast),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(udp_rx_axis_tuser),

        /*
        * Pause
        */
        .pause_req(1'b0),
        .pause_ack(),

        /*
        * Status
        */
        .status_depth(),
        .status_depth_commit(),
        .status_overflow(),
        .status_bad_frame(),
        .status_good_frame()
    );


    wire 			        adj_tx_axis_tready;
	wire 			        adj_tx_axis_tvalid;
	wire [63:0] 	        adj_tx_axis_tdata ;
	wire [7:0] 	            adj_tx_axis_tkeep ;
	wire [0:0] 		        adj_tx_axis_tuser ;
	wire  			        adj_tx_axis_tlast ;


    axis_frame_length_adjust #
    (
        .DATA_WIDTH(64),
        .KEEP_ENABLE(1),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(1)
    )
    inst_tx_frame_length_adjust
    (
        .clk(tx_clk),
        .rst(user_tx_reset_0),

        /*
        * AXI input
        */
        .s_axis_tdata   (udp_tx_axis_tdata),
        .s_axis_tkeep   (udp_tx_axis_tkeep),
        .s_axis_tvalid  (udp_tx_axis_tvalid),
        .s_axis_tready  (udp_tx_axis_tready),
        .s_axis_tlast   (udp_tx_axis_tlast),
        .s_axis_tid     ('d0),
        .s_axis_tdest   ('d0),
        .s_axis_tuser   (udp_tx_axis_tuser),

        /*
        * AXI output
        */
        .m_axis_tdata   (adj_tx_axis_tdata),
        .m_axis_tkeep   (adj_tx_axis_tkeep),
        .m_axis_tvalid  (adj_tx_axis_tvalid),
        .m_axis_tready  (adj_tx_axis_tready),
        .m_axis_tlast   (adj_tx_axis_tlast),
        .m_axis_tid     (),
        .m_axis_tdest   (),
        .m_axis_tuser   (adj_tx_axis_tuser),

        /*
        * Status
        */
        .status_valid(),
        .status_ready(1'b1),
        .status_frame_pad(),
        .status_frame_truncate(),
        .status_frame_length(),
        .status_frame_original_length(),

        /*
        * Configuration
        */
        .length_min(64),
        .length_max(9216)
    );

    axis_fifo_adapter #
    (
        .DEPTH(9216),
        .S_DATA_WIDTH(64),
        .M_DATA_WIDTH(64),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(1),
        .RAM_PIPELINE (1),
        .OUTPUT_FIFO_ENABLE (0),
        .FRAME_FIFO (1),
        .USER_BAD_FRAME_VALUE (1),
        .USER_BAD_FRAME_MASK (1),
        .DROP_OVERSIZE_FRAME (1),
        .DROP_BAD_FRAME (0),
        .DROP_WHEN_FULL (0),
        .MARK_WHEN_FULL (0),
        .PAUSE_ENABLE (0),
        .FRAME_PAUSE (0)
    )
    inst_axis_fifo_adapter_tx
    (
        .clk(tx_clk),
        .rst(user_tx_reset_0),

        /*
        * AXI input
        */
        .s_axis_tdata(adj_tx_axis_tdata),
        .s_axis_tkeep(adj_tx_axis_tkeep),
        .s_axis_tvalid(adj_tx_axis_tvalid),
        .s_axis_tready(adj_tx_axis_tready),
        .s_axis_tlast(adj_tx_axis_tlast),
        .s_axis_tid(),
        .s_axis_tdest(),
        .s_axis_tuser(adj_tx_axis_tuser),

        /*
        * AXI output
        */
        .m_axis_tdata(tx_axis_tdata_0),
        .m_axis_tkeep(tx_axis_tkeep_0),
        .m_axis_tvalid(tx_axis_tvalid_0),
        .m_axis_tready(tx_axis_tready_0),
        .m_axis_tlast(tx_axis_tlast_0),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(tx_axis_tuser_0),

        /*
        * Pause
        */
        .pause_req(1'b0),
        .pause_ack(),

        /*
        * Status
        */
        .status_depth(),
        .status_depth_commit(),
        .status_overflow(),
        .status_bad_frame(),
        .status_good_frame()
    );



endmodule