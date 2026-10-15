`timescale 1ns / 1ps

// Firmware status register (AXI4-Lite slave on the PS M_AXI_GPIO port).
//
// The PS firmware has one thing to tell the PL: the result of its RFDC
// startup (DAC MTS required/ready/failed, tile mask, error code, NCO SYSREF
// alignment done).  It writes that as one status word, and reads the same
// address to learn whether the PL has finished programming the HMC7044.
//
//   0x008  write  status word, byte strobes honoured
//          read   {hmc_done, status[30:0]}
//   0x00C  read   {hmc_gpio1, 15'b0, hmc_rb_sweeps[15:0]}
//   0x100  read   HMC7044 register readback, 4 registers per word: the word
//   ..1FC         at 0x100 + 4*i holds registers 4i+3..4i (MSB first).  The
//                 PL re-reads registers 0x00..0x9F continuously after
//                 configuration; hmc_rb_sweeps counts completed passes.
//
// Every other address reads as zero and ignores writes; both still complete
// with OKAY so a stray access cannot hang the PS bus.
module firmware_status_reg (
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    input  wire [8:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,

    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,

    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [8:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,

    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // HMC7044 configuration finished (same clock domain); read back in bit 31.
    input  wire        hmc_done,
    input  wire        hmc_gpio1,
    input  wire [15:0] hmc_rb_sweeps,
    output wire [5:0]  hmc_rb_index,
    input  wire [31:0] hmc_rb_word,
    output wire [31:0] status
);

  localparam ADDR_STATUS = 9'h008;
  localparam ADDR_HMC_RB_STATUS = 9'h00C;

  assign hmc_rb_index = s_axi_araddr[7:2];

  reg [31:0] status_reg;

  // AW and W are accepted independently and held until both have arrived.
  reg [8:0]  awaddr_reg;
  reg        awaddr_valid;
  reg [31:0] wdata_reg;
  reg [3:0]  wstrb_reg;
  reg        wdata_valid;

  wire aw_take = s_axi_awvalid && s_axi_awready;
  wire w_take = s_axi_wvalid && s_axi_wready;

  wire        write_addr_valid = awaddr_valid || aw_take;
  wire [8:0]  write_addr = aw_take ? s_axi_awaddr : awaddr_reg;
  wire        write_data_valid = wdata_valid || w_take;
  wire [31:0] write_data = w_take ? s_axi_wdata : wdata_reg;
  wire [3:0]  write_strb = w_take ? s_axi_wstrb : wstrb_reg;
  wire        write_fire = write_addr_valid && write_data_valid && !s_axi_bvalid;
  wire        read_fire = s_axi_arvalid && s_axi_arready;

  assign s_axi_awready = !awaddr_valid && !s_axi_bvalid;
  assign s_axi_wready = !wdata_valid && !s_axi_bvalid;
  assign s_axi_bresp = 2'b00;
  assign s_axi_arready = !s_axi_rvalid;
  assign s_axi_rresp = 2'b00;

  assign status = status_reg;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      status_reg <= 32'h00000000;
      awaddr_reg <= 9'h000;
      awaddr_valid <= 1'b0;
      wdata_reg <= 32'h00000000;
      wstrb_reg <= 4'h0;
      wdata_valid <= 1'b0;
      s_axi_bvalid <= 1'b0;
      s_axi_rvalid <= 1'b0;
      s_axi_rdata <= 32'h00000000;
    end else begin
      if (aw_take) begin
        awaddr_reg <= s_axi_awaddr;
        awaddr_valid <= 1'b1;
      end

      if (w_take) begin
        wdata_reg <= s_axi_wdata;
        wstrb_reg <= s_axi_wstrb;
        wdata_valid <= 1'b1;
      end

      if (write_fire) begin
        if (write_addr == ADDR_STATUS) begin
          if (write_strb[0]) status_reg[7:0] <= write_data[7:0];
          if (write_strb[1]) status_reg[15:8] <= write_data[15:8];
          if (write_strb[2]) status_reg[23:16] <= write_data[23:16];
          if (write_strb[3]) status_reg[31:24] <= write_data[31:24];
        end
        awaddr_valid <= 1'b0;
        wdata_valid <= 1'b0;
        s_axi_bvalid <= 1'b1;
      end else if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end

      if (read_fire) begin
        if (s_axi_araddr == ADDR_STATUS)
          s_axi_rdata <= {hmc_done, status_reg[30:0]};
        else if (s_axi_araddr == ADDR_HMC_RB_STATUS)
          s_axi_rdata <= {hmc_gpio1, 15'd0, hmc_rb_sweeps};
        else if (s_axi_araddr[8])
          s_axi_rdata <= hmc_rb_word;
        else
          s_axi_rdata <= 32'h00000000;
        s_axi_rvalid <= 1'b1;
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule
