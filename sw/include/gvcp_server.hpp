// -----------------------------------------------------------------------------
// File:        gvcp_server.hpp
// Description: GVCP control server and stream forwarder. Makes the
//              camera discoverable and controllable by a standard client:
//              discovery, register access and the feature description document.
//              On acquisition start the fabric writes finished Ethernet frames
//              into the DDR ring and this forwards them to the client
//              untouched, so the payload never passes through the network
//              stack. Also serves packet resend requests straight out of the
//              retained part of the ring.
// -----------------------------------------------------------------------------

#pragma once
#include "gvcp_protocol.hpp"
#include "gvsp_header.hpp"
#include "pl_present.hpp"
#include "gcam1g_regs.h"
#include "axi_mmio.hpp"
#include "udmabuf.hpp"
#include "raw_socket.hpp"
#include "resend_index.hpp"
#include "ap1302_i2c.hpp"
#include "ff_limits.hpp"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <atomic>
#include <thread>
#include <mutex>
#include <time.h>
#include <chrono>
#include <condition_variable>
#include <pthread.h>
#include <sched.h>
#if defined(__linux__)
#include <arpa/inet.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#endif

namespace kv260gige {

namespace feat {
constexpr uint32_t WIDTH = 0x00010000, HEIGHT = 0x00010004, PIXFMT = 0x00010008, PAYLOAD = 0x0001000C,
                   ACQMODE = 0x00010010, ACQSTART = 0x00010014, ACQSTOP = 0x00010018, TLLOCK = 0x0001001C;
constexpr uint32_t TESTPATTERN = 0x00010020;
constexpr uint32_t BRIGHTNESS = 0x00010024;
constexpr uint32_t SATURATION = 0x00010028;
constexpr uint32_t GAMMA = 0x0001002C;
constexpr uint32_t EXPOSUREBIAS = 0x00010030;
constexpr uint32_t LIGHTSOURCE = 0x00010034;
constexpr uint32_t EXPOSURETIME = 0x00010038;
constexpr uint32_t EXPOSUREAUTO = 0x0001003C;
constexpr uint32_t GAIN = 0x00010040;
constexpr uint32_t REVERSEX = 0x00010044;
constexpr uint32_t REVERSEY = 0x00010048;
constexpr uint32_t SHARPNESS = 0x0001004C;
constexpr uint32_t ACQFRAMERATE = 0x00010050;
constexpr uint32_t XML_ADDR = 0x00020000;
constexpr bool is_feature(uint32_t a) { return a >= WIDTH && a <= ACQFRAMERATE && (a & 3) == 0; }
constexpr bool locked_while_streaming(uint32_t a) { return a == PIXFMT; }
}

struct Peer {
  uint32_t ip = 0;
  uint16_t port = 0;
  constexpr bool operator==(const Peer& o) const { return ip == o.ip && port == o.port; }
};

constexpr bool ccp_release_applies(bool streaming, Peer owner, Peer releaser) {
  return !streaming || owner.ip == 0 || owner == releaser;
}

namespace ps_default {
constexpr uint32_t WIDTH = 1280, HEIGHT = 720, PAYLOAD_SIZE = 1448;
constexpr uint16_t STREAM_SRC_PORT = 20249;
}

class GvcpServer {
public:
  explicit GvcpServer(const std::string& our_ip) : our_ip_(our_ip) { bs_.assign(0x1000, 0); }

  ~GvcpServer() {
    stop_fps_worker();
    stop_stream();
  }

  int run() {
#if defined(__linux__)
    ::setvbuf(stdout, nullptr, _IONBF, 0);
    if (init_fullfab() != 0) return 2;
    set_pl_clock();
    build_xml();
    init_bootstrap();

    fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) {
      std::printf("[gvcp] ERROR: socket\n");
      return 2;
    }
    int one = 1;
    ::setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    int prio = 6;
    ::setsockopt(fd_, SOL_SOCKET, SO_PRIORITY, &prio, sizeof(prio));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = INADDR_ANY;
    a.sin_port = htons(GVCP_PORT);
    if (::bind(fd_, (sockaddr*)&a, sizeof(a)) < 0) {
      std::printf("[gvcp] ERROR: bind 3956 (root?)\n");
      return 2;
    }
    timeval tv{1, 0};
    ::setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    std::printf("[gvcp] serving on %s:%u  (%ux%u pixfmt=0x%08X, eth ring=0x%llX, xml=%zuB)\n",
                our_ip_.c_str(), GVCP_PORT, width_, height_, pixfmt_cur_,
                (unsigned long long)ring_.phys(), xml_.size());
    std::printf("[gvcp] discover with Aravis (arv-viewer-0.8 / arv-tool-0.8); Ctrl-C to stop.\n");

    std::vector<uint8_t> rx(1500);
    for (;;) {
      sockaddr_in from{};
      socklen_t fl = sizeof(from);
      long n = ::recvfrom(fd_, rx.data(), rx.size(), 0, (sockaddr*)&from, &fl);
      heartbeat_watchdog();
      if (n < 8) continue;
      handle(rx.data(), (size_t)n, from);
    }
#else
    std::printf("[gvcp] non-Linux build\n");
    return 2;
#endif
  }

private:
#if defined(__linux__)
  static uint16_t be16(const uint8_t* p) { return (p[0] << 8) | p[1]; }
  static uint32_t be32(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
  }
  static void wbe16(uint8_t* p, uint16_t v) {
    p[0] = v >> 8;
    p[1] = v & 0xff;
  }
  static void wbe32(uint8_t* p, uint32_t v) {
    p[0] = v >> 24;
    p[1] = v >> 16;
    p[2] = v >> 8;
    p[3] = v;
  }

  void put_str(uint32_t off, const char* s, size_t field) {
    size_t l = std::strlen(s);
    if (l > field) l = field;
    std::memcpy(&bs_[off], s, l);
    for (size_t i = l; i < field; ++i) bs_[off + i] = 0;
  }

  void init_bootstrap() {
    wbe32(&bs_[GVBS_DEVICE_MODE], GVBS_DEVICE_MODE_BIG_ENDIAN);
    const uint8_t mac[6] = {0x00, 0x0A, 0x35, 0x0F, 0x29, 0x4E};
    bs_[GVBS_DEVICE_MAC_HIGH_0 + 0] = 0;
    bs_[GVBS_DEVICE_MAC_HIGH_0 + 1] = 0;
    bs_[GVBS_DEVICE_MAC_HIGH_0 + 2] = mac[0];
    bs_[GVBS_DEVICE_MAC_HIGH_0 + 3] = mac[1];
    bs_[GVBS_DEVICE_MAC_LOW_0 + 0] = mac[2];
    bs_[GVBS_DEVICE_MAC_LOW_0 + 1] = mac[3];
    bs_[GVBS_DEVICE_MAC_LOW_0 + 2] = mac[4];
    bs_[GVBS_DEVICE_MAC_LOW_0 + 3] = mac[5];
    wbe32(&bs_[GVBS_NUMBER_OF_NETWORK_INTERFACES], 0x00000001);
    uint32_t ip = 0;
    ::inet_pton(AF_INET, our_ip_.c_str(), &ip);
    uint32_t iph = ntohl(ip);
    wbe32(&bs_[GVBS_CURRENT_IP_ADDRESS_0], iph);
    wbe32(&bs_[GVBS_CURRENT_SUBNET_MASK_0], 0xFFFFFF00);
    wbe32(&bs_[GVBS_CURRENT_DEFAULT_GATEWAY_0], (iph & 0xFFFFFF00u) | 1u);
    put_str(GVBS_MANUFACTURER_NAME, "gcam1g", GVBS_MANUFACTURER_NAME_SIZE);
    put_str(GVBS_MODEL_NAME, "KV260-GigE-PoC", GVBS_MODEL_NAME_SIZE);
    put_str(GVBS_DEVICE_VERSION, "1.0", GVBS_DEVICE_VERSION_SIZE);
    put_str(GVBS_MANUFACTURER_INFO, "KV260 camera", GVBS_MANUFACTURER_INFO_SIZE);
    put_str(GVBS_SERIAL_NUMBER, "KV260POC0001", GVBS_SERIAL_NUMBER_SIZE);
    put_str(GVBS_USER_DEFINED_NAME, "kv260-gige", GVBS_USER_DEFINED_NAME_SIZE);
    char url[GVBS_XML_URL_SIZE];
    std::snprintf(url, sizeof(url), "Local:kv260_gige.xml;%08X;%zX", feat::XML_ADDR, xml_.size());
    put_str(GVBS_FIRST_URL, url, GVBS_XML_URL_SIZE);
    put_str(GVBS_SECOND_URL, "", GVBS_XML_URL_SIZE);
    wbe32(&bs_[GVBS_NUMBER_OF_STREAM_CHANNELS], 1);
    wbe32(&bs_[GVBS_GVCP_CAPABILITY], GVBS_CAP_PACKET_RESEND | GVBS_CAP_WRITE_MEMORY);
    wbe32(&bs_[GVBS_HEARTBEAT_TIMEOUT], HEARTBEAT_TIMEOUT_DEFAULT_MS);
    wbe32(&bs_[GVBS_TIMESTAMP_TICK_FREQ_HIGH], 0x00000000);
    wbe32(&bs_[GVBS_TIMESTAMP_TICK_FREQ_LOW], 0x05F5E100);
    const uint32_t ppb = ctrl_.ok() ? (ctrl_.rd(FF_R_GV_PPB) & 0xFFFFu) : 0;
    wbe32(&bs_[GVBS_SCPS0], ppb ? ff::scps_for_ppb(ppb) : 1500);
  }

  uint32_t read_reg(uint32_t addr) {
    switch (addr) {
    case feat::WIDTH: return width_;
    case feat::HEIGHT: return height_;
    case feat::PIXFMT:
      return pixfmt_cur_;
    case feat::BRIGHTNESS: return (uint32_t)(int32_t)brightness_cur_;
    case feat::SATURATION: return saturation_cur_;
    case feat::GAMMA: return gamma_cur_;
    case feat::EXPOSUREBIAS: return (uint32_t)(int32_t)expbias_cur_;
    case feat::LIGHTSOURCE: return lightsrc_cur_;
    case feat::EXPOSURETIME: return exptime_cur_;
    case feat::EXPOSUREAUTO: return expauto_cur_;
    case feat::GAIN: return gain_cur_;
    case feat::REVERSEX: return revx_cur_;
    case feat::REVERSEY: return revy_cur_;
    case feat::SHARPNESS: return sharp_cur_;
    case feat::ACQFRAMERATE: return fps_cur_;
    case feat::PAYLOAD:
      return frame_bytes_;
    case feat::ACQMODE: return acq_mode_;
    case feat::ACQSTART: return 0;
    case feat::ACQSTOP: return 0;
    case feat::TLLOCK: return tl_locked_;
    case feat::TESTPATTERN: return pattern_cur_;
    case GVBS_CCP: return ccp_;
    default: break;
    }
    if (ff::bootstrap_in_range(addr, bs_.size())) return be32(&bs_[addr]);
    return 0;
  }

