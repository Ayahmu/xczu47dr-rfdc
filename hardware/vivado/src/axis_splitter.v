`timescale 1ns / 1ps

module axis_splitter_delay_128to64x2 #(
    parameter DELAY_WIDTH = 32
)(
    input  wire                   aclk,
    input  wire                   aresetn,

    // --- Config Inputs ---
    input  wire [DELAY_WIDTH-1:0] delay_cycles_a,
    input  wire [DELAY_WIDTH-1:0] delay_cycles_b,

    // --- Slave Input (128-bit) ---
    input  wire [127:0]           s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tlast,

    // --- Master Output A (64-bit) ---
    output wire [63:0]            m_axis_a_tdata, // 这里改为 wire，由 assign 驱动
    output wire                   m_axis_a_tvalid,
    input  wire                   m_axis_a_tready,
    output wire                   m_axis_a_tlast,

    // --- Master Output B (64-bit) ---
    output wire [63:0]            m_axis_b_tdata,
    output wire                   m_axis_b_tvalid,
    input  wire                   m_axis_b_tready,
    output wire                   m_axis_b_tlast
);

    // ... (中间的 FIFO 定义和实例化部分保持不变) ...
    // ... (请保留原代码中的 xpm_fifo_sync 实例化部分) ...
    
    // =========================================================
    // 1. 内部 FIFO 信号 (复用你的原代码)
    // =========================================================
    wire [63:0] fifo_a_din, fifo_b_din;
    wire        fifo_a_wren, fifo_b_wren;
    wire        fifo_a_full, fifo_b_full;
    wire        fifo_a_empty, fifo_b_empty;
    reg         fifo_a_rden, fifo_b_rden;
    wire [64:0] fifo_a_in_packed, fifo_b_in_packed;
    wire [64:0] fifo_a_out_packed, fifo_b_out_packed;

    assign fifo_a_din = s_axis_tdata[63:0];
    assign fifo_b_din = s_axis_tdata[127:64];
    assign fifo_a_in_packed = {s_axis_tlast, fifo_a_din};
    assign fifo_b_in_packed = {s_axis_tlast, fifo_b_din};

    wire write_enable = s_axis_tvalid && (!fifo_a_full) && (!fifo_b_full);
    assign fifo_a_wren = write_enable;
    assign fifo_b_wren = write_enable;
    assign s_axis_tready = (!fifo_a_full) && (!fifo_b_full);

    // 实例化 FIFO A
    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE("auto"), .FIFO_WRITE_DEPTH(4096),
        .WRITE_DATA_WIDTH(65), .READ_DATA_WIDTH(65),
        .READ_MODE("fwft")
    ) u_fifo_a (
        .sleep(1'b0), .rst(~aresetn), .wr_clk(aclk), .wr_en(fifo_a_wren), 
        .din(fifo_a_in_packed), .full(fifo_a_full), .rd_en(fifo_a_rden), 
        .dout(fifo_a_out_packed), .empty(fifo_a_empty),
        .injectsbiterr(1'b0), .injectdbiterr(1'b0)
    );

    // 实例化 FIFO B
    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE("auto"), .FIFO_WRITE_DEPTH(512),
        .WRITE_DATA_WIDTH(65), .READ_DATA_WIDTH(65),
        .READ_MODE("fwft")
    ) u_fifo_b (
        .sleep(1'b0), .rst(~aresetn), .wr_clk(aclk), .wr_en(fifo_b_wren), 
        .din(fifo_b_in_packed), .full(fifo_b_full), .rd_en(fifo_b_rden), 
        .dout(fifo_b_out_packed), .empty(fifo_b_empty),
        .injectsbiterr(1'b0), .injectdbiterr(1'b0)
    );

    // =========================================================
    // 关键修改区：解包与输出控制
    // =========================================================
    
    wire        fifo_a_last_out, fifo_b_last_out;
    wire [63:0] fifo_a_tdata_raw, fifo_b_tdata_raw; // 原始 FIFO 数据

    // 1. 先把 FIFO 数据解包到临时变量，而不是直接连到输出
    assign {fifo_a_last_out, fifo_a_tdata_raw} = fifo_a_out_packed;
    assign {fifo_b_last_out, fifo_b_tdata_raw} = fifo_b_out_packed;

    // 2. 延时控制逻辑 (保持不变)
    reg [DELAY_WIDTH-1:0] cnt_a;
    reg [DELAY_WIDTH-1:0] cnt_b;
    reg active_a, active_b;

    // 通道 A 状态机
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            cnt_a <= 0;
            active_a <= 0;
            fifo_a_rden <= 0;
        end else begin
            fifo_a_rden <= 0;
            if (!active_a) begin
                if (!fifo_a_empty) begin
                    if (cnt_a >= delay_cycles_a) active_a <= 1;
                    else cnt_a <= cnt_a + 1;
                end
            end else begin
                if (m_axis_a_tready && !fifo_a_empty) begin
                    fifo_a_rden <= 1;
                    if (fifo_a_last_out) begin
                         active_a <= 0;
                         cnt_a <= 0;
                    end
                end
            end
        end
    end

    // 通道 B 状态机
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            cnt_b <= 0;
            active_b <= 0;
            fifo_b_rden <= 0;
        end else begin
            fifo_b_rden <= 0;
            if (!active_b) begin
                if (!fifo_b_empty) begin
                    if (cnt_b >= delay_cycles_b) active_b <= 1;
                    else cnt_b <= cnt_b + 1;
                end
            end else begin
                if (m_axis_b_tready && !fifo_b_empty) begin
                    fifo_b_rden <= 1;
                    if (fifo_b_last_out) begin
                         active_b <= 0;
                         cnt_b <= 0;
                    end
                end
            end
        end
    end

    // =========================================================
    // 3. 输出赋值 (增加了数据掩码)
    // =========================================================
    
    // 如果 active_a 为 0 (延时中)，强制输出 0；否则输出 FIFO 数据
    assign m_axis_a_tdata  = active_a ? fifo_a_tdata_raw : 64'd0;
    assign m_axis_a_tvalid = active_a && (!fifo_a_empty);
    assign m_axis_a_tlast  = fifo_a_last_out;

    // 通道 B 同理
    assign m_axis_b_tdata  = active_b ? fifo_b_tdata_raw : 64'd0;
    assign m_axis_b_tvalid = active_b && (!fifo_b_empty);
    assign m_axis_b_tlast  = fifo_b_last_out;

endmodule