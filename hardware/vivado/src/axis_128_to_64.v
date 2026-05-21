module axis_128_to_64 (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [127:0] s_tdata,
    input  wire         s_tvalid,
    output wire         s_tready,

    output wire [63:0]  m_tdata,
    output wire         m_tvalid,
    input  wire         m_tready
);

  localparam [1:0] PHASE_EMPTY = 2'd0;
  localparam [1:0] PHASE_UPPER = 2'd1;
  localparam [1:0] PHASE_LOWER_BUFFERED = 2'd2;

  reg [1:0]  phase;
  reg [63:0] lower_half;
  reg [63:0] upper_half;

  assign s_tready = m_tready && (phase != PHASE_LOWER_BUFFERED);
  assign m_tvalid = (phase != PHASE_EMPTY) || s_tvalid;
  assign m_tdata  = (phase == PHASE_UPPER) ? upper_half :
                    (phase == PHASE_LOWER_BUFFERED) ? lower_half :
                    s_tdata[63:0];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase      <= PHASE_EMPTY;
      lower_half <= 64'd0;
      upper_half <= 64'd0;
    end else if (m_tready) begin
      case (phase)
        PHASE_EMPTY: begin
          if (s_tvalid) begin
            upper_half <= s_tdata[127:64];
            phase      <= PHASE_UPPER;
          end
        end

        PHASE_UPPER: begin
          if (s_tvalid) begin
            lower_half <= s_tdata[63:0];
            upper_half <= s_tdata[127:64];
            phase      <= PHASE_LOWER_BUFFERED;
          end else begin
            phase <= PHASE_EMPTY;
          end
        end

        default: begin
          phase <= PHASE_UPPER;
        end
      endcase
    end
  end

endmodule
