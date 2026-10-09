// -----------------------------------------------------------------------------
// File:        test_ap1302_stall.cpp
// Description: Host test for starting and stalling the camera's image signal
//              processor. Each write to its start register toggles the state,
//              so the helper reads the state first and writes only when needed.
// -----------------------------------------------------------------------------

#include "ap1302_i2c.hpp"
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
using namespace kv260gige;

#define CHECK(c) do { if (!(c)) { std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); std::exit(1); } } while (0)

struct FakeAp1302 {
  uint16_t sys_start = 0x8240;
  uint16_t max_fps = 0x1E00;
  int sys_start_writes = 0;
  bool wr16(uint16_t reg, uint16_t) {
    if (reg == Ap1302I2c::R_SYS_START) { sys_start ^= 0x0200; ++sys_start_writes; }
    return true;
  }
  bool rd16(uint16_t reg, uint16_t& out) {
    out = reg == Ap1302I2c::R_SYS_START ? sys_start : max_fps;
    return true;
  }
};

int main() {
  auto no_sleep = [](unsigned) {};
  for (uint16_t initial : {uint16_t(0x8240), uint16_t(0x8040)}) {
    FakeAp1302 cam; cam.sys_start = initial;
    CHECK(ap1302_set_streaming(cam, true, no_sleep));
    CHECK(cam.sys_start == 0x8040);
    CHECK(ap1302_set_streaming(cam, false, no_sleep));
    CHECK(cam.sys_start == 0x8240);
  }
  FakeAp1302 cam; cam.sys_start = 0x8040;
  CHECK(ap1302_set_streaming(cam, true, no_sleep));
  CHECK(cam.sys_start_writes == 0);
  std::puts("TEST_AP1302_STALL_PASS");
  return 0;
}
