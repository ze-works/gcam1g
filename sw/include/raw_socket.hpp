// -----------------------------------------------------------------------------
// File:        raw_socket.hpp
// Description: Layer 2 packet sender used for the image stream. The kernel UDP
//              path caps throughput well below line rate on this controller, so
//              the frames built by the fabric are injected directly onto the
//              interface instead.
// -----------------------------------------------------------------------------

#pragma once
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#if defined(__linux__)
#include <arpa/inet.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <linux/if_packet.h>
#include <linux/if_ether.h>
#include <netinet/in.h>
#include <unistd.h>
#include <time.h>
#endif
namespace kv260gige {

class RawSender {
public:
#if defined(__linux__)
  void close_fd() {
    if (fd_ >= 0) {
      ::close(fd_);
      fd_ = -1;
    }
  }
#endif

  bool open(const std::string& dst_ip, uint16_t dst_port, const std::string& src_ip, uint16_t src_port,
            const std::string& ifname) {
#if defined(__linux__)
    close_fd();
    ok_ = false;
    fd_ = ::socket(AF_PACKET, SOCK_RAW, htons(ETH_P_IP));
    if (fd_ < 0) {
      std::perror("[raw] socket(AF_PACKET)");
      return false;
    }
    struct ifreq ifr{};
    std::strncpy(ifr.ifr_name, ifname.c_str(), IFNAMSIZ - 1);
    if (::ioctl(fd_, SIOCGIFINDEX, &ifr) < 0) {
      std::perror("[raw] SIOCGIFINDEX");
      close_fd();
      return false;
    }
    ifindex_ = ifr.ifr_ifindex;
    if (::ioctl(fd_, SIOCGIFHWADDR, &ifr) < 0) {
      std::perror("[raw] SIOCGIFHWADDR");
      close_fd();
      return false;
    }
    std::memcpy(src_mac_, ifr.ifr_hwaddr.sa_data, 6);
    if (!resolve_mac(dst_ip, ifname, dst_mac_)) {
      std::printf("[raw] could not resolve MAC for %s on %s\n", dst_ip.c_str(), ifname.c_str());
      {
        close_fd();
        return false;
      }
    }
    struct sockaddr_ll sll{};
    sll.sll_family = AF_PACKET;
    sll.sll_protocol = htons(ETH_P_IP);
    sll.sll_ifindex = ifindex_;
    if (::bind(fd_, reinterpret_cast<sockaddr*>(&sll), sizeof(sll)) < 0) {
      std::perror("[raw] bind");
      close_fd();
      return false;
    }
#ifdef PACKET_QDISC_BYPASS
    if (std::getenv("GVSP_QDISC_BYPASS")) {
      int one = 1;
      ::setsockopt(fd_, SOL_PACKET, PACKET_QDISC_BYPASS, &one, sizeof(one));
    }
#endif
    int snd = 8 * 1024 * 1024;
    ::setsockopt(fd_, SOL_SOCKET, SO_SNDBUF, &snd, sizeof(snd));
    src_ip_ = inaddr(src_ip);
    dst_ip_ = inaddr(dst_ip);
    sport_ = src_port;
    dport_ = dst_port;
    txaddr_.sll_family = AF_PACKET;
    txaddr_.sll_protocol = htons(ETH_P_IP);
    txaddr_.sll_ifindex = ifindex_;
    txaddr_.sll_halen = 6;
    std::memcpy(txaddr_.sll_addr, dst_mac_, 6);
    ok_ = true;
    std::printf("[raw] AF_PACKET TX ready: %s -> %s  src_mac %02x:%02x:%02x:%02x:%02x:%02x "
                "dst_mac %02x:%02x:%02x:%02x:%02x:%02x  ports %u->%u  if=%s(%d)\n",
                src_ip.c_str(), dst_ip.c_str(), src_mac_[0], src_mac_[1], src_mac_[2], src_mac_[3],
                src_mac_[4], src_mac_[5], dst_mac_[0], dst_mac_[1], dst_mac_[2], dst_mac_[3], dst_mac_[4],
                dst_mac_[5], sport_, dport_, ifname.c_str(), ifindex_);
    return true;
#else
    (void)dst_ip;
    (void)dst_port;
    (void)src_ip;
    (void)src_port;
    (void)ifname;
    return false;
#endif
  }

