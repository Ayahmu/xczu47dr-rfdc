`timescale 1ns / 1ps
//
// ext_trigger_phase_compensator.v
//
// Compensates external trigger timing by delaying the launch by N fabric clock
// cycles (2.5 ns each at 400 MHz) based on the detected phase slot, achieving
// a fixed trigger-to-RF delay with zero jitter.
//
// Phase slot 0..7 corresponds to 8 possible alignments of the 200 MHz sample
// clock (5 ns period) relative to the 50 MHz DAC AXIS clock (20 ns period).
// The compensation table is designed so that after adding the slot-dependent
// delay, all triggers launch at the same AXIS beat phase.
//
// Example compensation strategy:
//   slot 0 -> delay 0 cycles (reference phase)
//   slot 1 -> delay 1 cycle  (+2.5 ns)
//   slot 2 -> delay 2 cycles (+5.0 ns)
//   slot 3 -> delay 3 cycles (+7.5 ns)
//   slot 4 -> delay 0 cycles (WrappingBackToReference)
//   slot 5 -> delay 1 cycle
//   slot 6 -> delay 2 cycles
//   slot 7 -> delay 3 cycles
//
// This assumes phase slots repeat every 4 slots modulo the 20 ns AXIS period.
// Adjust the LUT based on actual phase measurement if needed.

module ext_trigger_phase_compensator #(
    parameter MAX_DELAY_CYCLES = 7  // Maximum delay in fabric clock cycles
)(
    input  wire        clk_fabric,   // 400 MHz fabric sample clock
    input  wire        rst_n,

    input  wire        trigger_in,   // Uncompensated trigger from capture
    input  wire [2:0]  phase_slot,   // Detected phase slot (0..7)
    input  wire        phase_valid,  // High when phase slot is valid

    output reg         trigger_out   // Compensated trigger aligned to fixed phase
);

    // Compensation delay lookup table: maps phase_slot -> delay in fabric cycles
    // This table should be calibrated based on actual phase detector output.
    // For now, use a linear ramp that adds 2.5 ns per slot increment.
    function [2:0] get_delay_cycles;
        input [2:0] slot;
        begin
            case (slot)
                3'd0: get_delay_cycles = 3'd0;
                3'd1: get_delay_cycles = 3'd1;
                3'd2: get_delay_cycles = 3'd2;
                3'd3: get_delay_cycles = 3'd3;
                3'd4: get_delay_cycles = 3'd4;
                3'd5: get_delay_cycles = 3'd5;
                3'd6: get_delay_cycles = 3'd6;
                3'd7: get_delay_cycles = 3'd7;
            endcase
        end
    endfunction

    reg [2:0] delay_target;
    reg [2:0] delay_counter;
    reg       trigger_pending;

    always @(posedge clk_fabric or negedge rst_n) begin
        if (!rst_n) begin
            trigger_out     <= 1'b0;
            trigger_pending <= 1'b0;
            delay_counter   <= 3'd0;
            delay_target    <= 3'd0;
        end else begin
            trigger_out <= 1'b0;  // Single-cycle pulse output

            if (trigger_in && !trigger_pending) begin
                // New trigger arrives: latch the delay and start counting
                if (phase_valid) begin
                    delay_target    <= get_delay_cycles(phase_slot);
                    delay_counter   <= 3'd0;
                    trigger_pending <= 1'b1;
                end else begin
                    // Phase not valid yet: pass through immediately (no compensation)
                    trigger_out <= 1'b1;
                end
            end else if (trigger_pending) begin
                if (delay_counter >= delay_target) begin
                    // Delay complete: emit the compensated trigger
                    trigger_out     <= 1'b1;
                    trigger_pending <= 1'b0;
                end else begin
                    delay_counter <= delay_counter + 1'b1;
                end
            end
        end
    end

endmodule
