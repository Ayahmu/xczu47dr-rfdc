`timescale 1ns/1ps

// Single-pulse board synchronization sequencer.
//
// role_master is deliberately a runtime signal. IS_MASTER remains the reset
// default so small legacy simulations can still use the original parameter.
module sync_role_control #(
    parameter integer IS_MASTER = 1,
    parameter integer WAIT_CYCLES = 100000,
    parameter integer HIGH_CYCLES = 100
) (
    input  wire clk,
    input  wire rst_n,
    input  wire sync_request,
    input  wire sync_in,
    input  wire role_master,
    input  wire self_sync,
    output wire hmc_sync,
    output wire slave_sync,
    output wire sync_done
);
  localparam integer WAIT_LAST = (WAIT_CYCLES < 1) ? 0 : WAIT_CYCLES - 1;
  localparam integer HIGH_LAST = (HIGH_CYCLES < 1) ? 0 : HIGH_CYCLES - 1;

  localparam [2:0] ST_IDLE = 3'd0;
  localparam [2:0] ST_WAIT = 3'd1;
  localparam [2:0] ST_HIGH = 3'd2;
  localparam [2:0] ST_DONE = 3'd3;

  reg sync_req_meta;
  reg sync_req_sync;
  reg sync_req_prev;
  reg sync_in_meta;
  reg sync_in_sync;
  reg sync_in_prev;
  reg role_master_d;
  reg self_sync_d;
  reg sync_pulse;
  reg sync_done_pulse;
  reg [2:0] state;
  reg [31:0] count;

  wire role_master_selected = role_master;
  wire role_changed = (role_master_selected != role_master_d);
  wire self_sync_rise = self_sync && !self_sync_d;
  wire sync_request_rise = sync_req_sync && !sync_req_prev;
  wire sync_input_rise = sync_in_sync && !sync_in_prev;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync_req_meta <= 1'b0;
      sync_req_sync <= 1'b0;
      sync_req_prev <= 1'b0;
      sync_in_meta <= 1'b0;
      sync_in_sync <= 1'b0;
      sync_in_prev <= 1'b0;
      role_master_d <= IS_MASTER ? 1'b1 : 1'b0;
      self_sync_d <= 1'b0;
    end else begin
      sync_req_meta <= sync_request;
      sync_req_sync <= sync_req_meta;
      sync_req_prev <= sync_req_sync;
      sync_in_meta <= sync_in;
      sync_in_sync <= sync_in_meta;
      sync_in_prev <= sync_in_sync;
      role_master_d <= role_master_selected;
      self_sync_d <= self_sync;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= (IS_MASTER ? ST_IDLE : ST_DONE);
      count <= 32'd0;
      sync_pulse <= 1'b0;
      sync_done_pulse <= 1'b0;
    end else begin
      sync_done_pulse <= 1'b0;

      // A role change starts a fresh epoch and cannot leak a pulse into the
      // newly selected direction.
      if (role_changed) begin
        state <= role_master_selected ? ST_IDLE : ST_DONE;
        count <= 32'd0;
        sync_pulse <= 1'b0;
      end else if (!role_master_selected) begin
        sync_pulse <= 1'b0;
        count <= 32'd0;
        state <= ST_DONE;
        if (self_sync_rise || sync_input_rise)
          sync_done_pulse <= 1'b1;
      end else begin
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
            state <= role_master_selected ? ST_IDLE : ST_DONE;
            count <= 32'd0;
            sync_pulse <= 1'b0;
          end
        endcase
      end
    end
  end

  // On a master, hmc_sync and slave_sync are the same one-pulse source. On a
  // slave, hmc_sync is the synchronized external pulse forwarded to HMC7044.
  assign hmc_sync = role_master_selected ? sync_pulse : sync_in_sync;
  assign slave_sync = role_master_selected ? sync_pulse : 1'b0;
  assign sync_done = sync_done_pulse;
endmodule