  uint16_t write_status(uint32_t addr, uint32_t val) const {
    if (!ccp_ok()) {
      std::printf("[gvcp] rejecting a write to 0x%08X from a host that does not hold the control channel\n", addr);
      return GEV_STATUS_ACCESS_DENIED;
    }
    static const bool allow_any = std::getenv("GVCP_ALLOW_ANY_SCDA") != nullptr;
    if (addr == GVBS_SCDA0 && !allow_any && val && val != cur_peer_ip_) {
      std::printf("[gvcp] rejecting stream destination %u.%u.%u.%u: the stream may only go back to the requester. "
                  "Set GVCP_ALLOW_ANY_SCDA=1 to receive on another host\n",
                  (val >> 24) & 0xFF, (val >> 16) & 0xFF, (val >> 8) & 0xFF, val & 0xFF);
      return GEV_STATUS_ACCESS_DENIED;
    }
    if (addr != GVBS_CCP && !ff::bootstrap_in_range(addr, bs_.size()) && !feat::is_feature(addr))
      return GEV_STATUS_INVALID_ADDRESS;
    if (streaming_ && feat::locked_while_streaming(addr)) {
      std::printf("[gvcp] 0x%08X cannot change while streaming (returning WRITE_PROTECT)\n", addr);
      return GEV_STATUS_WRITE_PROTECT;
    }
    return GEV_STATUS_SUCCESS;
  }

  void write_reg(uint32_t addr, uint32_t val) {
    switch (addr) {
    case feat::ACQMODE: acq_mode_ = val; return;
    case feat::TLLOCK: tl_locked_ = val; return;
    case feat::TESTPATTERN: {
      pattern_cur_ = val & 0xF;
      apply_test_pattern();
      return;
    }
    case feat::ACQFRAMERATE: {
      uint32_t f = (uint32_t)clamp_i32((int32_t)val, 1, 18);
      fps_cur_ = f;
      request_fps(f);
      return;
    }
    case feat::BRIGHTNESS: {
      int32_t v = clamp_i32((int32_t)val, -2048, 2048);
      if (cam_i2c_ok()) cam_.wr16(Ap1302I2c::R_BRIGHTNESS, (uint16_t)(int16_t)v);
      brightness_cur_ = v;
      return;
    }
    case feat::SATURATION: {
      int32_t v = clamp_i32((int32_t)val, 0, 8192);
      if (cam_i2c_ok()) cam_.wr16(Ap1302I2c::R_SATURATION, (uint16_t)v);
      saturation_cur_ = (uint32_t)v;
      return;
    }
    case feat::GAMMA: {
      int32_t v = clamp_i32((int32_t)val, 0, 16384);
      if (cam_i2c_ok()) cam_.wr16(Ap1302I2c::R_GAMMA, (uint16_t)v);
      gamma_cur_ = (uint32_t)v;
      return;
    }
    case feat::EXPOSUREBIAS: {
      int32_t v = clamp_i32((int32_t)val, -768, 768);
      if (cam_i2c_ok()) cam_.wr16(Ap1302I2c::R_AE_BV_OFF, (uint16_t)(int16_t)v);
      expbias_cur_ = v;
      return;
    }
    case feat::EXPOSURETIME: {
      uint32_t v = (uint32_t)clamp_i32((int32_t)val, 100, 50000);
      exptime_cur_ = v;
      if (expauto_cur_ == 0 && cam_i2c_ok()) cam_.wr_exposure_us(v);
      return;
    }
    case feat::GAIN: {
      uint32_t v = (uint32_t)clamp_i32((int32_t)val, 0, 0xFFFF);
      gain_cur_ = v;
      if (expauto_cur_ == 0 && cam_i2c_ok()) cam_.wr16(Ap1302I2c::R_AE_GAIN, (uint16_t)v);
      return;
    }
    case feat::EXPOSUREAUTO: {
      uint32_t mode = val ? 12u : 0u;
      if (cam_i2c_ok()) {
        if (mode == 0) {
          cam_.wr_exposure_us(exptime_cur_);
          cam_.wr16(Ap1302I2c::R_AE_GAIN, (uint16_t)gain_cur_);
        }
        cam_.wr16(Ap1302I2c::R_AE_CTRL, (uint16_t)((ae_other_bits_ & ~0xFu) | mode));
      }
      expauto_cur_ = val ? 1u : 0u;
      return;
    }
    case feat::REVERSEX:
    case feat::REVERSEY: {
      if (addr == feat::REVERSEX)
        revx_cur_ = val ? 1u : 0u;
      else
        revy_cur_ = val ? 1u : 0u;
      if (cam_i2c_ok())
        cam_.wr16(Ap1302I2c::R_FLIP,
                  (uint16_t)((flip_other_bits_ & ~0x3u) | (revx_cur_ ? 1u : 0u) | (revy_cur_ ? 2u : 0u)));
      return;
    }
    case feat::SHARPNESS: {
      uint32_t v = (uint32_t)clamp_i32((int32_t)val, 0, 0x4000);
      if (cam_i2c_ok()) cam_.wr16(Ap1302I2c::R_SHARPEN, (uint16_t)v);
      sharp_cur_ = v;
      return;
    }
    case feat::LIGHTSOURCE: {
      uint32_t mode = val & 0xF;
      if (mode != 1 && mode != 2 && mode != 3 && mode != 4 && mode != 5 && mode != 6 && mode != 15) return;
      if (cam_i2c_ok()) cam_.wr16(Ap1302I2c::R_AWB_CTRL, (uint16_t)((AWB_CTRL_BASE & ~0xFu) | mode));
      lightsrc_cur_ = mode;
      return;
    }
    case feat::PIXFMT: {
      if (val != 0x01080001u && val != 0x02180014u && val != 0x01080009u) {
        std::printf("[gvcp] PixelFormat 0x%08X is not supported, ignoring it"
                    " (Mono8=0x01080001 / RGB8=0x02180014 / BayerRG8=0x01080009)\n", val);
        return;
      }
      if (streaming_.load()) {
        std::printf("[gvcp] PixelFormat cannot change while acquiring; dropping the request for 0x%08X"
                    " (stop acquisition first)\n", val);
        return;
      }
      uint32_t bpp = bpp_of(val);
      frame_bytes_ = width_ * height_ * bpp;
      if (ctrl_.ok()) {
        ctrl_.wr(FF_R_PIXFMT, val);
        ctrl_.wr(FF_R_FRAME_SZ, frame_bytes_);
        ctrl_.wr(FF_R_LINE_SZ, width_ * bpp);
        ctrl_.wr(FF_R_WIDTH, width_);
        ctrl_.wr(FF_R_HEIGHT, height_);
        ctrl_.wr(FF_R_CONTROL, 0x2);
        ::usleep(1000);
        ctrl_.wr(FF_R_CONTROL, 0x0);
      }
      pixfmt_cur_ = val;
      std::printf("[gvcp] PixelFormat is now 0x%08X (bpp=%u frame=%uB line=%uB)\n", val, bpp,
                  frame_bytes_, width_ * bpp);
      return;
    }
    case feat::ACQSTART:
      if (val) {
        start_stream();
        if (streaming_) acq_owner_ = cur_peer_;
      } else {
        stop_stream();
      }
      return;
    case feat::ACQSTOP:
      if (val) stop_stream();
      else std::printf("[gvcp] AcquisitionStop was written with 0; it is a command register, ignoring it\n");
      return;
    case GVBS_CCP: {
      if (val == 0 && !ccp_release_applies(streaming_, acq_owner_, cur_peer_)) {
        std::printf("[gvcp] CCP release from %u.%u.%u.%u:%u ignored: the stream belongs to port %u\n",
                    (cur_peer_.ip >> 24) & 0xFF, (cur_peer_.ip >> 16) & 0xFF, (cur_peer_.ip >> 8) & 0xFF,
                    cur_peer_.ip & 0xFF, cur_peer_.port, acq_owner_.port);
        return;
      }
      ccp_ = val;
      ccp_ip_ = val ? cur_peer_ip_ : 0;
      if (val == 0) stop_stream();
      return;
    }
    case GVBS_HEARTBEAT_TIMEOUT:
      wbe32(&bs_[GVBS_HEARTBEAT_TIMEOUT], val);
      return;
    case GVBS_SCDA0: {
      wbe32(&bs_[GVBS_SCDA0], val);
      if (!val) {
        std::printf("[gvcp] SCDA=0: closing the stream channel\n");
        stop_stream();
      }
      return;
    }
    case GVBS_SCPS0: {
      const uint32_t size = val & GVBS_SCPS_SIZE_MASK;
      wbe32(&bs_[GVBS_SCPS0], size);
      if (val & GVBS_SCPS_FIRE_TEST)
        fire_test_packet(size);
      else
        apply_packet_size(size);
      return;
    }
    default: break;
    }
    if (ff::bootstrap_in_range(addr, bs_.size())) wbe32(&bs_[addr], val);
  }

  void apply_packet_size(uint32_t scps) {
    const uint32_t ppb = ff::ppb_for_scps(scps, FF_SLOT_SIZE);
    if (!ppb || !ctrl_.ok()) return;
    if (streaming_) {
      std::printf("[gvcp] SCPS=%u: streaming, so GV_PPB is left unchanged (write it again before the next start)\n", scps);
      return;
    }
    ctrl_.wr(FF_R_GV_PPB, ppb);
    std::printf("[gvcp] SCPS=%u -> GV_PPB=%u\n", scps, ctrl_.rd(FF_R_GV_PPB) & 0xFFFFu);
  }

