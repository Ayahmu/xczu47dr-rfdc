`timescale 1ns/1ps

// Coherent request/acknowledge bridge for a multi-bit DAC-domain status record.
// The source record is held until the next request. The destination only
// presents snapshot_valid after both the request toggle and the held data have
// crossed their respective synchronizer delays; no status bit is synchronized
// independently as a live control signal.
module waveform_status_cdc #(
    parameter integer WIDTH = 296
) (
    input wire ddr_clk,
    input wire ddr_rst_n,
    input wire request_ddr,
    output wire request_ready_ddr,
    output reg snapshot_valid_ddr,
    output reg [WIDTH-1:0] snapshot_data_ddr,
    input wire dac_clk,
    input wire dac_rst_n,
    input wire [WIDTH-1:0] source_data_dac
);
  reg request_toggle_ddr;
  reg snapshot_busy_ddr;
  (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [2:0] ack_sync_ddr;
  reg ack_seen_ddr;
  reg ack_pending_ddr;
  (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [WIDTH-1:0] data_meta_ddr;
  reg [WIDTH-1:0] data_sync_ddr;

  reg [WIDTH-1:0] source_hold_dac;
  reg ack_toggle_dac;
  (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [2:0] request_sync_dac;
  reg request_seen_dac;

  assign request_ready_ddr = !snapshot_busy_ddr && !ack_pending_ddr;

  always @(posedge dac_clk or negedge dac_rst_n) begin
    if (!dac_rst_n) begin
      source_hold_dac <= {WIDTH{1'b0}};
      ack_toggle_dac <= 1'b0;
      request_sync_dac <= 3'b000;
      request_seen_dac <= 1'b0;
    end else begin
      request_sync_dac <= {request_sync_dac[1:0], request_toggle_ddr};
      if (request_sync_dac[2] != request_seen_dac) begin
        source_hold_dac <= source_data_dac;
        request_seen_dac <= request_sync_dac[2];
        ack_toggle_dac <= request_sync_dac[2];
      end
    end
  end

  always @(posedge ddr_clk or negedge ddr_rst_n) begin
    if (!ddr_rst_n) begin
      request_toggle_ddr <= 1'b0;
      snapshot_busy_ddr <= 1'b0;
      snapshot_valid_ddr <= 1'b0;
      snapshot_data_ddr <= {WIDTH{1'b0}};
      ack_sync_ddr <= 3'b000;
      ack_seen_ddr <= 1'b0;
      ack_pending_ddr <= 1'b0;
      data_meta_ddr <= {WIDTH{1'b0}};
      data_sync_ddr <= {WIDTH{1'b0}};
    end else begin
      ack_sync_ddr <= {ack_sync_ddr[1:0], ack_toggle_dac};
      data_meta_ddr <= source_hold_dac;
      data_sync_ddr <= data_meta_ddr;
      snapshot_valid_ddr <= 1'b0;

      if (request_ddr && request_ready_ddr) begin
        request_toggle_ddr <= ~request_toggle_ddr;
        snapshot_busy_ddr <= 1'b1;
      end

      if (snapshot_busy_ddr && !ack_pending_ddr && ack_sync_ddr[2] != ack_seen_ddr) begin
        ack_seen_ddr <= ack_sync_ddr[2];
        ack_pending_ddr <= 1'b1;
      end
      if (ack_pending_ddr) begin
        snapshot_data_ddr <= data_sync_ddr;
        snapshot_valid_ddr <= 1'b1;
        snapshot_busy_ddr <= 1'b0;
        ack_pending_ddr <= 1'b0;
      end
    end
  end
endmodule
