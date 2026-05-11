`timescale 1ns / 1ps

module AXIS_PULSE_GEN #(
    parameter WAVE_PERIOD   = 4096,
    parameter PULSE_WIDTH   = 1
)(
    input  wire aclk,
    input  wire aresetn,

    output wire trigger_out
);

    reg [31:0] sample_cnt;
    reg        trigger_reg;

    assign trigger_out = trigger_reg;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            sample_cnt  <= 0;
            trigger_reg <= 1'b0;
        end else begin
            if (sample_cnt >= WAVE_PERIOD - 1) begin
                sample_cnt <= 0;
            end else begin
                sample_cnt <= sample_cnt + 1;
            end

            if (sample_cnt < PULSE_WIDTH) begin
                trigger_reg <= 1'b1; 
            end 
            else begin
                trigger_reg <= 1'b0;
            end
        end
    end

endmodule