  void fire_test_packet(uint32_t packet_size) {
    uint32_t dip = be32(&bs_[GVBS_SCDA0]);
    uint16_t dport = be32(&bs_[GVBS_SCP_HOST_PORT0]) & 0xFFFF;
    if (!dip || !dport) return;
    constexpr uint32_t overhead = IPV4_HEADER_SIZE + UDP_HEADER_SIZE;
    constexpr uint32_t udp_max = 9000 - overhead;
    uint32_t udp = packet_size > overhead ? packet_size - overhead : 0;
    if (udp > udp_max) udp = udp_max;
    std::vector<uint8_t> p(udp, 0);
    int s = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return;
    int one = 1;
    ::setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    sa.sin_port = htons(ps_default::STREAM_SRC_PORT);
    ::bind(s, (sockaddr*)&sa, sizeof(sa));
    sockaddr_in d{};
    d.sin_family = AF_INET;
    d.sin_port = htons(dport);
    d.sin_addr.s_addr = htonl(dip);
    ::sendto(s, p.data(), p.size(), 0, (sockaddr*)&d, sizeof(d));
    ::close(s);
    std::printf("[gvcp] fire test packet %u B -> %u.%u.%u.%u:%u\n", udp, (dip >> 24) & 0xff,
                (dip >> 16) & 0xff, (dip >> 8) & 0xff, dip & 0xff, dport);
  }

  static uint64_t now_ms() {
    timespec ts{};
    ::clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + ts.tv_nsec / 1000000u;
  }

  void heartbeat_watchdog() {
    if (!streaming_) return;
    uint64_t to = be32(&bs_[GVBS_HEARTBEAT_TIMEOUT]);
    if (to < 500) to = 500;
    uint64_t now = now_ms();
    if (gvcp::heartbeat_expired(now, last_ctrl_ms_, to)) {
      std::printf(
          "[gvcp] heartbeat timeout (%llu ms > %llu ms): client gone -> AcquisitionStop, release CCP\n",
          (unsigned long long)(now - last_ctrl_ms_), (unsigned long long)to);
      stop_stream();
      ccp_ = 0;
      ccp_ip_ = 0;
    }
  }

  void handle(const uint8_t* p, size_t n, const sockaddr_in& from) {
    auto ack = respond(p, n, ntohl(from.sin_addr.s_addr), ntohs(from.sin_port));
    if (!ack.empty()) ::sendto(fd_, ack.data(), ack.size(), 0, (const sockaddr*)&from, sizeof(from));
  }

public:
  std::vector<uint8_t> respond(const uint8_t* p, size_t n, uint32_t peer_ip, uint16_t peer_port = 0) {
    cur_peer_ip_ = peer_ip;
    cur_peer_ = Peer{peer_ip, peer_port};
    auto parsed = gvcp::parse_command(p, n);
    if (!std::holds_alternative<gvcp::Command>(parsed)) return {};
    const gvcp::Command c = std::get<gvcp::Command>(parsed);
    if (c.opcode != GVCP_DISCOVERY_CMD && ccp_ok()) last_ctrl_ms_ = now_ms();
    const uint8_t* d = c.data;
    std::vector<uint8_t> ack;
    auto hdr = [&](uint16_t status, uint16_t ackop, uint16_t plen) {
      ack.assign(gvcp::HEADER_LEN + plen, 0);
      gvcp::put_ack_header(ack.data(), status, ackop, plen, c.req_id);
    };
    uint8_t* body = nullptr;
    auto ok = [&](uint16_t ackop, uint16_t plen) {
      hdr(GEV_STATUS_SUCCESS, ackop, plen);
      body = ack.data() + gvcp::HEADER_LEN;
    };

    switch (c.opcode) {
    case GVCP_DISCOVERY_CMD: {
      std::printf("[gvcp] DISCOVERY from %u.%u.%u.%u\n", (peer_ip >> 24) & 0xFF, (peer_ip >> 16) & 0xFF,
                  (peer_ip >> 8) & 0xFF, peer_ip & 0xFF);
      ok(GVCP_DISCOVERY_ACK, GVCP_DISCOVERY_DATA_SIZE);
      std::memcpy(body, bs_.data(), GVCP_DISCOVERY_DATA_SIZE);
      break;
    }
    case GVCP_READREG_CMD: {
      if (c.len == 0 || c.len % 4 != 0) {
        hdr(GEV_STATUS_INVALID_PARAMETER, GVCP_READREG_ACK, 0);
        break;
      }
      ok(GVCP_READREG_ACK, c.len);
      for (size_t i = 0; i < c.len; i += 4) wbe32(body + i, read_reg(be32(d + i)));
      break;
    }
    case GVCP_WRITEREG_CMD: {
      if (c.len == 0 || c.len % 8 != 0) {
        hdr(GEV_STATUS_INVALID_PARAMETER, GVCP_WRITEREG_ACK, 4);
        break;
      }
      uint32_t done = 0;
      uint16_t st = GEV_STATUS_SUCCESS;
      for (size_t i = 0; i < c.len; i += 8, ++done) {
        uint32_t a = be32(d + i), v = be32(d + i + 4);
        if ((st = write_status(a, v)) != GEV_STATUS_SUCCESS) break;
        write_reg(a, v);
      }
      hdr(st, GVCP_WRITEREG_ACK, 4);
      wbe32(ack.data() + gvcp::HEADER_LEN, done);
      break;
    }
    case GVCP_WRITEMEM_CMD: {
      if (c.len < 8 || (c.len - 4) % 4 != 0) {
        hdr(GEV_STATUS_INVALID_PARAMETER, GVCP_WRITEMEM_ACK, 0);
        break;
      }
      const uint32_t addr = be32(d);
      uint16_t st = GEV_STATUS_SUCCESS;
      if (addr % 4 != 0) {
        st = GEV_STATUS_BAD_ALIGNMENT;
      } else {
        for (size_t i = 4; i < c.len; i += 4) {
          const uint32_t a = addr + uint32_t(i - 4), v = be32(d + i);
          if ((st = write_status(a, v)) != GEV_STATUS_SUCCESS) break;
          write_reg(a, v);
        }
      }
      hdr(st, GVCP_WRITEMEM_ACK, 4);
      wbe32(ack.data() + gvcp::HEADER_LEN, addr);
      break;
    }
    case GVCP_READMEM_CMD: {
      if (c.len < 8) {
        hdr(GEV_STATUS_INVALID_PARAMETER, GVCP_READMEM_ACK, 0);
        break;
      }
      uint32_t addr = be32(d), cnt = be32(d + 4);
      if (!gvcp::readmem_len_ok(cnt)) {
        hdr(GEV_STATUS_INVALID_PARAMETER, GVCP_READMEM_ACK, 0);
        break;
      }
      const uint32_t xml_span = uint32_t((xml_.size() + GVCP_READMEM_LEN_ALIGN - 1) /
                                         GVCP_READMEM_LEN_ALIGN * GVCP_READMEM_LEN_ALIGN);
      const bool in_bs = gvcp::readmem_range_ok(addr, cnt, uint32_t(bs_.size()));
      const bool in_xml = addr >= feat::XML_ADDR && gvcp::readmem_range_ok(addr - feat::XML_ADDR, cnt, xml_span);
      constexpr uint32_t feat_span = feat::ACQFRAMERATE + 4 - feat::WIDTH;
      const bool in_feat = addr >= feat::WIDTH && addr % 4 == 0 &&
                           gvcp::readmem_range_ok(addr - feat::WIDTH, cnt, feat_span);
      if (in_feat || (in_bs && addr % 4 == 0)) {
        ok(GVCP_READMEM_ACK, uint16_t(4 + cnt));
        wbe32(body, addr);
        for (uint32_t i = 0; i < cnt; i += 4) wbe32(body + 4 + i, read_reg(addr + i));
        break;
      }
      if (!in_bs && !in_xml) {
        hdr(GEV_STATUS_INVALID_ADDRESS, GVCP_READMEM_ACK, 0);
        break;
      }
      ok(GVCP_READMEM_ACK, uint16_t(4 + cnt));
      wbe32(body, addr);
      for (uint32_t i = 0; i < cnt; ++i) body[4 + i] = mem_byte(addr + i);
      break;
    }
    case GVCP_PACKETRESEND_CMD: {
      if (c.len >= 12) {
        uint16_t bid = be32(d) & 0xFFFF;
        uint32_t first = be32(d + 4) & GVSP_PACKET_ID_MASK, last = be32(d + 8) & GVSP_PACKET_ID_MASK;
        resend_packets(bid, first, last);
      }
      return {};
    }
    default: return {};
    }
    if (!(c.flags & GVCP_FLAG_ACK_REQUIRED)) return {};
    return ack;
  }
  bool streaming() const { return streaming_; }
  uint64_t last_control_ms() const { return last_ctrl_ms_; }

private:
  void set_pl_clock() {
    const char* e = std::getenv("GVSP_PL_MHZ");
    int mhz = e ? std::atoi(e) : 0;
    if (mhz <= 0) return;
    if (mhz != 100) {
      std::printf("[gvcp] WARN: ignoring GVSP_PL_MHZ=%d. The block design fixes the reference clock at 100 MHz "
                  "and changing it corrupts memory while the clock generator re-locks.\n",
                  mhz);
      return;
    }
    int div0 = (1500 + mhz / 2) / mhz;
    if (div0 < 1) div0 = 1;
    if (div0 > 63) div0 = 63;
    MmioWindow crl;
    if (!crl.open(0xFF5E0000ull, 0x1000)) return;
    uint32_t v =
        (1u << 24) | (1u << 16) | ((uint32_t)div0 << 8) | 0u;
    crl.wr(0xC0, v);
    std::printf("[gvcp] PL0_REF_CTRL=0x%08X -> pl_clk0 ~%d MHz (div0=%d)\n", v, 1500 / div0, div0);
  }
  uint8_t mem_byte(uint32_t a) {
    if (a >= feat::XML_ADDR && a < feat::XML_ADDR + xml_.size()) return (uint8_t)xml_[a - feat::XML_ADDR];
    if (a < bs_.size()) return bs_[a];
    return 0;
  }

