`timescale 1ns / 1ps

module udp64_to_axis128_instr (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         udp_tvalid,
    input  wire [63:0]  udp_tdata,

    output reg  [127:0] m_axis_tdata,
    output reg          m_axis_tvalid,
    input  wire         m_axis_tready
);

  reg        have_low_word;
  reg [63:0] low_word;

  wire output_accepted = m_axis_tvalid && m_axis_tready;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      have_low_word <= 1'b0;
      low_word      <= 64'd0;
      m_axis_tdata  <= 128'd0;
      m_axis_tvalid <= 1'b0;
    end else begin
      if (output_accepted) begin
        m_axis_tvalid <= 1'b0;
      end

      if (udp_tvalid && (!m_axis_tvalid || output_accepted)) begin
        if (!have_low_word) begin
          low_word      <= udp_tdata;
          have_low_word <= 1'b1;
        end else begin
          m_axis_tdata  <= {udp_tdata, low_word};
          m_axis_tvalid <= 1'b1;
          have_low_word <= 1'b0;
        end
      end
    end
  end

endmodule
