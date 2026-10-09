// -----------------------------------------------------------------------------
// File:        ff_limits.hpp
// Description: Packet length arithmetic shared between the fabric and software.
//              A packet occupies its payload plus a fixed header overhead,
//              rounded up to the bus width, and it must fit in one DDR ring
//              slot. The same rule exists in the control block, so both read
//              the shared constants from the generated register header. The
//              static assertions below check the arithmetic at build time.
// -----------------------------------------------------------------------------

#pragma once
#include <cstdint>
#include <cstddef>
#include "gcam1g_regs.h"
#include "gvbs.h"

namespace kv260gige {
namespace ff {

inline constexpr uint32_t WIRE_OVERHEAD = GCAM1G_CTRL_WIRE_OVERHEAD;
static_assert(WIRE_OVERHEAD == 8u + 42u, "WIRE_OVERHEAD should be 8 bytes of stream header plus 42 of Ethernet, IP and UDP");

inline constexpr uint32_t BEAT_MAX = GCAM1G_CTRL_BEAT_MAX;

constexpr uint32_t wire_of(uint32_t ppb) {
  return ((ppb + BEAT_MAX - 1u) & ~(BEAT_MAX - 1u)) + WIRE_OVERHEAD;
}

constexpr uint32_t max_ppb(uint32_t slot) { return (slot - WIRE_OVERHEAD) & ~(BEAT_MAX - 1u); }

constexpr uint32_t ppb_for_scps(uint32_t scps, uint32_t slot) {
  constexpr uint32_t hdr = IPV4_HEADER_SIZE + UDP_HEADER_SIZE + GVSP_PKT_HEADER_OFFSET + GVSP_HDR_DATA_OFFSET;
  if (scps <= hdr) return 0;
  const uint32_t ppb = (scps - hdr) & ~(BEAT_MAX - 1u);
  const uint32_t cap = max_ppb(slot);
  return ppb < cap ? ppb : cap;
}
static_assert(ppb_for_scps(1500, 8192) == 1464, "an SCPS of 1500 gives GV_PPB 1464");
constexpr uint32_t scps_for_ppb(uint32_t ppb) {
  return ppb + IPV4_HEADER_SIZE + UDP_HEADER_SIZE + GVSP_PKT_HEADER_OFFSET + GVSP_HDR_DATA_OFFSET;
}

constexpr bool bootstrap_in_range(uint32_t addr, size_t size) {
  return static_cast<uint64_t>(addr) + 4u <= static_cast<uint64_t>(size);
}

namespace detail {
constexpr bool bootstrap_in_range_buggy_32bit(uint32_t addr, size_t size) { return addr + 4u <= size; }
}

static_assert(!bootstrap_in_range(0xFFFFFFFCu, 0x1000), "C1: 0xFFFFFFFC is not rejected");
static_assert(!bootstrap_in_range(0xFFFFFFFDu, 0x1000), "C1: 0xFFFFFFFD is not rejected");
static_assert(!bootstrap_in_range(0xFFFFFFFEu, 0x1000), "C1: 0xFFFFFFFE is not rejected");
static_assert(!bootstrap_in_range(0xFFFFFFFFu, 0x1000), "C1: 0xFFFFFFFF is not rejected");
static_assert(detail::bootstrap_in_range_buggy_32bit(0xFFFFFFFFu, 0x1000),
              "C1: the unfixed expression must accept this, otherwise the test proves nothing");
static_assert(bootstrap_in_range(0x0000u, 0x1000), "C1: addr=0 must be accepted");
static_assert(bootstrap_in_range(0x0FFCu, 0x1000), "C1: the last four bytes must be accepted");
static_assert(!bootstrap_in_range(0x0FFDu, 0x1000), "C1: one byte past the end must be rejected");
static_assert(!bootstrap_in_range(0x1000u, 0x1000), "C1: an address past the end must be rejected");

static_assert(max_ppb(8192u) == 8140u, "C3: the limit disagrees with GV_PPB_MAX in the fabric");
static_assert(wire_of(max_ppb(8192u)) <= 8192u, "C3: the clamped value does not fit");
static_assert(wire_of(8000u) <= 8192u, "C3: the production value 8000 does not fit");
static_assert(wire_of(8141u) > 8192u, "C3: an oversized value must be rejected");
static_assert(wire_of(8200u) > 8192u, "C3: an oversized value must be rejected");
static_assert(wire_of(8141u) > 8141u + WIRE_OVERHEAD, "C3: rounding up to the bus width is not accounted for");
static_assert(max_ppb(8192u) > 0u, "C3: the clamped value collapsed to zero");

static_assert(BEAT_MAX != 0u && (BEAT_MAX & (BEAT_MAX - 1u)) == 0u,
              "L4-a: BEAT_MAX must be a power of two, otherwise ~(BEAT_MAX-1) is not a rounding mask");

static_assert(BEAT_MAX == 4u, "L4-b: BEAT_MAX changed. Set FF_BEAT_MAX in ctrl.sv to the same value, "
                              "confirm ETH_BYTES <= BEAT_MAX, then update this assertion");
static_assert(WIRE_OVERHEAD == 50u,
              "L4-b: WIRE_OVERHEAD changed. Update FF_WIRE_OVERHEAD in ctrl.sv to match");

static_assert(max_ppb(8192u) % BEAT_MAX == 0u, "L4-c: the limit is not rounded to the bus width");
static_assert(wire_of(max_ppb(8192u)) <= 8192u, "L4-c: a packet at the limit does not fit in a slot");
static_assert(wire_of(max_ppb(4096u)) <= 4096u, "L4-c: a packet at the limit does not fit a 4096 byte slot");
static_assert(max_ppb(8192u) + BEAT_MAX + WIRE_OVERHEAD > 8192u,
              "L4-c: the limit wastes a whole bus word or more");
static_assert(wire_of(1u) == BEAT_MAX + WIRE_OVERHEAD, "L4-c: the rounding step does not match BEAT_MAX");
static_assert(wire_of(BEAT_MAX) == BEAT_MAX + WIRE_OVERHEAD, "L4-c: an exact multiple must not be rounded up");

}
}