  void start_stream() {
    if (streaming_) return;
    uint32_t dip = be32(&bs_[GVBS_SCDA0]);
    uint16_t dport = be32(&bs_[GVBS_SCP_HOST_PORT0]) & 0xFFFF;
    if (!dip || !dport) {
      std::printf("[gvcp] AcquisitionStart but SCDA/port unset\n");
      return;
    }
    char ip[16];
    std::snprintf(ip, sizeof(ip), "%u.%u.%u.%u", (dip >> 24) & 0xff, (dip >> 16) & 0xff, (dip >> 8) & 0xff,
                  dip & 0xff);
    stream_ip_ = ip;
    stream_port_ = dport;
    uint32_t scps = be32(&bs_[GVBS_SCPS0]) & GVBS_SCPS_SIZE_MASK;
    constexpr uint32_t hdrs = IPV4_HEADER_SIZE + UDP_HEADER_SIZE + GVSP_PKT_HEADER_OFFSET + GVSP_HDR_DATA_OFFSET;
    stream_payload_ = (scps > hdrs) ? (scps - hdrs) : ps_default::PAYLOAD_SIZE;
    streaming_ = true;
    stop_ = false;
    std::printf("[gvcp] acquisition start -> %s:%u (packet size %u -> payload %u; the fabric decides the real length)\n",
                stream_ip_.c_str(), stream_port_, scps, stream_payload_);
    if (!start_fullfab_forwarder()) streaming_ = false;
  }
  static void pin_thread(std::thread& t, int cpu) {
    cpu_set_t s;
    CPU_ZERO(&s);
    CPU_SET(cpu, &s);
    ::pthread_setaffinity_np(t.native_handle(), sizeof(s), &s);
  }
  void stop_stream() {
    if (!streaming_) return;
    acq_owner_ = Peer{};
    stop_ = true;
    if (ctrl_.ok()) ctrl_.wr(FF_R_CONTROL, 0);
    if (th_.joinable()) th_.join();
    streaming_ = false;
    std::printf("[gvcp] AcquisitionStop\n");
  }
  int init_fullfab() {
    if (!pl_window_present("/sys/class/uio", FF_CTRL_BASE)) {
      std::printf("[gvcp] ERROR: the kv260_gige PL is not loaded (no uio maps 0x%llX).\n"
                  "       Load it first:  sudo xmutil loadapp kv260_gige\n",
                  (unsigned long long)FF_CTRL_BASE);
      return 2;
    }
    if (!ctrl_.open(FF_CTRL_BASE, 0x1000)) {
      std::printf("[gvcp] ERROR: ctrl@0x%llX /dev/mem (root?)\n", (unsigned long long)FF_CTRL_BASE);
      return 2;
    }
    {
      int sk = ::socket(AF_INET, SOCK_DGRAM, 0);
      if (sk >= 0) {
        struct ifreq ifr{};
        std::strncpy(ifr.ifr_name, "eth0", IFNAMSIZ - 1);
        if (::ioctl(sk, SIOCGIFHWADDR, &ifr) == 0) {
          uint8_t m[6];
          std::memcpy(m, ifr.ifr_hwaddr.sa_data, 6);
          uint32_t hi, lo;
          mac_to_hilo(m, hi, lo);
          ctrl_.wr(FF_R_SRC_MAC_HI, hi);
          ctrl_.wr(FF_R_SRC_MAC_LO, lo);
          uint32_t ip = 0;
          ::inet_pton(AF_INET, our_ip_.c_str(), &ip);
          uint32_t iph = ntohl(ip);
          ctrl_.wr(FF_R_SRC_IP, iph);
          std::printf("[gvcp] src CSR: eth0 mac %02x:%02x:%02x:%02x:%02x:%02x ip %s "
                      "(HI=0x%04X LO=0x%08X IP=0x%08X)\n",
                      m[0], m[1], m[2], m[3], m[4], m[5], our_ip_.c_str(), hi, lo, iph);
        } else
          std::perror("[gvcp] warn: SIOCGIFHWADDR eth0");
        ::close(sk);
      } else
        std::perror("[gvcp] warn: socket() for SIOCGIFHWADDR");
    }
    if (!ring_.open("udmabuf0")) {
      std::printf("[gvcp] ERROR: udmabuf0 open (full-fabric ring; module loaded?)\n");
      return 2;
    }
    width_ = env_u32("GVSP_W", ps_default::WIDTH);
    height_ = env_u32("GVSP_H", ps_default::HEIGHT);
    leader_fix_ =
        std::getenv("GVSP_LEADER_FIX") !=
        nullptr;
    pixfmt_cur_ = env_u32("GVSP_PIXFMT", PFNC_MONO8);
    const uint32_t bpp0 = bpp_of(pixfmt_cur_);
    frame_bytes_ = width_ * height_ * bpp0;
    if (ctrl_.ok()) {
      ctrl_.wr(FF_R_PIXFMT, pixfmt_cur_);
      ctrl_.wr(FF_R_FRAME_SZ, frame_bytes_);
      ctrl_.wr(FF_R_LINE_SZ, width_ * bpp0);
      ctrl_.wr(FF_R_WIDTH, width_);
      ctrl_.wr(FF_R_HEIGHT, height_);
    }
    std::printf("[gvcp] init: %ux%u pixfmt=0x%08X bpp=%u frame=%uB line=%uB\n", width_, height_, pixfmt_cur_,
                bpp0, frame_bytes_, width_ * bpp0);
    if (const char* ss = std::getenv("GVSP_SRC_SEL")) {
      if (ctrl_.ok()) {
        uint32_t v = (uint32_t)std::strtoul(ss, nullptr, 0);
        ctrl_.wr(FF_R_SRC_SEL, v);
        std::printf("[gvcp] src_sel CSR=0x%08X (src=%s y_in_high=%u cbcr_swap=%u)\n", v,
                    (v & 1) ? "camera" : "TPG", (v >> 8) & 1, (v >> 9) & 1);
        src_sel_cur_ = v;
        (void)cam_i2c_ok();
        if (v & 1u) {
          pattern_cur_ = 0;
        } else {
          pattern_cur_ = ctrl_.rd(FF_R_PATTERN) & 0xFu;
          if (pattern_cur_ == 0) {
            pattern_cur_ = GCAM1G_CTRL_PATTERN_RESET & 0xFu;
            ctrl_.wr(FF_R_PATTERN, pattern_cur_);
          }
        }
        std::printf("[gvcp] TestPattern starts at %u, read back from the hardware\n", pattern_cur_);
      }
    }
    const uint64_t need = (uint64_t)FF_SLOT_SIZE * FF_NUM_SLOTS;
    if (ring_.size() < need) {
      std::printf("[gvcp] ERROR: udmabuf0 too small %lluB < %lluB (need %u slots x %uB)\n",
                  (unsigned long long)ring_.size(), (unsigned long long)need, FF_NUM_SLOTS, FF_SLOT_SIZE);
      return 2;
    }
    if (ctrl_.ok()) {
      const uint32_t hw_slot = ctrl_.rd(FF_R_RING_SLOT), hw_nslot = ctrl_.rd(FF_R_RING_NSLOT);
      if (hw_slot != FF_SLOT_SIZE || hw_nslot != FF_NUM_SLOTS) {
        std::printf("[gvcp] ERROR: ring geometry does not match the bitstream: fabric %ux%uB, software %ux%uB\n"
                    "       deploy the bitstream and this application together"
                    " (the block design parameters and FF_SLOT_SIZE/FF_NUM_SLOTS must agree)\n",
                    hw_nslot, hw_slot, FF_NUM_SLOTS, FF_SLOT_SIZE);
        return 2;
      }
      std::printf("[gvcp] ring geometry agrees: %u slots of %uB on both sides\n", hw_nslot, hw_slot);
      if (hw_slot <= ff::WIRE_OVERHEAD) {
        std::printf("[gvcp] ERROR: slot size %u is smaller than the per packet overhead %u\n", hw_slot,
                    ff::WIRE_OVERHEAD);
        return 2;
      }
      uint32_t ppb = ctrl_.rd(FF_R_GV_PPB);
      if (ppb == 0 || ff::wire_of(ppb) > hw_slot) {
        const uint32_t safe = ff::max_ppb(hw_slot);
        std::printf("[gvcp] WARN: payload %u does not fit a %uB slot (%uB on the wire). "
                    "Clamping to %u; the fabric does not clamp and would write past the ring\n",
                    ppb, hw_slot, ff::wire_of(ppb), safe);
        ctrl_.wr(FF_R_GV_PPB, safe);
        ppb = ctrl_.rd(FF_R_GV_PPB) & 0xFFFFu;
        if (ppb == 0 || ff::wire_of(ppb) > hw_slot) {
          std::printf("[gvcp] ERROR: payload is still %u after clamping; the register write did not take effect\n", ppb);
          return 2;
        }
      }
      std::printf("[gvcp] GV_PPB=%u OK (wire=%uB <= slot %uB)\n", ppb, ff::wire_of(ppb), hw_slot);
    }
    std::printf("[gvcp] full-fabric mode: ctrl@0x%llX ring phys=0x%llX (%lluKB, %u slots) %ux%u\n",
                (unsigned long long)FF_CTRL_BASE, (unsigned long long)ring_.phys(),
                (unsigned long long)(ring_.size() >> 10), FF_NUM_SLOTS, width_, height_);
    return 0;
  }
  bool start_fullfab_forwarder() {
    ff_use_raw_ = ff_raw_.open(stream_ip_, stream_port_, our_ip_, ps_default::STREAM_SRC_PORT, "eth0");
    if (!ff_use_raw_) {
      std::printf("[gvcp] ERROR: AF_PACKET raw TX setup failed (dst ARP unresolved / iface down) -> "
                  "full-fabric forwarder cannot start (no verbatim-safe fallback)\n");
      return false;
    }
    std::printf("[gvcp] TX path: AF_PACKET raw (line-rate, verbatim whole-frame)\n");
    {
      const uint8_t* dm = ff_raw_.dst_mac();
      uint32_t hi, lo;
      mac_to_hilo(dm, hi, lo);
      ctrl_.wr(FF_R_DST_MAC_HI, hi);
      ctrl_.wr(FF_R_DST_MAC_LO, lo);
      uint32_t dip = 0;
      ::inet_pton(AF_INET, stream_ip_.c_str(), &dip);
      uint32_t diph = ntohl(dip);
      ctrl_.wr(FF_R_DST_IP, diph);
      ctrl_.wr(FF_R_DST_PORT, (uint32_t)stream_port_);
      std::printf("[gvcp] dst CSR: mac %02x:%02x:%02x:%02x:%02x:%02x ip %s port %u "
                  "(HI=0x%04X LO=0x%08X IP=0x%08X PORT=%u)\n",
                  dm[0], dm[1], dm[2], dm[3], dm[4], dm[5], stream_ip_.c_str(), stream_port_, hi, lo, diph,
                  stream_port_);
    }
    ctrl_.wr(FF_R_CONTROL, 0x2);
    ::usleep(1000);
    ctrl_.wr(FF_R_CONTROL, 0x0);
    ::usleep(1000);
    ctrl_.wr(FF_R_WR_RING_LO, (uint32_t)(ring_.phys() & 0xFFFFFFFF));
    ctrl_.wr(FF_R_WR_RING_HI, (uint32_t)(ring_.phys() >> 32));
    uint32_t prod = ctrl_.rd(FF_R_WR_PROD);
    ff_send_pos_ = prod;
    ctrl_.wr(FF_R_WR_CONS, prod);
    ff_pl_payload_ = 0;
    ri_.set_num_slots(FF_NUM_SLOTS);
    {
      const char* mb = std::getenv("GVSP_MBPS");
      ff_target_bps_ = mb ? (uint64_t)std::strtoull(mb, nullptr, 10) * 1000000ull / 8ull : 0;
      const char* bc = std::getenv("GVSP_BATCH");
      ff_batch_cap_ = bc ? std::atoi(bc) : FF_BATCH;
      if (ff_batch_cap_ < 1) ff_batch_cap_ = 1;
      if (ff_batch_cap_ > FF_BATCH) ff_batch_cap_ = FF_BATCH;
      ff_next_ns_ = 0.0;
      ff_skip_slots_ = env_u32("GVSP_SKIP_SLOTS", 0);
      ff_skipped_frames_ = 0;
      ff_skipped_pkts_ = 0;
      std::printf(
          "[gvcp] pacing: target=%s Mbps burst_cap=%d pkts  frame-skip=%s\n", mb ? mb : "unlimited",
          ff_batch_cap_,
          ff_skip_slots_
              ? (std::to_string(ff_skip_slots_) + " slots behind, dropping one block back to a leader boundary").c_str()
              : "off");
    }
    ctrl_.wr(FF_R_CONTROL, 0x1);
    std::printf("[gvcp] full-fabric stream -> %s:%u (src %u) ring@0x%llX start prod=cons=%u status=0x%08X\n",
                stream_ip_.c_str(), stream_port_, ps_default::STREAM_SRC_PORT, (unsigned long long)ring_.phys(), prod,
                ctrl_.rd(FF_R_STATUS));
    th_ = std::thread([this] { forwarder_loop(); });
    pin_thread(th_, 1);
    return true;
  }
  void forwarder_loop() {
    const uint8_t* base = ring_.bytes();
    uint64_t pkts = 0, bytes = 0, drops = 0, errs = 0;
    while (!stop_) {
      uint32_t producer = ctrl_.rd(FF_R_WR_PROD);
      if (producer == ff_send_pos_) {
        timespec ts{0, 20000};
        ::nanosleep(&ts, nullptr);
        continue;
      }
      uint32_t navail = producer - ff_send_pos_;
      if (ff_skip_slots_ && navail > ff_skip_slots_) {
        uint32_t s0chk = ff_send_pos_ % FF_NUM_SLOTS;
        ring_.sync_for_cpu((uint64_t)s0chk * FF_SLOT_SIZE, FF_SLOT_SIZE);
        const uint8_t* f0 = base + (uint64_t)s0chk * FF_SLOT_SIZE;
        int fl0 = frame_len_of(f0);
        bool at_leader = fl0 >= (int)FF_UDP_BODY && gvsp::is_leader(f0 + FF_UDP_BODY, fl0 - FF_UDP_BODY);
        if (at_leader) {
          const uint32_t CH = 256;
          uint32_t scanned = 0;
          bool moved = false;
          while (ff_send_pos_ != producer && scanned < FF_NUM_SLOTS) {
            uint32_t s = ff_send_pos_ % FF_NUM_SLOTS;
            if ((scanned % CH) == 0) {
              uint32_t n = FF_NUM_SLOTS - s;
              if (n > CH) n = CH;
              ring_.sync_for_cpu((uint64_t)s * FF_SLOT_SIZE, (uint64_t)n * FF_SLOT_SIZE);
            }
            const uint8_t* f = base + (uint64_t)s * FF_SLOT_SIZE;
            int fl = frame_len_of(f);
            bool is_leader = fl >= (int)FF_UDP_BODY && gvsp::is_leader(f + FF_UDP_BODY, fl - FF_UDP_BODY);
            if (is_leader && moved) break;
            ++ff_send_pos_;
            ++scanned;
            ++ff_skipped_pkts_;
            moved = true;
          }
          ++ff_skipped_frames_;
          ctrl_.wr(FF_R_WR_CONS, (ff_send_pos_ > FF_RETAIN_SLOTS) ? ff_send_pos_ - FF_RETAIN_SLOTS : 0);
          producer = ctrl_.rd(FF_R_WR_PROD);
          if (ff_send_pos_ == producer) continue;
          navail = producer - ff_send_pos_;
        }
      }
      uint32_t nb = navail > (uint32_t)ff_batch_cap_ ? (uint32_t)ff_batch_cap_ : navail;
      uint32_t s0 = ff_send_pos_ % FF_NUM_SLOTS;
      if (s0 + nb <= FF_NUM_SLOTS) {
        ring_.sync_for_cpu((uint64_t)s0 * FF_SLOT_SIZE, (uint64_t)nb * FF_SLOT_SIZE);
      } else {
        uint32_t first = FF_NUM_SLOTS - s0;
        ring_.sync_for_cpu((uint64_t)s0 * FF_SLOT_SIZE, (uint64_t)first * FF_SLOT_SIZE);
        ring_.sync_for_cpu(0, (uint64_t)(nb - first) * FF_SLOT_SIZE);
      }
      int m = 0;
      for (uint32_t i = 0; i < nb && ff_send_pos_ != producer; ++i) {
        uint32_t slot = ff_send_pos_ % FF_NUM_SLOTS;
        const uint8_t* f = base + (uint64_t)slot * FF_SLOT_SIZE;
        int fl = frame_len_of(f);
        if (fl < 0) {
          ++drops;
          ++ff_send_pos_;
          continue;
        }
        const uint8_t* g = f + FF_UDP_BODY;
        int glen = fl - (int)FF_UDP_BODY;
        if (glen >= 8) {
          mm_hdr_[m] = f;
          mm_hlen_[m] = (uint32_t)fl;
          mm_len_[m] = (uint32_t)fl;
          ++m;
        } else
          ++drops;
        if (glen >= (int)gvsp::HEADER_END) {
          const uint8_t ct = gvsp::content_type(g);
          uint16_t bid16 = gvsp::block_id(g);
          if (bid16 == 0) bid16 = 1;
          const uint32_t pid = gvsp::packet_id(g);
          const bool leader = ct == GVSP_CT_LEADER && pid == 0;
          if (ct == GVSP_CT_PAYLOAD) {
            int paylen = glen - (int)gvsp::HEADER_END;
            if (ff_pl_payload_ == 0 && paylen > 1) {
              ff_pl_payload_ = (uint32_t)paylen;
              stream_payload_ = ff_pl_payload_;
            }
          }
          if (leader && leader_fix_ && glen >= (int)gvsp::LEADER_IMAGE_END) {
            gvsp::set_leader_image(const_cast<uint8_t*>(g), pixfmt_cur_, width_, height_);
          }
          {
            std::lock_guard<std::mutex> lk(ri_mtx_);
            if (leader) ri_.record_leader(bid16, slot, ff_send_pos_);
            ri_.note_pkt(bid16, pid);
          }
        }
        ++ff_send_pos_;
      }
      if (m > 0) {
        int sent = ff_raw_.send_batch_verbatim(mm_hdr_, mm_hlen_, (size_t)m);
        uint64_t bb = 0;
        if (sent < 0) {
          errs += (uint64_t)m;
        } else {
          for (int k = 0; k < sent; ++k) {
            ++pkts;
            bytes += mm_len_[k];
            bb += mm_len_[k];
          }
          if (sent < m) errs += (uint64_t)(m - sent);
        }
        if (ff_target_bps_ && bb) {
          timespec tn;
          ::clock_gettime(CLOCK_MONOTONIC, &tn);
          double now = (double)tn.tv_sec * 1e9 + tn.tv_nsec;
          if (ff_next_ns_ == 0.0 || ff_next_ns_ < now - 2e6)
            ff_next_ns_ = now;
          ff_next_ns_ += (double)bb * 1e9 / (double)ff_target_bps_;
          if (ff_next_ns_ > now) {
            double d = ff_next_ns_ - now;
            timespec ts{(time_t)(d / 1e9), (long)(d - (long)(d / 1e9) * 1e9)};
            ::nanosleep(&ts, nullptr);
          }
        }
      }
      uint32_t rel = (ff_send_pos_ > FF_RETAIN_SLOTS) ? ff_send_pos_ - FF_RETAIN_SLOTS : 0;
      ctrl_.wr(FF_R_WR_CONS, rel);
    }
    ctrl_.wr(FF_R_CONTROL, 0x0);
    std::printf("[gvcp] forwarder stopped: pkts=%llu bytes=%llu drops=%llu send_err=%llu "
                "skipped_frames=%llu skipped_pkts=%llu\n",
                (unsigned long long)pkts, (unsigned long long)bytes, (unsigned long long)drops,
                (unsigned long long)errs, (unsigned long long)ff_skipped_frames_,
                (unsigned long long)ff_skipped_pkts_);
  }
  static constexpr uint32_t FF_UDP_BODY = 14 + IPV4_HEADER_SIZE + UDP_HEADER_SIZE;
  static int frame_len_of(const uint8_t* f) {
    uint16_t et = (uint16_t(f[12]) << 8) | f[13];
    if (et != 0x0800) return -1;
    uint16_t ip_len = (uint16_t(f[16]) << 8) | f[17];
    int fl = 14 + ip_len;
    if (fl < (int)FF_UDP_BODY || (uint32_t)fl > (int)FF_SLOT_SIZE) return -1;
    return fl;
  }
  bool ccp_ok() const { return !(ccp_ && ccp_ip_ && ccp_ip_ != cur_peer_ip_); }

