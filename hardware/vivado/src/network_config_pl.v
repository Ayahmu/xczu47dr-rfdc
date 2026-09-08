`timescale 1ns / 1ps

// Runtime network identity for the normal RFDC bitstream.
//
// The reset identity is derived from the FPGA DNA so one bitstream can boot on
// multiple boards without colliding on the same initial MAC/IP. NETWORK_APPLY
// stages a host-assigned identity. NETWORK_RESTART commits it and pulses
// clear_arp_cache. Keeping the two operations separate lets the host receive
// the apply acknowledgement on the old IP.
module network_config_pl #(
    parameter [31:0] BOOTSTRAP_IP = 32'hC0A8FEFE,
    parameter [31:0] DEFAULT_IP = 32'hA9FEFEFE,
    parameter [63:0] DEFAULT_MAC = 64'h0200_0000_0000_0001,
    parameter [31:0] DEFAULT_SUBNET = 32'hFFFF0000,
    parameter [31:0] DEFAULT_GATEWAY = 32'h00000000,
    parameter [15:0] DEFAULT_PORT = 16'd1234,
    parameter INITIALIZE_FROM_DNA = 1'b1,
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
  reg [15:0] dna_ip_dna;
  reg dna_ready;
  reg dna_ready_sync1;
  reg dna_ready_sync2;
  reg [63:0] dna_uid_sync1;
  reg [63:0] dna_uid_sync2;
  reg [47:0] dna_mac_sync1;
  reg [47:0] dna_mac_sync2;
  reg [15:0] dna_ip_sync1;
  reg [15:0] dna_ip_sync2;

  // The bootstrap identity must remain unique even for devices whose low
  // 64 DNA bits happen to match.  Fold all 96 DNA bits before mapping them
  // into the link-local host portion of 169.254.0.0/16.
  wire [15:0] dna_ip_fold = dna_ip_sync2;
  wire [7:0] dna_ip_octet2 = ((dna_ip_fold[15:8] == 8'h00) || (dna_ip_fold[15:8] == 8'hFF))
      ? 8'hFE : dna_ip_fold[15:8];
  wire [7:0] dna_ip_octet3 = ((dna_ip_fold[7:0] == 8'h00) || (dna_ip_fold[7:0] == 8'hFF))
      ? 8'h7E : dna_ip_fold[7:0];
  wire [15:0] dna_ip_suffix = (dna_ip_fold == 16'hFA0B) ? 16'hFE7E :
                              {dna_ip_octet2, dna_ip_octet3};
  wire [31:0] dna_default_ip = {8'd169, 8'd254, dna_ip_suffix};
  wire [47:0] dna_default_mac = (dna_mac_sync2 == 48'd0)
      ? DEFAULT_MAC[47:0]
      : {8'h02, dna_mac_sync2[39:0]};

  // DNA_PORTE2 has a 205 MHz maximum clock specification. The DDR user
  // clock is 300 MHz in the normal target, so read the DNA in a dedicated
  // divided clock domain and synchronize the stable result back below.
  BUFGCE_DIV #(
      .BUFGCE_DIVIDE(2)
  ) dna_clk_div_i (
      .I  (clk),
      .CE (1'b1),
      .CLR(1'b0),
      .O  (dna_clk)
  );

  // The reader has its own reset release; resetting the clock divider with
  // the DDR-domain reset creates recovery/removal paths into a divided clock.
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] dna_reset_sync;
  always @(posedge dna_clk or negedge rst_n) begin
    if (!rst_n) dna_reset_sync <= 3'b000;
    else dna_reset_sync <= {dna_reset_sync[1:0], 1'b1};
  end
  wire dna_rst_n = dna_reset_sync[2];

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
      current_ip <= DEFAULT_IP;
      current_mac <= DEFAULT_MAC;
      current_subnet <= DEFAULT_SUBNET;
      current_gateway <= DEFAULT_GATEWAY;
      current_port <= DEFAULT_PORT;
      clear_arp_cache <= 1'b0;
      network_restart_pulse <= 1'b0;
      shadow_ip <= DEFAULT_IP;
      shadow_mac <= DEFAULT_MAC;
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
      dna_ip_sync1 <= 16'd0;
      dna_ip_sync2 <= 16'd0;
      dna_ready <= 1'b0;
      device_uid <= 64'd0;
      bootstrap_mac <= DEFAULT_MAC;
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
      dna_ip_sync1 <= dna_ip_dna;
      dna_ip_sync2 <= dna_ip_sync1;

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
        current_ip <= INITIALIZE_FROM_DNA ? dna_default_ip : BOOTSTRAP_IP;
        current_mac <= {16'd0, dna_default_mac};
        current_subnet <= INITIALIZE_FROM_DNA ? 32'hFFFF0000 : 32'hFFFFFF00;
        shadow_ip <= INITIALIZE_FROM_DNA ? dna_default_ip : BOOTSTRAP_IP;
        shadow_mac <= {16'd0, dna_default_mac};
        shadow_subnet <= INITIALIZE_FROM_DNA ? 32'hFFFF0000 : 32'hFFFFFF00;
        bootstrap_mac <= {16'd0, dna_default_mac};
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
  always @(posedge dna_clk or negedge dna_rst_n) begin
    if (!dna_rst_n) begin
      dna_read <= 1'b0;
      dna_shift <= 1'b0;
      dna_count <= 8'd0;
      dna_ready_dna <= 1'b0;
      dna_value_dna <= 96'd0;
      dna_uid_dna <= 64'd0;
      dna_mac_dna <= 48'd0;
      dna_ip_dna <= 16'd0;
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
          // Keep the established 64-bit UID wire contract.  Older boards can
          // still share this truncated value; software uses UID+MAC as the
          // discovery identity.  The bootstrap IP below uses all 96 bits.
          dna_uid_dna <= dna_value_dna[63:0];
          // Fold all 96 DNA bits into the locally administered MAC suffix
          // instead of exposing a raw DNA slice on the Ethernet network.
          dna_mac_dna <= dna_value_dna[31:0] ^
                         dna_value_dna[63:32] ^
                         dna_value_dna[95:64];
          dna_ip_dna <= dna_value_dna[15:0] ^ dna_value_dna[31:16] ^
                        dna_value_dna[47:32] ^ dna_value_dna[63:48] ^
                        dna_value_dna[79:64] ^ dna_value_dna[95:80];
          dna_ready_dna <= 1'b1;
        end
      end
    end
  end
endmodule
