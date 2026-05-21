`timescale 1ns / 1ps

module axis_data_fifo_1 (
  input  wire         s_axis_aclk,
  input  wire         s_axis_aresetn,
  input  wire [127:0] s_axis_tdata,
  input  wire         s_axis_tvalid,
  output wire         s_axis_tready,
  output reg  [127:0] m_axis_tdata,
  output reg          m_axis_tvalid,
  input  wire         m_axis_tready
);
  assign s_axis_tready = !m_axis_tvalid || m_axis_tready;

  always @(posedge s_axis_aclk or negedge s_axis_aresetn) begin
    if (!s_axis_aresetn) begin
      m_axis_tdata <= 128'd0;
      m_axis_tvalid <= 1'b0;
    end else begin
      if (s_axis_tready && s_axis_tvalid) begin
        m_axis_tdata <= s_axis_tdata;
        m_axis_tvalid <= 1'b1;
      end else if (m_axis_tready) begin
        m_axis_tvalid <= 1'b0;
      end
    end
  end
endmodule