  static uint32_t env_u32(const char* k, uint32_t d) {
    const char* e = std::getenv(k);
    return e ? (uint32_t)std::strtoul(e, nullptr, 0) : d;
  }
  static void mac_to_hilo(const uint8_t m[6], uint32_t& hi, uint32_t& lo) {
    hi = ((uint32_t)m[0] << 8) | m[1];
    lo = ((uint32_t)m[2] << 24) | ((uint32_t)m[3] << 16) | ((uint32_t)m[4] << 8) | m[5];
  }

  void build_xml();

  std::string our_ip_;
  MmioWindow ctrl_;
  UdmaBuf ring_;
  std::atomic<uint32_t> ff_send_pos_{0};
  uint32_t ff_pl_payload_ = 0;
  ResendIndex ri_;
  std::mutex ri_mtx_;
  static constexpr uint64_t FF_CTRL_BASE = GCAM1G_WINDOW_BASE;
  static constexpr uint32_t FF_R_CONTROL = GCAM1G_CTRL_CONTROL_OFFSET,
                            FF_R_STATUS = GCAM1G_CTRL_STATUS_OFFSET;
  static constexpr uint32_t FF_R_WR_RING_LO = GCAM1G_CTRL_WR_RING_LO_OFFSET,
                            FF_R_WR_RING_HI = GCAM1G_CTRL_WR_RING_HI_OFFSET,
                            FF_R_WR_CONS = GCAM1G_CTRL_WR_CONS_OFFSET,
                            FF_R_WR_PROD = GCAM1G_CTRL_WR_PROD_OFFSET;
  static constexpr uint32_t FF_R_SRC_MAC_LO = GCAM1G_CTRL_SRC_MAC_LO_OFFSET,
                            FF_R_SRC_MAC_HI = GCAM1G_CTRL_SRC_MAC_HI_OFFSET,
                            FF_R_SRC_IP = GCAM1G_CTRL_SRC_IP_OFFSET,
                            FF_R_DST_MAC_LO = GCAM1G_CTRL_DST_MAC_LO_OFFSET,
                            FF_R_DST_MAC_HI = GCAM1G_CTRL_DST_MAC_HI_OFFSET,
                            FF_R_DST_IP = GCAM1G_CTRL_DST_IP_OFFSET,
                            FF_R_DST_PORT = GCAM1G_CTRL_DST_PORT_OFFSET;
  static constexpr uint32_t FF_R_PATTERN = GCAM1G_CTRL_PATTERN_OFFSET;
  static constexpr uint32_t FF_R_PIXFMT = GCAM1G_CTRL_PIXFMT_OFFSET,
                            FF_R_FRAME_SZ = GCAM1G_CTRL_FRAME_SZ_OFFSET,
                            FF_R_LINE_SZ = GCAM1G_CTRL_LINE_SZ_OFFSET;
  static constexpr uint32_t FF_R_WIDTH = GCAM1G_CTRL_WIDTH_OFFSET,
                            FF_R_HEIGHT = GCAM1G_CTRL_HEIGHT_OFFSET;
  static constexpr uint32_t FF_R_SRC_SEL = GCAM1G_CTRL_SRC_SEL_OFFSET;
  static constexpr uint32_t FF_R_RING_SLOT = GCAM1G_CTRL_RING_SLOT_OFFSET,
                            FF_R_RING_NSLOT = GCAM1G_CTRL_RING_NSLOT_OFFSET;
  static constexpr uint32_t FF_R_GV_PPB = GCAM1G_CTRL_GV_PPB_OFFSET;
  static constexpr uint32_t FF_SLOT_SIZE = GCAM1G_CTRL_RING_SLOT_SIZE_B,
                            FF_NUM_SLOTS = GCAM1G_CTRL_RING_NUM_SLOTS;
  static constexpr uint32_t FF_RETAIN_SLOTS =
      14336;
  static constexpr int FF_BATCH = 64;
  uint32_t mm_len_[FF_BATCH];
  uint64_t ff_target_bps_ = 0;
  int ff_batch_cap_ = FF_BATCH;
  uint32_t ff_skip_slots_ = 0;
  uint64_t ff_skipped_frames_ = 0, ff_skipped_pkts_ = 0;
  double ff_next_ns_ = 0.0;
  RawSender ff_raw_;
  bool ff_use_raw_ = false;
  const uint8_t* mm_hdr_[FF_BATCH];
  uint32_t mm_hlen_[FF_BATCH];
  uint32_t width_ = 0, height_ = 0, frame_bytes_ = 0;
  std::vector<uint8_t> bs_;
  std::string xml_;
  uint32_t ccp_ = 0, acq_mode_ = 2, tl_locked_ = 0;
  uint32_t ccp_ip_ = 0;
  uint32_t cur_peer_ip_ = 0;
  Peer cur_peer_{};
  Peer acq_owner_{};
  uint32_t pattern_cur_ = 0;
  Ap1302I2c cam_;
  bool cam_open_tried_ = false;
  int32_t brightness_cur_ = 0;
  uint32_t saturation_cur_ = 0x1000;
  uint32_t gamma_cur_ = 0;
  int32_t expbias_cur_ = 0;
  uint32_t lightsrc_cur_ = 5;
  static constexpr uint32_t AWB_CTRL_BASE = 0x1150;
  static int32_t clamp_i32(int32_t v, int32_t lo, int32_t hi) { return v < lo ? lo : (v > hi ? hi : v); }
  bool cam_i2c_ok() {
    if (!(src_sel_cur_ & 1u)) return false;
    if (!cam_open_tried_) {
      cam_open_tried_ = true;
      if (cam_.open(4)) {
        uint16_t v;
        if (cam_.rd16(Ap1302I2c::R_AE_CTRL, v)) ae_other_bits_ = v;
        if (cam_.rd16(Ap1302I2c::R_FLIP, v)) flip_other_bits_ = v;
        expauto_cur_ = ((ae_other_bits_ & 0xF) == 0) ? 0u : 1u;
        revx_cur_ = flip_other_bits_ & 1u;
        revy_cur_ = (flip_other_bits_ >> 1) & 1u;
        cam_.wr16(Ap1302I2c::R_BRIGHTNESS, (uint16_t)(int16_t)brightness_cur_);
        cam_.wr16(Ap1302I2c::R_SATURATION, (uint16_t)saturation_cur_);
        cam_.wr16(Ap1302I2c::R_GAMMA, (uint16_t)gamma_cur_);
        cam_.wr16(Ap1302I2c::R_AE_BV_OFF, (uint16_t)(int16_t)expbias_cur_);
        cam_.wr16(Ap1302I2c::R_SHARPEN, (uint16_t)sharp_cur_);
        cam_.wr16(Ap1302I2c::R_AWB_CTRL, (uint16_t)((AWB_CTRL_BASE & ~0xFu) | lightsrc_cur_));
        std::printf("[gvcp] applying the default image quality settings to the camera "
                    "(Brightness=%d Saturation=%u Gamma=%u ExposureBiasEV=%d Sharpness=%u LightSource=%u)\n",
                    brightness_cur_, saturation_cur_, gamma_cur_, expbias_cur_, sharp_cur_, lightsrc_cur_);
        std::printf("[gvcp] AP1302: AE_CTRL=0x%04X FLIP=0x%04X (ExposureAuto=%s ReverseX=%u ReverseY=%u)\n",
                    ae_other_bits_, flip_other_bits_, expauto_cur_ ? "Continuous" : "Off", revx_cur_,
                    revy_cur_);
        fps_applied_ = 0;
        need_initial_fps_ = true;
      }
    }
    const bool ok = cam_.ok();
    if (ok && need_initial_fps_) {
      need_initial_fps_ = false;
      enqueue_fps(fps_cur_);
      std::printf("[gvcp] requesting the startup frame rate of %u fps (applied asynchronously)\n", fps_cur_);
    }
    return ok;
  }
  bool need_initial_fps_ = false;
  uint32_t src_sel_cur_ = 0;
  uint32_t exptime_cur_ = 16000;
  uint32_t expauto_cur_ = 1;
  uint32_t gain_cur_ = 0x1000;
  uint32_t revx_cur_ = 0, revy_cur_ = 0, sharp_cur_ = 0;
  uint32_t fps_cur_ = 18;
  bool fps_pending_ = false;
  void flush_image_stages() {
    if (!ctrl_.ok()) return;
    const uint32_t ctl = ctrl_.rd(FF_R_CONTROL);
    ctrl_.wr(FF_R_CONTROL, ctl & ~1u);
    ::usleep(2000);
    ctrl_.wr(FF_R_CONTROL, (ctl & ~1u) | 0x2u);
    ::usleep(1000);
    ctrl_.wr(FF_R_CONTROL, ctl & ~1u);
    ::usleep(1000);
    ctrl_.wr(FF_R_CONTROL, ctl);
  }

