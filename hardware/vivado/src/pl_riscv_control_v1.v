`timescale 1ns / 1ps

module pl_riscv_control_v1 #(
    parameter integer MAX_PAYLOAD_WORDS = 64,
    parameter integer ENABLE_UNSAFE_RFDC_MMIO = 1
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         rvctrl_tvalid,
    input  wire [63:0]  rvctrl_tdata,
    input  wire         rvctrl_tfirst,
    input  wire         rvctrl_tlast,
    input  wire [31:0]  rvctrl_word_count,

    output reg  [127:0] m_instr_tdata,
    output reg          m_instr_tvalid,
    input  wire         m_instr_tready,

    output reg          trigger_pulse,

    output reg          rfctrl2_arm_pulse,
    output reg          rfctrl2_trigger_pulse,
    output reg          rfctrl2_abort_mute_pulse,
    output reg          rfctrl2_sync_epoch_pulse,
    output reg  [63:0]  rfctrl2_epoch,
    output reg          rfctrl2_start_valid,
    output reg  [63:0]  rfctrl2_start_tick,

    output reg          rfdc_apply_start,
    output reg  [31:0]  rfdc_apply_sequence,
    output reg  [31:0]  rfdc_apply_revision,
    output reg  [7:0]   rfdc_apply_channel_mask,
    output reg  [511:0] rfdc_apply_nco_hz,
    output reg  [15:0]  rfdc_apply_nyquist_zone,
    output reg  [255:0] rfdc_apply_phase_mdeg,
    output reg  [255:0] rfdc_apply_current_ua,
    input  wire         rfdc_apply_busy,
    input  wire         rfdc_apply_done,
    input  wire [15:0]  rfdc_apply_status,
    input  wire [31:0]  rfdc_result_revision,
    input  wire [7:0]   rfdc_result_applied_mask,
    input  wire [7:0]   rfdc_result_error_mask,
    input  wire [7:0]   rfdc_config_valid_mask,
    input  wire [31:0]  rfdc_failure_stage,
    input  wire [17:0]  rfdc_failure_address,
    input  wire [1:0]   rfdc_failure_axi_response,
    input  wire         rfdc_ready,
    input  wire         playback_armed,
    input  wire         playback_prepared,
    input  wire         playback_running,
    input  wire [511:0] rfdc_actual_nco_hz,
    input  wire [15:0]  rfdc_actual_nyquist_zone,
    input  wire [255:0] rfdc_actual_phase_mdeg,
    input  wire [255:0] rfdc_actual_current_ua,
    input  wire [255:0] rfdc_channel_status,
    input  wire [511:0] rfdc_actual_nco_word,
    input  wire [255:0] rfdc_actual_phase_word,
    input  wire [255:0] rfdc_actual_vop_code,

    output reg  [63:0]  rvresp_tdata,
    output reg          rvresp_tvalid,
    input  wire         rvresp_tready,
    output reg          rvresp_tlast,
    output reg  [15:0]  rvresp_word_count,

    output reg  [17:0]  m_axil_awaddr,
    output reg          m_axil_awvalid,
    input  wire         m_axil_awready,
    output reg  [31:0]  m_axil_wdata,
    output reg  [3:0]   m_axil_wstrb,
    output reg          m_axil_wvalid,
    input  wire         m_axil_wready,
    input  wire [1:0]   m_axil_bresp,
    input  wire         m_axil_bvalid,
    output reg          m_axil_bready,

    output reg  [17:0]  m_axil_araddr,
    output reg          m_axil_arvalid,
    input  wire         m_axil_arready,
    input  wire [31:0]  m_axil_rdata,
    input  wire [1:0]   m_axil_rresp,
    input  wire         m_axil_rvalid,
    output reg          m_axil_rready,

    output reg  [31:0]  dbg_status,
    output reg  [31:0]  dbg_last_seq,
    output reg  [31:0]  dbg_last_cmd,
    output reg  [31:0]  dbg_ping_count,
    output reg  [31:0]  dbg_play_count,
    output reg  [31:0]  dbg_trigger_count,
    output reg  [31:0]  dbg_mmio_write_count,
    output reg  [31:0]  dbg_error_count,
    output reg  [31:0]  dbg_scratch,
    output reg  [3:0]   dbg_state
);

  localparam [31:0] RV0_CMD_PING             = 32'h00000001;
  localparam [31:0] RV0_CMD_PLAY_INTERLEAVED = 32'h00000002;
  localparam [31:0] RV0_CMD_TRIGGER          = 32'h00000003;
  localparam [31:0] RV0_CMD_WRITE_MMIO       = 32'h00000004;

  localparam [31:0] RV1_OP_PING             = 32'h00000001;
  localparam [31:0] RV1_OP_MMIO_READ32      = 32'h00000002;
  localparam [31:0] RV1_OP_MMIO_WRITE32     = 32'h00000003;
  localparam [31:0] RV1_OP_MMIO_RMW32       = 32'h00000004;
  localparam [31:0] RV1_OP_MMIO_BATCH       = 32'h00000005;
  localparam [31:0] RV1_OP_PLAY_INTERLEAVED = 32'h00000006;
  localparam [31:0] RV1_OP_TRIGGER          = 32'h00000007;
  localparam [31:0] RV1_OP_RFDC_CH_ENABLE   = 32'h00000008;
  localparam [31:0] RV1_OP_RFDC_SET_NCO     = 32'h00000009;
  localparam [31:0] RV1_OP_STATUS_READ      = 32'h0000000A;

  localparam [31:0] RF2_OP_HELLO             = 32'h00000001;
  localparam [31:0] RF2_OP_STATUS            = 32'h00000002;
  localparam [31:0] RF2_OP_RFDC_APPLY        = 32'h00000003;
  localparam [31:0] RF2_OP_UPLOAD_BEGIN      = 32'h00000004;
  localparam [31:0] RF2_OP_UPLOAD_COMMIT     = 32'h00000005;
  localparam [31:0] RF2_OP_ARM               = 32'h00000006;
  localparam [31:0] RF2_OP_SYNC_EPOCH        = 32'h00000007;
  localparam [31:0] RF2_OP_START_AT          = 32'h00000008;
  localparam [31:0] RF2_OP_TRIGGER           = 32'h00000009;
  localparam [31:0] RF2_OP_ABORT_MUTE        = 32'h0000000A;
  localparam [31:0] RF2_OP_RFDC_GET_CONFIG   = 32'h0000000B;
  localparam [31:0] RF2_CAPABILITIES         = 32'h00030000;
  localparam [31:0] RF2_RFDC_REQUEST_BYTES   = 32'd200;

  localparam [31:0] RV1_VERSION = 32'd1;
  localparam [31:0] RF2_VERSION = 32'd2;
  localparam [63:0] RVRESP1_MAGIC = 64'h0031505345525652;
  localparam [63:0] RFRESP2_MAGIC = 64'h0032505345524652;

  localparam [3:0] CMD_PLAY = 4'h2;
  localparam [3:0] CMD_END  = 4'h3;
  localparam [3:0] CH_AUTO_START = 4'hF;
  localparam [2:0] PLAY_FLAG_LOOP        = 3'h1;
  localparam [2:0] PLAY_FLAG_INTERLEAVED = 3'h4;

  localparam [3:0] ST_IDLE       = 4'd0;
  localparam [3:0] ST_RECEIVE    = 4'd1;
  localparam [3:0] ST_PROCESS    = 4'd2;
  localparam [3:0] ST_OUT_PLAY   = 4'd3;
  localparam [3:0] ST_MMIO_WRITE = 4'd4;
  localparam [3:0] ST_MMIO_READ  = 4'd5;
  localparam [3:0] ST_MMIO_RMW_W = 4'd6;
  localparam [3:0] ST_BATCH_LOAD = 4'd7;
  localparam [3:0] ST_NCO_SCAN   = 4'd8;
  localparam [31:0] MAX_PAYLOAD_WORDS_U32 = MAX_PAYLOAD_WORDS;

  reg [31:0] payload_words [0:MAX_PAYLOAD_WORDS-1];
  reg [31:0] rx_index;
  reg [31:0] rx_expected_words;
  reg        rx_drop;
  reg        rx_is_v1;
  reg        rx_is_v2;
  reg        process_pending;

  reg [31:0] play_bytes_per_channel;
  reg [31:0] play_flags;
  reg [3:0]  play_out_index;

  reg [31:0] cmd_opcode;
  reg [31:0] cmd_seq;
  reg [31:0] cmd_flags;
  reg [31:0] cmd_payload_bytes;
  reg [31:0] cmd_base;

  reg [17:0] mmio_addr;
  reg [31:0] mmio_wdata;
  reg [31:0] mmio_mask;
  reg [31:0] batch_index;
  reg [31:0] batch_count;
  reg [31:0] nco_index;
  reg [31:0] nco_apply_mask;
  reg [31:0] nco_zone_accum;
  reg        aw_done;
  reg        w_done;
  reg        b_done;
  reg [1:0]  bresp_latched;
  reg [63:0] resp_words [0:47];
  reg [5:0]  resp_index;
  reg [5:0]  resp_count;
  reg        rfdc_response_pending;
  reg [31:0] rfdc_response_sequence;
  reg [31:0] rfdc_response_opcode;
  reg        dbg_error_pending;

  wire instr_fire = m_instr_tvalid && m_instr_tready;
  wire out_can_load = !m_instr_tvalid || instr_fire;
  wire [31:0] rx_word_count_clean = {3'd0, rvctrl_word_count[28:0]};
  wire [31:0] active_rx_index = rvctrl_tfirst ? 32'd0 : rx_index;
  wire [31:0] active_expected_words = rvctrl_tfirst ? rx_word_count_clean : rx_expected_words;
  wire        active_count_ok = (active_expected_words <= MAX_PAYLOAD_WORDS_U32);
  wire        active_drop = rvctrl_tfirst ? !active_count_ok : rx_drop;
  wire [31:0] active_words_after_beat = active_rx_index +
      (((active_rx_index + 32'd1) < active_expected_words) ? 32'd2 : 32'd1);
  wire        write_done = aw_done && w_done && b_done;
  wire [63:0] response_magic = rx_is_v2 ? RFRESP2_MAGIC : RVRESP1_MAGIC;
  wire [15:0] response_version = rx_is_v2 ? RF2_VERSION[15:0] : RV1_VERSION[15:0];

  integer i;
  integer r;
  integer p;
  reg rfdc_payload_fields_invalid;

  always @* begin
    rfdc_payload_fields_invalid = |payload_words[5][31:8];
    for (p = 0; p < 8; p = p + 1) begin
      if (payload_words[6 + p*6 + 5] != 32'd0)
        rfdc_payload_fields_invalid = 1'b1;
    end
  end

  function [127:0] pack_instr;
    input [31:0] word0;
    input [31:0] word1;
    input [31:0] word2;
    input [31:0] word3;
    begin
      pack_instr = {word3, word2, word1, word0};
    end
  endfunction

  function [31:0] play_word0;
    input [3:0] channel;
    begin
      play_word0 = {21'd0, PLAY_FLAG_INTERLEAVED, channel, CMD_PLAY};
    end
  endfunction

  function [31:0] end_word0;
    input auto_start;
    input loop_en;
    reg [2:0] flags;
    begin
      flags = loop_en ? PLAY_FLAG_LOOP : 3'd0;
      end_word0 = {21'd0, flags, (auto_start ? CH_AUTO_START : 4'd0), CMD_END};
    end
  endfunction

  task queue_resp0;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    begin
      if (!rvresp_tvalid) begin
        resp_words[0] <= response_magic;
        resp_words[1] <= {opcode, status_code, response_version};
        resp_words[2] <= {32'd0, resp_seq};
        resp_count <= 4'd3;
        resp_index <= 4'd0;
        rvresp_word_count <= 16'd3;
        rvresp_tdata <= response_magic;
        rvresp_tvalid <= 1'b1;
        rvresp_tlast <= 1'b0;
      end else begin
        dbg_error_pending <= 1'b1;
      end
    end
  endtask

  task queue_rf2_status;
    input [31:0] opcode;
    input [31:0] resp_seq;
    reg [31:0] state_flags;
    begin
      if (!rvresp_tvalid) begin
        state_flags = {27'd0, playback_prepared, playback_running, playback_armed, rfdc_apply_busy, rfdc_ready};
        resp_words[0] <= RFRESP2_MAGIC;
        resp_words[1] <= {opcode, 16'h0000, RF2_VERSION[15:0]};
        resp_words[2] <= {32'd32, resp_seq};
        resp_words[3] <= {state_flags, RF2_CAPABILITIES};
        resp_words[4] <= {rfdc_result_revision, 24'd0, rfdc_config_valid_mask};
        resp_words[5] <= {rfdc_failure_stage, 16'd0, rfdc_apply_status};
        resp_words[6] <= {32'd0, 14'd0, rfdc_failure_address};
        resp_count <= 6'd7;
        resp_index <= 6'd0;
        rvresp_word_count <= 16'd7;
        rvresp_tdata <= RFRESP2_MAGIC;
        rvresp_tvalid <= 1'b1;
        rvresp_tlast <= 1'b0;
      end else begin
        dbg_error_pending <= 1'b1;
      end
    end
  endtask

  task queue_rfdc_response;
    input [31:0] opcode;
    input [31:0] resp_seq;
    integer channel;
    integer base_word;
    reg [31:0] state_flags;
    begin
      if (!rvresp_tvalid) begin
        state_flags = {27'd0, playback_prepared, playback_running, playback_armed, rfdc_apply_busy, rfdc_ready};
        resp_words[0] <= RFRESP2_MAGIC;
        resp_words[1] <= {
            opcode,
            (opcode == RF2_OP_RFDC_GET_CONFIG) ? 16'h0000 : rfdc_apply_status,
            RF2_VERSION[15:0]
        };
        resp_words[2] <= {32'd352, resp_seq};
        resp_words[3] <= {{24{1'b0}}, rfdc_result_applied_mask, rfdc_result_revision};
        resp_words[4] <= {{24{1'b0}}, rfdc_config_valid_mask, {24'd0, rfdc_result_error_mask}};
        resp_words[5] <= {{14{1'b0}}, rfdc_failure_address, rfdc_failure_stage};
        resp_words[6] <= {state_flags, 30'd0, rfdc_failure_axi_response};
        for (channel = 0; channel < 8; channel = channel + 1) begin
          base_word = 7 + channel * 5;
          resp_words[base_word] <= rfdc_actual_nco_hz[channel*64 +: 64];
          resp_words[base_word+1] <= {
              rfdc_actual_phase_mdeg[channel*32 +: 32],
              30'd0, rfdc_actual_nyquist_zone[channel*2 +: 2]
          };
          resp_words[base_word+2] <= {
              rfdc_channel_status[channel*32 +: 32],
              rfdc_actual_current_ua[channel*32 +: 32]
          };
          resp_words[base_word+3] <= rfdc_actual_nco_word[channel*64 +: 64];
          resp_words[base_word+4] <= {
              rfdc_actual_vop_code[channel*32 +: 32],
              rfdc_actual_phase_word[channel*32 +: 32]
          };
        end
        resp_count <= 6'd47;
        resp_index <= 6'd0;
        rvresp_word_count <= 16'd47;
        rvresp_tdata <= RFRESP2_MAGIC;
        rvresp_tvalid <= 1'b1;
        rvresp_tlast <= 1'b0;
      end else begin
        dbg_error_pending <= 1'b1;
      end
    end
  endtask

  task queue_resp1;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    input [31:0] payload_bytes;
    input [63:0] payload0;
    begin
      if (!rvresp_tvalid) begin
        resp_words[0] <= response_magic;
        resp_words[1] <= {opcode, status_code, response_version};
        resp_words[2] <= {payload_bytes, resp_seq};
        resp_words[3] <= payload0;
        resp_count <= 4'd4;
        resp_index <= 4'd0;
        rvresp_word_count <= 16'd4;
        rvresp_tdata <= response_magic;
        rvresp_tvalid <= 1'b1;
        rvresp_tlast <= 1'b0;
      end else begin
        dbg_error_pending <= 1'b1;
      end
    end
  endtask

  task queue_resp2;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    input [31:0] payload_bytes;
    input [63:0] payload0;
    input [63:0] payload1;
    begin
      if (!rvresp_tvalid) begin
        resp_words[0] <= response_magic;
        resp_words[1] <= {opcode, status_code, response_version};
        resp_words[2] <= {payload_bytes, resp_seq};
        resp_words[3] <= payload0;
        resp_words[4] <= payload1;
        resp_count <= 4'd5;
        resp_index <= 4'd0;
        rvresp_word_count <= 16'd5;
        rvresp_tdata <= response_magic;
        rvresp_tvalid <= 1'b1;
        rvresp_tlast <= 1'b0;
      end else begin
        dbg_error_pending <= 1'b1;
      end
    end
  endtask

  task start_write;
    input [31:0] addr;
    input [31:0] data;
    begin
      mmio_addr <= addr[17:0];
      mmio_wdata <= data;
      m_axil_awaddr <= addr[17:0];
      m_axil_awvalid <= 1'b1;
      m_axil_wdata <= data;
      m_axil_wstrb <= 4'hF;
      m_axil_wvalid <= 1'b1;
      m_axil_bready <= 1'b1;
      aw_done <= 1'b0;
      w_done <= 1'b0;
      b_done <= 1'b0;
      bresp_latched <= 2'b00;
      dbg_state <= ST_MMIO_WRITE;
    end
  endtask

  task start_read;
    input [31:0] addr;
    begin
      mmio_addr <= addr[17:0];
      m_axil_araddr <= addr[17:0];
      m_axil_arvalid <= 1'b1;
      m_axil_rready <= 1'b1;
      dbg_state <= ST_MMIO_READ;
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_instr_tdata <= 128'd0;
      m_instr_tvalid <= 1'b0;
      trigger_pulse <= 1'b0;
      rfctrl2_arm_pulse <= 1'b0;
      rfctrl2_trigger_pulse <= 1'b0;
      rfctrl2_abort_mute_pulse <= 1'b0;
      rfctrl2_sync_epoch_pulse <= 1'b0;
      rfctrl2_start_valid <= 1'b0;
      rfctrl2_epoch <= 64'd0;
      rfctrl2_start_valid <= 1'b0;
      rfctrl2_start_tick <= 64'd0;
      rfdc_apply_start <= 1'b0;
      rfdc_apply_sequence <= 32'd0;
      rfdc_apply_revision <= 32'd0;
      rfdc_apply_channel_mask <= 8'd0;
      rfdc_apply_nco_hz <= 512'd0;
      rfdc_apply_nyquist_zone <= 16'd0;
      rfdc_apply_phase_mdeg <= 256'd0;
      rfdc_apply_current_ua <= 256'd0;
      rvresp_tdata <= 64'd0;
      rvresp_tvalid <= 1'b0;
      rvresp_tlast <= 1'b0;
      rvresp_word_count <= 16'd0;
      m_axil_awaddr <= 18'd0;
      m_axil_awvalid <= 1'b0;
      m_axil_wdata <= 32'd0;
      m_axil_wstrb <= 4'h0;
      m_axil_wvalid <= 1'b0;
      m_axil_bready <= 1'b0;
      m_axil_araddr <= 18'd0;
      m_axil_arvalid <= 1'b0;
      m_axil_rready <= 1'b0;
      dbg_status <= 32'd0;
      dbg_last_seq <= 32'd0;
      dbg_last_cmd <= 32'd0;
      dbg_ping_count <= 32'd0;
      dbg_play_count <= 32'd0;
      dbg_trigger_count <= 32'd0;
      dbg_mmio_write_count <= 32'd0;
      dbg_error_count <= 32'd0;
      dbg_error_pending <= 1'b0;
      dbg_scratch <= 32'd0;
      dbg_state <= ST_IDLE;
      rx_index <= 32'd0;
      rx_expected_words <= 32'd0;
      rx_drop <= 1'b0;
      rx_is_v1 <= 1'b0;
      rx_is_v2 <= 1'b0;
      process_pending <= 1'b0;
      play_bytes_per_channel <= 32'd0;
      play_flags <= 32'd0;
      play_out_index <= 4'd0;
      cmd_opcode <= 32'd0;
      cmd_seq <= 32'd0;
      cmd_flags <= 32'd0;
      cmd_payload_bytes <= 32'd0;
      cmd_base <= 32'd0;
      mmio_addr <= 18'd0;
      mmio_wdata <= 32'd0;
      mmio_mask <= 32'd0;
      batch_index <= 32'd0;
      batch_count <= 32'd0;
      nco_index <= 32'd0;
      nco_apply_mask <= 32'd0;
      nco_zone_accum <= 32'd0;
      aw_done <= 1'b0;
      w_done <= 1'b0;
      b_done <= 1'b0;
      bresp_latched <= 2'b00;
      resp_index <= 4'd0;
      resp_count <= 4'd0;
      rfdc_response_pending <= 1'b0;
      rfdc_response_sequence <= 32'd0;
      rfdc_response_opcode <= RF2_OP_RFDC_APPLY;
      for (i = 0; i < MAX_PAYLOAD_WORDS; i = i + 1) begin
        payload_words[i] <= 32'd0;
      end
      for (i = 0; i < 48; i = i + 1) begin
        resp_words[i] <= 64'd0;
      end
    end else begin
      trigger_pulse <= 1'b0;
      rfctrl2_arm_pulse <= 1'b0;
      rfctrl2_trigger_pulse <= 1'b0;
      rfctrl2_abort_mute_pulse <= 1'b0;
      rfctrl2_sync_epoch_pulse <= 1'b0;
      rfdc_apply_start <= 1'b0;

      if (dbg_error_pending) begin
        dbg_error_count <= dbg_error_count + 32'd1;
        dbg_error_pending <= 1'b0;
      end

      if (rfdc_response_pending && rfdc_apply_done) begin
        rfdc_response_pending <= 1'b0;
        queue_rfdc_response(rfdc_response_opcode, rfdc_response_sequence);
      end

      if (rvresp_tvalid && rvresp_tready) begin
        if (rvresp_tlast) begin
          rvresp_tvalid <= 1'b0;
          rvresp_tlast <= 1'b0;
          rvresp_tdata <= 64'd0;
          resp_index <= 6'd0;
          resp_count <= 6'd0;
          rvresp_word_count <= 16'd0;
        end else begin
          resp_index <= resp_index + 6'd1;
          rvresp_tdata <= resp_words[resp_index + 6'd1];
          rvresp_tlast <= ((resp_index + 6'd1) == (resp_count - 6'd1));
        end
      end

      if (instr_fire) begin
        m_instr_tvalid <= 1'b0;
      end
      if (m_axil_awvalid && m_axil_awready) begin
        m_axil_awvalid <= 1'b0;
        aw_done <= 1'b1;
      end
      if (m_axil_wvalid && m_axil_wready) begin
        m_axil_wvalid <= 1'b0;
        w_done <= 1'b1;
      end
      if (m_axil_bvalid && m_axil_bready) begin
        b_done <= 1'b1;
        bresp_latched <= m_axil_bresp;
      end
      if (m_axil_arvalid && m_axil_arready) begin
        m_axil_arvalid <= 1'b0;
      end

      if (rvctrl_tvalid && !rfdc_response_pending) begin
        dbg_state <= ST_RECEIVE;
        if (rvctrl_tfirst) begin
          rx_index <= 32'd0;
          rx_expected_words <= rx_word_count_clean;
          rx_is_v1 <= rvctrl_word_count[31];
          rx_is_v2 <= rvctrl_word_count[29];
          rx_drop <= (rx_word_count_clean > MAX_PAYLOAD_WORDS_U32);
          if (rx_word_count_clean > MAX_PAYLOAD_WORDS_U32) begin
            dbg_error_pending <= 1'b1;
          end
        end

        if (active_count_ok && (active_rx_index < MAX_PAYLOAD_WORDS_U32)) begin
          payload_words[active_rx_index] <= rvctrl_tdata[31:0];
        end
        if (active_count_ok &&
            ((active_rx_index + 32'd1) < active_expected_words) &&
            ((active_rx_index + 32'd1) < MAX_PAYLOAD_WORDS_U32)) begin
          payload_words[active_rx_index + 32'd1] <= rvctrl_tdata[63:32];
        end
        rx_index <= active_rx_index + 32'd2;
        if (rvctrl_tlast) begin
          process_pending <= active_count_ok && !active_drop &&
                             (active_words_after_beat == active_expected_words);
          if (active_words_after_beat != active_expected_words)
            dbg_error_pending <= 1'b1;
        end
      end else if (process_pending) begin
        process_pending <= 1'b0;
        dbg_state <= ST_PROCESS;

        if (rx_is_v1) begin
          cmd_flags <= {16'd0, payload_words[0][31:16]};
          cmd_opcode <= payload_words[1];
          cmd_seq <= payload_words[2];
          cmd_payload_bytes <= payload_words[3];
          cmd_base <= 32'd4;
          dbg_last_cmd <= payload_words[1];
          dbg_last_seq <= payload_words[2];
        end else if (rx_is_v2) begin
          // RFCTRL2 keeps the version/opcode/sequence/payload-length header
          // in the same four 32-bit words as RVCTRL1, but uses a distinct
          // transport marker. Keep the decoded command fields consistent
          // with the indexed payload handling below.
          cmd_flags <= {16'd0, payload_words[0][31:16]};
          cmd_opcode <= payload_words[1];
          cmd_seq <= payload_words[2];
          cmd_payload_bytes <= payload_words[3];
          cmd_base <= 32'd4;
          dbg_last_cmd <= payload_words[1];
          dbg_last_seq <= payload_words[2];
        end else begin
          cmd_flags <= 32'd0;
          cmd_opcode <= payload_words[0];
          cmd_seq <= payload_words[1];
          cmd_payload_bytes <= (rx_expected_words > 32'd2) ? ((rx_expected_words - 32'd2) << 2) : 32'd0;
          cmd_base <= 32'd2;
          dbg_last_cmd <= payload_words[0];
          dbg_last_seq <= payload_words[1];
        end

        if ((rx_is_v1 || rx_is_v2) &&
            (payload_words[0][15:0] != (rx_is_v2 ? RF2_VERSION[15:0] : RV1_VERSION[15:0]))) begin
          dbg_status <= 32'hBAD1_0001;
          dbg_error_pending <= 1'b1;
          queue_resp0(payload_words[1], 16'h0001, payload_words[2]);
        end else if (rx_is_v2 && (payload_words[1] == RF2_OP_HELLO)) begin
          dbg_status <= 32'h2000_0001;
          queue_rf2_status(RF2_OP_HELLO, payload_words[2]);
        end else if (rx_is_v2 && (payload_words[1] == RF2_OP_STATUS)) begin
          dbg_status <= 32'h2000_0002;
          queue_rf2_status(RF2_OP_STATUS, payload_words[2]);
        end else if (rx_is_v2 && (payload_words[1] == RF2_OP_RFDC_APPLY)) begin
          if ((payload_words[3] != RF2_RFDC_REQUEST_BYTES) ||
              (rx_expected_words != 32'd54) || rfdc_payload_fields_invalid) begin
            dbg_status <= 32'hBAD2_0003;
            dbg_error_pending <= 1'b1;
            queue_resp0(RF2_OP_RFDC_APPLY, 16'h0003, payload_words[2]);
          end else if (rfdc_apply_busy) begin
            dbg_status <= 32'hBAD2_0004;
            queue_resp0(RF2_OP_RFDC_APPLY, 16'h0004, payload_words[2]);
          end else begin
            rfdc_apply_sequence <= payload_words[2];
            rfdc_apply_revision <= payload_words[4];
            rfdc_apply_channel_mask <= payload_words[5][7:0];
            for (r = 0; r < 8; r = r + 1) begin
              rfdc_apply_nco_hz[r*64 +: 64] <= {
                  payload_words[6 + r*6 + 1], payload_words[6 + r*6]
              };
              rfdc_apply_nyquist_zone[r*2 +: 2] <= payload_words[6 + r*6 + 2][1:0];
              rfdc_apply_phase_mdeg[r*32 +: 32] <= payload_words[6 + r*6 + 3];
              rfdc_apply_current_ua[r*32 +: 32] <= payload_words[6 + r*6 + 4];
            end
            rfdc_apply_start <= 1'b1;
            rfdc_response_pending <= 1'b1;
            rfdc_response_sequence <= payload_words[2];
            rfdc_response_opcode <= RF2_OP_RFDC_APPLY;
            dbg_status <= 32'h2000_0003;
          end
        end else if (rx_is_v2 && (payload_words[1] == RF2_OP_RFDC_GET_CONFIG)) begin
          queue_rfdc_response(RF2_OP_RFDC_GET_CONFIG, payload_words[2]);
        end else if (rx_is_v2 && (payload_words[1] == RF2_OP_ARM)) begin
          if ((payload_words[3] != 32'd8) ||
              ((payload_words[5][7:0] & ~rfdc_config_valid_mask) != 8'd0)) begin
            dbg_status <= 32'hBAD2_0006;
            queue_resp0(RF2_OP_ARM, 16'h0006, payload_words[2]);
          end else if (playback_armed || playback_prepared || playback_running) begin
            dbg_status <= 32'hBAD2_1006;
            queue_resp0(RF2_OP_ARM, 16'h0006, payload_words[2]);
          end else begin
            rfctrl2_arm_pulse <= 1'b1;
            dbg_scratch <= payload_words[5];
            dbg_status <= 32'h2000_0006;
            queue_resp1(RF2_OP_ARM, 16'h0000, payload_words[2], 32'd8, {payload_words[5], payload_words[4]});
          end
        end else if (rx_is_v2 && (payload_words[1] == RF2_OP_SYNC_EPOCH)) begin
          rfctrl2_epoch <= {payload_words[5], payload_words[4]};
          rfctrl2_sync_epoch_pulse <= 1'b1;
          dbg_status <= 32'h2000_0007;
          queue_resp1(RF2_OP_SYNC_EPOCH, 16'h0000, payload_words[2], 32'd8, {payload_words[5], payload_words[4]});
        end else if (rx_is_v2 && (payload_words[1] == RF2_OP_START_AT)) begin
          rfctrl2_start_tick <= {payload_words[5], payload_words[4]};
          rfctrl2_start_valid <= 1'b1;
          dbg_status <= 32'h2000_0008;
          queue_resp1(RF2_OP_START_AT, 16'h0000, payload_words[2], 32'd8, {payload_words[5], payload_words[4]});
        end else if (rx_is_v2 && (payload_words[1] == RF2_OP_TRIGGER)) begin
          if (!playback_prepared) begin
            dbg_status <= 32'hBAD2_0009;
            queue_resp0(RF2_OP_TRIGGER, 16'h0006, payload_words[2]);
          end else begin
            rfctrl2_trigger_pulse <= 1'b1;
            dbg_trigger_count <= dbg_trigger_count + 32'd1;
            dbg_status <= 32'h2000_0009;
            queue_resp0(RF2_OP_TRIGGER, 16'h0000, payload_words[2]);
          end
        end else if (rx_is_v2 && (payload_words[1] == RF2_OP_ABORT_MUTE)) begin
          rfctrl2_abort_mute_pulse <= 1'b1;
          dbg_status <= 32'h2000_000A;
          queue_resp0(RF2_OP_ABORT_MUTE, 16'h0000, payload_words[2]);
        end else if ((!rx_is_v1 && (payload_words[0] == RV0_CMD_PING)) ||
                     ( rx_is_v1 && (payload_words[1] == RV1_OP_PING))) begin
          dbg_status <= rx_is_v1 ? 32'h1000_0001 : 32'h0000_0001;
          dbg_ping_count <= dbg_ping_count + 32'd1;
          if (rx_is_v1) queue_resp0(RV1_OP_PING, 16'h0000, payload_words[2]);
        end else if ((!rx_is_v1 && (payload_words[0] == RV0_CMD_PLAY_INTERLEAVED)) ||
                     ( rx_is_v1 && (payload_words[1] == RV1_OP_PLAY_INTERLEAVED))) begin
          if (payload_words[rx_is_v1 ? 4 : 2][4:0] != 5'd0) begin
            dbg_status <= 32'hBAD0_0002;
            dbg_error_pending <= 1'b1;
            if (rx_is_v1) queue_resp0(RV1_OP_PLAY_INTERLEAVED, 16'h0002, payload_words[2]);
          end else begin
            play_bytes_per_channel <= payload_words[rx_is_v1 ? 4 : 2];
            play_flags <= payload_words[rx_is_v1 ? 5 : 3];
            play_out_index <= 4'd0;
            dbg_play_count <= dbg_play_count + 32'd1;
            dbg_status <= rx_is_v1 ? 32'h1000_0006 : 32'h0000_0002;
            dbg_state <= ST_OUT_PLAY;
          end
        end else if ((!rx_is_v1 && (payload_words[0] == RV0_CMD_TRIGGER)) ||
                     ( rx_is_v1 && (payload_words[1] == RV1_OP_TRIGGER))) begin
          trigger_pulse <= 1'b1;
          dbg_trigger_count <= dbg_trigger_count + 32'd1;
          dbg_status <= rx_is_v1 ? 32'h1000_0007 : 32'h0000_0003;
          if (rx_is_v1) queue_resp0(RV1_OP_TRIGGER, 16'h0000, payload_words[2]);
        end else if (ENABLE_UNSAFE_RFDC_MMIO &&
                     ((!rx_is_v1 && (payload_words[0] == RV0_CMD_WRITE_MMIO)) ||
                     ( rx_is_v1 && (payload_words[1] == RV1_OP_MMIO_WRITE32)))) begin
          start_write(payload_words[rx_is_v1 ? 4 : 2], payload_words[rx_is_v1 ? 5 : 3]);
        end else if (rx_is_v1 && (payload_words[1] == RV1_OP_MMIO_READ32)) begin
          start_read(payload_words[4]);
        end else if (ENABLE_UNSAFE_RFDC_MMIO && rx_is_v1 && (payload_words[1] == RV1_OP_MMIO_RMW32)) begin
          mmio_mask <= payload_words[5];
          mmio_wdata <= payload_words[6];
          start_read(payload_words[4]);
        end else if (ENABLE_UNSAFE_RFDC_MMIO && rx_is_v1 && (payload_words[1] == RV1_OP_MMIO_BATCH)) begin
          batch_count <= payload_words[4];
          batch_index <= 32'd0;
          dbg_state <= ST_BATCH_LOAD;
        end else if (ENABLE_UNSAFE_RFDC_MMIO && rx_is_v1 &&
                     (payload_words[1] == RV1_OP_RFDC_CH_ENABLE)) begin
          dbg_scratch <= payload_words[4];
          dbg_status <= 32'h1000_0008;
          queue_resp1(RV1_OP_RFDC_CH_ENABLE, 16'h0000, payload_words[2], 32'd8, {payload_words[5], payload_words[4]});
        end else if (ENABLE_UNSAFE_RFDC_MMIO && rx_is_v1 &&
                     (payload_words[1] == RV1_OP_RFDC_SET_NCO)) begin
          nco_apply_mask <= payload_words[4];
          nco_index <= 32'd0;
          nco_zone_accum <= 32'd0;
          dbg_state <= ST_NCO_SCAN;
        end else if (rx_is_v1 && (payload_words[1] == RV1_OP_STATUS_READ)) begin
          dbg_status <= 32'h1000_000A;
          queue_resp2(
              RV1_OP_STATUS_READ,
              16'h0000,
              payload_words[2],
              32'd16,
              {dbg_last_cmd, 32'h1000_000A},
              {dbg_error_count, dbg_scratch}
          );
        end else begin
          dbg_status <= rx_is_v1 ? 32'hBAD1_0002 : 32'hBAD0_0001;
          dbg_error_pending <= 1'b1;
          if (rx_is_v1 || rx_is_v2) queue_resp0(payload_words[1], 16'h0002, payload_words[2]);
        end
      end else if (dbg_state == ST_OUT_PLAY) begin
        if (out_can_load) begin
          if (play_out_index < 4'd8) begin
            m_instr_tdata <= pack_instr(
                play_word0(play_out_index + 4'd1),
                play_bytes_per_channel,
                32'd0,
                32'd0
            );
            m_instr_tvalid <= 1'b1;
            play_out_index <= play_out_index + 4'd1;
          end else begin
            m_instr_tdata <= pack_instr(
                end_word0(play_flags[0], play_flags[1]),
                32'd0,
                32'd0,
                32'd0
            );
            m_instr_tvalid <= 1'b1;
            play_out_index <= 4'd0;
            dbg_state <= ST_IDLE;
            if (rx_is_v1) queue_resp1(
                RV1_OP_PLAY_INTERLEAVED,
                16'h0000,
                cmd_seq,
                32'd8,
                {play_flags, play_bytes_per_channel}
            );
          end
        end
      end else if (dbg_state == ST_MMIO_WRITE) begin
        if (write_done) begin
          m_axil_bready <= 1'b0;
          dbg_scratch <= mmio_wdata;
          dbg_mmio_write_count <= dbg_mmio_write_count + 32'd1;
          dbg_status <= (bresp_latched == 2'b00) ? 32'h1000_0003 : 32'hBAD1_0010;
          if (bresp_latched != 2'b00) dbg_error_pending <= 1'b1;
          if (rx_is_v1 && (cmd_opcode != RV1_OP_MMIO_BATCH)) begin
            queue_resp1(cmd_opcode, {14'd0, bresp_latched}, cmd_seq, 32'd8, {mmio_wdata, 14'd0, mmio_addr});
          end
          aw_done <= 1'b0;
          w_done <= 1'b0;
          b_done <= 1'b0;
          dbg_state <= (cmd_opcode == RV1_OP_MMIO_BATCH && batch_index < batch_count) ? ST_BATCH_LOAD : ST_IDLE;
        end
      end else if (dbg_state == ST_MMIO_READ) begin
        if (m_axil_rvalid) begin
          m_axil_rready <= 1'b0;
          dbg_scratch <= m_axil_rdata;
          if (cmd_opcode == RV1_OP_MMIO_RMW32) begin
            start_write({14'd0, mmio_addr}, (m_axil_rdata & ~mmio_mask) | (mmio_wdata & mmio_mask));
            dbg_state <= ST_MMIO_RMW_W;
          end else begin
            dbg_status <= (m_axil_rresp == 2'b00) ? 32'h1000_0002 : 32'hBAD1_0011;
            if (m_axil_rresp != 2'b00) dbg_error_pending <= 1'b1;
            queue_resp1(RV1_OP_MMIO_READ32, {14'd0, m_axil_rresp}, cmd_seq, 32'd8, {m_axil_rdata, 14'd0, mmio_addr});
            dbg_state <= ST_IDLE;
          end
        end
      end else if (dbg_state == ST_MMIO_RMW_W) begin
        dbg_state <= ST_MMIO_WRITE;
      end else if (dbg_state == ST_BATCH_LOAD) begin
        if (batch_index >= batch_count) begin
          dbg_status <= 32'h1000_0005;
          queue_resp1(RV1_OP_MMIO_BATCH, 16'h0000, cmd_seq, 32'd8, {batch_count, 32'd0});
          dbg_state <= ST_IDLE;
        end else if ((32'd5 + (batch_index << 1) + 32'd1) < MAX_PAYLOAD_WORDS_U32) begin
          start_write(payload_words[32'd5 + (batch_index << 1)],
                      payload_words[32'd6 + (batch_index << 1)]);
          batch_index <= batch_index + 32'd1;
        end else begin
          dbg_status <= 32'hBAD1_0005;
          dbg_error_pending <= 1'b1;
          dbg_state <= ST_IDLE;
        end
      end else if (dbg_state == ST_NCO_SCAN) begin
        // Legacy diagnostics only. Production builds disable this path and use
        // structured RFCTRL2 RFDC_APPLY with hardware readback instead.
        if (nco_index >= 32'd8) begin
          dbg_scratch <= {nco_apply_mask[7:0], nco_zone_accum[23:0]};
          dbg_status <= 32'h1000_0009;
          queue_resp1(RV1_OP_RFDC_SET_NCO, 16'h0000, cmd_seq, 32'd8, {nco_apply_mask, nco_zone_accum});
          dbg_state <= ST_IDLE;
        end else begin
          nco_zone_accum <= nco_zone_accum ^ payload_words[32'd7 + (nco_index * 32'd4)];
          nco_index <= nco_index + 32'd1;
        end
      end else begin
        dbg_state <= ST_IDLE;
      end
    end
  end

endmodule
