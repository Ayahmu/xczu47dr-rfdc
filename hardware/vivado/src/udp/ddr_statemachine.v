`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
//mode:
// 1）	RAM模式0，写满停止，读完结束。
// 2）	RAM模式1，写满停止，循环读取。直至start上升沿开始下一轮
// 3）	RAM模式2，循环写，直至触发上升沿时停止。触发位置在数据中间，数据一次性读出。

//////////////////////////////////////////////////////////////////////////////////


module ddr_statemachine
  #( 
   parameter procress_axi_addr_wid = 33,  // 用户实际操作的内存大小axi地址宽度，例如8G内存，用户实际只需操作128MB
   parameter log2_dat_wid = 6 ,           // 数据宽度，6为2的6次方个字节，64字节，512位 
   parameter log2_burst_words = 6,         //突发长度，一次64个
   parameter dbg = 1 
    ) 
(
    input clk,
    input rst,
    
    input        start,
    input        trig_en, 
    input [1:0]  mode, 
    
    input ddr_wr_detect,
    input ddr_rd_detect, 
    input axi_bvalid, 
    input axi_bready, 
    
    output reg ddr_wren,
    output     ddr_rden 
    );

   localparam burst_addr_sw   = log2_burst_words + log2_dat_wid; //12
   localparam burst_addr_size = 1 << burst_addr_sw; //4k 一次突发地址增量
   
   localparam log2_words_in_ram  = procress_axi_addr_wid - log2_dat_wid; //27
   localparam log2_bursts_in_ram = log2_words_in_ram - log2_burst_words; //21 
   localparam bursts_in_ram      = 1 << log2_bursts_in_ram;//能发的突发读/写指令总数 2M
  
   localparam IDLE            = 3'b000; 
   localparam WT_TRIG         = 3'b001;   
   localparam WR_ALL          = 3'b010;
   localparam WRITE_OK        = 3'b011;
   localparam FIFO_MODE       = 3'b100;   
   
   reg [2:0] state = IDLE;
   
   reg        trig_en_d1, trig_en_d2, trig_en_d3;
   reg        start_d1,start_d2,start_d3;
 
   reg [1:0]       mode_d1,mode_d2,mode_d3;  
   reg [log2_bursts_in_ram-1:0] cnt, cnt_dl;
   
   always @(posedge clk) begin
       trig_en_d1 <= trig_en;
       trig_en_d2 <= trig_en_d1;
       trig_en_d3 <= trig_en_d2;
       start_d1   <= start;
       start_d2   <= start_d1;
       start_d3   <= start_d2;
       mode_d1 <= mode;
       mode_d2 <= mode_d1;
       mode_d3 <= mode_d2;  
   end
   
   reg ddr_rden_t;
   always @(posedge clk)
      if (rst) begin
          state <= IDLE;
          ddr_wren <= 1'b0;
          ddr_rden_t  <= 1'b0; 
          cnt    <= 0;
          cnt_dl    <= 0;
      end   else
         case (state)
            IDLE : begin
              if (start_d2 & ~start_d3 )   begin
                   if (mode_d3[1]==1'b0)   state <= WR_ALL; // mode 0/1
                   else if(mode_d3==2'b10) state <= WT_TRIG;// mode 2    
                   else if(mode_d3==2'b11) state <= FIFO_MODE;// mode 3    
              end else                   state <= IDLE;                 
              
              ddr_wren  <= 1'b0;
              ddr_rden_t  <= 1'b0; 
              cnt    <= 0;
            end  
            
            FIFO_MODE : begin
              ddr_wren  <= (cnt < (bursts_in_ram-8'd8) ); 
              
              if (axi_bvalid & axi_bready & ~ddr_rd_detect)        cnt <= cnt + 1;
              else if (~(axi_bvalid & axi_bready) & ddr_rd_detect) cnt <= cnt - 1;               
              
              cnt_dl    <= cnt;
              
              if(start_d1 & ~start_d2 ) state     <= IDLE;  //重新start
                    
            end
                     
            WT_TRIG : begin ///// wait trig ,  ddr read and write
              if (trig_en_d2 & ~trig_en_d3) state <= WR_ALL;  //trig posedge                    
              else                          state <= WT_TRIG;                 
              
              ddr_wren  <= 1'b1;
              ddr_rden_t  <= 1'b0; 
              cnt    <= 0;
            end 
            
            WR_ALL : begin ///// write data to ddr
              if( ( mode_d3[1] & (cnt==((bursts_in_ram>>1) - 1) )  & ddr_wr_detect )  | //mode 2: write half deep
                  ( (~mode_d3[1]) & (cnt==(bursts_in_ram - 1) ) & ddr_wr_detect )       //mode 0/1: write full deep
                ) begin
                   state    <= WRITE_OK;  
                   cnt      <= 0;
              end else if(ddr_wr_detect) begin
                   cnt <= cnt + 1;//11'd1024; // 1K bytes per axi_bvalid
                   state <= WR_ALL;                 
              end
              ddr_wren  <= 1'b1;
              ddr_rden_t  <= 1'b0; 
            end       
 
            WRITE_OK : begin ///// write data ok
              if((~mode_d3[0]) &  (cnt==(bursts_in_ram - 1) ) & ddr_rd_detect ) begin// mode0和mode2 读一次完毕，开始下一循环操作，等待下一个start 
                    state     <= IDLE;    
              end else if(mode_d3[0] & start_d3 & ~start_d2  ) begin//mode1如果不重新start，就循环读
                    state     <= IDLE;   
              end else if(ddr_rd_detect) begin
                    cnt       <= cnt + 1;// per ddr burst 
              end      
             ddr_wren  <= 1'b0;  
             ddr_rden_t  <= 1'b1;    
              
            end            
                        
         endcase
         
	wire ddr_rden_fifomode;
	assign ddr_rden_fifomode = (|cnt) & (|cnt_dl);
	
	assign ddr_rden = (&mode_d3) ? ddr_rden_fifomode : ddr_rden_t;
	
//   generate
//      if (dbg) begin:dbgila 
//            ila_1 ila_0i (
//                .clk(clk),  
//                .probe0(state ) ,
//                .probe1(cnt ) 
//            );  
//      end
//   endgenerate
			
		

endmodule
