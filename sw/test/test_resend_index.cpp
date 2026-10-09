// -----------------------------------------------------------------------------
// File:        test_resend_index.cpp
// Description: Host test for the ring position index used by packet resend.
//              Checks lookup, eviction once a block falls out of the retained
//              window, and the wrap around of the block identifier. Pure C++17;
//              no board and no fabric needed.
// -----------------------------------------------------------------------------

#include "resend_index.hpp"
#include <cstdio>

using kv260gige::ResendIndex;

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

int main() {
  constexpr uint32_t NUM_SLOTS = 4096;
  constexpr uint32_t RETAIN = 3840;

  {
    ResendIndex ri;
    ri.set_num_slots(NUM_SLOTS);
    ri.record_leader(5, 100, 1000);
    for (uint32_t pid = 0; pid <= 10; ++pid) ri.note_pkt(5, pid);
    auto h = ri.lookup(5, 1000 + 50, RETAIN);
    CHECK(h.ok, "(a) recent block hits");
    CHECK(h.base_slot == 100, "(a) base_slot correct");
    CHECK(h.npkts == 11, "(a) npkts == max pid + 1");
  }

  {
    ResendIndex ri;
    ri.set_num_slots(NUM_SLOTS);
    ri.record_leader(7, 200, 1000);
    auto h_in = ri.lookup(7, 1000 + (RETAIN - 1), RETAIN);
    auto h_out = ri.lookup(7, 1000 + RETAIN, RETAIN);
    CHECK(h_in.ok, "(b) just inside retention window HITs");
    CHECK(!h_out.ok, "(b) block older than retain_slots MISSes");
  }

  {
    ResendIndex ri;
    ri.set_num_slots(NUM_SLOTS);
    uint32_t base_slot = NUM_SLOTS - 2;
    ri.record_leader(9, base_slot, 5000);
    auto h = ri.lookup(9, 5000 + 5, RETAIN);
    CHECK(h.ok, "(c) wrap block hits");
    CHECK(ri.slot_for(h.base_slot, 0) == NUM_SLOTS - 2, "(c) slot(pid=0) no wrap");
    CHECK(ri.slot_for(h.base_slot, 1) == NUM_SLOTS - 1, "(c) slot(pid=1) no wrap (last slot)");
    CHECK(ri.slot_for(h.base_slot, 2) == 0, "(c) slot(pid=2) wraps to 0");
    CHECK(ri.slot_for(h.base_slot, 5) == 3, "(c) slot(pid=5) wraps to 3");
  }

  {
    ResendIndex ri;
    ri.set_num_slots(NUM_SLOTS);
    ri.record_leader(11, 10, 1000);
    ri.note_pkt(11, 0);
    ri.note_pkt(11, 1);
    ri.record_leader(11, 999, 9000);
    ri.note_pkt(11, 0);
    ri.note_pkt(11, 1);
    ri.note_pkt(11, 2);
    auto h = ri.lookup(11, 9000 + 1, RETAIN);
    CHECK(h.ok, "(d) re-recorded bid hits");
    CHECK(h.base_slot == 999, "(d) re-recorded bid: base_slot updated to latest");
    CHECK(h.npkts == 3, "(d) re-recorded bid: npkts reset to latest frame's count");

    ri.record_leader(75, 500, 20000);
    ri.note_pkt(75, 0);
    auto h11 = ri.lookup(11, 20000, RETAIN);
    auto h75 = ri.lookup(75, 20000, RETAIN);
    CHECK(!h11.ok, "(d) bid%M collision evicts the old bid");
    CHECK(h75.ok && h75.base_slot == 500, "(d) bid%M collision: new bid hits with its own base_slot");
  }

  {
    ResendIndex ri;
    ri.set_num_slots(NUM_SLOTS);
    auto h = ri.lookup(42, 100, RETAIN);
    CHECK(!h.ok, "unknown bid MISSes");
  }

  {
    ResendIndex ri;
    ri.set_num_slots(16);
    ri.record_leader(1, 0, 0);
    for (uint32_t pid = 1; pid < 4; ++pid) ri.note_pkt(1, pid);
    CHECK(ri.lookup(1, 15, 64).ok, "(e) block still on the ring HITs");
    CHECK(!ri.lookup(1, 16, 64).ok, "(e) block overwritten after one full ring MISSes");
  }

  if (failures) {
    std::printf("TEST_RESEND_INDEX_FAIL (%d failures)\n", failures);
    return 1;
  }
  std::printf("TEST_RESEND_INDEX_PASS\n");
  return 0;
}
