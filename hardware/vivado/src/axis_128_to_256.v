// ============================================================
//  axis_128_to_256 : 128-bit -> 256-bit AXIS gearbox.
//
//  Two consecutive 128-bit input beats are merged into one
//  256-bit output beat:
//    output[127:0]   = first  input beat  (DAC slice 0 of the tile)
//    output[255:128] = second input beat  (DAC slice 2 of the tile)
//
//  Each 128-bit DDR beat carries one DAC's 8x16-bit IQ lane group
//  (4 complex samples). One 256-bit tile word therefore carries the
//  two physical DACs of a single RFDC tile for one fabric cycle.
// ============================================================
module axis_128_to_256 (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [127:0] s_tdata,
    input  wire         s_tvalid,
    output wire         s_tready,

    output wire [255:0] m_tdata,
    output wire         m_tvalid,
    input  wire         m_tready
);

  localparam [0:0] PHASE_LOW  = 1'b0; // waiting for first (low) beat
  localparam [0:0] PHASE_HIGH = 1'b1; // low captured, waiting for high beat

  reg        phase;
  reg [127:0] low_half;

  // Accept input whenever we are filling, or when draining and the output
  // word can be consumed this cycle.
  assign s_tready = (phase == PHASE_LOW) || m_tready;

  // A full 256-bit word is available when the high beat is presented while
  // the low half is already buffered.
  assign m_tvalid = (phase == PHASE_HIGH) && s_tvalid;
  assign m_tdata  = {s_tdata, low_half};

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase    <= PHASE_LOW;
      low_half <= 128'd0;
    end else begin
      case (phase)
        PHASE_LOW: begin
          if (s_tvalid) begin
            low_half <= s_tdata;
            phase    <= PHASE_HIGH;
          end
        end

        PHASE_HIGH: begin
          // High beat fires together with the output handshake.
          if (s_tvalid && m_tready) begin
            phase <= PHASE_LOW;
          end
        end

        default: phase <= PHASE_LOW;
      endcase
    end
  end

endmodule
