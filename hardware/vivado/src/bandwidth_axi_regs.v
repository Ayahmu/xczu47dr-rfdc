`timescale 1ns / 1ps

module bandwidth_axi_regs #(
    parameter integer ADDR_WIDTH = 12
)(
    input  wire                    s_axi_aclk,
    input  wire                    s_axi_aresetn,

    input  wire [ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  wire                    s_axi_awvalid,
    output wire                    s_axi_awready,
    input  wire [31:0]             s_axi_wdata,
    input  wire [3:0]              s_axi_wstrb,
    input  wire                    s_axi_wvalid,
    output wire                    s_axi_wready,
    output wire [1:0]              s_axi_bresp,
    output reg                     s_axi_bvalid,
    input  wire                    s_axi_bready,

    input  wire [ADDR_WIDTH-1:0]   s_axi_araddr,
    input  wire                    s_axi_arvalid,
    output wire                    s_axi_arready,
    output reg  [31:0]             s_axi_rdata,
    output wire [1:0]              s_axi_rresp,
    output reg                     s_axi_rvalid,
    input  wire                    s_axi_rready,

    output reg                     soft_reset,
    output reg                     trigger,
    output reg  [31:0]             sample_period_cycles,

    output wire [127:0]            instr_tdata,
    output wire                    instr_tvalid,
    input  wire                    instr_tready,

    input  wire [31:0]             status,
    input  wire [31:0]             total_bytes_low,
    input  wire [31:0]             total_bytes_high,
    input  wire [31:0]             total_bursts,
    input  wire [31:0]             total_stall_cycles,
    input  wire [31:0]             total_underflows,
    input  wire [31:0]             sample_index,
    input  wire [31:0]             sample_bytes_low,
    input  wire [31:0]             sample_bytes_high,
    input  wire [31:0]             sample_stalls,
    input  wire [31:0]             sample_underflows,
    input  wire [31:0]             sample_valid,
    input  wire [31:0]             ch_bytes_low,
    input  wire [31:0]             ch_bytes_high,
    input  wire [31:0]             ch_bursts,
    input  wire [31:0]             ch_stalls,
    input  wire [31:0]             ch_underflows,
    input  wire [31:0]             ch_fifo_min,
    input  wire [31:0]             ch_fifo_max,
    output reg  [2:0]              ch_select
);

  localparam [ADDR_WIDTH-1:0] REG_CONTROL       = 12'h000;
  localparam [ADDR_WIDTH-1:0] REG_TRIGGER       = 12'h004;
  localparam [ADDR_WIDTH-1:0] REG_SAMPLE_PERIOD = 12'h008;
  localparam [ADDR_WIDTH-1:0] REG_CH_SELECT     = 12'h00c;
  localparam [ADDR_WIDTH-1:0] REG_INSTR_W0      = 12'h020;
  localparam [ADDR_WIDTH-1:0] REG_INSTR_W1      = 12'h024;
  localparam [ADDR_WIDTH-1:0] REG_INSTR_W2      = 12'h028;
  localparam [ADDR_WIDTH-1:0] REG_INSTR_W3      = 12'h02c;
  localparam [ADDR_WIDTH-1:0] REG_INSTR_PUSH    = 12'h030;
  localparam [ADDR_WIDTH-1:0] REG_STATUS        = 12'h100;
  localparam [ADDR_WIDTH-1:0] REG_TOTAL_LO      = 12'h104;
  localparam [ADDR_WIDTH-1:0] REG_TOTAL_HI      = 12'h108;
  localparam [ADDR_WIDTH-1:0] REG_BURSTS        = 12'h10c;
  localparam [ADDR_WIDTH-1:0] REG_STALLS        = 12'h110;
  localparam [ADDR_WIDTH-1:0] REG_UNDERFLOWS    = 12'h114;
  localparam [ADDR_WIDTH-1:0] REG_SAMPLE_IDX    = 12'h118;
  localparam [ADDR_WIDTH-1:0] REG_SAMPLE_LO     = 12'h11c;
  localparam [ADDR_WIDTH-1:0] REG_SAMPLE_HI     = 12'h120;
  localparam [ADDR_WIDTH-1:0] REG_SAMPLE_STALL  = 12'h124;
  localparam [ADDR_WIDTH-1:0] REG_SAMPLE_UNDER  = 12'h128;
  localparam [ADDR_WIDTH-1:0] REG_SAMPLE_VALID  = 12'h12c;
  localparam [ADDR_WIDTH-1:0] REG_CH_LO         = 12'h140;
  localparam [ADDR_WIDTH-1:0] REG_CH_HI         = 12'h144;
  localparam [ADDR_WIDTH-1:0] REG_CH_BURSTS     = 12'h148;
  localparam [ADDR_WIDTH-1:0] REG_CH_STALLS     = 12'h14c;
  localparam [ADDR_WIDTH-1:0] REG_CH_UNDER      = 12'h150;
  localparam [ADDR_WIDTH-1:0] REG_CH_FIFO_MIN   = 12'h154;
  localparam [ADDR_WIDTH-1:0] REG_CH_FIFO_MAX   = 12'h158;

  reg [ADDR_WIDTH-1:0] awaddr_reg;
  reg                  awaddr_valid;
  reg [31:0]           wdata_reg;
  reg [3:0]            wstrb_reg;
  reg                  wdata_valid;
  reg [31:0]           instr_w0;
  reg [31:0]           instr_w1;
  reg [31:0]           instr_w2;
  reg [31:0]           instr_w3;
  reg [127:0]          instr_data_reg;
  reg                  instr_valid_reg;

  wire aw_take = s_axi_awvalid && s_axi_awready;
  wire w_take  = s_axi_wvalid && s_axi_wready;

  wire                  write_addr_valid = awaddr_valid || aw_take;
  wire [ADDR_WIDTH-1:0] write_addr = aw_take ? s_axi_awaddr : awaddr_reg;
  wire                  write_data_valid = wdata_valid || w_take;
  wire [31:0]           write_data = w_take ? s_axi_wdata : wdata_reg;
  wire [3:0]            write_strb = w_take ? s_axi_wstrb : wstrb_reg;
  wire                  write_fire = write_addr_valid && write_data_valid && !s_axi_bvalid;
  wire                  read_fire = s_axi_arvalid && s_axi_arready;

  assign s_axi_awready = !awaddr_valid && !s_axi_bvalid;
  assign s_axi_wready  = !wdata_valid && !s_axi_bvalid;
  assign s_axi_bresp   = 2'b00;
  assign s_axi_arready = !s_axi_rvalid;
  assign s_axi_rresp   = 2'b00;

  assign instr_tdata  = instr_data_reg;
  assign instr_tvalid = instr_valid_reg;

  function [31:0] apply_wstrb;
    input [31:0] old_value;
    input [31:0] new_value;
    input [3:0]  strb;
    begin
      apply_wstrb = old_value;
      if(strb[0]) apply_wstrb[7:0]   = new_value[7:0];
      if(strb[1]) apply_wstrb[15:8]  = new_value[15:8];
      if(strb[2]) apply_wstrb[23:16] = new_value[23:16];
      if(strb[3]) apply_wstrb[31:24] = new_value[31:24];
    end
  endfunction

  always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if(!s_axi_aresetn) begin
      awaddr_reg <= {ADDR_WIDTH{1'b0}};
      awaddr_valid <= 1'b0;
      wdata_reg <= 32'd0;
      wstrb_reg <= 4'd0;
      wdata_valid <= 1'b0;
      s_axi_bvalid <= 1'b0;
      s_axi_rvalid <= 1'b0;
      s_axi_rdata <= 32'd0;
      soft_reset <= 1'b0;
      trigger <= 1'b0;
      sample_period_cycles <= 32'd100000000;
      ch_select <= 3'd0;
      instr_w0 <= 32'd0;
      instr_w1 <= 32'd0;
      instr_w2 <= 32'd0;
      instr_w3 <= 32'd0;
      instr_data_reg <= 128'd0;
      instr_valid_reg <= 1'b0;
    end else begin
      soft_reset <= 1'b0;
      trigger <= 1'b0;

      if(instr_valid_reg && instr_tready) begin
        instr_valid_reg <= 1'b0;
      end

      if(aw_take) begin
        awaddr_reg <= s_axi_awaddr;
        awaddr_valid <= 1'b1;
      end
      if(w_take) begin
        wdata_reg <= s_axi_wdata;
        wstrb_reg <= s_axi_wstrb;
        wdata_valid <= 1'b1;
      end

      if(write_fire) begin
        case(write_addr)
          REG_CONTROL: begin
            if(write_strb[0] && write_data[0]) soft_reset <= 1'b1;
          end
          REG_TRIGGER: begin
            if(write_strb[0] && write_data[0]) trigger <= 1'b1;
          end
          REG_SAMPLE_PERIOD: sample_period_cycles <= apply_wstrb(sample_period_cycles, write_data, write_strb);
          REG_CH_SELECT: if(write_strb[0]) ch_select <= write_data[2:0];
          REG_INSTR_W0: instr_w0 <= apply_wstrb(instr_w0, write_data, write_strb);
          REG_INSTR_W1: instr_w1 <= apply_wstrb(instr_w1, write_data, write_strb);
          REG_INSTR_W2: instr_w2 <= apply_wstrb(instr_w2, write_data, write_strb);
          REG_INSTR_W3: instr_w3 <= apply_wstrb(instr_w3, write_data, write_strb);
          REG_INSTR_PUSH: begin
            if(write_strb[0] && write_data[0] && (!instr_valid_reg || instr_tready)) begin
              instr_data_reg <= {instr_w3, instr_w2, instr_w1, instr_w0};
              instr_valid_reg <= 1'b1;
            end
          end
          default: begin
          end
        endcase
        awaddr_valid <= 1'b0;
        wdata_valid <= 1'b0;
        s_axi_bvalid <= 1'b1;
      end else if(s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end

      if(read_fire) begin
        case(s_axi_araddr)
          REG_CONTROL:       s_axi_rdata <= {31'd0, soft_reset};
          REG_TRIGGER:       s_axi_rdata <= {31'd0, trigger};
          REG_SAMPLE_PERIOD: s_axi_rdata <= sample_period_cycles;
          REG_CH_SELECT:     s_axi_rdata <= {29'd0, ch_select};
          REG_INSTR_W0:      s_axi_rdata <= instr_w0;
          REG_INSTR_W1:      s_axi_rdata <= instr_w1;
          REG_INSTR_W2:      s_axi_rdata <= instr_w2;
          REG_INSTR_W3:      s_axi_rdata <= instr_w3;
          REG_INSTR_PUSH:    s_axi_rdata <= {31'd0, !instr_valid_reg || instr_tready};
          REG_STATUS:        s_axi_rdata <= status;
          REG_TOTAL_LO:      s_axi_rdata <= total_bytes_low;
          REG_TOTAL_HI:      s_axi_rdata <= total_bytes_high;
          REG_BURSTS:        s_axi_rdata <= total_bursts;
          REG_STALLS:        s_axi_rdata <= total_stall_cycles;
          REG_UNDERFLOWS:    s_axi_rdata <= total_underflows;
          REG_SAMPLE_IDX:    s_axi_rdata <= sample_index;
          REG_SAMPLE_LO:     s_axi_rdata <= sample_bytes_low;
          REG_SAMPLE_HI:     s_axi_rdata <= sample_bytes_high;
          REG_SAMPLE_STALL:  s_axi_rdata <= sample_stalls;
          REG_SAMPLE_UNDER:  s_axi_rdata <= sample_underflows;
          REG_SAMPLE_VALID:  s_axi_rdata <= sample_valid;
          REG_CH_LO:         s_axi_rdata <= ch_bytes_low;
          REG_CH_HI:         s_axi_rdata <= ch_bytes_high;
          REG_CH_BURSTS:     s_axi_rdata <= ch_bursts;
          REG_CH_STALLS:     s_axi_rdata <= ch_stalls;
          REG_CH_UNDER:      s_axi_rdata <= ch_underflows;
          REG_CH_FIFO_MIN:   s_axi_rdata <= ch_fifo_min;
          REG_CH_FIFO_MAX:   s_axi_rdata <= ch_fifo_max;
          default:           s_axi_rdata <= 32'd0;
        endcase
        s_axi_rvalid <= 1'b1;
      end else if(s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule
