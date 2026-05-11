`timescale 1ns / 1ps

module axis_axis_trigger_start #(
    parameter DATA_WIDTH      = 32
)(
    input  wire                       aclk,
    input  wire                       aresetn,
    
    input  wire [DATA_WIDTH-1:0]      s_data_tdata,
    input  wire                       s_data_tvalid,
    output reg                        s_data_tready,
    input  wire                       s_data_tlast,

    output reg  [DATA_WIDTH-1:0]      m_data_tdata,
    output reg                        m_data_tvalid,
    input  wire                       m_data_tready,

    input  wire                       trigger_in
);
    localparam STATE_IDLE = 2'd0;
    localparam STATE_RUN  = 2'd1;

    reg [1:0] state;

    reg [1:0] trig_sync;
    reg       trig_d;
    wire      trigger_posedge;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            trig_sync <= 2'b00;
            trig_d    <= 1'b0;
        end else begin
            trig_sync <= {trig_sync[0], trigger_in};
            trig_d    <= trig_sync[1];
        end
    end

    assign trigger_posedge = trig_sync[1] && (!trig_d);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state <= STATE_IDLE;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (trigger_posedge && s_data_tvalid) begin
                        state <= STATE_RUN;
                    end
                end

                STATE_RUN: begin
                    if (s_data_tvalid && s_data_tready && s_data_tlast) begin
                        state <= STATE_IDLE;
                    end
                end
            endcase
        end
    end

    always @(*) begin
        s_data_tready = 1'b0;
        m_data_tvalid = 1'b0;
        m_data_tdata  = {DATA_WIDTH{1'b0}};

        case (state)
            STATE_IDLE: begin
                s_data_tready = 1'b0; 
                m_data_tvalid = 1'b0; 
            end

            STATE_RUN: begin
                m_data_tvalid = s_data_tvalid;
                s_data_tready = m_data_tready;
                m_data_tdata  = s_data_tdata;
            end
        endcase
    end
endmodule