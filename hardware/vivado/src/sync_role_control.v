`timescale 1ns/1ps

// Synthesis-time role selection for the HMC7044 synchronization link.
// Master emits the two-pulse sequence; slave forwards the received pulse.
module sync_role_control #(
    parameter integer IS_MASTER = 1,
    parameter integer WAIT_CYCLES = 100000,
    parameter integer HIGH_CYCLES = 100
) (
    input  wire clk,
    input  wire rst_n,
    input  wire sync_request,
    input  wire sync_in,
    output wire hmc_sync,
    output wire slave_sync,
    output wire sync_done
);
  reg sync_out;
  reg slave_sync_out;

  generate
    if (IS_MASTER) begin : gen_master
      reg sync_req_meta;
      reg sync_req_sync;
      reg sync_req_prev;
      reg sync_pulse;
      reg sync_trig_d1;
      reg sync_trig_d2;
      reg sync_trig_d3;
      reg [2:0] sync_seq_state;
      reg [31:0] sync_seq_count;
      reg sync_done_pulse;

      localparam [2:0] SYNC_IDLE = 3'd0;
      localparam [2:0] SYNC_WAIT_FIRST = 3'd1;
      localparam [2:0] SYNC_HIGH_FIRST = 3'd2;
      localparam [2:0] SYNC_GAP = 3'd3;
      localparam [2:0] SYNC_HIGH_SECOND = 3'd4;
      localparam [2:0] SYNC_WAIT_END = 3'd5;

      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          sync_req_meta <= 1'b0;
          sync_req_sync <= 1'b0;
          sync_req_prev <= 1'b0;
        end else begin
          sync_req_meta <= sync_request;
          sync_req_sync <= sync_req_meta;
          sync_req_prev <= sync_req_sync;
        end
      end

      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          sync_done_pulse <= 1'b0;
        end else begin
          sync_done_pulse <= 1'b0;
          if (sync_seq_state == SYNC_WAIT_END && sync_seq_count == WAIT_CYCLES - 1)
            sync_done_pulse <= 1'b1;
        end
      end

      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          sync_seq_state <= SYNC_IDLE;
          sync_seq_count <= 32'd0;
          sync_pulse <= 1'b0;
        end else begin
          case (sync_seq_state)
            SYNC_IDLE: begin
              sync_seq_count <= 32'd0;
              sync_pulse <= 1'b0;
              if (sync_req_sync && !sync_req_prev)
                sync_seq_state <= SYNC_WAIT_FIRST;
            end
            SYNC_WAIT_FIRST: begin
              sync_pulse <= 1'b0;
              if (sync_seq_count == WAIT_CYCLES - 1) begin
                sync_seq_count <= 32'd0;
                sync_pulse <= 1'b1;
                sync_seq_state <= SYNC_HIGH_FIRST;
              end else begin
                sync_seq_count <= sync_seq_count + 1'b1;
              end
            end
            SYNC_HIGH_FIRST: begin
              sync_pulse <= 1'b1;
              if (sync_seq_count == HIGH_CYCLES - 1) begin
                sync_seq_count <= 32'd0;
                sync_pulse <= 1'b0;
                sync_seq_state <= SYNC_GAP;
              end else begin
                sync_seq_count <= sync_seq_count + 1'b1;
              end
            end
            SYNC_GAP: begin
              sync_pulse <= 1'b0;
              if (sync_seq_count == WAIT_CYCLES - 1) begin
                sync_seq_count <= 32'd0;
                sync_pulse <= 1'b1;
                sync_seq_state <= SYNC_HIGH_SECOND;
              end else begin
                sync_seq_count <= sync_seq_count + 1'b1;
              end
            end
            SYNC_HIGH_SECOND: begin
              sync_pulse <= 1'b1;
              if (sync_seq_count == HIGH_CYCLES - 1) begin
                sync_seq_count <= 32'd0;
                sync_pulse <= 1'b0;
                sync_seq_state <= SYNC_WAIT_END;
              end else begin
                sync_seq_count <= sync_seq_count + 1'b1;
              end
            end
            SYNC_WAIT_END: begin
              sync_pulse <= 1'b0;
              if (sync_seq_count == WAIT_CYCLES - 1) begin
                sync_seq_count <= 32'd0;
                sync_seq_state <= SYNC_IDLE;
              end else begin
                sync_seq_count <= sync_seq_count + 1'b1;
              end
            end
            default: begin
              sync_seq_state <= SYNC_IDLE;
              sync_seq_count <= 32'd0;
              sync_pulse <= 1'b0;
            end
          endcase
        end
      end

      // The slave receives the pulse one PL clock earlier than the local HMC.
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          sync_trig_d1 <= 1'b0;
          sync_trig_d2 <= 1'b0;
          sync_trig_d3 <= 1'b0;
        end else begin
          sync_trig_d1 <= sync_pulse;
          sync_trig_d2 <= sync_trig_d1;
          sync_trig_d3 <= sync_trig_d2;
        end
      end

      always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
          sync_out <= 1'b0;
          slave_sync_out <= 1'b0;
        end else begin
          sync_out <= sync_trig_d3;
          slave_sync_out <= sync_trig_d2;
        end
      end

      assign sync_done = sync_done_pulse;
    end else begin : gen_slave
      reg sync_in_meta;
      reg sync_in_sync;
      reg sync_in_prev;
      reg [1:0] slave_pulse_count;
      reg sync_done_pulse;

      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          sync_in_meta <= 1'b0;
          sync_in_sync <= 1'b0;
          sync_in_prev <= 1'b0;
          slave_pulse_count <= 2'd0;
          sync_done_pulse <= 1'b0;
        end else begin
          sync_in_meta <= sync_in;
          sync_in_sync <= sync_in_meta;
          sync_in_prev <= sync_in_sync;
          sync_done_pulse <= 1'b0;
          if (sync_in_sync && !sync_in_prev) begin
            if (slave_pulse_count == 2'd1) begin
              slave_pulse_count <= 2'd0;
              sync_done_pulse <= 1'b1;
            end else begin
              slave_pulse_count <= slave_pulse_count + 2'd1;
            end
          end
        end
      end

      always @* begin
        sync_out = sync_in;
        slave_sync_out = 1'b0;
      end

      assign sync_done = sync_done_pulse;
    end
  endgenerate

  assign hmc_sync = sync_out;
  assign slave_sync = slave_sync_out;
endmodule
