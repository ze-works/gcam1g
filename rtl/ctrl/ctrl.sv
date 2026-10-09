// -----------------------------------------------------------------------------
// Module:      ctrl
// Description: AXI4-Lite control and status registers for the camera pipeline.
//              Holds acquisition control, the DDR ring geometry and base
//              address, the Ethernet header fields the packet builder uses, the
//              image geometry, and debug counters. acquisition_start resets to
//              zero so the fabric stays idle until software starts it. Register
//              offsets and reset values come from the generated
//              gcam1g_regs_pkg.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module ctrl #(
    parameter int unsigned ADDR_W           = 7,
    parameter int unsigned FB_ADDR_W        = 40,
    parameter int unsigned GV_PPB_DEFAULT   = 8000,
    parameter int unsigned RING_SLOT_SIZE_B = 8192,
    parameter int unsigned RING_NUM_SLOTS   = 16384
) (
    input wire clk,
    input wire rst_ni,

    input  wire  [ADDR_W-1:0] s_axil_awaddr,
    input  wire               s_axil_awvalid,
    output logic              s_axil_awready,
    input  wire  [      31:0] s_axil_wdata,
    input  wire  [       3:0] s_axil_wstrb,
    input  wire               s_axil_wvalid,
    output logic              s_axil_wready,
    output logic [       1:0] s_axil_bresp,
    output logic              s_axil_bvalid,
    input  wire               s_axil_bready,
    input  wire  [ADDR_W-1:0] s_axil_araddr,
    input  wire               s_axil_arvalid,
    output logic              s_axil_arready,
    output logic [      31:0] s_axil_rdata,
    output logic [       1:0] s_axil_rresp,
    output logic              s_axil_rvalid,
    input  wire               s_axil_rready,

    output logic acquisition_start_o,
    output logic soft_reset_o,

    input wire        acquisition_active_i,
    input wire [31:0] frames_received_i,

    input wire [31:0] dbg0_i,
    input wire [31:0] dbg1_i,
    input wire [31:0] dbg2_i,
    input wire [31:0] dbg3_i,

    output logic [FB_ADDR_W-1:0] wr_ring_base_addr_o,
    output logic [         31:0] wr_consumer_idx_o,
    input  wire  [         31:0] wr_producer_idx_i,

    output logic [47:0] src_mac_o,
    output logic [31:0] src_ip_o,
    output logic [47:0] dst_mac_o,
    output logic [31:0] dst_ip_o,
    output logic [15:0] dst_port_o,

    output logic [3:0] pattern_select_o,

    output logic [31:0] pixel_format_o,
    output logic [31:0] frame_size_bytes_o,
    output logic [31:0] line_bytes_o,

    output logic [15:0] width_o,
    output logic [15:0] height_o,
    output logic        src_sel_o,
    output logic [ 3:0] mipi_format_mode_o,
    output logic        yuv_y_in_high_o,
    output logic        yuv_cbcr_swap_o,

    output logic [15:0] gv_ppb_o
);

  import gcam1g_regs_pkg::*;

  typedef enum logic [ADDR_W-1:0] {
    R_CONTROL = CTRL_CONTROL_OFFSET,
    R_STATUS = CTRL_STATUS_OFFSET,
    R_DBG0 = CTRL_DBG0_OFFSET,
    R_DBG1 = CTRL_DBG1_OFFSET,
    R_DBG2 = CTRL_DBG2_OFFSET,
    R_DBG3 = CTRL_DBG3_OFFSET,
    R_WR_RING_LO = CTRL_WR_RING_LO_OFFSET,
    R_WR_RING_HI = CTRL_WR_RING_HI_OFFSET,
    R_WR_CONS = CTRL_WR_CONS_OFFSET,
    R_WR_PROD = CTRL_WR_PROD_OFFSET,
    R_SRC_MAC_LO = CTRL_SRC_MAC_LO_OFFSET,
    R_SRC_MAC_HI = CTRL_SRC_MAC_HI_OFFSET,
    R_SRC_IP = CTRL_SRC_IP_OFFSET,
    R_DST_MAC_LO = CTRL_DST_MAC_LO_OFFSET,
    R_DST_MAC_HI = CTRL_DST_MAC_HI_OFFSET,
    R_DST_IP = CTRL_DST_IP_OFFSET,
    R_DST_PORT = CTRL_DST_PORT_OFFSET,
    R_PATTERN = CTRL_PATTERN_OFFSET,
    R_PIXFMT = CTRL_PIXFMT_OFFSET,
    R_FRAME_SZ = CTRL_FRAME_SZ_OFFSET,
    R_LINE_SZ = CTRL_LINE_SZ_OFFSET,
    R_WIDTH = CTRL_WIDTH_OFFSET,
    R_HEIGHT = CTRL_HEIGHT_OFFSET,
    R_SRC_SEL = CTRL_SRC_SEL_OFFSET,
    R_GV_PPB = CTRL_GV_PPB_OFFSET,
    R_RING_SLOT = CTRL_RING_SLOT_OFFSET,
    R_RING_NSLOT = CTRL_RING_NSLOT_OFFSET
  } csr_e;

  localparam int unsigned FF_WIRE_OVERHEAD = CTRL_WIRE_OVERHEAD;
  localparam int unsigned FF_BEAT_MAX = CTRL_BEAT_MAX;
  localparam int unsigned GV_PPB_MAX =
      (RING_SLOT_SIZE_B - FF_WIRE_OVERHEAD) & ~32'(FF_BEAT_MAX - 1);

  if (RING_SLOT_SIZE_B != CTRL_RING_SLOT_SIZE_B
      || RING_NUM_SLOTS != CTRL_RING_NUM_SLOTS) begin : g_ring_matches_yaml
    $warning(
        "ring geometry %0dB x %0d differs from ip/ctrl/regs.yaml (%0dB x %0d)",
        RING_SLOT_SIZE_B,
        RING_NUM_SLOTS,
        CTRL_RING_SLOT_SIZE_B,
        CTRL_RING_NUM_SLOTS
    );
  end
  if ((FF_BEAT_MAX & (FF_BEAT_MAX - 1)) != 0) begin : g_beat_pow2
    $error("FF_BEAT_MAX(%0d) must be a power of two (mask ~(FF_BEAT_MAX-1) is used)", FF_BEAT_MAX);
  end
  if (RING_SLOT_SIZE_B <= FF_WIRE_OVERHEAD + FF_BEAT_MAX) begin : g_slot_too_small
    $error(
        "RING_SLOT_SIZE_B(%0d) is too small for GVSP overhead %0d",
        RING_SLOT_SIZE_B,
        FF_WIRE_OVERHEAD
    );
  end
  if ((GV_PPB_MAX + FF_WIRE_OVERHEAD) > RING_SLOT_SIZE_B) begin : g_ppb_max_overflow
    $error(
        "GV_PPB_MAX(%0d)+%0d exceeds RING_SLOT_SIZE_B(%0d)",
        GV_PPB_MAX,
        FF_WIRE_OVERHEAD,
        RING_SLOT_SIZE_B
    );
  end
  localparam logic [31:0] RST_GV_PPB =
      (GV_PPB_DEFAULT > GV_PPB_MAX) ? 32'(GV_PPB_MAX) : 32'(GV_PPB_DEFAULT);

  logic [31:0] control_q;
  logic [31:0] wr_ring_lo_q;
  logic [31:0] wr_ring_hi_q;
  logic [31:0] wr_cons_q;
  logic [31:0] src_mac_lo_q;
  logic [31:0] src_mac_hi_q;
  logic [31:0] src_ip_q;
  logic [31:0] dst_mac_lo_q;
  logic [31:0] dst_mac_hi_q;
  logic [31:0] dst_ip_q;
  logic [31:0] dst_port_q;
  logic [ 3:0] pattern_q;
  logic [31:0] pixfmt_q;
  logic [31:0] frame_sz_q;
  logic [31:0] line_sz_q;
  logic [31:0] width_q;
  logic [31:0] height_q;
  logic [31:0] src_sel_q;
  logic [31:0] gv_ppb_q;

  assign wr_ring_base_addr_o = {wr_ring_hi_q[FB_ADDR_W-33:0], wr_ring_lo_q};
  assign wr_consumer_idx_o   = wr_cons_q;

  assign acquisition_start_o = control_q[0];
  assign soft_reset_o        = control_q[1];

  assign src_mac_o           = {src_mac_hi_q[15:0], src_mac_lo_q};
  assign src_ip_o            = src_ip_q;
  assign dst_mac_o           = {dst_mac_hi_q[15:0], dst_mac_lo_q};
  assign dst_ip_o            = dst_ip_q;
  assign dst_port_o          = dst_port_q[15:0];

  assign pattern_select_o    = pattern_q;

  assign pixel_format_o      = pixfmt_q;
  assign frame_size_bytes_o  = frame_sz_q;
  assign line_bytes_o        = line_sz_q;

  assign width_o             = width_q[15:0];
  assign height_o            = height_q[15:0];
  assign src_sel_o           = src_sel_q[0];
  assign mipi_format_mode_o  = src_sel_q[7:4];
  assign yuv_y_in_high_o     = src_sel_q[8];
  assign yuv_cbcr_swap_o     = src_sel_q[9];
  assign gv_ppb_o            = gv_ppb_q[15:0];

  logic              aw_en_q;
  logic [ADDR_W-1:0] awaddr_q;
  logic              wr_fire;

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      s_axil_awready <= 1'b0;
      s_axil_wready  <= 1'b0;
      s_axil_bvalid  <= 1'b0;
      s_axil_bresp   <= 2'b00;
      aw_en_q        <= 1'b1;
      awaddr_q       <= '0;
    end else begin
      if (~s_axil_awready && s_axil_awvalid && s_axil_wvalid && aw_en_q) begin
        s_axil_awready <= 1'b1;
        s_axil_wready  <= 1'b1;
        awaddr_q       <= s_axil_awaddr;
      end else begin
        s_axil_awready <= 1'b0;
        s_axil_wready  <= 1'b0;
      end
      if (s_axil_awready && s_axil_awvalid && s_axil_wready && s_axil_wvalid && aw_en_q) begin
        s_axil_bvalid <= 1'b1;
        s_axil_bresp  <= 2'b00;
        aw_en_q       <= 1'b0;
      end else if (s_axil_bvalid && s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
        aw_en_q       <= 1'b1;
      end
    end
  end
  assign wr_fire = s_axil_awready & s_axil_awvalid & s_axil_wready & s_axil_wvalid & aw_en_q;

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      control_q    <= 32'h0;
      wr_ring_lo_q <= 32'h0;
      wr_ring_hi_q <= 32'h0;
      wr_cons_q <= 32'h0;
      src_mac_lo_q <= CTRL_SRC_MAC_LO_RESET;
      src_mac_hi_q <= CTRL_SRC_MAC_HI_RESET;
      src_ip_q <= CTRL_SRC_IP_RESET;
      dst_mac_lo_q <= CTRL_DST_MAC_LO_RESET;
      dst_mac_hi_q <= CTRL_DST_MAC_HI_RESET;
      dst_ip_q <= CTRL_DST_IP_RESET;
      dst_port_q <= CTRL_DST_PORT_RESET;
      pattern_q <= 4'd3;
      pixfmt_q <= CTRL_PIXFMT_RESET;
      frame_sz_q <= CTRL_FRAME_SZ_RESET;
      line_sz_q <= CTRL_LINE_SZ_RESET;
      width_q <= CTRL_WIDTH_RESET;
      height_q <= CTRL_HEIGHT_RESET;
      src_sel_q <= CTRL_SRC_SEL_RESET;
      gv_ppb_q <= RST_GV_PPB;
    end else if (wr_fire) begin
      unique case (awaddr_q)
        R_CONTROL:    control_q <= s_axil_wdata;
        R_WR_RING_LO: wr_ring_lo_q <= s_axil_wdata;
        R_WR_RING_HI: wr_ring_hi_q <= s_axil_wdata;
        R_WR_CONS:    wr_cons_q <= s_axil_wdata;
        R_SRC_MAC_LO: src_mac_lo_q <= s_axil_wdata;
        R_SRC_MAC_HI: src_mac_hi_q <= s_axil_wdata;
        R_SRC_IP:     src_ip_q <= s_axil_wdata;
        R_DST_MAC_LO: dst_mac_lo_q <= s_axil_wdata;
        R_DST_MAC_HI: dst_mac_hi_q <= s_axil_wdata;
        R_DST_IP:     dst_ip_q <= s_axil_wdata;
        R_DST_PORT:   dst_port_q <= s_axil_wdata;
        R_PATTERN:    pattern_q <= s_axil_wdata[3:0];
        R_PIXFMT:     pixfmt_q <= s_axil_wdata;
        R_FRAME_SZ:   frame_sz_q <= s_axil_wdata;
        R_LINE_SZ:    line_sz_q <= s_axil_wdata;
        R_WIDTH:      width_q <= s_axil_wdata;
        R_HEIGHT:     height_q <= s_axil_wdata;
        R_SRC_SEL:    src_sel_q <= s_axil_wdata;
        R_GV_PPB:     gv_ppb_q <= (s_axil_wdata > 32'(GV_PPB_MAX)) ? 32'(GV_PPB_MAX) : s_axil_wdata;
        default:      ;
      endcase
    end
  end

  logic [ADDR_W-1:0] araddr_q;
  logic [      31:0] rdata_c;
  always_comb begin
    unique case (araddr_q)
      R_CONTROL:    rdata_c = control_q;
      R_STATUS:     rdata_c = {frames_received_i[15:0], 15'h0, acquisition_active_i};
      R_DBG0:       rdata_c = dbg0_i;
      R_DBG1:       rdata_c = dbg1_i;
      R_DBG2:       rdata_c = dbg2_i;
      R_DBG3:       rdata_c = dbg3_i;
      R_WR_RING_LO: rdata_c = wr_ring_lo_q;
      R_WR_RING_HI: rdata_c = wr_ring_hi_q;
      R_WR_CONS:    rdata_c = wr_cons_q;
      R_WR_PROD:    rdata_c = wr_producer_idx_i;
      R_SRC_MAC_LO: rdata_c = src_mac_lo_q;
      R_SRC_MAC_HI: rdata_c = src_mac_hi_q;
      R_SRC_IP:     rdata_c = src_ip_q;
      R_DST_MAC_LO: rdata_c = dst_mac_lo_q;
      R_DST_MAC_HI: rdata_c = dst_mac_hi_q;
      R_DST_IP:     rdata_c = dst_ip_q;
      R_DST_PORT:   rdata_c = dst_port_q;
      R_PATTERN:    rdata_c = {28'd0, pattern_q};
      R_PIXFMT:     rdata_c = pixfmt_q;
      R_FRAME_SZ:   rdata_c = frame_sz_q;
      R_LINE_SZ:    rdata_c = line_sz_q;
      R_WIDTH:      rdata_c = width_q;
      R_HEIGHT:     rdata_c = height_q;
      R_SRC_SEL:    rdata_c = src_sel_q;
      R_GV_PPB:     rdata_c = {16'd0, gv_ppb_q[15:0]};
      R_RING_SLOT:  rdata_c = 32'(RING_SLOT_SIZE_B);
      R_RING_NSLOT: rdata_c = 32'(RING_NUM_SLOTS);
      default:      rdata_c = 32'h0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      s_axil_arready <= 1'b0;
      s_axil_rvalid  <= 1'b0;
      s_axil_rresp   <= 2'b00;
      s_axil_rdata   <= 32'h0;
      araddr_q       <= '0;
    end else begin
      if (~s_axil_arready && s_axil_arvalid) begin
        s_axil_arready <= 1'b1;
        araddr_q       <= s_axil_araddr;
      end else begin
        s_axil_arready <= 1'b0;
      end
      if (s_axil_arready && s_axil_arvalid) begin
        s_axil_rvalid <= 1'b1;
        s_axil_rresp  <= 2'b00;
        s_axil_rdata  <= rdata_c;
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
    end
  end

  logic unused;
  assign unused = ^{s_axil_wstrb, frames_received_i[31:16]};

endmodule : ctrl
`default_nettype wire
