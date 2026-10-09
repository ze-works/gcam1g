// -----------------------------------------------------------------------------
// File:        udmabuf.hpp
// Description: Cached DMA buffer obtained from the u-dma-buf kernel module. A
//              cacheable mapping is required: reading the ring through an
//              uncached mapping is roughly an order of magnitude slower and
//              faults on unaligned access.
// -----------------------------------------------------------------------------

#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <map>
#include <mutex>
#if defined(__linux__)
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#endif
namespace kv260gige {

class UdmaBuf {
public:
  UdmaBuf() = default;
  UdmaBuf(const UdmaBuf&) = delete;
  UdmaBuf& operator=(const UdmaBuf&) = delete;
  UdmaBuf(UdmaBuf&&) = delete;
  UdmaBuf& operator=(UdmaBuf&&) = delete;

  bool open(const std::string& dev = "udmabuf0") {
#if defined(__linux__)
    std::string sys = "/sys/class/u-dma-buf/" + dev + "/";
    if (!read_u64(sys + "phys_addr", phys_) || !read_u64(sys + "size", size_)) return false;
    fd_ = ::open(("/dev/" + dev).c_str(), O_RDWR);
    if (fd_ < 0) return false;
    map_ = ::mmap(nullptr, size_, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0);
    if (map_ == MAP_FAILED) {
      ::close(fd_);
      fd_ = -1;
      map_ = nullptr;
      return false;
    }
    write_str(sys + "sync_direction", "2");
    foff_ = ::open((sys + "sync_offset").c_str(), O_WRONLY);
    fsz_ = ::open((sys + "sync_size").c_str(), O_WRONLY);
    fcpu_ = ::open((sys + "sync_for_cpu").c_str(), O_WRONLY);
    mu_ = &dev_mutex(dev);
    ok_ = (foff_ >= 0 && fsz_ >= 0 && fcpu_ >= 0);
    return ok_;
#else
    (void)dev;
    return false;
#endif
  }
  bool ok() const { return ok_; }
  uint64_t phys() const { return phys_; }
  uint64_t size() const { return size_; }
  const uint8_t* bytes() const { return reinterpret_cast<const uint8_t*>(map_); }

  void sync_for_cpu(uint64_t offset, uint64_t len) {
#if defined(__linux__)
    if (!ok_ || !mu_) return;
    std::lock_guard<std::mutex> lk(*mu_);
    wr_dec(foff_, offset);
    wr_dec(fsz_, len);
    wr_dec(fcpu_, 1);
#else
    (void)offset;
    (void)len;
#endif
  }
  ~UdmaBuf() {
#if defined(__linux__)
    if (map_) ::munmap(map_, size_);
    for (int f : {fd_, foff_, fsz_, fcpu_})
      if (f >= 0) ::close(f);
#endif
  }

private:
#if defined(__linux__)
  static bool read_u64(const std::string& p, uint64_t& v) {
    FILE* f = ::fopen(p.c_str(), "r");
    if (!f) return false;
    unsigned long long t = 0;
    int n = std::fscanf(f, "%lli", &t);
    ::fclose(f);
    if (n != 1) return false;
    v = (uint64_t)t;
    return true;
  }
  static void write_str(const std::string& p, const char* s) {
    int f = ::open(p.c_str(), O_WRONLY);
    if (f >= 0) {
      (void)!::write(f, s, std::strlen(s));
      ::close(f);
    }
  }
  static void wr_dec(int fd, uint64_t v) {
    char b[24];
    int n = std::snprintf(b, sizeof(b), "%llu", (unsigned long long)v);
    (void)!::pwrite(fd, b, (size_t)n, 0);
  }
  static std::mutex& dev_mutex(const std::string& dev) {
    static std::mutex reg_mu;
    static std::map<std::string, std::mutex> reg;
    std::lock_guard<std::mutex> lk(reg_mu);
    return reg[dev];
  }
  void* map_ = nullptr;
  int fd_ = -1, foff_ = -1, fsz_ = -1, fcpu_ = -1;
  std::mutex* mu_ = nullptr;
#endif
  uint64_t phys_ = 0, size_ = 0;
  bool ok_ = false;
};
}
