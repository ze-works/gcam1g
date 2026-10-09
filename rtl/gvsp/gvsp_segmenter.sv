// -----------------------------------------------------------------------------
// Module:      gvsp_segmenter
// Description: Splits an image byte stream into stream protocol packets. Emits
//              a zero length leader frame, then payload packets of the
//              configured size, then a trailer frame. The packet builder fills
//              in the actual packet contents.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module gvsp_segmenter #(
    parameter int unsigned IN_DATA_W     = 128,
    parameter int unsigned IN_KEEP_W     = IN_DATA_W / 8,
    parameter int unsigned MAX_PKT_BYTES = 8964
) (
    input wire logic clk,
    input wire logic rst_ni,

    input wire logic [15:0] pkt_payload_bytes_i,
    input wire logic [31:0] frame_size_bytes_i,
    input wire logic        new_frame_i,
    input wire logic [63:0] block_id_i,

    input  wire logic [IN_DATA_W-1:0] s_axis_tdata_i,
    input  wire logic [IN_KEEP_W-1:0] s_axis_tkeep_i,
    input  wire logic                 s_axis_tvalid_i,
    output logic                      s_axis_tready_o,
    input  wire logic                 s_axis_tuser_i,
    input  wire logic                 s_axis_tlast_i,

    output logic      [IN_DATA_W-1:0] m_axis_tdata_o,
    output logic      [IN_KEEP_W-1:0] m_axis_tkeep_o,
    output logic                      m_axis_tvalid_o,
    input  wire logic                 m_axis_tready_i,
    output logic                      m_axis_tuser_o,
    output logic                      m_axis_tlast_o,

    output logic [63:0] pkt_block_id_o,
    output logic [31:0] pkt_packet_id_o,
    output logic [15:0] pkt_payload_len_o,
    output logic        pkt_is_leader_o,
    output logic        pkt_is_trailer_o,
    output logic        pkt_is_payload_o
);

  localparam int unsigned BPB       = IN_DATA_W / 8;
  localparam int unsigned BUF_BYTES = 2 * BPB;
  localparam int unsigned CNT_W     = $clog2(BUF_BYTES + 1);

  typedef enum logic [2:0] {
    S_IDLE    = 3'd0,
    S_LEADER  = 3'd1,
    S_PAYLOAD = 3'd2,
    S_TRAILER = 3'd3,
    S_DONE    = 3'd4
  } state_e;

  state_e state_q, state_d;

  logic [63:0] block_id_q;
  logic [15:0] pkt_payload_bytes_q;
  logic [31:0] frame_size_bytes_q;

  logic [31:0] packet_id_q;
  logic [15:0] pkt_byte_cnt_q;
  logic [15:0] remaining_pkt_q;

  logic [7:0] buf_q[0:BUF_BYTES-1];
  localparam int unsigned PTR_W = $clog2(BUF_BYTES);
  logic [PTR_W-1:0] wr_ptr_q, rd_ptr_q;
  logic [CNT_W-1:0] buf_count_q;
  logic             in_eol_q;
  logic [     31:0] bytes_consumed_q;

  logic [CNT_W-1:0] in_byte_cnt_c;
  always_comb begin
    int unsigned k;
    in_byte_cnt_c = '0;
    for (k = 0; k < IN_KEEP_W; k++) begin
      if (s_axis_tkeep_i[k]) in_byte_cnt_c = in_byte_cnt_c + CNT_W'(1);
    end
  end

  logic [31:0] bytes_after_this_beat_c;
  logic        frame_end_this_beat_c;
  always_comb begin
    bytes_after_this_beat_c = bytes_consumed_q + 32'(in_byte_cnt_c);
    frame_end_this_beat_c   = (frame_size_bytes_q != 32'd0) &&
                              (bytes_after_this_beat_c >= frame_size_bytes_q);
  end

  logic in_ready_c;
  logic in_fire_c;

  always_comb begin
    in_ready_c = (state_q == S_PAYLOAD) && !in_eol_q && ((BUF_BYTES - int'(buf_count_q)) >= BPB);
    if ((state_q == S_IDLE) && s_axis_tvalid_i && !new_frame_i) in_ready_c = 1'b1;
  end
  assign s_axis_tready_o = in_ready_c;
  assign in_fire_c       = s_axis_tvalid_i && in_ready_c;

  logic [     15:0] remaining_pkt_c;
  logic [CNT_W-1:0] emit_bytes_c;
  logic             pkt_full_after_emit_c;
  logic             frame_last_payload_c;
  logic             payload_can_emit_c;
  logic             payload_pkt_sof_c;

  always_comb begin
    remaining_pkt_c = remaining_pkt_q;

    emit_bytes_c    = CNT_W'(BPB);
    if (16'(emit_bytes_c) > remaining_pkt_c) emit_bytes_c = CNT_W'(remaining_pkt_c);
    if (emit_bytes_c > buf_count_q) emit_bytes_c = buf_count_q;

    pkt_full_after_emit_c = (state_q == S_PAYLOAD) &&
                            (16'(emit_bytes_c) == remaining_pkt_c) &&
                            (emit_bytes_c != '0);

    frame_last_payload_c  = (state_q == S_PAYLOAD) &&
                            in_eol_q &&
                            (emit_bytes_c == buf_count_q) &&
                            !pkt_full_after_emit_c &&
                            (emit_bytes_c != '0);

    payload_can_emit_c = (state_q == S_PAYLOAD) &&
                         ((buf_count_q >= CNT_W'(BPB)) ||
                          ((buf_count_q != '0) && (16'(buf_count_q) >= remaining_pkt_c)) ||
                          ((buf_count_q != '0) && in_eol_q));

    payload_pkt_sof_c = (state_q == S_PAYLOAD) && (pkt_byte_cnt_q == 16'd0);
  end

  logic [IN_DATA_W-1:0] out_tdata_c;
  logic [IN_KEEP_W-1:0] out_tkeep_c;
  logic                 out_tvalid_c;
  logic                 out_tuser_c;
  logic                 out_tlast_c;
  logic [         15:0] out_payload_len_c;
  logic                 out_is_leader_c;
  logic                 out_is_trailer_c;
  logic                 out_is_payload_c;

  always_comb begin
    int unsigned i;
    out_tdata_c       = '0;
    out_tkeep_c       = '0;
    out_tvalid_c      = 1'b0;
    out_tuser_c       = 1'b0;
    out_tlast_c       = 1'b0;
    out_payload_len_c = '0;
    out_is_leader_c   = 1'b0;
    out_is_trailer_c  = 1'b0;
    out_is_payload_c  = 1'b0;

    unique case (state_q)
      S_LEADER: begin
        out_tvalid_c      = 1'b1;
        out_tuser_c       = 1'b1;
        out_tlast_c       = 1'b1;
        out_tkeep_c       = '0;
        out_tdata_c       = '0;
        out_payload_len_c = 16'd0;
        out_is_leader_c   = 1'b1;
      end
      S_PAYLOAD: begin
        out_tvalid_c = payload_can_emit_c;
        out_tuser_c  = payload_pkt_sof_c && payload_can_emit_c;
        out_tlast_c  = (pkt_full_after_emit_c || frame_last_payload_c) && payload_can_emit_c;
        for (i = 0; i < IN_KEEP_W; i++) begin
          out_tdata_c[i*8+:8] = buf_q[(int'(rd_ptr_q)+i)%BUF_BYTES];
          out_tkeep_c[i]      = (CNT_W'(i) < emit_bytes_c);
        end
        if (frame_last_payload_c) begin
          out_payload_len_c = pkt_byte_cnt_q + 16'(emit_bytes_c);
        end else begin
          out_payload_len_c = pkt_payload_bytes_q;
        end
        out_is_payload_c = 1'b1;
      end
      S_TRAILER: begin
        out_tvalid_c      = 1'b1;
        out_tuser_c       = 1'b1;
        out_tlast_c       = 1'b1;
        out_tkeep_c       = '0;
        out_tdata_c       = '0;
        out_payload_len_c = 16'd0;
        out_is_trailer_c  = 1'b1;
      end
      default: begin
      end
    endcase
  end

  assign m_axis_tdata_o    = out_tdata_c;
  assign m_axis_tkeep_o    = out_tkeep_c;
  assign m_axis_tvalid_o   = out_tvalid_c;
  assign m_axis_tuser_o    = out_tuser_c;
  assign m_axis_tlast_o    = out_tlast_c;
  assign pkt_block_id_o    = block_id_q;
  assign pkt_packet_id_o   = packet_id_q;
  assign pkt_payload_len_o = out_payload_len_c;
  assign pkt_is_leader_o   = out_is_leader_c;
  assign pkt_is_trailer_o  = out_is_trailer_c;
  assign pkt_is_payload_o  = out_is_payload_c;

  logic out_fire_c;
  assign out_fire_c = out_tvalid_c && m_axis_tready_i;

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      S_IDLE: begin
        if (new_frame_i) state_d = S_LEADER;
      end
      S_LEADER: begin
        if (out_fire_c) state_d = S_PAYLOAD;
      end
      S_PAYLOAD: begin
        if (out_fire_c && out_tlast_c && in_eol_q && (buf_count_q == emit_bytes_c)) begin
          state_d = S_TRAILER;
        end
        else if (in_eol_q && (buf_count_q == '0) && !out_fire_c) begin
          state_d = S_TRAILER;
        end
      end
      S_TRAILER: begin
        if (out_fire_c) state_d = S_DONE;
      end
      S_DONE: begin
        state_d = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

  logic [CNT_W-1:0] new_buf_count_c;
  logic [CNT_W-1:0] post_drain_count_c;
  always_comb begin
    post_drain_count_c = buf_count_q - (out_fire_c ? emit_bytes_c : CNT_W'(0));
    new_buf_count_c    = post_drain_count_c + (in_fire_c ? in_byte_cnt_c : CNT_W'(0));
  end

  always_ff @(posedge clk) begin
    int unsigned       i;
    int unsigned       src_idx;
    logic        [7:0] shifted      [0:BUF_BYTES-1];
    logic        [7:0] in_bytes     [0:IN_KEEP_W-1];
    logic        [7:0] merged       [0:BUF_BYTES-1];
    int unsigned       in_compact_n;

    if (!rst_ni) begin
      state_q             <= S_IDLE;
      block_id_q          <= '0;
      pkt_payload_bytes_q <= '0;
      remaining_pkt_q     <= '0;
      frame_size_bytes_q  <= '0;
      packet_id_q         <= '0;
      pkt_byte_cnt_q      <= '0;
      buf_count_q         <= '0;
      wr_ptr_q            <= '0;
      rd_ptr_q            <= '0;
      in_eol_q            <= 1'b0;
      bytes_consumed_q    <= '0;
      for (i = 0; i < BUF_BYTES; i++) buf_q[i] <= 8'h0;
    end else begin
      state_q <= state_d;

      if ((state_q == S_IDLE) && new_frame_i) begin
        block_id_q          <= block_id_i;
        pkt_payload_bytes_q <= pkt_payload_bytes_i;
        remaining_pkt_q     <= pkt_payload_bytes_i;
        frame_size_bytes_q  <= frame_size_bytes_i;
        wr_ptr_q            <= '0;
        rd_ptr_q            <= '0;
        packet_id_q         <= 32'd0;
        pkt_byte_cnt_q      <= 16'd0;
        buf_count_q         <= '0;
        in_eol_q            <= 1'b0;
        bytes_consumed_q    <= 32'd0;
      end

      if ((state_q == S_LEADER) && out_fire_c) begin
        packet_id_q     <= 32'd1;
        pkt_byte_cnt_q  <= 16'd0;
        remaining_pkt_q <= pkt_payload_bytes_q;
      end

      if (state_q == S_PAYLOAD) begin
        if (in_fire_c) begin
          for (i = 0; i < IN_KEEP_W; i++) in_bytes[i] = 8'h0;
          in_compact_n = 0;
          for (i = 0; i < IN_KEEP_W; i++) begin
            if (s_axis_tkeep_i[i]) begin
              in_bytes[in_compact_n] = s_axis_tdata_i[i*8+:8];
              in_compact_n           = in_compact_n + 1;
            end
          end
          for (i = 0; i < IN_KEEP_W; i++) begin
            if (i < in_compact_n) buf_q[(int'(wr_ptr_q)+i)%BUF_BYTES] <= in_bytes[i];
          end
          wr_ptr_q <= PTR_W'((int'(wr_ptr_q) + int'(in_byte_cnt_c)) % BUF_BYTES);
        end
        if (out_fire_c) begin
          rd_ptr_q <= PTR_W'((int'(rd_ptr_q) + int'(emit_bytes_c)) % BUF_BYTES);
        end

        if (out_fire_c) begin
          if (out_tlast_c) begin
            packet_id_q     <= packet_id_q + 32'd1;
            pkt_byte_cnt_q  <= 16'd0;
            remaining_pkt_q <= pkt_payload_bytes_q;
          end else begin
            pkt_byte_cnt_q  <= pkt_byte_cnt_q + 16'(emit_bytes_c);
            remaining_pkt_q <= remaining_pkt_q - 16'(emit_bytes_c);
          end
        end

        if (in_fire_c) begin
          bytes_consumed_q <= bytes_after_this_beat_c;
          if (frame_end_this_beat_c) in_eol_q <= 1'b1;
        end

        buf_count_q <= new_buf_count_c;
      end

      if ((state_q == S_TRAILER) && out_fire_c) begin
        packet_id_q <= packet_id_q + 32'd1;
      end

      if (state_q == S_DONE) begin
      end
    end
  end

`ifdef SIM_ONLY
  always_ff @(posedge clk) begin
    if (rst_ni) begin
      if (m_axis_tvalid_o === 1'b1 && pkt_is_payload_o === 1'b1) begin
        assert (m_axis_tkeep_o !== '0)
        else $error("gvsp_segmenter: payload beat with tkeep=0 at t=%0t", $time);
        assert (((m_axis_tkeep_o + {{(IN_KEEP_W - 1) {1'b0}}, 1'b1}) & m_axis_tkeep_o) === '0)
        else
          $error("gvsp_segmenter: tkeep=%b is not LSB-contiguous at t=%0t", m_axis_tkeep_o, $time);
      end
      assert (buf_count_q <= CNT_W'(BUF_BYTES))
      else $error("gvsp_segmenter: buf_count_q overflow=%0d", buf_count_q);
      if (state_q == S_PAYLOAD) begin
        assert (pkt_payload_bytes_q != 16'd0)
        else $error("gvsp_segmenter: pkt_payload_bytes_q=0 in S_PAYLOAD");
      end
    end
  end
`endif

endmodule : gvsp_segmenter

`default_nettype wire
