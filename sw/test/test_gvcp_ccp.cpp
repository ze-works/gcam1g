// -----------------------------------------------------------------------------
// File:        test_gvcp_ccp.cpp
// Description: Host test for the control server: a host that does not hold the
//              control channel cannot take it, retarget the stream or start
//              acquisition, and bad memory reads get an error acknowledge.
// -----------------------------------------------------------------------------

#include "gvcp_server.hpp"
#include <cstdio>
#include <cstdlib>
#include <thread>
using namespace kv260gige;

#define CHECK(c) do { if (!(c)) { std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); std::exit(1); } } while (0)

static constexpr uint32_t HOST_A = 0xC0000201, HOST_B = 0xC0000202;

static std::vector<uint8_t> cmd(uint16_t op, std::initializer_list<uint32_t> words) {
  std::vector<uint8_t> p(gvcp::HEADER_LEN + 4 * words.size());
  gvcp::put_be(&p[GVCP_HDR_PACKET_TYPE_OFFSET], GVCP_HDR_PACKET_TYPE_WIDTH, GVCP_CMD_KEY);
  gvcp::put_be(&p[GVCP_HDR_FLAGS_OFFSET], GVCP_HDR_FLAGS_WIDTH, GVCP_FLAG_ACK_REQUIRED);
  gvcp::put_be(&p[GVCP_HDR_COMMAND_OFFSET], GVCP_HDR_COMMAND_WIDTH, op);
  gvcp::put_be(&p[GVCP_HDR_SIZE_OFFSET], GVCP_HDR_SIZE_WIDTH, 4 * words.size());
  gvcp::put_be(&p[GVCP_HDR_ID_OFFSET], GVCP_HDR_ID_WIDTH, 7);
  size_t i = gvcp::HEADER_LEN;
  for (uint32_t w : words) { gvcp::put_be(&p[i], 4, w); i += 4; }
  return p;
}
static uint16_t status_of(const std::vector<uint8_t>& ack) {
  CHECK(ack.size() >= gvcp::HEADER_LEN);
  return gvcp::get_be(&ack[GVCP_HDR_PACKET_TYPE_OFFSET], GVCP_HDR_PACKET_TYPE_WIDTH + GVCP_HDR_FLAGS_WIDTH);
}
static uint32_t readreg(GvcpServer& s, uint32_t addr, uint32_t peer) {
  auto c = cmd(GVCP_READREG_CMD, {addr});
  auto ack = s.respond(c.data(), c.size(), peer);
  CHECK(status_of(ack) == GEV_STATUS_SUCCESS);
  return gvcp::get_be(&ack[gvcp::HEADER_LEN], 4);
}

