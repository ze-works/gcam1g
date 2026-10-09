// -----------------------------------------------------------------------------
// File:        gvsp_header.hpp
// Description: Reads the header of a stream packet built by the fabric (block
//              id, content type, packet id) and rewrites the image fields of a
//              leader. Offsets are taken from gvbs.h.
// -----------------------------------------------------------------------------

#pragma once
#include "gvcp_protocol.hpp"

namespace kv260gige::gvsp {

using gvcp::get_be;
using gvcp::put_be;

constexpr size_t HDR = GVSP_PKT_HEADER_OFFSET;
constexpr size_t BLOCK_ID = HDR + GVSP_HDR_BLOCK_ID_OFFSET;
constexpr size_t PACKET_INFOS = HDR + GVSP_HDR_PACKET_INFOS_OFFSET;
constexpr size_t DATA = HDR + GVSP_HDR_DATA_OFFSET;
constexpr size_t HEADER_END = DATA;
constexpr size_t IMAGE = DATA + GVSP_LEADER_IMAGE_INFOS_OFFSET;
constexpr size_t PIXEL_FORMAT = IMAGE + GVSP_IMG_PIXEL_FORMAT_OFFSET;
constexpr size_t WIDTH = IMAGE + GVSP_IMG_WIDTH_OFFSET;
constexpr size_t HEIGHT = IMAGE + GVSP_IMG_HEIGHT_OFFSET;
constexpr size_t LEADER_IMAGE_END = HEIGHT + GVSP_IMG_HEIGHT_WIDTH;

inline uint16_t block_id(const uint8_t* g) { return uint16_t(get_be(g + BLOCK_ID, GVSP_HDR_BLOCK_ID_WIDTH)); }
inline uint32_t packet_infos(const uint8_t* g) { return get_be(g + PACKET_INFOS, GVSP_HDR_PACKET_INFOS_WIDTH); }
inline uint8_t content_type(const uint8_t* g) { return uint8_t(packet_infos(g) >> GVSP_CONTENT_TYPE_POS); }
inline uint32_t packet_id(const uint8_t* g) { return packet_infos(g) & GVSP_PACKET_ID_MASK; }

inline bool is_leader(const uint8_t* g, size_t len) {
  return len >= HEADER_END && content_type(g) == GVSP_CT_LEADER && packet_id(g) == 0;
}

inline void set_leader_image(uint8_t* g, uint32_t pixel_format, uint32_t width, uint32_t height) {
  put_be(g + PIXEL_FORMAT, GVSP_IMG_PIXEL_FORMAT_WIDTH, pixel_format);
  put_be(g + WIDTH, GVSP_IMG_WIDTH_WIDTH, width);
  put_be(g + HEIGHT, GVSP_IMG_HEIGHT_WIDTH, height);
}

}
