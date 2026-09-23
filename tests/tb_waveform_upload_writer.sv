`timescale 1ns/1ps
module tb_waveform_upload_writer;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,udp_tvalid=0,udp_tlast=0;reg [63:0] udp_tdata=0;
  reg command_ready=1;
  reg status_request_ready=1, status_snapshot_valid=1;
  reg [31:0] status_snapshot_state=0, status_snapshot_error_code=0;
  reg [15:0] status_snapshot_status=0;
  reg [63:0] status_snapshot_error_offset=0;
  wire status_request;
  wire response_valid;wire [31:0] response_seq,response_opcode,response_error_code;
  wire [15:0] response_status;wire [63:0] response_error_offset;
  wire [31:0] response_state,response_ack_packet_seq,response_next_expected_sequence;
  wire [63:0] response_received_bytes,response_first_error_offset;
  wire [31:0] session,descriptor;reg [31:0] playback_state=0;
  wire [3:0] state;wire begin_valid,commit_valid,play_valid,pause_valid,stop_valid,abort_valid;
  wire [63:0] ddr_base_addr,total_bytes;wire [31:0] total_beats,loop_count;wire [7:0] channel_mask;
  wire [127:0] instr_tdata;wire instr_tvalid;reg instr_tready=1;
  wire [63:0] m_axi_awaddr;wire m_axi_awvalid;reg m_axi_awready=0;
  wire [255:0] m_axi_wdata;wire [31:0] m_axi_wstrb;wire m_axi_wvalid,m_axi_wlast;reg m_axi_wready=0;
  reg [1:0] m_axi_bresp=0;reg m_axi_bvalid=0;wire m_axi_bready;
  wire [63:0] received_bytes,error_offset;wire [31:0] next_packet_seq,error_count;
  reg response_ready=1;
  wire [31:0] response_expected_crc,response_actual_crc;
  waveform_upload_writer #(.AXI_TIMEOUT_CYCLES(40)) dut(.*);
  integer cycles=0,writes=0,commits=0,begins=0,plays=0;
  reg aw_seen=0,w_seen=0,respond_b=1;reg [63:0] addr_q;reg [255:0] data_q;
  reg [7:0] memory[0:511];integer lane;
  reg [15:0] last_status;integer responses=0;
  always @(posedge clk) if(rst_n) begin
    cycles<=cycles+1;
    if(begin_valid) begin begins<=begins+1;playback_state<=1;end
    if(commit_valid) begin commits<=commits+1;playback_state<=3;end
    if(play_valid) plays<=plays+1;
    if(response_valid && response_ready) begin last_status<=response_status;responses<=responses+1; $display("response seq=%0d op=%0d status=%0d writes=%0d",response_seq,response_opcode,response_status,writes);end
    if(m_axi_awvalid&&m_axi_awready) begin aw_seen<=1;addr_q<=m_axi_awaddr;end
    if(m_axi_wvalid&&m_axi_wready) begin
      w_seen<=1;data_q<=m_axi_wdata;
      if(!m_axi_wlast||m_axi_wstrb!==32'hffffffff) $fatal(1,"write framing");
    end
    if(aw_seen&&w_seen&&!m_axi_bvalid&&respond_b) m_axi_bvalid<=1;
    if(m_axi_bvalid&&m_axi_bready) begin
      if(m_axi_bresp==0) for(lane=0;lane<32;lane++) memory[addr_q+lane]<=data_q[lane*8+:8];
      m_axi_bvalid<=0;aw_seen<=0;w_seen<=0;writes<=writes+1;
    end
  end
  always @(negedge clk) begin m_axi_awready=(cycles%4!=0);m_axi_wready=(cycles%5==1);end
  task word(input [63:0] data,input bit last);begin
    @(negedge clk);udp_tvalid=1;udp_tdata=data;udp_tlast=last;
    @(negedge clk);udp_tvalid=0;udp_tlast=0;
  end endtask
  task header(input integer op,input integer seq,input integer size,input integer version);begin
    word(64'h5741564543545230,0);word({op[31:0],16'd0,version[15:0]},0);word({size[31:0],seq[31:0]},0);
  end endtask
  task begin_packet(input integer seq,input integer version);begin
    header(1,seq,28,version);word({32'd256,32'd1},0);word(64'h000001ff00000000,0);
    word({32'd1,32'd1},0);word(64'd64,1);
  end endtask
  function [31:0] crc_byte(input [31:0] prev,input [7:0] data);
    reg [31:0] crc;integer b;begin crc=prev^data;for(b=0;b<8;b++) crc=(crc>>1)^(32'hedb88320&{32{crc[0]}});crc_byte=crc;end
  endfunction
  task data_packet(input integer req,input integer seq,input integer offset,input integer n,input bit corrupt,input bit truncated);
    reg [31:0] crc;reg [63:0] data;integer i,j;begin
      crc=32'hffffffff;for(i=0;i<n;i++) crc=crc_byte(crc,(offset+i)&255);crc=~crc;
      header(2,req,n+24,1);word({seq[31:0],32'd1},0);word(offset,0);word({crc^{31'd0,corrupt},n[31:0]},0);
      for(i=0;i<(truncated?n/16:n/8);i++) begin
        for(j=0;j<8;j++)data[j*8+:8]=(offset+i*8+j)&255;
        word(data,i==((truncated?n/16:n/8)-1));
      end
    end
  endtask
  task response(input integer prior_count,input integer expected);integer timeout;begin
    timeout=0;while(responses==prior_count&&timeout<20000) begin @(negedge clk);timeout++;end
    if(responses==prior_count||last_status!==expected) $fatal(1,"response expected=%0d actual=%0d state=%0d",expected,last_status,state);
    repeat(3) @(negedge clk);
  end endtask
  integer n,i;
  initial begin
    repeat(3)@(negedge clk);rst_n=1;
    n=responses;begin_packet(1,9);response(n,2);if(begins||session) $fatal(1,"bad-version BEGIN mutated session");
    command_ready=0;n=responses;begin_packet(2,1);repeat(8) @(negedge clk);
    if(responses!=n||begins!=0) $fatal(1,"command was accepted while playback mailbox was full");
    command_ready=1;response(n,0);if(total_bytes!=256||total_beats!=1||begins!=1) $fatal(1,"DAC beat units");
    n=responses;data_packet(3,0,0,256,0,1);response(n,2);if(writes||received_bytes) $fatal(1,"truncated DATA wrote DDR");
    n=responses;data_packet(4,0,0,256,1,0);response(n,7);if(writes||received_bytes) $fatal(1,"bad CRC wrote DDR");
    n=responses;header(3,5,4,1);word(1,1);response(n,4);if(commits) $fatal(1,"incomplete COMMIT accepted");
    n=responses;data_packet(6,1,0,256,0,0);response(n,5);
    n=responses;data_packet(7,0,32,256,0,0);response(n,6);
    n=responses;respond_b=0;data_packet(8,0,0,256,0,0);
    wait(m_axi_bready);repeat(4) @(negedge clk);
    if(received_bytes || next_packet_seq || responses!=n) $fatal(1,"ACK preceded B");
    respond_b=1;response(n,0);
    if(received_bytes!=256||next_packet_seq!=1||writes!=8) $fatal(1,"cumulative B ACK");
    for(i=0;i<256;i++)if(memory[i]!==i[7:0]) $fatal(1,"DDR data mismatch at %0d",i);
    n=responses;data_packet(8,0,0,256,0,0);response(n,0);if(writes!=8) $fatal(1,"duplicate DATA rewrote");
    n=responses;header(3,9,4,1);word(2,1);response(n,2);if(commits) $fatal(1,"wrong session COMMIT");
    n=responses;header(3,10,4,1);word(1,1);response(n,0);if(commits!=1||descriptor!=1) $fatal(1,"descriptor generation");
    n=responses;header(3,10,4,1);word(1,1);response(n,0);if(commits!=1) $fatal(1,"duplicate COMMIT");
    n=responses;header(4,11,4,1);word(1,1);response(n,0);
    n=responses;header(4,11,4,1);word(1,1);response(n,0);if(plays!=1) $fatal(1,"duplicate PLAY");
    // High halves of descriptor fields survive parsing without allocating
    // or writing a multi-gigabyte image in the memory model.
    n=responses;header(7,12,4,1);word(1,1);response(n,0);
    n=responses;response_ready=0;header(1,13,28,1);
    word({32'd256,32'd7},0);word(64'h000001ff00000001,0);
    word({32'd1,32'h01000001},0);word(64'd64,1);wait(response_valid);
    repeat(5) @(negedge clk);
    if(total_bytes!==64'h100000100 || total_beats!==32'h01000001 || responses!=n)
      $fatal(1,"64-bit descriptor/response hold");
    response_ready=1;response(n,0);
    n=responses;header(7,14,4,1);word(7,1);response(n,0);
    n=responses;begin_packet(15,1);response(n,0);
    n=responses;m_axi_bresp=2;data_packet(16,0,0,256,0,0);response(n,9);
    if(received_bytes||next_packet_seq) $fatal(1,"B error advanced ACK");
    n=responses;header(3,17,4,1);word(1,1);response(n,2);
    n=responses;header(7,18,4,1);word(1,1);response(n,0);
    n=responses;begin_packet(19,1);response(n,0);m_axi_bresp=0;
    n=responses;respond_b=0;data_packet(20,0,0,256,0,0);response(n,10);
    if(received_bytes||next_packet_seq) $fatal(1,"timeout advanced ACK");
    // A timed-out AXI transaction still exists. Retire it before a new BEGIN.
    respond_b=1;wait(m_axi_bvalid&&m_axi_bready);repeat(5)@(negedge clk);
    n=responses;header(3,21,4,1);word(1,1);response(n,2);
    n=responses;header(7,22,4,1);word(1,1);response(n,0);
    if(session||descriptor||received_bytes||error_count) $fatal(1,"ABORT did not clear upload");
    $display("PASS: WAVECTR0 writer validates CRC, emits aligned writes, and advances ACK only after AXI B responses");$finish;
  end
  initial begin #1000000;$fatal(1,"writer timeout");end
endmodule