int main() {
  GvcpServer s("192.0.2.100");

  auto take = cmd(GVCP_WRITEREG_CMD, {GVBS_CCP, GVBS_CCP_CONTROL});
  CHECK(status_of(s.respond(take.data(), take.size(), HOST_A)) == GEV_STATUS_SUCCESS);
  CHECK(readreg(s, GVBS_CCP, HOST_A) == GVBS_CCP_CONTROL);

  auto steal = s.respond(take.data(), take.size(), HOST_B);
  CHECK(status_of(steal) == GEV_STATUS_ACCESS_DENIED);
  CHECK(gvcp::get_be(&steal[GVCP_HDR_COMMAND_OFFSET], GVCP_HDR_COMMAND_WIDTH) == GVCP_WRITEREG_ACK);

  uint32_t scda = readreg(s, GVBS_SCDA0, HOST_A);
  auto w = cmd(GVCP_WRITEREG_CMD, {GVBS_SCDA0, HOST_B});
  CHECK(status_of(s.respond(w.data(), w.size(), HOST_B)) == GEV_STATUS_ACCESS_DENIED);
  CHECK(readreg(s, GVBS_SCDA0, HOST_A) == scda);
  auto start = cmd(GVCP_WRITEREG_CMD, {feat::ACQSTART, 1});
  CHECK(status_of(s.respond(start.data(), start.size(), HOST_B)) == GEV_STATUS_ACCESS_DENIED);
  CHECK(!s.streaming());

  auto scps = cmd(GVCP_WRITEREG_CMD, {GVBS_SCPS0, 1500});
  CHECK(status_of(s.respond(scps.data(), scps.size(), HOST_A)) == GEV_STATUS_SUCCESS);
  CHECK(readreg(s, GVBS_SCPS0, HOST_A) == 1500);
  auto fire = cmd(GVCP_WRITEREG_CMD, {GVBS_SCPS0, GVBS_SCPS_FIRE_TEST | 1400});
  CHECK(status_of(s.respond(fire.data(), fire.size(), HOST_A)) == GEV_STATUS_SUCCESS);
  CHECK(readreg(s, GVBS_SCPS0, HOST_A) == 1400);

  {
    auto wm = cmd(GVCP_WRITEMEM_CMD, {GVBS_SCPS0, 1200});
    auto ack = s.respond(wm.data(), wm.size(), HOST_A);
    CHECK(status_of(ack) == GEV_STATUS_SUCCESS);
    CHECK(gvcp::get_be(&ack[GVCP_HDR_COMMAND_OFFSET], GVCP_HDR_COMMAND_WIDTH) == GVCP_WRITEMEM_ACK);
    CHECK(gvcp::get_be(&ack[gvcp::HEADER_LEN], 4) == GVBS_SCPS0);
    CHECK(readreg(s, GVBS_SCPS0, HOST_A) == 1200);
    CHECK(status_of(s.respond(wm.data(), wm.size(), HOST_B)) == GEV_STATUS_ACCESS_DENIED);
    auto odd = cmd(GVCP_WRITEMEM_CMD, {GVBS_SCPS0 + 1, 1});
    CHECK(status_of(s.respond(odd.data(), odd.size(), HOST_A)) == GEV_STATUS_BAD_ALIGNMENT);
  }

  {
    auto rm = cmd(GVCP_READMEM_CMD, {feat::PIXFMT, 4});
    auto ack = s.respond(rm.data(), rm.size(), HOST_A);
    CHECK(status_of(ack) == GEV_STATUS_SUCCESS);
    CHECK(gvcp::get_be(&ack[gvcp::HEADER_LEN], 4) == feat::PIXFMT);
    CHECK(gvcp::get_be(&ack[gvcp::HEADER_LEN + 4], 4) == readreg(s, feat::PIXFMT, HOST_A));
    auto rm2 = cmd(GVCP_READMEM_CMD, {feat::WIDTH, 8});
    auto ack2 = s.respond(rm2.data(), rm2.size(), HOST_A);
    CHECK(status_of(ack2) == GEV_STATUS_SUCCESS);
    CHECK(gvcp::get_be(&ack2[gvcp::HEADER_LEN + 8], 4) == readreg(s, feat::HEIGHT, HOST_A));
    auto rc = cmd(GVCP_READMEM_CMD, {GVBS_CCP, 4});
    auto ackc = s.respond(rc.data(), rc.size(), HOST_A);
    CHECK(gvcp::get_be(&ackc[gvcp::HEADER_LEN + 4], 4) == GVBS_CCP_CONTROL);
    auto rm3 = cmd(GVCP_READMEM_CMD, {feat::PIXFMT + 2, 4});
    CHECK(status_of(s.respond(rm3.data(), rm3.size(), HOST_A)) != GEV_STATUS_SUCCESS);
  }

  {
    auto rr = cmd(GVCP_READREG_CMD, {GVBS_CCP});
    s.respond(rr.data(), rr.size(), HOST_A);
    const uint64_t t0 = s.last_control_ms();
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    s.respond(rr.data(), rr.size(), HOST_B);
    CHECK(s.last_control_ms() == t0);
    s.respond(rr.data(), rr.size(), HOST_A);
    CHECK(s.last_control_ms() > t0);
  }

  CHECK(feat::locked_while_streaming(feat::PIXFMT));
  CHECK(!feat::locked_while_streaming(feat::TESTPATTERN));
  CHECK(!feat::locked_while_streaming(GVBS_CCP));

  {
    const Peer viewer{HOST_A, 50000}, tool{HOST_A, 50001}, nobody{0, 0};
    CHECK(ccp_release_applies(false, viewer, tool));
    CHECK(ccp_release_applies(true, nobody, tool));
    CHECK(ccp_release_applies(true, viewer, viewer));
    CHECK(!ccp_release_applies(true, viewer, tool));
    CHECK(!ccp_release_applies(true, viewer, Peer{HOST_B, 50000}));
  }

  auto bad = cmd(GVCP_READREG_CMD, {GVBS_CCP});
  bad[GVCP_HDR_PACKET_TYPE_OFFSET] ^= 0xFF;
  CHECK(s.respond(bad.data(), bad.size(), HOST_A).empty());

  auto rm = cmd(GVCP_READMEM_CMD, {0x7FFFFFF0u, 4});
  CHECK(status_of(s.respond(rm.data(), rm.size(), HOST_A)) == GEV_STATUS_INVALID_ADDRESS);
  auto rm3 = cmd(GVCP_READMEM_CMD, {0, 3});
  CHECK(status_of(s.respond(rm3.data(), rm3.size(), HOST_A)) == GEV_STATUS_INVALID_PARAMETER);

  std::puts("TEST_GVCP_CCP_PASS");
  return 0;
}
