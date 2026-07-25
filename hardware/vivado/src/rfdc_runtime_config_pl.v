`timescale 1ns / 1ps

// Structured, PS-independent RFDC runtime configuration controller. All RFDC
// accesses are 16-bit AXI-Lite transactions followed by critical-register
// readback. The controller retains the last hardware-confirmed configuration
// so RFDC_GET_CONFIG survives host service restarts.
module rfdc_runtime_config_pl #(
    parameter integer CLOCK_HZ = 100000000,
    parameter integer AXI_TIMEOUT_CYCLES = 100000,
    parameter integer READY_PROBE_INTERVAL_CYCLES = CLOCK_HZ
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    input  wire [31:0]   cmd_sequence,
    input  wire [31:0]   cmd_revision,
    input  wire [7:0]    cmd_channel_mask,
    input  wire [511:0]  cmd_nco_hz,
    input  wire [15:0]   cmd_nyquist_zone,
    input  wire [255:0]  cmd_phase_mdeg,
    input  wire [255:0]  cmd_current_ua,
    input  wire          playback_armed,
    input  wire          playback_running,

    output reg           busy,
    output reg           done,
    output reg           force_mute_pulse,
    output reg  [15:0]   status,
    output reg  [31:0]   revision,
    output reg  [7:0]    applied_mask,
    output reg  [7:0]    error_mask,
    output reg  [7:0]    config_valid_mask,
    output reg  [31:0]   failure_stage,
    output reg  [17:0]   failure_address,
    output reg  [1:0]    failure_axi_response,
    output reg           rfdc_ready,
    output reg  [511:0]  actual_nco_hz,
    output reg  [15:0]   actual_nyquist_zone,
    output reg  [255:0]  actual_phase_mdeg,
    output reg  [255:0]  actual_current_ua,
    output reg  [255:0]  channel_status,
    output reg  [511:0]  actual_nco_word,
    output reg  [255:0]  actual_phase_word,
    output reg  [255:0]  actual_vop_code,

    output wire [17:0]   m_axil_awaddr,
    output wire          m_axil_awvalid,
    input  wire          m_axil_awready,
    output wire [31:0]   m_axil_wdata,
    output wire [3:0]    m_axil_wstrb,
    output wire          m_axil_wvalid,
    input  wire          m_axil_wready,
    input  wire [1:0]    m_axil_bresp,
    input  wire          m_axil_bvalid,
    output wire          m_axil_bready,
    output wire [17:0]   m_axil_araddr,
    output wire          m_axil_arvalid,
    input  wire          m_axil_arready,
    input  wire [31:0]   m_axil_rdata,
    input  wire [1:0]    m_axil_rresp,
    input  wire          m_axil_rvalid,
    output wire          m_axil_rready
);

  localparam [15:0] ST_OK             = 16'h0000;
  localparam [15:0] ST_BAD_REQUEST    = 16'h0003;
  localparam [15:0] ST_BUSY           = 16'h0004;
  localparam [15:0] ST_RFDC_NOT_READY = 16'h0005;
  localparam [15:0] ST_UNSAFE_STATE   = 16'h0006;
  localparam [15:0] ST_RANGE          = 16'h0007;
  localparam [15:0] ST_AXI_ERROR      = 16'h0008;
  localparam [15:0] ST_AXI_TIMEOUT    = 16'h0009;
  localparam [15:0] ST_READBACK       = 16'h000A;
  localparam [15:0] ST_PARTIAL        = 16'h000B;

  localparam [31:0] STAGE_VALIDATE = 32'd1;
  localparam [31:0] STAGE_READY    = 32'd2;
  localparam [31:0] STAGE_NYQUIST  = 32'd3;
  localparam [31:0] STAGE_NCO      = 32'd4;
  localparam [31:0] STAGE_PHASE    = 32'd5;
  localparam [31:0] STAGE_UPDATE   = 32'd6;
  localparam [31:0] STAGE_VOP      = 32'd7;
  localparam [31:0] STAGE_READBACK = 32'd8;

  localparam [17:0] OFF_CURRENT_STATE = 18'h0000C;
  localparam [17:0] OFF_UPDATE_DYN    = 18'h00020;
  localparam [17:0] OFF_NCO_UPDT      = 18'h0008C;
  localparam [17:0] OFF_NCO_UPPER     = 18'h00094;
  localparam [17:0] OFF_NCO_MIDDLE    = 18'h00098;
  localparam [17:0] OFF_NCO_LOWER     = 18'h0009C;
  localparam [17:0] OFF_PHASE_UPPER   = 18'h000A0;
  localparam [17:0] OFF_PHASE_LOWER   = 18'h000A4;
  localparam [17:0] OFF_VOP_CTRL      = 18'h00198;
  localparam [17:0] OFF_CFG0          = 18'h001C4;
  localparam [17:0] OFF_CFG2          = 18'h001CC;
  localparam [17:0] OFF_CFG3          = 18'h001D0;

  localparam [15:0] NYQUIST_MASK = 16'h0002;
  localparam [15:0] CFG0_CAS_BLDR_MASK = 16'hE000;
  localparam [15:0] CFG2_VOP_MASK = 16'hFFDF;
  localparam [15:0] CFG3_VOP_MASK = 16'hFFDF;
  localparam [15:0] CFG3_UPDATE_MASK = 16'h0020;
  localparam integer WAIT_1US_CYCLES =
      (CLOCK_HZ < 1000000) ? 1 : ((CLOCK_HZ + 999999) / 1000000);

  localparam [7:0] S_IDLE             = 8'd0;
  localparam [7:0] S_SELECT           = 8'd1;
  localparam [7:0] S_TILE_READ        = 8'd2;
  localparam [7:0] S_TILE_WAIT        = 8'd3;
  localparam [7:0] S_NYQ_READ         = 8'd4;
  localparam [7:0] S_NYQ_READ_WAIT    = 8'd5;
  localparam [7:0] S_NYQ_WRITE        = 8'd6;
  localparam [7:0] S_NYQ_WRITE_WAIT   = 8'd7;
  localparam [7:0] S_UPDMODE_READ     = 8'd8;
  localparam [7:0] S_UPDMODE_READ_WAIT= 8'd9;
  localparam [7:0] S_UPDMODE_WRITE    = 8'd10;
  localparam [7:0] S_UPDMODE_WRITE_WAIT=8'd11;
  localparam [7:0] S_NCO_LO_WRITE     = 8'd12;
  localparam [7:0] S_NCO_LO_WAIT      = 8'd13;
  localparam [7:0] S_NCO_MI_WRITE     = 8'd14;
  localparam [7:0] S_NCO_MI_WAIT      = 8'd15;
  localparam [7:0] S_NCO_HI_WRITE     = 8'd16;
  localparam [7:0] S_NCO_HI_WAIT      = 8'd17;
  localparam [7:0] S_PHASE_LO_WRITE   = 8'd18;
  localparam [7:0] S_PHASE_LO_WAIT    = 8'd19;
  localparam [7:0] S_PHASE_HI_WRITE   = 8'd20;
  localparam [7:0] S_PHASE_HI_WAIT    = 8'd21;
  localparam [7:0] S_DYN_WRITE        = 8'd22;
  localparam [7:0] S_DYN_WAIT         = 8'd23;
  localparam [7:0] S_VOP_CTRL_READ    = 8'd24;
  localparam [7:0] S_VOP_CTRL_READ_WAIT=8'd25;
  localparam [7:0] S_VOP_CTRL_WRITE   = 8'd26;
  localparam [7:0] S_VOP_CTRL_WRITE_WAIT=8'd27;
  localparam [7:0] S_VOP_INIT_READ    = 8'd28;
  localparam [7:0] S_VOP_INIT_WAIT    = 8'd29;
  localparam [7:0] S_VOP_PREP         = 8'd30;
  localparam [7:0] S_VOP_CFG0_READ    = 8'd31;
  localparam [7:0] S_VOP_CFG0_READ_WAIT=8'd32;
  localparam [7:0] S_VOP_CFG0_WRITE   = 8'd33;
  localparam [7:0] S_VOP_CFG0_WRITE_WAIT=8'd34;
  localparam [7:0] S_VOP_CFG2_READ    = 8'd35;
  localparam [7:0] S_VOP_CFG2_READ_WAIT=8'd36;
  localparam [7:0] S_VOP_CFG2_WRITE   = 8'd37;
  localparam [7:0] S_VOP_CFG2_WRITE_WAIT=8'd38;
  localparam [7:0] S_VOP_CFG3_READ    = 8'd39;
  localparam [7:0] S_VOP_CFG3_READ_WAIT=8'd40;
  localparam [7:0] S_VOP_CFG3_WRITE   = 8'd41;
  localparam [7:0] S_VOP_CFG3_WRITE_WAIT=8'd42;
  localparam [7:0] S_VOP_UPDATE_READ  = 8'd43;
  localparam [7:0] S_VOP_UPDATE_READ_WAIT=8'd44;
  localparam [7:0] S_VOP_UPDATE_WRITE = 8'd45;
  localparam [7:0] S_VOP_UPDATE_WRITE_WAIT=8'd46;
  localparam [7:0] S_VOP_DELAY        = 8'd47;
  localparam [7:0] S_RB_CFG0_READ     = 8'd48;
  localparam [7:0] S_RB_CFG0_WAIT     = 8'd49;
  localparam [7:0] S_RB_NCO_LO_READ   = 8'd50;
  localparam [7:0] S_RB_NCO_LO_WAIT   = 8'd51;
  localparam [7:0] S_RB_NCO_MI_READ   = 8'd52;
  localparam [7:0] S_RB_NCO_MI_WAIT   = 8'd53;
  localparam [7:0] S_RB_NCO_HI_READ   = 8'd54;
  localparam [7:0] S_RB_NCO_HI_WAIT   = 8'd55;
  localparam [7:0] S_RB_PHASE_LO_READ = 8'd56;
  localparam [7:0] S_RB_PHASE_LO_WAIT = 8'd57;
  localparam [7:0] S_RB_PHASE_HI_READ = 8'd58;
  localparam [7:0] S_RB_PHASE_HI_WAIT = 8'd59;
  localparam [7:0] S_RB_CFG2_READ     = 8'd60;
  localparam [7:0] S_RB_CFG2_WAIT     = 8'd61;
  localparam [7:0] S_RB_CFG3_READ     = 8'd62;
  localparam [7:0] S_RB_CFG3_WAIT     = 8'd63;
  localparam [7:0] S_CHANNEL_DONE     = 8'd64;
  localparam [7:0] S_FINISH           = 8'd65;
  localparam [7:0] S_DYN_COMMIT       = 8'd66;
  localparam [7:0] S_DYN_COMMIT_WAIT  = 8'd67;
  localparam [7:0] S_NCO_CALC_INIT    = 8'd68;
  localparam [7:0] S_NCO_CALC_STEP    = 8'd69;
  localparam [7:0] S_NCO_CALC_DONE    = 8'd70;
  localparam [7:0] S_PHASE_CALC_INIT  = 8'd71;
  localparam [7:0] S_PHASE_CALC_STEP  = 8'd72;
  localparam [7:0] S_PHASE_CALC_DONE  = 8'd73;
  localparam [7:0] S_RAMP_DIV_STEP    = 8'd74;
  localparam [7:0] S_RAMP_DIV_DONE    = 8'd75;
  localparam [7:0] S_VOP_QUANT_INIT   = 8'd76;
  localparam [7:0] S_VOP_QUANT_STEP   = 8'd77;
  localparam [7:0] S_VOP_QUANT_DONE   = 8'd78;
  localparam [7:0] S_READY_PROBE_READ = 8'd79;
  localparam [7:0] S_READY_PROBE_WAIT = 8'd80;

  reg [7:0] state;
  reg [2:0] channel_index;
  reg [7:0] request_mask;
  reg [31:0] request_sequence;
  reg [511:0] request_nco_hz;
  reg [15:0] request_zone;
  reg [255:0] request_phase;
  reg [255:0] request_current;
  reg [17:0] block_base;
  reg [17:0] tile_base;
  reg signed [63:0] selected_nco_hz;
  reg signed [31:0] selected_phase_mdeg;
  reg [31:0] selected_current_ua;
  reg [1:0] selected_zone;
  reg [47:0] expected_nco_word;
  reg [17:0] expected_phase_word;
  reg [15:0] rmw_value;
  reg [15:0] expected_cfg0;
  reg [15:0] expected_cfg2;
  reg [15:0] expected_cfg3;
  reg [31:0] ramp_current_ua;
  reg [31:0] ramp_next_ua;
  reg [15:0] vop_code;
  reg [5:0] vop_opt_index;
  reg [31:0] delay_count;
  reg [47:0] readback_nco_word;
  reg [17:0] readback_phase_word;
  reg [15:0] readback_cfg0;
  reg [15:0] readback_cfg2;
  reg [15:0] readback_cfg3;
  reg [31:0] cached_sequence;
  reg [31:0] cached_revision;
  reg cached_response_valid;
  reg vop_write_performed;
  reg [65:0] calc_dividend;
  reg [65:0] calc_quotient;
  reg [19:0] calc_remainder;
  reg [19:0] calc_divisor;
  reg [6:0] calc_iteration;
  reg calc_negative;
  reg ramp_up;
  reg vop_readback_only;
  reg [31:0] ready_probe_count;
  reg [1:0] ready_probe_tile;
  reg [3:0] ready_probe_mask;

  reg [7:0] validation_error_mask;
  integer vi;
  reg signed [63:0] validate_nco;
  reg [31:0] validate_current;
  reg [1:0] validate_zone;
  reg signed [31:0] validate_phase;
  always @* begin
    validation_error_mask = 8'd0;
    for (vi = 0; vi < 8; vi = vi + 1) begin
      validate_nco = cmd_nco_hz[vi*64 +: 64];
      validate_current = cmd_current_ua[vi*32 +: 32];
      validate_zone = cmd_nyquist_zone[vi*2 +: 2];
      validate_phase = cmd_phase_mdeg[vi*32 +: 32];
      if (cmd_channel_mask[vi]) begin
        if ((validate_nco < -64'sd3200000000) || (validate_nco > 64'sd3200000000) ||
            ((validate_zone != 2'd1) && (validate_zone != 2'd2)) ||
            (validate_phase < -32'sd180000) || (validate_phase >= 32'sd180000)) begin
          validation_error_mask[vi] = 1'b1;
        end
        if ((vi == 4) || (vi == 5)) begin
          if ((validate_current < 32'd6400) || (validate_current > 32'd32000))
            validation_error_mask[vi] = 1'b1;
        end else if ((validate_current < 32'd2250) || (validate_current > 32'd40500)) begin
          validation_error_mask[vi] = 1'b1;
        end
      end
    end
  end

  function [17:0] channel_block_base;
    input [2:0] channel;
    begin
      channel_block_base = 18'h06000 + ({15'd0, channel[2:1]} << 14) +
                           (channel[0] ? 18'h00800 : 18'h00000);
    end
  endfunction

  function [17:0] channel_tile_base;
    input [2:0] channel;
    begin
      channel_tile_base = 18'h04000 + ({15'd0, channel[2:1]} << 14);
    end
  endfunction

  function [17:0] tile_base_from_index;
    input [1:0] tile;
    begin
      tile_base_from_index = 18'h04000 + ({16'd0, tile} << 14);
    end
  endfunction

  reg [15:0] bldr_ac [0:63];
  reg [15:0] bldr_dc [0:63];
  reg [15:0] csc_bldr_ac [0:63];
  reg [15:0] csc_bldr_dc [0:63];
  reg [4:0] csc_bias_ac [0:63];
  reg [4:0] csc_bias_dc [0:63];
  integer li;
  initial begin
    bldr_ac[0]=22542; bldr_ac[1]=26637; bldr_ac[2]=27661; bldr_ac[3]=27661; bldr_ac[4]=28686; bldr_ac[5]=28686; bldr_ac[6]=29710; bldr_ac[7]=29711;
    bldr_ac[8]=30735; bldr_ac[9]=30735; bldr_ac[10]=31760; bldr_ac[11]=31760; bldr_ac[12]=32784; bldr_ac[13]=32785; bldr_ac[14]=33809; bldr_ac[15]=33809;
    bldr_ac[16]=34833; bldr_ac[17]=34833; bldr_ac[18]=35857; bldr_ac[19]=36881; bldr_ac[20]=37906; bldr_ac[21]=38930; bldr_ac[22]=38930; bldr_ac[23]=39954;
    bldr_ac[24]=40978; bldr_ac[25]=42003; bldr_ac[26]=43027; bldr_ac[27]=43027; bldr_ac[28]=44051; bldr_ac[29]=45075; bldr_ac[30]=46100; bldr_ac[31]=47124;
    bldr_ac[32]=48148; bldr_ac[33]=49172; bldr_ac[34]=50196; bldr_ac[35]=51220; bldr_ac[36]=52245; bldr_ac[37]=53269; bldr_ac[38]=53269; bldr_ac[39]=54293;
    bldr_ac[40]=55317; bldr_ac[41]=56342; bldr_ac[42]=57366; bldr_ac[43]=58390; bldr_ac[44]=58390; bldr_ac[45]=58390; bldr_ac[46]=59415; bldr_ac[47]=59415;
    bldr_ac[48]=59415; bldr_ac[49]=59415; bldr_ac[50]=60439; bldr_ac[51]=60439; bldr_ac[52]=60439; bldr_ac[53]=60439; bldr_ac[54]=60439; bldr_ac[55]=60440;
    bldr_ac[56]=62489; bldr_ac[57]=62489; bldr_ac[58]=63514; bldr_ac[59]=63514; bldr_ac[60]=63514; bldr_ac[61]=64539; bldr_ac[62]=64539; bldr_ac[63]=64539;
    for (li=0; li<64; li=li+1) begin
      bldr_dc[li] = 16'd0;
      csc_bldr_ac[li] = (li < 16) ? 16'hC000 : (li < 32) ? 16'hA000 : (li < 48) ? 16'h8000 : 16'h6000;
      csc_bldr_dc[li] = 16'd0;
      csc_bias_ac[li] = 5'd0;
      csc_bias_dc[li] = 5'd0;
    end
    bldr_dc[7]=21526; bldr_dc[8]=22550; bldr_dc[9]=23574; bldr_dc[10]=24598; bldr_dc[11]=25622; bldr_dc[12]=26646; bldr_dc[13]=27670; bldr_dc[14]=28694; bldr_dc[15]=29718;
    for (li=16; li<=43; li=li+1) bldr_dc[li] = 16'd30742 + ((li-16)*16'd1024);
    for (li=7; li<16; li=li+1) csc_bldr_dc[li]=16'hC000;
    for (li=16; li<24; li=li+1) csc_bldr_dc[li]=16'hA000;
    for (li=24; li<32; li=li+1) csc_bldr_dc[li]=16'h8000;
    for (li=32; li<40; li=li+1) csc_bldr_dc[li]=16'h6000;
    for (li=40; li<44; li=li+1) csc_bldr_dc[li]=16'h4000;
    csc_bias_ac[6]=1; csc_bias_ac[7]=1; csc_bias_ac[8]=1; csc_bias_ac[9]=1; csc_bias_ac[10]=1; csc_bias_ac[11]=1;
    csc_bias_ac[12]=2; csc_bias_ac[13]=2; csc_bias_ac[14]=2; csc_bias_ac[15]=2; csc_bias_ac[16]=2; csc_bias_ac[17]=2;
    csc_bias_ac[18]=3; csc_bias_ac[19]=3; csc_bias_ac[20]=3; csc_bias_ac[21]=3;
    csc_bias_ac[22]=5; csc_bias_ac[23]=5; csc_bias_ac[24]=5; csc_bias_ac[25]=5; csc_bias_ac[26]=5; csc_bias_ac[27]=5;
    csc_bias_ac[28]=6; csc_bias_ac[29]=7; csc_bias_ac[30]=8; csc_bias_ac[31]=9; csc_bias_ac[32]=10; csc_bias_ac[33]=11; csc_bias_ac[34]=11;
    csc_bias_ac[35]=12; csc_bias_ac[36]=12; csc_bias_ac[37]=13; csc_bias_ac[38]=13;
    csc_bias_ac[39]=14; csc_bias_ac[40]=14; csc_bias_ac[41]=15; csc_bias_ac[42]=15;
    csc_bias_ac[43]=16; csc_bias_ac[44]=16; csc_bias_ac[45]=17; csc_bias_ac[46]=18;
    csc_bias_ac[47]=19; csc_bias_ac[48]=20; csc_bias_ac[49]=21; csc_bias_ac[50]=22;
    csc_bias_ac[51]=23; csc_bias_ac[52]=24; csc_bias_ac[53]=25; csc_bias_ac[54]=26;
    csc_bias_ac[55]=27; csc_bias_ac[56]=28; csc_bias_ac[57]=29; csc_bias_ac[58]=30; csc_bias_ac[59]=31;
    csc_bias_ac[60]=31; csc_bias_ac[61]=31; csc_bias_ac[62]=31; csc_bias_ac[63]=31;
    for (li=0; li<44; li=li+1) csc_bias_dc[li]=csc_bias_ac[li];
  end

  reg axi_start;
  reg axi_write;
  reg [17:0] axi_address;
  reg [31:0] axi_write_data;
  reg [3:0] axi_write_strobe;
  wire axi_busy;
  wire axi_done;
  wire [2:0] axi_error;
  wire [1:0] axi_response;
  wire [31:0] axi_read_data;

  rfdc_axil_transaction #(
      .ADDR_WIDTH(18),
      .TIMEOUT_CYCLES(AXI_TIMEOUT_CYCLES)
  ) transaction_i (
      .clk(clk), .rst_n(rst_n), .start(axi_start), .write_not_read(axi_write),
      .address(axi_address), .write_data(axi_write_data), .write_strobe(axi_write_strobe),
      .busy(axi_busy), .done(axi_done), .error(axi_error), .response(axi_response),
      .read_data(axi_read_data),
      .m_awaddr(m_axil_awaddr), .m_awvalid(m_axil_awvalid), .m_awready(m_axil_awready),
      .m_wdata(m_axil_wdata), .m_wstrb(m_axil_wstrb), .m_wvalid(m_axil_wvalid), .m_wready(m_axil_wready),
      .m_bresp(m_axil_bresp), .m_bvalid(m_axil_bvalid), .m_bready(m_axil_bready),
      .m_araddr(m_axil_araddr), .m_arvalid(m_axil_arvalid), .m_arready(m_axil_arready),
      .m_rdata(m_axil_rdata), .m_rresp(m_axil_rresp), .m_rvalid(m_axil_rvalid), .m_rready(m_axil_rready)
  );

  task launch_read;
    input [17:0] address;
    begin
      axi_address <= address;
      axi_write <= 1'b0;
      axi_write_data <= 32'd0;
      axi_write_strobe <= 4'b0011;
      axi_start <= 1'b1;
    end
  endtask

  task launch_write16;
    input [17:0] address;
    input [15:0] value;
    begin
      axi_address <= address;
      axi_write <= 1'b1;
      axi_write_data <= {16'd0, value};
      axi_write_strobe <= 4'b0011;
      axi_start <= 1'b1;
    end
  endtask

  task fail_transaction;
    input [31:0] stage_value;
    begin
      failure_stage <= stage_value;
      failure_address <= axi_address;
      failure_axi_response <= axi_response;
      error_mask <= request_mask & ~applied_mask;
      channel_status[channel_index*32 +: 32] <= (axi_error == 3'd3) ? ST_AXI_TIMEOUT : ST_AXI_ERROR;
      status <= (applied_mask != 0) ? ST_PARTIAL : ((axi_error == 3'd3) ? ST_AXI_TIMEOUT : ST_AXI_ERROR);
      force_mute_pulse <= 1'b1;
      state <= S_FINISH;
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; done <= 1'b0; force_mute_pulse <= 1'b0; status <= ST_OK;
      revision <= 32'd0; applied_mask <= 8'd0; error_mask <= 8'd0; config_valid_mask <= 8'd0;
      failure_stage <= 32'd0; failure_address <= 18'd0; failure_axi_response <= 2'd0;
      rfdc_ready <= 1'b0; actual_nco_hz <= 512'd0; actual_nyquist_zone <= 16'd0;
      actual_phase_mdeg <= 256'd0; actual_current_ua <= 256'd0; channel_status <= 256'd0;
      actual_nco_word <= 512'd0; actual_phase_word <= 256'd0; actual_vop_code <= 256'd0;
      state <= S_IDLE; channel_index <= 3'd0; request_mask <= 8'd0; request_sequence <= 32'd0;
      request_nco_hz <= 512'd0; request_zone <= 16'd0; request_phase <= 256'd0; request_current <= 256'd0;
      block_base <= 18'd0; tile_base <= 18'd0; selected_nco_hz <= 64'sd0;
      selected_phase_mdeg <= 32'sd0; selected_current_ua <= 32'd0; selected_zone <= 2'd1;
      expected_nco_word <= 48'd0; expected_phase_word <= 18'd0; rmw_value <= 16'd0;
      expected_cfg0 <= 16'd0; expected_cfg2 <= 16'd0; expected_cfg3 <= 16'd0;
      ramp_current_ua <= 32'd0; ramp_next_ua <= 32'd0; vop_code <= 16'd0; vop_opt_index <= 6'd0;
      delay_count <= 32'd0; readback_nco_word <= 48'd0; readback_phase_word <= 18'd0;
      readback_cfg0 <= 16'd0; readback_cfg2 <= 16'd0; readback_cfg3 <= 16'd0;
      cached_sequence <= 32'd0; cached_revision <= 32'd0; cached_response_valid <= 1'b0;
      vop_write_performed <= 1'b0;
      calc_dividend <= 66'd0; calc_quotient <= 66'd0; calc_remainder <= 20'd0;
      calc_divisor <= 20'd0; calc_iteration <= 7'd0; calc_negative <= 1'b0;
      ramp_up <= 1'b0; vop_readback_only <= 1'b0;
      ready_probe_count <= READY_PROBE_INTERVAL_CYCLES - 1;
      ready_probe_tile <= 2'd0; ready_probe_mask <= 4'd0;
      axi_start <= 1'b0; axi_write <= 1'b0; axi_address <= 18'd0;
      axi_write_data <= 32'd0; axi_write_strobe <= 4'b0011;
    end else begin
      done <= 1'b0;
      force_mute_pulse <= 1'b0;
      axi_start <= 1'b0;

      case (state)
        S_IDLE: begin
          busy <= 1'b0;
          if (start) begin
            ready_probe_count <= READY_PROBE_INTERVAL_CYCLES - 1;
            if (cached_response_valid && (cmd_sequence == cached_sequence) && (cmd_revision == cached_revision)) begin
              done <= 1'b1;
            end else if (cmd_channel_mask == 8'd0) begin
              status <= ST_BAD_REQUEST; error_mask <= 8'd0; failure_stage <= STAGE_VALIDATE;
              revision <= cmd_revision; done <= 1'b1; cached_response_valid <= 1'b0;
            end else if (playback_armed || playback_running) begin
              status <= ST_UNSAFE_STATE; error_mask <= cmd_channel_mask; failure_stage <= STAGE_VALIDATE;
              revision <= cmd_revision; force_mute_pulse <= 1'b1; done <= 1'b1; cached_response_valid <= 1'b0;
            end else if (validation_error_mask != 8'd0) begin
              status <= ST_RANGE; error_mask <= validation_error_mask; failure_stage <= STAGE_VALIDATE;
              revision <= cmd_revision; force_mute_pulse <= 1'b1; done <= 1'b1; cached_response_valid <= 1'b0;
            end else begin
              busy <= 1'b1; status <= ST_OK; revision <= cmd_revision;
              applied_mask <= 8'd0; error_mask <= 8'd0; failure_stage <= 32'd0;
              failure_address <= 18'd0; failure_axi_response <= 2'd0;
              request_mask <= cmd_channel_mask; request_sequence <= cmd_sequence;
              request_nco_hz <= cmd_nco_hz; request_zone <= cmd_nyquist_zone;
              request_phase <= cmd_phase_mdeg; request_current <= cmd_current_ua;
              config_valid_mask <= config_valid_mask & ~cmd_channel_mask;
              channel_status <= 256'd0; channel_index <= 3'd0;
              force_mute_pulse <= 1'b1; state <= S_SELECT;
            end
          end else if (ready_probe_count == 0) begin
            // RFDC startup is performed once by the PS. Probe all four DAC
            // tiles from PL so STATUS reflects hardware without requiring a
            // parameter write first.
            busy <= 1'b1;
            ready_probe_tile <= 2'd0;
            ready_probe_mask <= 4'd0;
            ready_probe_count <= READY_PROBE_INTERVAL_CYCLES - 1;
            state <= S_READY_PROBE_READ;
          end else begin
            ready_probe_count <= ready_probe_count - 1'b1;
          end
        end

        S_READY_PROBE_READ: begin
          launch_read(tile_base_from_index(ready_probe_tile) + OFF_CURRENT_STATE);
          state <= S_READY_PROBE_WAIT;
        end
        S_READY_PROBE_WAIT: if (axi_done) begin
          ready_probe_mask[ready_probe_tile] <=
              (axi_error == 0) && (axi_read_data[3:0] == 4'hF);
          if (ready_probe_tile == 2'd3) begin
            rfdc_ready <= (ready_probe_mask[2:0] == 3'b111) &&
                          (axi_error == 0) && (axi_read_data[3:0] == 4'hF);
            busy <= 1'b0;
            state <= S_IDLE;
          end else begin
            ready_probe_tile <= ready_probe_tile + 1'b1;
            state <= S_READY_PROBE_READ;
          end
        end

        S_SELECT: begin
          if (!request_mask[channel_index]) begin
            if (channel_index == 3'd7) state <= S_FINISH;
            else channel_index <= channel_index + 3'd1;
          end else begin
            block_base <= channel_block_base(channel_index);
            tile_base <= channel_tile_base(channel_index);
            selected_nco_hz <= request_nco_hz[channel_index*64 +: 64];
            selected_zone <= request_zone[channel_index*2 +: 2];
            selected_phase_mdeg <= request_phase[channel_index*32 +: 32];
            selected_current_ua <= request_current[channel_index*32 +: 32];
            vop_write_performed <= 1'b0;
            state <= S_NCO_CALC_INIT;
          end
        end

        // 2^48 / 6.4e9 reduces exactly to 2^34 / 390625. A restoring
        // divider keeps this conversion off the 300 MHz combinational path.
        S_NCO_CALC_INIT: begin
          calc_negative <= selected_nco_hz[63];
          calc_dividend <= selected_nco_hz[63]
              ? {((~selected_nco_hz[31:0]) + 32'd1), 34'd0}
              : {selected_nco_hz[31:0], 34'd0};
          calc_quotient <= 66'd0;
          calc_remainder <= 20'd0;
          calc_divisor <= 20'd390625;
          calc_iteration <= 7'd65;
          state <= S_NCO_CALC_STEP;
        end
        S_NCO_CALC_STEP: begin
          calc_dividend <= {calc_dividend[64:0], 1'b0};
          if ({calc_remainder[18:0], calc_dividend[65]} >= calc_divisor) begin
            calc_remainder <= {calc_remainder[18:0], calc_dividend[65]} - calc_divisor;
            calc_quotient <= {calc_quotient[64:0], 1'b1};
          end else begin
            calc_remainder <= {calc_remainder[18:0], calc_dividend[65]};
            calc_quotient <= {calc_quotient[64:0], 1'b0};
          end
          if (calc_iteration == 0)
            state <= S_NCO_CALC_DONE;
          else
            calc_iteration <= calc_iteration - 1'b1;
        end
        S_NCO_CALC_DONE: begin
          expected_nco_word <= calc_negative
              ? ((~calc_quotient[47:0]) + 48'd1)
              : calc_quotient[47:0];
          state <= S_PHASE_CALC_INIT;
        end

        // 2^17 / 180000 reduces exactly to 2^12 / 5625.
        S_PHASE_CALC_INIT: begin
          calc_negative <= selected_phase_mdeg[31];
          calc_dividend <= selected_phase_mdeg[31]
              ? {((~selected_phase_mdeg[17:0]) + 18'd1), 12'd0, 36'd0}
              : {selected_phase_mdeg[17:0], 12'd0, 36'd0};
          calc_quotient <= 66'd0;
          calc_remainder <= 20'd0;
          calc_divisor <= 20'd5625;
          calc_iteration <= 7'd29;
          state <= S_PHASE_CALC_STEP;
        end
        S_PHASE_CALC_STEP: begin
          calc_dividend <= {calc_dividend[64:0], 1'b0};
          if ({calc_remainder[18:0], calc_dividend[65]} >= calc_divisor) begin
            calc_remainder <= {calc_remainder[18:0], calc_dividend[65]} - calc_divisor;
            calc_quotient <= {calc_quotient[64:0], 1'b1};
          end else begin
            calc_remainder <= {calc_remainder[18:0], calc_dividend[65]};
            calc_quotient <= {calc_quotient[64:0], 1'b0};
          end
          if (calc_iteration == 0)
            state <= S_PHASE_CALC_DONE;
          else
            calc_iteration <= calc_iteration - 1'b1;
        end
        S_PHASE_CALC_DONE: begin
          expected_phase_word <= calc_negative
              ? ((~calc_quotient[17:0]) + 18'd1)
              : calc_quotient[17:0];
          state <= S_TILE_READ;
        end

        S_TILE_READ: begin launch_read(tile_base + OFF_CURRENT_STATE); state <= S_TILE_WAIT; end
        S_TILE_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_READY);
          else if ((axi_read_data[3:0] != 4'hF)) begin
            status <= (applied_mask != 0) ? ST_PARTIAL : ST_RFDC_NOT_READY;
            error_mask <= request_mask & ~applied_mask; failure_stage <= STAGE_READY;
            failure_address <= axi_address;
            ready_probe_mask[channel_index[2:1]] <= 1'b0;
            rfdc_ready <= 1'b0; force_mute_pulse <= 1'b1; state <= S_FINISH;
          end else begin
            ready_probe_mask[channel_index[2:1]] <= 1'b1;
            if ((ready_probe_mask | (4'b0001 << channel_index[2:1])) == 4'hF)
              rfdc_ready <= 1'b1;
            state <= S_NYQ_READ;
          end
        end
        S_NYQ_READ: begin launch_read(block_base + OFF_CFG0); state <= S_NYQ_READ_WAIT; end
        S_NYQ_READ_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_NYQUIST);
          else begin rmw_value <= (selected_zone == 2) ? (axi_read_data[15:0] | NYQUIST_MASK) : (axi_read_data[15:0] & ~NYQUIST_MASK); state <= S_NYQ_WRITE; end
        end
        S_NYQ_WRITE: begin launch_write16(block_base + OFF_CFG0, rmw_value); state <= S_NYQ_WRITE_WAIT; end
        S_NYQ_WRITE_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_NYQUIST); else state <= S_UPDMODE_READ; end
        S_UPDMODE_READ: begin launch_read(block_base + OFF_NCO_UPDT); state <= S_UPDMODE_READ_WAIT; end
        S_UPDMODE_READ_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_NCO); else begin rmw_value <= axi_read_data[15:0] & 16'hFFF8; state <= S_UPDMODE_WRITE; end
        end
        S_UPDMODE_WRITE: begin launch_write16(block_base + OFF_NCO_UPDT, rmw_value); state <= S_UPDMODE_WRITE_WAIT; end
        S_UPDMODE_WRITE_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_NCO); else state <= S_NCO_LO_WRITE; end
        S_NCO_LO_WRITE: begin launch_write16(block_base + OFF_NCO_LOWER, expected_nco_word[15:0]); state <= S_NCO_LO_WAIT; end
        S_NCO_LO_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_NCO); else state <= S_NCO_MI_WRITE; end
        S_NCO_MI_WRITE: begin launch_write16(block_base + OFF_NCO_MIDDLE, expected_nco_word[31:16]); state <= S_NCO_MI_WAIT; end
        S_NCO_MI_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_NCO); else state <= S_NCO_HI_WRITE; end
        S_NCO_HI_WRITE: begin launch_write16(block_base + OFF_NCO_UPPER, expected_nco_word[47:32]); state <= S_NCO_HI_WAIT; end
        S_NCO_HI_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_NCO); else state <= S_PHASE_LO_WRITE; end
        S_PHASE_LO_WRITE: begin launch_write16(block_base + OFF_PHASE_LOWER, expected_phase_word[15:0]); state <= S_PHASE_LO_WAIT; end
        S_PHASE_LO_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_PHASE); else state <= S_PHASE_HI_WRITE; end
        S_PHASE_HI_WRITE: begin launch_write16(block_base + OFF_PHASE_UPPER, {14'd0, expected_phase_word[17:16]}); state <= S_PHASE_HI_WAIT; end
        S_PHASE_HI_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_PHASE); else state <= S_DYN_WRITE; end
        S_DYN_WRITE: begin launch_read(block_base + OFF_UPDATE_DYN); state <= S_DYN_WAIT; end
        S_DYN_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_UPDATE);
          else begin rmw_value <= (axi_read_data[15:0] & 16'hFFF0) | 16'h0002; state <= S_DYN_COMMIT; end
        end
        S_DYN_COMMIT: begin launch_write16(block_base + OFF_UPDATE_DYN, rmw_value); state <= S_DYN_COMMIT_WAIT; end
        S_DYN_COMMIT_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_UPDATE); else state <= S_VOP_CTRL_READ; end

        S_VOP_CTRL_READ: begin launch_read(block_base + OFF_VOP_CTRL); state <= S_VOP_CTRL_READ_WAIT; end
        S_VOP_CTRL_READ_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_VOP); else begin rmw_value <= axi_read_data[15:0] & 16'hFFFC; state <= S_VOP_CTRL_WRITE; end
        end
        S_VOP_CTRL_WRITE: begin launch_write16(block_base + OFF_VOP_CTRL, rmw_value); state <= S_VOP_CTRL_WRITE_WAIT; end
        S_VOP_CTRL_WRITE_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_VOP); else state <= S_VOP_INIT_READ; end
        S_VOP_INIT_READ: begin launch_read(block_base + OFF_CFG3); state <= S_VOP_INIT_WAIT; end
        S_VOP_INIT_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_VOP);
          else begin ramp_current_ua <= 32'd1400 + ((axi_read_data[15:6] * 32'd175) >> 2); state <= S_VOP_PREP; end
        end
        S_VOP_PREP: begin
          if (ramp_current_ua == selected_current_ua) begin
            vop_readback_only <= 1'b1;
            state <= S_VOP_QUANT_INIT;
          end else begin
            ramp_up <= ramp_current_ua < selected_current_ua;
            vop_readback_only <= 1'b0;
            calc_dividend <= {ramp_current_ua[15:0], 50'd0};
            calc_quotient <= 66'd0;
            calc_remainder <= 20'd0;
            calc_divisor <= 20'd10;
            calc_iteration <= 7'd15;
            state <= S_RAMP_DIV_STEP;
          end
        end
        S_RAMP_DIV_STEP: begin
          calc_dividend <= {calc_dividend[64:0], 1'b0};
          if ({calc_remainder[18:0], calc_dividend[65]} >= calc_divisor) begin
            calc_remainder <= {calc_remainder[18:0], calc_dividend[65]} - calc_divisor;
            calc_quotient <= {calc_quotient[64:0], 1'b1};
          end else begin
            calc_remainder <= {calc_remainder[18:0], calc_dividend[65]};
            calc_quotient <= {calc_quotient[64:0], 1'b0};
          end
          if (calc_iteration == 0)
            state <= S_RAMP_DIV_DONE;
          else
            calc_iteration <= calc_iteration - 1'b1;
        end
        S_RAMP_DIV_DONE: begin
          if (ramp_up) begin
            if ((ramp_current_ua + calc_quotient[15:0]) > selected_current_ua)
              ramp_next_ua <= selected_current_ua;
            else
              ramp_next_ua <= ramp_current_ua + calc_quotient[15:0];
          end else begin
            if ((ramp_current_ua - calc_quotient[15:0]) < selected_current_ua)
              ramp_next_ua <= selected_current_ua;
            else
              ramp_next_ua <= ramp_current_ua - calc_quotient[15:0];
          end
          state <= S_VOP_QUANT_INIT;
        end
        S_VOP_QUANT_INIT: begin
          calc_dividend <= vop_readback_only
              ? {(selected_current_ua[15:0] - 16'd1400), 2'd0, 48'd0}
              : {(ramp_next_ua[15:0] - 16'd1400), 2'd0, 48'd0};
          calc_quotient <= 66'd0;
          calc_remainder <= 20'd0;
          calc_divisor <= 20'd175;
          calc_iteration <= 7'd17;
          state <= S_VOP_QUANT_STEP;
        end
        S_VOP_QUANT_STEP: begin
          calc_dividend <= {calc_dividend[64:0], 1'b0};
          if ({calc_remainder[18:0], calc_dividend[65]} >= calc_divisor) begin
            calc_remainder <= {calc_remainder[18:0], calc_dividend[65]} - calc_divisor;
            calc_quotient <= {calc_quotient[64:0], 1'b1};
          end else begin
            calc_remainder <= {calc_remainder[18:0], calc_dividend[65]};
            calc_quotient <= {calc_quotient[64:0], 1'b0};
          end
          if (calc_iteration == 0)
            state <= S_VOP_QUANT_DONE;
          else
            calc_iteration <= calc_iteration - 1'b1;
        end
        S_VOP_QUANT_DONE: begin
          vop_code <= calc_quotient[15:0];
          vop_opt_index <= calc_quotient[9:4];
          state <= vop_readback_only ? S_RB_CFG0_READ : S_VOP_CFG0_READ;
        end
        S_VOP_CFG0_READ: begin
          vop_write_performed <= 1'b1;
          launch_read(block_base + OFF_CFG0); state <= S_VOP_CFG0_READ_WAIT;
        end
        S_VOP_CFG0_READ_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_VOP);
          else begin expected_cfg0 <= (axi_read_data[15:0] & ~CFG0_CAS_BLDR_MASK) | ((channel_index==4 || channel_index==5) ? csc_bldr_dc[vop_opt_index] : csc_bldr_ac[vop_opt_index]); state <= S_VOP_CFG0_WRITE; end
        end
        S_VOP_CFG0_WRITE: begin launch_write16(block_base + OFF_CFG0, expected_cfg0); state <= S_VOP_CFG0_WRITE_WAIT; end
        S_VOP_CFG0_WRITE_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_VOP); else state <= S_VOP_CFG2_READ; end
        S_VOP_CFG2_READ: begin launch_read(block_base + OFF_CFG2); state <= S_VOP_CFG2_READ_WAIT; end
        S_VOP_CFG2_READ_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_VOP);
          else begin expected_cfg2 <= (axi_read_data[15:0] & ~CFG2_VOP_MASK) | ((channel_index==4 || channel_index==5) ? bldr_dc[vop_opt_index] : bldr_ac[vop_opt_index]) | ((vop_code & 16'h000F) << 6); state <= S_VOP_CFG2_WRITE; end
        end
        S_VOP_CFG2_WRITE: begin launch_write16(block_base + OFF_CFG2, expected_cfg2); state <= S_VOP_CFG2_WRITE_WAIT; end
        S_VOP_CFG2_WRITE_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_VOP); else state <= S_VOP_CFG3_READ; end
        S_VOP_CFG3_READ: begin launch_read(block_base + OFF_CFG3); state <= S_VOP_CFG3_READ_WAIT; end
        S_VOP_CFG3_READ_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_VOP);
          else begin expected_cfg3 <= (axi_read_data[15:0] & ~CFG3_VOP_MASK) | (vop_code << 6) | ((channel_index==4 || channel_index==5) ? csc_bias_dc[vop_opt_index] : csc_bias_ac[vop_opt_index]); state <= S_VOP_CFG3_WRITE; end
        end
        S_VOP_CFG3_WRITE: begin launch_write16(block_base + OFF_CFG3, expected_cfg3); state <= S_VOP_CFG3_WRITE_WAIT; end
        S_VOP_CFG3_WRITE_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_VOP); else state <= S_VOP_UPDATE_READ; end
        S_VOP_UPDATE_READ: begin launch_read(block_base + OFF_CFG3); state <= S_VOP_UPDATE_READ_WAIT; end
        S_VOP_UPDATE_READ_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_VOP); else begin rmw_value <= axi_read_data[15:0] | CFG3_UPDATE_MASK; state <= S_VOP_UPDATE_WRITE; end
        end
        S_VOP_UPDATE_WRITE: begin launch_write16(block_base + OFF_CFG3, rmw_value); state <= S_VOP_UPDATE_WRITE_WAIT; end
        S_VOP_UPDATE_WRITE_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_VOP); else begin delay_count <= WAIT_1US_CYCLES; state <= S_VOP_DELAY; end
        end
        S_VOP_DELAY: begin
          if (delay_count == 0) begin ramp_current_ua <= ramp_next_ua; state <= S_VOP_PREP; end
          else delay_count <= delay_count - 1;
        end

        S_RB_CFG0_READ: begin launch_read(block_base + OFF_CFG0); state <= S_RB_CFG0_WAIT; end
        S_RB_CFG0_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_READBACK);
          else begin readback_cfg0 <= axi_read_data[15:0]; state <= S_RB_NCO_LO_READ; end
        end
        S_RB_NCO_LO_READ: begin launch_read(block_base + OFF_NCO_LOWER); state <= S_RB_NCO_LO_WAIT; end
        S_RB_NCO_LO_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_READBACK); else begin readback_nco_word[15:0] <= axi_read_data[15:0]; state <= S_RB_NCO_MI_READ; end end
        S_RB_NCO_MI_READ: begin launch_read(block_base + OFF_NCO_MIDDLE); state <= S_RB_NCO_MI_WAIT; end
        S_RB_NCO_MI_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_READBACK); else begin readback_nco_word[31:16] <= axi_read_data[15:0]; state <= S_RB_NCO_HI_READ; end end
        S_RB_NCO_HI_READ: begin launch_read(block_base + OFF_NCO_UPPER); state <= S_RB_NCO_HI_WAIT; end
        S_RB_NCO_HI_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_READBACK); else begin readback_nco_word[47:32] <= axi_read_data[15:0]; state <= S_RB_PHASE_LO_READ; end end
        S_RB_PHASE_LO_READ: begin launch_read(block_base + OFF_PHASE_LOWER); state <= S_RB_PHASE_LO_WAIT; end
        S_RB_PHASE_LO_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_READBACK); else begin readback_phase_word[15:0] <= axi_read_data[15:0]; state <= S_RB_PHASE_HI_READ; end end
        S_RB_PHASE_HI_READ: begin launch_read(block_base + OFF_PHASE_UPPER); state <= S_RB_PHASE_HI_WAIT; end
        S_RB_PHASE_HI_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_READBACK); else begin readback_phase_word[17:16] <= axi_read_data[1:0]; state <= S_RB_CFG2_READ; end end
        S_RB_CFG2_READ: begin launch_read(block_base + OFF_CFG2); state <= S_RB_CFG2_WAIT; end
        S_RB_CFG2_WAIT: if (axi_done) begin if (axi_error != 0) fail_transaction(STAGE_READBACK); else begin readback_cfg2 <= axi_read_data[15:0]; state <= S_RB_CFG3_READ; end end
        S_RB_CFG3_READ: begin launch_read(block_base + OFF_CFG3); state <= S_RB_CFG3_WAIT; end
        S_RB_CFG3_WAIT: if (axi_done) begin
          if (axi_error != 0) fail_transaction(STAGE_READBACK);
          else begin
            readback_cfg3 <= axi_read_data[15:0];
            if ((((readback_cfg0 & NYQUIST_MASK) != ((selected_zone == 2) ? NYQUIST_MASK : 16'd0))) ||
                (readback_nco_word != expected_nco_word) || (readback_phase_word != expected_phase_word) ||
                (vop_write_performed &&
                 (((readback_cfg2 & CFG2_VOP_MASK) != (expected_cfg2 & CFG2_VOP_MASK)) ||
                  ((axi_read_data[15:0] & CFG3_VOP_MASK) != (expected_cfg3 & CFG3_VOP_MASK))))) begin
              status <= (applied_mask != 0) ? ST_PARTIAL : ST_READBACK;
              error_mask <= request_mask & ~applied_mask; failure_stage <= STAGE_READBACK;
              failure_address <= axi_address; force_mute_pulse <= 1'b1; state <= S_FINISH;
            end else state <= S_CHANNEL_DONE;
          end
        end

        S_CHANNEL_DONE: begin
          applied_mask[channel_index] <= 1'b1;
          config_valid_mask[channel_index] <= 1'b1;
          actual_nco_word[channel_index*64 +: 64] <= {16'd0, readback_nco_word};
          // The raw readback word is the authoritative quantized value. Keep
          // integer display units at the confirmed request value; software can
          // derive sub-Hz precision from actual_nco_word without a 300 MHz DSP chain.
          actual_nco_hz[channel_index*64 +: 64] <= selected_nco_hz;
          actual_nyquist_zone[channel_index*2 +: 2] <= (readback_cfg0 & NYQUIST_MASK) ? 2'd2 : 2'd1;
          actual_phase_word[channel_index*32 +: 32] <= {14'd0, readback_phase_word};
          actual_phase_mdeg[channel_index*32 +: 32] <= selected_phase_mdeg;
          actual_vop_code[channel_index*32 +: 32] <= {16'd0, vop_code};
          actual_current_ua[channel_index*32 +: 32] <= 32'd1400 + ((vop_code * 32'd175) >> 2);
          channel_status[channel_index*32 +: 32] <= 32'd0;
          if (channel_index == 3'd7) state <= S_FINISH;
          else begin channel_index <= channel_index + 3'd1; state <= S_SELECT; end
        end

        S_FINISH: begin
          busy <= 1'b0;
          if (status == ST_OK && ((applied_mask | (8'b1 << channel_index)) == request_mask) && state == S_FINISH)
            status <= ST_OK;
          cached_sequence <= request_sequence;
          cached_revision <= revision;
          cached_response_valid <= 1'b1;
          done <= 1'b1;
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule


module rfdc_axil_transaction #(
    parameter integer ADDR_WIDTH = 18,
    parameter integer TIMEOUT_CYCLES = 100000
) (
    input wire clk, input wire rst_n, input wire start, input wire write_not_read,
    input wire [ADDR_WIDTH-1:0] address, input wire [31:0] write_data, input wire [3:0] write_strobe,
    output reg busy, output reg done, output reg [2:0] error, output reg [1:0] response,
    output reg [31:0] read_data,
    output reg [ADDR_WIDTH-1:0] m_awaddr, output reg m_awvalid, input wire m_awready,
    output reg [31:0] m_wdata, output reg [3:0] m_wstrb, output reg m_wvalid, input wire m_wready,
    input wire [1:0] m_bresp, input wire m_bvalid, output reg m_bready,
    output reg [ADDR_WIDTH-1:0] m_araddr, output reg m_arvalid, input wire m_arready,
    input wire [31:0] m_rdata, input wire [1:0] m_rresp, input wire m_rvalid, output reg m_rready
);
  reg [31:0] timeout_count;
  reg aw_done, w_done;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy<=0; done<=0; error<=0; response<=0; read_data<=0; timeout_count<=0; aw_done<=0; w_done<=0;
      m_awaddr<=0; m_awvalid<=0; m_wdata<=0; m_wstrb<=0; m_wvalid<=0; m_bready<=0;
      m_araddr<=0; m_arvalid<=0; m_rready<=0;
    end else begin
      done <= 1'b0;
      if (start && !busy) begin
        busy<=1; error<=0; response<=0; timeout_count<=0; aw_done<=0; w_done<=0;
        if (write_not_read) begin
          m_awaddr<=address; m_awvalid<=1; m_wdata<=write_data; m_wstrb<=write_strobe; m_wvalid<=1; m_bready<=1;
        end else begin m_araddr<=address; m_arvalid<=1; m_rready<=1; end
      end else if (busy) begin
        timeout_count <= timeout_count + 1;
        if (m_awvalid && m_awready) begin m_awvalid<=0; aw_done<=1; end
        if (m_wvalid && m_wready) begin m_wvalid<=0; w_done<=1; end
        if (m_arvalid && m_arready) m_arvalid<=0;
        if (m_bvalid && m_bready) begin
          response<=m_bresp; error<=(m_bresp==0)?0:1; m_bready<=0; busy<=0; done<=1;
        end else if (m_rvalid && m_rready) begin
          read_data<=m_rdata; response<=m_rresp; error<=(m_rresp==0)?0:2; m_rready<=0; busy<=0; done<=1;
        end else if (timeout_count >= TIMEOUT_CYCLES-1) begin
          error<=3; response<=0; m_awvalid<=0; m_wvalid<=0; m_bready<=0; m_arvalid<=0; m_rready<=0; busy<=0; done<=1;
        end
      end
    end
  end
endmodule
