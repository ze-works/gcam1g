// -----------------------------------------------------------------------------
// Module:      eth_tx_udp_ip
// Description: Ethernet, IPv4 and UDP header builder. Takes a UDP payload byte
//              stream plus its routing fields and emits a complete Ethernet
//              frame. The IPv4 header checksum is computed once per packet.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module eth_tx_udp_ip #(
    parameter int unsigned ETH_BYTES = 1
) (
    input wire logic clk,
    input wire logic rst_ni,

    input wire logic [47:0] local_mac_i,
    input wire logic [31:0] local_ip_i,

    input wire logic        pkt_start_i,
    input wire logic [47:0] pkt_dst_mac_i,
    input wire logic [31:0] pkt_dst_ip_i,
    input wire logic [15:0] pkt_src_port_i,
    input wire logic [15:0] pkt_dst_port_i,
    input wire logic [15:0] pkt_payload_bytes_i,

    input  wire logic [ETH_BYTES*8-1:0] pld_byte_i,
    input  wire logic                   pld_valid_i,
    output logic                        pld_ready_o,
    input  wire logic                   pld_eof_i,

    output logic      [ETH_BYTES*8-1:0] eth_byte_o,
    output logic                        eth_valid_o,
    input  wire logic                   eth_ready_i,
    output logic                        eth_sof_o,
    output logic                        eth_eof_o,

    output logic        busy_o,
    output logic [31:0] packets_sent_o
);

  localparam logic [15:0] ETHERTYPE_IPV4    = 16'h0800;
  localparam logic [ 7:0] IP_V_IHL          = 8'h45;
  localparam logic [ 7:0] IP_TOS            = 8'h00;
  localparam logic [ 7:0] IP_FLAGS_HI       = 8'h40;
  localparam logic [ 7:0] IP_FLAGS_LO       = 8'h00;
  localparam logic [ 7:0] IP_TTL            = 8'h40;
  localparam logic [ 7:0] IP_PROTO_UDP      = 8'h11;

  localparam logic [15:0] IP_HDR_LEN_BYTES  = 16'd20;
  localparam logic [15:0] UDP_HDR_LEN_BYTES = 16'd8;

  typedef enum logic [2:0] {
    S_IDLE        = 3'd0,
    S_ETH_HDR     = 3'd1,
    S_IP_HDR_CALC = 3'd2,
    S_IP_HDR      = 3'd3,
    S_UDP_HDR     = 3'd4,
    S_PAYLOAD     = 3'd5,
    S_DONE        = 3'd6
  } state_e;

  state_e state_q, state_d;

  logic [47:0] dst_mac_q;
  logic [47:0] src_mac_q;
  logic [31:0] dst_ip_q;
  logic [31:0] src_ip_q;
  logic [15:0] src_port_q;
  logic [15:0] dst_port_q;
  logic [15:0] payload_bytes_q;
  logic [15:0] ip_total_len_q;
  logic [15:0] udp_len_q;
  logic [15:0] ip_id_q;
  logic [15:0] ip_csum_q;

  localparam int unsigned ETH_HDR_BEATS = 14 / ETH_BYTES;
  localparam int unsigned IP_HDR_BEATS  = 20 / ETH_BYTES;
  localparam int unsigned UDP_HDR_BEATS = 8 / ETH_BYTES;

  logic [            3:0] eth_idx_q;
  logic [            3:0] eth_idx_d;
  logic [            4:0] ip_idx_q;
  logic [            4:0] ip_idx_d;
  logic [            2:0] udp_idx_q;
  logic [            2:0] udp_idx_d;
  logic [           15:0] pld_idx_q;
  logic [           15:0] pld_idx_d;

  logic [           31:0] packets_sent_q;
  logic [           31:0] packets_sent_d;

  logic [ETH_BYTES*8-1:0] eth_hdr_word;
  logic [ETH_BYTES*8-1:0] ip_hdr_word;
  logic [ETH_BYTES*8-1:0] udp_hdr_word;
  always_comb begin
    for (int b = 0; b < ETH_BYTES; b++) begin
      eth_hdr_word[b*8+:8] = eth_hdr_byte_f(int'(eth_idx_q) * ETH_BYTES + b);
      ip_hdr_word[b*8+:8]  = ip_hdr_byte_f(int'(ip_idx_q) * ETH_BYTES + b);
      udp_hdr_word[b*8+:8] = udp_hdr_byte_f(int'(udp_idx_q) * ETH_BYTES + b);
    end
  end

  function automatic logic [7:0] eth_hdr_byte_f(input int i);
    unique case (i)
      0:       eth_hdr_byte_f = dst_mac_q[47:40];
      1:       eth_hdr_byte_f = dst_mac_q[39:32];
      2:       eth_hdr_byte_f = dst_mac_q[31:24];
      3:       eth_hdr_byte_f = dst_mac_q[23:16];
      4:       eth_hdr_byte_f = dst_mac_q[15:8];
      5:       eth_hdr_byte_f = dst_mac_q[7:0];
      6:       eth_hdr_byte_f = src_mac_q[47:40];
      7:       eth_hdr_byte_f = src_mac_q[39:32];
      8:       eth_hdr_byte_f = src_mac_q[31:24];
      9:       eth_hdr_byte_f = src_mac_q[23:16];
      10:      eth_hdr_byte_f = src_mac_q[15:8];
      11:      eth_hdr_byte_f = src_mac_q[7:0];
      12:      eth_hdr_byte_f = ETHERTYPE_IPV4[15:8];
      13:      eth_hdr_byte_f = ETHERTYPE_IPV4[7:0];
      default: eth_hdr_byte_f = 8'h00;
    endcase
  endfunction

  function automatic logic [7:0] ip_hdr_byte_f(input int i);
    unique case (i)
      0:       ip_hdr_byte_f = IP_V_IHL;
      1:       ip_hdr_byte_f = IP_TOS;
      2:       ip_hdr_byte_f = ip_total_len_q[15:8];
      3:       ip_hdr_byte_f = ip_total_len_q[7:0];
      4:       ip_hdr_byte_f = ip_id_q[15:8];
      5:       ip_hdr_byte_f = ip_id_q[7:0];
      6:       ip_hdr_byte_f = IP_FLAGS_HI;
      7:       ip_hdr_byte_f = IP_FLAGS_LO;
      8:       ip_hdr_byte_f = IP_TTL;
      9:       ip_hdr_byte_f = IP_PROTO_UDP;
      10:      ip_hdr_byte_f = ip_csum_q[15:8];
      11:      ip_hdr_byte_f = ip_csum_q[7:0];
      12:      ip_hdr_byte_f = src_ip_q[31:24];
      13:      ip_hdr_byte_f = src_ip_q[23:16];
      14:      ip_hdr_byte_f = src_ip_q[15:8];
      15:      ip_hdr_byte_f = src_ip_q[7:0];
      16:      ip_hdr_byte_f = dst_ip_q[31:24];
      17:      ip_hdr_byte_f = dst_ip_q[23:16];
      18:      ip_hdr_byte_f = dst_ip_q[15:8];
      19:      ip_hdr_byte_f = dst_ip_q[7:0];
      default: ip_hdr_byte_f = 8'h00;
    endcase
  endfunction

  function automatic logic [7:0] udp_hdr_byte_f(input int i);
    unique case (i)
      0:       udp_hdr_byte_f = src_port_q[15:8];
      1:       udp_hdr_byte_f = src_port_q[7:0];
      2:       udp_hdr_byte_f = dst_port_q[15:8];
      3:       udp_hdr_byte_f = dst_port_q[7:0];
      4:       udp_hdr_byte_f = udp_len_q[15:8];
      5:       udp_hdr_byte_f = udp_len_q[7:0];
      6:       udp_hdr_byte_f = 8'h00;
      7:       udp_hdr_byte_f = 8'h00;
      default: udp_hdr_byte_f = 8'h00;
    endcase
  endfunction

  function automatic logic [15:0] ipv4_checksum(input logic [15:0] tot_len,
                                                input logic [15:0] ident, input logic [31:0] s_ip,
                                                input logic [31:0] d_ip);
    logic [31:0] sum;
    logic [15:0] w0;
    logic [15:0] w1;
    logic [15:0] w2;
    logic [15:0] w3;
    logic [15:0] w4;
    logic [15:0] w5;
    logic [15:0] w6;
    logic [15:0] w7;
    logic [15:0] w8;
    begin
      w0            = {IP_V_IHL, IP_TOS};
      w1            = tot_len;
      w2            = ident;
      w3            = {IP_FLAGS_HI, IP_FLAGS_LO};
      w4            = {IP_TTL, IP_PROTO_UDP};
      w5            = s_ip[31:16];
      w6            = s_ip[15:0];
      w7            = d_ip[31:16];
      w8            = d_ip[15:0];
      sum           = 32'h0;
      sum           = sum + {16'h0, w0};
      sum           = sum + {16'h0, w1};
      sum           = sum + {16'h0, w2};
      sum           = sum + {16'h0, w3};
      sum           = sum + {16'h0, w4};
      sum           = sum + {16'h0, w5};
      sum           = sum + {16'h0, w6};
      sum           = sum + {16'h0, w7};
      sum           = sum + {16'h0, w8};
      sum           = {16'h0, sum[31:16]} + {16'h0, sum[15:0]};
      sum           = {16'h0, sum[31:16]} + {16'h0, sum[15:0]};
      ipv4_checksum = ~sum[15:0];
    end
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      dst_mac_q       <= 48'h0;
      src_mac_q       <= 48'h0;
      dst_ip_q        <= 32'h0;
      src_ip_q        <= 32'h0;
      src_port_q      <= 16'h0;
      dst_port_q      <= 16'h0;
      payload_bytes_q <= 16'h0;
      ip_total_len_q  <= 16'h0;
      udp_len_q       <= 16'h0;
      ip_id_q         <= 16'h0;
    end else if ((state_q == S_IDLE) && pkt_start_i) begin
      dst_mac_q       <= pkt_dst_mac_i;
      src_mac_q       <= local_mac_i;
      dst_ip_q        <= pkt_dst_ip_i;
      src_ip_q        <= local_ip_i;
      src_port_q      <= pkt_src_port_i;
      dst_port_q      <= pkt_dst_port_i;
      payload_bytes_q <= pkt_payload_bytes_i;
      ip_total_len_q  <= IP_HDR_LEN_BYTES + UDP_HDR_LEN_BYTES + pkt_payload_bytes_i;
      udp_len_q       <= UDP_HDR_LEN_BYTES + pkt_payload_bytes_i;
      ip_id_q         <= ip_id_q + 16'h1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      ip_csum_q <= 16'h0;
    end else if (state_q == S_IP_HDR_CALC) begin
      ip_csum_q <= ipv4_checksum(ip_total_len_q, ip_id_q, src_ip_q, dst_ip_q);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      state_q        <= S_IDLE;
      eth_idx_q      <= 4'h0;
      ip_idx_q       <= 5'h0;
      udp_idx_q      <= 3'h0;
      pld_idx_q      <= 16'h0;
      packets_sent_q <= 32'h0;
    end else begin
      state_q        <= state_d;
      eth_idx_q      <= eth_idx_d;
      ip_idx_q       <= ip_idx_d;
      udp_idx_q      <= udp_idx_d;
      pld_idx_q      <= pld_idx_d;
      packets_sent_q <= packets_sent_d;
    end
  end

  always_comb begin
    state_d        = state_q;
    eth_idx_d      = eth_idx_q;
    ip_idx_d       = ip_idx_q;
    udp_idx_d      = udp_idx_q;
    pld_idx_d      = pld_idx_q;
    packets_sent_d = packets_sent_q;

    eth_byte_o     = '0;
    eth_valid_o    = 1'b0;
    eth_sof_o      = 1'b0;
    eth_eof_o      = 1'b0;
    pld_ready_o    = 1'b0;
    busy_o         = (state_q != S_IDLE);

    unique case (state_q)
      S_IDLE: begin
        eth_idx_d = 4'h0;
        ip_idx_d  = 5'h0;
        udp_idx_d = 3'h0;
        pld_idx_d = 16'h0;
        if (pkt_start_i) begin
          state_d = S_ETH_HDR;
        end
      end

      S_ETH_HDR: begin
        eth_valid_o = 1'b1;
        eth_byte_o  = eth_hdr_word;
        if (eth_idx_q == 4'd0) eth_sof_o = 1'b1;
        if (eth_ready_i) begin
          if (int'(eth_idx_q) == ETH_HDR_BEATS - 1) begin
            eth_idx_d = 4'h0;
            state_d   = S_IP_HDR_CALC;
          end else begin
            eth_idx_d = eth_idx_q + 4'h1;
          end
        end
      end

      S_IP_HDR_CALC: begin
        state_d = S_IP_HDR;
      end

      S_IP_HDR: begin
        eth_valid_o = 1'b1;
        eth_byte_o  = ip_hdr_word;
        if (eth_ready_i) begin
          if (int'(ip_idx_q) == IP_HDR_BEATS - 1) begin
            ip_idx_d = 5'h0;
            state_d  = S_UDP_HDR;
          end else begin
            ip_idx_d = ip_idx_q + 5'h1;
          end
        end
      end

      S_UDP_HDR: begin
        eth_valid_o = 1'b1;
        eth_byte_o  = udp_hdr_word;
        if (eth_ready_i) begin
          if (int'(udp_idx_q) == UDP_HDR_BEATS - 1) begin
            udp_idx_d = 3'h0;
            if (payload_bytes_q == 16'h0) begin
              state_d        = S_DONE;
              packets_sent_d = packets_sent_q + 32'h1;
            end else begin
              state_d = S_PAYLOAD;
            end
          end else begin
            udp_idx_d = udp_idx_q + 3'h1;
          end
        end
        if ((int'(udp_idx_q) == UDP_HDR_BEATS - 1) && (payload_bytes_q == 16'h0)) begin
          eth_eof_o = 1'b1;
        end
      end

      S_PAYLOAD: begin
        pld_ready_o = eth_ready_i;
        eth_valid_o = pld_valid_i;
        eth_byte_o  = pld_byte_i;
        if (pld_valid_i && (pld_idx_q >= (payload_bytes_q - 16'(ETH_BYTES)))) begin
          eth_eof_o = 1'b1;
        end
        if (pld_valid_i && eth_ready_i) begin
          pld_idx_d = pld_idx_q + 16'(ETH_BYTES);
          if (pld_idx_q >= (payload_bytes_q - 16'(ETH_BYTES))) begin
            state_d        = S_DONE;
            packets_sent_d = packets_sent_q + 32'h1;
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

  assign packets_sent_o = packets_sent_q;

`ifdef SIM_ONLY
  always_ff @(posedge clk) begin
    if (rst_ni) begin
      if (state_q == S_PAYLOAD) begin
        assert (pld_idx_q < payload_bytes_q)
        else
          $error(
              "eth_tx_udp_ip: pld_idx_q (%0d) >= payload_bytes_q (%0d)", pld_idx_q, payload_bytes_q
          );
      end
      if (eth_sof_o === 1'b1) begin
        assert ((state_q == S_ETH_HDR) && (eth_idx_q == 4'd0))
        else $error("eth_tx_udp_ip: SOF asserted outside first Ethernet byte");
      end
      if (eth_eof_o === 1'b1) begin
        assert (eth_valid_o === 1'b1)
        else $error("eth_tx_udp_ip: EOF asserted with valid=0");
      end
      if (state_q != S_IDLE) begin
        assert (ip_total_len_q == (16'd28 + payload_bytes_q))
        else
          $error(
              "eth_tx_udp_ip: ip_total_len_q (%0d) inconsistent (%0d expected)",
              ip_total_len_q,
              28 + payload_bytes_q
          );
      end
    end
  end
`endif

endmodule : eth_tx_udp_ip

`default_nettype wire
