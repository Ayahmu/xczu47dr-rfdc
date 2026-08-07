`timescale 1ns/1ps

module tb_rfdc_runtime_config_pl;
  reg clk=0, rst_n=0;
  always #5 clk=~clk;
  reg start=0;
  reg [31:0] seq_num=0, revision=0;
  reg [7:0] mask=0;
  reg [511:0] nco_hz=0;
  reg [15:0] zones=0;
  reg [255:0] phases=0, currents=0;
  reg armed=0, running=0;
  wire busy, done, mute;
  wire [15:0] status;
  wire [31:0] result_revision;
  wire [7:0] applied_mask, error_mask, valid_mask;
  wire [31:0] failure_stage;
  wire [17:0] failure_address;
  wire [1:0] failure_response;
  wire ready;
  wire [511:0] actual_nco_hz, actual_nco_word;
  wire [15:0] actual_zone;
  wire [255:0] actual_phase, actual_current, channel_status, actual_phase_word, actual_vop;
  wire [17:0] awaddr, araddr;
  wire awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  wire [31:0] wdata;
  wire [3:0] wstrb;
  reg [1:0] bresp=0, rresp=0;
  reg [31:0] rdata=0;
  reg bvalid_reg=0, rvalid_reg=0;
  assign awready=1'b1;
  assign wready=1'b1;
  assign arready=1'b1;
  assign bvalid=bvalid_reg;
  assign rvalid=rvalid_reg;

  reg [15:0] memory [0:65535];
  integer write_count=0;
  integer write_count_before_retry=0;
  reg [17:0] inject_write_error_addr=18'h3ffff;
  reg nco_low_seen=0, update_seen=0, vop_seen=0;
  wire nco_commit_start;
  wire [7:0] nco_commit_mask;
  wire [383:0] nco_commit_freq_words;
  wire [143:0] nco_commit_phase_words;
  reg nco_commit_busy=0, nco_commit_done=0;
  reg [1:0] nco_commit_error=0;
  integer nco_commit_delay=0;
  integer nco_commit_count=0;

  rfdc_runtime_config_pl #(
    .CLOCK_HZ(1000000), .AXI_TIMEOUT_CYCLES(100), .READY_PROBE_INTERVAL_CYCLES(20)
  ) dut (
    .clk(clk), .rst_n(rst_n), .start(start), .cmd_sequence(seq_num), .cmd_revision(revision),
    .cmd_channel_mask(mask), .cmd_nco_hz(nco_hz), .cmd_nyquist_zone(zones),
    .cmd_phase_mdeg(phases), .cmd_current_ua(currents), .playback_armed(armed),
    .playback_running(running), .busy(busy), .done(done), .force_mute_pulse(mute),
    .status(status), .revision(result_revision), .applied_mask(applied_mask), .error_mask(error_mask),
    .config_valid_mask(valid_mask), .failure_stage(failure_stage), .failure_address(failure_address),
    .failure_axi_response(failure_response), .rfdc_ready(ready), .actual_nco_hz(actual_nco_hz),
    .actual_nyquist_zone(actual_zone), .actual_phase_mdeg(actual_phase),
    .actual_current_ua(actual_current), .channel_status(channel_status),
    .actual_nco_word(actual_nco_word), .actual_phase_word(actual_phase_word),
    .actual_vop_code(actual_vop),
    .nco_commit_start(nco_commit_start), .nco_commit_mask(nco_commit_mask),
    .nco_commit_freq_words(nco_commit_freq_words), .nco_commit_phase_words(nco_commit_phase_words),
    .nco_commit_busy(nco_commit_busy), .nco_commit_done(nco_commit_done),
    .nco_commit_error(nco_commit_error),
    .m_axil_awaddr(awaddr), .m_axil_awvalid(awvalid), .m_axil_awready(awready),
    .m_axil_wdata(wdata), .m_axil_wstrb(wstrb), .m_axil_wvalid(wvalid), .m_axil_wready(wready),
    .m_axil_bresp(bresp), .m_axil_bvalid(bvalid), .m_axil_bready(bready),
    .m_axil_araddr(araddr), .m_axil_arvalid(arvalid), .m_axil_arready(arready),
    .m_axil_rdata(rdata), .m_axil_rresp(rresp), .m_axil_rvalid(rvalid), .m_axil_rready(rready)
  );

  always @(posedge clk) begin
    if (!rst_n) begin bvalid_reg<=0; rvalid_reg<=0; end
    else begin
      if (awvalid && wvalid && awready && wready) begin
        if (wstrb !== 4'b0011) begin $display("FAIL: RFDC write did not use 16-bit WSTRB"); $finish; end
        write_count <= write_count + 1;
        memory[awaddr[17:2]] <= wdata[15:0];
        bresp <= (awaddr == inject_write_error_addr) ? 2'b10 : 2'b00;
        bvalid_reg <= 1;
        if (awaddr == 18'h0609c) nco_low_seen <= 1;
        if (awaddr == 18'h06020) update_seen <= 1;
        if (awaddr == 18'h061cc || awaddr == 18'h061d0) vop_seen <= 1;
      end else if (bvalid_reg && bready) bvalid_reg <= 0;
      if (arvalid && arready) begin
        rdata <= {16'd0, memory[araddr[17:2]]};
        rresp <= 2'b00;
        rvalid_reg <= 1;
      end else if (rvalid_reg && rready) rvalid_reg <= 0;
    end
  end

  always @(posedge clk) begin
    nco_commit_done <= 0;
    if (!rst_n) begin
      nco_commit_busy <= 0;
      nco_commit_delay <= 0;
      nco_commit_count <= 0;
    end else if (nco_commit_start && !nco_commit_busy) begin
      nco_commit_busy <= 1;
      nco_commit_delay <= 3;
      nco_commit_count <= nco_commit_count + 1;
    end else if (nco_commit_busy && nco_commit_delay == 0) begin
      nco_commit_busy <= 0;
      nco_commit_done <= 1;
    end else if (nco_commit_busy) begin
      nco_commit_delay <= nco_commit_delay - 1;
    end
  end

  task pulse_start;
    begin
      while (busy) @(negedge clk);
      @(negedge clk); start=1; @(negedge clk); start=0;
    end
  endtask
  task wait_done;
    integer timeout;
    begin
      timeout=0;
      while (!done && timeout < 5000) begin @(negedge clk); timeout=timeout+1; end
      if (!done) begin $display("FAIL: RFDC controller timed out in testbench"); $finish; end
    end
  endtask
  task check(input condition, input string message);
    begin if (!condition) begin $display("FAIL: %s", message); $finish; end end
  endtask

  initial begin
    integer i;
    for (i=0;i<65536;i=i+1) memory[i]=0;
    // DAC tile state 15 and a 20 mA-equivalent initial VOP code.
    memory[18'h0400c >> 2]=16'h000f;
    memory[18'h0800c >> 2]=16'h000f;
    memory[18'h0c00c >> 2]=16'h000f;
    memory[18'h1000c >> 2]=16'h000f;
    memory[18'h061d0 >> 2]=(425 << 6);
    repeat(5) @(negedge clk); rst_n=1;

    while (!ready) @(negedge clk);
    check(ready, "periodic probe did not detect four ready DAC tiles");
    memory[18'h0c00c >> 2]=16'h000e;
    repeat(50) @(negedge clk);
    check(!ready, "periodic probe did not clear readiness for a failed tile");
    memory[18'h0c00c >> 2]=16'h000f;
    repeat(50) @(negedge clk);
    check(ready, "periodic probe did not recover readiness after tile startup");

    seq_num=32'h55; revision=4; mask=8'h01;
    nco_hz[0 +: 64]=64'sd1600000000;
    zones[0 +: 2]=2'd2;
    phases[0 +: 32]=32'sd90000;
    currents[0 +: 32]=32'd20000;
    pulse_start(); wait_done();
    check(status == 0, "valid CH1 apply should succeed");
    check(applied_mask == 8'h01 && valid_mask[0], "CH1 masks were not confirmed");
    check(!nco_low_seen && !update_seen && vop_seen, "NCO must use RTS while VOP remains AXI-controlled");
    check(nco_commit_count == 1 && nco_commit_mask == 8'h01, "NCO RTS commit did not preserve the request mask");
    check(nco_commit_freq_words[0 +: 48] == 48'h400000000000, "NCO RTS frequency word mismatch");
    check(nco_commit_phase_words[0 +: 18] == 18'h10000, "NCO RTS phase word mismatch");
    check(memory[18'h061c4 >> 2][1] == 1'b1, "Nyquist zone RMW failed");
    check(actual_nco_word[0 +: 64] == 64'h0000400000000000, "1.6 GHz NCO word mismatch");
    check(actual_phase_word[0 +: 32] == 32'h00010000, "90 degree phase word mismatch");
    check($signed(actual_nco_hz[0 +: 64]) == 64'sd1600000000, "confirmed NCO Hz mismatch");
    check($signed(actual_phase[0 +: 32]) == 32'sd90000, "confirmed phase mismatch");

    // A current that already equals the quantized hardware value must still
    // pass readback without relying on stale expected VOP register values.
    seq_num=32'h56; revision=5;
    nco_hz[0 +: 64]=-64'sd1200000000;
    phases[0 +: 32]=-32'sd45000;
    currents[0 +: 32]=actual_current[0 +: 32];
    pulse_start(); wait_done();
    check(status == 0 && applied_mask == 8'h01, "unchanged quantized VOP should succeed");
    check(actual_nco_word[0 +: 64] == 64'h0000d00000000000, "negative NCO word mismatch");
    check(actual_phase_word[0 +: 32] == 32'h00038000, "negative phase word mismatch");
    check($signed(actual_nco_hz[0 +: 64]) == -64'sd1200000000, "negative confirmed NCO Hz mismatch");
    check($signed(actual_phase[0 +: 32]) == -32'sd45000, "negative confirmed phase mismatch");

    write_count_before_retry=write_count;
    pulse_start(); wait_done();
    check(write_count == write_count_before_retry, "duplicate sequence/revision repeated RFDC writes");

    // A new request that fails on CH2 Nyquist write must report an AXI error and remain muted.
    seq_num=32'h57; revision=6; mask=8'h02;
    nco_hz[64 +: 64]=64'sd0; zones[2 +: 2]=2'd1; phases[32 +: 32]=0; currents[32 +: 32]=20000;
    memory[18'h069d0 >> 2]=(425 << 6);
    inject_write_error_addr=18'h069c4;
    pulse_start(); wait_done();
    check(status == 16'h0008, "injected SLVERR was not reported");
    check(error_mask == 8'h02 && failure_address == 18'h069c4, "failure metadata mismatch");

    $display("PASS: PL RFDC controller stages NCO RTS, probes readiness, validates VOP/Nyquist, caches retries, and reports failures");
    $finish;
  end
endmodule
