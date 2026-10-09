// -----------------------------------------------------------------------------
// File:        ap1302_i2c.hpp
// Description: Register access to the camera image signal processor over i2c.
//              The processor sits behind an i2c multiplexer that the kernel
//              already exposes as a normal i2c device, so this uses the
//              standard interface rather than raw register access. Registers
//              are 16 bit and big endian.
// -----------------------------------------------------------------------------

#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#if defined(__linux__)
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#endif

namespace kv260gige {

class Ap1302I2c {
public:
  static constexpr uint8_t ADDR = 0x3C;

  ~Ap1302I2c() { close_(); }

  bool open(int bus = 4) {
#if defined(__linux__)
    close_();
    char path[32];
    std::snprintf(path, sizeof(path), "/dev/i2c-%d", bus);
    fd_ = ::open(path, O_RDWR);
    if (fd_ < 0) {
      std::printf("[ap1302] cannot open i2c %s (camera not present?)\n", path);
      return false;
    }
    return true;
#else
    return false;
#endif
  }
  bool ok() const { return fd_ >= 0; }

  bool wr16(uint16_t reg, uint16_t val) {
#if defined(__linux__)
    if (fd_ < 0) return false;
    uint8_t buf[4] = {uint8_t(reg >> 8), uint8_t(reg & 0xFF), uint8_t(val >> 8), uint8_t(val & 0xFF)};
    i2c_msg msg{};
    msg.addr = ADDR;
    msg.flags = 0;
    msg.len = 4;
    msg.buf = buf;
    i2c_rdwr_ioctl_data x{};
    x.msgs = &msg;
    x.nmsgs = 1;
    return ::ioctl(fd_, I2C_RDWR, &x) >= 0;
#else
    (void)reg;
    (void)val;
    return false;
#endif
  }

  bool rd16(uint16_t reg, uint16_t& out) {
#if defined(__linux__)
    if (fd_ < 0) return false;
    uint8_t a[2] = {uint8_t(reg >> 8), uint8_t(reg & 0xFF)}, d[2] = {0, 0};
    i2c_msg msgs[2]{};
    msgs[0].addr = ADDR;
    msgs[0].flags = 0;
    msgs[0].len = 2;
    msgs[0].buf = a;
    msgs[1].addr = ADDR;
    msgs[1].flags = I2C_M_RD;
    msgs[1].len = 2;
    msgs[1].buf = d;
    i2c_rdwr_ioctl_data x{};
    x.msgs = msgs;
    x.nmsgs = 2;
    if (::ioctl(fd_, I2C_RDWR, &x) < 0) return false;
    out = uint16_t(d[0]) << 8 | d[1];
    return true;
#else
    (void)reg;
    (void)out;
    return false;
#endif
  }

  static constexpr uint16_t R_AE_BV_OFF = 0x5014;
  static constexpr uint16_t R_AWB_CTRL = 0x5100;
  static constexpr uint16_t R_BRIGHTNESS = 0x7000;
  static constexpr uint16_t R_SATURATION = 0x7006;
  static constexpr uint16_t R_GAMMA = 0x700A;
  static constexpr uint16_t R_MAX_FPS = 0x2020;
  static constexpr uint16_t R_SYS_START = 0x601A;
  static constexpr uint16_t SYS_START_STALLED = 0x0200;
  static constexpr uint16_t SYS_START_TOGGLE = 0x8140;
  static constexpr uint16_t R_AE_CTRL = 0x5002;
  static constexpr uint16_t R_AE_GAIN = 0x5006;
  static constexpr uint16_t R_AE_EXP_HI = 0x500C;
  static constexpr uint16_t R_AE_EXP_LO = 0x500E;
  static constexpr uint16_t R_FLIP = 0x100C;
  static constexpr uint16_t R_SHARPEN = 0x7010;

  bool wr_exposure_us(uint32_t us) {
    if (!wr16(R_AE_EXP_HI, (uint16_t)(us >> 16))) return false;
#if defined(__linux__)
    ::usleep(10000);
#endif
    return wr16(R_AE_EXP_LO, (uint16_t)(us & 0xFFFF));
  }

private:
  void close_() {
#if defined(__linux__)
    if (fd_ >= 0) {
      ::close(fd_);
      fd_ = -1;
    }
#endif
  }
  int fd_ = -1;
};

template <class Cam, class SleepMs>
bool ap1302_set_streaming(Cam& cam, bool on, SleepMs sleep_ms) {
  auto streaming = [&](bool& out) {
    uint16_t v = 0;
    if (!cam.rd16(Ap1302I2c::R_SYS_START, v)) return false;
    out = (v & Ap1302I2c::SYS_START_STALLED) == 0;
    return true;
  };
  bool cur = false;
  if (!streaming(cur)) return false;
  if (cur == on) return true;
  if (!cam.wr16(Ap1302I2c::R_SYS_START, Ap1302I2c::SYS_START_TOGGLE)) return false;
  for (int i = 0; i < 10; ++i) {
    sleep_ms(100);
    if (streaming(cur) && cur == on) return true;
  }
  return false;
}

}
