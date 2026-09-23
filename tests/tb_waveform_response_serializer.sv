`timescale 1ns/1ps
module tb_waveform_response_serializer;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0,event_valid=0,response_ready=0;
  reg [31:0] event_seq=32'h12345678,event_opcode=2,event_error_code=32'h11223344;
  reg [15:0] event_status=7;
  reg [31:0] event_session=5,event_state=1,event_descriptor=9;
  reg [63:0] event_error_offset=64'h00000001aabbccdd;
  reg [31:0] event_ack_packet_seq=2,event_next_expected_sequence=3;
  reg [63:0] event_received_bytes=64'h0000000200000020;
  reg [63:0] event_first_error_offset=64'h0000000388776655;
  wire response_valid,response_last,busy;
  wire [63:0] response_data;wire [15:0] response_word_count;
  reg [31:0] event_expected_crc=32'h12345678,event_actual_crc=32'h87654321;
  reg [31:0] event_current_beat=0,event_loop_position=0,event_loop_count=0;
  reg [7:0] event_channel_mask=0,event_layout=1;
  reg [127:0] event_fifo_levels=0;
  reg [31:0] event_error_count=0,event_underflow_count=0;
  reg [31:0] event_trigger_seen_count=0,event_trigger_dropped_count=0,event_trigger_fire_count=0;
  waveform_response_serializer dut(.*);
  reg [63:0] expected[0:10];reg [63:0] held;reg held_last,stalled=0;
  integer index=0,cycles=0;
  always @(posedge clk) if(rst_n) begin
    if(stalled && (!response_valid || response_data !== held || response_last !== held_last))
      $fatal(1,"response changed under backpressure");
    stalled = response_valid && !response_ready;held=response_data;held_last=response_last;
    if(response_valid && response_ready) begin
      if(index>=11 || response_data !== expected[index])
        $fatal(1,"response word %0d got=%h expected=%h",index,response_data,expected[index]);
      if(response_word_count != 11 || response_last != (index==10)) $fatal(1,"response framing");
      index++;
    end
  end
  initial begin
    expected[0]=64'h5741564552535030;expected[1]={32'd2,16'd7,16'd1};
    expected[2]={32'd60,32'h12345678};expected[3]={32'd1,32'd5};
    expected[4]={32'h11223344,32'd7};expected[5]={32'haabbccdd,32'd9};
    expected[6]={32'd2,32'd1};expected[7]={32'h20,32'd3};
    expected[8]={32'h88776655,32'd2};expected[9]={32'h12345678,32'd3};
    expected[10]={32'd0,32'h87654321};
    repeat(3) @(negedge clk);rst_n=1;event_valid=1;
    @(negedge clk);event_valid=0;
    // Inputs may change while the output packet is stalled: the serializer
    // must use the event snapshot, not live counters.
    event_received_bytes=0;event_first_error_offset=0;
    for(cycles=0;cycles<40;cycles++) begin
      @(negedge clk);response_ready=(cycles%5!=0 && cycles%5!=1);
    end
    if(index!=11 || busy || response_valid) $fatal(1,"missing/trailing response word");
    $display("PASS: waveform response golden bytes and AXIS backpressure");$finish;
  end
endmodule
