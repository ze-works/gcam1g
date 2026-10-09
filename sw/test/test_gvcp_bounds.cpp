// -----------------------------------------------------------------------------
// File:        test_gvcp_bounds.cpp
// Description: Host test for the control protocol bounds arithmetic. Checks
//              that a register address near the end of the 32 bit range cannot
//              wrap past the bootstrap region, and that the packet length
//              limits reject oversized payloads. Pure C++17; no board and no
//              fabric needed.
// -----------------------------------------------------------------------------

#include "ff_limits.hpp"
#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <initializer_list>

static int failures = 0;
#define CHECK(cond, msg)                                                                                     \
  do {                                                                                                       \
    if (!(cond)) {                                                                                           \
      std::printf("FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__);                                            \
      ++failures;                                                                                            \
    } else {                                                                                                 \
      std::printf("PASS: %s\n", msg);                                                                        \
    }                                                                                                        \
  } while (0)

static bool bootstrap_in_range_buggy(uint32_t addr, size_t size) {
  return addr + 4u <= size;
}

using kv260gige::ff::BEAT_MAX;
using kv260gige::ff::bootstrap_in_range;
using kv260gige::ff::max_ppb;
using kv260gige::ff::wire_of;
using kv260gige::ff::WIRE_OVERHEAD;
namespace ff = kv260gige::ff;
int main() {
  const size_t BS = 0x1000;

  std::printf("-- C1: 32 bit wraparound --\n");
  for (uint32_t a : {0xFFFFFFFCu, 0xFFFFFFFDu, 0xFFFFFFFEu, 0xFFFFFFFFu}) {
    char m[64];
    std::snprintf(m, sizeof(m), "addr=0x%08X is rejected", a);
    CHECK(!bootstrap_in_range(a, BS), m);
    char m2[80];
    std::snprintf(m2, sizeof(m2), "addr=0x%08X was accepted by the unfixed expression", a);
    CHECK(bootstrap_in_range_buggy(a, BS), m2);
  }

  std::printf("-- C1: valid addresses --\n");
  CHECK(bootstrap_in_range(0x0000, BS), "addr=0 is accepted");
  CHECK(bootstrap_in_range(0x0FFC, BS), "addr=0x0FFC, the last four bytes, is accepted");
  CHECK(!bootstrap_in_range(0x0FFD, BS), "addr=0x0FFD, one byte past the end, is rejected");
  CHECK(!bootstrap_in_range(0x1000, BS), "addr=0x1000, past the end, is rejected");

  std::printf("-- C3: GV_PPB --\n");
  const uint32_t SLOT = 8192;
  CHECK(wire_of(8000) <= SLOT, "the production payload of 8000 fits an 8192 byte slot");
  CHECK(wire_of(8140) <= SLOT, "a payload of 8140, the limit, fits");
  CHECK(wire_of(8141) > SLOT, "a payload of 8141 does not fit once rounded up to the bus width");
  CHECK(wire_of(8200) > SLOT, "a payload of 8200 does not fit");
  CHECK(wire_of(8141) > 8141u + 50u, "an odd payload is longer on the wire than payload plus overhead alone");
  const uint32_t safe = max_ppb(SLOT);
  CHECK(wire_of(safe) <= SLOT, "the clamped payload always fits");
  CHECK(safe > 0, "the clamped payload is never zero");

  {
    constexpr uint32_t SLOT = 8192;
    CHECK(ff::ppb_for_scps(1500, SLOT) == 1464, "SCPS=1500 -> GV_PPB=1464 (IP 20 + UDP 8 + GVSP 8)");
    CHECK(ff::ppb_for_scps(1501, SLOT) == 1464, "SCPS=1501 rounds down to a whole beat");
    CHECK(ff::ppb_for_scps(1500, SLOT) % ff::BEAT_MAX == 0, "GV_PPB is a whole number of beats");
    CHECK(ff::ppb_for_scps(1500, SLOT) + 36 <= 1500, "the IP packet length does not exceed SCPS");
    CHECK(ff::ppb_for_scps(9000, SLOT) == ff::max_ppb(SLOT), "a large SCPS is capped at the slot size");
    CHECK(ff::wire_of(ff::ppb_for_scps(9000, SLOT)) <= SLOT, "the capped value fits the slot");
    CHECK(ff::ppb_for_scps(36, SLOT) == 0, "an SCPS that only fits the headers gives 0 (no change)");
    CHECK(ff::ppb_for_scps(0, SLOT) == 0, "SCPS=0 gives 0 (no change)");
    CHECK(ff::scps_for_ppb(8000) == 8036, "GV_PPB=8000 is advertised as SCPS 8036");
    CHECK(ff::ppb_for_scps(ff::scps_for_ppb(1464), SLOT) == 1464, "scps_for_ppb and ppb_for_scps round-trip");
  }

  std::printf(failures ? "\n>>> %d FAILED\n" : "\n>>> ALL PASS\n", failures);
  return failures ? 1 : 0;
}
