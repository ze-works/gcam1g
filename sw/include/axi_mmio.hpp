// -----------------------------------------------------------------------------
// File:        axi_mmio.hpp
// Description: Maps a physical register aperture for 32 bit access. Uses the
//              physical memory device, which needs root. A production driver
//              would use a kernel module or the userspace I/O interface
//              instead.
// -----------------------------------------------------------------------------

#pragma once
#include <cstdint>
#include <cstdio>
#include <cerrno>
#include <cstring>
#if defined(__linux__)
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#endif

namespace kv260gige {

class MmioWindow {
public:
  MmioWindow() = default;
  bool open(uint64_t phys_base, size_t size) {
#if defined(__linux__)
    base_phys_ = phys_base;
    size_ = size;
    fd_ = ::open("/dev/mem", O_RDWR | O_SYNC);
    if (fd_ < 0) {
      std::fprintf(stderr, "open(/dev/mem) failed: %s\n", std::strerror(errno));
      return false;
    }
    long ps = ::sysconf(_SC_PAGESIZE);
    uint64_t aligned = phys_base & ~((uint64_t)ps - 1);
    page_off_ = (size_t)(phys_base - aligned);
    map_len_ = page_off_ + size;
    map_ = ::mmap(nullptr, map_len_, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, (off_t)aligned);
    if (map_ == MAP_FAILED) {
      std::fprintf(stderr, "mmap(0x%llx) failed: %s\n", (unsigned long long)aligned, std::strerror(errno));
      ::close(fd_);
      fd_ = -1;
      map_ = nullptr;
      return false;
    }
    return true;
#else
    (void)phys_base;
    (void)size;
    std::fprintf(stderr, "MmioWindow: non-Linux build\n");
    return false;
#endif
  }
  bool ok() const { return map_ != nullptr; }
  const uint8_t* bytes() const {
    return reinterpret_cast<const uint8_t*>(static_cast<char*>(map_) + page_off_);
  }
  uint32_t rd(uint32_t off) const {
    return *reinterpret_cast<volatile uint32_t*>(static_cast<char*>(map_) + page_off_ + off);
  }
  void wr(uint32_t off, uint32_t val) {
    *reinterpret_cast<volatile uint32_t*>(static_cast<char*>(map_) + page_off_ + off) = val;
  }
  ~MmioWindow() {
#if defined(__linux__)
    if (map_) ::munmap(map_, map_len_);
    if (fd_ >= 0) ::close(fd_);
#endif
  }

private:
  void* map_ = nullptr;
  int fd_ = -1;
  size_t size_ = 0, page_off_ = 0, map_len_ = 0;
  uint64_t base_phys_ = 0;
};

}
