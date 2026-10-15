`timescale 1ns / 1ps

// firmware_status_reg: the status word is stored with byte strobes, read back
// with the HMC7044 done flag in bit 31, the HMC7044 readback bank and GPIO1
// are readable, and stray accesses still complete.
module tb_firmware_status_reg;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  reg  [8:0]  awaddr = 0;  reg awvalid = 0;  wire awready;
  reg  [31:0] wdata = 0;   reg [3:0] wstrb = 0;  reg wvalid = 0;  wire wready;
  wire [1:0]  bresp;       wire bvalid;      reg bready = 0;
  reg  [8:0]  araddr = 0;  reg arvalid = 0;  wire arready;
  wire [31:0] rdata;       wire [1:0] rresp; wire rvalid;  reg rready = 0;
  reg         hmc_done = 1'b0;
  reg         hmc_gpio1 = 1'b0;
  reg  [15:0] hmc_rb_sweeps = 16'h0000;
  wire [5:0]  hmc_rb_index;
  // Stand-in for the HMC7044 readback bank: the word is a function of its index.
  wire [31:0] hmc_rb_word = {8'hC0, 8'h00, 2'b00, hmc_rb_index, 8'h5A};
  wire [31:0] status;

  firmware_status_reg dut (
      .s_axi_aclk(clk), .s_axi_aresetn(rst_n),
      .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
      .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
      .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
      .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
      .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
      .hmc_done(hmc_done), .hmc_gpio1(hmc_gpio1), .hmc_rb_sweeps(hmc_rb_sweeps),
      .hmc_rb_index(hmc_rb_index), .hmc_rb_word(hmc_rb_word), .status(status));

  task check(input condition, input string message);
    begin
      if (!condition) begin
        $display("FAIL: %s", message);
        $finish;
      end
    end
  endtask

  // The address may arrive before, with or after the data.
  task write(input [8:0] address, input [31:0] data, input [3:0] strobe, input integer data_delay);
    integer timeout;
    begin
      @(negedge clk);
      awaddr = address; awvalid = 1'b1;
      if (data_delay == 0) begin wdata = data; wstrb = strobe; wvalid = 1'b1; end
      @(negedge clk);
      awvalid = 1'b0;
      if (data_delay == 0) wvalid = 1'b0;
      else begin
        repeat (data_delay - 1) @(negedge clk);
        wdata = data; wstrb = strobe; wvalid = 1'b1;
        @(negedge clk);
        wvalid = 1'b0;
      end
      timeout = 0;
      while (!bvalid && timeout < 16) begin @(negedge clk); timeout = timeout + 1; end
      check(bvalid && bresp == 2'b00, "write must complete with OKAY");
      bready = 1'b1; @(negedge clk); bready = 1'b0;
      check(!bvalid, "BVALID must drop after the response handshake");
    end
  endtask

  task read(input [8:0] address, output [31:0] data);
    integer timeout;
    begin
      @(negedge clk);
      araddr = address; arvalid = 1'b1;
      @(negedge clk);
      arvalid = 1'b0;
      timeout = 0;
      while (!rvalid && timeout < 16) begin @(negedge clk); timeout = timeout + 1; end
      check(rvalid && rresp == 2'b00, "read must complete with OKAY");
      data = rdata;
      rready = 1'b1; @(negedge clk); rready = 1'b0;
    end
  endtask

  reg [31:0] value;
  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    check(status == 32'd0, "status must reset to zero");

    write(9'h008, 32'h8123_4567, 4'hF, 0);
    check(status == 32'h8123_4567, "full status word was not stored");
    read(9'h008, value);
    check(value == 32'h0123_4567, "bit 31 must read back hmc_done, not the stored bit");
    hmc_done = 1'b1;
    read(9'h008, value);
    check(value == 32'h8123_4567, "hmc_done was not read back in bit 31");

    write(9'h008, 32'hAABB_CCDD, 4'b0101, 3);
    check(status == 32'h81BB_45DD, "byte strobes were not honoured");

    // Addresses other than the status word are inert but still answered.
    write(9'h000, 32'hFFFF_FFFF, 4'hF, 1);
    write(9'h00C, 32'hFFFF_FFFF, 4'hF, 0);
    check(status == 32'h81BB_45DD, "a stray write changed the status word");
    read(9'h000, value);
    check(value == 32'd0, "a stray read must return zero");

    // 0x00C: {GPIO1, 15'b0, sweep count}; 0x100 + 4i: readback word i.
    hmc_rb_sweeps = 16'h1234;
    read(9'h00C, value);
    check(value == 32'h0000_1234, "readback sweep count not at 0x00C");
    hmc_gpio1 = 1'b1;
    read(9'h00C, value);
    check(value == 32'h8000_1234, "GPIO1 not read back in bit 31 of 0x00C");
    read(9'h100, value);
    check(value == 32'hC000_005A, "readback word 0 not at 0x100");
    read(9'h1FC, value);
    check(value == 32'hC000_3F5A, "readback word 63 not at 0x1FC");
    read(9'h0FC, value);
    check(value == 32'd0, "readback bank must not alias below 0x100");

    $display("PASS: firmware status register stores the word, reads back hmc_done, the HMC7044 readback bank and ignores stray accesses");
    $finish;
  end
endmodule