  void apply_test_pattern() {
    if (!ctrl_.ok()) return;
    if (pattern_cur_ == 0) {
      src_sel_cur_ |= 1u;
    }
    else {
      ctrl_.wr(FF_R_PATTERN, pattern_cur_);
      src_sel_cur_ &= ~1u;
    }
    ctrl_.wr(FF_R_SRC_SEL, src_sel_cur_);
    if (!streaming_.load()) flush_image_stages();
    std::printf("[gvcp] test pattern %u applied -> source select 0x%X (%s)%s\n", pattern_cur_, src_sel_cur_,
                (src_sel_cur_ & 1) ? "camera" : "PL TPG",
                streaming_.load() ? " [switched live without a flush; the frame at the seam will be torn]" : "");
    if ((src_sel_cur_ & 1u) && fps_pending_) {
      std::printf("[gvcp] applying the deferred frame rate of %u fps to the camera\n", fps_cur_);
      request_fps(fps_cur_);
    }
  }

  static constexpr unsigned FPS_COOLDOWN_MS = 1000;
  static constexpr unsigned FPS_MAX_RETRY = 2;

  void request_fps(uint32_t fps) {
    if (!cam_i2c_ok()) {
      fps_pending_ = true;
      std::printf(
          "[gvcp] frame rate of %u fps deferred "
          "(source select 0x%X selects the test pattern, so the camera is not reachable; it will be applied when the camera is selected again)\n",
          fps, src_sel_cur_);
      return;
    }
    fps_pending_ = false;
    enqueue_fps(fps);
  }
  void enqueue_fps(uint32_t fps) {
    if (!fps_worker_started_) {
      fps_worker_started_ = true;
      fps_th_ = std::thread([this] { fps_worker_loop(); });
    }
    {
      std::lock_guard<std::mutex> lk(fps_mtx_);
      fps_req_ = fps;
      fps_req_valid_ = true;
    }
    fps_cv_.notify_one();
    std::printf("[gvcp] frame rate of %u fps requested (applied asynchronously; the acknowledgement is not delayed)\n", fps);
  }

  void fps_worker_loop() {
    unsigned retries = 0;
    std::unique_lock<std::mutex> lk(fps_mtx_);
    for (;;) {
      fps_cv_.wait(lk, [this] { return fps_stop_ || fps_req_valid_; });
      if (fps_stop_) return;
      const uint32_t fps = fps_req_;
      fps_req_valid_ = false;
      if (fps == fps_applied_) continue;
      lk.unlock();
      const bool ok = apply_fps_blocking(fps);
      lk.lock();
      if (ok) {
        fps_applied_ = fps;
        retries = 0;
      } else if (fps_req_valid_) {
        retries = 0;
      }
      else if (retries < FPS_MAX_RETRY) {
        ++retries;
        fps_req_ = fps;
        fps_req_valid_ = true;
        std::printf("[gvcp] WARN: i2c write for %u fps failed, scheduling retry %u/%u\n", fps,
                    retries, FPS_MAX_RETRY);
      } else {
        retries = 0;
        std::printf("[gvcp] ERROR: could not apply a frame rate of %u fps to the camera. "
                    "The value read back may be a stale mirror rather than the device state"
                    " (setting it again from the client retries)\n",
                    fps);
      }
      if (fps_cv_.wait_for(lk, std::chrono::milliseconds(FPS_COOLDOWN_MS), [this] { return fps_stop_; }))
        return;
    }
  }

