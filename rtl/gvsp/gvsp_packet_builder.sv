// -----------------------------------------------------------------------------
// Module:      gvsp_packet_builder
// Description: Builds GVSP stream packets. Turns the per-packet
//              side band from the segmenter into a UDP payload byte stream:
//              leader, data packets and trailer, in the extended identifier
//              format.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module gvsp_packet_builder
  import gvsp_proto_pkg::*;
#(
    parameter int unsigned ETH_BYTES = 1,
    parameter int unsigned IN_DATA_W = 128,
    parameter int unsigned IN_KEEP_W = IN_DATA_W / 8
) (
    input wire logic clk,
    input wire logic rst_ni,

    input  wire logic        pkt_valid_i,
    output logic             pkt_ready_o,
    input  wire logic [63:0] pkt_block_id_i,
    input  wire logic [31:0] pkt_packet_id_i,
    input  wire logic [15:0] pkt_payload_len_i,
    input  wire logic        pkt_is_leader_i,
    input  wire logic        pkt_is_trailer_i,
    input  wire logic        pkt_is_payload_i,
    input  wire logic [31:0] pkt_dst_ip_i,
    input  wire logic [15:0] pkt_dst_port_i,
    input  wire logic [15:0] pkt_status_i,

    input  wire logic [IN_DATA_W-1:0] s_axis_tdata_i,
    input  wire logic [IN_KEEP_W-1:0] s_axis_tkeep_i,
    input  wire logic                 s_axis_tvalid_i,
    output logic                      s_axis_tready_o,
    input  wire logic                 s_axis_tlast_i,

    input wire logic [31:0] width_i,
    input wire logic [31:0] height_i,
    input wire logic [31:0] pixel_format_i,
    input wire logic [63:0] timestamp_i,

    output logic      [ETH_BYTES*8-1:0] udp_byte_o,
    output logic                        udp_valid_o,
    input  wire logic                   udp_ready_i,
    output logic                        udp_sof_o,
    output logic                        udp_eof_o,
    output logic      [           31:0] udp_dst_ip_o,
    output logic      [           15:0] udp_dst_port_o
);

  initial begin
    if (IN_DATA_W != 128) begin
      $error("gvsp_packet_builder: IN_DATA_W must be 128 (got %0d)", IN_DATA_W);
    end
    if (IN_KEEP_W != IN_DATA_W / 8) begin
      $error("gvsp_packet_builder: IN_KEEP_W must be IN_DATA_W/8");
    end
  end

  localparam int unsigned HDR_BYTES = GVSP_PKT_HEADER_OFFSET + GVSP_HDR_DATA_OFFSET;
  localparam int unsigned BLOCK_ID_POS = GVSP_PKT_HEADER_OFFSET + GVSP_HDR_BLOCK_ID_OFFSET;
  localparam int unsigned PACKET_INFOS_POS = GVSP_PKT_HEADER_OFFSET + GVSP_HDR_PACKET_INFOS_OFFSET;
  localparam int unsigned IMAGE_POS = GVSP_LEADER_IMAGE_INFOS_OFFSET;
  localparam int unsigned LEADER_BODY_BYTES = IMAGE_POS + GVSP_IMG_Y_PADDING_OFFSET + GVSP_IMG_Y_PADDING_WIDTH;
  localparam int unsigned TRAILER_BODY_BYTES = GVSP_TRAILER_DATA0_OFFSET + GVSP_TRAILER_DATA0_WIDTH;

  initial begin
    if (HDR_BYTES % ETH_BYTES != 0 || LEADER_BODY_BYTES % ETH_BYTES != 0 ||
        TRAILER_BODY_BYTES % ETH_BYTES != 0)
      $error("gvsp_packet_builder: header/leader/trailer lengths must be multiples of ETH_BYTES");
  end

  typedef enum logic [3:0] {
    S_IDLE         = 4'd0,
    S_HDR          = 4'd1,
    S_LEADER_BODY  = 4'd9,
    S_TRAILER_BODY = 4'd10,
    S_PAYLOAD_PLD  = 4'd11,
    S_DONE         = 4'd12
  } state_e;

  state_e state_q, state_d;

  logic [15:0] block_id_q;
  logic [23:0] packet_id_q;
  logic [15:0] payload_len_q;
  logic        is_leader_q;
  logic        is_trailer_q;
  logic        is_payload_q;
  logic [31:0] dst_ip_q;
  logic [15:0] dst_port_q;
  logic [15:0] status_q;

  logic [ 7:0] pkt_fmt_q;

  logic [31:0] width_q;
  logic [31:0] height_q;
  logic [31:0] pixel_format_q;
  logic [63:0] timestamp_q;

  logic [15:0] pld_cnt_q;
  logic [15:0] pld_cnt_d;

  logic [ 5:0] body_cnt_q;
  logic [ 5:0] body_cnt_d;
  function automatic logic [7:0] be_field_f(input int i, input int unsigned off, input int unsigned w,
                                            input logic [63:0] v);
    if (i >= int'(off) && i < int'(off + w)) return v[(int'(off + w) - 1 - i)*8+:8];
    return 8'h00;
  endfunction

  function automatic logic [7:0] gvsp_hdr_byte_f(input int i);
    return be_field_f(i, GVSP_PKT_STATUS_OFFSET, GVSP_PKT_STATUS_WIDTH, 64'(status_q))
         | be_field_f(i, BLOCK_ID_POS, GVSP_HDR_BLOCK_ID_WIDTH, 64'(block_id_q))
         | be_field_f(i, PACKET_INFOS_POS, GVSP_HDR_PACKET_INFOS_WIDTH,
                      (64'(pkt_fmt_q) << GVSP_CONTENT_TYPE_POS) | (64'(packet_id_q) & GVSP_PACKET_ID_MASK));
  endfunction

  function automatic logic [7:0] leader_body_byte_f(input int i);
    return be_field_f(i, GVSP_LEADER_PAYLOAD_TYPE_OFFSET, GVSP_LEADER_PAYLOAD_TYPE_WIDTH,
                      GVSP_PAYLOAD_TYPE_IMAGE)
         | be_field_f(i, GVSP_LEADER_TS_HIGH_OFFSET, GVSP_LEADER_TS_HIGH_WIDTH, 64'(timestamp_q[63:32]))
         | be_field_f(i, GVSP_LEADER_TS_LOW_OFFSET, GVSP_LEADER_TS_LOW_WIDTH, 64'(timestamp_q[31:0]))
         | be_field_f(i, IMAGE_POS + GVSP_IMG_PIXEL_FORMAT_OFFSET, GVSP_IMG_PIXEL_FORMAT_WIDTH,
                      64'(pixel_format_q))
         | be_field_f(i, IMAGE_POS + GVSP_IMG_WIDTH_OFFSET, GVSP_IMG_WIDTH_WIDTH, 64'(width_q))
         | be_field_f(i, IMAGE_POS + GVSP_IMG_HEIGHT_OFFSET, GVSP_IMG_HEIGHT_WIDTH, 64'(height_q));
  endfunction

  function automatic logic [7:0] trailer_body_byte_f(input int i);
    return be_field_f(i, GVSP_TRAILER_PAYLOAD_TYPE_OFFSET, GVSP_TRAILER_PAYLOAD_TYPE_WIDTH,
                      GVSP_PAYLOAD_TYPE_IMAGE);
  endfunction

  localparam int unsigned LEADER_BODY_BEATS  = LEADER_BODY_BYTES / ETH_BYTES;
  localparam int unsigned TRAILER_BODY_BEATS = TRAILER_BODY_BYTES / ETH_BYTES;
  logic [ETH_BYTES*8-1:0] leader_body_word, trailer_body_word;
  always_comb begin
    for (int b = 0; b < ETH_BYTES; b++) begin
      leader_body_word[b*8+:8]  = leader_body_byte_f(int'(body_cnt_q) * ETH_BYTES + b);
      trailer_body_word[b*8+:8] = trailer_body_byte_f(int'(body_cnt_q) * ETH_BYTES + b);
    end
  end

  localparam int unsigned GVSP_HDR_BEATS = HDR_BYTES / ETH_BYTES;
  logic [3:0] hdr_idx_q, hdr_idx_d;
  logic [ETH_BYTES*8-1:0] gvsp_hdr_word;
  always_comb begin
    for (int b = 0; b < ETH_BYTES; b++)
    gvsp_hdr_word[b*8+:8] = gvsp_hdr_byte_f(int'(hdr_idx_q) * ETH_BYTES + b);
  end

  logic [  3:0] beat_idx_q;
  logic [  3:0] beat_idx_d;
  logic [127:0] beat_data_q;
  logic [127:0] beat_data_d;
  logic [ 15:0] beat_keep_q;
  logic [ 15:0] beat_keep_d;
  logic         beat_valid_q;
  logic         beat_valid_d;
  logic         beat_last_q;
  logic         beat_last_d;

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      block_id_q     <= 16'h0;
      packet_id_q    <= 24'h0;
      payload_len_q  <= 16'h0;
      is_leader_q    <= 1'b0;
      is_trailer_q   <= 1'b0;
      is_payload_q   <= 1'b0;
      dst_ip_q       <= 32'h0;
      dst_port_q     <= 16'h0;
      status_q       <= 16'h0;
      pkt_fmt_q      <= 8'h0;
      width_q        <= 32'h0;
      height_q       <= 32'h0;
      pixel_format_q <= 32'h0;
      timestamp_q    <= 64'h0;
    end else if ((state_q == S_IDLE) && pkt_valid_i && pkt_ready_o) begin
      block_id_q     <= (pkt_block_id_i[15:0] == 16'h0) ? 16'h1 : pkt_block_id_i[15:0];
      packet_id_q    <= pkt_packet_id_i[23:0];
      payload_len_q  <= pkt_payload_len_i;
      is_leader_q    <= pkt_is_leader_i;
      is_trailer_q   <= pkt_is_trailer_i;
      is_payload_q   <= pkt_is_payload_i;
      dst_ip_q       <= pkt_dst_ip_i;
      dst_port_q     <= pkt_dst_port_i;
      status_q       <= pkt_status_i;
      width_q        <= width_i;
      height_q       <= height_i;
      pixel_format_q <= pixel_format_i;
      timestamp_q    <= timestamp_i;
      if (pkt_is_leader_i) begin
        pkt_fmt_q <= 8'(GVSP_CT_LEADER);
      end else if (pkt_is_trailer_i) begin
        pkt_fmt_q <= 8'(GVSP_CT_TRAILER);
      end else if (pkt_is_payload_i) begin
        pkt_fmt_q <= 8'(GVSP_CT_PAYLOAD);
      end else begin
        pkt_fmt_q <= 8'h0;
      end
    end
  end

  logic [4:0] pop_q;

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      state_q      <= S_IDLE;
      pld_cnt_q    <= 16'h0;
      body_cnt_q   <= 6'h0;
      beat_idx_q   <= 4'h0;
      hdr_idx_q    <= 4'h0;
      beat_data_q  <= 128'h0;
      beat_keep_q  <= 16'h0;
      pop_q        <= 5'h0;
      beat_valid_q <= 1'b0;
      beat_last_q  <= 1'b0;
    end else begin
      state_q     <= state_d;
      pld_cnt_q   <= pld_cnt_d;
      body_cnt_q  <= body_cnt_d;
      beat_idx_q  <= beat_idx_d;
      hdr_idx_q   <= hdr_idx_d;
      beat_data_q <= beat_data_d;
      beat_keep_q <= beat_keep_d;
      begin
        logic [4:0] c2;
        c2 = 5'h0;
        for (int i3 = 0; i3 < IN_KEEP_W; i3++) c2 = c2 + 5'(beat_keep_d[i3]);
        pop_q <= c2;
      end
      beat_valid_q <= beat_valid_d;
      beat_last_q  <= beat_last_d;
    end
  end

  logic [            3:0] sel_lane;
  logic [            7:0] payload_byte_c;
  logic [ETH_BYTES*8-1:0] payload_word_c;
  logic                   beat_last_byte_c;
  logic [            4:0] pop_c;

  always_comb begin
    logic        [3:0] lanes[0:ETH_BYTES-1];
    int unsigned       idx;
    for (int b = 0; b < ETH_BYTES; b++) begin
      idx = int'(beat_idx_q) + b;
      lanes[b] = (idx < IN_KEEP_W) ? 4'(idx) : 4'h0;
    end
    pop_c    = pop_q;
    sel_lane = lanes[0];
    for (int b = 0; b < ETH_BYTES; b++) payload_word_c[b*8+:8] = beat_data_q[lanes[b]*8+:8];
    payload_byte_c = payload_word_c[7:0];
    if (pop_q == 0) beat_last_byte_c = 1'b1;
    else beat_last_byte_c = ((int'(beat_idx_q) + ETH_BYTES) >= int'(pop_q));
  end

  always_comb begin
    state_d         = state_q;
    pld_cnt_d       = pld_cnt_q;
    body_cnt_d      = body_cnt_q;
    beat_idx_d      = beat_idx_q;
    hdr_idx_d       = hdr_idx_q;
    beat_data_d     = beat_data_q;
    beat_keep_d     = beat_keep_q;
    beat_valid_d    = beat_valid_q;
    beat_last_d     = beat_last_q;
    pkt_ready_o     = 1'b0;
    s_axis_tready_o = 1'b0;
    udp_byte_o      = '0;
    udp_valid_o     = 1'b0;
    udp_sof_o       = 1'b0;
    udp_eof_o       = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        pkt_ready_o = 1'b1;
        if (pkt_valid_i) begin
          state_d      = S_HDR;
          pld_cnt_d    = 16'h0;
          body_cnt_d   = 6'h0;
          beat_idx_d   = 4'h0;
          beat_valid_d = 1'b0;
          beat_last_d  = 1'b0;
        end
      end

      S_HDR: begin
        udp_valid_o = 1'b1;
        udp_byte_o  = gvsp_hdr_word;
        if (hdr_idx_q == 4'h0) udp_sof_o = 1'b1;
        if (int'(hdr_idx_q) == GVSP_HDR_BEATS - 1) begin
          if (is_payload_q && (payload_len_q == 16'h0)) begin
            udp_eof_o = 1'b1;
          end
          if (udp_ready_i) begin
            hdr_idx_d = 4'h0;
            if (is_leader_q) begin
              state_d    = S_LEADER_BODY;
              body_cnt_d = 6'h0;
            end else if (is_trailer_q) begin
              state_d    = S_TRAILER_BODY;
              body_cnt_d = 6'h0;
            end else if (is_payload_q && (payload_len_q == 16'h0)) begin
              state_d = S_DONE;
            end else begin
              state_d = S_PAYLOAD_PLD;
            end
          end
        end else if (udp_ready_i) begin
          hdr_idx_d = hdr_idx_q + 4'h1;
        end
      end

      S_LEADER_BODY: begin
        udp_valid_o = 1'b1;
        udp_byte_o  = leader_body_word;
        if (int'(body_cnt_q) == LEADER_BODY_BEATS - 1) begin
          udp_eof_o = 1'b1;
        end
        if (udp_ready_i) begin
          if (int'(body_cnt_q) == LEADER_BODY_BEATS - 1) begin
            state_d = S_DONE;
          end else begin
            body_cnt_d = body_cnt_q + 6'h1;
          end
        end
      end

      S_TRAILER_BODY: begin
        udp_valid_o = 1'b1;
        udp_byte_o  = trailer_body_word;
        if (int'(body_cnt_q) == TRAILER_BODY_BEATS - 1) begin
          udp_eof_o = 1'b1;
        end
        if (udp_ready_i) begin
          if (int'(body_cnt_q) == TRAILER_BODY_BEATS - 1) begin
            state_d = S_DONE;
          end else begin
            body_cnt_d = body_cnt_q + 6'h1;
          end
        end
      end

      S_PAYLOAD_PLD: begin
        if (!beat_valid_q) begin
          s_axis_tready_o = 1'b1;
          if (s_axis_tvalid_i) begin
            beat_data_d  = s_axis_tdata_i;
            beat_keep_d  = s_axis_tkeep_i;
            beat_idx_d   = 4'h0;
            beat_valid_d = 1'b1;
            beat_last_d  = s_axis_tlast_i;
          end
        end else begin
          udp_valid_o = 1'b1;
          udp_byte_o  = payload_word_c;
          if (beat_last_q && beat_last_byte_c) begin
            udp_eof_o = 1'b1;
          end
          if (udp_ready_i) begin
            pld_cnt_d = pld_cnt_q + 16'(ETH_BYTES);
            if (beat_last_q && beat_last_byte_c) begin
              state_d      = S_DONE;
              beat_valid_d = 1'b0;
              beat_last_d  = 1'b0;
            end else if (beat_last_byte_c) begin
              s_axis_tready_o = 1'b1;
              if (s_axis_tvalid_i) begin
                beat_data_d  = s_axis_tdata_i;
                beat_keep_d  = s_axis_tkeep_i;
                beat_idx_d   = 4'h0;
                beat_valid_d = 1'b1;
                beat_last_d  = s_axis_tlast_i;
              end else begin
                beat_valid_d = 1'b0;
                beat_idx_d   = 4'h0;
              end
            end else begin
              beat_idx_d = beat_idx_q + 4'(ETH_BYTES);
            end
          end
        end
      end

      S_DONE: begin
        state_d = S_IDLE;
      end

      default: begin
        state_d = S_IDLE;
      end
    endcase
  end

  assign udp_dst_ip_o   = dst_ip_q;
  assign udp_dst_port_o = dst_port_q;

`ifdef SIM_ONLY
  always_ff @(posedge clk) begin
    if (rst_ni) begin
      if ((state_q == S_IDLE) && pkt_valid_i && pkt_ready_o) begin
        assert (($countones({pkt_is_leader_i, pkt_is_trailer_i, pkt_is_payload_i}) == 1))
        else $error("gvsp_packet_builder: pkt_is_{leader,trailer,payload} must be one-hot");
        if (pkt_is_trailer_i) begin
          assert (pkt_payload_len_i == 16'h0)
          else
            $error(
                "gvsp_packet_builder: Trailer with payload_len=%0d (must be 0)", pkt_payload_len_i
            );
        end
      end
      if ((state_q == S_PAYLOAD_PLD) && is_payload_q && (payload_len_q != 16'h0)) begin
        assert (pld_cnt_q <= payload_len_q)
        else
          $error(
              "gvsp_packet_builder: pld_cnt_q (%0d) > payload_len_q (%0d)", pld_cnt_q, payload_len_q
          );
      end
      if (udp_sof_o === 1'b1) begin
        assert (state_q == S_HDR)
        else $error("gvsp_packet_builder: SOF asserted outside S_HDR");
      end
    end
  end
`endif

endmodule : gvsp_packet_builder

`default_nettype wire
