// -----------------------------------------------------------------------------
// Module:      mipi_src
// Description: Adapts the MIPI receiver video stream to the pipeline contract.
//              The receiver emits RGB888 video; the pipeline expects 32 bits
//              per pixel with the start of frame on tuser and the end of line
//              on tlast. Also counts input beats so software can tell an idle
//              receiver from a stalled pipeline.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module mipi_src #(
    parameter int unsigned NUM_TAP = 1
) (
    input wire clk,
    input wire rst_ni,

    input  wire  [NUM_TAP*24-1:0] s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output logic                  s_axis_tready,
    input  wire                   s_axis_tuser,
    input  wire                   s_axis_tlast,

    input wire [3:0] format_mode_i,

    output logic [NUM_TAP*32-1:0] m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  wire                   m_axis_tready,
    output logic                  m_axis_tuser,
    output logic                  m_axis_tlast,

    input  wire         dbg_cnt_rst_ni,
    input wire dbg_clk,
    input wire dbg_rst_ni,
    output logic [31:0] dbg_valid_o,
    output logic [31:0] dbg_beat_o
);

  assign s_axis_tready = m_axis_tready;
  assign m_axis_tvalid = s_axis_tvalid;
  assign m_axis_tuser  = s_axis_tuser;
  assign m_axis_tlast  = s_axis_tlast;

  always_comb begin
    for (int t = 0; t < NUM_TAP; t++) begin
      logic [7:0] vr, vg, vb;
      vr = s_axis_tdata[t*24+16+:8];
      vg = s_axis_tdata[t*24+8+:8];
      vb = s_axis_tdata[t*24+0+:8];
      unique case (format_mode_i)
        4'd0:    m_axis_tdata[t*32+:32] = {vr, vg, vb, 8'h00};
        default: m_axis_tdata[t*32+:32] = {vr, vg, vb, 8'h00};
      endcase
    end
  end

  function automatic logic [31:0] bin2gray(input logic [31:0] b);
    return b ^ (b >> 1);
  endfunction
  function automatic logic [31:0] gray2bin(input logic [31:0] g);
    logic [31:0] b;
    b = g;
    for (int i = 16; i >= 1; i = i >> 1) b = b ^ (b >> i);
    return b;
  endfunction

  logic [31:0] vcnt_q, bcnt_q, vgray_q, bgray_q;
  always_ff @(posedge clk) begin
    if (!dbg_cnt_rst_ni) begin
      vcnt_q  <= '0;
      bcnt_q  <= '0;
      vgray_q <= '0;
      bgray_q <= '0;
    end else begin
      logic [31:0] vnext, bnext;
      vnext = s_axis_tvalid ? vcnt_q + 32'd1 : vcnt_q;
      bnext = (s_axis_tvalid & m_axis_tready) ? bcnt_q + 32'd1 : bcnt_q;
      vcnt_q  <= vnext;
      vgray_q <= bin2gray(vnext);
      bcnt_q  <= bnext;
      bgray_q <= bin2gray(bnext);
    end
  end

  (* ASYNC_REG = "TRUE" *) logic [31:0] vs1_q, vs2_q, bs1_q, bs2_q;
  always_ff @(posedge dbg_clk) begin
    if (!dbg_rst_ni) begin
      vs1_q       <= '0;
      vs2_q       <= '0;
      dbg_valid_o <= '0;
      bs1_q       <= '0;
      bs2_q       <= '0;
      dbg_beat_o  <= '0;
    end else begin
      vs1_q       <= vgray_q;
      vs2_q       <= vs1_q;
      dbg_valid_o <= gray2bin(vs2_q);
      bs1_q       <= bgray_q;
      bs2_q       <= bs1_q;
      dbg_beat_o  <= gray2bin(bs2_q);
    end
  end

  logic unused_rst;
  assign unused_rst = rst_ni;

endmodule : mipi_src
`default_nettype wire
