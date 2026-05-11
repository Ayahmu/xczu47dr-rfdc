module axis_tlast_generator #(
    parameter DATA_WIDTH = 128,
    parameter PACKET_LEN = 1024
)(
    input  wire                  aclk,
    input  wire                  aresetn,
    
    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                  s_axis_tvalid,
    output wire                  s_axis_tready,
 
    output wire [DATA_WIDTH-1:0] m_axis_tdata,
    output wire                  m_axis_tvalid,
    input  wire                  m_axis_tready,
    output wire                  m_axis_tlast
);

    reg [31:0] beat_count;

    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tvalid = s_axis_tvalid;
    assign s_axis_tready = m_axis_tready;

    assign m_axis_tlast = (beat_count == PACKET_LEN - 1);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            beat_count <= 0;
        end else begin
            if (s_axis_tvalid && m_axis_tready) begin
                if (beat_count == PACKET_LEN - 1) begin
                    beat_count <= 0;
                end else begin
                    beat_count <= beat_count + 1;
                end
            end
        end
    end

endmodule