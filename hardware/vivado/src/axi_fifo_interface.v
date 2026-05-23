`timescale 1ns / 1ps

module axi_fifo_interface #(
    parameter integer AXI_DATA_WIDTH = 32,
    parameter integer FIFO_DATA_WIDTH = 128,
    parameter integer FIFO_DEPTH_LOG2 = 4
)(
    input  wire                         s_axi_aclk,
    input  wire                         s_axi_aresetn,

    input  wire [31:0]                  s_axi_awaddr,
    input  wire [7:0]                   s_axi_awlen,
    input  wire                         s_axi_awvalid,
    output wire                         s_axi_awready,
    input  wire [AXI_DATA_WIDTH-1:0]    s_axi_wdata,
    input  wire [(AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                         s_axi_wvalid,
    output wire                         s_axi_wready,
    output reg                          s_axi_bvalid,
    input  wire                         s_axi_bready,
    output wire [1:0]                   s_axi_bresp,

    input  wire [31:0]                  s_axi_araddr,
    input  wire [7:0]                   s_axi_arlen,
    input  wire                         s_axi_arvalid,
    output wire                         s_axi_arready,
    output wire [AXI_DATA_WIDTH-1:0]    s_axi_rdata,
    output wire                         s_axi_rlast,
    output reg                          s_axi_rvalid,
    input  wire                         s_axi_rready,
    output wire [1:0]                   s_axi_rresp,

    input  wire                         m_aclk,
    input  wire                         m_aresetn,
    output wire [FIFO_DATA_WIDTH-1:0]   m_axis_tdata,
    output wire                         m_axis_tvalid,
    input  wire                         m_axis_tready
);

  localparam integer WORDS_PER_FIFO_BEAT = FIFO_DATA_WIDTH / AXI_DATA_WIDTH;
  localparam integer PACK_COUNT_WIDTH = (WORDS_PER_FIFO_BEAT <= 2) ? 1 : $clog2(WORDS_PER_FIFO_BEAT);
  localparam integer FIFO_DEPTH = (1 << FIFO_DEPTH_LOG2);

  initial begin
    if (AXI_DATA_WIDTH != 32) begin
      $error("axi_fifo_interface supports AXI_DATA_WIDTH=32 only");
    end
    if (FIFO_DATA_WIDTH != 128) begin
      $error("axi_fifo_interface supports FIFO_DATA_WIDTH=128 only");
    end
  end

  reg [FIFO_DATA_WIDTH-1:0] pack_data;
  reg [PACK_COUNT_WIDTH-1:0] pack_count;
  reg aw_active;
  reg [7:0] beats_remaining;
  reg [7:0] read_beats_remaining;

  wire fifo_full;
  wire fifo_empty;
  wire fifo_wr_en;
  wire fifo_rd_en;
  wire accepting_last_pack_word;
  wire accepting_last_axi_word;

  assign s_axi_awready = !aw_active && !s_axi_bvalid;
  assign s_axi_wready = aw_active && ((pack_count != WORDS_PER_FIFO_BEAT-1) || !fifo_full);
  assign s_axi_bresp = 2'b00;

  assign s_axi_arready = !s_axi_rvalid;
  assign s_axi_rdata = {AXI_DATA_WIDTH{1'b0}};
  assign s_axi_rresp = 2'b00;

  assign accepting_last_pack_word = s_axi_wvalid && s_axi_wready && (pack_count == WORDS_PER_FIFO_BEAT-1);
  assign accepting_last_axi_word = s_axi_wvalid && s_axi_wready && (beats_remaining == 8'd0);
  assign fifo_wr_en = accepting_last_pack_word;

  always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
      aw_active <= 1'b0;
      beats_remaining <= 8'd0;
      read_beats_remaining <= 8'd0;
      pack_data <= {FIFO_DATA_WIDTH{1'b0}};
      pack_count <= {PACK_COUNT_WIDTH{1'b0}};
      s_axi_bvalid <= 1'b0;
      s_axi_rvalid <= 1'b0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin
        aw_active <= 1'b1;
        beats_remaining <= s_axi_awlen;
      end

      if (s_axi_wvalid && s_axi_wready) begin
        pack_data[pack_count*AXI_DATA_WIDTH +: AXI_DATA_WIDTH] <= s_axi_wdata;

        if (accepting_last_pack_word) begin
          pack_count <= {PACK_COUNT_WIDTH{1'b0}};
        end else begin
          pack_count <= pack_count + {{(PACK_COUNT_WIDTH-1){1'b0}}, 1'b1};
        end

        if (accepting_last_axi_word) begin
          aw_active <= 1'b0;
          s_axi_bvalid <= 1'b1;
        end else begin
          beats_remaining <= beats_remaining - 8'd1;
        end
      end

      if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end

      if (s_axi_arvalid && s_axi_arready) begin
        s_axi_rvalid <= 1'b1;
        read_beats_remaining <= s_axi_arlen;
      end else if (s_axi_rvalid && s_axi_rready) begin
        if (read_beats_remaining == 8'd0) begin
          s_axi_rvalid <= 1'b0;
        end else begin
          read_beats_remaining <= read_beats_remaining - 8'd1;
        end
      end
    end
  end

  assign fifo_rd_en = m_axis_tvalid && m_axis_tready;
  assign m_axis_tvalid = !fifo_empty;

  xpm_fifo_async #(
      .CASCADE_HEIGHT(0),
      .CDC_SYNC_STAGES(2),
      .DOUT_RESET_VALUE("0"),
      .ECC_MODE("no_ecc"),
      .FIFO_MEMORY_TYPE("auto"),
      .FIFO_READ_LATENCY(1),
      .FIFO_WRITE_DEPTH(FIFO_DEPTH),
      .FULL_RESET_VALUE(0),
      .PROG_EMPTY_THRESH(3),
      .PROG_FULL_THRESH(FIFO_DEPTH-3),
      .RD_DATA_COUNT_WIDTH(FIFO_DEPTH_LOG2+1),
      .READ_DATA_WIDTH(FIFO_DATA_WIDTH),
      .READ_MODE("fwft"),
      .RELATED_CLOCKS(0),
      .SIM_ASSERT_CHK(0),
      .USE_ADV_FEATURES("0000"),
      .WAKEUP_TIME(0),
      .WRITE_DATA_WIDTH(FIFO_DATA_WIDTH),
      .WR_DATA_COUNT_WIDTH(FIFO_DEPTH_LOG2+1)
  ) instr_fifo_i (
      .almost_empty(),
      .almost_full(),
      .data_valid(),
      .dbiterr(),
      .dout(m_axis_tdata),
      .empty(fifo_empty),
      .full(fifo_full),
      .overflow(),
      .prog_empty(),
      .prog_full(),
      .rd_data_count(),
      .rd_rst_busy(),
      .sbiterr(),
      .underflow(),
      .wr_ack(),
      .wr_data_count(),
      .wr_rst_busy(),
      .din({s_axi_wdata, pack_data[FIFO_DATA_WIDTH-AXI_DATA_WIDTH-1:0]}),
      .injectdbiterr(1'b0),
      .injectsbiterr(1'b0),
      .rd_clk(m_aclk),
      .rd_en(fifo_rd_en),
      .rst(!s_axi_aresetn || !m_aresetn),
      .sleep(1'b0),
      .wr_clk(s_axi_aclk),
      .wr_en(fifo_wr_en)
  );

  assign s_axi_rlast = s_axi_rvalid && (read_beats_remaining == 8'd0);

  wire _unused = &{1'b0, s_axi_awaddr, s_axi_wstrb, s_axi_araddr, s_axi_arlen};

endmodule
