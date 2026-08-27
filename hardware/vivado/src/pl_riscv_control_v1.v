`timescale 1ns / 1ps

module pl_riscv_control_v1 #(
    parameter integer MAX_PAYLOAD_WORDS = 64,
    parameter integer ENABLE_UNSAFE_RFDC_MMIO = 1,
    parameter [31:0] BUILD_PROFILE_ID = 32'd1
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         rvctrl_tvalid,
    input  wire [63:0]  rvctrl_tdata,
    input  wire         rvctrl_tfirst,
    input  wire         rvctrl_tlast,
    input  wire [31:0]  rvctrl_word_count,
    input  wire [1:0]   rvctrl_protocol,

    output reg  [127:0] m_instr_tdata,
    output reg          m_instr_tvalid,
    input  wire         m_instr_tready,

    output reg          trigger_pulse,

    output reg          rfctrl2_arm_pulse,
    output reg          rfctrl2_trigger_pulse,
    output reg          rfctrl2_abort_mute_pulse,
    output reg          rfctrl2_sync_epoch_pulse,
    output reg  [63:0]  rfctrl2_epoch,
    output reg          rfctrl2_set_sync_role_pulse,
    output reg  [31:0]  rfctrl2_sync_role,
    output reg  [31:0]  rfctrl2_sync_mode,
    output reg          rfctrl2_emit_trigger_pulse,
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
    input  wire         dac_mts_required,
    input  wire         dac_mts_ready,
    input  wire         dac_mts_failed,
    input  wire [3:0]   dac_mts_tile_mask,
    input  wire [15:0]  dac_mts_error,
    input  wire         nco_sync_ready,
    input  wire [31:0]  nco_sync_epoch,
    input  wire         playback_armed,
    input  wire         playback_prepared,
    input  wire         playback_running,
    input  wire         sync_role_master,
    input  wire         sync_bypass,
    input  wire         sync_seen,
    input  wire         sync_link_ready,
    input  wire         sync_align_busy,
    input  wire         sync_align_failed,
    input  wire [5:0]   sync_alignment_epoch,
    input  wire [15:0]  sync_alignment_error,
    input  wire [31:0]  trigger_input_count,
    input  wire [31:0]  trigger_accepted_count,
    input  wire [31:0]  trigger_output_count,
    input  wire [511:0] rfdc_actual_nco_hz,
    input  wire [15:0]  rfdc_actual_nyquist_zone,
    input  wire [255:0] rfdc_actual_phase_mdeg,
    input  wire [255:0] rfdc_actual_current_ua,
    input  wire [255:0] rfdc_channel_status,
    input  wire [511:0] rfdc_actual_nco_word,
    input  wire [255:0] rfdc_actual_phase_word,
    input  wire [255:0] rfdc_actual_vop_code,

    output reg         network_apply_start,
    output reg [31:0]  network_apply_revision,
    output reg [31:0]  network_apply_ip,
    output reg [63:0]  network_apply_mac,
    output reg [31:0]  network_apply_subnet,
    output reg [31:0]  network_apply_gateway,
    output reg [15:0]  network_apply_port,
    output reg         network_restart_start,
    input  wire        network_busy,
    input  wire        network_done,
    input  wire [15:0] network_status,
    input  wire [31:0] network_result_revision,
    input  wire [31:0] network_current_ip,
    input  wire [63:0] network_current_mac,
    input  wire [31:0] network_current_subnet,
    input  wire [31:0] network_current_gateway,
    input  wire [15:0] network_current_port,
    input  wire [63:0] network_device_uid,
    input  wire [63:0] network_bootstrap_mac,
    input  wire [31:0] network_bootstrap_ip,
    input  wire [31:0] network_capabilities,
    input  wire [31:0] network_status_flags,
    input  wire [15:0] network_link_state,
    input  wire [7:0]  play_config_channel_mask,
    input  wire [7:0]  play_fifo_valid_mask,
    input  wire [7:0]  play_fifo_ready_mask,
    input  wire [7:0]  play_executor_state,
    input  wire [31:0] play_ddr_read_counter,
    input  wire [31:0] play_bad_instr_count,
    input  wire        play_prefill_ready,
    input  wire        play_active_valid,
    input  wire        play_pending_valid,

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
  // Structured RFDC apply, RFDC readback, and runtime network identity
  // configuration are all advertised through HELLO/STATUS.
  localparam [31:0] RF2_CAPABILITIES         = 32'h007F0000;
  localparam [31:0] RF2_RFDC_REQUEST_BYTES   = 32'd200;
  localparam [31:0] RF2_NETWORK_APPLY_BYTES  = 32'd32;
  localparam [31:0] RF2_NETWORK_RESPONSE_BYTES = 32'd80;
  localparam [31:0] RF2_OP_NETWORK_GET       = 32'h0000000C;
  localparam [31:0] RF2_OP_NETWORK_APPLY     = 32'h0000000D;
  localparam [31:0] RF2_OP_NETWORK_RESTART   = 32'h0000000E;
  localparam [31:0] RF2_OP_SET_SYNC_ROLE     = 32'h0000000F;
  localparam [31:0] RF2_OP_EMIT_TRIGGER      = 32'h00000010;

  localparam [31:0] RV1_VERSION = 32'd1;
  localparam [31:0] RF2_VERSION = 32'd2;
  localparam [1:0] RVCTRL_PROTOCOL_LEGACY = 2'd0;
  localparam [1:0] RVCTRL_PROTOCOL_V1     = 2'd1;
  localparam [1:0] RVCTRL_PROTOCOL_RF2    = 2'd2;
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
  localparam [2:0] RESP_REQ_NONE    = 3'd0;
  localparam [2:0] RESP_REQ_0       = 3'd1;
  localparam [2:0] RESP_REQ_1       = 3'd2;
  localparam [2:0] RESP_REQ_2       = 3'd3;
  localparam [2:0] RESP_REQ_STATUS  = 3'd4;
  localparam [2:0] RESP_REQ_RFDC    = 3'd5;
  localparam [2:0] RESP_REQ_NETWORK = 3'd6;
  localparam [4:0] DEC_UNSUPPORTED       = 5'd0;
  localparam [4:0] DEC_RF2_HELLO         = 5'd1;
  localparam [4:0] DEC_RF2_STATUS        = 5'd2;
  localparam [4:0] DEC_RF2_NETWORK_GET   = 5'd3;
  localparam [4:0] DEC_RF2_NETWORK_APPLY = 5'd4;
  localparam [4:0] DEC_RF2_NETWORK_RESTART = 5'd5;
  localparam [4:0] DEC_RF2_RFDC_APPLY    = 5'd6;
  localparam [4:0] DEC_RF2_RFDC_GET      = 5'd7;
  localparam [4:0] DEC_RF2_ARM           = 5'd8;
  localparam [4:0] DEC_RF2_SYNC_EPOCH    = 5'd9;
  localparam [4:0] DEC_RF2_START_AT      = 5'd10;
  localparam [4:0] DEC_RF2_TRIGGER       = 5'd11;
  localparam [4:0] DEC_RF2_ABORT_MUTE    = 5'd12;
  localparam [4:0] DEC_RV_PING           = 5'd13;
  localparam [4:0] DEC_RV_PLAY_INTERLEAVED = 5'd14;
  localparam [4:0] DEC_RV_TRIGGER        = 5'd15;
  localparam [4:0] DEC_RV_WRITE_MMIO     = 5'd16;
  localparam [4:0] DEC_RV1_MMIO_READ32   = 5'd17;
  localparam [4:0] DEC_RV1_MMIO_RMW32    = 5'd18;
  localparam [4:0] DEC_RV1_MMIO_BATCH    = 5'd19;
  localparam [4:0] DEC_RV1_RFDC_CH_ENABLE = 5'd20;
  localparam [4:0] DEC_RV1_RFDC_SET_NCO  = 5'd21;
  localparam [4:0] DEC_RV1_STATUS_READ   = 5'd22;
  localparam [4:0] DEC_RF2_SET_SYNC_ROLE = 5'd23;
  localparam [4:0] DEC_RF2_EMIT_TRIGGER  = 5'd24;
  localparam integer RX_COUNT_WIDTH = $clog2(MAX_PAYLOAD_WORDS + 1);
  localparam [31:0] MAX_PAYLOAD_WORDS_U32 = MAX_PAYLOAD_WORDS;
  localparam [RX_COUNT_WIDTH-1:0] MAX_PAYLOAD_WORDS_COUNT = MAX_PAYLOAD_WORDS;

  reg [31:0] payload_words [0:MAX_PAYLOAD_WORDS-1];
  reg [RX_COUNT_WIDTH-1:0] rx_index;
  reg [RX_COUNT_WIDTH-1:0] rx_expected_words;
  reg        rx_drop;
  reg        rx_is_v1;
  reg        rx_is_v2;
  reg        process_pending;
  reg        decode_pending;

  reg [31:0] play_bytes_per_channel;
  reg [31:0] play_flags;
  reg [3:0]  play_out_index;

  reg [31:0] cmd_opcode;
  reg [31:0] cmd_seq;
  reg [31:0] cmd_flags;
  reg [31:0] cmd_payload_bytes;
  reg [31:0] cmd_base;
  reg        cmd_version_valid;
  reg [4:0]  cmd_kind;

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
  reg        rfdc_payload_fields_invalid_latched;
  reg        network_response_pending;
  reg [31:0] network_response_sequence;
  reg [31:0] network_response_opcode;
  reg        resp_request_valid;
  reg [2:0]  resp_request_kind;
  reg [63:0] resp_request_magic;
  reg [15:0] resp_request_version;
  reg [31:0] resp_request_opcode;
  reg [15:0] resp_request_status;
  reg [31:0] resp_request_sequence;
  reg [31:0] resp_request_payload_bytes;
  reg [63:0] resp_request_payload0;
  reg [63:0] resp_request_payload1;
  reg        dbg_error_pending;

  wire instr_fire = m_instr_tvalid && m_instr_tready;
  wire out_can_load = !m_instr_tvalid || instr_fire;
  wire [31:0] rx_word_count_clean = rvctrl_word_count;
  wire [RX_COUNT_WIDTH-1:0] rx_word_count_narrow =
      rx_word_count_clean[RX_COUNT_WIDTH-1:0];
  wire        first_count_ok =
      !(|rx_word_count_clean[31:RX_COUNT_WIDTH]) &&
      (rx_word_count_narrow <= MAX_PAYLOAD_WORDS_COUNT);
  wire [RX_COUNT_WIDTH-1:0] active_rx_index =
      rvctrl_tfirst ? {RX_COUNT_WIDTH{1'b0}} : rx_index;
  wire [RX_COUNT_WIDTH-1:0] active_expected_words =
      rvctrl_tfirst ? rx_word_count_narrow : rx_expected_words;
  wire        active_count_ok = rvctrl_tfirst ? first_count_ok : !rx_drop;
  wire        active_drop = rvctrl_tfirst ? !active_count_ok : rx_drop;
  wire [RX_COUNT_WIDTH-1:0] active_second_index =
      active_rx_index + {{(RX_COUNT_WIDTH-1){1'b0}}, 1'b1};
  wire        active_second_word = active_second_index < active_expected_words;
  wire        active_channel_mask_word = active_second_index == 7'd5;
  wire        active_reserved_second =
      (active_second_index == 7'd11) ||
      (active_second_index == 7'd17) ||
      (active_second_index == 7'd23) ||
      (active_second_index == 7'd29) ||
      (active_second_index == 7'd35) ||
      (active_second_index == 7'd41) ||
      (active_second_index == 7'd47) ||
      (active_second_index == 7'd53);
  wire [RX_COUNT_WIDTH-1:0] active_words_after_beat = active_rx_index +
      (active_second_word ? {{(RX_COUNT_WIDTH-2){1'b0}}, 2'd2} :
                            {{(RX_COUNT_WIDTH-1){1'b0}}, 1'b1});
  wire        write_done = aw_done && w_done && b_done;
  wire [63:0] response_magic = rx_is_v2 ? RFRESP2_MAGIC : RVRESP1_MAGIC;
  wire [15:0] response_version = rx_is_v2 ? RF2_VERSION[15:0] : RV1_VERSION[15:0];

  integer i;
  integer r;
  integer p;
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

  function [4:0] decode_kind;
    input is_v1;
    input is_v2;
    input [31:0] opcode;
    begin
      decode_kind = DEC_UNSUPPORTED;
      if (is_v2) begin
        case (opcode)
          RF2_OP_HELLO: decode_kind = DEC_RF2_HELLO;
          RF2_OP_STATUS: decode_kind = DEC_RF2_STATUS;
          RF2_OP_NETWORK_GET: decode_kind = DEC_RF2_NETWORK_GET;
          RF2_OP_NETWORK_APPLY: decode_kind = DEC_RF2_NETWORK_APPLY;
          RF2_OP_NETWORK_RESTART: decode_kind = DEC_RF2_NETWORK_RESTART;
          RF2_OP_RFDC_APPLY: decode_kind = DEC_RF2_RFDC_APPLY;
          RF2_OP_RFDC_GET_CONFIG: decode_kind = DEC_RF2_RFDC_GET;
          RF2_OP_ARM: decode_kind = DEC_RF2_ARM;
          RF2_OP_SYNC_EPOCH: decode_kind = DEC_RF2_SYNC_EPOCH;
          RF2_OP_START_AT: decode_kind = DEC_RF2_START_AT;
          RF2_OP_TRIGGER: decode_kind = DEC_RF2_TRIGGER;
          RF2_OP_ABORT_MUTE: decode_kind = DEC_RF2_ABORT_MUTE;
          RF2_OP_SET_SYNC_ROLE: decode_kind = DEC_RF2_SET_SYNC_ROLE;
          RF2_OP_EMIT_TRIGGER: decode_kind = DEC_RF2_EMIT_TRIGGER;
          default: decode_kind = DEC_UNSUPPORTED;
        endcase
      end else if (is_v1) begin
        case (opcode)
          RV1_OP_PING: decode_kind = DEC_RV_PING;
          RV1_OP_PLAY_INTERLEAVED: decode_kind = DEC_RV_PLAY_INTERLEAVED;
          RV1_OP_TRIGGER: decode_kind = DEC_RV_TRIGGER;
          RV1_OP_MMIO_WRITE32: decode_kind = DEC_RV_WRITE_MMIO;
          RV1_OP_MMIO_READ32: decode_kind = DEC_RV1_MMIO_READ32;
          RV1_OP_MMIO_RMW32: decode_kind = DEC_RV1_MMIO_RMW32;
          RV1_OP_MMIO_BATCH: decode_kind = DEC_RV1_MMIO_BATCH;
          RV1_OP_RFDC_CH_ENABLE: decode_kind = DEC_RV1_RFDC_CH_ENABLE;
          RV1_OP_RFDC_SET_NCO: decode_kind = DEC_RV1_RFDC_SET_NCO;
          RV1_OP_STATUS_READ: decode_kind = DEC_RV1_STATUS_READ;
          default: decode_kind = DEC_UNSUPPORTED;
        endcase
      end else begin
        case (opcode)
          RV0_CMD_PING: decode_kind = DEC_RV_PING;
          RV0_CMD_PLAY_INTERLEAVED: decode_kind = DEC_RV_PLAY_INTERLEAVED;
          RV0_CMD_TRIGGER: decode_kind = DEC_RV_TRIGGER;
          RV0_CMD_WRITE_MMIO: decode_kind = DEC_RV_WRITE_MMIO;
          default: decode_kind = DEC_UNSUPPORTED;
        endcase
      end
    end
  endfunction

  task request_response;
    input [2:0]  kind;
    input [63:0] magic;
    input [15:0] version;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    input [31:0] payload_bytes;
    input [63:0] payload0;
    input [63:0] payload1;
    begin
      if (!resp_request_valid) begin
        resp_request_valid <= 1'b1;
        resp_request_kind <= kind;
        resp_request_magic <= magic;
        resp_request_version <= version;
        resp_request_opcode <= opcode;
        resp_request_status <= status_code;
        resp_request_sequence <= resp_seq;
        resp_request_payload_bytes <= payload_bytes;
        resp_request_payload0 <= payload0;
        resp_request_payload1 <= payload1;
      end else begin
        dbg_error_pending <= 1'b1;
      end
    end
  endtask

  task queue_resp0;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    begin
      request_response(RESP_REQ_0, response_magic, response_version, opcode, status_code, resp_seq, 32'd0, 64'd0, 64'd0);
    end
  endtask

  task queue_resp1;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    input [31:0] payload_bytes;
    input [63:0] payload0;
    begin
      request_response(RESP_REQ_1, response_magic, response_version, opcode, status_code, resp_seq, payload_bytes, payload0, 64'd0);
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
      request_response(RESP_REQ_2, response_magic, response_version, opcode, status_code, resp_seq, payload_bytes, payload0, payload1);
    end
  endtask

  task queue_rf2_status;
    input [31:0] opcode;
    input [31:0] resp_seq;
    begin
      request_response(RESP_REQ_STATUS, RFRESP2_MAGIC, RF2_VERSION[15:0], opcode, 16'h0000, resp_seq, 32'd112, 64'd0, 64'd0);
    end
  endtask

  task queue_rfdc_response;
    input [31:0] opcode;
    input [31:0] resp_seq;
    begin
      request_response(RESP_REQ_RFDC, RFRESP2_MAGIC, RF2_VERSION[15:0], opcode, 16'h0000, resp_seq, 32'd352, 64'd0, 64'd0);
    end
  endtask

  task queue_network_response;
    input [31:0] opcode;
    input [31:0] resp_seq;
    begin
      request_response(RESP_REQ_NETWORK, RFRESP2_MAGIC, RF2_VERSION[15:0], opcode, network_status, resp_seq, RF2_NETWORK_RESPONSE_BYTES, 64'd0, 64'd0);
    end
  endtask

  task load_resp0;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    begin
      if (!rvresp_tvalid) begin
        resp_words[0] <= resp_request_magic;
        resp_words[1] <= {opcode, status_code, resp_request_version};
        resp_words[2] <= {32'd0, resp_seq};
        resp_count <= 4'd3;
        resp_index <= 4'd0;
        rvresp_word_count <= 16'd3;
        rvresp_tdata <= resp_request_magic;
        rvresp_tvalid <= 1'b1;
        rvresp_tlast <= 1'b0;
      end else begin
        dbg_error_pending <= 1'b1;
      end
    end
  endtask

  task load_rf2_status;
    input [31:0] opcode;
    input [31:0] resp_seq;
    reg [31:0] state_flags;
    begin
      if (!rvresp_tvalid) begin
        state_flags = {
            23'd0, dac_mts_required, nco_sync_ready, dac_mts_failed, dac_mts_ready,
            playback_prepared, playback_running, playback_armed, rfdc_apply_busy, rfdc_ready
        };
        resp_words[0] <= resp_request_magic;
        resp_words[1] <= {opcode, 16'h0000, resp_request_version};
        resp_words[2] <= {resp_request_payload_bytes, resp_seq};
        resp_words[3] <= {state_flags, RF2_CAPABILITIES};
        resp_words[4] <= {rfdc_result_revision, 24'd0, rfdc_config_valid_mask};
        resp_words[5] <= {rfdc_failure_stage, 16'd0, rfdc_apply_status};
        resp_words[6] <= {32'd0, 14'd0, rfdc_failure_address};
        resp_words[7] <= {24'd0, play_fifo_valid_mask, 24'd0, play_config_channel_mask};
        resp_words[8] <= {24'd0, play_executor_state, 24'd0, play_fifo_ready_mask};
        resp_words[9] <= {play_bad_instr_count, play_ddr_read_counter};
        resp_words[10] <= {30'd0, play_active_valid, play_pending_valid, 31'd0, play_prefill_ready};
        resp_words[11] <= {
            nco_sync_epoch, dac_mts_error, 8'd0, dac_mts_tile_mask,
            1'b0, dac_mts_required, dac_mts_failed, dac_mts_ready
        };
        resp_words[12] <= {32'd0, 27'd0, sync_role_master, sync_bypass,
                            sync_link_ready, sync_seen};
        resp_words[13] <= {trigger_accepted_count, trigger_input_count};
        resp_words[14] <= {32'd0, trigger_output_count};
        // Appended strict-alignment state.  The low six bits are the
        // acknowledged hardware epoch; bits 22/23 are busy/failed.
        resp_words[15] <= {32'd0, 8'd0, sync_align_failed, sync_align_busy,
                           16'd0, sync_alignment_epoch};
        resp_words[16] <= {48'd0, sync_alignment_error};
        resp_count <= 6'd17;
        resp_index <= 6'd0;
        rvresp_word_count <= 16'd17;
        rvresp_tdata <= resp_request_magic;
        rvresp_tvalid <= 1'b1;
        rvresp_tlast <= 1'b0;
      end else begin
        dbg_error_pending <= 1'b1;
      end
    end
  endtask

  task load_rfdc_response;
    input [31:0] opcode;
    input [31:0] resp_seq;
    integer channel;
    integer base_word;
    reg [31:0] state_flags;
    begin
      if (!rvresp_tvalid) begin
        state_flags = {27'd0, playback_prepared, playback_running, playback_armed, rfdc_apply_busy, rfdc_ready};
        resp_words[0] <= resp_request_magic;
        resp_words[1] <= {
            opcode,
            (opcode == RF2_OP_RFDC_GET_CONFIG) ? 16'h0000 : rfdc_apply_status,
            resp_request_version
        };
        resp_words[2] <= {resp_request_payload_bytes, resp_seq};
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
        rvresp_tdata <= resp_request_magic;
        rvresp_tvalid <= 1'b1;
        rvresp_tlast <= 1'b0;
      end else begin
        dbg_error_pending <= 1'b1;
      end
    end
  endtask

  task load_network_response;
    input [31:0] opcode;
    input [31:0] resp_seq;
    reg [31:0] state_flags;
    begin
      if (!rvresp_tvalid) begin
        state_flags = network_status_flags;
        resp_words[0] <= resp_request_magic;
        resp_words[1] <= {opcode, resp_request_status, resp_request_version};
        resp_words[2] <= {resp_request_payload_bytes, resp_seq};
        resp_words[3] <= network_device_uid;
        resp_words[4] <= {network_bootstrap_ip, network_current_ip};
        resp_words[5] <= network_current_mac;
        resp_words[6] <= {{16{1'b0}}, network_link_state, network_current_port, network_result_revision};
        resp_words[7] <= {state_flags, network_capabilities};
        resp_words[8] <= network_bootstrap_mac;
        resp_words[9] <= {32'd0, network_current_subnet};
        resp_words[10] <= {32'd0, network_current_gateway};
        resp_words[11] <= {network_status_flags, BUILD_PROFILE_ID};
        resp_words[12] <= {56'd0, rfdc_config_valid_mask};
        resp_count <= 6'd13;
        resp_index <= 6'd0;
        rvresp_word_count <= 16'd13;
        rvresp_tdata <= resp_request_magic;
        rvresp_tvalid <= 1'b1;
        rvresp_tlast <= 1'b0;
      end else begin
        dbg_error_pending <= 1'b1;
      end
    end
  endtask

  task load_resp1;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    input [31:0] payload_bytes;
    input [63:0] payload0;
    begin
      if (!rvresp_tvalid) begin
        resp_words[0] <= resp_request_magic;
        resp_words[1] <= {opcode, status_code, resp_request_version};
        resp_words[2] <= {payload_bytes, resp_seq};
        resp_words[3] <= payload0;
        resp_count <= 4'd4;
        resp_index <= 4'd0;
        rvresp_word_count <= 16'd4;
        rvresp_tdata <= resp_request_magic;
        rvresp_tvalid <= 1'b1;
        rvresp_tlast <= 1'b0;
      end else begin
        dbg_error_pending <= 1'b1;
      end
    end
  endtask

  task load_resp2;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    input [31:0] payload_bytes;
    input [63:0] payload0;
    input [63:0] payload1;
    begin
      if (!rvresp_tvalid) begin
        resp_words[0] <= resp_request_magic;
        resp_words[1] <= {opcode, status_code, resp_request_version};
        resp_words[2] <= {payload_bytes, resp_seq};
        resp_words[3] <= payload0;
        resp_words[4] <= payload1;
        resp_count <= 4'd5;
        resp_index <= 4'd0;
        rvresp_word_count <= 16'd5;
        rvresp_tdata <= resp_request_magic;
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
      rfctrl2_set_sync_role_pulse <= 1'b0;
      rfctrl2_sync_role <= 32'd0;
      rfctrl2_sync_mode <= 32'd0;
      rfctrl2_emit_trigger_pulse <= 1'b0;
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
      network_apply_start <= 1'b0;
      network_apply_revision <= 32'd0;
      network_apply_ip <= 32'd0;
      network_apply_mac <= 64'd0;
      network_apply_subnet <= 32'd0;
      network_apply_gateway <= 32'd0;
      network_apply_port <= 16'd0;
      network_restart_start <= 1'b0;
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
      rx_index <= {RX_COUNT_WIDTH{1'b0}};
      rx_expected_words <= {RX_COUNT_WIDTH{1'b0}};
      rx_drop <= 1'b0;
      rx_is_v1 <= 1'b0;
      rx_is_v2 <= 1'b0;
      process_pending <= 1'b0;
      decode_pending <= 1'b0;
      play_bytes_per_channel <= 32'd0;
      play_flags <= 32'd0;
      play_out_index <= 4'd0;
      cmd_opcode <= 32'd0;
      cmd_seq <= 32'd0;
      cmd_flags <= 32'd0;
      cmd_payload_bytes <= 32'd0;
      cmd_base <= 32'd0;
      cmd_version_valid <= 1'b0;
      cmd_kind <= DEC_UNSUPPORTED;
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
      rfdc_payload_fields_invalid_latched <= 1'b0;
      network_response_pending <= 1'b0;
      network_response_sequence <= 32'd0;
      network_response_opcode <= RF2_OP_NETWORK_APPLY;
      resp_request_valid <= 1'b0;
      resp_request_kind <= RESP_REQ_NONE;
      resp_request_magic <= 64'd0;
      resp_request_version <= 16'd0;
      resp_request_opcode <= 32'd0;
      resp_request_status <= 16'd0;
      resp_request_sequence <= 32'd0;
      resp_request_payload_bytes <= 32'd0;
      resp_request_payload0 <= 64'd0;
      resp_request_payload1 <= 64'd0;
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
      rfctrl2_set_sync_role_pulse <= 1'b0;
      rfctrl2_emit_trigger_pulse <= 1'b0;
      rfdc_apply_start <= 1'b0;
      network_apply_start <= 1'b0;
      network_restart_start <= 1'b0;

      if (dbg_error_pending) begin
        dbg_error_count <= dbg_error_count + 32'd1;
        dbg_error_pending <= 1'b0;
      end

      if (resp_request_valid && !rvresp_tvalid) begin
        case (resp_request_kind)
          RESP_REQ_0: begin
            load_resp0(resp_request_opcode, resp_request_status, resp_request_sequence);
          end
          RESP_REQ_1: begin
            load_resp1(
                resp_request_opcode,
                resp_request_status,
                resp_request_sequence,
                resp_request_payload_bytes,
                resp_request_payload0
            );
          end
          RESP_REQ_2: begin
            load_resp2(
                resp_request_opcode,
                resp_request_status,
                resp_request_sequence,
                resp_request_payload_bytes,
                resp_request_payload0,
                resp_request_payload1
            );
          end
          RESP_REQ_STATUS: begin
            load_rf2_status(resp_request_opcode, resp_request_sequence);
          end
          RESP_REQ_RFDC: begin
            load_rfdc_response(resp_request_opcode, resp_request_sequence);
          end
          RESP_REQ_NETWORK: begin
            load_network_response(resp_request_opcode, resp_request_sequence);
          end
          default: begin
            dbg_error_pending <= 1'b1;
          end
        endcase
        resp_request_valid <= 1'b0;
        resp_request_kind <= RESP_REQ_NONE;
      end

      if (rfdc_response_pending && rfdc_apply_done) begin
        rfdc_response_pending <= 1'b0;
        queue_rfdc_response(rfdc_response_opcode, rfdc_response_sequence);
      end

      if (network_response_pending && network_done) begin
        network_response_pending <= 1'b0;
        queue_network_response(network_response_opcode, network_response_sequence);
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
          rx_index <= {RX_COUNT_WIDTH{1'b0}};
          rx_expected_words <= rx_word_count_narrow;
          rx_is_v1 <= (rvctrl_protocol == RVCTRL_PROTOCOL_V1);
          rx_is_v2 <= (rvctrl_protocol == RVCTRL_PROTOCOL_RF2);
          rx_drop <= !first_count_ok;
          rfdc_payload_fields_invalid_latched <= 1'b0;
          if (!first_count_ok) begin
            dbg_error_pending <= 1'b1;
          end
        end

        // RFCTRL2 RFDC_APPLY reserves the odd word at the end of every
        // six-word channel record. Track those words while receiving so the
        // command decoder does not build a wide payload-to-response path.
        if (active_count_ok && !active_drop &&
            ((active_channel_mask_word && (rvctrl_tdata[63:40] != 24'd0)) ||
             (active_reserved_second && (rvctrl_tdata[63:32] != 32'd0)))) begin
          rfdc_payload_fields_invalid_latched <= 1'b1;
        end

        if (active_count_ok && !active_drop &&
            (active_rx_index < MAX_PAYLOAD_WORDS_COUNT)) begin
          payload_words[active_rx_index] <= rvctrl_tdata[31:0];
        end
        if (active_count_ok && !active_drop && active_second_word &&
            (active_second_index < MAX_PAYLOAD_WORDS_COUNT)) begin
          payload_words[active_second_index] <= rvctrl_tdata[63:32];
        end
        if (active_rx_index < MAX_PAYLOAD_WORDS_COUNT)
          rx_index <= active_rx_index + {{(RX_COUNT_WIDTH-2){1'b0}}, 2'd2};
        else
          rx_index <= MAX_PAYLOAD_WORDS_COUNT;
        if (rvctrl_tlast) begin
          process_pending <= active_count_ok && !active_drop &&
                             (active_words_after_beat == active_expected_words);
          if (active_words_after_beat != active_expected_words)
            dbg_error_pending <= 1'b1;
        end
      end else if (process_pending) begin
        process_pending <= 1'b0;
        decode_pending <= 1'b1;
        dbg_state <= ST_PROCESS;

        if (rx_is_v2) begin
          cmd_flags <= {16'd0, payload_words[0][31:16]};
          cmd_opcode <= payload_words[1];
          cmd_seq <= payload_words[2];
          cmd_payload_bytes <= payload_words[3];
          cmd_base <= 32'd4;
          cmd_version_valid <= (payload_words[0][15:0] == RF2_VERSION[15:0]);
          cmd_kind <= decode_kind(1'b0, 1'b1, payload_words[1]);
          dbg_last_cmd <= payload_words[1];
          dbg_last_seq <= payload_words[2];
        end else if (rx_is_v1) begin
          cmd_flags <= {16'd0, payload_words[0][31:16]};
          cmd_opcode <= payload_words[1];
          cmd_seq <= payload_words[2];
          cmd_payload_bytes <= payload_words[3];
          cmd_base <= 32'd4;
          cmd_version_valid <= (payload_words[0][15:0] == RV1_VERSION[15:0]);
          cmd_kind <= decode_kind(1'b1, 1'b0, payload_words[1]);
          dbg_last_cmd <= payload_words[1];
          dbg_last_seq <= payload_words[2];
        end else begin
          cmd_flags <= 32'd0;
          cmd_opcode <= payload_words[0];
          cmd_seq <= payload_words[1];
          cmd_payload_bytes <= (rx_expected_words > 32'd2) ? ((rx_expected_words - 32'd2) << 2) : 32'd0;
          cmd_base <= 32'd2;
          cmd_version_valid <= 1'b1;
          cmd_kind <= decode_kind(1'b0, 1'b0, payload_words[0]);
          dbg_last_cmd <= payload_words[0];
          dbg_last_seq <= payload_words[1];
        end
      end else if (decode_pending) begin
        decode_pending <= 1'b0;
        dbg_state <= ST_PROCESS;

        if ((rx_is_v1 || rx_is_v2) && !cmd_version_valid) begin
          dbg_status <= 32'hBAD1_0001;
          dbg_error_pending <= 1'b1;
          queue_resp0(cmd_opcode, 16'h0001, cmd_seq);
        end else begin
          case (cmd_kind)
            DEC_RF2_HELLO: begin
              dbg_status <= 32'h2000_0001;
              queue_rf2_status(RF2_OP_HELLO, cmd_seq);
            end
            DEC_RF2_STATUS: begin
              dbg_status <= 32'h2000_0002;
              queue_rf2_status(RF2_OP_STATUS, cmd_seq);
            end
            DEC_RF2_NETWORK_GET: begin
              dbg_status <= 32'h2000_000C;
              queue_network_response(RF2_OP_NETWORK_GET, cmd_seq);
            end
            DEC_RF2_NETWORK_APPLY: begin
              if ((cmd_payload_bytes != RF2_NETWORK_APPLY_BYTES) ||
                  (rx_expected_words != 32'd12)) begin
                dbg_status <= 32'hBAD2_000D;
                queue_resp0(RF2_OP_NETWORK_APPLY, 16'h0003, cmd_seq);
              end else if (network_busy) begin
                dbg_status <= 32'hBAD2_100D;
                queue_resp0(RF2_OP_NETWORK_APPLY, 16'h0004, cmd_seq);
              end else begin
                network_apply_revision <= payload_words[4];
                network_apply_ip <= payload_words[5];
                network_apply_mac <= {payload_words[7], payload_words[6]};
                network_apply_subnet <= payload_words[8];
                network_apply_gateway <= payload_words[9];
                network_apply_port <= payload_words[10][15:0];
                network_apply_start <= 1'b1;
                network_response_pending <= 1'b1;
                network_response_sequence <= cmd_seq;
                network_response_opcode <= RF2_OP_NETWORK_APPLY;
                dbg_status <= 32'h2000_000D;
              end
            end
            DEC_RF2_NETWORK_RESTART: begin
              if (cmd_payload_bytes != 32'd0 || rx_expected_words != 32'd4) begin
                dbg_status <= 32'hBAD2_000E;
                queue_resp0(RF2_OP_NETWORK_RESTART, 16'h0003, cmd_seq);
              end else if (network_busy) begin
                dbg_status <= 32'hBAD2_100E;
                queue_resp0(RF2_OP_NETWORK_RESTART, 16'h0004, cmd_seq);
              end else begin
                network_restart_start <= 1'b1;
                network_response_pending <= 1'b1;
                network_response_sequence <= cmd_seq;
                network_response_opcode <= RF2_OP_NETWORK_RESTART;
                dbg_status <= 32'h2000_000E;
              end
            end
            DEC_RF2_RFDC_APPLY: begin
              if ((cmd_payload_bytes != RF2_RFDC_REQUEST_BYTES) ||
                  (rx_expected_words != 32'd54) ||
                  rfdc_payload_fields_invalid_latched) begin
                dbg_status <= 32'hBAD2_0003;
                dbg_error_pending <= 1'b1;
                queue_resp0(RF2_OP_RFDC_APPLY, 16'h0003, cmd_seq);
              end else if (!rfdc_ready || !dac_mts_ready || dac_mts_failed ||
                           sync_align_busy || sync_align_failed) begin
                dbg_status <= 32'hBAD2_2003;
                queue_resp0(RF2_OP_RFDC_APPLY, 16'h0005, cmd_seq);
              end else if (rfdc_apply_busy) begin
                dbg_status <= 32'hBAD2_0004;
                queue_resp0(RF2_OP_RFDC_APPLY, 16'h0004, cmd_seq);
              end else begin
                rfdc_apply_sequence <= cmd_seq;
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
                rfdc_response_sequence <= cmd_seq;
                rfdc_response_opcode <= RF2_OP_RFDC_APPLY;
                dbg_status <= 32'h2000_0003;
              end
            end
            DEC_RF2_RFDC_GET: begin
              queue_rfdc_response(RF2_OP_RFDC_GET_CONFIG, cmd_seq);
            end
            DEC_RF2_ARM: begin
              if (!rfdc_ready || !dac_mts_ready || dac_mts_failed || !nco_sync_ready ||
                  sync_align_busy || sync_align_failed) begin
                dbg_status <= 32'hBAD2_2006;
                queue_resp0(RF2_OP_ARM, 16'h0005, cmd_seq);
              end else if ((cmd_payload_bytes != 32'd8) ||
                  ((payload_words[5][7:0] & ~rfdc_config_valid_mask) != 8'd0)) begin
                dbg_status <= 32'hBAD2_0006;
                queue_resp0(RF2_OP_ARM, 16'h0006, cmd_seq);
              end else if (playback_armed || playback_prepared || playback_running) begin
                dbg_status <= 32'hBAD2_1006;
                queue_resp0(RF2_OP_ARM, 16'h0006, cmd_seq);
              end else begin
                rfctrl2_arm_pulse <= 1'b1;
                dbg_scratch <= payload_words[5];
                dbg_status <= 32'h2000_0006;
                queue_resp1(RF2_OP_ARM, 16'h0000, cmd_seq, 32'd8, {payload_words[5], payload_words[4]});
              end
            end
            DEC_RF2_SYNC_EPOCH: begin
              if ((cmd_payload_bytes != 32'd8) || !sync_role_master || sync_bypass) begin
                dbg_status <= 32'hBAD2_0007;
                queue_resp0(RF2_OP_SYNC_EPOCH, 16'h0006, cmd_seq);
              end else if (sync_align_busy && !sync_align_failed) begin
                dbg_status <= 32'hBAD2_1007;
                queue_resp0(RF2_OP_SYNC_EPOCH, 16'h0004, cmd_seq);
              end else begin
                rfctrl2_epoch <= {payload_words[5], payload_words[4]};
                rfctrl2_sync_epoch_pulse <= 1'b1;
                dbg_status <= 32'h2000_0007;
                queue_resp1(RF2_OP_SYNC_EPOCH, 16'h0000, cmd_seq, 32'd8, {payload_words[5], payload_words[4]});
              end
            end
            DEC_RF2_SET_SYNC_ROLE: begin
              if ((cmd_payload_bytes != 32'd8) ||
                  (payload_words[4] > 32'd1) || (payload_words[5] > 32'd1) ||
                  (payload_words[4][0] != sync_role_master) ||
                  playback_armed || playback_prepared || playback_running ||
                  sync_align_busy || sync_align_failed) begin
                dbg_status <= 32'hBAD2_000F;
                queue_resp0(RF2_OP_SET_SYNC_ROLE, 16'h0003, cmd_seq);
              end else begin
                rfctrl2_sync_role <= payload_words[4];
                rfctrl2_sync_mode <= payload_words[5];
                rfctrl2_set_sync_role_pulse <= 1'b1;
                dbg_status <= 32'h2000_000F;
                queue_resp0(RF2_OP_SET_SYNC_ROLE, 16'h0000, cmd_seq);
              end
            end
            DEC_RF2_EMIT_TRIGGER: begin
              if (cmd_payload_bytes != 32'd0) begin
                dbg_status <= 32'hBAD2_0010;
                queue_resp0(RF2_OP_EMIT_TRIGGER, 16'h0003, cmd_seq);
              end else if (sync_align_busy || sync_align_failed) begin
                dbg_status <= 32'hBAD2_1010;
                queue_resp0(RF2_OP_EMIT_TRIGGER, 16'h0006, cmd_seq);
              end else begin
                rfctrl2_emit_trigger_pulse <= 1'b1;
                dbg_status <= 32'h2000_0010;
                queue_resp0(RF2_OP_EMIT_TRIGGER, 16'h0000, cmd_seq);
              end
            end
            DEC_RF2_START_AT: begin
              rfctrl2_start_tick <= {payload_words[5], payload_words[4]};
              rfctrl2_start_valid <= 1'b1;
              dbg_status <= 32'h2000_0008;
              queue_resp1(RF2_OP_START_AT, 16'h0000, cmd_seq, 32'd8, {payload_words[5], payload_words[4]});
            end
            DEC_RF2_TRIGGER: begin
              if (!playback_prepared || !sync_link_ready || sync_align_busy || sync_align_failed) begin
                dbg_status <= 32'hBAD2_0009;
                queue_resp0(RF2_OP_TRIGGER, 16'h0006, cmd_seq);
              end else begin
                rfctrl2_trigger_pulse <= 1'b1;
                dbg_trigger_count <= dbg_trigger_count + 32'd1;
                dbg_status <= 32'h2000_0009;
                queue_resp0(RF2_OP_TRIGGER, 16'h0000, cmd_seq);
              end
            end
            DEC_RF2_ABORT_MUTE: begin
              rfctrl2_abort_mute_pulse <= 1'b1;
              dbg_status <= 32'h2000_000A;
              queue_resp0(RF2_OP_ABORT_MUTE, 16'h0000, cmd_seq);
            end
            DEC_RV_PING: begin
              dbg_status <= rx_is_v1 ? 32'h1000_0001 : 32'h0000_0001;
              dbg_ping_count <= dbg_ping_count + 32'd1;
              if (rx_is_v1) queue_resp0(RV1_OP_PING, 16'h0000, cmd_seq);
            end
            DEC_RV_PLAY_INTERLEAVED: begin
              if (payload_words[rx_is_v1 ? 4 : 2][4:0] != 5'd0) begin
                dbg_status <= 32'hBAD0_0002;
                dbg_error_pending <= 1'b1;
                if (rx_is_v1) queue_resp0(RV1_OP_PLAY_INTERLEAVED, 16'h0002, cmd_seq);
              end else begin
                play_bytes_per_channel <= payload_words[rx_is_v1 ? 4 : 2];
                play_flags <= payload_words[rx_is_v1 ? 5 : 3];
                play_out_index <= 4'd0;
                dbg_play_count <= dbg_play_count + 32'd1;
                dbg_status <= rx_is_v1 ? 32'h1000_0006 : 32'h0000_0002;
                dbg_state <= ST_OUT_PLAY;
              end
            end
            DEC_RV_TRIGGER: begin
              trigger_pulse <= 1'b1;
              dbg_trigger_count <= dbg_trigger_count + 32'd1;
              dbg_status <= rx_is_v1 ? 32'h1000_0007 : 32'h0000_0003;
              if (rx_is_v1) queue_resp0(RV1_OP_TRIGGER, 16'h0000, cmd_seq);
            end
            DEC_RV_WRITE_MMIO: begin
              if (ENABLE_UNSAFE_RFDC_MMIO) begin
                start_write(payload_words[rx_is_v1 ? 4 : 2], payload_words[rx_is_v1 ? 5 : 3]);
              end else begin
                dbg_status <= rx_is_v1 ? 32'hBAD1_0002 : 32'hBAD0_0001;
                dbg_error_pending <= 1'b1;
                if (rx_is_v1) queue_resp0(RV1_OP_MMIO_WRITE32, 16'h0002, cmd_seq);
              end
            end
            DEC_RV1_MMIO_READ32: begin
              start_read(payload_words[4]);
            end
            DEC_RV1_MMIO_RMW32: begin
              if (ENABLE_UNSAFE_RFDC_MMIO) begin
                mmio_mask <= payload_words[5];
                mmio_wdata <= payload_words[6];
                start_read(payload_words[4]);
              end else begin
                dbg_status <= 32'hBAD1_0002;
                dbg_error_pending <= 1'b1;
                queue_resp0(RV1_OP_MMIO_RMW32, 16'h0002, cmd_seq);
              end
            end
            DEC_RV1_MMIO_BATCH: begin
              if (ENABLE_UNSAFE_RFDC_MMIO) begin
                batch_count <= payload_words[4];
                batch_index <= 32'd0;
                dbg_state <= ST_BATCH_LOAD;
              end else begin
                dbg_status <= 32'hBAD1_0002;
                dbg_error_pending <= 1'b1;
                queue_resp0(RV1_OP_MMIO_BATCH, 16'h0002, cmd_seq);
              end
            end
            DEC_RV1_RFDC_CH_ENABLE: begin
              if (ENABLE_UNSAFE_RFDC_MMIO) begin
                dbg_scratch <= payload_words[4];
                dbg_status <= 32'h1000_0008;
                queue_resp1(RV1_OP_RFDC_CH_ENABLE, 16'h0000, cmd_seq, 32'd8, {payload_words[5], payload_words[4]});
              end else begin
                dbg_status <= 32'hBAD1_0002;
                dbg_error_pending <= 1'b1;
                queue_resp0(RV1_OP_RFDC_CH_ENABLE, 16'h0002, cmd_seq);
              end
            end
            DEC_RV1_RFDC_SET_NCO: begin
              if (ENABLE_UNSAFE_RFDC_MMIO) begin
                nco_apply_mask <= payload_words[4];
                nco_index <= 32'd0;
                nco_zone_accum <= 32'd0;
                dbg_state <= ST_NCO_SCAN;
              end else begin
                dbg_status <= 32'hBAD1_0002;
                dbg_error_pending <= 1'b1;
                queue_resp0(RV1_OP_RFDC_SET_NCO, 16'h0002, cmd_seq);
              end
            end
            DEC_RV1_STATUS_READ: begin
              dbg_status <= 32'h1000_000A;
              queue_resp2(
                  RV1_OP_STATUS_READ,
                  16'h0000,
                  cmd_seq,
                  32'd16,
                  {dbg_last_cmd, 32'h1000_000A},
                  {dbg_error_count, dbg_scratch}
              );
            end
            default: begin
              dbg_status <= rx_is_v1 ? 32'hBAD1_0002 : (rx_is_v2 ? 32'hBAD2_0002 : 32'hBAD0_0001);
              dbg_error_pending <= 1'b1;
              if (rx_is_v1 || rx_is_v2) queue_resp0(cmd_opcode, 16'h0002, cmd_seq);
            end
          endcase
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
