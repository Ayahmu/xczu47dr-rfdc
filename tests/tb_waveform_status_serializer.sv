`timescale 1ns/1ps
module tb_waveform_status_serializer;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, event_valid=0, response_ready=1;
  reg [31:0] event_seq=32'h12345678, event_opcode=8, event_error_code=32'h11223344;
  reg [15:0] event_status=0;
  reg [31:0] event_session=5, event_state=4, event_descriptor=9;
  reg [63:0] event_error_offset=64'h00000001aabbccdd;
  reg [31:0] event_ack_packet_seq=0, event_next_expected_sequence=0;
  reg [63:0] event_received_bytes=0, event_first_error_offset=0;
  reg [31:0] event_expected_crc=0, event_actual_crc=0;
  reg [31:0] event_current_beat=32'h01020304;
  reg [31:0] event_loop_position=32'h05060708;
  reg [31:0] event_loop_count=32'h090a0b0c;
  reg [7:0] event_channel_mask=8'hA5, event_layout=8'h01;
  reg [127:0] event_fifo_levels={16'h0080,16'h0070,16'h0060,16'h0050,16'h0040,16'h0030,16'h0020,16'h0010};
  reg [31:0] event_error_count=32'h11121314;
  reg [31:0] event_underflow_count=32'h15161718;
  reg [31:0] event_trigger_seen_count=32'h191a1b1c;
  reg [31:0] event_trigger_dropped_count=32'h1d1e1f20;
  reg [31:0] event_trigger_fire_count=32'h21222324;
  wire response_valid,response_last,busy;
  wire [63:0] response_data; wire [15:0] response_word_count;
  waveform_response_serializer dut(.*);
  reg [63:0] expected[0:12];
  integer index=0;
  always @(posedge clk) if (rst_n && response_valid && response_ready) begin
    if (index>=13 || response_data !== expected[index])
      $fatal(1,"status response word %0d got=%h expected=%h",index,response_data,expected[index]);
    if (response_word_count != 13 || response_last != (index==12))
      $fatal(1,"status response framing at word %0d count=%0d last=%b",index,response_word_count,response_last);
    index=index+1;
  end
  initial begin
    expected[0]=64'h5741564552535030;
    expected[1]={32'd8,16'd0,16'd1};
    expected[2]={32'd80,32'h12345678};
    expected[3]={32'd4,32'd5};
    expected[4]={32'h11223344,32'd0};
    expected[5]={32'haabbccdd,32'd9};
    expected[6]={32'h01020304,32'h00000001};
    expected[7]={32'h090a0b0c,32'h05060708};
    expected[8]={16'h0020,16'h0010,32'h000001a5};
    expected[9]={16'h0060,16'h0050,16'h0040,16'h0030};
    expected[10]={32'h11121314,16'h0080,16'h0070};
    expected[11]={32'h191a1b1c,32'h15161718};
    expected[12]={32'h21222324,32'h1d1e1f20};
    repeat(3) @(negedge clk); rst_n=1; event_valid=1;
    @(negedge clk); event_valid=0;
    repeat(30) @(negedge clk);
    if (index != 13 || busy || response_valid) $fatal(1,"missing/trailing status response");
    $display("PASS: waveform STATUS snapshot serializer returns beat, loop, FIFO, error and trigger fields");
    $finish;
  end
endmodule
