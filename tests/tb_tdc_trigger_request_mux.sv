`timescale 1ns/1ps
module tb_tdc_trigger_request_mux;
  reg prepared, bypass, ready, ext_valid, ext_good, local_pulse, local_external;
  wire allowed, valid, good, master_allowed;
  wire [31:0] epoch;
  wire [10:0] phase;
  integer pattern;
  reg local_request, use_external;
  tdc_trigger_request_mux dut (
      .prepared(prepared), .sync_bypass(bypass), .sync_ready(ready),
      .external_valid(ext_valid), .external_good(ext_good),
      .external_epoch(32'd123), .external_phase(11'd789),
      .software_pulse(local_pulse), .software_is_external(local_external),
      .current_epoch(32'd456), .admission_open(allowed), .event_valid(valid),
      .event_good(good), .event_epoch(epoch), .event_phase(phase)
  );
  tdc_trigger_request_mux #(.IS_MASTER(1)) master (
      .prepared(prepared), .sync_bypass(bypass), .sync_ready(ready),
      .external_valid(ext_valid), .external_good(ext_good),
      .external_epoch(32'd123), .external_phase(11'd789),
      .software_pulse(local_pulse), .software_is_external(local_external),
      .current_epoch(32'd456), .admission_open(master_allowed)
  );
  initial begin
    for(pattern=0;pattern<128;pattern=pattern+1) begin
      {prepared,bypass,ready,ext_valid,ext_good,local_pulse,local_external}=pattern;
      #1;
      if(allowed !== (prepared && (bypass || ready)) || master_allowed !== prepared)
        $fatal(1,"SYNC admission mismatch");
      local_request=local_pulse && !local_external;
      if(valid !== (ext_valid || local_request)) $fatal(1,"Duplicate external/software event");
      use_external=ext_valid && (ext_good || !local_request);
      if(epoch !== (use_external ? 123 : 456) || phase !== (use_external ? 789 : 0))
        $fatal(1,"Event source timestamp mismatch");
      if(good !== (use_external ? ext_good : 1'b1)) $fatal(1,"Event validity mismatch");
    end
    $display("PASS: slave SYNC gate, master admission, software triggers and external duplicate suppression");
    $finish;
  end
endmodule
