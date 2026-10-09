// -----------------------------------------------------------------------------
// File:        resend_index.hpp
// Description: Maps a block identifier to its position in the DDR ring. Packet
//              resend is served by re-reading the original bytes from the ring,
//              so this only has to remember where each block started and how
//              many packets it spans.
// -----------------------------------------------------------------------------

#pragma once
#include <cstdint>

namespace kv260gige {

class ResendIndex {
public:
  struct Hit {
    bool ok = false;
    uint32_t base_slot = 0;
    uint32_t npkts = 0;
  };

  static constexpr uint32_t M = 64;

  void set_num_slots(uint32_t n) { num_slots_ = n; }

  void record_leader(uint16_t bid, uint32_t base_slot, uint64_t send_ptr) {
    Entry& e = blk_[bid % M];
    e.valid = true;
    e.bid = bid;
    e.base_slot = base_slot;
    e.send_ptr_at_leader = send_ptr;
    e.npkts = 1;
  }

  void note_pkt(uint16_t bid, uint32_t pid) {
    Entry& e = blk_[bid % M];
    if (e.valid && e.bid == bid) {
      uint32_t n = pid + 1;
      if (n > e.npkts) e.npkts = n;
    }
  }

  Hit lookup(uint16_t bid, uint64_t cur_send_ptr, uint32_t retain_slots) const {
    const Entry& e = blk_[bid % M];
    Hit h;
    if (num_slots_ && retain_slots > num_slots_) retain_slots = num_slots_;
    if (e.valid && e.bid == bid && (cur_send_ptr - e.send_ptr_at_leader) < (uint64_t)retain_slots) {
      h.ok = true;
      h.base_slot = e.base_slot;
      h.npkts = e.npkts;
    }
    return h;
  }

  uint32_t slot_for(uint32_t base_slot, uint32_t pid) const {
    return num_slots_ ? (base_slot + pid) % num_slots_ : 0;
  }

private:
  struct Entry {
    bool valid = false;
    uint16_t bid = 0;
    uint32_t base_slot = 0;
    uint64_t send_ptr_at_leader = 0;
    uint32_t npkts = 0;
  };
  Entry blk_[M];
  uint32_t num_slots_ = 0;
};

}