  bool apply_fps_blocking(uint32_t fps) {
    auto sleep_ms = [](unsigned ms) { ::usleep(ms * 1000u); };
    if (!ap1302_set_streaming(cam_, false, sleep_ms)) {
      std::printf("[gvcp] could not stall the AP1302 (before writing MAX_FPS)\n");
      return false;
    }
    bool ok = cam_.wr16(Ap1302I2c::R_MAX_FPS, (uint16_t)(fps * 256u));
    ::usleep(20000);
    ok = ap1302_set_streaming(cam_, true, sleep_ms) && ok;
    uint16_t rb = 0;
    cam_.rd16(Ap1302I2c::R_SYS_START, rb);
    if (!ok) {
      std::printf("[gvcp] the AP1302 does not start streaming (SYS_START=0x%04X)\n", rb);
      return false;
    }
    std::printf("[gvcp] frame rate of %u fps applied (MAX_FPS=0x%04X, SYS_START=0x%04X)\n", fps,
                fps * 256u, rb);
    return true;
  }

  void stop_fps_worker() {
    if (!fps_worker_started_) return;
    {
      std::lock_guard<std::mutex> lk(fps_mtx_);
      fps_stop_ = true;
    }
    fps_cv_.notify_all();
    if (fps_th_.joinable()) fps_th_.join();
    fps_worker_started_ = false;
  }
  std::thread fps_th_;
  std::mutex fps_mtx_;
  std::condition_variable fps_cv_;
  bool fps_worker_started_ = false;
  bool fps_stop_ = false;
  bool fps_req_valid_ = false;
  uint32_t fps_req_ = 0;
  uint32_t fps_applied_ = 0;
  uint32_t ae_other_bits_ = 0x029C;
  uint32_t flip_other_bits_ = 0x0000;
  uint32_t pixfmt_cur_ = PFNC_MONO8;
  bool leader_fix_ =
      false;
  static uint32_t bpp_of(uint32_t pfnc) { return pfnc == 0x02180014u ? 3u : 1u; }
  uint64_t last_ctrl_ms_ = 0;
  int fd_ = -1;
  std::atomic<bool> streaming_{false}, stop_{false};
  std::thread th_;
  std::string stream_ip_;
  uint16_t stream_port_ = 0;
  uint32_t stream_payload_ = ps_default::PAYLOAD_SIZE;

  static constexpr size_t RESEND_BATCH_MAX = 64;

  void resend_packets(uint16_t bid, uint32_t first, uint32_t last) {
    if (stream_ip_.empty() || !stream_port_) return;
    ResendIndex::Hit h;
    {
      std::lock_guard<std::mutex> lk(ri_mtx_);
      h = ri_.lookup(bid, ff_send_pos_, FF_RETAIN_SLOTS);
    }
    if (!h.ok) {
      std::printf("[gvcp] resend MISS block %u pkts %u..%u (not in ring retention window)\n", bid, first,
                  last);
      return;
    }
    if (h.npkts == 0) return;
    if (h.npkts > FF_RETAIN_SLOTS) {
      std::printf("[gvcp] rejecting resend for block %u: %u packets exceeds the retained window of %u\n", bid,
                  h.npkts, FF_RETAIN_SLOTS);
      return;
    }
    if (last > h.npkts - 1) last = h.npkts - 1;
    if (first > last) return;
    const uint8_t* base = ring_.bytes();
    const uint8_t* r_hdr[RESEND_BATCH_MAX];
    uint32_t r_len[RESEND_BATCH_MAX];
    uint32_t sent = 0, staged = 0, pid = first;
    while (pid <= last) {
      {
        const uint32_t n_batch = (uint32_t)std::min<uint64_t>(RESEND_BATCH_MAX, (uint64_t)last - pid + 1);
        const uint32_t s0 = ri_.slot_for(h.base_slot, pid);
        const uint32_t head = std::min(n_batch, FF_NUM_SLOTS - s0);
        ring_.sync_for_cpu((uint64_t)s0 * FF_SLOT_SIZE, (uint64_t)head * FF_SLOT_SIZE);
        if (head < n_batch)
          ring_.sync_for_cpu(0, (uint64_t)(n_batch - head) * FF_SLOT_SIZE);
      }
      int m = 0;
      for (; pid <= last && (size_t)m < RESEND_BATCH_MAX; ++pid) {
        uint32_t slot = ri_.slot_for(h.base_slot, pid);
        const uint8_t* f = base + (uint64_t)slot * FF_SLOT_SIZE;
        int fl = frame_len_of(f);
        if (fl < 0) continue;
        r_hdr[m] = f;
        r_len[m] = (uint32_t)fl;
        ++m;
        ++staged;
      }
      if (m > 0) {
        int s = ff_raw_.send_batch_verbatim(r_hdr, r_len, (size_t)m);
        if (s > 0) sent += (uint32_t)s;
      }
    }
    std::printf("[gvcp] resend block %u pkts %u..%u (%u/%u sent, ring-verbatim)\n", bid, first, last, sent,
                staged);
  }
#endif
};

