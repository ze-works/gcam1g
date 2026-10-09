#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# File:        build.sh
# Description: Top level build entry point. Builds the bitstream, the board
#              application, the device tree overlays and the release tarball; a
#              subcommand selects one of them.
# -----------------------------------------------------------------------------

set -u -o pipefail

export GCAM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export VERSION=v0.1.0

case "${1:-all}" in
  fpga)    bash "$GCAM_ROOT/build/fpga.sh" ;;
  sw)      bash "$GCAM_ROOT/build/sw.sh" ;;
  dt)      bash "$GCAM_ROOT/build/dt.sh" ;;
  package) bash "$GCAM_ROOT/build/package.sh" ;;
  clean)   rm -rf "$GCAM_ROOT/output" "$GCAM_ROOT/dist"; echo "cleaned" ;;
  all)     bash "$GCAM_ROOT/build/fpga.sh" \
        && bash "$GCAM_ROOT/build/sw.sh" \
        && bash "$GCAM_ROOT/build/dt.sh" \
        && bash "$GCAM_ROOT/build/package.sh" ;;
  *)       echo "usage: $0 [fpga|sw|dt|package|clean|all]" >&2; exit 2 ;;
esac
