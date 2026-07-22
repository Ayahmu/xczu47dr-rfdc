`timescale 1ns / 1ps

module axilite_cdc_simple (
    input  wire        s_clk,
    input  wire        s_rst_n,
    input  wire [17:0] s_awaddr,
    input  wire        s_awvalid,
    output reg         s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output reg         s_wready,
    output reg  [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [17:0] s_araddr,
    input  wire        s_arvalid,
    output reg         s_arready,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rvalid,
    input  wire        s_rready,

    input  wire        m_clk,
    input  wire        m_rst_n,
    output reg  [17:0] m_awaddr,
    output reg         m_awvalid,
    input  wire        m_awready,
    output reg  [31:0] m_wdata,
    output reg  [3:0]  m_wstrb,
    output reg         m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output reg         m_bready,
    output reg  [17:0] m_araddr,
    output reg         m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output reg         m_rready
);

  localparam [1:0] S_IDLE = 2'd0;
  localparam [1:0] S_WAIT_ACK = 2'd1;
  localparam [1:0] S_RESP = 2'd2;

  localparam [1:0] M_IDLE = 2'd0;
  localparam [1:0] M_WRITE = 2'd1;
  localparam [1:0] M_READ = 2'd2;

  reg [1:0] s_state;
  reg [1:0] m_state;

  reg        s_have_aw;
  reg        s_have_w;
  reg [17:0] s_cap_awaddr;
  reg [31:0] s_cap_wdata;
  reg [3:0]  s_cap_wstrb;
  reg        req_toggle_s;
  reg        req_is_write_s;
  reg [17:0] req_addr_s;
  reg [31:0] req_wdata_s;
  reg [3:0]  req_wstrb_s;
  reg        ack_seen_s;

  reg        ack_toggle_m;
  reg [1:0]  ack_resp_m;
  reg [31:0] ack_rdata_m;

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] req_sync_m;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] ack_sync_s;

  reg        req_seen_m;
  reg        m_req_write;
  reg [17:0] m_req_addr;
  reg [31:0] m_req_wdata;
  reg [3:0]  m_req_wstrb;
  reg        m_aw_done;
  reg        m_w_done;

  always @(posedge s_clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      s_state <= S_IDLE;
      s_awready <= 1'b0;
      s_wready <= 1'b0;
      s_bresp <= 2'b00;
      s_bvalid <= 1'b0;
      s_arready <= 1'b0;
      s_rdata <= 32'd0;
      s_rresp <= 2'b00;
      s_rvalid <= 1'b0;
      s_have_aw <= 1'b0;
      s_have_w <= 1'b0;
      s_cap_awaddr <= 18'd0;
      s_cap_wdata <= 32'd0;
      s_cap_wstrb <= 4'd0;
      req_toggle_s <= 1'b0;
      req_is_write_s <= 1'b0;
      req_addr_s <= 18'd0;
      req_wdata_s <= 32'd0;
      req_wstrb_s <= 4'd0;
      ack_seen_s <= 1'b0;
      ack_sync_s <= 3'b000;
    end else begin
      ack_sync_s <= {ack_sync_s[1:0], ack_toggle_m};
      s_awready <= 1'b0;
      s_wready <= 1'b0;
      s_arready <= 1'b0;

      case (s_state)
        S_IDLE: begin
          if (!s_have_aw) s_awready <= 1'b1;
          if (!s_have_w) s_wready <= 1'b1;
          s_arready <= !s_have_aw && !s_have_w && !s_bvalid && !s_rvalid;

          if (s_awvalid && s_awready) begin
            s_have_aw <= 1'b1;
            s_cap_awaddr <= s_awaddr;
          end
          if (s_wvalid && s_wready) begin
            s_have_w <= 1'b1;
            s_cap_wdata <= s_wdata;
            s_cap_wstrb <= s_wstrb;
          end

          if (s_arvalid && s_arready) begin
            req_is_write_s <= 1'b0;
            req_addr_s <= s_araddr;
            req_wdata_s <= 32'd0;
            req_wstrb_s <= 4'd0;
            req_toggle_s <= ~req_toggle_s;
            s_state <= S_WAIT_ACK;
          end else if ((s_have_aw || (s_awvalid && s_awready)) &&
                       (s_have_w  || (s_wvalid && s_wready))) begin
            req_is_write_s <= 1'b1;
            req_addr_s <= (s_awvalid && s_awready) ? s_awaddr : s_cap_awaddr;
            req_wdata_s <= (s_wvalid && s_wready) ? s_wdata : s_cap_wdata;
            req_wstrb_s <= (s_wvalid && s_wready) ? s_wstrb : s_cap_wstrb;
            req_toggle_s <= ~req_toggle_s;
            s_have_aw <= 1'b0;
            s_have_w <= 1'b0;
            s_state <= S_WAIT_ACK;
          end
        end

        S_WAIT_ACK: begin
          if (ack_sync_s[2] != ack_seen_s) begin
            ack_seen_s <= ack_sync_s[2];
            if (req_is_write_s) begin
              s_bresp <= ack_resp_m;
              s_bvalid <= 1'b1;
            end else begin
              s_rdata <= ack_rdata_m;
              s_rresp <= ack_resp_m;
              s_rvalid <= 1'b1;
            end
            s_state <= S_RESP;
          end
        end

        S_RESP: begin
          if (s_bvalid && s_bready) begin
            s_bvalid <= 1'b0;
            s_state <= S_IDLE;
          end
          if (s_rvalid && s_rready) begin
            s_rvalid <= 1'b0;
            s_state <= S_IDLE;
          end
        end

        default: s_state <= S_IDLE;
      endcase
    end
  end

  always @(posedge m_clk or negedge m_rst_n) begin
    if (!m_rst_n) begin
      m_state <= M_IDLE;
      req_sync_m <= 3'b000;
      req_seen_m <= 1'b0;
      m_req_write <= 1'b0;
      m_req_addr <= 18'd0;
      m_req_wdata <= 32'd0;
      m_req_wstrb <= 4'd0;
      m_awaddr <= 18'd0;
      m_awvalid <= 1'b0;
      m_wdata <= 32'd0;
      m_wstrb <= 4'd0;
      m_wvalid <= 1'b0;
      m_bready <= 1'b0;
      m_araddr <= 18'd0;
      m_arvalid <= 1'b0;
      m_rready <= 1'b0;
      m_aw_done <= 1'b0;
      m_w_done <= 1'b0;
      ack_toggle_m <= 1'b0;
      ack_resp_m <= 2'b00;
      ack_rdata_m <= 32'd0;
    end else begin
      req_sync_m <= {req_sync_m[1:0], req_toggle_s};

      case (m_state)
        M_IDLE: begin
          m_awvalid <= 1'b0;
          m_wvalid <= 1'b0;
          m_bready <= 1'b0;
          m_arvalid <= 1'b0;
          m_rready <= 1'b0;
          m_aw_done <= 1'b0;
          m_w_done <= 1'b0;
          if (req_sync_m[2] != req_seen_m) begin
            req_seen_m <= req_sync_m[2];
            m_req_write <= req_is_write_s;
            m_req_addr <= req_addr_s;
            m_req_wdata <= req_wdata_s;
            m_req_wstrb <= req_wstrb_s;
            if (req_is_write_s) begin
              m_awaddr <= req_addr_s;
              m_awvalid <= 1'b1;
              m_wdata <= req_wdata_s;
              m_wstrb <= req_wstrb_s;
              m_wvalid <= 1'b1;
              m_bready <= 1'b1;
              m_state <= M_WRITE;
            end else begin
              m_araddr <= req_addr_s;
              m_arvalid <= 1'b1;
              m_rready <= 1'b1;
              m_state <= M_READ;
            end
          end
        end

        M_WRITE: begin
          if (m_awvalid && m_awready) begin
            m_awvalid <= 1'b0;
            m_aw_done <= 1'b1;
          end
          if (m_wvalid && m_wready) begin
            m_wvalid <= 1'b0;
            m_w_done <= 1'b1;
          end
          if (m_bvalid && m_bready && (m_aw_done || (m_awvalid && m_awready)) &&
              (m_w_done || (m_wvalid && m_wready))) begin
            ack_resp_m <= m_bresp;
            ack_rdata_m <= 32'd0;
            ack_toggle_m <= ~ack_toggle_m;
            m_bready <= 1'b0;
            m_state <= M_IDLE;
          end
        end

        M_READ: begin
          if (m_arvalid && m_arready) begin
            m_arvalid <= 1'b0;
          end
          if (m_rvalid && m_rready) begin
            ack_resp_m <= m_rresp;
            ack_rdata_m <= m_rdata;
            ack_toggle_m <= ~ack_toggle_m;
            m_rready <= 1'b0;
            m_state <= M_IDLE;
          end
        end

        default: m_state <= M_IDLE;
      endcase
    end
  end

endmodule
