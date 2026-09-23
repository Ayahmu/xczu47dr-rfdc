`timescale 1ns/1ps

// Eight-lane DAC-domain output accounting. Each enabled channel consumes its
// FIFO only on its own VALID && READY. A sent mask prevents fast channels
// from sending the common beat twice while another channel is backpressured.
// The common position advances only after all selected channels have fired.
// Disabled channels send zeros and discard one FIFO word per common beat.
//
// CLEAR/PLAYING are controlled by the session FSM. Before closing PLAYING or
// clearing a FIFO it must finish any presented/stalled beat (or reset the AXI
// sink as part of fault recovery); changing PLAYING mid-stall is not legal.
module waveform_dac_stream (
    input wire clk, input wire rst_n, input wire playing, input wire clear,
    input wire [7:0] channel_mask, input wire [31:0] total_beats,
    input wire [2047:0] fifo_data, input wire [7:0] fifo_valid,
    output wire [7:0] fifo_ready,
    output wire [2047:0] dac_data, output wire [7:0] dac_valid,
    input wire [7:0] dac_ready,
    output wire [7:0] dac_last, output wire [255:0] dac_keep,
    output wire beat_fire, output wire beat_last, output wire underflow,
    output wire first_transfer, output reg [31:0] beat_position,
    output reg [31:0] underflow_count,
    output wire [255:0] channel_fire_counts
);
  reg [7:0] sent;
  reg first_sent;
  reg [7:0] silence_pending;
  wire active=playing&&beat_position<total_beats&&channel_mask!=0;
  wire [7:0] need=channel_mask&~sent;
  wire [7:0] fire= {8{active}} & need & ~silence_pending & fifo_valid & dac_ready;
  assign beat_fire=active&&((sent|fire|~channel_mask)==8'hff);
  assign beat_last=beat_position+1==total_beats;
  assign underflow=active&&|(need&~fifo_valid);
  assign first_transfer=|fire&&!first_sent;
  genvar ch;
  generate for(ch=0;ch<8;ch=ch+1) begin : channels
    reg [31:0] fire_count;
    assign channel_fire_counts[ch*32+:32]=fire_count;
    assign dac_data[ch*256+:256]=active&&channel_mask[ch]&&!sent[ch]&&!silence_pending[ch] ? fifo_data[ch*256+:256] : 256'd0;
    assign dac_valid[ch]=!playing||!channel_mask[ch]||silence_pending[ch] ? 1'b1 : active&&!sent[ch]&&fifo_valid[ch];
    assign dac_last[ch]=active&&channel_mask[ch]&&!sent[ch]&&!silence_pending[ch]&&beat_last;
    assign dac_keep[ch*32+:32]=32'hffffffff;
    assign fifo_ready[ch]=fire[ch]||(!channel_mask[ch]&&beat_fire&&fifo_valid[ch]);
    // A zero beat already offered while idle is also protected by AXIS
    // stability. Finish that zero handshake before offering waveform data;
    // it consumes no FIFO word and cannot generate TRIG_1.
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) silence_pending[ch]<=0;
      else if(!playing) silence_pending[ch]<=!dac_ready[ch];
      else if(silence_pending[ch]&&dac_ready[ch]) silence_pending[ch]<=0;
    end
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) fire_count<=0;
      else if(clear) fire_count<=0;
      else if(fire[ch]) fire_count<=fire_count+1'b1;
    end
  end endgenerate
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin sent<=0;first_sent<=0;beat_position<=0;underflow_count<=0;end
    else if(clear) begin sent<=0;first_sent<=0;beat_position<=0;underflow_count<=0;end
    else begin
      if (underflow && underflow_count != 32'hffffffff) underflow_count <= underflow_count + 1'b1;
      if(first_transfer) first_sent<=1;
      if(beat_fire) begin sent<=0;beat_position<=beat_position+1'b1;end
      else sent<=sent|fire;
    end
  end
endmodule
