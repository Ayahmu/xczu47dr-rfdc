//----------------------------------------------------------------------------------
// 指令模块：上位机发送和板卡接收使用的指令接口。解析上位机udp模块发送过来的指令
//---------------------+------------------------------------------------------------
// command             |  说明
//---------------------+------------------------------------------------------------
// 0x00000000_00000001 |  rec_en = 1
// 0x00000000_00000000 |  rec_en = 0
// 0x00000000_00000003 |  play_en = 1
// 0x00000000_00000002 |  play_en = 0
// 0x00000000_00000005 |  soft_rst = 1
// 0x00000000_00000004 |  soft_rst = 0
// 0x00000002_0000000x |  mode_ddr0 = x
// 0x00000001_0000000x |  mode_ddr1 = x
// 0x00000003_xxxxxxxx |  gap_num  = xxxxxxxx
// 0x00000004_0000xxxx |  数据输出dat_vld， 输出数据字节数xxxx，后跟xxxx字节的数据
//---------------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none
 
module command 
( 
    input  wire        clk,
    input  wire        rst, 
 
    input wire        rcv_vld,
    input wire[63:0]  rcv_dat,
     
    output reg        rec_en,  //记录使能
    output reg        play_en, //回放使能
//    output reg        soft_rst, 
    
    output reg[15:0]   ad1_trig_val, //ad1预置值
    output reg[15:0]   ad2_trig_val, //ad1预置值
    output reg[15:0]   ad3_trig_val, //ad1预置值
    output reg[15:0]   ad4_trig_val, //ad1预置值
    output reg[15:0]   ad5_trig_val, //ad1预置值
    output reg[15:0]   ad6_trig_val, //ad1预置值
    output reg[15:0]   ad7_trig_val, //ad1预置值
    output reg[15:0]   ad8_trig_val, //ad1预置值
    
    output reg[1:0]   mode_ddr0,// AD通路DDR工作模式，0:写满停止，读完结束。 1:写满停止，循环读取。直至start上升沿开始下一轮
                                //                   2:触发模式。触发位置在数据中间，数据一次性读出。3：fifo模式
    output reg[1:0]   mode_ddr1,// DA通路DDR工作模式，0:写满停止，读完结束。 1:写满停止，循环读取。直至start上升沿开始下一轮
                                  //                 2:触发模式。触发位置在数据中间，数据一次性读出。3：fifo模式
    output reg[23:0]  gap_num, //udp包间延时调节
    
    output reg        dat_vld,
    output reg[63:0]  dat
      
);

localparam  
    STATE_IDLE = 1'd0,
    STATE_DATA = 1'd1; 

reg   state_reg = STATE_IDLE;
 
reg [34:0] dat_cnt; 

always @(posedge clk) begin
    if (rst ) begin
        state_reg <= STATE_IDLE; 
        rec_en    <= 'd0;
        play_en   <= 'd0;
        ad1_trig_val <= 'd0;
        ad2_trig_val <= 'd0;
        ad3_trig_val <= 'd0;
        ad4_trig_val <= 'd0;
        ad5_trig_val <= 'd0;
        ad6_trig_val <= 'd0;
        ad7_trig_val <= 'd0;
        ad8_trig_val <= 'd0;
        mode_ddr0 <= 'd0; 
        mode_ddr1 <= 'd0;
        gap_num   <= 'd1100;
        dat_vld   <= 'd0;
        dat       <= 'd0;
        dat_cnt  <=  'd0; 
    end else if(state_reg==STATE_IDLE) begin
          dat_vld        <= 'd0;
          if(rcv_vld) begin  
               if( rcv_dat[7:0]==8'd1) begin //0x00000000_00000001
                   rec_en    <= 1'b1;
                   
                   case (rcv_dat[10:8])
                      3'd0  :ad1_trig_val <= rcv_dat[31:16];
                      3'd1  :ad2_trig_val <= rcv_dat[31:16];
                      3'd2  :ad3_trig_val <= rcv_dat[31:16];
                      3'd3  :ad4_trig_val <= rcv_dat[31:16];
                      3'd4  :ad5_trig_val <= rcv_dat[31:16];
                      3'd5  :ad6_trig_val <= rcv_dat[31:16];
                      3'd6  :ad7_trig_val <= rcv_dat[31:16];
                      3'd7  :ad8_trig_val <= rcv_dat[31:16];
                      default: ad8_trig_val <= rcv_dat[31:16];
                   endcase

                   state_reg <= STATE_IDLE; 
               end else if(|rcv_dat[7:0]==1'b0 ) begin  //0x00000000_00000000
                   rec_en    <= 1'b0;
                   state_reg <= STATE_IDLE; 
               end 
               
               if(rcv_dat[7:0]==8'd3) begin //0x00000000_00000003
                   play_en    <= 1'b1;
                   state_reg <= STATE_IDLE; 
               end else if(rcv_dat[7:0]==8'd2 ) begin //0x00000000_00000002
                   play_en    <= 1'b0;
                   state_reg <= STATE_IDLE; 
               end 
                                          
               if(rcv_dat[7:0]==8'd4) begin// 0x00000000_0000xx04
                   mode_ddr0 <= rcv_dat[9:8];
                   state_reg <= STATE_IDLE;  
               end 
               
               if(rcv_dat[7:0]==8'd5) begin// 0x00000000_0000xx05
                   mode_ddr1 <= rcv_dat[9:8];
                   state_reg <= STATE_IDLE;  
               end 
               
               if(rcv_dat[7:0]==8'd6) begin// 0x00000000_xxxxxx06
                   gap_num   <= rcv_dat[31:8];
                   state_reg <= STATE_IDLE;  
               end 
               
               if(rcv_dat[7:0]==8'd7) begin// 0x00000000_xxxxxx07
                   dat_cnt   <= {rcv_dat[22:8],20'd0};
                   state_reg <= STATE_DATA;  
               end 
          end 
    end else begin
          if(rcv_vld) begin
               dat_vld        <= 'd1;
               dat            <= rcv_dat;
               dat_cnt        <= dat_cnt - 8'd8;
               if(dat_cnt==35'd8)  state_reg      <= STATE_IDLE; 
           end else begin
               dat_vld       <= 'd0;                           
           end  
    end

end


    ila_3 ila_3 (
        .clk(clk), // input wire clk  
        .probe0(dat_vld    ), // input wire [0:0]  probe0  
        .probe1(dat        ), // input wire [0:0]  probe1 
        .probe2(dat_cnt    ), // 33
        .probe3(state_reg  ), // input wire [0:0]  probe3 
        .probe4(rcv_vld     ), // input wire [0:0]  probe4 
        .probe5(rcv_dat    )
    ); 
         
        

endmodule

`resetall
