`timescale 1 ns/1 ps
    
module icmp 
#
(
  parameter   AXI_DWIDTH      = 8,
  parameter   KEEP_WIDTH      = (AXI_DWIDTH / 8)
)
(
    input   wire                    clk         ,
    input   wire                    rst         ,

    /*
     * IP frame input
     */
    input  wire                     s_ip_hdr_valid,
    output reg                      s_ip_hdr_ready,
    input  wire [47:0]              s_ip_eth_dest_mac,
    input  wire [47:0]              s_ip_eth_src_mac,
    input  wire [15:0]              s_ip_eth_type,
    input  wire [3:0]               s_ip_version,
    input  wire [3:0]               s_ip_ihl,
    input  wire [5:0]               s_ip_dscp,
    input  wire [1:0]               s_ip_ecn,
    input  wire [15:0]              s_ip_length,
    input  wire [15:0]              s_ip_identification,
    input  wire [2:0]               s_ip_flags,
    input  wire [12:0]              s_ip_fragment_offset,
    input  wire [7:0]               s_ip_ttl,
    input  wire [7:0]               s_ip_protocol,
    input  wire [15:0]              s_ip_header_checksum,
    input  wire [31:0]              s_ip_source_ip,
    input  wire [31:0]              s_ip_dest_ip,

    input  wire [AXI_DWIDTH-1:0]    s_ip_payload_axis_tdata,
    input  wire [KEEP_WIDTH-1:0]    s_ip_payload_axis_tkeep,
    input  wire                     s_ip_payload_axis_tvalid,
    output wire                     s_ip_payload_axis_tready,
    input  wire                     s_ip_payload_axis_tlast,
    input  wire                     s_ip_payload_axis_tuser,
    
    /*
     * IP frame output
     */
    output reg                      m_ip_hdr_valid,
    input  wire                     m_ip_hdr_ready,
    output reg  [47:0]              m_ip_eth_dest_mac,
    output reg  [47:0]              m_ip_eth_src_mac,
    output reg  [15:0]              m_ip_eth_type,
    output reg  [3:0]               m_ip_version,
    output reg  [3:0]               m_ip_ihl,
    output reg  [5:0]               m_ip_dscp,
    output reg  [1:0]               m_ip_ecn,
    output reg  [15:0]              m_ip_length,
    output reg  [15:0]              m_ip_identification,
    output reg  [2:0]               m_ip_flags,
    output reg  [12:0]              m_ip_fragment_offset,
    output reg  [7:0]               m_ip_ttl,
    output reg  [7:0]               m_ip_protocol,
    output reg  [15:0]              m_ip_header_checksum,
    output reg  [31:0]              m_ip_source_ip,
    output reg  [31:0]              m_ip_dest_ip,

    output wire [AXI_DWIDTH-1:0]    m_ip_payload_axis_tdata,
    output wire [KEEP_WIDTH-1:0]    m_ip_payload_axis_tkeep,
    output wire                     m_ip_payload_axis_tvalid,
    input  wire                     m_ip_payload_axis_tready,
    output wire                     m_ip_payload_axis_tlast,
    output wire                     m_ip_payload_axis_tuser,


    output wire 	                rx_busy,
    output wire                     tx_busy,

    output wire 	                rx_error_header_early_termination,
    output wire                     rx_error_payload_early_termination,
    output wire                     tx_error_payload_early_termination
    );

    localparam ICMP_BYTES             = 8;
    localparam HDR_BYTES            = ICMP_BYTES;


    reg flag_tx_ip;

    wire is_ip_valid;

    assign is_ip_valid = (s_ip_protocol == 8'd1) && (s_ip_payload_axis_tvalid);

    always  @(posedge clk)begin
        if(rst==1'b1)begin
            m_ip_eth_dest_mac       <= 48'd0;
            m_ip_eth_src_mac        <= 48'd0;
            m_ip_eth_type           <= 16'd0;
            m_ip_version            <= 4'd0;
            m_ip_ihl                <= 4'd0;
            m_ip_dscp               <= 6'd0;
            m_ip_ecn                <= 2'd0;
            m_ip_length             <= 16'd0;
            m_ip_identification     <= 16'd0;
            m_ip_flags              <= 3'd0;
            m_ip_fragment_offset    <= 13'd0;
            m_ip_ttl                <= 8'd0;
            m_ip_protocol           <= 8'd0;
            m_ip_header_checksum    <= 16'd0;
            m_ip_source_ip          <= 32'd0;
            m_ip_dest_ip            <= 32'd0;
        end
        else if(s_ip_hdr_valid && s_ip_hdr_ready)begin
            m_ip_eth_dest_mac       <= s_ip_eth_dest_mac;
            m_ip_eth_src_mac        <= s_ip_eth_src_mac;
            m_ip_eth_type           <= s_ip_eth_type;
            m_ip_version            <= s_ip_version;
            m_ip_ihl                <= s_ip_ihl;
            m_ip_dscp               <= s_ip_dscp;
            m_ip_ecn                <= s_ip_ecn;
            m_ip_length             <= s_ip_length;
            m_ip_identification     <= s_ip_identification;
            m_ip_flags              <= s_ip_flags;
            m_ip_fragment_offset    <= s_ip_fragment_offset;
            m_ip_ttl                <= s_ip_ttl;
            m_ip_protocol           <= s_ip_protocol;
            m_ip_header_checksum    <= s_ip_header_checksum;
            m_ip_source_ip          <= s_ip_dest_ip;
            m_ip_dest_ip            <= s_ip_source_ip;
        end
    end

    always  @(posedge clk)begin
        if(rst==1'b1)begin
            m_ip_hdr_valid <= 1'b0;
        end
        else if(m_ip_hdr_valid && m_ip_hdr_ready)begin
            m_ip_hdr_valid <= 1'b0;
        end
        else if(s_ip_hdr_valid && s_ip_hdr_ready)begin
            m_ip_hdr_valid <= 1'b1;
        end
    end

    always  @(posedge clk)begin
        if(rst==1'b1)begin
            flag_tx_ip <= 1'b0;
        end
        else if(m_ip_hdr_valid && m_ip_hdr_ready)begin
            flag_tx_ip <= 1'b1;
        end
        else if(m_ip_payload_axis_tvalid && m_ip_payload_axis_tlast && m_ip_payload_axis_tready)begin
            flag_tx_ip <= 1'b0;
        end
    end


    always  @(posedge clk)begin
        if(rst==1'b1)begin
            s_ip_hdr_ready <= 1'b1;
        end
        else if(s_ip_hdr_valid && s_ip_hdr_ready)begin
            s_ip_hdr_ready <= 1'b0;
        end
        else if(m_ip_payload_axis_tvalid && m_ip_payload_axis_tlast && m_ip_payload_axis_tready)begin
            s_ip_hdr_ready <= 1'b1;
        end
    end








    wire [(HDR_BYTES*8)-1:0] hdr;
    wire [7:0]               hdr_array [0:HDR_BYTES-1];
    wire                     hdr_valid;
    wire                     hdr_done;
    wire                     axis_rx_tready;

    axis_to_vec #(
        .AXI_DWIDTH         ( AXI_DWIDTH          ),
        .DATA_WIDTH         ( HDR_BYTES*8         )
    ) axis_to_ciaddr (
        .clk                ( clk                      ),
        .rst                ( rst                      ),
        .i_axis_rx_tvalid   ( s_ip_payload_axis_tvalid ),
        .i_axis_rx_tdata    ( s_ip_payload_axis_tdata  ),
        .i_axis_rx_tlast    ( s_ip_payload_axis_tlast  ),
        .i_axis_rx_tuser    ( s_ip_payload_axis_tuser  ),
        .i_axis_rx_tkeep    ( s_ip_payload_axis_tkeep  ),
        .o_axis_rx_tready   ( axis_rx_tready           ),
        .i_done             ( hdr_done                 ),
        .o_data             ( hdr                      ),
        .o_valid            ( hdr_valid                ),
        .o_byte_cnt         (                          )
    );

    assign hdr_done = (m_ip_payload_axis_tvalid && m_ip_payload_axis_tlast && m_ip_payload_axis_tready);

    genvar m;
    generate
        for (m=0; m<HDR_BYTES; m=m+1) begin
            assign hdr_array[m] = hdr[m*8+:8];
        end
    endgenerate



    wire [(HDR_BYTES*8)-1:0] hdr_out_array;
    reg  [16:0]              ping_chksum;

    assign hdr_out_array[00*8+:8]  = 8'h00; // Type: Echo Reply
    assign hdr_out_array[01*8+:8]  = hdr_array[01];
    assign hdr_out_array[02*8+:8]  = ping_chksum[15:08];
    assign hdr_out_array[03*8+:8]  = ping_chksum[07:00];
    assign hdr_out_array[04*8+:8]  = hdr_array[04];
    assign hdr_out_array[05*8+:8]  = hdr_array[05];
    assign hdr_out_array[06*8+:8]  = hdr_array[06];
    assign hdr_out_array[07*8+:8]  = hdr_array[07];

    always  @(*)begin
        ping_chksum = {hdr_array[2],hdr_array[3]} + 16'h0800;
        ping_chksum = ping_chksum[16] + ping_chksum[15:0];
    end


    




    wire                  hdr_axis_tvalid; 
    wire                  hdr_axis_tlast; 
    wire [AXI_DWIDTH-1:0] hdr_axis_tdata; 
    wire [KEEP_WIDTH-1:0] hdr_axis_tkeep; 
    wire                  hdr_axis_tuser; 
    wire                  hdr_axis_tready;

    vec_to_axis #(
        .AXI_DWIDTH       ( AXI_DWIDTH       ),
        .DATA_WIDTH       ( HDR_BYTES*8      )
    ) hdr_to_axis (
        .clk              ( clk              ),
        .rst              ( rst              ),
        .trigger          ( hdr_valid        ),
        .data             ( hdr_out_array    ),
        .is_busy          (                  ),
        .o_axis_tx_tvalid ( hdr_axis_tvalid  ),
        .o_axis_tx_tdata  ( hdr_axis_tdata   ),
        .o_axis_tx_tlast  ( hdr_axis_tlast   ),
        .o_axis_tx_tuser  ( hdr_axis_tuser   ),
        .o_axis_tx_tkeep  ( hdr_axis_tkeep   ),
        .i_axis_tx_tready ( hdr_axis_tready  )
    );


    reg hdr_active;

    //Raise packet active after the first tvalid following a tlast.
    always  @(posedge clk)begin
        if(rst==1'b1)begin
            hdr_active <= 1'b1;
        end
        else if(!hdr_active)begin
            hdr_active <= (s_ip_payload_axis_tlast && s_ip_payload_axis_tvalid && s_ip_payload_axis_tready);
        end
        else begin
            hdr_active <= !(hdr_axis_tlast && hdr_axis_tvalid && m_ip_payload_axis_tready && !s_ip_payload_axis_tlast);
        end
    end

    assign m_ip_payload_axis_tvalid = hdr_active ? hdr_axis_tvalid : s_ip_payload_axis_tvalid;
    assign m_ip_payload_axis_tlast = hdr_active ? (s_ip_payload_axis_tlast && hdr_axis_tlast)  : s_ip_payload_axis_tlast;
    assign m_ip_payload_axis_tuser = hdr_active ? hdr_axis_tuser : s_ip_payload_axis_tuser;
    assign m_ip_payload_axis_tdata = hdr_active ? hdr_axis_tdata : s_ip_payload_axis_tdata;
    assign m_ip_payload_axis_tkeep = hdr_active ? hdr_axis_tkeep : s_ip_payload_axis_tkeep;
    
    assign hdr_axis_tready = m_ip_payload_axis_tready && flag_tx_ip;

    assign s_ip_payload_axis_tready = hdr_active ? ((!hdr_valid && !s_ip_payload_axis_tlast) || (hdr_axis_tlast && s_ip_payload_axis_tlast))  : m_ip_payload_axis_tready;
    //assign s_ip_payload_axis_tready = hdr_active ? ((!hdr_valid && !s_ip_payload_axis_tlast) || (hdr_axis_tlast && s_ip_payload_axis_tlast))  : axis_rx_tready;

endmodule
