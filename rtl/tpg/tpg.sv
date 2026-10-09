// -----------------------------------------------------------------------------
// Module:      tpg
// Description: Block design wrapper for the test pattern source. Wraps the
//              pattern generator and its registers, and free-runs while
//              acquisition is enabled so the pipeline sees a continuous stream
//              of frames.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module tpg #(
    parameter int unsigned NUM_TAP      = 1,
    parameter int unsigned MAX_WIDTH = 4096,
    parameter int unsigned MAX_HEIGHT = 4096,
    parameter int unsigned MAX_BPP = 16,
    parameter int unsigned NUM_PATTERNS = 15,
    parameter int unsigned AXIL_ADDR_W = 8
) (
    input wire clk,
    input wire rst_ni,

    input  wire  [AXIL_ADDR_W-1:0] s_axil_awaddr,
    input  wire                    s_axil_awvalid,
    output logic                   s_axil_awready,
    input  wire  [           31:0] s_axil_wdata,
    input  wire  [            3:0] s_axil_wstrb,
    input  wire                    s_axil_wvalid,
    output logic                   s_axil_wready,
    output logic [            1:0] s_axil_bresp,
    output logic                   s_axil_bvalid,
    input  wire                    s_axil_bready,
    input  wire  [AXIL_ADDR_W-1:0] s_axil_araddr,
    input  wire                    s_axil_arvalid,
    output logic                   s_axil_arready,
    output logic [           31:0] s_axil_rdata,
    output logic [            1:0] s_axil_rresp,
    output logic                   s_axil_rvalid,
    input  wire                    s_axil_rready,

    output logic [NUM_TAP*32-1:0] m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  wire                   m_axis_tready,
    output logic                  m_axis_tuser,
    output logic                  m_axis_tlast,

    input wire                            start_i,
    input wire                            run_i,
    input wire [ $clog2(MAX_WIDTH+1)-1:0] width_i,
    input wire [$clog2(MAX_HEIGHT+1)-1:0] height_i,
    input wire [                    31:0] pixel_format_i,

    input wire [3:0] pattern_select_i,

    output logic [63:0] frame_id_o,
    output logic        busy_o
);

  logic [3:0] pattern_select_unused;
  logic       tpg_enable;

  tpg_regs #(
      .ADDR_W(AXIL_ADDR_W)
  ) u_regs (
      .clk             (clk),
      .rst_ni          (rst_ni),
      .s_awaddr        (s_axil_awaddr),
      .s_awvalid       (s_axil_awvalid),
      .s_awready       (s_axil_awready),
      .s_wdata         (s_axil_wdata),
      .s_wstrb         (s_axil_wstrb),
      .s_wvalid        (s_axil_wvalid),
      .s_wready        (s_axil_wready),
      .s_bresp         (s_axil_bresp),
      .s_bvalid        (s_axil_bvalid),
      .s_bready        (s_axil_bready),
      .s_araddr        (s_axil_araddr),
      .s_arvalid       (s_axil_arvalid),
      .s_arready       (s_axil_arready),
      .s_rdata         (s_axil_rdata),
      .s_rresp         (s_axil_rresp),
      .s_rvalid        (s_axil_rvalid),
      .s_rready        (s_axil_rready),
      .pattern_select_o(pattern_select_unused),
      .tpg_enable_o    (tpg_enable)
  );

  logic unused_en;
  assign unused_en = tpg_enable ^ (|pattern_select_unused);

  logic tpg_busy;
  logic idle_seen_q;
  logic tpg_start;
  always_ff @(posedge clk) begin
    if (!rst_ni) idle_seen_q <= 1'b0;
    else idle_seen_q <= run_i & ~tpg_busy;
  end
  assign tpg_start = start_i | (run_i & ~tpg_busy & ~idle_seen_q);

  tpg_gen #(
      .NUM_TAP         (NUM_TAP),
      .MAX_WIDTH       (MAX_WIDTH),
      .MAX_HEIGHT      (MAX_HEIGHT),
      .MAX_BPP         (MAX_BPP),
      .NUM_PATTERNS    (NUM_PATTERNS),
      .ENABLED_PATTERNS(15'h7FFF)
  ) u_tpg (
      .clk             (clk),
      .rst_ni          (rst_ni),
      .start_i         (tpg_start),
      .width_i         (width_i),
      .height_i        (height_i),
      .pixel_format_i  (pixel_format_i),
      .pattern_select_i(pattern_select_i),
      .m_axis_tdata_o  (m_axis_tdata),
      .m_axis_tvalid_o (m_axis_tvalid),
      .m_axis_tready_i (m_axis_tready),
      .m_axis_tuser_o  (m_axis_tuser),
      .m_axis_tlast_o  (m_axis_tlast),
      .frame_id_o      (frame_id_o),
      .busy_o          (tpg_busy)
  );

  assign busy_o = tpg_busy;

endmodule : tpg
`default_nettype wire
