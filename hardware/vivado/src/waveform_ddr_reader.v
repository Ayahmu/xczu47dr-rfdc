`timescale 1ns/1ps

// Independent AXI4 read engine, DDR/UI clock domain. All bursts use one AXI
// ID, so returned bursts are ordered. Four 64-byte DDR beats form a complete
// frame of eight 32-byte DAC beats. Credit is reserved at AR presentation
// (including an AR stalled before acceptance), not at R arrival. The FIFO
// free count must be conservative in the write clock domain.
//
// CANCEL/error never withdraws VALID or resets a live AXI transaction. Issued
// bursts drain without producing frames. A missing RLAST/timeout quarantines
// the engine until the real bus transaction retires; !busy is the only safe
// permission to clear FIFOs or replace descriptor storage.
module waveform_ddr_reader #(
    parameter integer MAX_OUTSTANDING = 4,
    parameter integer BURST_FRAMES = 16,
    parameter integer TIMEOUT_CYCLES = 300000
) (
    input wire clk, input wire rst_n, input wire start, input wire cancel,
    input wire [63:0] base_addr, input wire [31:0] total_beats,
    input wire [15:0] fifo_free_beats,
    output reg [63:0] m_axi_araddr, output reg [7:0] m_axi_arlen,
    output reg m_axi_arvalid, input wire m_axi_arready,
    input wire [511:0] m_axi_rdata, input wire [1:0] m_axi_rresp,
    input wire m_axi_rvalid, input wire m_axi_rlast, output wire m_axi_rready,
    output wire [2047:0] frame_data, output reg frame_valid, input wire frame_ready,
    output reg busy, output reg done, output reg error,
    output reg [31:0] error_code, output reg [63:0] error_offset
);
  localparam integer QW = $clog2(MAX_OUTSTANDING);
  localparam integer CREDIT_W = 11; // 1024-entry DAC FIFO contract.
  localparam [CREDIT_W-1:0] FIFO_CREDIT_MAX = 11'd1024;
  reg [8:0] burst_lengths [0:MAX_OUTSTANDING-1];
  reg [QW-1:0] head,tail;
  reg [QW:0] outstanding;
  reg [63:0] issue_addr, return_offset;
  reg [31:0] remaining;
  reg [CREDIT_W-1:0] reserved;
  wire [CREDIT_W-1:0] fifo_free_credit =
      (|fifo_free_beats[15:CREDIT_W]) ? FIFO_CREDIT_MAX : fifo_free_beats[CREDIT_W-1:0];
  reg [6:0] proposed_frames, pending_frames;
  reg [4:0] page_frames;
  reg [31:0] watchdog;
  reg [8:0] returned_in_burst;
  reg [1:0] slice;
  reg [2047:0] assembling;
  reg cancelled;
  wire ar_fire=m_axi_arvalid&&m_axi_arready;
  wire r_fire=m_axi_rvalid&&m_axi_rready;
  wire frame_fire=frame_valid&&frame_ready;
  wire retiring=r_fire&&m_axi_rlast;
  wire r_fault=r_fire && (m_axi_rresp!=0 || m_axi_rlast!=(returned_in_burst+1==burst_lengths[head]));
  wire draining=cancelled||cancel||error||r_fault;
  // The one-frame production instance deliberately keeps only one AXI
  // burst in flight.  Its credit is a physical ready indication rather than
  // a wide FIFO count, so another frame is not reserved until the first one
  // has retired into the FIFOs.  Wider standalone instances retain the
  // configured outstanding-read depth.
  wire reserve_new=busy&&!draining&&!m_axi_arvalid&&remaining!=0&&
                   ((BURST_FRAMES == 1) ? (outstanding == 0) :
                    (outstanding < MAX_OUTSTANDING)) &&
                   proposed_frames!=0;
  // Stop cannot revoke a frame already presented with VALID. The downstream
  // must keep accepting/discarding until busy clears before resetting FIFOs.
  assign frame_data=assembling;
  assign m_axi_rready=busy&&outstanding!=0&&(!frame_valid||frame_ready);
  integer channel,queue_slot;
  initial begin
    if(MAX_OUTSTANDING<2 || (MAX_OUTSTANDING & (MAX_OUTSTANDING-1))!=0 || MAX_OUTSTANDING>1024)
      $error("MAX_OUTSTANDING must be a power of two in 2..1024");
    if(BURST_FRAMES<1 || BURST_FRAMES>16 || TIMEOUT_CYCLES<1)
      $error("invalid burst/timeout configuration");
  end
  always @* begin
    proposed_frames = 7'd0;
    // The production playback-path instance uses BURST_FRAMES=1 because its
    // ready-derived credit deliberately admits one complete frame at a time.
    // Avoid retaining a 32-bit remaining-vs-burst comparator on that critical
    // path.  Standalone instances with wider bursts retain the general logic.
    if (BURST_FRAMES == 1) begin
      if (remaining != 0)
        proposed_frames = 7'd1;
    end else begin
      proposed_frames = BURST_FRAMES;
      // A burst is at most BURST_FRAMES (<=16) frames, so only the low bits of
      // the (up to 32-bit) remaining count can clamp it.  Reduce the high bits
      // with a cheap OR instead of a full 32-bit magnitude compare, which was
      // 15 logic levels on the 300 MHz AR-reservation path.
      if (!(|remaining[31:7]) && (remaining[6:0] < proposed_frames))
        proposed_frames = remaining[6:0];
    end
    // Base and every increment are 256-byte aligned, so issue_addr[11:8]
    // is the frame index within the current 4 KiB page.  There are exactly
    // 16 - index frames left in that page.  Keep this calculation narrow;
    // the previous 13-bit subtract/shift fed the 300 MHz AR enable path.
    page_frames = 5'd16 - {1'b0, issue_addr[11:8]};
    if (page_frames < proposed_frames)
      proposed_frames = page_frames;
    if(fifo_free_credit<=reserved) proposed_frames=0;
    else if(fifo_free_credit-reserved<proposed_frames)
      proposed_frames=fifo_free_credit-reserved;
  end
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      busy<=0;done<=0;error<=0;error_code<=0;error_offset<=0;
      for(queue_slot=0;queue_slot<MAX_OUTSTANDING;queue_slot=queue_slot+1) burst_lengths[queue_slot]<=0;
      m_axi_araddr<=0;m_axi_arlen<=0;m_axi_arvalid<=0;
      frame_valid<=0;assembling<=0;head<=0;tail<=0;outstanding<=0;
      issue_addr<=0;return_offset<=0;remaining<=0;reserved<=0;pending_frames<=0;
      watchdog<=0;returned_in_burst<=0;slice<=0;cancelled<=0;
    end else begin
      done<=0;
      if(start&&!busy) begin
        error<=0;error_code<=0;error_offset<=0;cancelled<=0;
        issue_addr<=base_addr;return_offset<=0;remaining<=total_beats;
        head<=0;tail<=0;outstanding<=0;reserved<=0;watchdog<=0;
        returned_in_burst<=0;slice<=0;frame_valid<=0;
        if(base_addr[7:0]!=0 || total_beats==0 ||
           base_addr+{24'd0,total_beats,8'd0}<base_addr) begin
          error<=1;error_code<=4;error_offset<=base_addr;
        end else busy<=1;
      end else if(busy) begin
        if(cancel) cancelled<=1;
        if(frame_fire) frame_valid<=0;
        if(reserve_new) begin
          m_axi_araddr<=issue_addr;m_axi_arlen<=(proposed_frames<<2)-1'b1;
          pending_frames<=proposed_frames;m_axi_arvalid<=1;
        end
        case({reserve_new,frame_fire})
          2'b10: reserved<=reserved+proposed_frames;
          2'b01: reserved<=reserved-1'b1;
          2'b11: reserved<=reserved+proposed_frames-1'b1;
          default: begin end
        endcase
        if(ar_fire) begin
          m_axi_arvalid<=0;
          burst_lengths[tail]<={2'b00,pending_frames}<<2;
          tail<=tail+1'b1;
          issue_addr<=issue_addr+({57'd0,pending_frames}<<8);
          remaining<=remaining-pending_frames;
        end
        case({ar_fire,retiring})
          2'b10: outstanding<=outstanding+1'b1;
          2'b01: outstanding<=outstanding-1'b1;
          default: begin end
        endcase
        if(r_fire) begin
          return_offset<=return_offset+64;
          if(m_axi_rlast) begin head<=head+1'b1;returned_in_burst<=0;end
          else if(returned_in_burst!=9'h1ff) returned_in_burst<=returned_in_burst+1'b1;
          if(!draining) begin
            // Static channel slices infer wiring/registers, not an 8x mux.
            for(channel=0;channel<8;channel=channel+1)
              assembling[channel*256+slice*64+:64]<=m_axi_rdata[channel*64+:64];
            if(slice==3) frame_valid<=1;
            slice<=slice+1'b1;
          end
          if(r_fault&&!error) begin error<=1;error_code<=2;error_offset<=return_offset;end
        end
        // Only count cycles in which the bus owes progress. Local FIFO
        // backpressure is not an AXI timeout; credit prevents buffer overrun.
        if(ar_fire||r_fire||(!m_axi_arvalid&&outstanding==0)||(!m_axi_arvalid&&!m_axi_rready)) watchdog<=0;
        else if(!error) begin
          if(watchdog==TIMEOUT_CYCLES-1) begin
            error<=1;error_code<=3;error_offset<=return_offset;
          end else watchdog<=watchdog+1'b1;
        end
        if(!m_axi_arvalid&&outstanding==0&&!frame_valid&&
           (remaining==0||cancelled||cancel||error)) begin
          busy<=0;done<=!draining;reserved<=0;slice<=0;
        end
      end
    end
  end
endmodule
