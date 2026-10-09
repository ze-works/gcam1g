// -----------------------------------------------------------------------------
// File:        gvcp_protocol.hpp
// Description: Pure functions that read and write GVCP control packets:
//              command parsing, acknowledge headers, the memory read range check
//              and the heartbeat timeout. Every value comes from gvbs.h.
// -----------------------------------------------------------------------------

#pragma once
#include "gvbs.h"
#include <cstddef>
#include <cstdint>
#include <variant>

namespace kv260gige::gvcp {

constexpr size_t HEADER_LEN = GVCP_HDR_ID_OFFSET + GVCP_HDR_ID_WIDTH;

struct Command {
  uint16_t opcode;
  uint16_t req_id;
  uint16_t flags;
  const uint8_t* data;
  size_t len;
};
enum class ParseError { Short, BadKey, LengthMismatch };

inline uint32_t get_be(const uint8_t* p, size_t width) {
  uint32_t v = 0;
  for (size_t i = 0; i < width; ++i) v = (v << 8) | p[i];
  return v;
}
inline void put_be(uint8_t* p, size_t width, uint32_t v) {
  for (size_t i = width; i-- > 0; v >>= 8) p[i] = uint8_t(v);
}

inline std::variant<Command, ParseError> parse_command(const uint8_t* rx, size_t n) {
  if (n < HEADER_LEN) return ParseError::Short;
  if (get_be(rx + GVCP_HDR_PACKET_TYPE_OFFSET, GVCP_HDR_PACKET_TYPE_WIDTH) != GVCP_CMD_KEY)
    return ParseError::BadKey;
  const size_t len = get_be(rx + GVCP_HDR_SIZE_OFFSET, GVCP_HDR_SIZE_WIDTH);
  if (len > n - HEADER_LEN) return ParseError::LengthMismatch;
  return Command{uint16_t(get_be(rx + GVCP_HDR_COMMAND_OFFSET, GVCP_HDR_COMMAND_WIDTH)),
                 uint16_t(get_be(rx + GVCP_HDR_ID_OFFSET, GVCP_HDR_ID_WIDTH)),
                 uint16_t(get_be(rx + GVCP_HDR_FLAGS_OFFSET, GVCP_HDR_FLAGS_WIDTH)),
                 rx + HEADER_LEN, len};
}

inline size_t put_ack_header(uint8_t* out, uint16_t status, uint16_t ack_opcode, uint16_t len,
                             uint16_t req_id) {
  put_be(out + GVCP_HDR_PACKET_TYPE_OFFSET, GVCP_HDR_PACKET_TYPE_WIDTH + GVCP_HDR_FLAGS_WIDTH, status);
  put_be(out + GVCP_HDR_COMMAND_OFFSET, GVCP_HDR_COMMAND_WIDTH, ack_opcode);
  put_be(out + GVCP_HDR_SIZE_OFFSET, GVCP_HDR_SIZE_WIDTH, len);
  put_be(out + GVCP_HDR_ID_OFFSET, GVCP_HDR_ID_WIDTH, req_id);
  return HEADER_LEN;
}

inline bool readmem_len_ok(uint32_t len) {
  return len != 0 && len % GVCP_READMEM_LEN_ALIGN == 0 && len <= GVCP_DATA_SIZE_MAX;
}
inline bool readmem_range_ok(uint32_t addr, uint32_t len, uint32_t memory_size) {
  return readmem_len_ok(len) && addr < memory_size && len <= memory_size - addr;
}

inline bool heartbeat_expired(uint64_t now_ms, uint64_t last_ms, uint32_t timeout_ms) {
  return now_ms > last_ms && now_ms - last_ms > timeout_ms;
}

}
