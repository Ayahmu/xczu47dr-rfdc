`timescale 1ns/1ps

// AXI-Lite register interface for TDC calibration and readout.
// Provides read access to phase measurement and write access to calibration table.
//
// Register map (all 32-bit):
//   0x000: TDC_PHASE_PS_X10 (RO) - Latest phase measurement in units of 10ps
//   0x004: TDC_STATUS (RO) - [0]=valid, [1]=overflow, [2]=metastable
//   0x008: TDC_TAP_RAW (RO) - Raw tap index (debug)
//   0x400-0x7FC: TDC_CALIB_TABLE[0-255] (RW) - Calibration table, 16-bit per entry

module tdc_axi_regs #(
    parameter ADDR_WIDTH = 12
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // AXI-Lite slave interface
    input  wire [ADDR_WIDTH-1:0]  s_axi_awaddr,
    input  wire                   s_axi_awvalid,
    output wire                   s_axi_awready,
    input  wire [31:0]            s_axi_wdata,
    input  wire [3:0]             s_axi_wstrb,
    input  wire                   s_axi_wvalid,
    output wire                   s_axi_wready,
    output wire [1:0]             s_axi_bresp,
    output reg                    s_axi_bvalid,
    input  wire                   s_axi_bready,

    input  wire [ADDR_WIDTH-1:0]  s_axi_araddr,
    input  wire                   s_axi_arvalid,
    output wire                   s_axi_arready,
    output reg  [31:0]            s_axi_rdata,
    output wire [1:0]             s_axi_rresp,
    output reg                    s_axi_rvalid,
    input  wire                   s_axi_rready,

    // TDC core interface
    input  wire [15:0]            tdc_phase_ps_x10,
    input  wire                   tdc_phase_valid,
    input  wire                   tdc_phase_overflow,
    input  wire                   tdc_phase_metastable,
    input  wire [7:0]             tdc_tap_raw,

    output reg                    tdc_calib_wr_en,
    output reg  [9:0]             tdc_calib_wr_addr,
    output reg  [15:0]            tdc_calib_wr_data
);

  // Register addresses
  localparam ADDR_TDC_PHASE      = 12'h000;
  localparam ADDR_TDC_STATUS     = 12'h004;
  localparam ADDR_TDC_TAP_RAW    = 12'h008;
  localparam ADDR_TDC_CALIB_BASE = 12'h400;  // 0x400-0x7FC (256 entries × 4 bytes)

  // Write channel
  reg [ADDR_WIDTH-1:0] awaddr_reg;
  reg                  awaddr_valid;
  reg [31:0]           wdata_reg;
  reg [3:0]            wstrb_reg;
  reg                  wdata_valid;

  assign s_axi_awready = !awaddr_valid;
  assign s_axi_wready  = !wdata_valid;
  assign s_axi_bresp   = 2'b00;  // OKAY

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      awaddr_reg    <= {ADDR_WIDTH{1'b0}};
      awaddr_valid  <= 1'b0;
      wdata_reg     <= 32'd0;
      wstrb_reg     <= 4'd0;
      wdata_valid   <= 1'b0;
      s_axi_bvalid  <= 1'b0;
    end else begin
      // Capture write address
      if (s_axi_awvalid && s_axi_awready) begin
        awaddr_reg   <= s_axi_awaddr;
        awaddr_valid <= 1'b1;
      end

      // Capture write data
      if (s_axi_wvalid && s_axi_wready) begin
        wdata_reg   <= s_axi_wdata;
        wstrb_reg   <= s_axi_wstrb;
        wdata_valid <= 1'b1;
      end

      // Complete write transaction
      if (awaddr_valid && wdata_valid && !s_axi_bvalid) begin
        awaddr_valid <= 1'b0;
        wdata_valid  <= 1'b0;
        s_axi_bvalid <= 1'b1;
      end

      // Clear bvalid when acknowledged
      if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end
    end
  end

  // Write logic: calibration table only
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tdc_calib_wr_en   <= 1'b0;
      tdc_calib_wr_addr <= 10'd0;
      tdc_calib_wr_data <= 16'd0;
    end else begin
      tdc_calib_wr_en <= 1'b0;  // default

      if (awaddr_valid && wdata_valid && !s_axi_bvalid) begin
        // Check if address is in calibration table range
        if (awaddr_reg >= ADDR_TDC_CALIB_BASE && awaddr_reg < (ADDR_TDC_CALIB_BASE + 12'h400)) begin
          tdc_calib_wr_en   <= 1'b1;
          tdc_calib_wr_addr <= (awaddr_reg - ADDR_TDC_CALIB_BASE) >> 2;  // byte addr -> word index
          tdc_calib_wr_data <= wdata_reg[15:0];
        end
      end
    end
  end

  // Read channel
  reg [ADDR_WIDTH-1:0] araddr_reg;
  reg                  araddr_valid;

  assign s_axi_arready = !araddr_valid;
  assign s_axi_rresp   = 2'b00;  // OKAY

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      araddr_reg   <= {ADDR_WIDTH{1'b0}};
      araddr_valid <= 1'b0;
      s_axi_rdata  <= 32'd0;
      s_axi_rvalid <= 1'b0;
    end else begin
      // Capture read address
      if (s_axi_arvalid && s_axi_arready) begin
        araddr_reg   <= s_axi_araddr;
        araddr_valid <= 1'b1;
      end

      // Complete read transaction
      if (araddr_valid && !s_axi_rvalid) begin
        araddr_valid <= 1'b0;
        s_axi_rvalid <= 1'b1;

        // Read mux
        case (araddr_reg)
          ADDR_TDC_PHASE: begin
            s_axi_rdata <= {16'd0, tdc_phase_ps_x10};
          end
          ADDR_TDC_STATUS: begin
            s_axi_rdata <= {29'd0, tdc_phase_metastable, tdc_phase_overflow, tdc_phase_valid};
          end
          ADDR_TDC_TAP_RAW: begin
            s_axi_rdata <= {24'd0, tdc_tap_raw};
          end
          default: begin
            // Calibration table reads not supported (write-only from CPU perspective)
            s_axi_rdata <= 32'hDEADBEEF;
          end
        endcase
      end

      // Clear rvalid when acknowledged
      if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule
