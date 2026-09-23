`timescale 1ns/1ps
module tb_waveform_ddr_reader;
  reg clk=0;always #2 clk=~clk;
  reg rst_n=0,start=0,cancel=0;
  reg [63:0] base_addr=64'h100000f00;
  reg [31:0] total_beats=40;
  reg [15:0] fifo_free_beats=1024;
  wire [63:0] m_axi_araddr;wire [7:0] m_axi_arlen;
  wire m_axi_arvalid;reg m_axi_arready=1;
  reg [511:0] m_axi_rdata;reg [1:0] m_axi_rresp=0;
  reg m_axi_rvalid=0,m_axi_rlast=0;wire m_axi_rready;
  wire [2047:0] frame_data;wire frame_valid;reg frame_ready=1;
  wire busy,done,error;wire [31:0] error_code;wire [63:0] error_offset;
  waveform_ddr_reader #(.TIMEOUT_CYCLES(30)) dut(.*);
  reg [63:0] addresses[0:31];integer lengths[0:31];integer issued=0,retired=0;
  integer return_beat=0,frames=0,cycles=0,i,j,scenario=0;
  reg responding=1,stall_frames=0;
  reg held=0;reg [2047:0] held_data;
  always @(posedge clk) if(rst_n) begin
    cycles<=cycles+1;
    if(m_axi_arvalid&&m_axi_arready) begin
      if(m_axi_araddr[5:0] || m_axi_araddr[11:0]+(m_axi_arlen+1)*64>4096)
        $fatal(1,"unaligned or 4 KiB crossing burst");
      addresses[issued]<=m_axi_araddr;lengths[issued]<=m_axi_arlen+1;issued<=issued+1;
    end
    if(m_axi_rvalid&&m_axi_rready) begin
      if(m_axi_rlast) begin retired<=retired+1;return_beat<=0;end
      else return_beat<=return_beat+1;
    end
    if(held && (!frame_valid || frame_data!==held_data)) $fatal(1,"frame changed while stalled");
    held=frame_valid&&!frame_ready;held_data=frame_data;
    if(frame_valid&&frame_ready) begin
      if(scenario==0) for(i=0;i<8;i++)for(j=0;j<4;j++)
        if(frame_data[i*256+j*64+:64] !== 64'(frames*4*8+j*8+i))
          $fatal(1,"interleaved lane mismatch frame=%0d ch=%0d slice=%0d got=%h",frames,i,j,frame_data[i*256+j*64+:64]);
      frames<=frames+1;
    end
  end
  always @(negedge clk) begin
    frame_ready=!stall_frames && cycles%7!=1;
    m_axi_rvalid=responding && retired<issued && cycles%5!=0;
    m_axi_rlast=retired<issued && return_beat==lengths[retired]-1;
    for(integer c=0;c<8;c++)m_axi_rdata[c*64+:64]=((addresses[retired]-base_addr)/64+return_beat)*8+c;
  end
  task tick(input integer n);begin repeat(n)@(negedge clk);end endtask
  task launch;begin start=1;tick(1);start=0;end endtask
  task reset;begin rst_n=0;start=0;cancel=0;responding=1;stall_frames=0;
    tick(3);issued=0;retired=0;frames=0;return_beat=0;cycles=0;held=0;rst_n=1;tick(3);end endtask
  initial begin
    reset;fifo_free_beats=0;launch;tick(10);
    if(issued) $fatal(1,"reader ignored FIFO credit");
    fifo_free_beats=1024;wait(done);tick(2);
    if(frames!=40||error||busy) $fatal(1,"reader completion");
    reset;scenario=1;responding=0;launch;tick(8);cancel=1;responding=1;
    wait(!busy);tick(2);if(frame_valid) $fatal(1,"cancel leaked old frame");
    reset;scenario=2;m_axi_rresp=2;launch;wait(error);wait(!busy);
    if(error_code!=2) $fatal(1,"RRESP not reported");
    reset;scenario=3;m_axi_rresp=0;responding=0;launch;wait(error);
    if(error_code!=3 || !busy) $fatal(1,"timeout must quarantine outstanding reads");
    responding=1;wait(!busy);
    $display("PASS: waveform reader credits, interleave, cancel, AXI errors and timeout");$finish;
  end
  initial begin #100000;$fatal(1,"reader timeout");end
endmodule
