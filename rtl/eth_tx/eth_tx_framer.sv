// -----------------------------------------------------------------------------
// Module:      eth_tx_framer
// Description: Store-and-forward stage in front of eth_tx_udp_ip. The upstream
//              byte stream marks packet boundaries with tuser and tlast but
//              carries no length, which the header builder needs up front.
//              Buffer each packet, latch its length and destination at end of
//              frame, then release it to the header builder.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module eth_tx_framer #(
    parameter int unsigned ETH_BYTES     = 1,
    parameter int unsigned MAX_PKT_BYTES = 9000,
    parameter int unsigned BUF_DEPTH     = 32768,
    parameter int unsigned META_DEPTH    = 8
) (
    input wire logic clk,
    input wire logic rst_ni,

    input wire logic [47:0] local_mac_i,
    input wire logic [31:0] local_ip_i,
    input wire logic [47:0] dst_mac_i,
    input wire logic [15:0] src_port_i,

    input  wire logic [ETH_BYTES*8-1:0] pld_byte_i,
    input  wire logic                   pld_valid_i,
    output logic                        pld_ready_o,
    input  wire logic                   pld_sof_i,
    input  wire logic                   pld_eof_i,
    input  wire logic [           31:0] pld_dst_ip_i,
    input  wire logic [           15:0] pld_dst_port_i,

    output logic      [ETH_BYTES*8-1:0] eth_byte_o,
    output logic                        eth_valid_o,
    input  wire logic                   eth_ready_i,
    output logic                        eth_sof_o,
    output logic                        eth_eof_o,

    output logic        busy_o,
    output logic [31:0] packets_sent_o
);

  localparam int unsigned LEN_W  = 16;
  localparam int unsigned META_W = LEN_W + 32 + 16;

  initial begin : g_param_check
    if (BUF_DEPTH < 2 * MAX_PKT_BYTES) begin
      $error("eth_tx_framer: BUF_DEPTH (%0d) must be >= 2*MAX_PKT_BYTES (%0d)", BUF_DEPTH,
             2 * MAX_PKT_BYTES);
    end
  end

  logic             byte_wr_ready;
  logic             meta_wr_ready;
  logic             in_fire;
  logic [LEN_W-1:0] in_len_q;

  assign pld_ready_o = byte_wr_ready & meta_wr_ready;
  assign in_fire     = pld_valid_i & pld_ready_o;

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      in_len_q <= '0;
    end else if (in_fire) begin
      if (pld_eof_i) begin
        in_len_q <= '0;
      end else begin
        in_len_q <= in_len_q + 16'(ETH_BYTES);
      end
    end
  end

  logic              meta_push;
  logic [META_W-1:0] meta_wr_data;
  assign meta_push    = in_fire & pld_eof_i;
  assign meta_wr_data = {in_len_q + 16'(ETH_BYTES), pld_dst_ip_i, pld_dst_port_i};

  logic                   byte_rd_valid;
  logic                   byte_rd_ready;
  logic [ETH_BYTES*8-1:0] byte_rd_data;

  eth_tx_fifo #(
      .DATA_W(ETH_BYTES * 8),
      .DEPTH (BUF_DEPTH)
  ) u_byte_fifo (
      .wr_clk_i  (clk),
      .wr_rst_ni (rst_ni),
      .wr_valid_i(in_fire),
      .wr_ready_o(byte_wr_ready),
      .wr_data_i (pld_byte_i),
      .rd_clk_i  (clk),
      .rd_rst_ni (rst_ni),
      .rd_valid_o(byte_rd_valid),
      .rd_ready_i(byte_rd_ready),
      .rd_data_o (byte_rd_data)
  );

  logic              meta_rd_valid;
  logic              meta_rd_ready;
  logic [META_W-1:0] meta_rd_data;

  eth_tx_fifo #(
      .DATA_W(META_W),
      .DEPTH (META_DEPTH)
  ) u_meta_fifo (
      .wr_clk_i  (clk),
      .wr_rst_ni (rst_ni),
      .wr_valid_i(meta_push),
      .wr_ready_o(meta_wr_ready),
      .wr_data_i (meta_wr_data),
      .rd_clk_i  (clk),
      .rd_rst_ni (rst_ni),
      .rd_valid_o(meta_rd_valid),
      .rd_ready_i(meta_rd_ready),
      .rd_data_o (meta_rd_data)
  );

  typedef enum logic [0:0] {
    F_IDLE = 1'd0,
    F_PLD  = 1'd1
  } state_e;

  state_e             state_q;
  state_e             state_d;
  logic   [LEN_W-1:0] tx_rem_q;
  logic   [LEN_W-1:0] tx_rem_d;

  logic               utx_busy;
  logic               utx_pld_ready;
  logic               utx_pkt_start;
  logic               tx_byte_fire;

  assign tx_byte_fire  = (state_q == F_PLD) & byte_rd_valid & utx_pld_ready;
  assign byte_rd_ready = (state_q == F_PLD) & utx_pld_ready;

  always_comb begin
    state_d       = state_q;
    tx_rem_d      = tx_rem_q;
    meta_rd_ready = 1'b0;
    utx_pkt_start = 1'b0;

    unique case (state_q)
      F_IDLE: begin
        if (meta_rd_valid && !utx_busy) begin
          meta_rd_ready = 1'b1;
          utx_pkt_start = 1'b1;
          tx_rem_d      = meta_rd_data[META_W-1-:LEN_W];
          state_d       = F_PLD;
        end
      end

      F_PLD: begin
        if (tx_byte_fire) begin
          tx_rem_d = (tx_rem_q <= 16'(ETH_BYTES)) ? '0 : (tx_rem_q - 16'(ETH_BYTES));
          if (tx_rem_q <= 16'(ETH_BYTES)) begin
            state_d = F_IDLE;
          end
        end
      end

      default: state_d = F_IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      state_q  <= F_IDLE;
      tx_rem_q <= '0;
    end else begin
      state_q  <= state_d;
      tx_rem_q <= tx_rem_d;
    end
  end

  eth_tx_udp_ip #(
      .ETH_BYTES(ETH_BYTES)
  ) u_udp_ip_tx (
      .clk                (clk),
      .rst_ni             (rst_ni),
      .local_mac_i        (local_mac_i),
      .local_ip_i         (local_ip_i),
      .pkt_start_i        (utx_pkt_start),
      .pkt_dst_mac_i      (dst_mac_i),
      .pkt_dst_ip_i       (meta_rd_data[47:16]),
      .pkt_src_port_i     (src_port_i),
      .pkt_dst_port_i     (meta_rd_data[15:0]),
      .pkt_payload_bytes_i(meta_rd_data[META_W-1-:LEN_W]),
      .pld_byte_i         (byte_rd_data),
      .pld_valid_i        ((state_q == F_PLD) & byte_rd_valid),
      .pld_ready_o        (utx_pld_ready),
      .pld_eof_i          ((state_q == F_PLD) & (tx_rem_q <= 16'(ETH_BYTES))),
      .eth_byte_o         (eth_byte_o),
      .eth_valid_o        (eth_valid_o),
      .eth_ready_i        (eth_ready_i),
      .eth_sof_o          (eth_sof_o),
      .eth_eof_o          (eth_eof_o),
      .busy_o             (utx_busy),
      .packets_sent_o     (packets_sent_o)
  );

  assign busy_o = (state_q != F_IDLE) | utx_busy | meta_rd_valid;

`ifdef SIM_ONLY
  always_ff @(posedge clk) begin
    if (rst_ni && in_fire && pld_sof_i) begin
      assert (in_len_q == '0)
      else $error("eth_tx_framer: SOF mid-packet (in_len_q=%0d)", in_len_q);
    end
  end
`else
  logic unused_sof;
  assign unused_sof = pld_sof_i;
`endif

endmodule : eth_tx_framer
`default_nettype wire
