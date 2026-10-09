// -----------------------------------------------------------------------------
// Module:      gvsp
// Description: Block design wrapper for the stream protocol stage. Turns packed
//              image data into GVSP stream packets by chaining
//              the segmenter and the packet builder. Image geometry and payload
//              size come from the control registers, so they can change without
//              rebuilding the bitstream.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module gvsp #(
    parameter int unsigned ETH_BYTES          = 1,
    parameter int unsigned IN_DATA_W          = 128,
    parameter int unsigned IN_KEEP_W          = 16,
    parameter int unsigned GVSP_MAX_PKT_BYTES = 8964
) (
    input wire clk,
    input wire rst_ni,
    input wire blkid_rst_ni,

    input  wire  [IN_DATA_W-1:0] s_axis_tdata,
    input  wire  [IN_KEEP_W-1:0] s_axis_tkeep,
    input  wire                  s_axis_tvalid,
    output logic                 s_axis_tready,
    input  wire                  s_axis_tuser,
    input  wire                  s_axis_tlast,

    input wire        new_frame_i,
    input wire [63:0] block_id_i,
    input wire [15:0] pkt_payload_bytes_i,
    input wire [31:0] frame_size_bytes_i,
    input wire [31:0] width_i,
    input wire [31:0] height_i,
    input wire [31:0] pixel_format_i,
    input wire [31:0] line_bytes_i,
    input wire [31:0] dst_ip_i,
    input wire [15:0] dst_port_i,

    output logic [ETH_BYTES*8-1:0] m_axis_pld_tdata,
    output logic                   m_axis_pld_tvalid,
    input  wire                    m_axis_pld_tready,
    output logic                   m_axis_pld_tuser,
    output logic                   m_axis_pld_tlast,

    output logic [47:0] m_axis_meta_tdata,
    output logic        m_axis_meta_tvalid,
    input  wire         m_axis_meta_tready
);

  logic rd_sof_lvl, rd_sof_seen_q;
  logic        rd_new_frame;
  logic [63:0] rd_block_id_q;
  assign rd_sof_lvl   = s_axis_tvalid & s_axis_tuser;
  assign rd_new_frame = rd_sof_lvl;
  always_ff @(posedge clk) begin
    if (!rst_ni) rd_sof_seen_q <= 1'b1;
    else rd_sof_seen_q <= rd_sof_lvl;
  end
  logic [63:0] rd_block_id_nxt;
  assign rd_block_id_nxt = rd_block_id_q + ((rd_block_id_q[15:0] == 16'hFFFF) ? 64'd2 : 64'd1);
  always_ff @(posedge clk) begin
    if (!blkid_rst_ni) rd_block_id_q <= 64'd1;
    else if (rst_ni && (rd_sof_lvl & ~rd_sof_seen_q)) rd_block_id_q <= rd_block_id_nxt;
  end
  logic unused_ext_nf;
  assign unused_ext_nf = ^{new_frame_i, block_id_i};

  logic [IN_DATA_W-1:0] seg_tdata;
  logic [IN_KEEP_W-1:0] seg_tkeep;
  logic                 seg_tvalid;
  logic                 seg_tready;
  logic                 seg_tuser;
  logic                 seg_tlast;
  logic [         63:0] seg_pkt_block_id;
  logic [         31:0] seg_pkt_packet_id;
  logic [         15:0] seg_pkt_payload_len;
  logic                 seg_pkt_is_leader;
  logic                 seg_pkt_is_trailer;
  logic                 seg_pkt_is_payload;

  gvsp_segmenter #(
      .IN_DATA_W    (IN_DATA_W),
      .IN_KEEP_W    (IN_KEEP_W),
      .MAX_PKT_BYTES(GVSP_MAX_PKT_BYTES)
  ) u_seg (
      .clk                (clk),
      .rst_ni             (rst_ni),
      .pkt_payload_bytes_i(pkt_payload_bytes_i),
      .frame_size_bytes_i (frame_size_bytes_i),
      .new_frame_i        (rd_new_frame),
      .block_id_i         (rd_block_id_q),
      .s_axis_tdata_i     (s_axis_tdata),
      .s_axis_tkeep_i     (s_axis_tkeep),
      .s_axis_tvalid_i    (s_axis_tvalid),
      .s_axis_tready_o    (s_axis_tready),
      .s_axis_tuser_i     (s_axis_tuser),
      .s_axis_tlast_i     (s_axis_tlast),
      .m_axis_tdata_o     (seg_tdata),
      .m_axis_tkeep_o     (seg_tkeep),
      .m_axis_tvalid_o    (seg_tvalid),
      .m_axis_tready_i    (seg_tready),
      .m_axis_tuser_o     (seg_tuser),
      .m_axis_tlast_o     (seg_tlast),
      .pkt_block_id_o     (seg_pkt_block_id),
      .pkt_packet_id_o    (seg_pkt_packet_id),
      .pkt_payload_len_o  (seg_pkt_payload_len),
      .pkt_is_leader_o    (seg_pkt_is_leader),
      .pkt_is_trailer_o   (seg_pkt_is_trailer),
      .pkt_is_payload_o   (seg_pkt_is_payload)
  );

  logic seg_pkt_valid;
  logic seg_pkt_ready;
  logic seg_pkt_meta_done_q;
  logic seg_is_hdr_only_beat;

  assign seg_is_hdr_only_beat = (seg_tkeep == '0);

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      seg_pkt_meta_done_q <= 1'b0;
    end else begin
      if (seg_pkt_valid && seg_pkt_ready) seg_pkt_meta_done_q <= 1'b1;
      if (seg_tvalid && seg_tready) seg_pkt_meta_done_q <= 1'b0;
    end
  end

  assign seg_pkt_valid = seg_tvalid && seg_tuser && !seg_pkt_meta_done_q;

  logic seg_tready_from_builder;
  logic seg_tready_local;
  assign seg_tready_local = seg_is_hdr_only_beat
                            ? (seg_pkt_meta_done_q || (seg_pkt_valid && seg_pkt_ready))
                            : seg_tready_from_builder;
  assign seg_tready = seg_tready_local;

  logic bld_axis_tvalid;
  logic bld_axis_tlast;
  assign bld_axis_tvalid = seg_tvalid && !seg_is_hdr_only_beat;
  assign bld_axis_tlast  = seg_tlast;

  logic [ETH_BYTES*8-1:0] udp_byte;
  logic                   udp_valid;
  logic                   udp_ready;
  logic                   udp_sof;
  logic                   udp_eof;
  logic [           31:0] udp_dst_ip;
  logic [           15:0] udp_dst_port;

  gvsp_packet_builder #(
      .ETH_BYTES(ETH_BYTES),
      .IN_DATA_W(IN_DATA_W),
      .IN_KEEP_W(IN_KEEP_W)
  ) u_gpb (
      .clk              (clk),
      .rst_ni           (rst_ni),
      .pkt_valid_i      (seg_pkt_valid),
      .pkt_ready_o      (seg_pkt_ready),
      .pkt_block_id_i   (seg_pkt_block_id),
      .pkt_packet_id_i  (seg_pkt_packet_id),
      .pkt_payload_len_i(seg_pkt_payload_len),
      .pkt_is_leader_i  (seg_pkt_is_leader),
      .pkt_is_trailer_i (seg_pkt_is_trailer),
      .pkt_is_payload_i (seg_pkt_is_payload),
      .pkt_dst_ip_i     (dst_ip_i),
      .pkt_dst_port_i   (dst_port_i),
      .pkt_status_i     (16'h0000),
      .s_axis_tdata_i   (seg_tdata),
      .s_axis_tkeep_i   (seg_tkeep),
      .s_axis_tvalid_i  (bld_axis_tvalid),
      .s_axis_tready_o  (seg_tready_from_builder),
      .s_axis_tlast_i   (bld_axis_tlast),
      .width_i          (width_i),
      .height_i         (height_i),
      .pixel_format_i   (pixel_format_i),
      .timestamp_i      (64'd0),
      .udp_byte_o       (udp_byte),
      .udp_valid_o      (udp_valid),
      .udp_ready_i      (udp_ready),
      .udp_sof_o        (udp_sof),
      .udp_eof_o        (udp_eof),
      .udp_dst_ip_o     (udp_dst_ip),
      .udp_dst_port_o   (udp_dst_port)
  );

  assign m_axis_pld_tdata   = udp_byte;
  assign m_axis_pld_tvalid  = udp_valid;
  assign m_axis_pld_tuser   = udp_sof;
  assign m_axis_pld_tlast   = udp_eof;
  assign udp_ready          = m_axis_pld_tready;

  assign m_axis_meta_tdata  = {udp_dst_ip, udp_dst_port};
  assign m_axis_meta_tvalid = udp_valid & udp_sof;

  logic unused;
  assign unused = ^{seg_pkt_is_leader, seg_pkt_is_trailer, seg_pkt_is_payload, seg_tlast,
                    line_bytes_i, m_axis_meta_tready};

endmodule : gvsp
`default_nettype wire
