`timescale 1ns/1ps

// Unified single-board playback admission and DAC gate controller.
//
// DDR upload and prefetch engines own descriptor/FIFO storage.  This block is
// intentionally only the DAC-domain control contract: it never opens the DAC
// gate before the prefetch engine reports a safe startup level, and it never
// advances a beat counter without a real AXI-stream fire.
module waveform_playback_controller (
    input  wire clk,
    input  wire rst_n,
    input  wire begin_cmd,
    input  wire commit_cmd,
    input  wire play_cmd,
    input  wire pause_cmd,
    input  wire stop_cmd,
    input  wire abort_cmd,
    input  wire trigger_event,
    input  wire prefetch_done,
    input  wire fifo_safe,
    input  wire fifo_empty,
    input  wire axi_error,
    input  wire beat_valid,
    input  wire beat_ready,
    input  wire beat_last,
    input  wire [31:0] loop_count,
    output reg [3:0] state,
    output wire dac_gate,
    output reg loop_restart,
    output reg [31:0] loop_position,
    output reg [31:0] trigger_seen_count,
    output reg [31:0] trigger_dropped_count,
    output reg [31:0] trigger_fire_count
);
  localparam [3:0] ST_IDLE         = 4'd0;
  localparam [3:0] ST_UPLOAD       = 4'd1;
  localparam [3:0] ST_READY        = 4'd2;
  localparam [3:0] ST_PREFETCH    = 4'd3;
  localparam [3:0] ST_WAIT_TRIGGER= 4'd4;
  localparam [3:0] ST_PLAYING     = 4'd5;
  localparam [3:0] ST_DRAINING    = 4'd6;
  localparam [3:0] ST_DONE        = 4'd7;
  localparam [3:0] ST_ERROR       = 4'd8;

  reg play_pending;
  wire stream_fire = (state == ST_PLAYING) && beat_valid && beat_ready;
  wire active_fault = ((state == ST_PREFETCH) || (state == ST_WAIT_TRIGGER) ||
                       (state == ST_PLAYING) || (state == ST_DRAINING)) &&
                      (axi_error || ((state == ST_PLAYING) && fifo_empty) ||
                       ((state == ST_WAIT_TRIGGER) && (!fifo_safe || fifo_empty)));
  // Admission is the actual state transition, not just the presence of an
  // event in WAIT_TRIGGER. Counting is orthogonal to the transition priority:
  // a rejected trigger must never suppress STOP, an AXI error, or underflow.
  wire trigger_admission = (state == ST_WAIT_TRIGGER) && trigger_event &&
                           !abort_cmd && !active_fault && !begin_cmd &&
                           !stop_cmd && !pause_cmd;

  assign dac_gate = (state == ST_PLAYING);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      play_pending <= 1'b0;
      trigger_seen_count <= 32'd0;
      trigger_dropped_count <= 32'd0;
      trigger_fire_count <= 32'd0;
      loop_restart <= 1'b0;
      loop_position <= 32'd0;
    end else begin
      loop_restart <= 1'b0;
      if (trigger_event) begin
        trigger_seen_count <= trigger_seen_count + 32'd1;
        if (trigger_admission)
          trigger_fire_count <= trigger_fire_count + 32'd1;
        else
          trigger_dropped_count <= trigger_dropped_count + 32'd1;
      end

      // Priority: reset, ABORT, active fault, replacement BEGIN, STOP/PAUSE,
      // then start/completion. ERROR is sticky except for ABORT/new upload.
      if (abort_cmd) begin
        state <= ST_IDLE;
        play_pending <= 1'b0;
        loop_position <= 32'd0;
      end else if (active_fault) begin
        state <= ST_ERROR;
        play_pending <= 1'b0;
      end else if (begin_cmd) begin
        state <= ST_UPLOAD;
        play_pending <= 1'b0;
        loop_position <= 32'd0;
      end else if (stop_cmd && state == ST_UPLOAD) begin
        state <= ST_IDLE;
        play_pending <= 1'b0;
        loop_position <= 32'd0;
      end else if ((stop_cmd || pause_cmd) &&
                   (state == ST_READY || state == ST_PREFETCH ||
                    state == ST_WAIT_TRIGGER || state == ST_PLAYING ||
                    state == ST_DRAINING || state == ST_DONE)) begin
        state <= ST_READY;
        play_pending <= 1'b0;
        loop_position <= 32'd0;
      end else begin
        case (state)
          ST_UPLOAD: if (commit_cmd) begin
            state <= ST_PREFETCH;
            play_pending <= 1'b0;
            loop_position <= 32'd0;
          end
          ST_READY, ST_DONE: if (play_cmd) begin
            state <= ST_PREFETCH;
            play_pending <= 1'b1;
            loop_position <= 32'd0;
            // Software PLAY from READY/DONE drains the FIFO on the prior pass,
            // so the DDR reader must refill the descriptor from beat 0.  Reuse
            // the loop-restart refill path (clear + re-arm) rather than letting
            // the raw play_cmd re-arm the reader: play_cmd also fires on the
            // WAIT_TRIGGER->PLAYING gate-open transition, where re-arming would
            // double-read the already-prefetched descriptor into a full FIFO.
            loop_restart <= 1'b1;
          end
          ST_PREFETCH: begin
            // Only software PLAY is retained during prefetch. Include PLAY
            // on the completion cycle; an external event is never queued.
            if (play_cmd) play_pending <= 1'b1;
            if (prefetch_done && fifo_safe) begin
              state <= (play_pending || play_cmd) ? ST_PLAYING : ST_WAIT_TRIGGER;
              play_pending <= 1'b0;
            end
          end
          ST_WAIT_TRIGGER: if (trigger_admission || play_cmd) begin
            state <= ST_PLAYING;
            play_pending <= 1'b0;
          end
          ST_PLAYING: if (stream_fire && beat_last) begin
            if (loop_count > 32'd1 && loop_position + 32'd1 < loop_count) begin
              // The current descriptor remains valid.  Ask the DDR domain to
              // clear/refill the FIFOs and automatically continue; a loop
              // boundary never re-enters WAIT_TRIGGER.
              state <= ST_PREFETCH;
              play_pending <= 1'b1;
              loop_position <= loop_position + 32'd1;
              loop_restart <= 1'b1;
            end else begin
              state <= ST_DRAINING;
              loop_position <= 32'd0;
            end
          end
          ST_DRAINING: state <= ST_DONE;
          ST_IDLE, ST_ERROR: begin end
          default: begin state <= ST_ERROR; play_pending <= 1'b0; end
        endcase
      end
    end
  end
endmodule
