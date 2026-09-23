`timescale 1ns/1ps

// Top-level WAVECTR0 end-to-end test.
//
// The DUT is the real TopCustomXczu47dr / Top RTL.  Only the external
// environment is modelled: the UDP MAC boundary (udp_10G), the DDR memory
// controller window (ddr_axi_smartconnect_wrapper), the RFDC DAC AXIS sinks and
// the board clock/reset infrastructure.  The test drives WAVECTR0 control
// packets into the real UDP receive port and checks the bytes that reach the
// eight RFDC DAC AXIS inputs, together with the response frames the design
// sends back over the modelled UDP transmit port.
module tb_top_waveform_e2e;
  localparam integer BEATS       = 4;
  localparam integer TOTAL_BYTES = BEATS * 256;
  localparam integer DATA_WORDS  = TOTAL_BYTES / 8;
  // CRC32 of the deterministic payload in UDP byte order.  This is kept as
  // a literal because Vivado xsim 2024.2 can return X or a stale value when
  // optimizing a 1024-iteration function call loop in a task; the independent
  // host calculation is 0x27db6422.  The payload layout functions below still
  // define and verify every transmitted/captured data word.
  localparam [31:0] PAYLOAD_CRC = 32'h27db6422;

  localparam [3:0] ST_IDLE = 4'd0, ST_UPLOAD = 4'd1, ST_READY = 4'd2,
                   ST_PREFETCH = 4'd3, ST_WAIT_TRIGGER = 4'd4,
                   ST_PLAYING = 4'd5, ST_DRAINING = 4'd6, ST_DONE = 4'd7,
                   ST_ERROR = 4'd8;

  localparam [31:0] OP_BEGIN = 32'd1, OP_DATA = 32'd2, OP_COMMIT = 32'd3,
                    OP_PLAY = 32'd4, OP_PAUSE = 32'd5, OP_STOP = 32'd6,
                    OP_ABORT = 32'd7, OP_STATUS = 32'd8;
  localparam [15:0] RESP_OK = 16'd0;

  `define TOP tb_top_waveform_e2e.dut.top_i

  reg         TRIG_2 = 1'b0;
  wire        TRIG_1;
  wire        RST_88E1111;
  wire        H7044_SLEN_0;
  wire        H7044_SCLK_0;
  wire        H7044_SDATA_0;
  wire        RESET_H7044_H_0;
  wire [0:0]  c0_ddr4_bg;
  wire [1:0]  c0_ddr4_ba;
  wire [16:0] c0_ddr4_adr;
  wire [0:0]  c0_ddr4_ck_c;
  wire [0:0]  c0_ddr4_ck_t;
  wire [0:0]  c0_ddr4_cke;
  wire [0:0]  c0_ddr4_cs_n;
  wire [0:0]  c0_ddr4_odt;
  wire        c0_ddr4_act_n;
  wire        c0_ddr4_reset_n;
  wire [7:0]  c0_ddr4_dm_n;
  wire [63:0] c0_ddr4_dq;
  wire [7:0]  c0_ddr4_dqs_c;
  wire [7:0]  c0_ddr4_dqs_t;
  wire        SFP_TX_DIS;
  wire        sfp_txp;
  wire        sfp_txn;
  wire        vout00_v_n, vout00_v_p;
  wire        vout02_v_n, vout02_v_p;
  wire        vout10_v_n, vout10_v_p;
  wire        vout12_v_n, vout12_v_p;
  wire        vout20_v_n, vout20_v_p;
  wire        vout22_v_n, vout22_v_p;
  wire        vout30_v_n, vout30_v_p;
  wire        vout32_v_n, vout32_v_p;

  TopCustomXczu47dr #(
      .IS_MASTER(1),
      .XS20_TRIG_OUT(0),
      .TRIG_EMIT_DAC(0)
  ) dut (
      .RESET_H7044_H_0(RESET_H7044_H_0),
      .H7044_SYNC_0(),
      .H7044_SLEN_0(H7044_SLEN_0),
      .H7044_SCLK_0(H7044_SCLK_0),
      .H7044_SDATA_0(H7044_SDATA_0),
      .RST_88E1111(RST_88E1111),
      .TRIG_1(TRIG_1),
      .TRIG_2(TRIG_2),
      .TRIG_3(),
      .PL_CLK_P_0(1'b0),
      .PL_CLK_N_0(1'b0),
      .PL_SYSREF_P_0(1'b0),
      .PL_SYSREF_N_0(1'b0),
      .EXT_TRIGGER_P(1'b0),
      .EXT_TRIGGER_N(1'b0),
      .sfp_refclkp(1'b0),
      .sfp_refclkn(1'b0),
      .sfp_rxp(1'b0),
      .sfp_rxn(1'b0),
      .sfp_txp(sfp_txp),
      .sfp_txn(sfp_txn),
      .SFP_TX_DIS(SFP_TX_DIS),
      .dac2_clk_clk_n(1'b0),
      .dac2_clk_clk_p(1'b0),
      .sysref_in_diff_n(1'b0),
      .sysref_in_diff_p(1'b0),
      .vout00_v_n(vout00_v_n), .vout00_v_p(vout00_v_p),
      .vout02_v_n(vout02_v_n), .vout02_v_p(vout02_v_p),
      .vout10_v_n(vout10_v_n), .vout10_v_p(vout10_v_p),
      .vout12_v_n(vout12_v_n), .vout12_v_p(vout12_v_p),
      .vout20_v_n(vout20_v_n), .vout20_v_p(vout20_v_p),
      .vout22_v_n(vout22_v_n), .vout22_v_p(vout22_v_p),
      .vout30_v_n(vout30_v_n), .vout30_v_p(vout30_v_p),
      .vout32_v_n(vout32_v_n), .vout32_v_p(vout32_v_p),
      .c0_sys_clk_n(1'b0), .c0_sys_clk_p(1'b0),
      .c0_ddr4_act_n(c0_ddr4_act_n),
      .c0_ddr4_adr(c0_ddr4_adr),
      .c0_ddr4_ba(c0_ddr4_ba),
      .c0_ddr4_bg(c0_ddr4_bg),
      .c0_ddr4_ck_c(c0_ddr4_ck_c),
      .c0_ddr4_ck_t(c0_ddr4_ck_t),
      .c0_ddr4_cke(c0_ddr4_cke),
      .c0_ddr4_cs_n(c0_ddr4_cs_n),
      .c0_ddr4_dm_n(c0_ddr4_dm_n),
      .c0_ddr4_dq(c0_ddr4_dq),
      .c0_ddr4_dqs_c(c0_ddr4_dqs_c),
      .c0_ddr4_dqs_t(c0_ddr4_dqs_t),
      .c0_ddr4_odt(c0_ddr4_odt),
      .c0_ddr4_reset_n(c0_ddr4_reset_n)
  );

  // ---------------------------------------------------------------------
  // Observed design signals
  // ---------------------------------------------------------------------
  wire        gate        = `TOP.wave_new_dac_gate;
  wire [3:0]  state_dac   = `TOP.wave_new_state;
  wire [7:0]  dac_valid   = `TOP.new_dac_valid;
  wire        first_xfer  = `TOP.new_output_first_transfer;
  wire [255:0] ch_data [0:7];
  assign ch_data[0] = `TOP.rfdc_ch1_tdata;
  assign ch_data[1] = `TOP.rfdc_ch2_tdata;
  assign ch_data[2] = `TOP.rfdc_ch3_tdata;
  assign ch_data[3] = `TOP.rfdc_ch4_tdata;
  assign ch_data[4] = `TOP.rfdc_ch5_tdata;
  assign ch_data[5] = `TOP.rfdc_ch6_tdata;
  assign ch_data[6] = `TOP.rfdc_ch7_tdata;
  assign ch_data[7] = `TOP.rfdc_ch8_tdata;
  wire [7:0]  ch_valid;
  assign ch_valid[0] = `TOP.rfdc_ch1_tvalid;
  assign ch_valid[1] = `TOP.rfdc_ch2_tvalid;
  assign ch_valid[2] = `TOP.rfdc_ch3_tvalid;
  assign ch_valid[3] = `TOP.rfdc_ch4_tvalid;
  assign ch_valid[4] = `TOP.rfdc_ch5_tvalid;
  assign ch_valid[5] = `TOP.rfdc_ch6_tvalid;
  assign ch_valid[6] = `TOP.rfdc_ch7_tvalid;
  assign ch_valid[7] = `TOP.rfdc_ch8_tvalid;
  wire        rfdc_ready = `TOP.rfdc_custom_i.rfdc_custom_xczu47dr_ip_i.sim_axis_ready;

  // ---------------------------------------------------------------------
  // UDP response monitor (decodes the real WAVERSP0 frames on the UDP TX port)
  // ---------------------------------------------------------------------
  integer    resp_count = 0;
  reg [4:0]  resp_idx   = 5'd0;
  reg [31:0] rx_opcode  = 32'hdead_beef;
  reg [31:0] rx_seq     = 32'hdead_beef;
  reg [15:0] rx_status  = 16'hdead;
  reg [15:0] rx_version = 16'hdead;
  reg        rx_magic_ok = 1'b0;
  reg        rx_tlast_ok = 1'b0;

  reg resp_skip = 1'b0;
  always @(posedge `TOP.ddr4_ui_clk) begin
    if (`TOP.udp_10g_i.resp64_tvalid && `TOP.udp_10g_i.resp64_tready) begin
      if (resp_skip) begin
        // Retained RFCTRL2 responses share the UDP transmit port; they are not
        // part of this contract, so drain them without decoding.
        if (`TOP.udp_10g_i.resp64_tlast) resp_skip <= 1'b0;
      end else if (resp_idx == 5'd0) begin
        if (`TOP.udp_10g_i.resp64_tdata == 64'h5741564552535030) begin
          rx_magic_ok <= 1'b1;
          rx_tlast_ok <= !`TOP.udp_10g_i.resp64_tlast;
          resp_idx <= 5'd1;
        end else begin
          resp_skip <= !`TOP.udp_10g_i.resp64_tlast;
        end
      end else begin
        if (resp_idx == 5'd1) begin
          rx_opcode  <= `TOP.udp_10g_i.resp64_tdata[63:32];
          rx_status  <= `TOP.udp_10g_i.resp64_tdata[31:16];
          rx_version <= `TOP.udp_10g_i.resp64_tdata[15:0];
        end
        if (resp_idx == 5'd2)
          rx_seq <= `TOP.udp_10g_i.resp64_tdata[31:0];
        if (`TOP.udp_10g_i.resp64_tlast) begin
          resp_count <= resp_count + 1;
          resp_idx   <= 5'd0;
        end else begin
          resp_idx <= resp_idx + 5'd1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------
  // DAC capture
  // ---------------------------------------------------------------------
  reg capture_en = 1'b0;
  integer cap_idx = 0;
  integer trig1_pulses = 0;
  reg [255:0] cap [0:BEATS*8-1];

  always @(posedge `TOP.dac_axis_clk) begin
    if (`TOP.new_output_first_transfer)
      trig1_pulses <= trig1_pulses + 1;
  end

  always @(posedge `TOP.dac_axis_clk) begin
    if (capture_en && gate && (dac_valid == 8'hff) && rfdc_ready) begin
      cap[cap_idx*8 + 0] <= ch_data[0];
      cap[cap_idx*8 + 1] <= ch_data[1];
      cap[cap_idx*8 + 2] <= ch_data[2];
      cap[cap_idx*8 + 3] <= ch_data[3];
      cap[cap_idx*8 + 4] <= ch_data[4];
      cap[cap_idx*8 + 5] <= ch_data[5];
      cap[cap_idx*8 + 6] <= ch_data[6];
      cap[cap_idx*8 + 7] <= ch_data[7];
      if (cap_idx == 0 && !`TOP.new_output_first_transfer)
        $fatal(1, "TRIG_1 must mark the first real DAC transfer");
      cap_idx <= cap_idx + 1;
    end
  end

  // ---------------------------------------------------------------------
  // Payload definition
  //
  // DDR layout: beat k, channel c, slice s lives at byte
  // (k*4 + s)*64 + c*8 and carries slice_word(c,k,s).  The reader turns the
  // four slices of one channel into a single 32-byte DAC beat, so the DAC word
  // expected for channel c at beat k is {s3,s2,s1,s0}.
  // ---------------------------------------------------------------------
  function automatic [63:0] slice_word(input integer c, input integer k, input integer s);
    begin
      slice_word = {8'hA0 | c[7:0], 8'hB0 | k[7:0], 8'hC0 | s[7:0],
                    8'hD0 | c[7:0], 8'hE0 | k[7:0], 8'hF0 | s[7:0],
                    8'h11, 8'h22};
    end
  endfunction

  function automatic [255:0] beat_word(input integer c, input integer k);
    begin
      beat_word = {slice_word(c, k, 3), slice_word(c, k, 2),
                   slice_word(c, k, 1), slice_word(c, k, 0)};
    end
  endfunction

  function automatic [7:0] payload_byte(input integer offset);
    integer ddr_beat, c, s, k, j;
    reg [63:0] word;
    begin
      ddr_beat = offset / 64;
      c        = (offset % 64) / 8;
      j        = offset % 8;
      k        = ddr_beat / 4;
      s        = ddr_beat % 4;
      word = slice_word(c, k, s);
      payload_byte = word[j*8 +: 8];
    end
  endfunction

  function automatic [63:0] payload_word(input integer i);
    integer ddr_beat, c, k, s;
    begin
      ddr_beat = i / 8;
      c        = i % 8;
      k        = ddr_beat / 4;
      s        = ddr_beat % 4;
      payload_word = slice_word(c, k, s);
    end
  endfunction

  // ---------------------------------------------------------------------
  // UDP injection
  // ---------------------------------------------------------------------
  task udp_word(input [63:0] data, input bit last);
    begin
      @(negedge `TOP.ddr4_ui_clk);
      `TOP.udp_10g_i.inj_valid = 1'b1;
      `TOP.udp_10g_i.inj_data  = data;
      `TOP.udp_10g_i.inj_last  = last;
      @(negedge `TOP.ddr4_ui_clk);
      `TOP.udp_10g_i.inj_valid = 1'b0;
      `TOP.udp_10g_i.inj_last  = 1'b0;
    end
  endtask

  task send_header(input integer op, input integer seq, input integer size);
    begin
      udp_word(64'h5741564543545230, 0);
      udp_word({op[31:0], 16'd0, 16'd1}, 0);
      udp_word({size[31:0], seq[31:0]}, 0);
    end
  endtask

  task send_begin_mask(input integer seq, input integer session, input integer mask);
    begin
      send_header(OP_BEGIN, seq, 28);
      udp_word({TOTAL_BYTES[31:0], session[31:0]}, 0);
      udp_word({16'd0, 8'd1, mask[7:0], 32'd0}, 0);
      udp_word({32'd1, BEATS[31:0]}, 0);
      udp_word({32'd0, 32'd64}, 1);
    end
  endtask

  task send_begin(input integer seq, input integer session);
    begin
      send_begin_mask(seq, session, 8'hff);
    end
  endtask

  task send_data(input integer req, input integer packet_seq, input integer session);
    integer i;
    begin
      send_header(OP_DATA, req, TOTAL_BYTES + 24);
      udp_word({packet_seq[31:0], session[31:0]}, 0);
      udp_word(64'd0, 0);
      udp_word({PAYLOAD_CRC, TOTAL_BYTES[31:0]}, 0);
      for (i = 0; i < DATA_WORDS; i = i + 1)
        udp_word(payload_word(i), i == DATA_WORDS-1);
    end
  endtask

  task send_simple(input integer op, input integer seq, input integer session);
    begin
      send_header(op, seq, 4);
      udp_word({32'd0, session[31:0]}, 1);
    end
  endtask

  task expect_response(input integer op, input integer status, input integer seq);
    integer t;
    integer n;
    begin
      n = resp_count;
      t = 0;
      while (resp_count == n && t < 40000) begin
        @(negedge `TOP.ddr4_ui_clk);
        t = t + 1;
      end
      if (resp_count == n)
        $fatal(1, "timeout waiting for response opcode %0d", op);
      if (!rx_magic_ok)   $fatal(1, "response frame magic mismatch");
      if (!rx_tlast_ok)   $fatal(1, "response frame started with TLAST");
      if (rx_version != 16'd1) $fatal(1, "response version %0d", rx_version);
      if (rx_opcode != op) $fatal(1, "response opcode %0d expected %0d", rx_opcode, op);
      if (rx_status != status)
        $fatal(1, "response opcode %0d status %0d expected %0d", op, rx_status, status);
      if (rx_seq != seq)
        $fatal(1, "response opcode %0d seq %0d expected %0d", op, rx_seq, seq);
    end
  endtask

  // ---------------------------------------------------------------------
  // Checks
  // ---------------------------------------------------------------------
  task check_silence(input string where);
    integer c;
    begin
      for (c = 0; c < 8; c = c + 1) begin
        if (ch_data[c] !== 256'd0)
          $fatal(1, "non-PLAYING channel %0d is not zero at %s", c+1, where);
        if (ch_valid[c] !== 1'b1)
          $fatal(1, "non-PLAYING channel %0d is not driving valid silence at %s", c+1, where);
      end
    end
  endtask

  task check_captured(input string where);
    integer k, c;
    begin
      if (cap_idx != BEATS)
        $fatal(1, "%s: captured %0d beats, expected %0d", where, cap_idx, BEATS);
      for (k = 0; k < BEATS; k = k + 1)
        for (c = 0; c < 8; c = c + 1)
          if (cap[k*8 + c] !== beat_word(c, k))
            $fatal(1, "%s: beat %0d channel %0d got %h expected %h",
                   where, k, c+1, cap[k*8 + c], beat_word(c, k));
    end
  endtask

  task check_captured_mask(input string where, input integer mask);
    integer k, c;
    begin
      if (cap_idx != BEATS)
        $fatal(1, "%s: captured %0d beats, expected %0d", where, cap_idx, BEATS);
      for (k = 0; k < BEATS; k = k + 1)
        for (c = 0; c < 8; c = c + 1) begin
          if (mask[c]) begin
            if (cap[k*8 + c] !== beat_word(c, k))
              $fatal(1, "%s: active beat %0d channel %0d got %h expected %h",
                     where, k, c+1, cap[k*8 + c], beat_word(c, k));
          end else if (cap[k*8 + c] !== 256'd0) begin
            $fatal(1, "%s: disabled beat %0d channel %0d is not zero (%h)",
                   where, k, c+1, cap[k*8 + c]);
          end
        end
    end
  endtask

  task start_capture;
    begin
      cap_idx    = 0;
      capture_en = 1'b1;
    end
  endtask

  task wait_for_state(input [3:0] st, input integer limit, input string where);
    integer t;
    begin
      t = 0;
      while (state_dac !== st && t < limit) begin
        @(negedge `TOP.dac_axis_clk);
        t = t + 1;
      end
      if (state_dac !== st)
        $fatal(1, "%s: timeout waiting for DAC state %0d (state=%0d)",
               where, st, state_dac);
    end
  endtask

  task pulse_trigger_narrow;
    begin
      @(negedge `TOP.dac_axis_clk);
      TRIG_2 = 1'b1;
      #8;
      TRIG_2 = 1'b0;
    end
  endtask

  task dac_quiet(input integer cycles);
    begin
      repeat (cycles) @(negedge `TOP.dac_axis_clk);
    end
  endtask

  // ---------------------------------------------------------------------
  // Retained RFDC configuration entry (RFCTRL2 RFDC_APPLY).
  //
  // The new single-board playback protocol does not configure the converter.
  // The retained RFDC configuration command is what authorises the RFDC
  // output gate, so the test must issue it before arming a waveform.  The
  // requested current is 20475 uA, which the configuration FSM resolves to
  // the same 1400 uA quiescent point the modelled converter reports, so the
  // VOP ramp is already complete and no extra DAC traffic is generated.
  // ---------------------------------------------------------------------
  localparam integer RFDC_APPLY_CURRENT_UA = 20475;

  task send_rfdc_apply(input integer seq);
    integer ch;
    begin
      udp_word(64'h00324C5254434652, 0);
      udp_word({32'd3, 32'd3}, 0);
      udp_word({32'd200, seq[31:0]}, 0);
      udp_word({24'd0, 8'h3F, 32'd0}, 0);
      for (ch = 0; ch < 8; ch = ch + 1) begin
        udp_word(64'd0, 0);
        udp_word({32'd0, 32'd1}, 0);
        udp_word({32'd0, RFDC_APPLY_CURRENT_UA[31:0]}, ch == 7);
      end
    end
  endtask

  task wait_rfdc_ready(input integer limit);
    integer t;
    begin
      t = 0;
      while (!`TOP.rfdc_runtime_ready && t < limit) begin
        @(negedge `TOP.ddr4_ui_clk);
        t = t + 1;
      end
      if (!`TOP.rfdc_runtime_ready)
        $fatal(1, "RFDC tile probe did not report ready (cfgstate=%0d)",
               `TOP.rfdc_runtime_config_pl_i.state);
    end
  endtask

  task wait_rfdc_permitted(input integer limit);
    integer t;
    begin
      t = 0;
      while (!`TOP.rfdc_output_permitted_dac && t < limit) begin
        @(negedge `TOP.ddr4_ui_clk);
        t = t + 1;
      end
      if (!`TOP.rfdc_output_permitted_dac)
        $fatal(1, "RFDC output never permitted (apply_status=%h ready=%b mts_req=%b mts_rdy=%b)",
               `TOP.rfdc_apply_status, `TOP.rfdc_runtime_ready,
               `TOP.dac_mts_required, `TOP.dac_mts_ready);
    end
  endtask

  // ---------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------
  integer fifo_levels [0:7];
  integer c;

  initial begin
    TRIG_2 = 1'b0;

    wait (`TOP.ddr4_ui_aresetn === 1'b1);
    wait (`TOP.dac_rst_n === 1'b1);
    dac_quiet(64);
    $display("[%0t] resets released, checking idle silence", $time);
    check_silence("idle");

    // ---- RFDC readiness bootstrap -------------------------------------
    // The PL RFDC-ready interlock is established by a periodic tile probe
    // whose interval is READY_PROBE_INTERVAL_CYCLES = CLOCK_HZ (300120048 DDR
    // clocks, about 1.2 s), and RFDC_APPLY is refused until that probe has
    // run.  Simulating 1.2 s of the full design is not feasible, so the test
    // short-circuits only the *timer*: ready_probe_count is forced to zero for
    // one clock, after which the design itself performs the real four-tile
    // AXI probe and sets rfdc_ready.  No readiness flag is forced.
    force `TOP.rfdc_runtime_config_pl_i.ready_probe_count = 32'd0;
    @(negedge `TOP.ddr4_ui_clk);
    release `TOP.rfdc_runtime_config_pl_i.ready_probe_count;
    wait_rfdc_ready(20000);

    // ---- retained RFDC configuration ----------------------------------
    send_rfdc_apply(32'h100);
    wait_rfdc_permitted(200000);
    $display("[%0t] RFDC configuration applied and output permitted", $time);

    // ---- upload -------------------------------------------------------
    send_begin(1, 1);
    expect_response(OP_BEGIN, RESP_OK, 1);
    send_data(2, 0, 1);
    expect_response(OP_DATA, RESP_OK, 2);
    send_simple(OP_COMMIT, 3, 1);
    expect_response(OP_COMMIT, RESP_OK, 3);

    wait_for_state(ST_WAIT_TRIGGER, 20000, "commit prefetch");
    if (!`TOP.new_prefetch_safe_ddr)
      $fatal(1, "prefetch_safe is not asserted in WAIT_TRIGGER");
    fifo_levels[0] = `TOP.ch1_wr_count;
    fifo_levels[1] = `TOP.ch2_wr_count;
    fifo_levels[2] = `TOP.ch3_wr_count;
    fifo_levels[3] = `TOP.ch4_wr_count;
    fifo_levels[4] = `TOP.ch5_wr_count;
    fifo_levels[5] = `TOP.ch6_wr_count;
    fifo_levels[6] = `TOP.ch7_wr_count;
    fifo_levels[7] = `TOP.ch8_wr_count;
    for (c = 0; c < 8; c = c + 1)
      if (fifo_levels[c] < BEATS)
        $fatal(1, "channel %0d prefetch level %0d < %0d", c+1, fifo_levels[c], BEATS);
    check_silence("wait_trigger");
    $display("[%0t] COMMIT reached WAIT_TRIGGER with all FIFOs prefetched", $time);

    // ---- external trigger playback ------------------------------------
    dac_quiet(24);
    start_capture;
    pulse_trigger_narrow;
    wait_for_state(ST_PLAYING, 200, "trigger playback");
    wait_for_state(ST_DONE, 4000, "trigger playback");
    capture_en = 1'b0;
    check_captured("trigger playback");
    if (trig1_pulses != 1)
      $fatal(1, "TRIG_1 produced %0d pulses, expected 1", trig1_pulses);
    if (`TOP.wave_path_trigger_fire_count_dac != 1)
      $fatal(1, "trigger_fire_count %0d expected 1", `TOP.wave_path_trigger_fire_count_dac);
    if (`TOP.wave_path_underflow_count_dac != 0)
      $fatal(1, "underflow_count %0d during prefetched playback",
             `TOP.wave_path_underflow_count_dac);
    check_silence("after first playback");
    $display("[%0t] external TRIG_2 playback delivered %0d verified beats", $time, BEATS);

    // ---- trigger outside WAIT_TRIGGER must not start playback ----------
    // The DAC-domain admission gate only admits an external event while the
    // controller is in WAIT_TRIGGER, so an event arriving in DONE must be
    // refused outright: no gate, no new fire, no new TRIG_1.
    begin
      integer fires_before;
      integer trig1_before;
      fires_before = `TOP.wave_path_trigger_fire_count_dac;
      trig1_before = trig1_pulses;
      dac_quiet(12);
      pulse_trigger_narrow;
      dac_quiet(32);
      if (state_dac !== ST_DONE)
        $fatal(1, "trigger outside WAIT_TRIGGER moved state to %0d", state_dac);
      if (gate)
        $fatal(1, "trigger outside WAIT_TRIGGER opened the DAC gate");
      if (`TOP.wave_path_trigger_fire_count_dac != fires_before)
        $fatal(1, "trigger outside WAIT_TRIGGER changed trigger_fire_count");
      if (trig1_pulses != trig1_before)
        $fatal(1, "trigger outside WAIT_TRIGGER produced a TRIG_1 pulse");
    end

    // ---- software PLAY replay from DONE --------------------------------
    start_capture;
    send_simple(OP_PLAY, 4, 1);
    expect_response(OP_PLAY, RESP_OK, 4);
    wait_for_state(ST_PLAYING, 20000, "software replay");
    wait_for_state(ST_DONE, 4000, "software replay");
    capture_en = 1'b0;
    check_captured("software replay");
    if (trig1_pulses != 2)
      $fatal(1, "TRIG_1 produced %0d pulses, expected 2", trig1_pulses);
    check_silence("after software replay");
    $display("[%0t] software PLAY replay verified", $time);

    // ---- STOP from DONE clears the gate and the FIFOs ------------------
    send_simple(OP_STOP, 5, 1);
    expect_response(OP_STOP, RESP_OK, 5);
    wait_for_state(ST_READY, 20000, "stop");
    dac_quiet(16);
    check_silence("after stop");
    // The STOP/clear handshake resets all eight channel FIFOs.  Give the
    // top-level FIFO reset counter time to complete before sampling levels.
    repeat (64) @(negedge `TOP.ddr4_ui_clk);
    if (`TOP.ch1_wr_count != 0 || `TOP.ch2_wr_count != 0 ||
        `TOP.ch3_wr_count != 0 || `TOP.ch4_wr_count != 0 ||
        `TOP.ch5_wr_count != 0 || `TOP.ch6_wr_count != 0 ||
        `TOP.ch7_wr_count != 0 || `TOP.ch8_wr_count != 0)
      $fatal(1, "STOP left stale FIFO data: %0d %0d %0d %0d %0d %0d %0d %0d",
             `TOP.ch1_wr_count, `TOP.ch2_wr_count, `TOP.ch3_wr_count, `TOP.ch4_wr_count,
             `TOP.ch5_wr_count, `TOP.ch6_wr_count, `TOP.ch7_wr_count, `TOP.ch8_wr_count);
    $display("[%0t] STOP returned READY with a muted output", $time);

    // ---- software PLAY from READY --------------------------------------
    start_capture;
    send_simple(OP_PLAY, 6, 1);
    expect_response(OP_PLAY, RESP_OK, 6);
    wait_for_state(ST_PLAYING, 20000, "software play from ready");
    wait_for_state(ST_DONE, 4000, "software play from ready");
    capture_en = 1'b0;
    check_captured("software play from ready");
    if (trig1_pulses != 3)
      $fatal(1, "TRIG_1 produced %0d pulses, expected 3", trig1_pulses);
    check_silence("after ready replay");
    $display("[%0t] software PLAY from READY verified", $time);

    // ---- partial channel-mask upload ----------------------------------
    // The reader still receives the complete interleaved payload, but only
    // enabled lanes may enter physical FIFOs.  This exercises the real Top
    // mask adapter rather than only its isolated unit test: disabled lanes
    // must not accumulate credit debt or block channel 1, and DAC output
    // for them must remain zero.
    send_begin_mask(7, 2, 8'h01);
    expect_response(OP_BEGIN, RESP_OK, 7);
    send_data(8, 0, 2);
    expect_response(OP_DATA, RESP_OK, 8);
    send_simple(OP_COMMIT, 9, 2);
    expect_response(OP_COMMIT, RESP_OK, 9);
    wait_for_state(ST_WAIT_TRIGGER, 20000, "masked commit prefetch");
    if (`TOP.ch1_wr_count < BEATS)
      $fatal(1, "masked active channel prefetch level %0d < %0d", `TOP.ch1_wr_count, BEATS);
    if (`TOP.ch2_wr_count != 0 || `TOP.ch3_wr_count != 0 ||
        `TOP.ch4_wr_count != 0 || `TOP.ch5_wr_count != 0 ||
        `TOP.ch6_wr_count != 0 || `TOP.ch7_wr_count != 0 ||
        `TOP.ch8_wr_count != 0)
      $fatal(1, "masked disabled channels accumulated FIFO data: %0d %0d %0d %0d %0d %0d %0d",
             `TOP.ch2_wr_count, `TOP.ch3_wr_count, `TOP.ch4_wr_count,
             `TOP.ch5_wr_count, `TOP.ch6_wr_count, `TOP.ch7_wr_count, `TOP.ch8_wr_count);
    check_silence("masked wait_trigger");
    // The trigger synchronizer intentionally requires a low re-arm window
    // after the prior playback/test pulse; do not race that safety contract.
    dac_quiet(32);
    start_capture;
    pulse_trigger_narrow;
    wait_for_state(ST_PLAYING, 200, "masked trigger playback");
    wait_for_state(ST_DONE, 4000, "masked trigger playback");
    capture_en = 1'b0;
    check_captured_mask("masked trigger playback", 8'h01);
    if (trig1_pulses != 4)
      $fatal(1, "masked playback produced %0d TRIG_1 pulses, expected 4", trig1_pulses);
    if (`TOP.wave_path_underflow_count_dac != 0)
      $fatal(1, "underflow_count %0d during masked playback",
             `TOP.wave_path_underflow_count_dac);
    check_silence("after masked playback");
    $display("[%0t] partial channel-mask playback verified", $time);

    $display("PASS: Top WAVECTR0 upload -> DDR -> prefetch -> DAC path verified end to end");
    $finish;
  end

  initial begin
    #120000;
    $fatal(1, "top-level waveform e2e timeout at state=%0d gate=%b", state_dac, gate);
  end
endmodule
