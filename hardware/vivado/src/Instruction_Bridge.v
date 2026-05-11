`timescale 1ns / 1ps

// =========================================================================
// 子模块: 异步 FIFO (保持 128 位宽不变)
// =========================================================================
module axi_fifo_async_core #(
    parameter DATA_WIDTH = 128,
    parameter ADDR_WIDTH = 4
)(
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire                  full,

    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  empty
);
    // 内存定义 (128位宽)
    reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];
    
    // 指针定义
    reg [ADDR_WIDTH:0] wr_ptr_bin, wr_ptr_gray;
    reg [ADDR_WIDTH:0] rd_ptr_bin, rd_ptr_gray;
    reg [ADDR_WIDTH:0] wr_ptr_gray_r1, wr_ptr_gray_r2;
    reg [ADDR_WIDTH:0] rd_ptr_gray_r1, rd_ptr_gray_r2;

    // --- Write Domain ---
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin  <= 0;
            wr_ptr_gray <= 0;
        end else if (wr_en && !full) begin
            wr_ptr_bin  <= wr_ptr_bin + 1;
            wr_ptr_gray <= (wr_ptr_bin + 1) ^ ((wr_ptr_bin + 1) >> 1);
        end
    end

    always @(posedge wr_clk) begin
        if (wr_en && !full) mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
    end

    assign full = (wr_ptr_gray == {~rd_ptr_gray_r2[ADDR_WIDTH:ADDR_WIDTH-1], rd_ptr_gray_r2[ADDR_WIDTH-2:0]});

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) {rd_ptr_gray_r1, rd_ptr_gray_r2} <= 0;
        else {rd_ptr_gray_r2, rd_ptr_gray_r1} <= {rd_ptr_gray_r1, rd_ptr_gray};
    end

    // --- Read Domain ---
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin  <= 0;
            rd_ptr_gray <= 0;
        end else if (rd_en && !empty) begin
            rd_ptr_bin  <= rd_ptr_bin + 1;
            rd_ptr_gray <= (rd_ptr_bin + 1) ^ ((rd_ptr_bin + 1) >> 1);
        end
    end

    assign rd_data = mem[rd_ptr_bin[ADDR_WIDTH-1:0]];
    assign empty = (rd_ptr_gray == wr_ptr_gray_r2);

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) {wr_ptr_gray_r1, wr_ptr_gray_r2} <= 0;
        else {wr_ptr_gray_r2, wr_ptr_gray_r1} <= {wr_ptr_gray_r1, wr_ptr_gray};
    end
endmodule

// =========================================================================
// 顶层模块: axi_fifo_interface (32-bit AXI In -> 128-bit FIFO Out)
// =========================================================================
module axi_fifo_interface #(
    parameter AXI_DATA_WIDTH  = 32,   // 输入是 32位
    parameter FIFO_DATA_WIDTH = 128,  // 输出是 128位
    parameter FIFO_DEPTH_LOG2 = 4
)(
    // AXI4-Lite Slave Interface (PS Side - 32 bit)
    input  wire                  s_axi_aclk,
    input  wire                  s_axi_aresetn,
    
    // Write Channels
    input  wire [31:0]               s_axi_awaddr,
    input  wire                      s_axi_awvalid,
    output reg                       s_axi_awready,
    input  wire [AXI_DATA_WIDTH-1:0] s_axi_wdata,  // 32-bit input
    input  wire [3:0]                s_axi_wstrb,
    input  wire                      s_axi_wvalid,
    output reg                       s_axi_wready,
    output reg  [1:0]                s_axi_bresp,
    output reg                       s_axi_bvalid,
    input  wire                      s_axi_bready,
    
    // Read Channels (Dummy)
    input  wire [31:0]               s_axi_araddr,
    input  wire                      s_axi_arvalid,
    output reg                       s_axi_arready,
    output reg  [AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output reg  [1:0]                s_axi_rresp,
    output reg                       s_axi_rvalid,
    input  wire                      s_axi_rready,

    // AXI Stream Master Interface (Logic Side - 128 bit)
    input  wire                      m_aclk,
    input  wire                      m_aresetn,
    output wire [FIFO_DATA_WIDTH-1:0] m_axis_tdata, // 128-bit output
    output wire                      m_axis_tvalid,
    input  wire                      m_axis_tready
);

    // --- AXI Write Logic & Packing ---
    wire fifo_full;
    reg  fifo_wr_en;
    reg [127:0] data_accumulator; // 用于拼接 4 个 32位数据

    // 1. AXI 握手逻辑
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 0;
            s_axi_wready  <= 0;
            s_axi_bvalid  <= 0;
            s_axi_bresp   <= 0;
            fifo_wr_en    <= 0;
            data_accumulator <= 128'd0;
        end else begin
            // 默认拉低写使能 (脉冲信号)
            fifo_wr_en <= 0;

            // Ready 生成
            s_axi_awready <= (s_axi_awvalid && s_axi_wvalid && !s_axi_awready);
            s_axi_wready  <= (s_axi_wvalid && s_axi_awvalid && !s_axi_wready);

            // 数据接收与拼接
            if (s_axi_wready && s_axi_wvalid && s_axi_awready && s_axi_awvalid) begin
                // 根据地址的低位 [3:2] 判断是第几个 32位字
                // 0x00 -> [31:0]
                // 0x04 -> [63:32]
                // 0x08 -> [95:64]
                // 0x0C -> [127:96] (并且写入 FIFO)
                case (s_axi_awaddr[3:2])
                    2'b00: data_accumulator[31:0]   <= s_axi_wdata;
                    2'b01: data_accumulator[63:32]  <= s_axi_wdata;
                    2'b10: data_accumulator[95:64]  <= s_axi_wdata;
                    2'b11: begin
                           data_accumulator[127:96] <= s_axi_wdata;
                           // 只有在写入最后一个字 (0x0C) 时，且 FIFO 没满，才触发写入
                           if (!fifo_full) begin
                               fifo_wr_en <= 1;
                           end
                    end
                endcase
                
                // 发送写响应
                s_axi_bvalid <= 1;
            end else if (s_axi_bready && s_axi_bvalid) begin
                s_axi_bvalid <= 0;
            end
        end
    end

    // --- AXI Read Logic (Dummy) ---
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 0;
            s_axi_rvalid  <= 0;
            s_axi_rdata   <= 0;
            s_axi_rresp   <= 0;
        end else begin
            if (s_axi_arvalid && !s_axi_arready)
                s_axi_arready <= 1;
            else
                s_axi_arready <= 0;

            if (s_axi_arvalid && s_axi_arready && !s_axi_rvalid) begin
                s_axi_rvalid <= 1;
                s_axi_rdata  <= 32'd0; 
            end else if (s_axi_rready && s_axi_rvalid) begin
                s_axi_rvalid <= 0;
            end
        end
    end

    // --- Async FIFO 实例化 ---
    wire fifo_empty;
    wire [127:0] fifo_dout;
    wire fifo_rd_en;

    axi_fifo_async_core #(
        .DATA_WIDTH(128), // FIFO 内部存储 128 位
        .ADDR_WIDTH(FIFO_DEPTH_LOG2)
    ) u_core (
        .wr_clk   (s_axi_aclk),
        .wr_rst_n (s_axi_aresetn),
        .wr_en    (fifo_wr_en),        // 由 0x0C 写操作触发
        .wr_data  (data_accumulator),  // 写入拼接好的 128 位数据
        .full     (fifo_full),

        .rd_clk   (m_aclk),
        .rd_rst_n (m_aresetn),
        .rd_en    (fifo_rd_en),
        .rd_data  (fifo_dout),
        .empty    (fifo_empty)
    );

    // --- Stream Output Mapping ---
    assign m_axis_tdata  = fifo_dout;
    assign m_axis_tvalid = !fifo_empty;
    assign fifo_rd_en    = m_axis_tvalid && m_axis_tready;

endmodule