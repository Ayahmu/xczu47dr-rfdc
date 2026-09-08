`timescale 1ns/1ps
module BUFGCE_DIV #(parameter BUFGCE_DIVIDE=2)(input I, CE, CLR, output reg O=0);
  always @(posedge I or posedge CLR) if(CLR) O<=0; else if(CE) O<=!O;
endmodule
module DNA_PORTE2 #(parameter [95:0] SIM_DNA_VALUE=96'h123456789abcdef123456789)
    (output DOUT, input CLK, DIN, READ, SHIFT);
  reg [95:0] value = SIM_DNA_VALUE;
  assign DOUT=value[95];
  always @(posedge CLK) if(READ) value<=SIM_DNA_VALUE; else if(SHIFT) value<={value[94:0],DIN};
endmodule
module tb_network_dna_reset;
  reg clk=0, rst_n=0;
  always #1.667 clk=!clk;
  wire ready;
  wire [63:0] uid, mac;
  wire [31:0] ip;
  integer phase, cycles;
  reg [63:0] expected_uid;
  realtime dna_edge;
  network_config_pl dut (
      .clk(clk), .rst_n(rst_n), .apply_start(1'b0), .apply_revision(32'd0),
      .apply_ip(32'd0), .apply_mac(64'd0), .apply_subnet(32'd0), .apply_gateway(32'd0),
      .apply_port(16'd0), .restart_start(1'b0), .playback_armed(1'b0),
      .playback_prepared(1'b0), .playback_running(1'b0), .identity_ready(ready),
      .device_uid(uid), .current_mac(mac), .current_ip(ip)
  );
  always @(posedge dut.dna_clk) dna_edge=$realtime;
  always @(posedge dut.dna_rst_n) begin
    if($realtime-dna_edge > 0.001) $fatal(1,"DNA reset released outside DNA clock edge");
  end
  initial begin
    for(phase=0;phase<8;phase=phase+1) begin
      rst_n=0; #0.002;
      if(dut.dna_rst_n!==0) $fatal(1,"DNA reset assertion was not asynchronous");
      #(17.13+phase*0.431); rst_n=1;
      cycles=0;
      while(!ready && cycles<500) begin @(negedge clk); cycles=cycles+1; end
      if(!ready || uid==0 || mac[47:40]!=8'h02 || ip[31:16]!=16'ha9fe)
        $fatal(1,"DNA identity did not initialize after reset");
      if(phase==0) expected_uid=uid;
      else if(uid!==expected_uid) $fatal(1,"DNA identity changed with reset phase");
      #29.37;
    end
    $display("PASS: DNA reset asserts asynchronously, releases on its own clock, and preserves identity");
    $finish;
  end
  initial begin #100000; $fatal(1,"TIMEOUT"); end
endmodule
