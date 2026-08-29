`timescale 1ns/1ps

// Single-pulse board synchronization sequencer.
//
// Single-pulse board synchronization sequencer in the PS pl_clk domain.
//
// role_master is fixed by the selected master/slave bitstream:
//   master  - emits one clean pulse on XS20 and drives its local HMC7044
//             SYNC one pl_clk cycle later, compensating the XS20 cable/IO
//             path as in the 0807 Type-C design.
//   slave   - forwards the received XS20 edge combinationally to HMC7044
//             SYNC.  The FPGA only adds a bounded, fixed propagation delay;
//             a separate synchronizer is used solely for sync_done status
//             and never feeds the HMC7044 SYNC pin.
module sync_role_control #(
    parameter integer IS_MASTER = 1,
    parameter integer WAIT_CYCLES = 20000,
    parameter integer HIGH_CYCLES = 40
) (
    input  wire clk,
    input  wire rst_n,
    input  wire sync_request,
    input  wire sync_in,
    input  wire role_master,
    input  wire sync_bypass,
    output wire hmc_sync,
    output wire slave_sync,
    output wire sync_done
);
  localparam integer WAIT_LAST = (WAIT_CYCLES < 1) ? 0 : WAIT_CYCLES - 1;
  localparam integer HIGH_LAST = (HIGH_CYCLES < 1) ? 0 : HIGH_CYCLES - 1;

  localparam [1:0] ST_IDLE = 2'd0;
  localparam [1:0] ST_WAIT = 2'd1;
  localparam [1:0] ST_HIGH = 2'd2;
  localparam [1:0] ST_DONE = 2'd3;

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] sync_in_sync;
  reg sync_in_prev;
  reg sync_req_prev;
  reg [1:0] state;
  reg [31:0] count;
  reg sync_pulse;
  reg sync_pulse_local_d;
  reg sync_done_pulse;

  wire sync_request_rise = sync_request && !sync_req_prev;
  wire sync_input_rise = sync_in_sync[1] && !sync_in_prev;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync_in_sync <= 2'b00;
      sync_in_prev <= 1'b0;
      sync_req_prev <= 1'b0;
      state <= IS_MASTER ? ST_IDLE : ST_DONE;
      count <= 32'd0;
      sync_pulse <= 1'b0;
      sync_pulse_local_d <= 1'b0;
      sync_done_pulse <= 1'b0;
    end else begin
      sync_in_sync <= {sync_in_sync[0], sync_in};
      sync_in_prev <= sync_in_sync[1];
      sync_req_prev <= sync_request;
      sync_pulse_local_d <= sync_pulse;
      sync_done_pulse <= 1'b0;

      if (role_master) begin
        case (state)
          ST_IDLE: begin
            sync_pulse <= 1'b0;
            count <= 32'd0;
            if (sync_request_rise)
              state <= ST_WAIT;
          end
          ST_WAIT: begin
            sync_pulse <= 1'b0;
            if (count >= WAIT_LAST) begin
              count <= 32'd0;
              sync_pulse <= 1'b1;
              state <= ST_HIGH;
            end else begin
              count <= count + 1'b1;
            end
          end
          ST_HIGH: begin
            sync_pulse <= 1'b1;
            if (count >= HIGH_LAST) begin
              count <= 32'd0;
              sync_pulse <= 1'b0;
              sync_done_pulse <= 1'b1;
              state <= ST_DONE;
            end else begin
              count <= count + 1'b1;
            end
          end
          ST_DONE: begin
            sync_pulse <= 1'b0;
            count <= 32'd0;
            if (sync_request_rise)
              state <= ST_WAIT;
          end
          default: begin
            state <= ST_IDLE;
            count <= 32'd0;
            sync_pulse <= 1'b0;
          end
        endcase
      end else begin
        // Slave: forward the received XS20 edge directly to HMC7044 SYNC.
        state <= ST_DONE;
        count <= 32'd0;
        sync_pulse <= 1'b0;
        if (sync_input_rise)
          sync_done_pulse <= 1'b1;
      end
    end
  end

  // Slave: combinational copy of the XS20 pad.  Master: local HMC7044 SYNC is
  // one pl_clk cycle behind the XS20 pulse so the slave path delay converges.
  assign hmc_sync = role_master ? sync_pulse_local_d : sync_in;
  assign slave_sync = role_master ? sync_pulse : 1'b0;
  assign sync_done = sync_done_pulse;

endmodule