  int send_batch(const std::vector<uint8_t>* pkts, size_t n) {
#if defined(__linux__)
    if (fd_ < 0) return -1;
    constexpr size_t MAX = 64;
    if (n > MAX) n = MAX;
    struct mmsghdr msgs[MAX];
    struct iovec iov[MAX * 2];
    for (size_t i = 0; i < n; ++i) {
      uint8_t* h = hdr_[i].b;
      build_headers(h, pkts[i].size());
      iov[2 * i].iov_base = h;
      iov[2 * i].iov_len = 42;
      iov[2 * i + 1].iov_base = const_cast<uint8_t*>(pkts[i].data());
      iov[2 * i + 1].iov_len = pkts[i].size();
      std::memset(&msgs[i].msg_hdr, 0, sizeof(msgs[i].msg_hdr));
      msgs[i].msg_hdr.msg_name = &txaddr_;
      msgs[i].msg_hdr.msg_namelen = sizeof(txaddr_);
      msgs[i].msg_hdr.msg_iov = &iov[2 * i];
      msgs[i].msg_hdr.msg_iovlen = 2;
      msgs[i].msg_len = 0;
    }
    return ::sendmmsg(fd_, msgs, (unsigned)n, 0);
#else
    (void)pkts;
    (void)n;
    return -1;
#endif
  }
  int send_batch_verbatim(const uint8_t* const* frame, const uint32_t* len, size_t n) {
#if defined(__linux__)
    if (fd_ < 0) return -1;
    constexpr size_t MAX = 64;
    if (n > MAX) n = MAX;
    struct mmsghdr msgs[MAX];
    struct iovec iov[MAX];
    for (size_t i = 0; i < n; ++i) {
      iov[i].iov_base = const_cast<uint8_t*>(frame[i]);
      iov[i].iov_len = len[i];
      std::memset(&msgs[i].msg_hdr, 0, sizeof(msgs[i].msg_hdr));
      msgs[i].msg_hdr.msg_name = &txaddr_;
      msgs[i].msg_hdr.msg_namelen = sizeof(txaddr_);
      msgs[i].msg_hdr.msg_iov = &iov[i];
      msgs[i].msg_hdr.msg_iovlen = 1;
      msgs[i].msg_len = 0;
    }
    return ::sendmmsg(fd_, msgs, (unsigned)n, 0);
#else
    (void)frame;
    (void)len;
    (void)n;
    return -1;
#endif
  }
  const uint8_t* src_mac() const { return src_mac_; }
  const uint8_t* dst_mac() const { return dst_mac_; }
  bool ready() const { return ok_; }
  ~RawSender() {
#if defined(__linux__)
    if (fd_ >= 0) ::close(fd_);
#endif
  }

private:
#if defined(__linux__)
  static uint32_t inaddr(const std::string& ip) {
    in_addr a{};
    ::inet_pton(AF_INET, ip.c_str(), &a);
    return a.s_addr;
  }
  static uint16_t ipcksum(const uint8_t* h) {
    uint32_t s = 0;
    for (int i = 0; i < 20; i += 2) s += (uint16_t)((h[i] << 8) | h[i + 1]);
    while (s >> 16) s = (s & 0xFFFF) + (s >> 16);
    return (uint16_t)~s;
  }
  void build_headers(uint8_t* f, size_t plen) {
    std::memcpy(f, dst_mac_, 6);
    std::memcpy(f + 6, src_mac_, 6);
    f[12] = 0x08;
    f[13] = 0x00;
    uint8_t* ip = f + 14;
    const uint16_t tot = (uint16_t)(20 + 8 + plen);
    ip[0] = 0x45;
    ip[1] = 0x00;
    ip[2] = tot >> 8;
    ip[3] = tot & 0xFF;
    ip[4] = ipid_ >> 8;
    ip[5] = ipid_ & 0xFF;
    ipid_++;
    ip[6] = 0x40;
    ip[7] = 0x00;
    ip[8] = 64;
    ip[9] = 17;
    ip[10] = 0;
    ip[11] = 0;
    std::memcpy(ip + 12, &src_ip_, 4);
    std::memcpy(ip + 16, &dst_ip_, 4);
    uint16_t c = ipcksum(ip);
    ip[10] = c >> 8;
    ip[11] = c & 0xFF;
    uint8_t* ud = f + 34;
    const uint16_t ul = (uint16_t)(8 + plen);
    ud[0] = sport_ >> 8;
    ud[1] = sport_ & 0xFF;
    ud[2] = dport_ >> 8;
    ud[3] = dport_ & 0xFF;
    ud[4] = ul >> 8;
    ud[5] = ul & 0xFF;
    ud[6] = 0;
    ud[7] = 0;
  }
  bool resolve_mac(const std::string& ip, const std::string& ifname, uint8_t out[6]) {
    if (arp_lookup(ip, ifname, out)) return true;
    int k = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (k >= 0) {
      sockaddr_in d{};
      d.sin_family = AF_INET;
      d.sin_port = htons(9);
      d.sin_addr.s_addr = inaddr(ip);
      char z = 0;
      ::sendto(k, &z, 1, 0, reinterpret_cast<sockaddr*>(&d), sizeof(d));
      ::close(k);
    }
    const char* e = std::getenv("GVSP_ARP_MS");
    const long budget_ms = e ? std::strtol(e, nullptr, 0) : 400;
    const long step_ms = 5;
    for (long waited = 0; waited < budget_ms; waited += step_ms) {
      struct timespec ts{0, step_ms * 1000 * 1000};
      ::nanosleep(&ts, nullptr);
      if (arp_lookup(ip, ifname, out)) {
        if (waited >= 50) std::printf("[raw] address resolution took %ld ms (%s)\n", waited, ip.c_str());
        return true;
      }
    }
    std::printf("[raw] address resolution did not complete within %ld ms (%s). Raise GVSP_ARP_MS to wait longer\n", budget_ms, ip.c_str());
    return false;
  }
  static bool arp_lookup(const std::string& ip, const std::string& ifname, uint8_t out[6]) {
    FILE* fp = ::fopen("/proc/net/arp", "r");
    if (!fp) return false;
    char line[256];
    bool found = false;
    (void)::fgets(line, sizeof(line), fp);
    while (::fgets(line, sizeof(line), fp)) {
      char aip[64], hw[64], mask[64], dev[64];
      unsigned htype, flags;
      if (std::sscanf(line, "%63s 0x%x 0x%x %63s %63s %63s", aip, &htype, &flags, hw, mask, dev) == 6) {
        if (ip == aip && ifname == dev && (flags & 0x2)) {
          unsigned m[6];
          if (std::sscanf(hw, "%x:%x:%x:%x:%x:%x", &m[0], &m[1], &m[2], &m[3], &m[4], &m[5]) == 6) {
            for (int i = 0; i < 6; ++i) out[i] = (uint8_t)m[i];
            found = true;
            break;
          }
        }
      }
    }
    ::fclose(fp);
    return found;
  }
  int fd_ = -1, ifindex_ = 0;
  uint8_t src_mac_[6]{}, dst_mac_[6]{};
  uint32_t src_ip_ = 0, dst_ip_ = 0;
  uint16_t sport_ = 0, dport_ = 0, ipid_ = 0;
  struct sockaddr_ll txaddr_{};
  struct Hdr {
    uint8_t b[42];
  };
  Hdr hdr_[64]{};
#endif
  bool ok_ = false;
};
}
