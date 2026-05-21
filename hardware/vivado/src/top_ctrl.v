`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////////
module	 top_ctrl
(	
 input clk_in_p, 
 input clk_in_n,
 output H7044_SLEN,
  output H7044_SCLK,
  output H7044_SDATA,
  output H7044_SYNC,
  output RESET_H7044_H,
  input PL_CLK_N,
  input PL_CLK_P,
  input PL_SYSREF_N,
  input PL_SYSREF_P,

input[127:0] ad0_tdata,
input ad0_tvalid,
output ad0_tready,

input[127:0] ad1_tdata,
input ad1_tvalid,
output ad1_tready,

input[127:0] ad2_tdata,
input ad2_tvalid,
output ad2_tready,

input[127:0] ad3_tdata,
input ad3_tvalid,
output ad3_tready,

input[127:0] ad4_tdata,
input ad4_tvalid,
output ad4_tready,

input[127:0] ad5_tdata,
input ad5_tvalid,
output ad5_tready,

input[127:0] ad6_tdata,
input ad6_tvalid,
output ad6_tready,

input[127:0] ad7_tdata,
input ad7_tvalid,
output ad7_tready,

output ad_clk,
output da_clk,

output[127:0] da0_tdata,
output da0_tvalid,
input da0_tready,

output[127:0] da1_tdata,
output da1_tvalid,
input da1_tready,

output[127:0] da2_tdata,
output da2_tvalid,
input da2_tready,

output[127:0] da3_tdata,
output da3_tvalid,
input da3_tready,

output[127:0] da4_tdata,
output da4_tvalid,
input da4_tready,

output[127:0] da5_tdata,
output da5_tvalid,
input da5_tready,

output[127:0] da6_tdata,
output da6_tvalid,
input da6_tready,
output[127:0] da7_tdata,
output da7_tvalid,
input da7_tready,
output  adda_rstn,
output user_sysref_adc,
output user_sysref_dac,
input ps_clk0,
input ps_resetn0
);
////////////////////////////////PS BOOT
wire[17:0] s_axi_awaddr,s_axi_araddr;
wire s_axi_awvalid,s_axi_awready,s_axi_wvalid,s_axi_wready,s_axi_bvalid,s_axi_bready,s_axi_arvalid,s_axi_arready,s_axi_rvalid,s_axi_rready;
wire[31:0] s_axi_wdata,s_axi_rdata;
wire[3:0] s_axi_wstrb;
wire[1:0] s_axi_bresp,s_axi_rresp;
//wire ps_clk0,ps_resetn0;
///////////////////////////////////
wire clk100m,clk10m,locked;
clk_wiz_0 clk_wiz_inst
 (
  // Clock out ports
  .        clk_out1(clk10m),
//  .        clk_out2(clk10m),
  // Status and control signals
  .         reset(0),
  .        locked(locked),
 // Clock in ports
  .         clk_in1_p(clk_in_p),
  .         clk_in1_n(clk_in_n)
 );
 
 
 
 wire extclk_en;
 assign extclk_en = 0;
 wire clkset_finish;
 hmc7044 hmc7044_inst
(
.clk(clk10m),
.rst(locked),
.clk_sel(0),
.RESET_H7044_H(RESET_H7044_H),
.H7044_SLEN(H7044_SLEN),
.H7044_SCLK(H7044_SCLK),
.H7044_SDATA(H7044_SDATA),
.H7044_SYNC(H7044_SYNC),
.SET_FINISH(clkset_finish)
);	
 wire clk_rst;
assign clk_rst =  (!clkset_finish );//vio_rst |
wire adda_clk_locked;
wire ad_clk,da_clk;
//wire axi_100m;
wire PL_CLK;
//ADDA PLCLK 500M
wire user_sysref_adc,user_sysref_dac;
MTS_CLK MTS_CLK_inst(
    //input   aresetn,
	.   PL_CLK_N(PL_CLK_N),
    .   PL_CLK_P(PL_CLK_P),
    .   PL_SYSREF_N(PL_SYSREF_N),
    .   PL_SYSREF_P(PL_SYSREF_P),
    .   clk_adc(ad_clk),
    .   clk_dac(da_clk),
    
	. user_sysref_adc(user_sysref_adc),
	. user_sysref_dac(user_sysref_dac),
	.     PL_CLK(PL_CLK)
);

clk_adda clk_adda_inst
 (
  // Clock out ports
  .        clk_out1(axi_100m),
  .        clk_out2(ad_clk),
  .        clk_out3(),
  // Status and control signals
  .         reset(clk_rst),
  .        locked(adda_clk_locked),
 // Clock in ports
  .         clk_in1(PL_CLK)
 );
 assign da_clk = ad_clk;
 assign adda_rstn = adda_clk_locked;
// reg s_axi_aresetn=0;
//ADDA sysref
//wire[127:0] ad0_data,ad1_data,ad2_data,ad3_data,ad4_data,ad5_data,ad6_data,ad7_data;
//wire ad0_vaild,ad1_vaild,ad2_vaild,ad3_vaild,ad4_vaild,ad5_vaild,ad6_vaild,ad7_vaild;
reg[127:0] ad0_data_reg,ad1_data_reg,ad2_data_reg,ad3_data_reg,ad4_data_reg,ad5_data_reg,ad6_data_reg,ad7_data_reg;
reg[127:0] ad0_data_reg1,ad1_data_reg1,ad2_data_reg1,ad3_data_reg1,ad4_data_reg1,ad5_data_reg1,ad6_data_reg1,ad7_data_reg1;
reg ad0_vaild_reg,ad1_vaild_reg,ad2_vaild_reg,ad3_vaild_reg,ad4_vaild_reg,ad5_vaild_reg,ad6_vaild_reg,ad7_vaild_reg;
assign ad0_tready = 1;
assign ad1_tready = 1;
assign ad2_tready = 1;
assign ad3_tready = 1;
assign ad4_tready = 1;
assign ad5_tready = 1;
assign ad6_tready = 1;
assign ad7_tready = 1;
always@(posedge ad_clk)begin
ad0_data_reg <= ad0_tdata;
ad1_data_reg <= ad1_tdata;
ad2_data_reg <= ad2_tdata;
ad3_data_reg <= ad3_tdata;
ad4_data_reg <= ad4_tdata;
ad5_data_reg <= ad5_tdata;
ad6_data_reg <= ad6_tdata;
ad7_data_reg <= ad7_tdata;
ad0_data_reg1 <= ad0_data_reg;
ad1_data_reg1 <= ad1_data_reg;
ad2_data_reg1 <= ad2_data_reg;
ad3_data_reg1 <= ad3_data_reg;
ad4_data_reg1 <= ad4_data_reg;
ad5_data_reg1 <= ad5_data_reg;
ad6_data_reg1 <= ad6_data_reg;
ad7_data_reg1 <= ad7_data_reg;
ad0_vaild_reg <= 1;
ad1_vaild_reg <= 1;
ad2_vaild_reg <= 1;
ad3_vaild_reg <= 1;
ad4_vaild_reg <= 1;
ad5_vaild_reg <= 1;
ad6_vaild_reg <= 1;
ad7_vaild_reg <= 1;
end
//wire[127:0] da0_data,da1_data,da2_data,da3_data,da4_data,da5_data,da6_data,da7_data;
assign da0_tdata = ad0_data_reg1;
assign da1_tdata = ad1_data_reg1;
assign da2_tdata = ad2_data_reg1;
assign da3_tdata = ad3_data_reg1;
assign da4_tdata = ad4_data_reg1;
assign da5_tdata = ad5_data_reg1;
assign da6_tdata = ad6_data_reg1;
assign da7_tdata = ad7_data_reg1;
assign da0_tvalid = 1;
assign da1_tvalid = 1;
assign da2_tvalid = 1;
assign da3_tvalid = 1;
assign da4_tvalid = 1;
assign da5_tvalid = 1;
assign da6_tvalid = 1;
assign da7_tvalid = 1;
////////////////////////////////
reg[15:0] ad0_data0_dbg,ad0_data1_dbg,ad0_data2_dbg,ad0_data3_dbg,ad0_data4_dbg,ad0_data5_dbg,ad0_data6_dbg,ad0_data7_dbg,ad0_data8_dbg,ad0_data9_dbg;
reg[15:0] ad1_data0_dbg,ad1_data1_dbg,ad1_data2_dbg,ad1_data3_dbg,ad1_data4_dbg,ad1_data5_dbg,ad1_data6_dbg,ad1_data7_dbg,ad1_data8_dbg,ad1_data9_dbg;
reg[15:0] ad2_data0_dbg,ad2_data1_dbg,ad2_data2_dbg,ad2_data3_dbg,ad2_data4_dbg,ad2_data5_dbg,ad2_data6_dbg,ad2_data7_dbg,ad2_data8_dbg,ad2_data9_dbg;
reg[15:0] ad3_data0_dbg,ad3_data1_dbg,ad3_data2_dbg,ad3_data3_dbg,ad3_data4_dbg,ad3_data5_dbg,ad3_data6_dbg,ad3_data7_dbg,ad3_data8_dbg,ad3_data9_dbg;
reg[15:0] ad4_data0_dbg,ad4_data1_dbg,ad4_data2_dbg,ad4_data3_dbg,ad4_data4_dbg,ad4_data5_dbg,ad4_data6_dbg,ad4_data7_dbg,ad4_data8_dbg,ad4_data9_dbg;
reg[15:0] ad5_data0_dbg,ad5_data1_dbg,ad5_data2_dbg,ad5_data3_dbg,ad5_data4_dbg,ad5_data5_dbg,ad5_data6_dbg,ad5_data7_dbg,ad5_data8_dbg,ad5_data9_dbg;
reg[15:0] ad6_data0_dbg,ad6_data1_dbg,ad6_data2_dbg,ad6_data3_dbg,ad6_data4_dbg,ad6_data5_dbg,ad6_data6_dbg,ad6_data7_dbg,ad6_data8_dbg,ad6_data9_dbg;
reg[15:0] ad7_data0_dbg,ad7_data1_dbg,ad7_data2_dbg,ad7_data3_dbg,ad7_data4_dbg,ad7_data5_dbg,ad7_data6_dbg,ad7_data7_dbg,ad7_data8_dbg,ad7_data9_dbg;
always@(posedge ad_clk)begin
ad0_data0_dbg <= ad0_tdata[16*1-1:16*0];
ad0_data1_dbg <= ad0_tdata[16*2-1:16*1];
ad0_data2_dbg <= ad0_tdata[16*3-1:16*2];
ad0_data3_dbg <= ad0_tdata[16*4-1:16*3];
ad0_data4_dbg <= ad0_tdata[16*5-1:16*4];
ad0_data5_dbg <= ad0_tdata[16*6-1:16*5];
ad0_data6_dbg <= ad0_tdata[16*7-1:16*6];
ad0_data7_dbg <= ad0_tdata[16*8-1:16*7];
//ad0_data8_dbg <= ad0_data[16*9-1:16*8];
//ad0_data9_dbg <= ad0_data[16*10-1:16*9];

ad1_data0_dbg <= ad1_tdata[16*1-1:16*0];
ad1_data1_dbg <= ad1_tdata[16*2-1:16*1];
ad1_data2_dbg <= ad1_tdata[16*3-1:16*2];
ad1_data3_dbg <= ad1_tdata[16*4-1:16*3];
ad1_data4_dbg <= ad1_tdata[16*5-1:16*4];
ad1_data5_dbg <= ad1_tdata[16*6-1:16*5];
ad1_data6_dbg <= ad1_tdata[16*7-1:16*6];
ad1_data7_dbg <= ad1_tdata[16*8-1:16*7];
//ad1_data8_dbg <= ad1_data[16*9-1:16*8];
//ad1_data9_dbg <= ad1_data[16*10-1:16*9];

ad2_data0_dbg <= ad2_tdata[16*1-1:16*0];
ad2_data1_dbg <= ad2_tdata[16*2-1:16*1];
ad2_data2_dbg <= ad2_tdata[16*3-1:16*2];
ad2_data3_dbg <= ad2_tdata[16*4-1:16*3];
ad2_data4_dbg <= ad2_tdata[16*5-1:16*4];
ad2_data5_dbg <= ad2_tdata[16*6-1:16*5];
ad2_data6_dbg <= ad2_tdata[16*7-1:16*6];
ad2_data7_dbg <= ad2_tdata[16*8-1:16*7];
//ad2_data8_dbg <= ad2_data[16*9-1:16*8];
//ad2_data9_dbg <= ad2_data[16*10-1:16*9];

ad3_data0_dbg <= ad3_tdata[16*1-1:16*0];
ad3_data1_dbg <= ad3_tdata[16*2-1:16*1];
ad3_data2_dbg <= ad3_tdata[16*3-1:16*2];
ad3_data3_dbg <= ad3_tdata[16*4-1:16*3];
ad3_data4_dbg <= ad3_tdata[16*5-1:16*4];
ad3_data5_dbg <= ad3_tdata[16*6-1:16*5];
ad3_data6_dbg <= ad3_tdata[16*7-1:16*6];
ad3_data7_dbg <= ad3_tdata[16*8-1:16*7];
//ad3_data8_dbg <= ad3_data[16*9-1:16*8];
//ad3_data9_dbg <= ad3_data[16*10-1:16*9];

ad4_data0_dbg <= ad4_tdata[16*1-1:16*0];
ad4_data1_dbg <= ad4_tdata[16*2-1:16*1];
ad4_data2_dbg <= ad4_tdata[16*3-1:16*2];
ad4_data3_dbg <= ad4_tdata[16*4-1:16*3];
ad4_data4_dbg <= ad4_tdata[16*5-1:16*4];
ad4_data5_dbg <= ad4_tdata[16*6-1:16*5];
ad4_data6_dbg <= ad4_tdata[16*7-1:16*6];
ad4_data7_dbg <= ad4_tdata[16*8-1:16*7];
//ad4_data8_dbg <= ad4_data[16*9-1:16*8];
//ad4_data9_dbg <= ad4_data[16*10-1:16*9];

ad5_data0_dbg <= ad5_tdata[16*1-1:16*0];
ad5_data1_dbg <= ad5_tdata[16*2-1:16*1];
ad5_data2_dbg <= ad5_tdata[16*3-1:16*2];
ad5_data3_dbg <= ad5_tdata[16*4-1:16*3];
ad5_data4_dbg <= ad5_tdata[16*5-1:16*4];
ad5_data5_dbg <= ad5_tdata[16*6-1:16*5];
ad5_data6_dbg <= ad5_tdata[16*7-1:16*6];
ad5_data7_dbg <= ad5_tdata[16*8-1:16*7];
//ad5_data8_dbg <= ad5_data[16*9-1:16*8];
//ad5_data9_dbg <= ad5_data[16*10-1:16*9];

ad6_data0_dbg <= ad6_tdata[16*1-1:16*0];
ad6_data1_dbg <= ad6_tdata[16*2-1:16*1];
ad6_data2_dbg <= ad6_tdata[16*3-1:16*2];
ad6_data3_dbg <= ad6_tdata[16*4-1:16*3];
ad6_data4_dbg <= ad6_tdata[16*5-1:16*4];
ad6_data5_dbg <= ad6_tdata[16*6-1:16*5];
ad6_data6_dbg <= ad6_tdata[16*7-1:16*6];
ad6_data7_dbg <= ad6_tdata[16*8-1:16*7];
//ad6_data8_dbg <= ad6_data[16*9-1:16*8];
//ad6_data9_dbg <= ad6_data[16*10-1:16*9];

ad7_data0_dbg <= ad7_tdata[16*1-1:16*0];
ad7_data1_dbg <= ad7_tdata[16*2-1:16*1];
ad7_data2_dbg <= ad7_tdata[16*3-1:16*2];
ad7_data3_dbg <= ad7_tdata[16*4-1:16*3];
ad7_data4_dbg <= ad7_tdata[16*5-1:16*4];
ad7_data5_dbg <= ad7_tdata[16*6-1:16*5];
ad7_data6_dbg <= ad7_tdata[16*7-1:16*6];
ad7_data7_dbg <= ad7_tdata[16*8-1:16*7];
//ad7_data8_dbg <= ad7_data[16*9-1:16*8];
//ad7_data9_dbg <= ad7_data[16*10-1:16*9];
end
ila_0 ila_00(
.clk(ad_clk),
.probe0(ad0_data0_dbg),
.probe1(ad0_data1_dbg),
.probe2(ad0_data2_dbg),
.probe3(ad0_data3_dbg),
.probe4(ad0_data4_dbg),
.probe5(ad0_data5_dbg),
.probe6(ad0_data6_dbg),
.probe7(ad0_data7_dbg),

.probe8(ad1_data0_dbg),
.probe9(ad1_data1_dbg),
.probe10(ad1_data2_dbg),
.probe11(ad1_data3_dbg),
.probe12(ad1_data4_dbg),
.probe13(ad1_data5_dbg),
.probe14(ad1_data6_dbg),
.probe15(ad1_data7_dbg),

.probe16(ad2_data0_dbg),
.probe17(ad2_data1_dbg),
.probe18(ad2_data2_dbg),
.probe19(ad2_data3_dbg),
.probe20(ad2_data4_dbg),
.probe21(ad2_data5_dbg),
.probe22(ad2_data6_dbg),
.probe23(ad2_data7_dbg),

.probe24(ad3_data0_dbg),
.probe25(ad3_data1_dbg),
.probe26(ad3_data2_dbg),
.probe27(ad3_data3_dbg),
.probe28(ad3_data4_dbg),
.probe29(ad3_data5_dbg),
.probe30(ad3_data6_dbg),
.probe31(ad3_data7_dbg),

.probe32(ad4_data0_dbg),
.probe33(ad4_data1_dbg),
.probe34(ad4_data2_dbg),
.probe35(ad4_data3_dbg),
.probe36(ad4_data4_dbg),
.probe37(ad4_data5_dbg),
.probe38(ad4_data6_dbg),
.probe39(ad4_data7_dbg),

.probe40(ad5_data0_dbg),
.probe41(ad5_data1_dbg),
.probe42(ad5_data2_dbg),
.probe43(ad5_data3_dbg),
.probe44(ad5_data4_dbg),
.probe45(ad5_data5_dbg),
.probe46(ad5_data6_dbg),
.probe47(ad5_data7_dbg),

.probe48(ad6_data0_dbg),
.probe49(ad6_data1_dbg),
.probe50(ad6_data2_dbg),
.probe51(ad6_data3_dbg),
.probe52(ad6_data4_dbg),
.probe53(ad6_data5_dbg),
.probe54(ad6_data6_dbg),
.probe55(ad6_data7_dbg),

.probe56(ad7_data0_dbg),
.probe57(ad7_data1_dbg),
.probe58(ad7_data2_dbg),
.probe59(ad7_data3_dbg),
.probe60(ad7_data4_dbg),
.probe61(ad7_data5_dbg),
.probe62(ad7_data6_dbg),
.probe63(ad7_data7_dbg)
);


endmodule
