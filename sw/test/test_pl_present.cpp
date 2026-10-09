// -----------------------------------------------------------------------------
// File:        test_pl_present.cpp
// Description: Host test for pl_present.hpp, run against a fake sysfs tree.
// -----------------------------------------------------------------------------

#include "pl_present.hpp"
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>
namespace fs = std::filesystem;

#define CHECK(c) do { if (!(c)) { std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); std::exit(1); } } while (0)

static void make_uio(const fs::path& root, const char* name, const char* addr) {
  fs::path d = root / name / "maps" / "map0";
  fs::create_directories(d);
  std::ofstream(d / "addr") << addr << "\n";
}

int main() {
  fs::path root = fs::temp_directory_path() / ("pl_present_" + std::to_string(::getpid()));
  fs::remove_all(root);
  make_uio(root, "uio0", "0x00000000ffa00000");
  make_uio(root, "uio1", "0x00000000fd0b0000");
  CHECK(!kv260gige::pl_window_present(root.string(), 0xA0020000ull));
  make_uio(root, "uio4", "0x00000000a0020000");
  CHECK(kv260gige::pl_window_present(root.string(), 0xA0020000ull));
  CHECK(!kv260gige::pl_window_present((root / "nothing").string(), 0xA0020000ull));
  fs::remove_all(root);
  std::puts("TEST_PL_PRESENT_PASS");
  return 0;
}
