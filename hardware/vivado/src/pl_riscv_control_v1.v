`timescale 1ns / 1ps

// RFCTRL2 control-plane command processor.
//
// Receives the re-framed RFCTRL2 request words from udp_rvctrl_framer and
// serves the board-wide operations: HELLO/STATUS, structured RFDC apply and
// readback, runtime network identity, and TDC register access.  Waveform
// playback has its own WAVECTR0 protocol (waveform_upload_writer); nothing
// here can start, stop or arm playback.
//
// A request is stored whole, decoded one cycle later and answered through a
// two-entry response request queue, so a reply held up by ARP or by the
// previous response is not lost.  Operations that take time (RFDC apply,
// network apply/restart, TDC register) answer when the worker finishes.
module pl_riscv_control_v1 #(
    parameter integer MAX_PAYLOAD_WORDS = 64,
    parameter [31:0] BUILD_PROFILE_ID = 32'd1,
    parameter [31:0] TRIGGER_PATH_VERSION = 32'd3,
    parameter [31:0] SOURCE_COMMIT_ID = 32'd0,
    parameter integer TDC_REG_TIMEOUT_CYCLES = 1000000
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         rvctrl_tvalid,
    input  wire [63:0]  rvctrl_tdata,
    input  wire         rvctrl_tfirst,
    input  wire         rvctrl_tlast,
    input  wire [31:0]  rvctrl_word_count,

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
    input  wire [2:0]   ext_trigger_phase_slot,
    input  wire         ext_trigger_phase_valid,
    input  wire         ext_trigger_phase_overflow,
    input  wire         ext_trigger_phase_metastable,
    input  wire [7:0]   ext_trigger_tap_index,
    input  wire [15:0]  ext_trigger_phase_ps_x10,
    output reg          tdc_reg_valid,
    output reg          tdc_reg_write,
    output reg  [15:0]  tdc_reg_addr,
    output reg  [31:0]  tdc_reg_wdata,
    input  wire         tdc_reg_ready,
    input  wire [31:0]  tdc_reg_rdata,
    input  wire [15:0]  tdc_reg_error,
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
    // Playback observability reported in STATUS; owned by the waveform path.
    input  wire [7:0]  play_config_channel_mask,
    input  wire [7:0]  play_fifo_valid_mask,
    input  wire [7:0]  play_fifo_ready_mask,
    input  wire        play_prefill_ready,

    output reg  [63:0]  rvresp_tdata,
    output reg          rvresp_tvalid,
    input  wire         rvresp_tready,
    output reg          rvresp_tlast,
    output reg  [15:0]  rvresp_word_count
);

  localparam [31:0] RF2_OP_HELLO             = 32'h00000001;
  localparam [31:0] RF2_OP_STATUS            = 32'h00000002;
  localparam [31:0] RF2_OP_RFDC_APPLY        = 32'h00000003;
  localparam [31:0] RF2_OP_RFDC_GET_CONFIG   = 32'h0000000B;
  localparam [31:0] RF2_OP_NETWORK_GET       = 32'h0000000C;
  localparam [31:0] RF2_OP_NETWORK_APPLY     = 32'h0000000D;
  localparam [31:0] RF2_OP_NETWORK_RESTART   = 32'h0000000E;
  localparam [31:0] RF2_OP_TDC_REG           = 32'h00000011;
  // Capability bits advertised through HELLO/STATUS: PL RFDC config (16),
  // RFDC readback (17), runtime network identity (18), DAC MTS (19), NCO
  // sync (20) and the external Trigger input (22).
  localparam [31:0] RF2_CAPABILITIES         = 32'h005F0000;
  localparam [31:0] RF2_RFDC_REQUEST_BYTES   = 32'd200;
  localparam [31:0] RF2_NETWORK_APPLY_BYTES  = 32'd32;
  localparam [31:0] RF2_NETWORK_RESPONSE_BYTES = 32'd80;

  localparam [31:0] RF2_VERSION = 32'd3;
  localparam [63:0] RFRESP2_MAGIC = 64'h0032505345524652;

  localparam [15:0] RF2_STATUS_OK            = 16'h0000;
  localparam [15:0] RF2_STATUS_BAD_VERSION   = 16'h0001;
  localparam [15:0] RF2_STATUS_UNSUPPORTED   = 16'h0002;
  localparam [15:0] RF2_STATUS_BAD_REQUEST   = 16'h0003;
  localparam [15:0] RF2_STATUS_BUSY          = 16'h0004;
  localparam [15:0] RF2_STATUS_RFDC_NOT_READY = 16'h0005;
  localparam [15:0] RF2_STATUS_AXI_TIMEOUT   = 16'h0009;

  localparam [2:0] RESP_REQ_NONE    = 3'd0;
  localparam [2:0] RESP_REQ_0       = 3'd1;
  localparam [2:0] RESP_REQ_1       = 3'd2;
  localparam [2:0] RESP_REQ_STATUS  = 3'd4;
  localparam [2:0] RESP_REQ_RFDC    = 3'd5;
  localparam [2:0] RESP_REQ_NETWORK = 3'd6;
  localparam integer RX_COUNT_WIDTH = $clog2(MAX_PAYLOAD_WORDS + 1);
  localparam [RX_COUNT_WIDTH-1:0] MAX_PAYLOAD_WORDS_COUNT = MAX_PAYLOAD_WORDS;

  reg [31:0] payload_words [0:MAX_PAYLOAD_WORDS-1];
  reg [RX_COUNT_WIDTH-1:0] rx_index;
  reg [RX_COUNT_WIDTH-1:0] rx_expected_words;
  reg        rx_drop;
  reg        process_pending;
  reg        decode_pending;

  reg [31:0] cmd_opcode;
  reg [31:0] cmd_seq;
  reg [31:0] cmd_flags;
  reg [31:0] cmd_payload_bytes;
  reg        cmd_version_valid;

  reg [63:0] resp_words [0:47];
  reg [5:0]  resp_index;
  reg [5:0]  resp_count;
  reg        rfdc_response_pending;
  reg [31:0] rfdc_response_sequence;
  reg        rfdc_payload_fields_invalid_latched;
  reg        network_response_pending;
  reg [31:0] tdc_reg_timeout;
  reg [31:0] tdc_response_sequence;
  reg        tdc_response_pending;
  reg [31:0] tdc_response_data;
  reg [15:0] tdc_response_error;
  reg [31:0] network_response_sequence;
  reg [31:0] network_response_opcode;
  // Two-entry response request FIFO.  The UDP response TX path can be
  // temporarily occupied by ARP or a previous RFRESP2 frame; retaining one
  // additional decoded response prevents a back-to-back STATUS/HELLO request
  // from being silently discarded at this boundary.  A third response
  // arriving while both entries are held is dropped; the host retries.
  reg        resp_request_valid;
  reg [2:0]  resp_request_kind;
  reg [31:0] resp_request_opcode;
  reg [15:0] resp_request_status;
  reg [31:0] resp_request_sequence;
  reg [31:0] resp_request_payload_bytes;
  reg [63:0] resp_request_payload0;
  reg        resp_request_valid2;
  reg [2:0]  resp_request_kind2;
  reg [31:0] resp_request_opcode2;
  reg [15:0] resp_request_status2;
  reg [31:0] resp_request_sequence2;
  reg [31:0] resp_request_payload_bytes2;
  reg [63:0] resp_request_payload02;

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

  integer i;
  integer r;

  task request_response;
    input [2:0]  kind;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    input [31:0] payload_bytes;
    input [63:0] payload0;
    begin
      if (!resp_request_valid) begin
        resp_request_valid <= 1'b1;
        resp_request_kind <= kind;
        resp_request_opcode <= opcode;
        resp_request_status <= status_code;
        resp_request_sequence <= resp_seq;
        resp_request_payload_bytes <= payload_bytes;
        resp_request_payload0 <= payload0;
      end else if (!resp_request_valid2) begin
        resp_request_valid2 <= 1'b1;
        resp_request_kind2 <= kind;
        resp_request_opcode2 <= opcode;
        resp_request_status2 <= status_code;
        resp_request_sequence2 <= resp_seq;
        resp_request_payload_bytes2 <= payload_bytes;
        resp_request_payload02 <= payload0;
      end
    end
  endtask

  task queue_resp0;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    begin
      request_response(RESP_REQ_0, opcode, status_code, resp_seq, 32'd0, 64'd0);
    end
  endtask

  task queue_rf2_status;
    input [31:0] opcode;
    input [31:0] resp_seq;
    begin
      request_response(RESP_REQ_STATUS, opcode, RF2_STATUS_OK, resp_seq, 32'd128, 64'd0);
    end
  endtask

  task queue_rfdc_response;
    input [31:0] opcode;
    input [31:0] resp_seq;
    begin
      request_response(RESP_REQ_RFDC, opcode, RF2_STATUS_OK, resp_seq, 32'd352, 64'd0);
    end
  endtask

  task queue_network_response;
    input [31:0] opcode;
    input [31:0] resp_seq;
    begin
      request_response(RESP_REQ_NETWORK, opcode, network_status, resp_seq, RF2_NETWORK_RESPONSE_BYTES, 64'd0);
    end
  endtask

  // The loaders below run only while rvresp_tvalid is low.
  task start_response;
    input [5:0] words;
    begin
      resp_count <= words;
      resp_index <= 6'd0;
      rvresp_word_count <= {10'd0, words};
      rvresp_tdata <= RFRESP2_MAGIC;
      rvresp_tvalid <= 1'b1;
      rvresp_tlast <= 1'b0;
    end
  endtask

  task load_resp0;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    begin
      resp_words[0] <= RFRESP2_MAGIC;
      resp_words[1] <= {opcode, status_code, RF2_VERSION[15:0]};
      resp_words[2] <= {32'd0, resp_seq};
      start_response(6'd3);
    end
  endtask

  task load_resp1;
    input [31:0] opcode;
    input [15:0] status_code;
    input [31:0] resp_seq;
    input [31:0] payload_bytes;
    input [63:0] payload0;
    begin
      resp_words[0] <= RFRESP2_MAGIC;
      resp_words[1] <= {opcode, status_code, RF2_VERSION[15:0]};
      resp_words[2] <= {payload_bytes, resp_seq};
      resp_words[3] <= payload0;
      start_response(6'd4);
    end
  endtask

  // Fixed 128-byte STATUS/HELLO payload.  Words marked reserved carried the
  // retired instruction-executor and multi-board SYNC status; they stay in
  // the layout as zeros so every live field keeps its offset.
  task load_rf2_status;
    input [31:0] opcode;
    input [31:0] resp_seq;
    reg [31:0] state_flags;
    begin
      state_flags = {
          23'd0, dac_mts_required, nco_sync_ready, dac_mts_failed, dac_mts_ready,
          playback_prepared, playback_running, playback_armed, rfdc_apply_busy, rfdc_ready
      };
      resp_words[0] <= RFRESP2_MAGIC;
      resp_words[1] <= {opcode, RF2_STATUS_OK, RF2_VERSION[15:0]};
      resp_words[2] <= {resp_request_payload_bytes, resp_seq};
      resp_words[3] <= {state_flags, RF2_CAPABILITIES};
      resp_words[4] <= {rfdc_result_revision, 24'd0, rfdc_config_valid_mask};
      resp_words[5] <= {rfdc_failure_stage, 16'd0, rfdc_apply_status};
      resp_words[6] <= {32'd0, 14'd0, rfdc_failure_address};
      resp_words[7] <= {24'd0, play_fifo_valid_mask, 24'd0, play_config_channel_mask};
      resp_words[8] <= {32'd0, 24'd0, play_fifo_ready_mask};
      resp_words[9] <= 64'd0;                                   // reserved
      resp_words[10] <= {32'd0, 31'd0, play_prefill_ready};
      resp_words[11] <= {
          nco_sync_epoch, dac_mts_error, 8'd0, dac_mts_tile_mask,
          1'b0, dac_mts_required, dac_mts_failed, dac_mts_ready
      };
      // Payload bytes 76..79 are the trigger-path version.
      resp_words[12] <= {TRIGGER_PATH_VERSION, 32'd0};
      resp_words[13] <= 64'd0;                                  // reserved
      resp_words[14] <= 64'd0;                                  // reserved
      resp_words[15] <= 64'd0;                                  // reserved
      resp_words[16] <= {SOURCE_COMMIT_ID, BUILD_PROFILE_ID[15:0], 16'd0};
      resp_words[17] <= {
          32'd0,
          ext_trigger_phase_ps_x10,
          ext_trigger_tap_index,
          2'd0,
          ext_trigger_phase_metastable,
          ext_trigger_phase_overflow,
          ext_trigger_phase_valid,
          ext_trigger_phase_slot
      };
      resp_words[18] <= 64'd0;                                  // reserved
      start_response(6'd19);
    end
  endtask

  task load_rfdc_response;
    input [31:0] opcode;
    input [31:0] resp_seq;
    integer channel;
    integer base_word;
    reg [31:0] state_flags;
    begin
      state_flags = {27'd0, playback_prepared, playback_running, playback_armed, rfdc_apply_busy, rfdc_ready};
      resp_words[0] <= RFRESP2_MAGIC;
      resp_words[1] <= {
          opcode,
          (opcode == RF2_OP_RFDC_GET_CONFIG) ? 16'h0000 : rfdc_apply_status,
          RF2_VERSION[15:0]
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
      start_response(6'd47);
    end
  endtask

  task load_network_response;
    input [31:0] opcode;
    input [31:0] resp_seq;
    reg [31:0] state_flags;
    begin
      state_flags = network_status_flags;
      resp_words[0] <= RFRESP2_MAGIC;
      resp_words[1] <= {opcode, resp_request_status, RF2_VERSION[15:0]};
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
      start_response(6'd13);
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
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
      tdc_reg_valid <= 1'b0;
      tdc_reg_write <= 1'b0;
      tdc_reg_addr <= 16'd0;
      tdc_reg_wdata <= 32'd0;
      tdc_reg_timeout <= 32'd0;
      tdc_response_sequence <= 32'd0;
      tdc_response_pending <= 1'b0;
      tdc_response_data <= 32'd0;
      tdc_response_error <= 16'd0;
      rvresp_tdata <= 64'd0;
      rvresp_tvalid <= 1'b0;
      rvresp_tlast <= 1'b0;
      rvresp_word_count <= 16'd0;
      rx_index <= {RX_COUNT_WIDTH{1'b0}};
      rx_expected_words <= {RX_COUNT_WIDTH{1'b0}};
      rx_drop <= 1'b0;
      process_pending <= 1'b0;
      decode_pending <= 1'b0;
      cmd_opcode <= 32'd0;
      cmd_seq <= 32'd0;
      cmd_flags <= 32'd0;
      cmd_payload_bytes <= 32'd0;
      cmd_version_valid <= 1'b0;
      resp_index <= 6'd0;
      resp_count <= 6'd0;
      rfdc_response_pending <= 1'b0;
      rfdc_response_sequence <= 32'd0;
      rfdc_payload_fields_invalid_latched <= 1'b0;
      network_response_pending <= 1'b0;
      network_response_sequence <= 32'd0;
      network_response_opcode <= RF2_OP_NETWORK_APPLY;
      resp_request_valid <= 1'b0;
      resp_request_kind <= RESP_REQ_NONE;
      resp_request_opcode <= 32'd0;
      resp_request_status <= 16'd0;
      resp_request_sequence <= 32'd0;
      resp_request_payload_bytes <= 32'd0;
      resp_request_payload0 <= 64'd0;
      resp_request_valid2 <= 1'b0;
      resp_request_kind2 <= RESP_REQ_NONE;
      resp_request_opcode2 <= 32'd0;
      resp_request_status2 <= 16'd0;
      resp_request_sequence2 <= 32'd0;
      resp_request_payload_bytes2 <= 32'd0;
      resp_request_payload02 <= 64'd0;
      for (i = 0; i < MAX_PAYLOAD_WORDS; i = i + 1) begin
        payload_words[i] <= 32'd0;
      end
      for (i = 0; i < 48; i = i + 1) begin
        resp_words[i] <= 64'd0;
      end
    end else begin
      rfdc_apply_start <= 1'b0;
      network_apply_start <= 1'b0;
      network_restart_start <= 1'b0;

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
          end
        endcase
        if (resp_request_valid2) begin
          resp_request_kind <= resp_request_kind2;
          resp_request_opcode <= resp_request_opcode2;
          resp_request_status <= resp_request_status2;
          resp_request_sequence <= resp_request_sequence2;
          resp_request_payload_bytes <= resp_request_payload_bytes2;
          resp_request_payload0 <= resp_request_payload02;
          resp_request_valid2 <= 1'b0;
          resp_request_valid <= 1'b1;
        end else begin
          resp_request_valid <= 1'b0;
          resp_request_kind <= RESP_REQ_NONE;
        end
      end

      if (rfdc_response_pending && rfdc_apply_done) begin
        rfdc_response_pending <= 1'b0;
        queue_rfdc_response(RF2_OP_RFDC_APPLY, rfdc_response_sequence);
      end

      if (network_response_pending && network_done) begin
        network_response_pending <= 1'b0;
        queue_network_response(network_response_opcode, network_response_sequence);
      end

      if (tdc_reg_valid) begin
        if (tdc_reg_ready || tdc_reg_timeout >= TDC_REG_TIMEOUT_CYCLES - 1) begin
          tdc_reg_valid <= 1'b0;
          tdc_response_pending <= 1'b1;
          tdc_response_data <= tdc_reg_ready ? tdc_reg_rdata : 32'd0;
          tdc_response_error <= tdc_reg_ready ? tdc_reg_error : RF2_STATUS_AXI_TIMEOUT;
        end else begin
          tdc_reg_timeout <= tdc_reg_timeout + 32'd1;
        end
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

      if (rvctrl_tvalid && !rfdc_response_pending) begin
        if (rvctrl_tfirst) begin
          rx_index <= {RX_COUNT_WIDTH{1'b0}};
          rx_expected_words <= rx_word_count_narrow;
          rx_drop <= !first_count_ok;
          rfdc_payload_fields_invalid_latched <= 1'b0;
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
        // A request whose length does not match its header is dropped whole.
        if (rvctrl_tlast) begin
          process_pending <= active_count_ok && !active_drop &&
                             (active_words_after_beat == active_expected_words);
        end
      end else if (process_pending) begin
        process_pending <= 1'b0;
        decode_pending <= 1'b1;
        cmd_flags <= {16'd0, payload_words[0][31:16]};
        cmd_opcode <= payload_words[1];
        cmd_seq <= payload_words[2];
        cmd_payload_bytes <= payload_words[3];
        cmd_version_valid <= (payload_words[0][15:0] == RF2_VERSION[15:0]);
      end else if (tdc_response_pending && !resp_request_valid &&
                   !resp_request_valid2 &&
                   !(rfdc_response_pending && rfdc_apply_done) &&
                   !(network_response_pending && network_done)) begin
        // Queue completion separately so a following packet cannot change its sequence.
        request_response(RESP_REQ_1, RF2_OP_TDC_REG, tdc_response_error, tdc_response_sequence,
                         32'd8, {tdc_response_data, 16'd0, tdc_reg_addr});
        tdc_response_pending <= 1'b0;
      end else if (decode_pending) begin
        decode_pending <= 1'b0;

        if (!cmd_version_valid) begin
          queue_resp0(cmd_opcode, RF2_STATUS_BAD_VERSION, cmd_seq);
        end else begin
          case (cmd_opcode)
            RF2_OP_TDC_REG: begin
              if (cmd_payload_bytes != 32'd16 || rx_expected_words != 32'd8 ||
                  cmd_flags != 32'd0 || payload_words[4] > 32'd1 ||
                  payload_words[5][31:16] != 16'd0 ||
                  payload_words[5][1:0] != 2'd0 || payload_words[7] != 32'd0) begin
                queue_resp0(RF2_OP_TDC_REG, RF2_STATUS_BAD_REQUEST, cmd_seq);
              end else if (tdc_reg_valid || tdc_response_pending) begin
                queue_resp0(RF2_OP_TDC_REG, RF2_STATUS_BUSY, cmd_seq);
              end else begin
                tdc_reg_valid <= 1'b1;
                tdc_reg_write <= payload_words[4][0];
                tdc_reg_addr <= payload_words[5][15:0];
                tdc_reg_wdata <= payload_words[6];
                tdc_reg_timeout <= 32'd0;
                tdc_response_sequence <= cmd_seq;
              end
            end
            RF2_OP_HELLO: begin
              queue_rf2_status(RF2_OP_HELLO, cmd_seq);
            end
            RF2_OP_STATUS: begin
              queue_rf2_status(RF2_OP_STATUS, cmd_seq);
            end
            RF2_OP_NETWORK_GET: begin
              queue_network_response(RF2_OP_NETWORK_GET, cmd_seq);
            end
            RF2_OP_NETWORK_APPLY: begin
              if ((cmd_payload_bytes != RF2_NETWORK_APPLY_BYTES) ||
                  (rx_expected_words != 32'd12)) begin
                queue_resp0(RF2_OP_NETWORK_APPLY, RF2_STATUS_BAD_REQUEST, cmd_seq);
              end else if (network_busy) begin
                queue_resp0(RF2_OP_NETWORK_APPLY, RF2_STATUS_BUSY, cmd_seq);
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
              end
            end
            RF2_OP_NETWORK_RESTART: begin
              if (cmd_payload_bytes != 32'd0 || rx_expected_words != 32'd4) begin
                queue_resp0(RF2_OP_NETWORK_RESTART, RF2_STATUS_BAD_REQUEST, cmd_seq);
              end else if (network_busy) begin
                queue_resp0(RF2_OP_NETWORK_RESTART, RF2_STATUS_BUSY, cmd_seq);
              end else begin
                network_restart_start <= 1'b1;
                network_response_pending <= 1'b1;
                network_response_sequence <= cmd_seq;
                network_response_opcode <= RF2_OP_NETWORK_RESTART;
              end
            end
            RF2_OP_RFDC_APPLY: begin
              if ((cmd_payload_bytes != RF2_RFDC_REQUEST_BYTES) ||
                  (rx_expected_words != 32'd54) ||
                  rfdc_payload_fields_invalid_latched) begin
                queue_resp0(RF2_OP_RFDC_APPLY, RF2_STATUS_BAD_REQUEST, cmd_seq);
              end else if (!rfdc_ready || !dac_mts_ready || dac_mts_failed) begin
                queue_resp0(RF2_OP_RFDC_APPLY, RF2_STATUS_RFDC_NOT_READY, cmd_seq);
              end else if (rfdc_apply_busy) begin
                queue_resp0(RF2_OP_RFDC_APPLY, RF2_STATUS_BUSY, cmd_seq);
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
              end
            end
            RF2_OP_RFDC_GET_CONFIG: begin
              queue_rfdc_response(RF2_OP_RFDC_GET_CONFIG, cmd_seq);
            end
            default: begin
              queue_resp0(cmd_opcode, RF2_STATUS_UNSUPPORTED, cmd_seq);
            end
          endcase
        end
      end
    end
  end

endmodule
