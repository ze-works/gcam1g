// -----------------------------------------------------------------------------
// File:        test_gvcp_protocol.cpp
// Description: Host test for gvcp_protocol.hpp: malformed commands, the memory
//              read range, the heartbeat timeout and the acknowledge layout.
// -----------------------------------------------------------------------------

#include "gvcp_protocol.hpp"
#include "gvsp_header.hpp"
#include "gvcp_vectors.inc"
#include <cstdio>
#include <cstdlib>
using namespace kv260gige::gvcp;
namespace gvsp = kv260gige::gvsp;

#define CHECK(c) do { if (!(c)) { std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); std::exit(1); } } while (0)

static ParseError err_of(const uint8_t* p, size_t n) {
  auto r = parse_command(p, n);
  CHECK(std::holds_alternative<ParseError>(r));
  return std::get<ParseError>(r);
}

int main() {
  auto ok = parse_command(vec::readreg_cmd, sizeof vec::readreg_cmd);
  CHECK(std::holds_alternative<Command>(ok));
  const Command& c = std::get<Command>(ok);
  CHECK(c.opcode == GVCP_READREG_CMD);
  CHECK(c.req_id == 0x1234);
  CHECK(c.flags & GVCP_FLAG_ACK_REQUIRED);
  CHECK(c.len == 4 && c.data == vec::readreg_cmd + vec::ack_header_len);

  CHECK(err_of(vec::readreg_cmd, 3) == ParseError::Short);
  CHECK(err_of(vec::readreg_cmd, vec::ack_header_len - 1) == ParseError::Short);
  CHECK(err_of(vec::len_overrun_cmd, sizeof vec::len_overrun_cmd) == ParseError::LengthMismatch);
  CHECK(err_of(vec::bad_key_cmd, sizeof vec::bad_key_cmd) == ParseError::BadKey);

  CHECK(readmem_range_ok(0, 4, 4096));
  CHECK(readmem_range_ok(4092, 4, 4096));
  CHECK(!readmem_range_ok(4096, 4, 4096));
  CHECK(!readmem_range_ok(4092, 8, 4096));
  CHECK(!readmem_range_ok(0, 3, 4096));
  CHECK(!readmem_range_ok(0, 0, 4096));
  CHECK(!readmem_range_ok(0, GVCP_DATA_SIZE_MAX + GVCP_READMEM_LEN_ALIGN, 4096));
  CHECK(!readmem_range_ok(0xFFFFFFFCu, 8, 0xFFFFFFFFu));

  CHECK(!heartbeat_expired(1000, 900, 3000));
  CHECK(!heartbeat_expired(4000, 1000, 3000));
  CHECK(heartbeat_expired(5000, 1000, 3000));
  CHECK(!heartbeat_expired(500, 1000, 3000));

  uint8_t out[16] = {};
  size_t n = put_ack_header(out, GEV_STATUS_ACCESS_DENIED, GVCP_WRITEREG_ACK, 4, 0x1234);
  CHECK(n == vec::ack_header_len);
  CHECK(out[GVCP_HDR_PACKET_TYPE_OFFSET] == (GEV_STATUS_ACCESS_DENIED >> 8));
  CHECK(out[GVCP_HDR_FLAGS_OFFSET] == (GEV_STATUS_ACCESS_DENIED & 0xFF));
  CHECK(out[GVCP_HDR_COMMAND_OFFSET + 1] == GVCP_WRITEREG_ACK);
  CHECK(out[GVCP_HDR_SIZE_OFFSET + 1] == 4);
  CHECK(out[vec::ack_req_id_offset] == 0x12 && out[vec::ack_req_id_offset + 1] == 0x34);

  {
    uint8_t g[40] = {};
    g[2] = 0x12; g[3] = 0x34;
    g[4] = GVSP_CT_LEADER;
    g[5] = 0x00; g[6] = 0x01; g[7] = 0x02;
    CHECK(gvsp::block_id(g) == 0x1234);
    CHECK(gvsp::content_type(g) == GVSP_CT_LEADER);
    CHECK(gvsp::packet_id(g) == 0x0102);
    g[7] = 0;
    g[6] = 0;
    CHECK(gvsp::is_leader(g, sizeof g));
    CHECK(!gvsp::is_leader(g, 7));
    gvsp::set_leader_image(g, PFNC_RGB8, 1920, 1080);
    CHECK(g[20] == 0x02 && g[21] == 0x18 && g[22] == 0x00 && g[23] == 0x14);
    CHECK(g[26] == 0x07 && g[27] == 0x80);
    CHECK(g[30] == 0x04 && g[31] == 0x38);
    CHECK(gvsp::LEADER_IMAGE_END == 32);
  }

  std::puts("TEST_GVCP_PROTOCOL_PASS");
  return 0;
}
