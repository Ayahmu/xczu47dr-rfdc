`timescale 1ns/1ps

module tb_rfdc_nco_rts_bridge;
  reg src_clk=0, rfdc_clk=0, src_rst_n=0, rfdc_rst_n=0;
  always #5 src_clk=~src_clk;
  always #7 rfdc_clk=~rfdc_clk;

  reg src_start=0;
  reg [7:0] src_mask=0;
  reg [383:0] src_freq=0;
  reg [143:0] src_phase=0;
  wire src_busy, src_done, src_ready;
  wire [1:0] src_error;
  wire [31:0] src_epoch;
  reg [4:0] tile_busy=0;
  wire [383:0] dac_freq;
  wire [143:0] dac_phase;
  wire [7:0] phase_reset;
  wire [47:0] update_enable;
  wire [3:0] tile_req;
  wire sysref_gating, sysref_reenable;
  integer busy_delay=0;
  integer req_count=0;
  reg [4:0] expected_busy_mask;
  reg respond_to_requests=1;

  rfdc_nco_rts_bridge #(.TIMEOUT_CYCLES(40)) dut (
    .src_clk(src_clk), .src_rst_n(src_rst_n), .src_start(src_start),
    .src_channel_mask(src_mask), .src_nco_freq(src_freq), .src_nco_phase(src_phase),
    .src_busy(src_busy), .src_done(src_done), .src_error(src_error),
    .src_sync_ready(src_ready), .src_sync_epoch(src_epoch),
    .rfdc_clk(rfdc_clk), .rfdc_rst_n(rfdc_rst_n),
    .rfdc_tile_update_busy(tile_busy),
    .dac_nco_freq(dac_freq), .dac_nco_phase(dac_phase),
    .dac_nco_phase_reset(phase_reset), .dac_nco_update_enable(update_enable),
    .dac_tile_update_req(tile_req),
    .dac_sysref_int_gating(sysref_gating),
    .dac_sysref_int_reenable(sysref_reenable)
  );

  // Model the vendor NCO FSMs. Packed busy bits are:
  // bit 0 Tile0 DRP, bit 1 Tile0 SYSREF gate, bits 2..4 Tiles 1..3 DRP.
  always @(posedge rfdc_clk) begin
    if (tile_req != 0) begin
      if (req_count == 0) begin
        if (tile_req !== 4'hF || phase_reset !== 8'hFF ||
            update_enable !== {8{6'h3f}} || !sysref_gating) begin
          $display("FAIL: full-mask RTS request did not hold gate, reset, and enables");
          $finish;
        end
        expected_busy_mask <= 5'b11111;
      end else if (req_count == 1) begin
        if (tile_req !== 4'h9 || phase_reset !== 8'h81 ||
            update_enable[0 +: 6] !== 6'h3f ||
            update_enable[42 +: 6] !== 6'h3f ||
            update_enable[6 +: 36] !== 36'd0 || !sysref_gating) begin
          $display("FAIL: disabled channels participated in sparse RTS commit");
          $finish;
        end
        expected_busy_mask <= 5'b10011;
      end else begin
        // Even when no Tile 0 converter changes, Tile 0 must receive an RTS
        // request to run the RFDC IP's global SYSREF gate sequence.
        if (tile_req !== 4'h9 || phase_reset !== 8'h80 ||
            update_enable[0 +: 42] !== 42'd0 ||
            update_enable[42 +: 6] !== 6'h3f || !sysref_gating) begin
          $display("FAIL: Tile 0 SYSREF gate was not retained for Tile 3-only RTS commit");
          $finish;
        end
        expected_busy_mask <= 5'b10011;
      end
      req_count <= req_count + 1;
      if (respond_to_requests)
        busy_delay <= 1;
    end else if (busy_delay == 1) begin
      tile_busy <= expected_busy_mask;
      busy_delay <= 2;
    end else if (busy_delay == 2) begin
      // DRP transactions finish while the Tile 0 SYSREF gate remains held.
      tile_busy <= expected_busy_mask & 5'b00010;
      busy_delay <= 3;
    end else if (busy_delay == 3 && sysref_reenable) begin
      tile_busy <= 5'd0;
      busy_delay <= 0;
    end
  end

  task check(input condition, input string message);
    begin if (!condition) begin $display("FAIL: %s", message); $finish; end end
  endtask

  initial begin
    integer timeout;
    src_mask=8'hFF;
    src_freq[0 +: 48]=48'h123456789abc;
    src_freq[336 +: 48]=48'hfedcba987654;
    src_phase[0 +: 18]=18'h12345;
    src_phase[126 +: 18]=18'h23456;
    repeat(4) @(negedge src_clk); src_rst_n=1; rfdc_rst_n=1;

    @(negedge src_clk); src_start=1; @(negedge src_clk); src_start=0;
    timeout=0;
    while (!src_done && timeout < 300) begin @(negedge src_clk); timeout=timeout+1; end
    check(src_done && src_error == 0 && src_ready, "full-mask RTS request did not acknowledge");
    check(src_epoch == 1 && req_count == 1, "RTS epoch/request count mismatch");
    check(dac_freq[0 +: 48] == 48'h123456789abc &&
          dac_freq[336 +: 48] == 48'hfedcba987654, "frequency payload changed across CDC");
    check(dac_phase[0 +: 18] == 18'h12345 &&
          dac_phase[126 +: 18] == 18'h23456, "phase payload changed across CDC");

    src_mask=8'h81;
    @(negedge src_clk); src_start=1; @(negedge src_clk); src_start=0;
    timeout=0;
    while (!src_done && timeout < 300) begin @(negedge src_clk); timeout=timeout+1; end
    check(src_done && src_error == 0 && src_epoch == 2, "sparse-channel RTS request failed");
    check(update_enable[0 +: 6] == 6'h00 && update_enable[6 +: 6] == 6'h00,
          "update enables must return idle after acknowledgement");
    check(dut.dst_channel_mask == 8'h81, "disabled channels were not preserved in destination mask");

    src_mask=8'h80;
    @(negedge src_clk); src_start=1; @(negedge src_clk); src_start=0;
    timeout=0;
    while (!src_done && timeout < 300) begin @(negedge src_clk); timeout=timeout+1; end
    check(src_done && src_error == 0 && src_epoch == 3,
          "Tile 3-only RTS request did not complete through the Tile 0 SYSREF gate");
    check(dut.dst_channel_mask == 8'h80,
          "Tile 3-only RTS request changed the enabled-channel mask");

    respond_to_requests=0;
    @(negedge src_clk); src_start=1; @(negedge src_clk); src_start=0;
    timeout=0;
    while (!src_done && timeout < 300) begin @(negedge src_clk); timeout=timeout+1; end
    check(src_done && src_error == 1 && !src_ready,
          "missing RFDC busy assertion did not fail closed");
    check(src_epoch == 3, "failed RTS request changed synchronization epoch");
    repeat(4) @(negedge rfdc_clk);
    check(!sysref_gating && !sysref_reenable,
          "failed RTS request did not release SYSREF control");
    $display("PASS: NCO RTS bridge gates SYSREF and commits enabled channels across four tiles");
    $finish;
  end
endmodule
