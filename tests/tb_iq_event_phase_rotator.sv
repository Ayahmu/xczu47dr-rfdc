`timescale 1ns/1ps
module tb_iq_event_phase_rotator;
  reg clk = 0;
  always #10 clk = !clk;
  reg rst_n=0, clear=0, commit=0, armed=0, enable=1, in_busy=0;
  reg [47:0] frequency=0;
  reg [31:0] epoch=0, capture_epoch=0;
  reg [10:0] phase=0;
  reg [255:0] input_data=0;
  wire [255:0] output_data;
  wire busy, clipping;
  real angle, previous_angle, expected_angle, error, frequency_hz;
  integer mode, event_number, previous_epoch, previous_phase, i;
  always @(posedge clk) if(!rst_n) epoch<=0; else epoch<=epoch+1;
  iq_event_phase_rotator dut (
      .clk(clk), .rst_n(rst_n), .clear(clear), .config_valid(commit), .armed(armed),
      .enable(enable), .frequency_word(frequency), .current_epoch(epoch),
      .event_epoch(capture_epoch), .event_phase_10ps(phase), .in_data(input_data),
      .in_busy(in_busy), .out_data(output_data), .busy(busy), .clip_pulse(clipping)
  );
  initial begin
    repeat(3) @(negedge clk); rst_n=1;
    for(mode=0; mode<4; mode=mode+1) begin
      armed=0;
      case(mode)
        0: begin frequency=48'h140000000000; frequency_hz=500e6; end
        1: begin frequency=48'h180000000000; frequency_hz=600e6; end
        2: begin frequency=48'h070000000000; frequency_hz=175e6; end
        3: begin frequency=-48'h0d0000000000; frequency_hz=-325e6; end
      endcase
      repeat(10) @(negedge clk); armed=1;
      for(event_number=0;event_number<25;event_number=event_number+1) begin
        capture_epoch=epoch-(event_number%7);
        phase=(event_number*137)%2000;
        commit=1; @(negedge clk); commit=0;
        repeat(8) @(negedge clk);
        for(i=0;i<8;i=i+1) input_data[i*32+:32]={16'sd3000,16'sd10000};
        in_busy=1;
        repeat(4) @(negedge clk);
        if(clipping) $fatal(1,"Unexpected clipping");
        for(i=1;i<8;i=i+1)
          if(output_data[i*32+:32]!==output_data[31:0]) $fatal(1,"Lane mismatch");
        angle=$atan2(real'($signed(output_data[31:16])),real'($signed(output_data[15:0])));
        if(event_number>0) begin
          expected_angle=previous_angle-6.283185307179586*frequency_hz*
              ((capture_epoch-previous_epoch)*20e-9+(int'(phase)-previous_phase)*10e-12);
          error=angle-expected_angle;
          while(error>3.141592653589793) error=error-6.283185307179586;
          while(error< -3.141592653589793) error=error+6.283185307179586;
          if(error>0.0006 || error< -0.0006)
            $fatal(1,"Event carrier correction mismatch mode=%0d event=%0d error=%0.8f",mode,event_number,error);
        end
        previous_angle=angle; previous_epoch=capture_epoch; previous_phase=phase;
        in_busy=0; input_data=0;
        repeat(5) @(negedge clk);
        if(busy || output_data!==0) $fatal(1,"Rotator tail failed to drain");
      end
    end
    // Disabled carrier correction has exactly unity gain through the same pipeline.
    enable=0; commit=1; @(negedge clk); commit=0;
    repeat(8) @(negedge clk);
    input_data={8{32'h80007fff}}; in_busy=1;
    repeat(4) @(negedge clk);
    if(output_data!==input_data || clipping) $fatal(1,"Bypass is not exact unity");
    clear=1; @(negedge clk); clear=0; in_busy=0; input_data=0;
    if(output_data!==0 || busy) $fatal(1,"Clear retained data");
    $display("PASS: event-relative NCO correction, positive/negative frequencies, eight lanes, unity mode and clear");
    $finish;
  end
  initial begin #1000000; $fatal(1,"TIMEOUT"); end
endmodule
