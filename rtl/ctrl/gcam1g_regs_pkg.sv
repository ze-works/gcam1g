// -----------------------------------------------------------------------------
// Module:      gcam1g_regs_pkg
// Description: Register offsets, reset values and shared constants. Generated
//              from the register description; the control block and its
//              testbench both read it, so the two cannot drift apart. Do not
//              edit by hand.
// -----------------------------------------------------------------------------

package gcam1g_regs_pkg;
  localparam logic [31:0] WINDOW_BASE = 32'hA0020000;
  localparam logic [31:0] MIPI_BASE = 32'hA0100000;
  localparam logic [31:0] IIC_BASE = 32'hA0110000;
  localparam logic [31:0] FIREWALL_BASE = 32'hA0120000;

  localparam int unsigned CTRL_WIRE_OVERHEAD = 50;
  localparam int unsigned CTRL_BEAT_MAX = 4;
  localparam int unsigned CTRL_RING_SLOT_SIZE_B = 8192;
  localparam int unsigned CTRL_RING_NUM_SLOTS = 16384;

  localparam logic [31:0] CTRL_CONTROL_ADDR   = 32'hA0020000;
  localparam int unsigned CTRL_CONTROL_OFFSET = 'h00;
  localparam logic [31:0] CTRL_CONTROL_RESET  = 32'h00000000;
  localparam int CTRL_CONTROL_ACQUISITION_START_MSB = 0;
  localparam int CTRL_CONTROL_ACQUISITION_START_LSB = 0;
  localparam int CTRL_CONTROL_SOFT_RESET_MSB = 1;
  localparam int CTRL_CONTROL_SOFT_RESET_LSB = 1;
  localparam logic [31:0] CTRL_STATUS_ADDR   = 32'hA002000C;
  localparam int unsigned CTRL_STATUS_OFFSET = 'h0C;
  localparam logic [31:0] CTRL_DBG0_ADDR   = 32'hA0020010;
  localparam int unsigned CTRL_DBG0_OFFSET = 'h10;
  localparam logic [31:0] CTRL_DBG1_ADDR   = 32'hA0020014;
  localparam int unsigned CTRL_DBG1_OFFSET = 'h14;
  localparam logic [31:0] CTRL_DBG2_ADDR   = 32'hA0020018;
  localparam int unsigned CTRL_DBG2_OFFSET = 'h18;
  localparam logic [31:0] CTRL_DBG3_ADDR   = 32'hA002001C;
  localparam int unsigned CTRL_DBG3_OFFSET = 'h1C;
  localparam logic [31:0] CTRL_WR_RING_LO_ADDR   = 32'hA0020020;
  localparam int unsigned CTRL_WR_RING_LO_OFFSET = 'h20;
  localparam logic [31:0] CTRL_WR_RING_HI_ADDR   = 32'hA0020024;
  localparam int unsigned CTRL_WR_RING_HI_OFFSET = 'h24;
  localparam logic [31:0] CTRL_WR_CONS_ADDR   = 32'hA0020028;
  localparam int unsigned CTRL_WR_CONS_OFFSET = 'h28;
  localparam logic [31:0] CTRL_WR_PROD_ADDR   = 32'hA002002C;
  localparam int unsigned CTRL_WR_PROD_OFFSET = 'h2C;
  localparam logic [31:0] CTRL_SRC_MAC_LO_ADDR   = 32'hA0020030;
  localparam int unsigned CTRL_SRC_MAC_LO_OFFSET = 'h30;
  localparam logic [31:0] CTRL_SRC_MAC_LO_RESET  = 32'hBBCCDD01;
  localparam logic [31:0] CTRL_SRC_MAC_HI_ADDR   = 32'hA0020034;
  localparam int unsigned CTRL_SRC_MAC_HI_OFFSET = 'h34;
  localparam logic [31:0] CTRL_SRC_MAC_HI_RESET  = 32'h000002AA;
  localparam logic [31:0] CTRL_SRC_IP_ADDR   = 32'hA0020038;
  localparam int unsigned CTRL_SRC_IP_OFFSET = 'h38;
  localparam logic [31:0] CTRL_SRC_IP_RESET  = 32'hC0000296;
  localparam logic [31:0] CTRL_DST_MAC_LO_ADDR   = 32'hA002003C;
  localparam int unsigned CTRL_DST_MAC_LO_OFFSET = 'h3C;
  localparam logic [31:0] CTRL_DST_MAC_LO_RESET  = 32'h33445566;
  localparam logic [31:0] CTRL_DST_MAC_HI_ADDR   = 32'hA0020040;
  localparam int unsigned CTRL_DST_MAC_HI_OFFSET = 'h40;
  localparam logic [31:0] CTRL_DST_MAC_HI_RESET  = 32'h00001022;
  localparam logic [31:0] CTRL_DST_IP_ADDR   = 32'hA0020044;
  localparam int unsigned CTRL_DST_IP_OFFSET = 'h44;
  localparam logic [31:0] CTRL_DST_IP_RESET  = 32'hC0000201;
  localparam logic [31:0] CTRL_DST_PORT_ADDR   = 32'hA0020048;
  localparam int unsigned CTRL_DST_PORT_OFFSET = 'h48;
  localparam logic [31:0] CTRL_DST_PORT_RESET  = 32'h00004EEA;
  localparam logic [31:0] CTRL_PATTERN_ADDR   = 32'hA002004C;
  localparam int unsigned CTRL_PATTERN_OFFSET = 'h4C;
  localparam logic [31:0] CTRL_PATTERN_RESET  = 32'h00000003;
  localparam int CTRL_PATTERN_PATTERN_SELECT_MSB = 3;
  localparam int CTRL_PATTERN_PATTERN_SELECT_LSB = 0;
  localparam logic [31:0] CTRL_PIXFMT_ADDR   = 32'hA0020050;
  localparam int unsigned CTRL_PIXFMT_OFFSET = 'h50;
  localparam logic [31:0] CTRL_PIXFMT_RESET  = 32'h01080001;
  localparam logic [31:0] CTRL_FRAME_SZ_ADDR   = 32'hA0020054;
  localparam int unsigned CTRL_FRAME_SZ_OFFSET = 'h54;
  localparam logic [31:0] CTRL_FRAME_SZ_RESET  = 32'h000E1000;
  localparam logic [31:0] CTRL_LINE_SZ_ADDR   = 32'hA0020058;
  localparam int unsigned CTRL_LINE_SZ_OFFSET = 'h58;
  localparam logic [31:0] CTRL_LINE_SZ_RESET  = 32'h00000500;
  localparam logic [31:0] CTRL_WIDTH_ADDR   = 32'hA002005C;
  localparam int unsigned CTRL_WIDTH_OFFSET = 'h5C;
  localparam logic [31:0] CTRL_WIDTH_RESET  = 32'h00000500;
  localparam logic [31:0] CTRL_HEIGHT_ADDR   = 32'hA0020060;
  localparam int unsigned CTRL_HEIGHT_OFFSET = 'h60;
  localparam logic [31:0] CTRL_HEIGHT_RESET  = 32'h000002D0;
  localparam logic [31:0] CTRL_SRC_SEL_ADDR   = 32'hA0020064;
  localparam int unsigned CTRL_SRC_SEL_OFFSET = 'h64;
  localparam logic [31:0] CTRL_SRC_SEL_RESET  = 32'h00000000;
  localparam int CTRL_SRC_SEL_SRC_SEL_MSB = 0;
  localparam int CTRL_SRC_SEL_SRC_SEL_LSB = 0;
  localparam int CTRL_SRC_SEL_MIPI_FORMAT_MODE_MSB = 7;
  localparam int CTRL_SRC_SEL_MIPI_FORMAT_MODE_LSB = 4;
  localparam int CTRL_SRC_SEL_YUV_Y_IN_HIGH_MSB = 8;
  localparam int CTRL_SRC_SEL_YUV_Y_IN_HIGH_LSB = 8;
  localparam int CTRL_SRC_SEL_YUV_CBCR_SWAP_MSB = 9;
  localparam int CTRL_SRC_SEL_YUV_CBCR_SWAP_LSB = 9;
  localparam logic [31:0] CTRL_GV_PPB_ADDR   = 32'hA0020068;
  localparam int unsigned CTRL_GV_PPB_OFFSET = 'h68;
  localparam logic [31:0] CTRL_RING_SLOT_ADDR   = 32'hA002006C;
  localparam int unsigned CTRL_RING_SLOT_OFFSET = 'h6C;
  localparam logic [31:0] CTRL_RING_NSLOT_ADDR   = 32'hA0020070;
  localparam int unsigned CTRL_RING_NSLOT_OFFSET = 'h70;
endpackage
