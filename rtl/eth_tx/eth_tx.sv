// -----------------------------------------------------------------------------
// Module:      eth_tx
// Description: Block design wrapper for the Ethernet transmit stage. Accepts a
//              UDP payload stream and emits Ethernet frames. Port names follow
//              the Vivado conventions so the AXI-Stream interfaces are inferred
//              automatically.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module eth_tx #(
    parameter int unsigned ETH_BYTES     = 1,
    parameter int unsigned MAX_PKT_BYTES = 9000,
    parameter int unsigned BUF_DEPTH     = 32768,
    parameter int unsigned META_DEPTH    = 16
) (
    input wire clk,
    input wire rst_ni,

    input wire [47:0] local_mac_i,
    input wire [31:0] local_ip_i,
    input wire [47:0] dst_mac_i,
    input wire [15:0] src_port_i,

    input  wire  [ETH_BYTES*8-1:0] s_axis_pld_tdata,
    input  wire                    s_axis_pld_tvalid,
    output logic                   s_axis_pld_tready,
    input  wire                    s_axis_pld_tuser,
    input  wire                    s_axis_pld_tlast,

    input  wire  [47:0] s_axis_meta_tdata,
    input  wire         s_axis_meta_tvalid,
    output logic        s_axis_meta_tready,

    output logic [ETH_BYTES*8-1:0] m_axis_eth_tdata,
    output logic                   m_axis_eth_tvalid,
    input  wire                    m_axis_eth_tready,
    output logic                   m_axis_eth_tuser,
    output logic                   m_axis_eth_tlast,

    output logic        busy_o,
    output logic [31:0] packets_sent_o,

    output logic [31:0] pld_in_beats_o,
    output logic [31:0] eth_out_beats_o
);

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      pld_in_beats_o  <= 32'd0;
      eth_out_beats_o <= 32'd0;
    end else begin
      if (s_axis_pld_tvalid && s_axis_pld_tready) pld_in_beats_o <= pld_in_beats_o + 32'd1;
      if (m_axis_eth_tvalid && m_axis_eth_tready) eth_out_beats_o <= eth_out_beats_o + 32'd1;
    end
  end

  logic [47:0] dst_q;
  logic        meta_seen_q;

  assign s_axis_meta_tready = 1'b1;

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      dst_q       <= '0;
      meta_seen_q <= 1'b0;
    end else begin
      if (s_axis_meta_tvalid) begin
        dst_q       <= s_axis_meta_tdata;
        meta_seen_q <= 1'b1;
      end
    end
  end

  logic unused_meta_seen;
  assign unused_meta_seen = meta_seen_q;

  eth_tx_framer #(
      .ETH_BYTES    (ETH_BYTES),
      .MAX_PKT_BYTES(MAX_PKT_BYTES),
      .BUF_DEPTH    (BUF_DEPTH),
      .META_DEPTH   (META_DEPTH)
  ) u_framer (
      .clk           (clk),
      .rst_ni        (rst_ni),
      .local_mac_i   (local_mac_i),
      .local_ip_i    (local_ip_i),
      .dst_mac_i     (dst_mac_i),
      .src_port_i    (src_port_i),
      .pld_byte_i    (s_axis_pld_tdata),
      .pld_valid_i   (s_axis_pld_tvalid),
      .pld_ready_o   (s_axis_pld_tready),
      .pld_sof_i     (s_axis_pld_tuser),
      .pld_eof_i     (s_axis_pld_tlast),
      .pld_dst_ip_i  (dst_q[47:16]),
      .pld_dst_port_i(dst_q[15:0]),
      .eth_byte_o    (m_axis_eth_tdata),
      .eth_valid_o   (m_axis_eth_tvalid),
      .eth_ready_i   (m_axis_eth_tready),
      .eth_sof_o     (m_axis_eth_tuser),
      .eth_eof_o     (m_axis_eth_tlast),
      .busy_o        (busy_o),
      .packets_sent_o(packets_sent_o)
  );

endmodule : eth_tx
`default_nettype wire
