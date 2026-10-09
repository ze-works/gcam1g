// -----------------------------------------------------------------------------
// Module:      eth_wr_pkt
// Description: AXI4 write master that stores Ethernet frames in a DDR ring. One
//              frame per ring slot, with a two byte length prefix. The producer
//              index is published to software, which releases slots again
//              through the consumer index. Writing is disabled until software
//              has set a ring base address.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module eth_wr_pkt #(
    parameter int unsigned AXI_ADDR_W = 40,
    parameter int unsigned AXI_DATA_W = 128,
    parameter int unsigned AXI_ID_W = 4,
    parameter int unsigned BURST_LEN = 16,
    parameter int unsigned SLOT_SIZE_B  = 8192,
    parameter int unsigned NUM_SLOTS = 16384,
    parameter bit DROP_ON_FULL = 1'b1,
    parameter int unsigned MAX_W_OUT = 8,
    parameter int unsigned PSNAP_DEPTH = 16
) (
    input wire logic clk,
    input wire logic rst_ni,

    input wire logic drop_on_full_i,

    input  wire logic [AXI_ADDR_W-1:0] ring_base_addr_i,
    input  wire logic [          31:0] consumer_idx_i,
    output logic      [          31:0] producer_idx_o,
    output logic                       pkt_done_o,
    output logic                       err_o,

    input  wire logic [  AXI_DATA_W-1:0] s_axis_tdata_i,
    input  wire logic [AXI_DATA_W/8-1:0] s_axis_tkeep_i,
    input  wire logic                    s_axis_tvalid_i,
    output logic                         s_axis_tready_o,
    input  wire logic                    s_axis_tlast_i,

    output logic      [    AXI_ID_W-1:0] m_axi_awid_o,
    output logic      [  AXI_ADDR_W-1:0] m_axi_awaddr_o,
    output logic      [             7:0] m_axi_awlen_o,
    output logic      [             2:0] m_axi_awsize_o,
    output logic      [             1:0] m_axi_awburst_o,
    output logic                         m_axi_awvalid_o,
    input  wire logic                    m_axi_awready_i,
    output logic      [  AXI_DATA_W-1:0] m_axi_wdata_o,
    output logic      [AXI_DATA_W/8-1:0] m_axi_wstrb_o,
    output logic                         m_axi_wlast_o,
    output logic                         m_axi_wvalid_o,
    input  wire logic                    m_axi_wready_i,
    input  wire logic [    AXI_ID_W-1:0] m_axi_bid_i,
    input  wire logic [             1:0] m_axi_bresp_i,
    input  wire logic                    m_axi_bvalid_i,
    output logic                         m_axi_bready_o
);

  localparam int unsigned BYTES_PER_BEAT = AXI_DATA_W / 8;
  localparam int unsigned LOG2_BPB = $clog2(BYTES_PER_BEAT);
  localparam int unsigned FIFO_DEPTH = BURST_LEN * 4;
  localparam int unsigned FIFO_AW = $clog2(FIFO_DEPTH);
  localparam int unsigned FIFO_ENTRY_W = AXI_DATA_W + BYTES_PER_BEAT + 1;
  localparam int unsigned BOUNDARY_BYTES = 4096;
  localparam logic [1:0] AXI_BURST_INCR = 2'b01;
  localparam logic [1:0] AXI_RESP_OKAY = 2'b00;
  localparam int unsigned SLOT_IDX_W = $clog2(NUM_SLOTS);

  typedef enum logic [2:0] {
    S_IDLE,
    S_ACTIVE,
    S_AW_ISSUE,
    S_W_BEATS,
    S_DRAIN,
    S_DONE,
    S_DROP
  } state_e;
  state_e state_q, state_d;

  logic [3:0] wout_q, wout_d;
  logic wout_inc, wout_dec;

  logic [31:0] producer_q, producer_d;
  logic err_q, err_d;
  logic pkt_done_q, pkt_done_d;

  logic [31:0] issue_idx_q, issue_idx_d;
  logic [15:0] aw_cnt_q, aw_cnt_d;
  logic [15:0] b_cnt_q, b_cnt_d;
  logic aw_inc;
  localparam int unsigned PSNAP_AW = $clog2(PSNAP_DEPTH);
  logic [15:0] psnap_mem_q[PSNAP_DEPTH];
  logic [PSNAP_AW:0] psnap_wptr_q, psnap_rptr_q;
  logic psnap_full, psnap_empty, psnap_push, psnap_pop;
  assign psnap_empty = (psnap_wptr_q == psnap_rptr_q);
  assign psnap_full  = (psnap_wptr_q[PSNAP_AW-1:0] == psnap_rptr_q[PSNAP_AW-1:0]) &&
                       (psnap_wptr_q[PSNAP_AW] != psnap_rptr_q[PSNAP_AW]);

  logic ring_full;
  logic ring_armed;
  assign ring_armed = (ring_base_addr_i != '0);
  assign ring_full = !ring_armed
                     || ((issue_idx_q - consumer_idx_i) >= 32'(NUM_SLOTS)) || psnap_full;

  logic [AXI_ADDR_W-1:0] slot_addr;
  assign slot_addr = ring_base_addr_i +
                     (AXI_ADDR_W'(issue_idx_q[SLOT_IDX_W-1:0]) * AXI_ADDR_W'(SLOT_SIZE_B));

  logic [7:0] burst_beats_q, burst_beats_d;
  logic [7:0] beats_left_q, beats_left_d;
  logic [7:0] pending_beats_q, pending_beats_d;
  logic [AXI_ADDR_W-1:0] burst_start_addr_q, burst_start_addr_d;
  logic burst_has_last_q, burst_has_last_d;

  logic awvalid_q, awvalid_d;
  logic [AXI_ADDR_W-1:0] awaddr_q, awaddr_d;
  logic [7:0] awlen_q, awlen_d;
  logic wvalid_q, wvalid_d;
  logic [AXI_DATA_W-1:0] wdata_q, wdata_d;
  logic [BYTES_PER_BEAT-1:0] wstrb_q, wstrb_d;
  logic wlast_q, wlast_d;

  logic [FIFO_ENTRY_W-1:0] fifo_mem_q[FIFO_DEPTH];
  logic [FIFO_AW:0] fifo_wptr_q, fifo_rptr_q;
  logic fifo_push, fifo_pop;
  logic fifo_full, fifo_empty;
  logic [    AXI_DATA_W-1:0] fifo_rd_data;
  logic [BYTES_PER_BEAT-1:0] fifo_rd_strb;
  logic                      fifo_rd_last;

  assign fifo_empty = (fifo_wptr_q == fifo_rptr_q);
  assign fifo_full  = (fifo_wptr_q[FIFO_AW-1:0] == fifo_rptr_q[FIFO_AW-1:0]) &&
                      (fifo_wptr_q[FIFO_AW] != fifo_rptr_q[FIFO_AW]);
  assign {fifo_rd_data, fifo_rd_strb, fifo_rd_last} = fifo_mem_q[fifo_rptr_q[FIFO_AW-1:0]];

  logic [11:0] cur_addr_low12;
  logic [12:0] bytes_to_4k;
  logic [12:0] beats_to_4k_full;
  logic [ 7:0] max_burst_beats;
  logic        w_slot_free;
  always_comb begin
    cur_addr_low12   = burst_start_addr_q[11:0];
    bytes_to_4k      = 13'(BOUNDARY_BYTES) - 13'({1'b0, cur_addr_low12});
    beats_to_4k_full = bytes_to_4k >> LOG2_BPB;
    if (beats_to_4k_full >= 13'(BURST_LEN)) max_burst_beats = 8'(BURST_LEN);
    else max_burst_beats = 8'(beats_to_4k_full);
    w_slot_free = (!wvalid_q) || (wvalid_q && m_axi_wready_i);
  end

  logic s_ready, in_accept;
  always_comb begin
    s_ready = ((state_q == S_ACTIVE) && !fifo_full) || (state_q == S_DROP);
  end
  assign in_accept = s_ready && s_axis_tvalid_i;
  assign fifo_push = in_accept && (state_q == S_ACTIVE);

  logic beat_completes_burst;
  always_comb begin
    beat_completes_burst = 1'b0;
    if (in_accept) begin
      if ((pending_beats_q + 8'd1) >= max_burst_beats) beat_completes_burst = 1'b1;
      if (s_axis_tlast_i) beat_completes_burst = 1'b1;
    end
  end

  always_comb begin
    state_d            = state_q;
    producer_d         = producer_q;
    err_d              = err_q;
    pkt_done_d         = 1'b0;
    issue_idx_d        = issue_idx_q;
    psnap_push         = 1'b0;
    pending_beats_d    = pending_beats_q;
    burst_start_addr_d = burst_start_addr_q;
    burst_has_last_d   = burst_has_last_q;
    burst_beats_d      = burst_beats_q;
    beats_left_d       = beats_left_q;
    awaddr_d           = awaddr_q;
    awlen_d            = awlen_q;
    wout_d             = wout_q;
    fifo_pop           = 1'b0;
    wvalid_d           = wvalid_q;
    wdata_d            = wdata_q;
    wstrb_d            = wstrb_q;
    wlast_d            = wlast_q;

    if (wvalid_q && m_axi_wready_i) begin
      wvalid_d = 1'b0;
      wlast_d  = 1'b0;
    end
    wout_inc = 1'b0;
    wout_dec = 1'b0;
    if (m_axi_bvalid_i && (wout_q != '0)) begin
      wout_dec = 1'b1;
      if (m_axi_bresp_i != AXI_RESP_OKAY) err_d = 1'b1;
    end

    case (state_q)
      S_IDLE: begin
        if (s_axis_tvalid_i && !ring_full) begin
          burst_start_addr_d = slot_addr;
          pending_beats_d    = '0;
          burst_has_last_d   = 1'b0;
          state_d            = S_ACTIVE;
        end else if (s_axis_tvalid_i && ring_full && DROP_ON_FULL && drop_on_full_i) begin
          state_d = S_DROP;
        end
      end

      S_DROP: begin
        if (in_accept && s_axis_tlast_i) state_d = S_IDLE;
      end

      S_ACTIVE: begin
        if (in_accept) begin
          pending_beats_d = pending_beats_q + 8'd1;
          if (s_axis_tlast_i) burst_has_last_d = 1'b1;
          if (beat_completes_burst) begin
            burst_beats_d = pending_beats_q + 8'd1;
            state_d       = S_AW_ISSUE;
          end
        end
      end

      S_AW_ISSUE: begin
        if (!awvalid_q) begin
          awaddr_d = burst_start_addr_q;
          awlen_d  = burst_beats_q - 8'd1;
        end
        if (awvalid_q && m_axi_awready_i) begin
          beats_left_d = burst_beats_q;
          state_d      = S_W_BEATS;
        end
      end

      S_W_BEATS: begin
        if (w_slot_free && !fifo_empty && (beats_left_q > 0)) begin
          wdata_d      = fifo_rd_data;
          wstrb_d      = fifo_rd_strb;
          wvalid_d     = 1'b1;
          wlast_d      = (beats_left_q == 8'd1);
          fifo_pop     = 1'b1;
          beats_left_d = beats_left_q - 8'd1;
        end
        if ((beats_left_q == 8'd0) && (!wvalid_q || (wvalid_q && m_axi_wready_i))) begin
          burst_start_addr_d = burst_start_addr_q +
                               AXI_ADDR_W'(burst_beats_q) * AXI_ADDR_W'(BYTES_PER_BEAT);
          pending_beats_d = '0;
          wout_inc = 1'b1;
          if (burst_has_last_q) begin
            burst_has_last_d = 1'b0;
            psnap_push       = 1'b1;
            issue_idx_d      = issue_idx_q + 32'd1;
            state_d          = S_IDLE;
          end else begin
            state_d = S_ACTIVE;
          end
        end
      end

      default: state_d = S_IDLE;
    endcase

    aw_inc    = awvalid_q && m_axi_awready_i;
    aw_cnt_d  = aw_cnt_q + 16'(aw_inc);
    b_cnt_d   = b_cnt_q + 16'(wout_dec);
    wout_d    = wout_q + 4'(wout_inc) - 4'(wout_dec);

    psnap_pop = 1'b0;
    if (!psnap_empty && (b_cnt_q == psnap_mem_q[psnap_rptr_q[PSNAP_AW-1:0]])) begin
      producer_d = producer_q + 32'd1;
      pkt_done_d = 1'b1;
      psnap_pop  = 1'b1;
    end
  end

  always_comb begin
    awvalid_d = awvalid_q;
    if (awvalid_q && m_axi_awready_i) awvalid_d = 1'b0;
    else if ((state_q == S_AW_ISSUE) && !awvalid_q && (wout_q < 4'(MAX_W_OUT))) awvalid_d = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      state_q            <= S_IDLE;
      producer_q         <= 32'd0;
      issue_idx_q        <= 32'd0;
      aw_cnt_q           <= 16'd0;
      b_cnt_q            <= 16'd0;
      psnap_wptr_q       <= '0;
      psnap_rptr_q       <= '0;
      err_q              <= 1'b0;
      pkt_done_q         <= 1'b0;
      pending_beats_q    <= '0;
      burst_start_addr_q <= '0;
      burst_has_last_q   <= 1'b0;
      burst_beats_q      <= '0;
      beats_left_q       <= '0;
      awvalid_q          <= 1'b0;
      awaddr_q           <= '0;
      awlen_q            <= '0;
      wvalid_q           <= 1'b0;
      wdata_q            <= '0;
      wstrb_q            <= '0;
      wlast_q            <= 1'b0;
      wout_q             <= '0;
      fifo_wptr_q        <= '0;
      fifo_rptr_q        <= '0;
    end else begin
      state_q     <= state_d;
      producer_q  <= producer_d;
      issue_idx_q <= issue_idx_d;
      aw_cnt_q    <= aw_cnt_d;
      b_cnt_q     <= b_cnt_d;
      if (psnap_push && !psnap_full) begin
        psnap_mem_q[psnap_wptr_q[PSNAP_AW-1:0]] <= aw_cnt_q;
        psnap_wptr_q                            <= psnap_wptr_q + 1'b1;
      end
      if (psnap_pop && !psnap_empty) begin
        psnap_rptr_q <= psnap_rptr_q + 1'b1;
      end
      err_q              <= err_d;
      pkt_done_q         <= pkt_done_d;
      pending_beats_q    <= pending_beats_d;
      burst_start_addr_q <= burst_start_addr_d;
      burst_has_last_q   <= burst_has_last_d;
      burst_beats_q      <= burst_beats_d;
      beats_left_q       <= beats_left_d;
      awvalid_q          <= awvalid_d;
      awaddr_q           <= awaddr_d;
      awlen_q            <= awlen_d;
      wvalid_q           <= wvalid_d;
      wdata_q            <= wdata_d;
      wstrb_q            <= wstrb_d;
      wlast_q            <= wlast_d;
      wout_q             <= wout_d;
      if (fifo_push && !fifo_full) begin
        fifo_mem_q[fifo_wptr_q[FIFO_AW-1:0]] <= {s_axis_tdata_i, s_axis_tkeep_i, s_axis_tlast_i};
        fifo_wptr_q                          <= fifo_wptr_q + 1'b1;
      end
      if (fifo_pop && !fifo_empty) begin
        fifo_rptr_q <= fifo_rptr_q + 1'b1;
      end
    end
  end

  always_comb begin
    s_axis_tready_o = s_ready;
    producer_idx_o  = producer_q;
    pkt_done_o      = pkt_done_q;
    err_o           = err_q;
    m_axi_awid_o    = '0;
    m_axi_awaddr_o  = awaddr_q;
    m_axi_awlen_o   = awlen_q;
    m_axi_awsize_o  = 3'(LOG2_BPB);
    m_axi_awburst_o = AXI_BURST_INCR;
    m_axi_awvalid_o = awvalid_q;
    m_axi_wdata_o   = wdata_q;
    m_axi_wstrb_o   = wstrb_q;
    m_axi_wlast_o   = wlast_q;
    m_axi_wvalid_o  = wvalid_q;
    m_axi_bready_o  = (wout_q != '0);
  end

  logic _unused_ok;
  assign _unused_ok = &{1'b0, m_axi_bid_i};

endmodule : eth_wr_pkt

`default_nettype wire
