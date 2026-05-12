module AXIGPIOBlackBox (
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

    output wire [1:0]  gpio_io_o,
    output wire [31:0] gpio2_io_o
);

  localparam ADDR_GPIO_DATA  = 9'h000;
  localparam ADDR_GPIO2_DATA = 9'h008;

  reg [1:0]  gpio_reg;
  reg [31:0] gpio2_reg;

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

  assign gpio_io_o = gpio_reg;
  assign gpio2_io_o = gpio2_reg;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      gpio_reg <= 2'b00;
      gpio2_reg <= 32'h00000000;
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
        case (write_addr)
          ADDR_GPIO_DATA: begin
            if (write_strb[0]) begin
              gpio_reg <= write_data[1:0];
            end
          end
          ADDR_GPIO2_DATA: begin
            if (write_strb[0]) gpio2_reg[7:0] <= write_data[7:0];
            if (write_strb[1]) gpio2_reg[15:8] <= write_data[15:8];
            if (write_strb[2]) gpio2_reg[23:16] <= write_data[23:16];
            if (write_strb[3]) gpio2_reg[31:24] <= write_data[31:24];
          end
        endcase
        awaddr_valid <= 1'b0;
        wdata_valid <= 1'b0;
        s_axi_bvalid <= 1'b1;
      end else if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end

      if (read_fire) begin
        case (s_axi_araddr)
          ADDR_GPIO_DATA: s_axi_rdata <= {30'h0, gpio_reg};
          ADDR_GPIO2_DATA: s_axi_rdata <= gpio2_reg;
          default: s_axi_rdata <= 32'h00000000;
        endcase
        s_axi_rvalid <= 1'b1;
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule
