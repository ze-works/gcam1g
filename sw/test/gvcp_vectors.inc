// -----------------------------------------------------------------------------
// File:        gvcp_vectors.inc
// Description: Generated control packets used by the host tests: a valid
//              register read, one whose length field overruns the packet and
//              one with the wrong leading byte.
// -----------------------------------------------------------------------------

#pragma once
#include <cstddef>
#include <cstdint>
namespace vec {
constexpr size_t ack_header_len = 8;
constexpr size_t ack_req_id_offset = 6;
constexpr uint8_t readreg_cmd[] = {0x42, 0x01, 0x00, 0x80, 0x00, 0x04, 0x12, 0x34, 0x00, 0x00, 0x00, 0x00};
constexpr uint8_t len_overrun_cmd[] = {0x42, 0x01, 0x00, 0x80, 0x00, 0x08, 0x12, 0x34, 0x00, 0x00, 0x00, 0x00};
constexpr uint8_t bad_key_cmd[] = {0xBD, 0x01, 0x00, 0x80, 0x00, 0x04, 0x12, 0x34, 0x00, 0x00, 0x00, 0x00};
}
