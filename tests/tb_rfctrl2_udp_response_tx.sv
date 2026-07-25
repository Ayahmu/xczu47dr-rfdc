`timescale 1ns / 1ps

module tb_rfctrl2_udp_response_tx;
  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  reg        rx_header_fire = 1'b0;
  reg [31:0] rx_source_ip = 32'd0;
  reg [15:0] rx_source_port = 16'd0;
  reg [15:0] rx_dest_port = 16'd0;
  reg        rx_payload_fire = 1'b0;
  reg [63:0] rx_payload_data = 64'd0;
  reg        tx_path_enable = 1'b1;
  reg        tx_header_ready = 1'b0;
  reg        tx_payload_ready = 1'b0;
  reg        response_valid = 1'b0;
  reg [63:0] response_data = 64'd0;
  reg        response_last = 1'b0;
  reg [15:0] response_word_count = 16'd0;
  wire       response_ready;
  wire       tx_active;
  wire       tx_header_valid;
  wire [31:0] tx_dest_ip;
  wire [15:0] tx_source_port;
  wire [15:0] tx_dest_port;
  wire [15:0] tx_length;
  wire [63:0] tx_payload_data;
  wire       tx_payload_valid;
  wire       tx_payload_last;
  wire       request_inflight;
  wire [1:0] dbg_state;

  integer payload_handshakes = 0;
  reg [63:0] accepted_words [0:2];

  rfctrl2_udp_response_tx dut (
    .clk(clk), .rst(rst),
    .rx_header_fire(rx_header_fire),
    .rx_source_ip(rx_source_ip),
    .rx_source_port(rx_source_port),
    .rx_dest_port(rx_dest_port),
    .rx_payload_fire(rx_payload_fire),
    .rx_payload_data(rx_payload_data),
    .tx_path_enable(tx_path_enable),
    .tx_header_ready(tx_header_ready),
    .tx_payload_ready(tx_payload_ready),
    .response_valid(response_valid),
    .response_data(response_data),
    .response_last(response_last),
    .response_word_count(response_word_count),
    .response_ready(response_ready),
    .tx_active(tx_active),
    .tx_header_valid(tx_header_valid),
    .tx_dest_ip(tx_dest_ip),
    .tx_source_port(tx_source_port),
    .tx_dest_port(tx_dest_port),
    .tx_length(tx_length),
    .tx_payload_data(tx_payload_data),
    .tx_payload_valid(tx_payload_valid),
    .tx_payload_last(tx_payload_last),
    .request_inflight(request_inflight),
    .dbg_state(dbg_state)
  );

  always @(posedge clk) begin
    if (tx_payload_valid && tx_payload_ready) begin
      accepted_words[payload_handshakes] <= tx_payload_data;
      payload_handshakes <= payload_handshakes + 1;
    end
  end

  task check_condition(input condition, input string message);
    begin
      if (!condition) begin
        $display("FAIL: %s", message);
        $finish;
      end
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst = 1'b0;

    // Reproduce the risky case: UDP header and RFCTRL2 magic arrive together.
    @(negedge clk);
    rx_header_fire = 1'b1;
    rx_source_ip = 32'hC0A8_010A;
    rx_source_port = 16'd49152;
    rx_dest_port = 16'd1234;
    rx_payload_fire = 1'b1;
    rx_payload_data = 64'h00324C5254434652;
    @(negedge clk);
    rx_header_fire = 1'b0;
    rx_payload_fire = 1'b0;

    check_condition(request_inflight, "same-cycle header and magic must lock the request context");

    response_word_count = 16'd3;
    response_data = 64'h1111111111111111;
    response_valid = 1'b1;
    repeat (2) @(negedge clk);

    check_condition(tx_header_valid, "response header must remain valid under backpressure");
    check_condition(tx_dest_ip == 32'hC0A8_010A, "response destination IP must match the request source");
    check_condition(tx_dest_port == 16'd49152, "response destination port must match the request source port");
    check_condition(tx_source_port == 16'd1234, "response source port must match the request destination port");
    check_condition(tx_length == 16'd32, "UDP length must include three payload words and the UDP header");

    tx_header_ready = 1'b1;
    @(negedge clk);
    tx_header_ready = 1'b0;
    tx_payload_ready = 1'b1;
    @(negedge clk);
    response_data = 64'h2222222222222222;
    tx_payload_ready = 1'b0;
    repeat (2) @(negedge clk);
    check_condition(payload_handshakes == 1, "payload must stop while ready is low");
    check_condition(tx_payload_data == 64'h2222222222222222, "payload data must remain visible while stalled");

    tx_payload_ready = 1'b1;
    @(negedge clk);
    response_data = 64'h3333333333333333;
    response_last = 1'b1;
    @(negedge clk);
    response_valid = 1'b0;
    response_last = 1'b0;
    repeat (2) @(negedge clk);

    check_condition(payload_handshakes == 3, "all response payload words must handshake exactly once");
    check_condition(accepted_words[0] == 64'h1111111111111111, "first payload word mismatch");
    check_condition(accepted_words[1] == 64'h2222222222222222, "second payload word mismatch");
    check_condition(accepted_words[2] == 64'h3333333333333333, "third payload word mismatch");
    check_condition(!request_inflight, "request context must clear after the final response word");
    check_condition(!tx_active && dbg_state == 2'd0, "transmitter must return to idle");

    $display("PASS: RFCTRL2 UDP response TX locks the exact requester and honors AXIS backpressure");
    $finish;
  end
endmodule
