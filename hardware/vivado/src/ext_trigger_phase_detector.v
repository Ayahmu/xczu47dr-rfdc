`timescale 1ns / 1ps

// External trigger phase detector for 250 MHz grid alignment.
//
// Problem: National shield's 250 MHz trigger grid (4 ns) vs our 50 MHz fabric
// clock (20 ns) creates 5 discrete phase slots: 0, 4, 8, 12, 16 ns within each
// beat, yielding 16 ns shot-to-shot jitter when the trigger interval is not a
// multiple of 20 ns.
//
// Solution: Oversample the external trigger at 200 MHz (5 ns resolution) to
// detect which of the 5 slots the edge falls into, then software compensates
// by shifting the waveform start in the 2.5 ns fabric sample grid.
//
// The 200 MHz domain captures 4 samples per 20 ns beat. Edge detection maps to:
//   Sample pattern [3:0] -> slot_id:
//     0001 -> slot 0 (edge at  0– 5 ns)
//     0010 -> slot 1 (edge at  5–10 ns, maps to 4 ns nominal)
//     0100 -> slot 2 (edge at 10–15 ns, maps to 8 ns nominal)
//     1000 -> slot 3 (edge at 15–20 ns, maps to 12 ns nominal)
//     x001 -> slot 4 (edge at 16–20 ns, wraps to next beat, maps to 16 ns)
//
// Output is latched at first detected edge and held until software reads it.
// A clear pulse resets the latch for the next measurement cycle.

module ext_trigger_phase_detector (
    input  wire       clk_50mhz,        // dac_axis_clk
    input  wire       clk_200mhz,       // 4× oversampling clock
    input  wire       rst_n,            // Active-low reset (50 MHz domain)

    input  wire       trigger_in,       // External trigger (async, from IBUF)
    input  wire       clear_latch,      // Pulse in 50 MHz domain to reset for next measurement

    output reg [2:0]  slot_id,          // 0–4: detected phase slot
    output reg        slot_valid        // 1 when slot_id holds a valid measurement
);

  // ================================================================
  // 200 MHz domain: capture 4 samples per 20 ns window
  // ================================================================
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg trigger_meta_200;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg trigger_sync_200;
  reg trigger_d1_200, trigger_d2_200, trigger_d3_200;

  always @(posedge clk_200mhz or negedge rst_n) begin
    if (!rst_n) begin
      trigger_meta_200 <= 1'b0;
      trigger_sync_200 <= 1'b0;
      trigger_d1_200   <= 1'b0;
      trigger_d2_200   <= 1'b0;
      trigger_d3_200   <= 1'b0;
    end else begin
      trigger_meta_200 <= trigger_in;
      trigger_sync_200 <= trigger_meta_200;
      trigger_d1_200   <= trigger_sync_200;
      trigger_d2_200   <= trigger_d1_200;
      trigger_d3_200   <= trigger_d2_200;
    end
  end

  // Edge detected when current sample is high and previous was low
  wire edge_200 = trigger_sync_200 && !trigger_d1_200;

  // 4-sample shift register captures the position within the 20 ns beat
  reg [3:0] sample_window_200;
  reg       edge_captured_200;
  reg [2:0] captured_slot_200;

  always @(posedge clk_200mhz or negedge rst_n) begin
    if (!rst_n) begin
      sample_window_200  <= 4'b0001;  // Rotating 1-hot marker
      edge_captured_200  <= 1'b0;
      captured_slot_200  <= 3'd0;
    end else begin
      // Rotate the window marker every cycle
      sample_window_200 <= {sample_window_200[2:0], sample_window_200[3]};

      // Latch the first edge we see, ignore subsequent edges until cleared
      if (edge_200 && !edge_captured_200) begin
        edge_captured_200 <= 1'b1;
        // Decode slot from window position
        case (sample_window_200)
          4'b0001: captured_slot_200 <= 3'd0;  //  0– 5 ns
          4'b0010: captured_slot_200 <= 3'd1;  //  5–10 ns (~ 4 ns)
          4'b0100: captured_slot_200 <= 3'd2;  // 10–15 ns (~ 8 ns)
          4'b1000: captured_slot_200 <= 3'd3;  // 15–20 ns (~12 ns)
          default: captured_slot_200 <= 3'd4;  // Edge near boundary -> slot 4 (16 ns)
        endcase
      end
    end
  end

  // ================================================================
  // CDC to 50 MHz domain: toggle-based transfer
  // ================================================================
  reg edge_captured_toggle_200;

  always @(posedge clk_200mhz or negedge rst_n) begin
    if (!rst_n)
      edge_captured_toggle_200 <= 1'b0;
    else if (edge_200 && !edge_captured_200)
      edge_captured_toggle_200 <= ~edge_captured_toggle_200;
  end

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg toggle_meta_50;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg toggle_sync_50;
  reg toggle_seen_50;
  reg [2:0] slot_id_50;
  reg slot_valid_50;

  always @(posedge clk_50mhz or negedge rst_n) begin
    if (!rst_n) begin
      toggle_meta_50  <= 1'b0;
      toggle_sync_50  <= 1'b0;
      toggle_seen_50  <= 1'b0;
      slot_id_50      <= 3'd0;
      slot_valid_50   <= 1'b0;
    end else begin
      toggle_meta_50 <= edge_captured_toggle_200;
      toggle_sync_50 <= toggle_meta_50;

      if (clear_latch) begin
        slot_valid_50 <= 1'b0;
      end else if (toggle_sync_50 != toggle_seen_50) begin
        toggle_seen_50 <= toggle_sync_50;
        slot_id_50     <= captured_slot_200;
        slot_valid_50  <= 1'b1;
      end
    end
  end

  always @(posedge clk_50mhz) begin
    slot_id    <= slot_id_50;
    slot_valid <= slot_valid_50;
  end

  // ================================================================
  // Clear signal crosses back to 200 MHz to reset the latch
  // ================================================================
  reg clear_toggle_50;

  always @(posedge clk_50mhz or negedge rst_n) begin
    if (!rst_n)
      clear_toggle_50 <= 1'b0;
    else if (clear_latch)
      clear_toggle_50 <= ~clear_toggle_50;
  end

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg clear_meta_200;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg clear_sync_200;
  reg clear_seen_200;

  always @(posedge clk_200mhz or negedge rst_n) begin
    if (!rst_n) begin
      clear_meta_200 <= 1'b0;
      clear_sync_200 <= 1'b0;
      clear_seen_200 <= 1'b0;
    end else begin
      clear_meta_200 <= clear_toggle_50;
      clear_sync_200 <= clear_meta_200;

      if (clear_sync_200 != clear_seen_200) begin
        clear_seen_200    <= clear_sync_200;
        edge_captured_200 <= 1'b0;  // Reset latch
      end
    end
  end

endmodule