#if defined(__linux__)
inline void GvcpServer::build_xml() {
  static_assert(GVBS_SCPS0 == 0x0D04 && GVBS_SCPS_FIRE_TEST == 0x80000000u,
                "the XML GevSCPSFireTestPacket points at the top bit of SCPS (BigEndian bit 0)");
  char b[16384];
  int w = 0;
  w += std::snprintf(
      b + w, sizeof(b) - w,
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      "<RegisterDescription ModelName=\"KV260_GigE_PoC\" VendorName=\"gcam1g\""
      " StandardNameSpace=\"None\" SchemaMajorVersion=\"1\" SchemaMinorVersion=\"1\" "
      "SchemaSubMinorVersion=\"0\""
      " MajorVersion=\"1\" MinorVersion=\"0\" SubMinorVersion=\"0\""
      " ProductGuid=\"9A6C1B20-2F3D-4E5A-8B7C-1D2E3F405162\" "
      "VersionGuid=\"00000001-0000-0000-0000-000000000001\""
      " xmlns=\"http://www.genicam.org/GenApi/Version_1_1\" "
      "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
      " xsi:schemaLocation=\"http://www.genicam.org/GenApi/Version_1_1"
      " http://www.genicam.org/GenApi/GenApiSchema_Version_1_1.xsd\">\n"
      "<Category Name=\"Root\" NameSpace=\"Standard\">"
      "<pFeature>DeviceVendorName</pFeature><pFeature>DeviceModelName</pFeature><pFeature>DeviceVersion</"
      "pFeature>"
      "<pFeature>Width</pFeature><pFeature>Height</pFeature><pFeature>PixelFormat</pFeature>"
      "<pFeature>PayloadSize</pFeature><pFeature>AcquisitionMode</pFeature><pFeature>TestPattern</pFeature>"
      "<pFeature>LightSourcePreset</pFeature><pFeature>ExposureBiasEV</pFeature>"
      "<pFeature>Brightness</pFeature><pFeature>Saturation</pFeature><pFeature>Gamma</pFeature>"
      "<pFeature>ExposureAuto</pFeature><pFeature>ExposureTime</pFeature><pFeature>Gain</pFeature>"
      "<pFeature>Sharpness</pFeature><pFeature>ReverseX</pFeature><pFeature>ReverseY</pFeature>"
      "<pFeature>AcquisitionFrameRate</pFeature>"
      "<pFeature>AcquisitionStart</pFeature><pFeature>AcquisitionStop</pFeature></Category>\n"
      "<StringReg Name=\"DeviceVendorName\" NameSpace=\"Standard\"><Address>0x48</Address><Length>32</Length>"
      "<AccessMode>RO</AccessMode><pPort>Device</pPort></StringReg>\n"
      "<StringReg Name=\"DeviceModelName\" NameSpace=\"Standard\"><Address>0x68</Address><Length>32</Length>"
      "<AccessMode>RO</AccessMode><pPort>Device</pPort></StringReg>\n"
      "<StringReg Name=\"DeviceVersion\" NameSpace=\"Standard\"><Address>0x88</Address><Length>32</Length>"
      "<AccessMode>RO</AccessMode><pPort>Device</pPort></StringReg>\n"
      "<Integer Name=\"Width\" NameSpace=\"Standard\"><Value>%u</Value><Min>%u</Min><Max>%u</Max><Inc>1</Inc>"
      "<Representation>Linear</Representation></Integer>\n"
      "<Integer Name=\"Height\" "
      "NameSpace=\"Standard\"><Value>%u</Value><Min>%u</Min><Max>%u</Max><Inc>1</Inc>"
      "<Representation>Linear</Representation></Integer>\n"
      "<Enumeration Name=\"PixelFormat\" NameSpace=\"Standard\">"
      "<EnumEntry Name=\"Mono8\" "
      "NameSpace=\"Standard\"><Value>17301505</Value><Symbolic>Mono8</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"RGB8\" "
      "NameSpace=\"Standard\"><Value>35127316</Value><Symbolic>RGB8</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"BayerRG8\" "
      "NameSpace=\"Standard\"><Value>17301513</Value><Symbolic>BayerRG8</Symbolic></EnumEntry>"
      "<pValue>CtrlPixelFormat</pValue></Enumeration>\n"
      "<IntReg "
      "Name=\"CtrlPixelFormat\"><Address>0x10008</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Integer Name=\"PayloadSize\" "
      "NameSpace=\"Standard\"><pValue>CtrlPayloadSize</pValue>"
      "<Representation>Linear</Representation></Integer>\n"
      "<IntReg "
      "Name=\"CtrlPayloadSize\"><Address>0x1000C</Address><Length>4</Length><AccessMode>RO</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Enumeration Name=\"AcquisitionMode\" NameSpace=\"Standard\">"
      "<EnumEntry Name=\"Continuous\" "
      "NameSpace=\"Standard\"><Value>2</Value><Symbolic>Continuous</Symbolic></EnumEntry>"
      "<pValue>CtrlAcquisitionMode</pValue></Enumeration>\n"
      "<IntReg "
      "Name=\"CtrlAcquisitionMode\"><Address>0x10010</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Integer Name=\"TLParamsLocked\" "
      "NameSpace=\"Standard\"><pValue>CtrlTLParamsLocked</pValue><Min>0</Min><Max>1</Max><Inc>1</Inc></"
      "Integer>\n"
      "<IntReg "
      "Name=\"CtrlTLParamsLocked\"><Address>0x1001C</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Integer Name=\"AcquisitionFrameRate\" NameSpace=\"Custom\">"
      "<ToolTip>Frame rate in frames per second. 18 is the limit of a 1 Gb link. A change made during acquisition takes effect at the next start.</ToolTip>"
      "<pValue>CtrlAcqFrameRate</pValue>"
      "<Min>1</Min><Max>18</Max><Inc>1</Inc><Unit>Hz</Unit><Representation>Linear</Representation></"
      "Integer>\n"
      "<IntReg "
      "Name=\"CtrlAcqFrameRate\"><Address>0x10050</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Enumeration Name=\"ExposureAuto\" NameSpace=\"Standard\">"
      "<EnumEntry Name=\"Off\" NameSpace=\"Standard\"><Value>0</Value><Symbolic>Off</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"Continuous\" "
      "NameSpace=\"Standard\"><Value>1</Value><Symbolic>Continuous</Symbolic></EnumEntry>"
      "<pValue>CtrlExposureAuto</pValue></Enumeration>\n"
      "<IntReg "
      "Name=\"CtrlExposureAuto\"><Address>0x1003C</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Integer Name=\"ExposureTime\" NameSpace=\"Custom\">"
      "<ToolTip>Exposure time in microseconds. Only has an effect when ExposureAuto is Off.</ToolTip>"
      "<pValue>CtrlExposureTime</pValue>"
      "<Min>100</Min><Max>50000</Max><Inc>100</Inc><Unit>us</Unit><Representation>Linear</Representation></"
      "Integer>\n"
      "<IntReg "
      "Name=\"CtrlExposureTime\"><Address>0x10038</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Integer Name=\"Gain\" NameSpace=\"Custom\">"
      "<ToolTip>Raw gain value. Only has an effect when ExposureAuto is Off. The mapping to physical units is not characterised.</ToolTip>"
      "<pValue>CtrlGain</pValue>"
      "<Min>0</Min><Max>65535</Max><Inc>256</Inc><Representation>Linear</Representation></Integer>\n"
      "<IntReg Name=\"CtrlGain\"><Address>0x10040</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Integer Name=\"Sharpness\" NameSpace=\"Custom\">"
      "<ToolTip>Sharpening. 0 disables it, which is the default.</ToolTip>"
      "<pValue>CtrlSharpness</pValue>"
      "<Min>0</Min><Max>16384</Max><Inc>256</Inc><Representation>Linear</Representation></Integer>\n"
      "<IntReg Name=\"CtrlSharpness\"><Address>0x1004C</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Boolean Name=\"ReverseX\" NameSpace=\"Standard\">"
      "<ToolTip>Mirror horizontally.</ToolTip><pValue>CtrlReverseX</pValue><OnValue>1</OnValue><OffValue>0</OffValue></"
      "Boolean>\n"
      "<IntReg Name=\"CtrlReverseX\"><Address>0x10044</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Boolean Name=\"ReverseY\" NameSpace=\"Standard\">"
      "<ToolTip>Mirror vertically.</ToolTip><pValue>CtrlReverseY</pValue><OnValue>1</OnValue><OffValue>0</OffValue></"
      "Boolean>\n"
      "<IntReg Name=\"CtrlReverseY\"><Address>0x10048</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Enumeration Name=\"LightSourcePreset\" NameSpace=\"Custom\">"
      "<EnumEntry Name=\"Tungsten2800K\" "
      "NameSpace=\"Custom\"><Value>2</Value><Symbolic>Tungsten2800K</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"Fluorescent\" "
      "NameSpace=\"Custom\"><Value>3</Value><Symbolic>Fluorescent</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"Daylight5000K\" "
      "NameSpace=\"Custom\"><Value>4</Value><Symbolic>Daylight5000K</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"Daylight6500K\" "
      "NameSpace=\"Custom\"><Value>5</Value><Symbolic>Daylight6500K</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"Daylight7500K\" "
      "NameSpace=\"Custom\"><Value>6</Value><Symbolic>Daylight7500K</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"Auto\" NameSpace=\"Custom\"><Value>15</Value><Symbolic>Auto</Symbolic></EnumEntry>"
      "<pValue>CtrlLightSource</pValue></Enumeration>\n"
      "<IntReg "
      "Name=\"CtrlLightSource\"><Address>0x10034</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Integer Name=\"ExposureBiasEV\" NameSpace=\"Custom\">"
      "<ToolTip>Exposure compensation for auto exposure. 256 is one stop, in signed Q8.8.</ToolTip>"
      "<pValue>CtrlExposureBias</pValue>"
      "<Min>-768</Min><Max>768</Max><Inc>16</Inc><Representation>Linear</Representation></Integer>\n"
      "<IntReg "
      "Name=\"CtrlExposureBias\"><Address>0x10030</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Signed</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Integer Name=\"Brightness\" NameSpace=\"Custom\">"
      "<ToolTip>Brightness offset added to the image. 16 raises the level by one.</ToolTip>"
      "<pValue>CtrlBrightness</pValue>"
      "<Min>-2048</Min><Max>2048</Max><Inc>16</Inc><Representation>Linear</Representation></Integer>\n"
      "<IntReg "
      "Name=\"CtrlBrightness\"><Address>0x10024</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Signed</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Integer Name=\"Saturation\" NameSpace=\"Custom\">"
      "<ToolTip>Saturation multiplier, in Q4.12. 4096 is unity.</ToolTip>"
      "<pValue>CtrlSaturation</pValue>"
      "<Min>0</Min><Max>8192</Max><Inc>256</Inc><Representation>Linear</Representation></Integer>\n"
      "<IntReg "
      "Name=\"CtrlSaturation\"><Address>0x10028</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Integer Name=\"Gamma\" NameSpace=\"Custom\">"
      "<ToolTip>0 selects the automatic curve, which is the default. A non-zero value is a gamma in Q4.12, where 4096 is unity.</ToolTip>"
      "<pValue>CtrlGamma</pValue>"
      "<Min>0</Min><Max>16384</Max><Inc>256</Inc><Representation>Linear</Representation></Integer>\n"
      "<IntReg Name=\"CtrlGamma\"><Address>0x1002C</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Enumeration Name=\"TestPattern\" NameSpace=\"Standard\">"
      "<ToolTip>Off selects the camera, any other value selects a test pattern generated in the fabric. A change made during acquisition takes effect after a stop and start."
      "</ToolTip>"

      "<EnumEntry Name=\"Off\" NameSpace=\"Standard\"><Value>0</Value><Symbolic>Off</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"Black\" "
      "NameSpace=\"Standard\"><Value>1</Value><Symbolic>Black</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"White\" "
      "NameSpace=\"Standard\"><Value>2</Value><Symbolic>White</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"GreyHorizontalRamp\" "
      "NameSpace=\"Standard\"><Value>3</Value><Symbolic>GreyHorizontalRamp</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"GreyVerticalRamp\" "
      "NameSpace=\"Standard\"><Value>4</Value><Symbolic>GreyVerticalRamp</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"GreyHorizontalRampMoving\" "
      "NameSpace=\"Standard\"><Value>5</Value><Symbolic>GreyHorizontalRampMoving</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"GreyVerticalRampMoving\" "
      "NameSpace=\"Standard\"><Value>6</Value><Symbolic>GreyVerticalRampMoving</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"HorizontalLineMoving\" "
      "NameSpace=\"Standard\"><Value>7</Value><Symbolic>HorizontalLineMoving</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"VerticalLineMoving\" "
      "NameSpace=\"Standard\"><Value>8</Value><Symbolic>VerticalLineMoving</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"ColorBar\" "
      "NameSpace=\"Standard\"><Value>9</Value><Symbolic>ColorBar</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"FrameCounter\" "
      "NameSpace=\"Standard\"><Value>10</Value><Symbolic>FrameCounter</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"SensorBayerSim\" "
      "NameSpace=\"Custom\"><Value>11</Value><Symbolic>SensorBayerSim</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"Random\" "
      "NameSpace=\"Custom\"><Value>12</Value><Symbolic>Random</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"CrossHatch\" "
      "NameSpace=\"Custom\"><Value>13</Value><Symbolic>CrossHatch</Symbolic></EnumEntry>"
      "<EnumEntry Name=\"Diagonal\" "
      "NameSpace=\"Custom\"><Value>14</Value><Symbolic>Diagonal</Symbolic></EnumEntry>"
      "<pValue>CtrlTestPattern</pValue></Enumeration>\n"
      "<IntReg "
      "Name=\"CtrlTestPattern\"><Address>0x10020</Address><Length>4</Length><AccessMode>RW</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Command Name=\"AcquisitionStart\" "
      "NameSpace=\"Standard\"><pValue>CtrlAcquisitionStart</pValue><CommandValue>1</CommandValue></Command>\n"
      "<IntReg "
      "Name=\"CtrlAcquisitionStart\"><Address>0x10014</Address><Length>4</Length><AccessMode>WO</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Command Name=\"AcquisitionStop\" "
      "NameSpace=\"Standard\"><pValue>CtrlAcquisitionStop</pValue><CommandValue>1</CommandValue></Command>\n"
      "<IntReg "
      "Name=\"CtrlAcquisitionStop\"><Address>0x10018</Address><Length>4</Length><AccessMode>WO</AccessMode>"
      "<pPort>Device</pPort><Sign>Unsigned</Sign><Endianess>BigEndian</Endianess></IntReg>\n"
      "<Boolean Name=\"GevSCPSFireTestPacket\" NameSpace=\"Standard\"><pValue>CtrlSCPSFireTestPacket</pValue>"
      "<OnValue>1</OnValue><OffValue>0</OffValue></Boolean>\n"
      "<MaskedIntReg Name=\"CtrlSCPSFireTestPacket\"><Address>0x0D04</Address><Length>4</Length>"
      "<AccessMode>RW</AccessMode><pPort>Device</pPort><Bit>0</Bit><Sign>Unsigned</Sign>"
      "<Endianess>BigEndian</Endianess></MaskedIntReg>\n"
      "<Port Name=\"Device\"/>\n"
      "</RegisterDescription>\n",
      width_, width_, width_, height_, height_, height_);
  if (w < 0 || (size_t)w >= sizeof(b)) {
    std::printf("[gvcp] FATAL: the feature description was truncated (%d bytes needed, buffer is %zu). "
                "Enlarge the buffer in build_xml()\n",
                w, sizeof(b));
    std::abort();
  }
  xml_.assign(b, (size_t)w);
}
#endif

}
