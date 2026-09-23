`timescale 1ns/1ps
module tb_waveform_dac_stream;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,playing=0,clear=0;
  reg [7:0] channel_mask=8'hff;
  reg [31:0] total_beats=3;
  reg [2047:0] fifo_data;
  reg [7:0] fifo_valid=8'hff;
  wire [7:0] fifo_ready;
  reg [7:0] dac_ready=8'hff;
  wire [2047:0] dac_data;wire [7:0] dac_valid,dac_last;wire [255:0] dac_keep;
  wire beat_fire,beat_last,underflow,first_transfer;
  wire [31:0] underflow_count;
  wire [31:0] beat_position;wire [255:0] channel_fire_counts;
  waveform_dac_stream dut(.*);
  integer indices[0:7];integer cycle=0,markers=0,c,ch;
  reg [7:0] stalled=0;reg [2047:0] held;reg [7:0] held_last;
  always @(negedge clk) begin
    for(integer i=0;i<8;i++) fifo_data[i*256+:256]=256'(100*i+indices[i]+1);
    cycle++;
  end
  always @(posedge clk) if(rst_n) begin
    for(integer i=0;i<8;i++)begin
      if(stalled[i] && (!dac_valid[i] || dac_data[i*256+:256]!==held[i*256+:256] || dac_last[i]!==held_last[i]))
        $fatal(1,"backpressure changed ch%0d",i);
      if(fifo_ready[i])begin
        if(!playing || !fifo_valid[i]) $fatal(1,"invalid FIFO consume");
        indices[i]++;
      end
      if(!playing && dac_data[i*256+:256]!==0) $fatal(1,"not zero when muted");
      if(playing && channel_mask[i] && dac_data[i*256+:256]!=0 && dac_valid[i] && dac_ready[i] && !fifo_ready[i])
        $fatal(1,"unaccounted DAC beat");
    end
    stalled=dac_valid&~dac_ready;held=dac_data;held_last=dac_last;
    if(first_transfer)markers++;
  end
  task tick(input integer n);begin repeat(n)@(negedge clk);#1;end endtask
  initial begin
    for(c=0;c<8;c++)indices[c]=0;
    tick(3);rst_n=1;tick(3);
    if(dac_valid!==8'hff) $fatal(1,"silence must send valid zeros");
    // Silence is a real AXIS beat too: stall the sink while idle, then
    // change PLAYING. Its already-presented zero must remain stable.
    dac_ready=0;tick(2);playing=1;tick(2);
    if(beat_position || markers) $fatal(1,"start without transfer");
    dac_ready=8'h01;tick(4);
    if(indices[0]!=1 || beat_position!=0 || markers!=1) $fatal(1,"per-channel completion");
    dac_ready=8'hfe;tick(2);dac_ready=0;tick(2);
    if(beat_position!=1) $fatal(1,"common position did not advance");
    dac_ready=8'hff;wait(beat_last&&beat_fire);@(posedge clk);tick(1);playing=0;tick(3);
    for(c=0;c<8;c++)if(indices[c]!=3||channel_fire_counts[c*32+:32]!=3) $fatal(1,"tail duplication");
    if(markers!=1) $fatal(1,"TRIG_1 not first transfer only");
    clear=1;tick(1);clear=0;channel_mask=1;playing=1;fifo_valid=8'h00;tick(1);
    if(!underflow || fifo_ready || underflow_count !== 32'd1) $fatal(1,"empty consume or missing underflow count");
    $display("PASS: eight-channel DAC fires, backpressure, tail and zero silence");$finish;
  end
  initial begin #10000;$fatal(1,"DAC test timeout");end
endmodule
