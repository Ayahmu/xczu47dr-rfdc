module axis_to_rfdc_continuous #(
  parameter integer W = 128
)(
  input  wire         clk,
  input  wire         rst_n,

  // 来自 FIFO 的数据与“原 valid”（建议用你 gated 后的 valid）
  input  wire [W-1:0] s_tdata,
  input  wire         s_tvalid_gated,

  // 来自 RFDC 的 ready
  input  wire         m_tready,

  // 送 RFDC：valid 常 1
  output wire [W-1:0] m_tdata,
  output wire         m_tvalid
);

  reg [W-1:0] m_tdata_r;

  assign m_tvalid = 1'b1;
  assign m_tdata  = m_tdata_r;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_tdata_r <= {W{1'b0}};
    end else begin
      // 只有在 ready=1 时才允许改变输出数据（满足 AXIS 稳定性要求）
      if (m_tready) begin
        m_tdata_r <= s_tvalid_gated ? s_tdata : {W{1'b0}};
      end
    end
  end

endmodule
