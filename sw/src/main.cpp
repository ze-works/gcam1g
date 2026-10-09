// -----------------------------------------------------------------------------
// File:        main.cpp
// Description: Entry point for the board application. --serve runs the
//              control server and the stream forwarder; the fabric builds the
//              video packets, so the application never assembles them itself.
// -----------------------------------------------------------------------------

#include "gvcp_server.hpp"
#include <cstdio>
#include <string>

using namespace kv260gige;

static void usage(const char* a) {
  std::printf("usage: %s --serve --our-ip A.B.C.D\n"
              "  --serve            run the GVCP server (UDP control port) and the stream forwarder (root)\n"
              "  --our-ip A.B.C.D   address this device announces\n",
              a);
}

int main(int argc, char** argv) {
  bool do_serve = false;
  std::string our_ip;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--serve")
      do_serve = true;
    else if (a == "--our-ip" && i + 1 < argc)
      our_ip = argv[++i];
    else {
      usage(argv[0]);
      return 2;
    }
  }
  if (!do_serve || our_ip.empty()) {
    usage(argv[0]);
    return 2;
  }
  GvcpServer srv(our_ip);
  return srv.run();
}
