
module vec_to_axis
#(
    parameter                               AXI_DWIDTH   = 64,
    parameter                               DATA_WIDTH   = 288,
    parameter                               PADDED_WIDTH = DATA_WIDTH
)(
    input                                   clk,
    input                                   rst,

    input                                   trigger,
    input   [DATA_WIDTH-1:0]                data,
    output                                  is_busy,
  //AXIS Interface        
    output  logic                           o_axis_tx_tvalid,                          
    output  logic   [AXI_DWIDTH-1:0]        o_axis_tx_tdata,
    output  logic                           o_axis_tx_tlast,                            
    output  logic                           o_axis_tx_tuser,                            
    output  logic   [(AXI_DWIDTH/8)-1:0]    o_axis_tx_tkeep,                            
    input                                   i_axis_tx_tready      
);








localparam D_CYCLES                     = (DATA_WIDTH-1)/AXI_DWIDTH + 1;
localparam P_CYCLES                     = (PADDED_WIDTH-1)/AXI_DWIDTH + 1;
localparam DATA_BITS                    = (DATA_WIDTH%AXI_DWIDTH) == 0 ? AXI_DWIDTH : (DATA_WIDTH%AXI_DWIDTH);
localparam PAD_BITS                     = (PADDED_WIDTH%AXI_DWIDTH) == 0 ? AXI_DWIDTH : (PADDED_WIDTH%AXI_DWIDTH);
localparam [AXI_DWIDTH/8-1:0] TKEEP_VAL = {'0,{(PAD_BITS/8){1'b1}}};


typedef enum logic [3:0] {
    AXI_IDLE, 
    AXI_SEND,
    AXI_PAD,
    AXI_PAD_LAST,
    AXI_LAST
} vec_states;
vec_states vec_state;
    
logic [D_CYCLES*AXI_DWIDTH-1:0] r_data;
logic [$clog2(P_CYCLES+1)+1:0]  cnt;
logic                  r_trigger;

always_ff@(posedge clk) begin
    if(rst)begin
        vec_state               <= AXI_IDLE;
        cnt                     <= '0;
        r_data                  <= '0;
        r_trigger               <= '0;
    end
    else begin
        r_trigger <= trigger;
        case(vec_state)
            AXI_IDLE:   begin
                cnt                     <= '0;
                r_data                  <= {'0,data};
                if({r_trigger,trigger} == 2'b01) begin
                    vec_state           <=  ((D_CYCLES == 1) && (P_CYCLES == 1)) ? AXI_LAST : AXI_SEND;
                end
            end
            AXI_SEND: begin
                if(i_axis_tx_tready) begin
                    cnt                     <= cnt + 1'b1;
                    if (P_CYCLES == D_CYCLES) begin
                        vec_state               <= (cnt == D_CYCLES-2) ? AXI_LAST : vec_state ;
                    end
                    else if (P_CYCLES == (D_CYCLES+1)) begin    
                        vec_state               <= (cnt == D_CYCLES-1) ? AXI_PAD_LAST : vec_state ;
                    end
                    else begin
                        vec_state               <= (cnt == D_CYCLES-1) ? AXI_PAD : vec_state ;
                    end                                
                end
            end
            AXI_PAD: begin
                if(i_axis_tx_tready) begin
                    cnt                     <= cnt + 1'b1;
                    vec_state               <= (cnt == P_CYCLES-2) ? AXI_PAD_LAST : vec_state ;                                
                end
            end
            AXI_PAD_LAST: begin
                vec_state               <= i_axis_tx_tready ? AXI_IDLE : vec_state; 
            end
            AXI_LAST: begin
                vec_state               <= i_axis_tx_tready ? AXI_IDLE : vec_state; 
            end
            default: begin
                vec_state               <= AXI_IDLE;
            end
        endcase
    end
end

assign o_axis_tx_tdata  = (vec_state == AXI_PAD || vec_state == AXI_PAD_LAST ||  vec_state == AXI_IDLE) ? '0 : {r_data[AXI_DWIDTH*cnt+:AXI_DWIDTH]};
assign o_axis_tx_tlast  = (vec_state == AXI_LAST) || (vec_state == AXI_PAD_LAST);
assign o_axis_tx_tvalid = (vec_state != AXI_IDLE);
assign o_axis_tx_tkeep  = o_axis_tx_tlast ? TKEEP_VAL : '1;
assign o_axis_tx_tuser  = 1'b0;
assign is_busy          = (vec_state != AXI_IDLE) && (!trigger);








endmodule
