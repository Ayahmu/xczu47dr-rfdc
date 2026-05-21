
 `timescale 1ns / 1ps 
 
module trimode_ddr4
  #( 
   parameter dbg                =1,
   parameter sim                =0,
   parameter procress_axi_addr_wid   = 28,//用户实际操作的内存大小axi地址宽度，例如8G内存，用户实际只需操作128MB
   
localparam axi_addr_wid            = 33,//实际内存支持的地址宽度，取值： 33：8G，32：4G，31：2G,30:1G, 29:512M, 28:256M...为字节地址,ddr mig axi_addr wid 
localparam log2_dat_wid            = 6,// 数据宽度，6为2的6次方个字节，64字节，512位 
localparam log2_burst_words        = 6  //突发长度，一次64个	  
    ) 
( 
	output                             c0_ddr4_act_n   ,
	output [16:0]                      c0_ddr4_adr     ,  
	output [1:0]                       c0_ddr4_ba      ,
	output [0:0]                       c0_ddr4_bg      ,
	output [0:0]                       c0_ddr4_cke     ,
	output [0:0]                       c0_ddr4_odt     ,
	output [0:0]                       c0_ddr4_cs_n    ,
	output [0:0]                       c0_ddr4_ck_t    ,
	output [0:0]                       c0_ddr4_ck_c    ,
	output                             c0_ddr4_reset_n ,
	inout [7:0]              c0_ddr4_dm_dbi_n,
	inout [63:0]             c0_ddr4_dq      ,
	inout [7:0]              c0_ddr4_dqs_c   ,
	inout [7:0]              c0_ddr4_dqs_t   ,               
	
	//Differential system clocks
	input                              c0_sys_clk_p,
	input                              c0_sys_clk_n,
	input                              sys_rst,

    input       rst,
    input       start,
    input       trig_en,
    input [1:0] mode, 

   input                    wr_addr_set,
   input [axi_addr_wid-1:0] wr_addr,
   input                    rd_addr_set,
   input [axi_addr_wid-1:0] rd_addr,   
output             mem_clk , 

output             init_calib_complete ,

output             clk_25M , 
output             clk_100M , 
output             clk_133M , 
//写入ddr的数据口，fifo_pre写宽度可重新定义，读宽度即DDR数据宽度
input  fifo_pre_wr_clk ,
input [511:0]  fifo_pre_din ,
input  fifo_pre_wen ,
output  fifo_pre_af,
output  fifo_pre_f,

//读出ddr的数据口，fifo_post读宽度可重新定义，写宽度即DDR数据宽度
input  fifo_post_rd_clk,
input  fifo_post_rden,
output [63:0]  fifo_post_dout,
output  fifo_post_emp,
output  fifo_post_vld

); 
	 
   wire         sync_rst_o;   
   
   wire         fifo_pre_rd_en;
   wire         fifo_pre_empty;
   wire [511:0] fifo_pre_dout; //512
   wire [9:0] 	fifo_pre_rd_count;

   wire 	fifo_post_wr_en;
   wire 	fifo_post_full;
   wire [511:0] fifo_post_din; //512
   wire [9:0] 	fifo_post_wr_count; 

   wire [axi_addr_wid-1:0] 	axi_awaddr; //[32:0]
   wire [7:0] 	axi_awlen;
   wire [2:0] 	axi_awsize;
   wire [1:0] 	axi_awburst;
   wire 	axi_awvalid;
   wire 	axi_awready;
   wire [511:0] axi_wdata;
   wire [63:0] 	axi_wstrb;
   wire 	axi_wlast;
   wire 	axi_wvalid;
   wire 	axi_wready;

   wire 	axi_bvalid;
   wire 	axi_bready;

   wire [axi_addr_wid-1:0] 	axi_araddr;
   wire [7:0] 	axi_arlen;
   wire [2:0] 	axi_arsize;
   wire [1:0] 	axi_arburst;
   wire 	axi_arvalid;
   wire 	axi_arready;
   wire [511:0] axi_rdata;
   wire 	axi_rlast;
   wire 	axi_rvalid;
   wire 	axi_rready;  

 wire ramwren,ramrden;   
  
 
  wire fifo_pre_rst;
 assign fifo_pre_rst = rst |  sync_rst_o; 
  
    afifo_pre afifo_pre_i
     (
      .rst(fifo_pre_rst),
      
      .wr_clk     (fifo_pre_wr_clk),
      .din        (fifo_pre_din),
      .wr_en      (fifo_pre_wen),
      .almost_full(fifo_pre_af),
      .full       (fifo_pre_f),
      
      .rd_clk       (mem_clk),
      .rd_en        (fifo_pre_rd_en),
      .dout         (fifo_pre_dout),
      .rd_data_count(fifo_pre_rd_count), 
      .empty        (fifo_pre_empty)   // output wire [9 : 0] rd_data_count 

      );


    deepfifo
//    #(.axi_addr_wid         (axi_addr_wid         ), 
//      .procress_axi_addr_wid(procress_axi_addr_wid),
//      .log2_dat_wid         (log2_dat_wid         ),
//      .log2_burst_words     (log2_burst_words     ) ,
//      .dbg                  (dbg)
//     )deepfifo_inst
     (
      .clk				    (mem_clk),
      .reset				(fifo_pre_rst), //   | (!ddr4_rstn)|wen_rst
      .axi_aresetn			( ),

      .fifo_pre_rd_en			(fifo_pre_rd_en),
      .fifo_pre_empty			(fifo_pre_empty),
      .fifo_pre_dout			(fifo_pre_dout),
      .fifo_pre_rd_count		(fifo_pre_rd_count),
      .fifo_pre_rd_count2		(0),

      .fifo_post_wr_en			(fifo_post_wr_en),
      .fifo_post_din			(fifo_post_din),
      .fifo_post_full			(fifo_post_full),
      .fifo_post_wr_count		(fifo_post_wr_count),
      
      .ramwren (ramwren),
      .ramrden (ramrden), 
      .mode    (mode      ),      
      
      .wr_addr_set(wr_addr_set),
      .wr_addr    (wr_addr    ),
      .rd_addr_set(rd_addr_set),
      .rd_addr    (rd_addr    ),

      .axi_awaddr			(axi_awaddr),
      .axi_awlen			(axi_awlen),
      .axi_awvalid			(axi_awvalid),
      .axi_awready			(axi_awready),
      .axi_awsize			(axi_awsize),
      .axi_awburst			(axi_awburst),
      .axi_wdata			(axi_wdata),
      .axi_wstrb			(axi_wstrb),
      .axi_wlast			(axi_wlast),
      .axi_wvalid			(axi_wvalid),
      .axi_wready			(axi_wready),
      .axi_bvalid			(axi_bvalid),
      .axi_bready			(axi_bready),

      .axi_araddr			(axi_araddr),
      .axi_arlen			(axi_arlen),
      .axi_arvalid			(axi_arvalid),
      .axi_arready			(axi_arready),
      .axi_arsize			(axi_arsize),
      .axi_arburst			(axi_arburst),
      .axi_rdata			(axi_rdata),
      .axi_rready			(axi_rready),
      .axi_rlast			(axi_rlast),
      .axi_rvalid			(axi_rvalid)
      );


 ddr_statemachine 
  #(  .procress_axi_addr_wid(procress_axi_addr_wid),//用户实际操作的内存大小axi地址宽度，例如8G内存，用户实际只需操作128MB
      .log2_dat_wid         (log2_dat_wid         ),// 数据宽度，6为2的6次方个字节，64字节，512位 
      .log2_burst_words     (log2_burst_words    ), //突发长度，一次16个
   .dbg             (dbg)
 )  
 ddr_statemachine_i(
   .clk          (mem_clk),
   .rst          (fifo_pre_rst  ),//| !ddr4_rstn|wen_rst
   .start        (start     ),
   .trig_en      (trig_en   ), 
   .mode         (mode      ),
   .ddr_wr_detect (axi_awvalid & axi_awready),
   .ddr_rd_detect (axi_arvalid & axi_arready),
      .axi_bvalid			(axi_bvalid),
      .axi_bready			(axi_bready),
   .ddr_wren     (ramwren),
   .ddr_rden     (ramrden) 
    );
 

   generate
      if (sim==0) begin: synth
		
ddr4_0 u_ddr4(
    .sys_rst(sys_rst),                                  // input wire sys_rst
    .c0_sys_clk_p(c0_sys_clk_p),                        // input wire c0_sys_clk_p
    .c0_sys_clk_n(c0_sys_clk_n),                        // input wire c0_sys_clk_n
    
    .c0_ddr4_act_n(c0_ddr4_act_n),                      // output wire c0_ddr4_act_n
    .c0_ddr4_adr(c0_ddr4_adr),                          // output wire [16 : 0] c0_ddr4_adr
    .c0_ddr4_ba(c0_ddr4_ba),                            // output wire [1 : 0] c0_ddr4_ba
    .c0_ddr4_bg(c0_ddr4_bg),                            // output wire [0 : 0] c0_ddr4_bg
    .c0_ddr4_cke(c0_ddr4_cke),                          // output wire [0 : 0] c0_ddr4_cke
    .c0_ddr4_odt(c0_ddr4_odt),                          // output wire [0 : 0] c0_ddr4_odt
    .c0_ddr4_cs_n(c0_ddr4_cs_n),                        // output wire [0 : 0] c0_ddr4_cs_n
    .c0_ddr4_ck_t(c0_ddr4_ck_t),                        // output wire [0 : 0] c0_ddr4_ck_t
    .c0_ddr4_ck_c(c0_ddr4_ck_c),                        // output wire [0 : 0] c0_ddr4_ck_c
    .c0_ddr4_reset_n(c0_ddr4_reset_n),                  // output wire c0_ddr4_reset_n
    .c0_ddr4_dm_dbi_n(c0_ddr4_dm_dbi_n),                // inout wire [3 : 0] c0_ddr4_dm_dbi_n
    .c0_ddr4_dq(c0_ddr4_dq),                            // inout wire [31 : 0] c0_ddr4_dq
    .c0_ddr4_dqs_c(c0_ddr4_dqs_c),                      // inout wire [3 : 0] c0_ddr4_dqs_c
    .c0_ddr4_dqs_t(c0_ddr4_dqs_t),                      // inout wire [3 : 0] c0_ddr4_dqs_t
    
    .c0_init_calib_complete(init_calib_complete),    // output wire c0_init_calib_complete
    
    .c0_ddr4_ui_clk(mem_clk),                    // output wire c0_ddr4_ui_clk
    .c0_ddr4_ui_clk_sync_rst( sync_rst_o),  // output wire c0_ddr4_ui_clk_sync_rst 
    
    .addn_ui_clkout1(clk_25M),                  // output wire addn_ui_clkout1
    .addn_ui_clkout2(clk_100M),                  // output wire addn_ui_clkout2
    .addn_ui_clkout3(clk_133M),
    
    .c0_ddr4_aresetn(~fifo_pre_rst),                  // input wire c0_ddr4_aresetn
    
    .c0_ddr4_s_axi_awid                     (4'd0),  // input [3:0]			s_axi_awid
    .c0_ddr4_s_axi_awaddr                   (axi_awaddr),  // input [30:0]			s_axi_awaddr
    .c0_ddr4_s_axi_awlen                    (axi_awlen),  // input [7:0]			s_axi_awlen
    .c0_ddr4_s_axi_awsize                   (axi_awsize),  // input [2:0]			s_axi_awsize
    .c0_ddr4_s_axi_awburst                  (axi_awburst),  // input [1:0]			s_axi_awburst
    .c0_ddr4_s_axi_awlock                   (1'b0),  // input [0:0]			s_axi_awlock
    .c0_ddr4_s_axi_awcache                  (4'd0),  // input [3:0]			s_axi_awcache
    .c0_ddr4_s_axi_awprot                   (3'd0),  // input [2:0]			s_axi_awprot
    .c0_ddr4_s_axi_awqos                    (4'd0),  // input [3:0]			s_axi_awqos
    .c0_ddr4_s_axi_awvalid                  (axi_awvalid),  // input			s_axi_awvalid
    .c0_ddr4_s_axi_awready                  (axi_awready),  // output			s_axi_awready
    // Slave Interface Write Data Ports
    .c0_ddr4_s_axi_wdata                    (axi_wdata),  // input [255:0]			s_axi_wdata
    .c0_ddr4_s_axi_wstrb                    (axi_wstrb),  // input [31:0]			s_axi_wstrb
    .c0_ddr4_s_axi_wlast                    (axi_wlast),  // input			s_axi_wlast
    .c0_ddr4_s_axi_wvalid                   (axi_wvalid),  // input			s_axi_wvalid
    .c0_ddr4_s_axi_wready                   (axi_wready),  // output		s_axi_wready
    // Slave Interface Write Response Ports
    .c0_ddr4_s_axi_bvalid                   (axi_bvalid),  // output		s_axi_bvalid
    .c0_ddr4_s_axi_bready                   (axi_bready),  // input			s_axi_bready
    // Slave Interface Read Address Ports
    .c0_ddr4_s_axi_arid                     (4'd0),  // input [3:0]			s_axi_arid
    .c0_ddr4_s_axi_araddr                   (axi_araddr),  // input [30:0]			s_axi_araddr
    .c0_ddr4_s_axi_arlen                    (axi_arlen),  // input [7:0]			s_axi_arlen
    .c0_ddr4_s_axi_arsize                   (axi_arsize),  // input [2:0]			s_axi_arsize
    .c0_ddr4_s_axi_arburst                  (axi_arburst),  // input [1:0]			s_axi_arburst
    .c0_ddr4_s_axi_arlock                   (1'b0),  // input [0:0]			s_axi_arlock
    .c0_ddr4_s_axi_arcache                  (4'd0),  // input [3:0]			s_axi_arcache
    .c0_ddr4_s_axi_arprot                   (3'd0),  // input [2:0]			s_axi_arprot
    .c0_ddr4_s_axi_arqos                    (4'd0),  // input [3:0]			s_axi_arqos
    .c0_ddr4_s_axi_arvalid                  (axi_arvalid),  // input			s_axi_arvalid
    .c0_ddr4_s_axi_arready                  (axi_arready),  // output			s_axi_arready
    // Slave Interface Read Data Ports
    .c0_ddr4_s_axi_rdata                    (axi_rdata),  // output [255:0]			s_axi_rdata
    .c0_ddr4_s_axi_rlast                    (axi_rlast),  // output			s_axi_rlast
    .c0_ddr4_s_axi_rvalid                   (axi_rvalid),  // output			s_axi_rvalid
    .c0_ddr4_s_axi_rready                   (axi_rready)   // input			s_axi_rready 
  
);  

      end else begin:simulate
 
           reg menclk;
           initial begin
              menclk = 1'b0;
              #20;
              forever
                 #20 menclk = ~menclk;
           end
           
           assign init_calib_complete=1'b1;
           assign	mem_clk=menclk;
           
           reg rsto;
           initial begin
              rsto = 1'b1;
              #222;
              rsto = 1'b0;
           end
           assign	sync_rst_o=rsto;
           
           assign	axi_bvalid=1;
           assign	 axi_awready=1;	
           assign	axi_wready=1;	
           assign	axi_arready=1; 

           assign	axi_rvalid=0;            
      end
      
   endgenerate
	
   fifo_post fifo_post_rd
     (
      .rst(fifo_pre_rst),//| (!ddr4_rstn)|wen_rst
      
      .wr_clk(mem_clk),
      .din   (fifo_post_din),
      .wr_en (fifo_post_wr_en),
      .full  (fifo_post_full), 
      .wr_data_count(fifo_post_wr_count),
      
      .rd_clk(fifo_post_rd_clk),
      .rd_en (fifo_post_rden),
      .dout  (fifo_post_dout),
      .empty (fifo_post_emp),
      .valid (fifo_post_vld)
      );
  
 
//ila_8 pre_ila (
//	.clk(fifo_pre_wr_clk), // input wire clk
//	.probe0( fifo_pre_wen ), // input wire [0:0]  probe0  
//	.probe1( fifo_pre_din[63:0] ), // input wire [31:0]  probe1 
//	.probe2( fifo_pre_f ), // input wire [0:0]  probe2 
//	.probe3(fifo_pre_rst ) 
//); (afifo1_valid & ~fifo_pre_rd_en) fifo_pre_rd_count2_wr_side
//ila_0 post_ila ( 
//	.clk(mem_clk), // input wire clk
//	.probe0( fifo_pre_rd_en ), // input wire [0:0]  probe0  
//	.probe1( afifo1_valid ), // input wire [31:0]  probe1 
//	.probe2( fifo_pre_rd_count2_wr_side  ), // input wire [0:0]  probe2 
//	.probe3( fifo_pre_rst  ) 
//);   
	
endmodule
