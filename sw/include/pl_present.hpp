// -----------------------------------------------------------------------------
// File:        pl_present.hpp
// Description: Checks that this project's PL design is loaded before the
//              application touches its control registers, by looking for the
//              uio device that maps the register window.
// -----------------------------------------------------------------------------

#pragma once
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

namespace kv260gige {

inline bool pl_window_present(const std::string& uio_root, uint64_t addr) {
  namespace fs = std::filesystem;
  std::error_code ec;
  for (const auto& e : fs::directory_iterator(uio_root, ec)) {
    std::ifstream f(e.path() / "maps" / "map0" / "addr");
    std::string s;
    if (f >> s && std::strtoull(s.c_str(), nullptr, 16) == addr) return true;
  }
  return false;
}

}
