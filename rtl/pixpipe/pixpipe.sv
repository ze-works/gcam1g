// -----------------------------------------------------------------------------
// Module:      pixpipe
// Description: Block design wrapper for the pixel formatting stage. Accepts 32
//              bit per pixel video and emits packed pixel data.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module pixpipe #(
    parameter int unsigned NUM_TAP    = 1,
    parameter int unsigned MAX_WIDTH = 4096,
    parameter int unsigned MAX_HEIGHT = 4096,
    parameter int unsigned MAX_BPP = 16
) (
    input wire clk,
    input wire rst_ni,

    input  wire  [NUM_TAP*32-1:0] s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output logic                  s_axis_tready,
    input  wire                   s_axis_tuser,
    input  wire                   s_axis_tlast,

    output logic [127:0] m_axis_tdata,
    output logic [ 15:0] m_axis_tkeep,
    output logic         m_axis_tvalid,
    input  wire          m_axis_tready,
    output logic         m_axis_tuser,
    output logic         m_axis_tlast,

    input wire [31:0] pixel_format_i
);

  localparam int unsigned UnusedMaxW   = MAX_WIDTH;
  localparam int unsigned UnusedMaxH   = MAX_HEIGHT;
  localparam int unsigned UnusedMaxBpp = MAX_BPP;

  pixpipe_pfc_packer #(
      .NUM_TAP   (NUM_TAP),
      .OUT_DATA_W(128),
      .OUT_KEEP_W(16)
  ) u_pfc (
      .clk            (clk),
      .rst_ni         (rst_ni),
      .pixel_format_i (pixel_format_i),
      .s_axis_tdata_i (s_axis_tdata),
      .s_axis_tvalid_i(s_axis_tvalid),
      .s_axis_tready_o(s_axis_tready),
      .s_axis_tuser_i (s_axis_tuser),
      .s_axis_tlast_i (s_axis_tlast),
      .m_axis_tdata_o (m_axis_tdata),
      .m_axis_tkeep_o (m_axis_tkeep),
      .m_axis_tvalid_o(m_axis_tvalid),
      .m_axis_tready_i(m_axis_tready),
      .m_axis_tuser_o (m_axis_tuser),
      .m_axis_tlast_o (m_axis_tlast)
  );

endmodule : pixpipe
`default_nettype wire
