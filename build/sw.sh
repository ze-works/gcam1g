#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# File:        sw.sh
# Description: Builds the board application for aarch64 Linux, statically
#              linked so it does not depend on the libraries installed on the
#              board.
# -----------------------------------------------------------------------------

set -u -o pipefail

GCAM=${GCAM_ROOT:?run via ./build.sh}
SW=$GCAM/sw
OUT=$GCAM/output
mkdir -p "$OUT/hosttest"

if command -v g++ >/dev/null 2>&1; then
  for t in test_gvcp_bounds test_resend_index test_gvcp_protocol test_gvcp_ccp test_pl_present test_ap1302_stall; do
    g++ -std=c++17 -O1 -Wall -Wextra -I"$SW/include" \
        "$SW/test/$t.cpp" -o "$OUT/hosttest/$t" || exit 1
    "$OUT/hosttest/$t" || { echo "host test FAILED: $t"; exit 1; }
    echo "host test PASS: $t"
  done
else
  echo "no host g++ - skipping host unit tests"
fi

if command -v python3 >/dev/null 2>&1; then
  ( cd "$SW" && python3 tools/check_genicam_xml.py ) || exit 1
else
  echo "no python3 - skipping GenICam XML validation"
fi

CXX=${CROSS_CXX:-aarch64-linux-gnu-g++}
command -v "$CXX" >/dev/null 2>&1 || {
  echo "$CXX not found." >&2
  echo "  Debian/Ubuntu:  sudo apt install g++-aarch64-linux-gnu" >&2
  echo "  Or set CROSS_CXX to your cross compiler." >&2
  exit 1; }

"$CXX" -std=c++17 -O2 -static -Wall -Wextra -pthread \
  -I"$SW/include" "$SW/src/main.cpp" -o "$OUT/gvsp_server" || exit 1
echo "gvsp_server: $OUT/gvsp_server ($(stat -c%s "$OUT/gvsp_server") bytes)"
file "$OUT/gvsp_server" | sed 's/^/  /'
echo "SW_BUILD_DONE"
