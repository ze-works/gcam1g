// -----------------------------------------------------------------------------
// Module:      src_mux2
// Description: Selects between the test pattern generator and the camera. The
//              select input is synchronised with two flip-flop stages before
//              use, and the unselected source is held off so a switch cannot
//              drop or duplicate a beat.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module src_mux2 #(
    parameter int unsigned NUM_TAP = 1
) (
    input wire clk,
    input wire rst_ni,
    input wire sel_i,

    input  wire  [NUM_TAP*32-1:0] s0_axis_tdata,
    input  wire                   s0_axis_tvalid,
    output logic                  s0_axis_tready,
    input  wire                   s0_axis_tuser,
    input  wire                   s0_axis_tlast,

    input  wire  [NUM_TAP*32-1:0] s1_axis_tdata,
    input  wire                   s1_axis_tvalid,
    output logic                  s1_axis_tready,
    input  wire                   s1_axis_tuser,
    input  wire                   s1_axis_tlast,

    output logic [NUM_TAP*32-1:0] m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  wire                   m_axis_tready,
    output logic                  m_axis_tuser,
    output logic                  m_axis_tlast
);

  logic sel_s1_q, sel_q;
  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      sel_s1_q <= 1'b0;
      sel_q    <= 1'b0;
    end else begin
      sel_s1_q <= sel_i;
      sel_q    <= sel_s1_q;
    end
  end

  always_comb begin
    if (sel_q) begin
      m_axis_tdata   = s1_axis_tdata;
      m_axis_tvalid  = s1_axis_tvalid;
      m_axis_tuser   = s1_axis_tuser;
      m_axis_tlast   = s1_axis_tlast;
      s1_axis_tready = m_axis_tready;
      s0_axis_tready = 1'b0;
    end else begin
      m_axis_tdata   = s0_axis_tdata;
      m_axis_tvalid  = s0_axis_tvalid;
      m_axis_tuser   = s0_axis_tuser;
      m_axis_tlast   = s0_axis_tlast;
      s0_axis_tready = m_axis_tready;
      s1_axis_tready = 1'b0;
    end
  end

endmodule : src_mux2
`default_nettype wire
