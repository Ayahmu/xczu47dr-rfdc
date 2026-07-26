`timescale 1ns / 1ps

// Runtime network identity for the normal RFDC bitstream.
//
// NETWORK_APPLY stages a validated identity. NETWORK_RESTART commits the
// staged identity and pulses clear_arp_cache. Keeping the two operations
// separate lets the host receive the apply acknowledgement on the old IP.
module network_config_pl #(
    parameter [31:0] BOOTSTRAP_IP = 32'hC0A8FEFE,
    parameter [31:0] DEFAULT_SUBNET = 32'hFFFFFF00,
    parameter [31:0] DEFAULT_GATEWAY = 32'h00000000,
    parameter [15:0] DEFAULT_PORT = 16'd1234,
    parameter integer RESTART_DELAY_CYCLES = 1024
) (
    input wire clk,
    input wire rst_n,
    input wire apply_start,
    input wire [31:0] apply_revision,
    input wire [31:0] apply_ip,
    input wire [63:0] apply_mac,
    input wire [31:0] apply_subnet,
    input wire [31:0] apply_gateway,
    input wire [15:0] apply_port,
    input wire restart_start,
    input wire playback_armed,
    input wire playback_prepared,
    input wire playback_running,
    output reg busy,
    output reg done,
    output reg [15:0] status,
    output reg [31:0] result_revision,
    output reg [31:0] current_ip,
    output reg [63:0] current_mac,
    output reg [31:0] current_subnet,
    output reg [31:0] current_gateway,
    output reg [15:0] current_port,
    output reg clear_arp_cache,
    output reg network_restart_pulse,
    output reg [63:0] device_uid,
    output reg [63:0] bootstrap_mac,
    output wire identity_ready
);

  localparam [15:0] STATUS_OK = 16'h0000;
  localparam [15:0] STATUS_BUSY = 16'h0004;
  localparam [15:0] STATUS_UNSAFE = 16'h0006;
  localparam [15:0] STATUS_RANGE = 16'h0007;

  reg [31:0] shadow_ip;
  reg [63:0] shadow_mac;
  reg [31:0] shadow_subnet;
  reg [31:0] shadow_gateway;
  reg [15:0] shadow_port;
  reg [31:0] shadow_revision;
  reg shadow_valid;
  reg restart_pending;
  reg operation_ack_pending;
  reg ack_release_busy;
  reg [$clog2(RESTART_DELAY_CYCLES + 1)-1:0] restart_count;

  wire dna_dout;
  wire dna_clk;
  reg dna_read;
  reg dna_shift;
  reg [7:0] dna_count;
  reg dna_ready_dna;
  reg [95:0] dna_value_dna;
  reg [63:0] dna_uid_dna;
  reg [47:0] dna_mac_dna;
  reg dna_ready;
  reg dna_ready_sync1;
  reg dna_ready_sync2;
  reg [63:0] dna_uid_sync1;
  reg [63:0] dna_uid_sync2;
  reg [47:0] dna_mac_sync1;
  reg [47:0] dna_mac_sync2;

  // DNA_PORTE2 has a 205 MHz maximum clock specification. The DDR user
  // clock is 300 MHz in the normal target, so read the DNA in a dedicated
  // divided clock domain and synchronize the stable result back below.
  BUFGCE_DIV #(
      .BUFGCE_DIVIDE(2)
  ) dna_clk_div_i (
      .I  (clk),
      .CE (1'b1),
      .CLR(~rst_n),
      .O  (dna_clk)
  );

  DNA_PORTE2 #(
      .SIM_DNA_VALUE(96'h0000_0000_0000_0000_47D0_0000)
  ) dna_i (
      .DOUT(dna_dout),
      .CLK(dna_clk),
      .DIN(1'b0),
      .READ(dna_read),
      .SHIFT(dna_shift)
  );

  assign identity_ready = dna_ready;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0;
      done <= 1'b0;
      status <= STATUS_OK;
      result_revision <= 32'd0;
      current_ip <= BOOTSTRAP_IP;
      // Keep a valid MAC on the Ethernet path while DNA_PORTE2 is being
      // shifted out. It is replaced with the DNA-derived identity once the
      // read completes.
      current_mac <= 64'h0200_0000_0000_0001;
      current_subnet <= DEFAULT_SUBNET;
      current_gateway <= DEFAULT_GATEWAY;
      current_port <= DEFAULT_PORT;
      clear_arp_cache <= 1'b0;
      network_restart_pulse <= 1'b0;
      shadow_ip <= BOOTSTRAP_IP;
      shadow_mac <= 64'd0;
      shadow_subnet <= DEFAULT_SUBNET;
      shadow_gateway <= DEFAULT_GATEWAY;
      shadow_port <= DEFAULT_PORT;
      shadow_revision <= 32'd0;
      shadow_valid <= 1'b0;
      restart_pending <= 1'b0;
      operation_ack_pending <= 1'b0;
      ack_release_busy <= 1'b0;
      restart_count <= 'd0;
      dna_ready_sync1 <= 1'b0;
      dna_ready_sync2 <= 1'b0;
      dna_uid_sync1 <= 64'd0;
      dna_uid_sync2 <= 64'd0;
      dna_mac_sync1 <= 48'd0;
      dna_mac_sync2 <= 48'd0;
      dna_ready <= 1'b0;
      device_uid <= 64'd0;
      bootstrap_mac <= 64'h0200_0000_0000_0001;
    end else begin
      done <= 1'b0;
      clear_arp_cache <= 1'b0;
      network_restart_pulse <= 1'b0;
      dna_ready_sync1 <= dna_ready_dna;
      dna_ready_sync2 <= dna_ready_sync1;
      dna_uid_sync1 <= dna_uid_dna;
      dna_uid_sync2 <= dna_uid_sync1;
      dna_mac_sync1 <= dna_mac_dna;
      dna_mac_sync2 <= dna_mac_sync1;

      // Delay the acknowledgement by one cycle. The RFCTRL2 decoder and
      // this block are clocked together; a same-cycle done pulse would be
      // observed one cycle too early by the decoder.
      if (operation_ack_pending) begin
        operation_ack_pending <= 1'b0;
        done <= 1'b1;
        if (ack_release_busy) begin
          busy <= 1'b0;
          ack_release_busy <= 1'b0;
        end
      end

      // Keep the old identity active while the RFRESP2 acknowledgement is
      // transmitted.  Only then commit the new identity and reset the
      // UDP/IP/ARP logic.  This prevents NETWORK_RESTART from destroying its
      // own acknowledgement packet.
      if (restart_pending) begin
        if (restart_count >= RESTART_DELAY_CYCLES - 1) begin
          current_ip <= shadow_ip;
          current_mac <= shadow_mac;
          current_subnet <= shadow_subnet;
          current_gateway <= shadow_gateway;
          current_port <= shadow_port;
          result_revision <= shadow_revision;
          clear_arp_cache <= 1'b1;
          network_restart_pulse <= 1'b1;
          restart_pending <= 1'b0;
          restart_count <= 'd0;
          busy <= 1'b0;
        end else begin
          restart_count <= restart_count + 1'b1;
        end
      end

      if (!dna_ready && dna_ready_sync2) begin
        device_uid <= dna_uid_sync2;
        bootstrap_mac <= {16'h0200, dna_mac_sync2[31:0]};
        current_mac <= {16'h0200, dna_mac_sync2[31:0]};
        dna_ready <= 1'b1;
      end

      if (!restart_pending && apply_start) begin
        if (busy) begin
          status <= STATUS_BUSY;
          operation_ack_pending <= 1'b1;
          ack_release_busy <= 1'b0;
        end else if (playback_armed || playback_prepared || playback_running) begin
          status <= STATUS_UNSAFE;
          operation_ack_pending <= 1'b1;
          ack_release_busy <= 1'b0;
        end else if ((apply_ip == 32'd0) || (apply_mac[47:0] == 48'd0) ||
                     (apply_mac[47:40] == 8'hFF) || apply_mac[40] ||
                     (apply_port == 16'd0) ||
                     (apply_subnet == 32'd0)) begin
          status <= STATUS_RANGE;
          operation_ack_pending <= 1'b1;
          ack_release_busy <= 1'b0;
        end else begin
          busy <= 1'b1;
          shadow_ip <= apply_ip;
          shadow_mac <= {16'd0, apply_mac[47:0]};
          shadow_subnet <= apply_subnet;
          shadow_gateway <= apply_gateway;
          shadow_port <= apply_port;
          shadow_revision <= apply_revision;
          shadow_valid <= 1'b1;
          result_revision <= apply_revision;
          status <= STATUS_OK;
          operation_ack_pending <= 1'b1;
          ack_release_busy <= 1'b1;
        end
      end else if (!restart_pending && restart_start) begin
        if (busy) begin
          status <= STATUS_BUSY;
          operation_ack_pending <= 1'b1;
          ack_release_busy <= 1'b0;
        end else if (playback_armed || playback_prepared || playback_running) begin
          status <= STATUS_UNSAFE;
          operation_ack_pending <= 1'b1;
          ack_release_busy <= 1'b0;
        end else if (shadow_valid) begin
          result_revision <= shadow_revision;
          restart_pending <= 1'b1;
          restart_count <= 'd0;
          busy <= 1'b1;
          status <= STATUS_OK;
          operation_ack_pending <= 1'b1;
          ack_release_busy <= 1'b0;
        end else begin
          status <= STATUS_OK;
          operation_ack_pending <= 1'b1;
          ack_release_busy <= 1'b0;
        end
      end
    end
  end

  // DNA_PORTE2 read/shift sequence. This state machine is deliberately kept
  // in the divided DNA clock domain; its outputs remain stable after the
  // one-time read and are synchronized into the network configuration clock.
  always @(posedge dna_clk or negedge rst_n) begin
    if (!rst_n) begin
      dna_read <= 1'b0;
      dna_shift <= 1'b0;
      dna_count <= 8'd0;
      dna_ready_dna <= 1'b0;
      dna_value_dna <= 96'd0;
      dna_uid_dna <= 64'd0;
      dna_mac_dna <= 48'd0;
    end else begin
      dna_read <= 1'b0;
      dna_shift <= 1'b0;
      if (!dna_ready_dna) begin
        if (dna_count == 8'd0) begin
          dna_read <= 1'b1;
          dna_count <= 8'd1;
        end else if (dna_count < 8'd97) begin
          dna_shift <= 1'b1;
          dna_value_dna <= {dna_value_dna[94:0], dna_dout};
          dna_count <= dna_count + 8'd1;
        end else begin
          dna_uid_dna <= dna_value_dna[63:0];
          // Fold all 96 DNA bits into the locally administered MAC suffix
          // instead of exposing a raw DNA slice on the Ethernet network.
          dna_mac_dna <= dna_value_dna[31:0] ^
                         dna_value_dna[63:32] ^
                         dna_value_dna[95:64];
          dna_ready_dna <= 1'b1;
        end
      end
    end
  end
endmodule
