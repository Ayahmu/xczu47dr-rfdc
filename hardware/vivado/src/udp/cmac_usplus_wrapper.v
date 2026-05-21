`timescale 1 ns/1 ps
    
module cmac_usplus_wrapper (
	input  	wire     						 init_clk						   ,
	input  	wire     						 drp_clk 						   ,
	input  	wire     			             sys_reset                         ,       

	output  wire 					   		 clk_axis 						   ,

	output	wire 	           				 usr_rx_reset					   ,
	output	wire 	           				 rx_axis_tvalid					   ,
	output	wire 	[511:0]    				 rx_axis_tdata					   ,
	output	wire 	           				 rx_axis_tlast					   ,
	output	wire 	[63:0]     				 rx_axis_tkeep					   ,
  	output	wire 	           				 rx_axis_tuser					   ,

  	output	wire 	           				 usr_tx_reset 					   ,
	input	wire 	[511:0]    				 tx_axis_tdata					   ,
	input	wire 	           				 tx_axis_tlast					   ,
	input	wire 	[63:0]     				 tx_axis_tkeep					   ,
	input	wire 	           				 tx_axis_tuser					   ,
	input	wire 	           				 tx_axis_tvalid 				   ,
	output	wire            				 tx_axis_tready 				   ,


    input 	wire 	[3 :0]		             gt_rxp_in                         ,       
    input 	wire 	[3 :0]					 gt_rxn_in 						   ,
    output	wire 	[3 :0]		             gt_txp_out                        ,       
    output	wire 	[3 :0]		             gt_txn_out                        ,       

    input 	wire     			             gt_ref_clk_p                      ,       
    input 	wire     						 gt_ref_clk_n
    );

  	
  	
	wire [11 :0]    gt_loopback_in;

	//// For other GT loopback options please change the value appropriately
	//// For example, for Near End PMA loopback for 4 Lanes update the gt_loopback_in = {4{3'b010}};
	//// For more information and settings on loopback, refer GT Transceivers user guide

	assign gt_loopback_in  = {4{3'b000}};

	wire            gt_ref_clk_out;
	// wire            usr_rx_reset;
	// wire            rx_axis_tvalid;
	// wire [511:0]    rx_axis_tdata;
	// wire            rx_axis_tlast;
	// wire [63:0]     rx_axis_tkeep;
	// wire            rx_axis_tuser;

	// wire            tx_axis_tready;
	// wire            tx_axis_tvalid;
	// wire [511:0]    tx_axis_tdata;
	// wire            tx_axis_tlast;
	// wire [63:0]     tx_axis_tkeep;
	// wire            tx_axis_tuser;
	wire            tx_ovfout;
	wire            tx_unfout;
	wire [55:0]     tx_preamblein;
	// wire            usr_tx_reset;
	wire            rxusrclk2;
	wire [8:0]      stat_tx_pause_valid;
	wire            stat_tx_pause;
	wire            stat_tx_user_pause;
	wire [8:0]      ctl_tx_pause_enable;
	wire [15:0]     ctl_tx_pause_quanta0;
	wire [15:0]     ctl_tx_pause_quanta1;
	wire [15:0]     ctl_tx_pause_quanta2;
	wire [15:0]     ctl_tx_pause_quanta3;
	wire [15:0]     ctl_tx_pause_quanta4;
	wire [15:0]     ctl_tx_pause_quanta5;
	wire [15:0]     ctl_tx_pause_quanta6;
	wire [15:0]     ctl_tx_pause_quanta7;
	wire [15:0]     ctl_tx_pause_quanta8;
	wire [15:0]     ctl_tx_pause_refresh_timer0;
	wire [15:0]     ctl_tx_pause_refresh_timer1;
	wire [15:0]     ctl_tx_pause_refresh_timer2;
	wire [15:0]     ctl_tx_pause_refresh_timer3;
	wire [15:0]     ctl_tx_pause_refresh_timer4;
	wire [15:0]     ctl_tx_pause_refresh_timer5;
	wire [15:0]     ctl_tx_pause_refresh_timer6;
	wire [15:0]     ctl_tx_pause_refresh_timer7;
	wire [15:0]     ctl_tx_pause_refresh_timer8;
	wire [8:0]      ctl_tx_pause_req;
	wire            ctl_tx_resend_pause;
	wire            stat_rx_pause;
	wire [15:0]     stat_rx_pause_quanta0;
	wire [15:0]     stat_rx_pause_quanta1;
	wire [15:0]     stat_rx_pause_quanta2;
	wire [15:0]     stat_rx_pause_quanta3;
	wire [15:0]     stat_rx_pause_quanta4;
	wire [15:0]     stat_rx_pause_quanta5;
	wire [15:0]     stat_rx_pause_quanta6;
	wire [15:0]     stat_rx_pause_quanta7;
	wire [15:0]     stat_rx_pause_quanta8;
	wire [8:0]      stat_rx_pause_req;
	wire [8:0]      stat_rx_pause_valid;
	wire            stat_rx_user_pause;
	wire            ctl_rx_check_etype_gcp;
	wire            ctl_rx_check_etype_gpp;
	wire            ctl_rx_check_etype_pcp;
	wire            ctl_rx_check_etype_ppp;
	wire            ctl_rx_check_mcast_gcp;
	wire            ctl_rx_check_mcast_gpp;
	wire            ctl_rx_check_mcast_pcp;
	wire            ctl_rx_check_mcast_ppp;
	wire            ctl_rx_check_opcode_gcp;
	wire            ctl_rx_check_opcode_gpp;
	wire            ctl_rx_check_opcode_pcp;
	wire            ctl_rx_check_opcode_ppp;
	wire            ctl_rx_check_sa_gcp;
	wire            ctl_rx_check_sa_gpp;
	wire            ctl_rx_check_sa_pcp;
	wire            ctl_rx_check_sa_ppp;
	wire            ctl_rx_check_ucast_gcp;
	wire            ctl_rx_check_ucast_gpp;
	wire            ctl_rx_check_ucast_pcp;
	wire            ctl_rx_check_ucast_ppp;
	wire            ctl_rx_enable_gcp;
	wire            ctl_rx_enable_gpp;
	wire            ctl_rx_enable_pcp;
	wire            ctl_rx_enable_ppp;
	wire [8:0]      ctl_rx_pause_ack;
	wire [8:0]      ctl_rx_pause_enable;
	wire            stat_rx_aligned;
	wire            stat_rx_aligned_err;
	wire [2:0]      stat_rx_bad_code;
	wire [2:0]      stat_rx_bad_fcs;
	wire            stat_rx_bad_preamble;
	wire            stat_rx_bad_sfd;
	wire            stat_rx_bip_err_0;
	wire            stat_rx_bip_err_1;
	wire            stat_rx_bip_err_10;
	wire            stat_rx_bip_err_11;
	wire            stat_rx_bip_err_12;
	wire            stat_rx_bip_err_13;
	wire            stat_rx_bip_err_14;
	wire            stat_rx_bip_err_15;
	wire            stat_rx_bip_err_16;
	wire            stat_rx_bip_err_17;
	wire            stat_rx_bip_err_18;
	wire            stat_rx_bip_err_19;
	wire            stat_rx_bip_err_2;
	wire            stat_rx_bip_err_3;
	wire            stat_rx_bip_err_4;
	wire            stat_rx_bip_err_5;
	wire            stat_rx_bip_err_6;
	wire            stat_rx_bip_err_7;
	wire            stat_rx_bip_err_8;
	wire            stat_rx_bip_err_9;
	wire [19:0]     stat_rx_block_lock;
	wire            stat_rx_broadcast;
	wire [2:0]      stat_rx_fragment;
	wire [1:0]      stat_rx_framing_err_0;
	wire [1:0]      stat_rx_framing_err_1;
	wire [1:0]      stat_rx_framing_err_10;
	wire [1:0]      stat_rx_framing_err_11;
	wire [1:0]      stat_rx_framing_err_12;
	wire [1:0]      stat_rx_framing_err_13;
	wire [1:0]      stat_rx_framing_err_14;
	wire [1:0]      stat_rx_framing_err_15;
	wire [1:0]      stat_rx_framing_err_16;
	wire [1:0]      stat_rx_framing_err_17;
	wire [1:0]      stat_rx_framing_err_18;
	wire [1:0]      stat_rx_framing_err_19;
	wire [1:0]      stat_rx_framing_err_2;
	wire [1:0]      stat_rx_framing_err_3;
	wire [1:0]      stat_rx_framing_err_4;
	wire [1:0]      stat_rx_framing_err_5;
	wire [1:0]      stat_rx_framing_err_6;
	wire [1:0]      stat_rx_framing_err_7;
	wire [1:0]      stat_rx_framing_err_8;
	wire [1:0]      stat_rx_framing_err_9;
	wire            stat_rx_framing_err_valid_0;
	wire            stat_rx_framing_err_valid_1;
	wire            stat_rx_framing_err_valid_10;
	wire            stat_rx_framing_err_valid_11;
	wire            stat_rx_framing_err_valid_12;
	wire            stat_rx_framing_err_valid_13;
	wire            stat_rx_framing_err_valid_14;
	wire            stat_rx_framing_err_valid_15;
	wire            stat_rx_framing_err_valid_16;
	wire            stat_rx_framing_err_valid_17;
	wire            stat_rx_framing_err_valid_18;
	wire            stat_rx_framing_err_valid_19;
	wire            stat_rx_framing_err_valid_2;
	wire            stat_rx_framing_err_valid_3;
	wire            stat_rx_framing_err_valid_4;
	wire            stat_rx_framing_err_valid_5;
	wire            stat_rx_framing_err_valid_6;
	wire            stat_rx_framing_err_valid_7;
	wire            stat_rx_framing_err_valid_8;
	wire            stat_rx_framing_err_valid_9;
	wire            stat_rx_got_signal_os;
	wire            stat_rx_hi_ber;
	wire            stat_rx_inrangeerr;
	wire            stat_rx_internal_local_fault;
	wire            stat_rx_jabber;
	wire            stat_rx_local_fault;
	wire [19:0]     stat_rx_mf_err;
	wire [19:0]     stat_rx_mf_len_err;
	wire [19:0]     stat_rx_mf_repeat_err;
	wire            stat_rx_misaligned;
	wire            stat_rx_multicast;
	wire            stat_rx_oversize;
	wire            stat_rx_packet_1024_1518_bytes;
	wire            stat_rx_packet_128_255_bytes;
	wire            stat_rx_packet_1519_1522_bytes;
	wire            stat_rx_packet_1523_1548_bytes;
	wire            stat_rx_packet_1549_2047_bytes;
	wire            stat_rx_packet_2048_4095_bytes;
	wire            stat_rx_packet_256_511_bytes;
	wire            stat_rx_packet_4096_8191_bytes;
	wire            stat_rx_packet_512_1023_bytes;
	wire            stat_rx_packet_64_bytes;
	wire            stat_rx_packet_65_127_bytes;
	wire            stat_rx_packet_8192_9215_bytes;
	wire            stat_rx_packet_bad_fcs;
	wire            stat_rx_packet_large;
	wire [2:0]      stat_rx_packet_small;
	wire            stat_rx_received_local_fault;
	wire            stat_rx_remote_fault;
	wire            stat_rx_status;
	wire [2:0]      stat_rx_stomped_fcs;
	wire [19:0]     stat_rx_synced;
	wire [19:0]     stat_rx_synced_err;
	wire [2:0]      stat_rx_test_pattern_mismatch;
	wire            stat_rx_toolong;
	wire [6:0]      stat_rx_total_bytes;
	wire [13:0]     stat_rx_total_good_bytes;
	wire            stat_rx_total_good_packets;
	wire [2:0]      stat_rx_total_packets;
	wire            stat_rx_truncated;
	wire [2:0]      stat_rx_undersize;
	wire            stat_rx_unicast;
	wire            stat_rx_vlan;
	wire [19:0]     stat_rx_pcsl_demuxed;
	wire [4:0]      stat_rx_pcsl_number_0;
	wire [4:0]      stat_rx_pcsl_number_1;
	wire [4:0]      stat_rx_pcsl_number_10;
	wire [4:0]      stat_rx_pcsl_number_11;
	wire [4:0]      stat_rx_pcsl_number_12;
	wire [4:0]      stat_rx_pcsl_number_13;
	wire [4:0]      stat_rx_pcsl_number_14;
	wire [4:0]      stat_rx_pcsl_number_15;
	wire [4:0]      stat_rx_pcsl_number_16;
	wire [4:0]      stat_rx_pcsl_number_17;
	wire [4:0]      stat_rx_pcsl_number_18;
	wire [4:0]      stat_rx_pcsl_number_19;
	wire [4:0]      stat_rx_pcsl_number_2;
	wire [4:0]      stat_rx_pcsl_number_3;
	wire [4:0]      stat_rx_pcsl_number_4;
	wire [4:0]      stat_rx_pcsl_number_5;
	wire [4:0]      stat_rx_pcsl_number_6;
	wire [4:0]      stat_rx_pcsl_number_7;
	wire [4:0]      stat_rx_pcsl_number_8;
	wire [4:0]      stat_rx_pcsl_number_9;
	wire            stat_rx_rsfec_am_lock0;
	wire            stat_rx_rsfec_am_lock1;
	wire            stat_rx_rsfec_am_lock2;
	wire            stat_rx_rsfec_am_lock3;
	wire            stat_rx_rsfec_corrected_cw_inc;
	wire            stat_rx_rsfec_cw_inc;
	wire [2:0]      stat_rx_rsfec_err_count0_inc;
	wire [2:0]      stat_rx_rsfec_err_count1_inc;
	wire [2:0]      stat_rx_rsfec_err_count2_inc;
	wire [2:0]      stat_rx_rsfec_err_count3_inc;
	wire            stat_rx_rsfec_hi_ser;
	wire            stat_rx_rsfec_lane_alignment_status;
	wire [13:0]     stat_rx_rsfec_lane_fill_0;
	wire [13:0]     stat_rx_rsfec_lane_fill_1;
	wire [13:0]     stat_rx_rsfec_lane_fill_2;
	wire [13:0]     stat_rx_rsfec_lane_fill_3;
	wire [7:0]      stat_rx_rsfec_lane_mapping;
	wire            stat_rx_rsfec_uncorrected_cw_inc;
	wire            stat_tx_bad_fcs;
	wire            stat_tx_broadcast;
	wire            stat_tx_frame_error;
	wire            stat_tx_local_fault;
	wire            stat_tx_multicast;
	wire            stat_tx_packet_1024_1518_bytes;
	wire            stat_tx_packet_128_255_bytes;
	wire            stat_tx_packet_1519_1522_bytes;
	wire            stat_tx_packet_1523_1548_bytes;
	wire            stat_tx_packet_1549_2047_bytes;
	wire            stat_tx_packet_2048_4095_bytes;
	wire            stat_tx_packet_256_511_bytes;
	wire            stat_tx_packet_4096_8191_bytes;
	wire            stat_tx_packet_512_1023_bytes;
	wire            stat_tx_packet_64_bytes;
	wire            stat_tx_packet_65_127_bytes;
	wire            stat_tx_packet_8192_9215_bytes;
	wire            stat_tx_packet_large;
	wire            stat_tx_packet_small;
	wire [5:0]      stat_tx_total_bytes;
	wire [13:0]     stat_tx_total_good_bytes;
	wire            stat_tx_total_good_packets;
	wire            stat_tx_total_packets;
	wire            stat_tx_unicast;
	wire            stat_tx_vlan;

	wire [7:0]      rx_otn_bip8_0;
	wire [7:0]      rx_otn_bip8_1;
	wire [7:0]      rx_otn_bip8_2;
	wire [7:0]      rx_otn_bip8_3;
	wire [7:0]      rx_otn_bip8_4;
	wire [65:0]     rx_otn_data_0;
	wire [65:0]     rx_otn_data_1;
	wire [65:0]     rx_otn_data_2;
	wire [65:0]     rx_otn_data_3;
	wire [65:0]     rx_otn_data_4;
	wire            rx_otn_ena;
	wire            rx_otn_lane0;
	wire            rx_otn_vlmarker;
	wire [55:0]     rx_preambleout;


	wire            ctl_rx_enable;
	wire            ctl_rx_force_resync;
	wire            ctl_rx_test_pattern;
	wire            ctl_tx_enable;
	wire            ctl_tx_test_pattern;
	// wire            ctl_rsfec_ieee_error_indication_mode;
	wire            ctl_rsfec_ieee_error_indication_mode_int;
	// wire            ctl_rx_rsfec_enable;
	wire            ctl_rx_rsfec_enable_int;
	// wire            ctl_rx_rsfec_enable_correction;
	wire            ctl_rx_rsfec_enable_correction_int;
	// wire            ctl_rx_rsfec_enable_indication;
	wire            ctl_rx_rsfec_enable_indication_int;
	// wire            ctl_tx_rsfec_enable;
	wire            ctl_tx_rsfec_enable_int;
	wire            ctl_tx_send_idle;
	wire            ctl_tx_send_rfi;
	wire            ctl_tx_send_lfi;
	// wire            rx_reset;
	// wire            tx_reset;
	wire [3 :0]     gt_rxrecclkout;
	wire [3 :0]     gt_powergoodout;
	wire            gtwiz_reset_tx_datapath;
	wire            gtwiz_reset_rx_datapath;

	wire            txusrclk2;


	assign gtwiz_reset_tx_datapath    = 1'b0;
	assign gtwiz_reset_rx_datapath    = 1'b0;

	assign clk_axis = txusrclk2;


	cmac_usplus_0 DUT
	(
		.gt_rxp_in                        (gt_rxp_in                        )       , // input wire [3 : 0] gt_rxp_in
		.gt_rxn_in                        (gt_rxn_in                        )       , // input wire [3 : 0] gt_rxn_in
		.gt_txp_out                       (gt_txp_out                       )       , // output wire [3 : 0] gt_txp_out
		.gt_txn_out                       (gt_txn_out                       )       , // output wire [3 : 0] gt_txn_out

		.gt_txusrclk2                     (txusrclk2                        )       , // output wire gt_txusrclk2

		.gt_loopback_in                   (gt_loopback_in                   )       , // input wire [11 : 0] gt_loopback_in

		.gt_rxrecclkout                   (gt_rxrecclkout                   )       , // output wire [3 : 0] gt_rxrecclkout
		.gt_powergoodout                  (gt_powergoodout                  )       , // output wire [3 : 0] gt_powergoodout

		.gtwiz_reset_tx_datapath          (gtwiz_reset_tx_datapath          )       , // input wire gtwiz_reset_tx_datapath
		.gtwiz_reset_rx_datapath          (gtwiz_reset_rx_datapath          )       , // input wire gtwiz_reset_rx_datapath

		.sys_reset                        (sys_reset                        )       , // input wire sys_reset

		.gt_ref_clk_p                     (gt_ref_clk_p                     )       , // input wire gt_ref_clk_p
		.gt_ref_clk_n                     (gt_ref_clk_n                     )       , // input wire gt_ref_clk_n

		.init_clk                         (init_clk                         )       , // input wire init_clk

		.gt_ref_clk_out                   (gt_ref_clk_out                   )       , // output wire gt_ref_clk_out

		.rx_axis_tvalid                   (rx_axis_tvalid                   )       , // output wire rx_axis_tvalid
		.rx_axis_tdata                    (rx_axis_tdata                    )       , // output wire [511 : 0] rx_axis_tdata
		.rx_axis_tkeep                    (rx_axis_tkeep                    )       , // output wire rx_axis_tlast
		.rx_axis_tlast                    (rx_axis_tlast                    )       , // output wire [63 : 0] rx_axis_tkeep
		.rx_axis_tuser                    (rx_axis_tuser                    )       , // output wire rx_axis_tuser

		.rx_otn_bip8_0                    (rx_otn_bip8_0                    )       , // output wire [7 : 0] rx_otn_bip8_0
		.rx_otn_bip8_1                    (rx_otn_bip8_1                    )       , // output wire [7 : 0] rx_otn_bip8_1
		.rx_otn_bip8_2                    (rx_otn_bip8_2                    )       , // output wire [7 : 0] rx_otn_bip8_2
		.rx_otn_bip8_3                    (rx_otn_bip8_3                    )       , // output wire [7 : 0] rx_otn_bip8_3
		.rx_otn_bip8_4                    (rx_otn_bip8_4                    )       , // output wire [7 : 0] rx_otn_bip8_4
		.rx_otn_data_0                    (rx_otn_data_0                    )       , // output wire [65 : 0] rx_otn_data_0
		.rx_otn_data_1                    (rx_otn_data_1                    )       , // output wire [65 : 0] rx_otn_data_1
		.rx_otn_data_2                    (rx_otn_data_2                    )       , // output wire [65 : 0] rx_otn_data_2
		.rx_otn_data_3                    (rx_otn_data_3                    )       , // output wire [65 : 0] rx_otn_data_3
		.rx_otn_data_4                    (rx_otn_data_4                    )       , // output wire [65 : 0] rx_otn_data_4
		.rx_otn_ena                       (rx_otn_ena                       )       , // output wire rx_otn_ena
		.rx_otn_lane0                     (rx_otn_lane0                     )       , // output wire rx_otn_lane0
		.rx_otn_vlmarker                  (rx_otn_vlmarker                  )       , // output wire rx_otn_vlmarker
		.rx_preambleout                   (rx_preambleout                   )       , // output wire [55 : 0] rx_preambleout
		.usr_rx_reset                     (usr_rx_reset                     )       , // output wire usr_rx_reset
		.gt_rxusrclk2                     (rxusrclk2                        )       , // output wire gt_rxusrclk2
		.stat_rx_aligned                  (stat_rx_aligned                  )       , // output wire stat_rx_aligned
		.stat_rx_aligned_err              (stat_rx_aligned_err              )       , // output wire stat_rx_aligned_err
		.stat_rx_bad_code                 (stat_rx_bad_code                 )       , // output wire [2 : 0] stat_rx_bad_code
		.stat_rx_bad_fcs                  (stat_rx_bad_fcs                  )       , // output wire [2 : 0] stat_rx_bad_fcs
		.stat_rx_bad_preamble             (stat_rx_bad_preamble             )       , // output wire stat_rx_bad_preamble
		.stat_rx_bad_sfd                  (stat_rx_bad_sfd                  )       , // output wire stat_rx_bad_sfd
		.stat_rx_bip_err_0                (stat_rx_bip_err_0                )       , // output wire stat_rx_bip_err_0
		.stat_rx_bip_err_1                (stat_rx_bip_err_1                )       , // output wire stat_rx_bip_err_1
		.stat_rx_bip_err_10               (stat_rx_bip_err_10               )       , // output wire stat_rx_bip_err_10
		.stat_rx_bip_err_11               (stat_rx_bip_err_11               )       , // output wire stat_rx_bip_err_11
		.stat_rx_bip_err_12               (stat_rx_bip_err_12               )       , // output wire stat_rx_bip_err_12
		.stat_rx_bip_err_13               (stat_rx_bip_err_13               )       , // output wire stat_rx_bip_err_13
		.stat_rx_bip_err_14               (stat_rx_bip_err_14               )       , // output wire stat_rx_bip_err_14
		.stat_rx_bip_err_15               (stat_rx_bip_err_15               )       , // output wire stat_rx_bip_err_15
		.stat_rx_bip_err_16               (stat_rx_bip_err_16               )       , // output wire stat_rx_bip_err_16
		.stat_rx_bip_err_17               (stat_rx_bip_err_17               )       , // output wire stat_rx_bip_err_17
		.stat_rx_bip_err_18               (stat_rx_bip_err_18               )       , // output wire stat_rx_bip_err_18
		.stat_rx_bip_err_19               (stat_rx_bip_err_19               )       , // output wire stat_rx_bip_err_19
		.stat_rx_bip_err_2                (stat_rx_bip_err_2                )       , // output wire stat_rx_bip_err_2
		.stat_rx_bip_err_3                (stat_rx_bip_err_3                )       , // output wire stat_rx_bip_err_3
		.stat_rx_bip_err_4                (stat_rx_bip_err_4                )       , // output wire stat_rx_bip_err_4
		.stat_rx_bip_err_5                (stat_rx_bip_err_5                )       , // output wire stat_rx_bip_err_5
		.stat_rx_bip_err_6                (stat_rx_bip_err_6                )       , // output wire stat_rx_bip_err_6
		.stat_rx_bip_err_7                (stat_rx_bip_err_7                )       , // output wire stat_rx_bip_err_7
		.stat_rx_bip_err_8                (stat_rx_bip_err_8                )       , // output wire stat_rx_bip_err_8
		.stat_rx_bip_err_9                (stat_rx_bip_err_9                )       , // output wire stat_rx_bip_err_9
		.stat_rx_block_lock               (stat_rx_block_lock               )       , // output wire [19 : 0] stat_rx_block_lock
		.stat_rx_broadcast                (stat_rx_broadcast                )       , // output wire stat_rx_broadcast
		.stat_rx_fragment                 (stat_rx_fragment                 )       , // output wire [2 : 0] stat_rx_fragment
		.stat_rx_framing_err_0            (stat_rx_framing_err_0            )       , // output wire [1 : 0] stat_rx_framing_err_0
		.stat_rx_framing_err_1            (stat_rx_framing_err_1            )       , // output wire [1 : 0] stat_rx_framing_err_1
		.stat_rx_framing_err_10           (stat_rx_framing_err_10           )       , // output wire [1 : 0] stat_rx_framing_err_10
		.stat_rx_framing_err_11           (stat_rx_framing_err_11           )       , // output wire [1 : 0] stat_rx_framing_err_11
		.stat_rx_framing_err_12           (stat_rx_framing_err_12           )       , // output wire [1 : 0] stat_rx_framing_err_12
		.stat_rx_framing_err_13           (stat_rx_framing_err_13           )       , // output wire [1 : 0] stat_rx_framing_err_13
		.stat_rx_framing_err_14           (stat_rx_framing_err_14           )       , // output wire [1 : 0] stat_rx_framing_err_14
		.stat_rx_framing_err_15           (stat_rx_framing_err_15           )       , // output wire [1 : 0] stat_rx_framing_err_15
		.stat_rx_framing_err_16           (stat_rx_framing_err_16           )       , // output wire [1 : 0] stat_rx_framing_err_16
		.stat_rx_framing_err_17           (stat_rx_framing_err_17           )       , // output wire [1 : 0] stat_rx_framing_err_17
		.stat_rx_framing_err_18           (stat_rx_framing_err_18           )       , // output wire [1 : 0] stat_rx_framing_err_18
		.stat_rx_framing_err_19           (stat_rx_framing_err_19           )       , // output wire [1 : 0] stat_rx_framing_err_19
		.stat_rx_framing_err_2            (stat_rx_framing_err_2            )       , // output wire [1 : 0] stat_rx_framing_err_2
		.stat_rx_framing_err_3            (stat_rx_framing_err_3            )       , // output wire [1 : 0] stat_rx_framing_err_3
		.stat_rx_framing_err_4            (stat_rx_framing_err_4            )       , // output wire [1 : 0] stat_rx_framing_err_4
		.stat_rx_framing_err_5            (stat_rx_framing_err_5            )       , // output wire [1 : 0] stat_rx_framing_err_5
		.stat_rx_framing_err_6            (stat_rx_framing_err_6            )       , // output wire [1 : 0] stat_rx_framing_err_6
		.stat_rx_framing_err_7            (stat_rx_framing_err_7            )       , // output wire [1 : 0] stat_rx_framing_err_7
		.stat_rx_framing_err_8            (stat_rx_framing_err_8            )       , // output wire [1 : 0] stat_rx_framing_err_8
		.stat_rx_framing_err_9            (stat_rx_framing_err_9            )       , // output wire [1 : 0] stat_rx_framing_err_9
		.stat_rx_framing_err_valid_0      (stat_rx_framing_err_valid_0      )       , // output wire stat_rx_framing_err_valid_0
		.stat_rx_framing_err_valid_1      (stat_rx_framing_err_valid_1      )       , // output wire stat_rx_framing_err_valid_1
		.stat_rx_framing_err_valid_10     (stat_rx_framing_err_valid_10     )       , // output wire stat_rx_framing_err_valid_10
		.stat_rx_framing_err_valid_11     (stat_rx_framing_err_valid_11     )       , // output wire stat_rx_framing_err_valid_11
		.stat_rx_framing_err_valid_12     (stat_rx_framing_err_valid_12     )       , // output wire stat_rx_framing_err_valid_12
		.stat_rx_framing_err_valid_13     (stat_rx_framing_err_valid_13     )       , // output wire stat_rx_framing_err_valid_13
		.stat_rx_framing_err_valid_14     (stat_rx_framing_err_valid_14     )       , // output wire stat_rx_framing_err_valid_14
		.stat_rx_framing_err_valid_15     (stat_rx_framing_err_valid_15     )       , // output wire stat_rx_framing_err_valid_15
		.stat_rx_framing_err_valid_16     (stat_rx_framing_err_valid_16     )       , // output wire stat_rx_framing_err_valid_16
		.stat_rx_framing_err_valid_17     (stat_rx_framing_err_valid_17     )       , // output wire stat_rx_framing_err_valid_17
		.stat_rx_framing_err_valid_18     (stat_rx_framing_err_valid_18     )       , // output wire stat_rx_framing_err_valid_18
		.stat_rx_framing_err_valid_19     (stat_rx_framing_err_valid_19     )       , // output wire stat_rx_framing_err_valid_19
		.stat_rx_framing_err_valid_2      (stat_rx_framing_err_valid_2      )       , // output wire stat_rx_framing_err_valid_2
		.stat_rx_framing_err_valid_3      (stat_rx_framing_err_valid_3      )       , // output wire stat_rx_framing_err_valid_3
		.stat_rx_framing_err_valid_4      (stat_rx_framing_err_valid_4      )       , // output wire stat_rx_framing_err_valid_4
		.stat_rx_framing_err_valid_5      (stat_rx_framing_err_valid_5      )       , // output wire stat_rx_framing_err_valid_5
		.stat_rx_framing_err_valid_6      (stat_rx_framing_err_valid_6      )       , // output wire stat_rx_framing_err_valid_6
		.stat_rx_framing_err_valid_7      (stat_rx_framing_err_valid_7      )       , // output wire stat_rx_framing_err_valid_7
		.stat_rx_framing_err_valid_8      (stat_rx_framing_err_valid_8      )       , // output wire stat_rx_framing_err_valid_8
		.stat_rx_framing_err_valid_9      (stat_rx_framing_err_valid_9      )       , // output wire stat_rx_framing_err_valid_9
		.stat_rx_got_signal_os            (stat_rx_got_signal_os            )       , // output wire stat_rx_got_signal_os
		.stat_rx_hi_ber                   (stat_rx_hi_ber                   )       , // output wire stat_rx_hi_ber
		.stat_rx_inrangeerr               (stat_rx_inrangeerr               )       , // output wire stat_rx_inrangeerr
		.stat_rx_internal_local_fault     (stat_rx_internal_local_fault     )       , // output wire stat_rx_internal_local_fault
		.stat_rx_jabber                   (stat_rx_jabber                   )       , // output wire stat_rx_jabber
		.stat_rx_local_fault              (stat_rx_local_fault              )       , // output wire stat_rx_local_fault
		.stat_rx_mf_err                   (stat_rx_mf_err                   )       , // output wire [19 : 0] stat_rx_mf_err
		.stat_rx_mf_len_err               (stat_rx_mf_len_err               )       , // output wire [19 : 0] stat_rx_mf_len_err
		.stat_rx_mf_repeat_err            (stat_rx_mf_repeat_err            )       , // output wire [19 : 0] stat_rx_mf_repeat_err
		.stat_rx_misaligned               (stat_rx_misaligned               )       , // output wire stat_rx_misaligned
		.stat_rx_multicast                (stat_rx_multicast                )       , // output wire stat_rx_multicast
		.stat_rx_oversize                 (stat_rx_oversize                 )       , // output wire stat_rx_oversize
		.stat_rx_packet_1024_1518_bytes   (stat_rx_packet_1024_1518_bytes   )       , // output wire stat_rx_packet_1024_1518_bytes
		.stat_rx_packet_128_255_bytes     (stat_rx_packet_128_255_bytes     )       , // output wire stat_rx_packet_128_255_bytes
		.stat_rx_packet_1519_1522_bytes   (stat_rx_packet_1519_1522_bytes   )       , // output wire stat_rx_packet_1519_1522_bytes
		.stat_rx_packet_1523_1548_bytes   (stat_rx_packet_1523_1548_bytes   )       , // output wire stat_rx_packet_1523_1548_bytes
		.stat_rx_packet_1549_2047_bytes   (stat_rx_packet_1549_2047_bytes   )       , // output wire stat_rx_packet_1549_2047_bytes
		.stat_rx_packet_2048_4095_bytes   (stat_rx_packet_2048_4095_bytes   )       , // output wire stat_rx_packet_2048_4095_bytes
		.stat_rx_packet_256_511_bytes     (stat_rx_packet_256_511_bytes     )       , // output wire stat_rx_packet_256_511_bytes
		.stat_rx_packet_4096_8191_bytes   (stat_rx_packet_4096_8191_bytes   )       , // output wire stat_rx_packet_4096_8191_bytes
		.stat_rx_packet_512_1023_bytes    (stat_rx_packet_512_1023_bytes    )       , // output wire stat_rx_packet_512_1023_bytes
		.stat_rx_packet_64_bytes          (stat_rx_packet_64_bytes          )       , // output wire stat_rx_packet_64_bytes
		.stat_rx_packet_65_127_bytes      (stat_rx_packet_65_127_bytes      )       , // output wire stat_rx_packet_65_127_bytes
		.stat_rx_packet_8192_9215_bytes   (stat_rx_packet_8192_9215_bytes   )       , // output wire stat_rx_packet_8192_9215_bytes
		.stat_rx_packet_bad_fcs           (stat_rx_packet_bad_fcs           )       , // output wire stat_rx_packet_bad_fcs
		.stat_rx_packet_large             (stat_rx_packet_large             )       , // output wire stat_rx_packet_large
		.stat_rx_packet_small             (stat_rx_packet_small             )       , // output wire [2 : 0] stat_rx_packet_small
		.stat_rx_pause                    (stat_rx_pause                    )       , // output wire stat_rx_pause
		.stat_rx_pause_quanta0            (stat_rx_pause_quanta0            )       , // output wire [15 : 0] stat_rx_pause_quanta0
		.stat_rx_pause_quanta1            (stat_rx_pause_quanta1            )       , // output wire [15 : 0] stat_rx_pause_quanta1
		.stat_rx_pause_quanta2            (stat_rx_pause_quanta2            )       , // output wire [15 : 0] stat_rx_pause_quanta2
		.stat_rx_pause_quanta3            (stat_rx_pause_quanta3            )       , // output wire [15 : 0] stat_rx_pause_quanta3
		.stat_rx_pause_quanta4            (stat_rx_pause_quanta4            )       , // output wire [15 : 0] stat_rx_pause_quanta4
		.stat_rx_pause_quanta5            (stat_rx_pause_quanta5            )       , // output wire [15 : 0] stat_rx_pause_quanta5
		.stat_rx_pause_quanta6            (stat_rx_pause_quanta6            )       , // output wire [15 : 0] stat_rx_pause_quanta6
		.stat_rx_pause_quanta7            (stat_rx_pause_quanta7            )       , // output wire [15 : 0] stat_rx_pause_quanta7
		.stat_rx_pause_quanta8            (stat_rx_pause_quanta8            )       , // output wire [15 : 0] stat_rx_pause_quanta8
		.stat_rx_pause_req                (stat_rx_pause_req                )       , // output wire [8 : 0] stat_rx_pause_req
		.stat_rx_pause_valid              (stat_rx_pause_valid              )       , // output wire [8 : 0] stat_rx_pause_valid
		.stat_rx_user_pause               (stat_rx_user_pause               )       , // output wire stat_rx_user_pause
		.ctl_rx_check_etype_gcp           (ctl_rx_check_etype_gcp           )       , // input wire ctl_rx_check_etype_gcp
		.ctl_rx_check_etype_gpp           (ctl_rx_check_etype_gpp           )       , // input wire ctl_rx_check_etype_gpp
		.ctl_rx_check_etype_pcp           (ctl_rx_check_etype_pcp           )       , // input wire ctl_rx_check_etype_pcp
		.ctl_rx_check_etype_ppp           (ctl_rx_check_etype_ppp           )       , // input wire ctl_rx_check_etype_ppp
		.ctl_rx_check_mcast_gcp           (ctl_rx_check_mcast_gcp           )       , // input wire ctl_rx_check_mcast_gcp
		.ctl_rx_check_mcast_gpp           (ctl_rx_check_mcast_gpp           )       , // input wire ctl_rx_check_mcast_gpp
		.ctl_rx_check_mcast_pcp           (ctl_rx_check_mcast_pcp           )       , // input wire ctl_rx_check_mcast_pcp
		.ctl_rx_check_mcast_ppp           (ctl_rx_check_mcast_ppp           )       , // input wire ctl_rx_check_mcast_ppp
		.ctl_rx_check_opcode_gcp          (ctl_rx_check_opcode_gcp          )       , // input wire ctl_rx_check_opcode_gcp
		.ctl_rx_check_opcode_gpp          (ctl_rx_check_opcode_gpp          )       , // input wire ctl_rx_check_opcode_gpp
		.ctl_rx_check_opcode_pcp          (ctl_rx_check_opcode_pcp          )       , // input wire ctl_rx_check_opcode_pcp
		.ctl_rx_check_opcode_ppp          (ctl_rx_check_opcode_ppp          )       , // input wire ctl_rx_check_opcode_ppp
		.ctl_rx_check_sa_gcp              (ctl_rx_check_sa_gcp              )       , // input wire ctl_rx_check_sa_gcp
		.ctl_rx_check_sa_gpp              (ctl_rx_check_sa_gpp              )       , // input wire ctl_rx_check_sa_gpp
		.ctl_rx_check_sa_pcp              (ctl_rx_check_sa_pcp              )       , // input wire ctl_rx_check_sa_pcp
		.ctl_rx_check_sa_ppp              (ctl_rx_check_sa_ppp              )       , // input wire ctl_rx_check_sa_ppp
		.ctl_rx_check_ucast_gcp           (ctl_rx_check_ucast_gcp           )       , // input wire ctl_rx_check_ucast_gcp
		.ctl_rx_check_ucast_gpp           (ctl_rx_check_ucast_gpp           )       , // input wire ctl_rx_check_ucast_gpp
		.ctl_rx_check_ucast_pcp           (ctl_rx_check_ucast_pcp           )       , // input wire ctl_rx_check_ucast_pcp
		.ctl_rx_check_ucast_ppp           (ctl_rx_check_ucast_ppp           )       , // input wire ctl_rx_check_ucast_ppp
		.ctl_rx_enable_gcp                (ctl_rx_enable_gcp                )       , // input wire ctl_rx_enable_gcp
		.ctl_rx_enable_gpp                (ctl_rx_enable_gpp                )       , // input wire ctl_rx_enable_gpp
		.ctl_rx_enable_pcp                (ctl_rx_enable_pcp                )       , // input wire ctl_rx_enable_pcp
		.ctl_rx_enable_ppp                (ctl_rx_enable_ppp                )       , // input wire ctl_rx_enable_ppp
		.ctl_rx_pause_ack                 (ctl_rx_pause_ack                 )       , // input wire [8 : 0] ctl_rx_pause_ack
		.ctl_rx_pause_enable              (ctl_rx_pause_enable              )       , // input wire [8 : 0] ctl_rx_pause_enable
		.ctl_rx_enable                    (ctl_rx_enable                    )       , // input wire ctl_rx_enable
		.ctl_rx_force_resync              (ctl_rx_force_resync              )       , // input wire ctl_rx_force_resync
		.ctl_rx_test_pattern              (ctl_rx_test_pattern              )       , // input wire ctl_rx_test_pattern
		.ctl_rsfec_ieee_error_indication_mode 	(ctl_rsfec_ieee_error_indication_mode_int)       , // input wire ctl_rsfec_ieee_error_indication_mode
		.ctl_rx_rsfec_enable              		(ctl_rx_rsfec_enable_int          		)       , // input wire ctl_rx_rsfec_enable
		.ctl_rx_rsfec_enable_correction   		(ctl_rx_rsfec_enable_correction_int		)       , // input wire ctl_rx_rsfec_enable_correction
		.ctl_rx_rsfec_enable_indication   		(ctl_rx_rsfec_enable_indication_int		)       , // input wire ctl_rx_rsfec_enable_indication
		.core_rx_reset                    		(sys_reset                             	)       , // input wire core_rx_reset
		.rx_clk                           		(txusrclk2                        		)       , // input wire rx_clk
		.stat_rx_received_local_fault     		(stat_rx_received_local_fault     		)       , // output wire stat_rx_received_local_fault
		.stat_rx_remote_fault             		(stat_rx_remote_fault             		)       , // output wire stat_rx_remote_fault
		.stat_rx_status                   		(stat_rx_status                   		)       , // output wire stat_rx_status
		.stat_rx_stomped_fcs              		(stat_rx_stomped_fcs              		)       , // output wire [2 : 0] stat_rx_stomped_fcs
		.stat_rx_synced                   		(stat_rx_synced                   		)       , // output wire [19 : 0] stat_rx_synced
		.stat_rx_synced_err               		(stat_rx_synced_err               		)       , // output wire [19 : 0] stat_rx_synced_err
		.stat_rx_test_pattern_mismatch    		(stat_rx_test_pattern_mismatch    		)       , // output wire [2 : 0] stat_rx_test_pattern_mismatch
		.stat_rx_toolong                  		(stat_rx_toolong                  		)       , // output wire stat_rx_toolong
		.stat_rx_total_bytes              		(stat_rx_total_bytes              		)       , // output wire [6 : 0] stat_rx_total_bytes
		.stat_rx_total_good_bytes         		(stat_rx_total_good_bytes         		)       , // output wire [13 : 0] stat_rx_total_good_bytes
		.stat_rx_total_good_packets       		(stat_rx_total_good_packets       		)       , // output wire stat_rx_total_good_packets
		.stat_rx_total_packets            		(stat_rx_total_packets            		)       , // output wire [2 : 0] stat_rx_total_packets
		.stat_rx_truncated                		(stat_rx_truncated                		)       , // output wire stat_rx_truncated
		.stat_rx_undersize                		(stat_rx_undersize                		)       , // output wire [2 : 0] stat_rx_undersize
		.stat_rx_unicast                  		(stat_rx_unicast                  		)       , // output wire stat_rx_unicast
		.stat_rx_vlan                     		(stat_rx_vlan                     		)       , // output wire stat_rx_vlan
		.stat_rx_pcsl_demuxed             		(stat_rx_pcsl_demuxed             		)       , // output wire [19 : 0] stat_rx_pcsl_demuxed
		.stat_rx_pcsl_number_0            		(stat_rx_pcsl_number_0            		)       , // output wire [4 : 0] stat_rx_pcsl_number_0
		.stat_rx_pcsl_number_1            		(stat_rx_pcsl_number_1            		)       , // output wire [4 : 0] stat_rx_pcsl_number_1
		.stat_rx_pcsl_number_10           		(stat_rx_pcsl_number_10           		)       , // output wire [4 : 0] stat_rx_pcsl_number_10
		.stat_rx_pcsl_number_11           		(stat_rx_pcsl_number_11           		)       , // output wire [4 : 0] stat_rx_pcsl_number_11
		.stat_rx_pcsl_number_12           		(stat_rx_pcsl_number_12           		)       , // output wire [4 : 0] stat_rx_pcsl_number_12
		.stat_rx_pcsl_number_13           		(stat_rx_pcsl_number_13           		)       , // output wire [4 : 0] stat_rx_pcsl_number_13
		.stat_rx_pcsl_number_14           		(stat_rx_pcsl_number_14           		)       , // output wire [4 : 0] stat_rx_pcsl_number_14
		.stat_rx_pcsl_number_15           		(stat_rx_pcsl_number_15           		)       , // output wire [4 : 0] stat_rx_pcsl_number_15
		.stat_rx_pcsl_number_16           		(stat_rx_pcsl_number_16           		)       , // output wire [4 : 0] stat_rx_pcsl_number_16
		.stat_rx_pcsl_number_17           		(stat_rx_pcsl_number_17           		)       , // output wire [4 : 0] stat_rx_pcsl_number_17
		.stat_rx_pcsl_number_18           		(stat_rx_pcsl_number_18           		)       , // output wire [4 : 0] stat_rx_pcsl_number_18
		.stat_rx_pcsl_number_19           		(stat_rx_pcsl_number_19           		)       , // output wire [4 : 0] stat_rx_pcsl_number_19
		.stat_rx_pcsl_number_2            		(stat_rx_pcsl_number_2            		)       , // output wire [4 : 0] stat_rx_pcsl_number_2
		.stat_rx_pcsl_number_3            		(stat_rx_pcsl_number_3            		)       , // output wire [4 : 0] stat_rx_pcsl_number_3
		.stat_rx_pcsl_number_4            		(stat_rx_pcsl_number_4            		)       , // output wire [4 : 0] stat_rx_pcsl_number_4
		.stat_rx_pcsl_number_5            		(stat_rx_pcsl_number_5            		)       , // output wire [4 : 0] stat_rx_pcsl_number_5
		.stat_rx_pcsl_number_6            		(stat_rx_pcsl_number_6            		)       , // output wire [4 : 0] stat_rx_pcsl_number_6
		.stat_rx_pcsl_number_7            		(stat_rx_pcsl_number_7            		)       , // output wire [4 : 0] stat_rx_pcsl_number_7
		.stat_rx_pcsl_number_8            		(stat_rx_pcsl_number_8            		)       , // output wire [4 : 0] stat_rx_pcsl_number_8
		.stat_rx_pcsl_number_9            		(stat_rx_pcsl_number_9            		)       , // output wire [4 : 0] stat_rx_pcsl_number_9
		.stat_rx_rsfec_am_lock0           		(stat_rx_rsfec_am_lock0           		)       , // output wire stat_rx_rsfec_am_lock0
		.stat_rx_rsfec_am_lock1           		(stat_rx_rsfec_am_lock1           		)       , // output wire stat_rx_rsfec_am_lock1
		.stat_rx_rsfec_am_lock2           		(stat_rx_rsfec_am_lock2           		)       , // output wire stat_rx_rsfec_am_lock2
		.stat_rx_rsfec_am_lock3           		(stat_rx_rsfec_am_lock3           		)       , // output wire stat_rx_rsfec_am_lock3
		.stat_rx_rsfec_corrected_cw_inc   		(stat_rx_rsfec_corrected_cw_inc   		)       , // output wire stat_rx_rsfec_corrected_cw_inc
		.stat_rx_rsfec_cw_inc             		(stat_rx_rsfec_cw_inc             		)       , // output wire stat_rx_rsfec_cw_inc
		.stat_rx_rsfec_err_count0_inc     		(stat_rx_rsfec_err_count0_inc     		)       , // output wire [2 : 0] stat_rx_rsfec_err_count0_inc
		.stat_rx_rsfec_err_count1_inc     		(stat_rx_rsfec_err_count1_inc     		)       , // output wire [2 : 0] stat_rx_rsfec_err_count1_inc
		.stat_rx_rsfec_err_count2_inc     		(stat_rx_rsfec_err_count2_inc     		)       , // output wire [2 : 0] stat_rx_rsfec_err_count2_inc
		.stat_rx_rsfec_err_count3_inc     		(stat_rx_rsfec_err_count3_inc     		)       , // output wire [2 : 0] stat_rx_rsfec_err_count3_inc
		.stat_rx_rsfec_hi_ser             		(stat_rx_rsfec_hi_ser             		)       , // output wire stat_rx_rsfec_hi_ser
		.stat_rx_rsfec_lane_alignment_status	(stat_rx_rsfec_lane_alignment_status	)       , // output wire stat_rx_rsfec_lane_alignment_status
		.stat_rx_rsfec_lane_fill_0        		(stat_rx_rsfec_lane_fill_0        		)       , // output wire [13 : 0] stat_rx_rsfec_lane_fill_0
		.stat_rx_rsfec_lane_fill_1        		(stat_rx_rsfec_lane_fill_1        		)       , // output wire [13 : 0] stat_rx_rsfec_lane_fill_1
		.stat_rx_rsfec_lane_fill_2        		(stat_rx_rsfec_lane_fill_2        		)       , // output wire [13 : 0] stat_rx_rsfec_lane_fill_2
		.stat_rx_rsfec_lane_fill_3        		(stat_rx_rsfec_lane_fill_3        		)       , // output wire [13 : 0] stat_rx_rsfec_lane_fill_3
		.stat_rx_rsfec_lane_mapping       		(stat_rx_rsfec_lane_mapping       		)       , // output wire [7 : 0] stat_rx_rsfec_lane_mapping
		.stat_rx_rsfec_uncorrected_cw_inc 		(stat_rx_rsfec_uncorrected_cw_inc 		)       , // output wire stat_rx_rsfec_uncorrected_cw_inc
		.stat_tx_bad_fcs                  		(stat_tx_bad_fcs                  		)       , // output wire stat_tx_bad_fcs
		.stat_tx_broadcast                		(stat_tx_broadcast                		)       , // output wire stat_tx_broadcast
		.stat_tx_frame_error              		(stat_tx_frame_error              		)       , // output wire stat_tx_frame_error
		.stat_tx_local_fault              		(stat_tx_local_fault              		)       , // output wire stat_tx_local_fault
		.stat_tx_multicast                		(stat_tx_multicast                		)       , // output wire stat_tx_multicast
		.stat_tx_packet_1024_1518_bytes   		(stat_tx_packet_1024_1518_bytes   		)       , // output wire stat_tx_packet_1024_1518_bytes
		.stat_tx_packet_128_255_bytes     		(stat_tx_packet_128_255_bytes     		)       , // output wire stat_tx_packet_128_255_bytes
		.stat_tx_packet_1519_1522_bytes   		(stat_tx_packet_1519_1522_bytes   		)       , // output wire stat_tx_packet_1519_1522_bytes
		.stat_tx_packet_1523_1548_bytes   		(stat_tx_packet_1523_1548_bytes   		)       , // output wire stat_tx_packet_1523_1548_bytes
		.stat_tx_packet_1549_2047_bytes   		(stat_tx_packet_1549_2047_bytes   		)       , // output wire stat_tx_packet_1549_2047_bytes
		.stat_tx_packet_2048_4095_bytes   		(stat_tx_packet_2048_4095_bytes   		)       , // output wire stat_tx_packet_2048_4095_bytes
		.stat_tx_packet_256_511_bytes     		(stat_tx_packet_256_511_bytes     		)       , // output wire stat_tx_packet_256_511_bytes
		.stat_tx_packet_4096_8191_bytes   		(stat_tx_packet_4096_8191_bytes   		)       , // output wire stat_tx_packet_4096_8191_bytes
		.stat_tx_packet_512_1023_bytes    		(stat_tx_packet_512_1023_bytes    		)       , // output wire stat_tx_packet_512_1023_bytes
		.stat_tx_packet_64_bytes          		(stat_tx_packet_64_bytes          		)       , // output wire stat_tx_packet_64_bytes
		.stat_tx_packet_65_127_bytes      		(stat_tx_packet_65_127_bytes      		)       , // output wire stat_tx_packet_65_127_bytes
		.stat_tx_packet_8192_9215_bytes   		(stat_tx_packet_8192_9215_bytes   		)       , // output wire stat_tx_packet_8192_9215_bytes
		.stat_tx_packet_large             		(stat_tx_packet_large             		)       , // output wire stat_tx_packet_large
		.stat_tx_packet_small             		(stat_tx_packet_small             		)       , // output wire stat_tx_packet_small
		.stat_tx_total_bytes              		(stat_tx_total_bytes              		)       , // output wire [5 : 0] stat_tx_total_bytes
		.stat_tx_total_good_bytes         		(stat_tx_total_good_bytes         		)       , // output wire [13 : 0] stat_tx_total_good_bytes
		.stat_tx_total_good_packets       		(stat_tx_total_good_packets       		)       , // output wire stat_tx_total_good_packets
		.stat_tx_total_packets            		(stat_tx_total_packets            		)       , // output wire stat_tx_total_packets
		.stat_tx_unicast                  		(stat_tx_unicast                  		)       , // output wire stat_tx_unicast
		.stat_tx_vlan                     		(stat_tx_vlan                     		)       , // output wire stat_tx_vlan


		.ctl_tx_enable                    		(ctl_tx_enable                    )       , // input wire ctl_tx_enable
		.ctl_tx_test_pattern              		(ctl_tx_test_pattern              )       , // input wire ctl_tx_test_pattern
		.ctl_tx_rsfec_enable              		(ctl_tx_rsfec_enable_int          )       , // input wire ctl_tx_rsfec_enable
		.ctl_tx_send_idle                 		(ctl_tx_send_idle                 )       , // input wire ctl_tx_send_idle
		.ctl_tx_send_rfi                  		(ctl_tx_send_rfi                  )       , // input wire ctl_tx_send_rfi
		.ctl_tx_send_lfi                  		(ctl_tx_send_lfi                  )       , // input wire ctl_tx_send_lfi
		.core_tx_reset                    		(sys_reset                        )       , // input wire core_tx_reset
		.stat_tx_pause_valid              		(stat_tx_pause_valid              )       , // output wire [8 : 0] stat_tx_pause_valid
		.stat_tx_pause                    		(stat_tx_pause                    )       , // output wire stat_tx_pause
		.stat_tx_user_pause               		(stat_tx_user_pause               )       , // output wire stat_tx_user_pause
		.ctl_tx_pause_enable              		(ctl_tx_pause_enable              )       , // input wire [8 : 0] ctl_tx_pause_enable
		.ctl_tx_pause_quanta0             		(ctl_tx_pause_quanta0             )       , // input wire [15 : 0] ctl_tx_pause_quanta0
		.ctl_tx_pause_quanta1             		(ctl_tx_pause_quanta1             )       , // input wire [15 : 0] ctl_tx_pause_quanta1
		.ctl_tx_pause_quanta2             		(ctl_tx_pause_quanta2             )       , // input wire [15 : 0] ctl_tx_pause_quanta2
		.ctl_tx_pause_quanta3             		(ctl_tx_pause_quanta3             )       , // input wire [15 : 0] ctl_tx_pause_quanta3
		.ctl_tx_pause_quanta4             		(ctl_tx_pause_quanta4             )       , // input wire [15 : 0] ctl_tx_pause_quanta4
		.ctl_tx_pause_quanta5             		(ctl_tx_pause_quanta5             )       , // input wire [15 : 0] ctl_tx_pause_quanta5
		.ctl_tx_pause_quanta6             		(ctl_tx_pause_quanta6             )       , // input wire [15 : 0] ctl_tx_pause_quanta6
		.ctl_tx_pause_quanta7             		(ctl_tx_pause_quanta7             )       , // input wire [15 : 0] ctl_tx_pause_quanta7
		.ctl_tx_pause_quanta8             		(ctl_tx_pause_quanta8             )       , // input wire [15 : 0] ctl_tx_pause_quanta8
		.ctl_tx_pause_refresh_timer0      		(ctl_tx_pause_refresh_timer0      )       , // input wire [15 : 0] ctl_tx_pause_refresh_timer0
		.ctl_tx_pause_refresh_timer1      		(ctl_tx_pause_refresh_timer1      )       , // input wire [15 : 0] ctl_tx_pause_refresh_timer1
		.ctl_tx_pause_refresh_timer2      		(ctl_tx_pause_refresh_timer2      )       , // input wire [15 : 0] ctl_tx_pause_refresh_timer2
		.ctl_tx_pause_refresh_timer3      		(ctl_tx_pause_refresh_timer3      )       , // input wire [15 : 0] ctl_tx_pause_refresh_timer3
		.ctl_tx_pause_refresh_timer4      		(ctl_tx_pause_refresh_timer4      )       , // input wire [15 : 0] ctl_tx_pause_refresh_timer4
		.ctl_tx_pause_refresh_timer5      		(ctl_tx_pause_refresh_timer5      )       , // input wire [15 : 0] ctl_tx_pause_refresh_timer5
		.ctl_tx_pause_refresh_timer6      		(ctl_tx_pause_refresh_timer6      )       , // input wire [15 : 0] ctl_tx_pause_refresh_timer6
		.ctl_tx_pause_refresh_timer7      		(ctl_tx_pause_refresh_timer7      )       , // input wire [15 : 0] ctl_tx_pause_refresh_timer7
		.ctl_tx_pause_refresh_timer8      		(ctl_tx_pause_refresh_timer8      )       , // input wire [15 : 0] ctl_tx_pause_refresh_timer8
		.ctl_tx_pause_req                 		(ctl_tx_pause_req                 )       , // input wire [8 : 0] ctl_tx_pause_req
		.ctl_tx_resend_pause              		(ctl_tx_resend_pause              )       , // input wire ctl_tx_resend_pause
		.tx_axis_tready                   		(tx_axis_tready                   )       , // output wire tx_axis_tready
		.tx_axis_tvalid                   		(tx_axis_tvalid                   )       , // input wire tx_axis_tvalid
		.tx_axis_tdata                    		(tx_axis_tdata                    )       , // input wire [511 : 0] tx_axis_tdata
		.tx_axis_tkeep                    		(tx_axis_tkeep                    )       , // input wire tx_axis_tlast
		.tx_axis_tlast                    		(tx_axis_tlast                    )       , // input wire [63 : 0] tx_axis_tkeep
		.tx_axis_tuser                    		(tx_axis_tuser                    )       , // input wire tx_axis_tuser
		.tx_ovfout                        		(tx_ovfout                        )       , // output wire tx_ovfout
		.tx_unfout                        		(tx_unfout                        )       , // output wire tx_unfout
		.tx_preamblein                    		(tx_preamblein                    )       , // input wire [55 : 0] tx_preamblein
		.usr_tx_reset                     		(usr_tx_reset                     )       , // output wire usr_tx_reset


		.core_drp_reset                   		(1'b0                             )       , // input wire core_drp_reset
		.drp_clk                          		(drp_clk                          )       , // input wire drp_clk
		.drp_addr                         		(10'b0                            )       , // input wire [9 : 0] drp_addr
		.drp_di                           		(16'b0                            )       , // input wire [15 : 0] drp_di
		.drp_en                           		(1'b0                             )       , // input wire drp_en
		.drp_do                           		(								  )       , // output wire [15 : 0] drp_do       
		.drp_rdy                          		(								  )       , // output wire drp_rdy       
		.drp_we                           		(1'b0							  )         // input wire drp_we
	);

	assign	ctl_tx_enable 		= 1'b1 ;
	assign	ctl_tx_test_pattern = 1'b0 ;
	assign	tx_preamblein 		= 56'd0 ;

	assign  ctl_tx_rsfec_enable_int = 1'b1;
	assign  ctl_tx_send_idle = 1'b0;
	assign  ctl_tx_send_rfi = 1'b0;
	assign  ctl_tx_send_lfi = 1'b0;

	assign  ctl_tx_pause_enable  = 9'd0;
	assign  ctl_tx_pause_quanta0 = 16'd0;
	assign  ctl_tx_pause_quanta1 = 16'd0;
	assign  ctl_tx_pause_quanta2 = 16'd0;
	assign  ctl_tx_pause_quanta3 = 16'd0;
	assign  ctl_tx_pause_quanta4 = 16'd0;
	assign  ctl_tx_pause_quanta5 = 16'd0;
	assign  ctl_tx_pause_quanta6 = 16'd0;
	assign  ctl_tx_pause_quanta7 = 16'd0;
	assign  ctl_tx_pause_quanta8 = 16'd0;
	assign  ctl_tx_pause_refresh_timer0 = 16'd0;
	assign  ctl_tx_pause_refresh_timer1 = 16'd0;
	assign  ctl_tx_pause_refresh_timer2 = 16'd0;
	assign  ctl_tx_pause_refresh_timer3 = 16'd0;
	assign  ctl_tx_pause_refresh_timer4 = 16'd0;
	assign  ctl_tx_pause_refresh_timer5 = 16'd0;
	assign  ctl_tx_pause_refresh_timer6 = 16'd0;
	assign  ctl_tx_pause_refresh_timer7 = 16'd0;
	assign  ctl_tx_pause_refresh_timer8 = 16'd0;
	assign  ctl_tx_pause_req = 9'd0;
	assign  ctl_tx_resend_pause = 1'b0;

	assign  ctl_rx_check_etype_gcp = 1'b0;
	assign  ctl_rx_check_etype_gpp = 1'b0;
	assign  ctl_rx_check_etype_pcp = 1'b0;
	assign  ctl_rx_check_etype_ppp = 1'b0;
	assign  ctl_rx_check_mcast_gcp = 1'b0;
	assign  ctl_rx_check_mcast_gpp = 1'b0;
	assign  ctl_rx_check_mcast_pcp = 1'b0;
	assign  ctl_rx_check_mcast_ppp = 1'b0;
	assign  ctl_rx_check_opcode_gcp = 1'b0;
	assign  ctl_rx_check_opcode_gpp = 1'b0;
	assign  ctl_rx_check_opcode_pcp = 1'b0;
	assign  ctl_rx_check_opcode_ppp = 1'b0;
	assign  ctl_rx_check_sa_gcp = 1'b0;
	assign  ctl_rx_check_sa_gpp = 1'b0;
	assign  ctl_rx_check_sa_pcp = 1'b0;
	assign  ctl_rx_check_sa_ppp = 1'b0;
	assign  ctl_rx_check_ucast_gcp = 1'b0;
	assign  ctl_rx_check_ucast_gpp = 1'b0;
	assign  ctl_rx_check_ucast_pcp = 1'b0;
	assign  ctl_rx_check_ucast_ppp = 1'b0;
	assign  ctl_rx_enable_gcp = 1'b0;
	assign  ctl_rx_enable_gpp = 1'b0;
	assign  ctl_rx_enable_pcp = 1'b0;
	assign  ctl_rx_enable_ppp = 1'b0;
	assign  ctl_rx_pause_ack = 9'd0;
	assign  ctl_rx_pause_enable = 9'd0;

	assign  ctl_rx_enable = 1'b1;
	assign  ctl_rx_force_resync = 1'b0;
	assign  ctl_rx_test_pattern = 1'b0;
	assign  ctl_rsfec_ieee_error_indication_mode_int = 1'b1;
	assign  ctl_rx_rsfec_enable_int = 1'b1;
	assign  ctl_rx_rsfec_enable_correction_int = 1'b1;
	assign  ctl_rx_rsfec_enable_indication_int = 1'b1;


//	ila_600 inst_status
//	(
//	    .clk(clk_axis),
	
//	    .probe0({
//			stat_tx_pause_valid,
//			stat_tx_pause,
//			stat_tx_user_pause,

//			stat_rx_pause,
//			stat_rx_pause_quanta0,
//			stat_rx_pause_quanta1,
//			stat_rx_pause_quanta2,
//			stat_rx_pause_quanta3,
//			stat_rx_pause_quanta4,
//			stat_rx_pause_quanta5,
//			stat_rx_pause_quanta6,
//			stat_rx_pause_quanta7,
//			stat_rx_pause_quanta8,
//			stat_rx_pause_req,
//			stat_rx_pause_valid,
//			stat_rx_user_pause,

//			stat_rx_aligned,
//			stat_rx_aligned_err,
//			stat_rx_bad_code,
//			stat_rx_bad_fcs,
//			stat_rx_bad_preamble,
//			stat_rx_bad_sfd,
//			stat_rx_bip_err_0,
//			stat_rx_bip_err_1,
//			stat_rx_bip_err_10,
//			stat_rx_bip_err_11,
//			stat_rx_bip_err_12,
//			stat_rx_bip_err_13,
//			stat_rx_bip_err_14,
//			stat_rx_bip_err_15,
//			stat_rx_bip_err_16,
//			stat_rx_bip_err_17,
//			stat_rx_bip_err_18,
//			stat_rx_bip_err_19,
//			stat_rx_bip_err_2,
//			stat_rx_bip_err_3,
//			stat_rx_bip_err_4,
//			stat_rx_bip_err_5,
//			stat_rx_bip_err_6,
//			stat_rx_bip_err_7,
//			stat_rx_bip_err_8,
//			stat_rx_bip_err_9,
//			stat_rx_block_lock,
//			stat_rx_broadcast,
//			stat_rx_fragment,
//			stat_rx_framing_err_0,
//			stat_rx_framing_err_1,
//			stat_rx_framing_err_10,
//			stat_rx_framing_err_11,
//			stat_rx_framing_err_12,
//			stat_rx_framing_err_13,
//			stat_rx_framing_err_14,
//			stat_rx_framing_err_15,
//			stat_rx_framing_err_16,
//			stat_rx_framing_err_17,
//			stat_rx_framing_err_18,
//			stat_rx_framing_err_19,
//			stat_rx_framing_err_2,
//			stat_rx_framing_err_3,
//			stat_rx_framing_err_4,
//			stat_rx_framing_err_5,
//			stat_rx_framing_err_6,
//			stat_rx_framing_err_7,
//			stat_rx_framing_err_8,
//			stat_rx_framing_err_9,
//			stat_rx_framing_err_valid_0,
//			stat_rx_framing_err_valid_1,
//			stat_rx_framing_err_valid_10,
//			stat_rx_framing_err_valid_11,
//			stat_rx_framing_err_valid_12,
//			stat_rx_framing_err_valid_13,
//			stat_rx_framing_err_valid_14,
//			stat_rx_framing_err_valid_15,
//			stat_rx_framing_err_valid_16,
//			stat_rx_framing_err_valid_17,
//			stat_rx_framing_err_valid_18,
//			stat_rx_framing_err_valid_19,
//			stat_rx_framing_err_valid_2,
//			stat_rx_framing_err_valid_3,
//			stat_rx_framing_err_valid_4,
//			stat_rx_framing_err_valid_5,
//			stat_rx_framing_err_valid_6,
//			stat_rx_framing_err_valid_7,
//			stat_rx_framing_err_valid_8,
//			stat_rx_framing_err_valid_9,
//			stat_rx_got_signal_os,
//			stat_rx_hi_ber,
//			stat_rx_inrangeerr,
//			stat_rx_internal_local_fault,
//			stat_rx_jabber,
//			stat_rx_local_fault,
//			stat_rx_mf_err,
//			stat_rx_mf_len_err,
//			stat_rx_mf_repeat_err,
//			stat_rx_misaligned,
//			stat_rx_multicast,
//			stat_rx_oversize,
//			stat_rx_packet_1024_1518_bytes,
//			stat_rx_packet_128_255_bytes,
//			stat_rx_packet_1519_1522_bytes,
//			stat_rx_packet_1523_1548_bytes,
//			stat_rx_packet_1549_2047_bytes,
//			stat_rx_packet_2048_4095_bytes,
//			stat_rx_packet_256_511_bytes,
//			stat_rx_packet_4096_8191_bytes,
//			stat_rx_packet_512_1023_bytes,
//			stat_rx_packet_64_bytes,
//			stat_rx_packet_65_127_bytes,
//			stat_rx_packet_8192_9215_bytes,
//			stat_rx_packet_bad_fcs,
//			stat_rx_packet_large,
//			stat_rx_packet_small,
//			stat_rx_received_local_fault,
//			stat_rx_remote_fault,
//			stat_rx_status,
//			stat_rx_stomped_fcs,
//			stat_rx_synced,
//			stat_rx_synced_err,
//			stat_rx_test_pattern_mismatch,
//			stat_rx_toolong,
//			stat_rx_total_bytes,
//			stat_rx_total_good_bytes,
//			stat_rx_total_good_packets,
//			stat_rx_total_packets,
//			stat_rx_truncated,
//			stat_rx_undersize,
//			stat_rx_unicast,
//			stat_rx_vlan,
//			stat_rx_pcsl_demuxed,
//			stat_rx_pcsl_number_0,
//			stat_rx_pcsl_number_1,
//			stat_rx_pcsl_number_10,
//			stat_rx_pcsl_number_11,
//			stat_rx_pcsl_number_12,
//			stat_rx_pcsl_number_13,
//			stat_rx_pcsl_number_14,
//			stat_rx_pcsl_number_15,
//			stat_rx_pcsl_number_16,
//			stat_rx_pcsl_number_17,
//			stat_rx_pcsl_number_18,
//			stat_rx_pcsl_number_19,
//			stat_rx_pcsl_number_2,
//			stat_rx_pcsl_number_3,
//			stat_rx_pcsl_number_4,
//			stat_rx_pcsl_number_5,
//			stat_rx_pcsl_number_6,
//			stat_rx_pcsl_number_7,
//			stat_rx_pcsl_number_8,
//			stat_rx_pcsl_number_9,
//			stat_rx_rsfec_am_lock0,
//			stat_rx_rsfec_am_lock1,
//			stat_rx_rsfec_am_lock2,
//			stat_rx_rsfec_am_lock3,
//			stat_rx_rsfec_corrected_cw_inc,
//			stat_rx_rsfec_cw_inc,
//			stat_rx_rsfec_err_count0_inc,
//			stat_rx_rsfec_err_count1_inc,
//			stat_rx_rsfec_err_count2_inc,
//			stat_rx_rsfec_err_count3_inc,
//			stat_rx_rsfec_hi_ser,
//			stat_rx_rsfec_lane_alignment_status,
//			stat_rx_rsfec_lane_fill_0,
//			stat_rx_rsfec_lane_fill_1,
//			stat_rx_rsfec_lane_fill_2,
//			stat_rx_rsfec_lane_fill_3,
//			stat_rx_rsfec_lane_mapping,
//			stat_rx_rsfec_uncorrected_cw_inc,
//			stat_tx_bad_fcs,
//			stat_tx_broadcast,
//			stat_tx_frame_error,
//			stat_tx_local_fault,
//			stat_tx_multicast,
//			stat_tx_packet_1024_1518_bytes,
//			stat_tx_packet_128_255_bytes,
//			stat_tx_packet_1519_1522_bytes,
//			stat_tx_packet_1523_1548_bytes,
//			stat_tx_packet_1549_2047_bytes,
//			stat_tx_packet_2048_4095_bytes,
//			stat_tx_packet_256_511_bytes,
//			stat_tx_packet_4096_8191_bytes,
//			stat_tx_packet_512_1023_bytes,
//			stat_tx_packet_64_bytes,
//			stat_tx_packet_65_127_bytes,
//			stat_tx_packet_8192_9215_bytes,
//			stat_tx_packet_large,
//			stat_tx_packet_small,
//			stat_tx_total_bytes,
//			stat_tx_total_good_bytes,
//			stat_tx_total_good_packets,
//			stat_tx_total_packets,
//			stat_tx_unicast,
//			stat_tx_vlan,
			
//			rx_otn_bip8_0,
//			rx_otn_bip8_1,
//			rx_otn_bip8_2,
//			rx_otn_bip8_3,
//			rx_otn_bip8_4,
//			rx_otn_data_0,
//			rx_otn_data_1,
//			rx_otn_data_2,
//			rx_otn_data_3,
//			rx_otn_data_4,
//			rx_otn_ena,
//			rx_otn_lane0,
//			rx_otn_vlmarker,
//			rx_preambleout,

//			gt_powergoodout
//	    })
//	);

//	ila_axis inst_ila_axis_tx
//	(
//		.clk(clk_axis),
	
//		.probe0(tx_axis_tdata),
//		.probe1(tx_axis_tlast),
//		.probe2(tx_axis_tkeep),
//		.probe3(tx_axis_tuser),
//		.probe4(tx_axis_tvalid),
//		.probe5(tx_axis_tready),
//		.probe6(usr_tx_reset)
//	);

//	ila_axis inst_ila_axis_rx
//	(
//		.clk(clk_axis),
	
//		.probe0(rx_axis_tdata),
//		.probe1(rx_axis_tlast),
//		.probe2(rx_axis_tkeep),
//		.probe3(rx_axis_tuser),
//		.probe4(rx_axis_tvalid),
//		.probe5(1'b0),
//		.probe6(usr_rx_reset)
//	);



endmodule
