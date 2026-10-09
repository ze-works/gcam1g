// -----------------------------------------------------------------------------
// Package:     gvsp_proto_pkg
// Description: Generated constants for the stream protocol: header field
//              offsets and widths, packet content types and pixel formats.
//              The packet builder assembles every header byte from these.
// -----------------------------------------------------------------------------

package gvsp_proto_pkg;
  localparam int unsigned PFNC_MONO8 = 'h1080001;
  localparam int unsigned PFNC_RGB8 = 'h2180014;
  localparam int unsigned PFNC_BAYER_RG8 = 'h1080009;
  localparam int unsigned PFNC_MONO10 = 'h1100003;
  localparam int unsigned PFNC_MONO10P = 'h10A0046;
  localparam int unsigned PFNC_MONO10_PACKED = 'h10C0004;
  localparam int unsigned PFNC_MONO12 = 'h1100005;
  localparam int unsigned PFNC_MONO12P = 'h10C0047;
  localparam int unsigned PFNC_MONO12_PACKED = 'h10C0006;
  localparam int unsigned PFNC_MONO16 = 'h1100007;
  localparam int unsigned PFNC_BAYER_GR8 = 'h1080008;
  localparam int unsigned PFNC_BAYER_GB8 = 'h108000A;
  localparam int unsigned PFNC_BAYER_BG8 = 'h108000B;
  localparam int unsigned PFNC_BAYER_GR10 = 'h110000C;
  localparam int unsigned PFNC_BAYER_RG10 = 'h110000D;
  localparam int unsigned PFNC_BAYER_GB10 = 'h110000E;
  localparam int unsigned PFNC_BAYER_BG10 = 'h110000F;
  localparam int unsigned PFNC_BAYER_GR10P = 'h10A0056;
  localparam int unsigned PFNC_BAYER_RG10P = 'h10A0058;
  localparam int unsigned PFNC_BAYER_GB10P = 'h10A0054;
  localparam int unsigned PFNC_BAYER_BG10P = 'h10A0052;
  localparam int unsigned PFNC_BAYER_GR12 = 'h1100010;
  localparam int unsigned PFNC_BAYER_RG12 = 'h1100011;
  localparam int unsigned PFNC_BAYER_GB12 = 'h1100012;
  localparam int unsigned PFNC_BAYER_BG12 = 'h1100013;
  localparam int unsigned PFNC_BAYER_GR12P = 'h10C0057;
  localparam int unsigned PFNC_BAYER_RG12P = 'h10C0059;
  localparam int unsigned PFNC_BAYER_GB12P = 'h10C0055;
  localparam int unsigned PFNC_BAYER_BG12P = 'h10C0053;
  localparam int unsigned GVSP_STATUS_OK = 'h0;
  localparam int unsigned GVSP_CT_LEADER = 'h1;
  localparam int unsigned GVSP_CT_TRAILER = 'h2;
  localparam int unsigned GVSP_CT_PAYLOAD = 'h3;
  localparam int unsigned GVSP_CONTENT_TYPE_POS = 'h18;
  localparam int unsigned GVSP_PACKET_ID_MASK = 'hFFFFFF;
  localparam int unsigned GVSP_EXTENDED_ID_MASK = 'h80;
  localparam int unsigned GVSP_PAYLOAD_TYPE_IMAGE = 'h1;
  localparam int unsigned GVSP_PKT_STATUS_OFFSET = 0;
  localparam int unsigned GVSP_PKT_STATUS_WIDTH = 2;
  localparam int unsigned GVSP_PKT_HEADER_OFFSET = 2;
  localparam int unsigned GVSP_HDR_BLOCK_ID_OFFSET = 0;
  localparam int unsigned GVSP_HDR_BLOCK_ID_WIDTH = 2;
  localparam int unsigned GVSP_HDR_PACKET_INFOS_OFFSET = 2;
  localparam int unsigned GVSP_HDR_PACKET_INFOS_WIDTH = 4;
  localparam int unsigned GVSP_HDR_DATA_OFFSET = 6;
  localparam int unsigned GVSP_LEADER_FLAGS_OFFSET = 0;
  localparam int unsigned GVSP_LEADER_FLAGS_WIDTH = 2;
  localparam int unsigned GVSP_LEADER_PAYLOAD_TYPE_OFFSET = 2;
  localparam int unsigned GVSP_LEADER_PAYLOAD_TYPE_WIDTH = 2;
  localparam int unsigned GVSP_LEADER_TS_HIGH_OFFSET = 4;
  localparam int unsigned GVSP_LEADER_TS_HIGH_WIDTH = 4;
  localparam int unsigned GVSP_LEADER_TS_LOW_OFFSET = 8;
  localparam int unsigned GVSP_LEADER_TS_LOW_WIDTH = 4;
  localparam int unsigned GVSP_LEADER_IMAGE_INFOS_OFFSET = 12;
  localparam int unsigned GVSP_IMG_PIXEL_FORMAT_OFFSET = 0;
  localparam int unsigned GVSP_IMG_PIXEL_FORMAT_WIDTH = 4;
  localparam int unsigned GVSP_IMG_WIDTH_OFFSET = 4;
  localparam int unsigned GVSP_IMG_WIDTH_WIDTH = 4;
  localparam int unsigned GVSP_IMG_HEIGHT_OFFSET = 8;
  localparam int unsigned GVSP_IMG_HEIGHT_WIDTH = 4;
  localparam int unsigned GVSP_IMG_X_OFFSET_OFFSET = 12;
  localparam int unsigned GVSP_IMG_X_OFFSET_WIDTH = 4;
  localparam int unsigned GVSP_IMG_Y_OFFSET_OFFSET = 16;
  localparam int unsigned GVSP_IMG_Y_OFFSET_WIDTH = 4;
  localparam int unsigned GVSP_IMG_X_PADDING_OFFSET = 20;
  localparam int unsigned GVSP_IMG_X_PADDING_WIDTH = 2;
  localparam int unsigned GVSP_IMG_Y_PADDING_OFFSET = 22;
  localparam int unsigned GVSP_IMG_Y_PADDING_WIDTH = 2;
  localparam int unsigned GVSP_TRAILER_PAYLOAD_TYPE_OFFSET = 0;
  localparam int unsigned GVSP_TRAILER_PAYLOAD_TYPE_WIDTH = 4;
  localparam int unsigned GVSP_TRAILER_DATA0_OFFSET = 4;
  localparam int unsigned GVSP_TRAILER_DATA0_WIDTH = 4;
endpackage
