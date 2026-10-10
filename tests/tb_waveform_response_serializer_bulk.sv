`timescale 1ns/1ps
// BULK_STATUS (9) and BULK_CHUNK_RESET (10) answer with the same 60-byte
// extended payload as DATA; every other command keeps its own length.
module tb_waveform_response_serializer_bulk;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, event_valid=0;
  reg [31:0] event_opcode=9;
  wire response_valid, response_last, busy; wire [63:0] response_data; wire [15:0] response_word_count;
  waveform_response_serializer dut (
    .clk(clk), .rst_n(rst_n), .event_valid(event_valid),
    .event_seq(32'h0000_0077), .event_opcode(event_opcode), .event_status(16'd0), .event_error_code(32'd0),
    .event_session(32'd5), .event_state(32'd1), .event_descriptor(32'd0),
    .event_error_offset(64'h66666666_55555555), .event_ack_packet_seq(32'h8000_0003),
    .event_next_expected_sequence(32'hffff_ffff),
    .event_received_bytes(64'h22222222_11111111), .event_first_error_offset(64'h44444444_33333333),
    .event_expected_crc(32'h7777_7777), .event_actual_crc(32'd0),
    .event_current_beat(32'd0), .event_loop_position(32'd0), .event_loop_count(32'd0),
    .event_channel_mask(8'd0), .event_layout(8'd2), .event_fifo_levels(128'd0),
    .event_error_count(32'd0), .event_underflow_count(32'd0), .event_trigger_seen_count(32'd0),
    .event_trigger_dropped_count(32'd0), .event_trigger_fire_count(32'd0),
    .response_valid(response_valid), .response_data(response_data), .response_last(response_last),
    .response_word_count(response_word_count), .response_ready(1'b1), .busy(busy));

  reg [63:0] got [0:15]; integer count;
  task automatic run(input [31:0] opcode);
    begin
      @(negedge clk); event_opcode = opcode; event_valid = 1; @(negedge clk); event_valid = 0;
      count = 0;
      while (!response_valid) @(negedge clk);
      while (response_valid) begin got[count] = response_data; count = count + 1; @(negedge clk); end
    end
  endtask
  task automatic check_extended(input [31:0] opcode);
    begin
      run(opcode);
      if (count != 11) $fatal(1, "opcode %0d: %0d words, expected 11", opcode, count);
      if (got[1] !== {opcode, 16'd0, 16'd1} || got[2] !== {32'd60, 32'h77}) $fatal(1, "opcode %0d header", opcode);
      if (got[5] !== {32'h55555555, 32'd0} || got[6] !== {32'h8000_0003, 32'h66666666} ||
          got[7] !== {32'h11111111, 32'hffff_ffff} || got[8] !== {32'h33333333, 32'h22222222} ||
          got[9] !== {32'h7777_7777, 32'h44444444} || got[10] !== 64'd0)
        $fatal(1, "opcode %0d payload", opcode);
    end
  endtask
  initial begin
    repeat (3) @(negedge clk); rst_n = 1;
    check_extended(9);
    check_extended(10);
    run(3);
    if (count != 7 || got[2] !== {32'd28, 32'h77}) $fatal(1, "COMMIT response length changed");
    $display("tb_waveform_response_serializer_bulk PASS");
    $finish;
  end
endmodule
