#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# File:        dt.sh
# Description: Compiles the device tree overlays: one loads the bitstream, the
#              other attaches the camera to the i2c bus in the fabric.
# -----------------------------------------------------------------------------

set -e -u -o pipefail

GCAM=${GCAM_ROOT:?run via ./build.sh}
OUT=$GCAM/output
mkdir -p "$OUT"

command -v dtc >/dev/null 2>&1 || {
  echo "dtc not found. Debian/Ubuntu: sudo apt install device-tree-compiler" >&2
  exit 1; }

dtc -@ -O dtb -o "$OUT/kv260_gige.dtbo"  "$GCAM/fpga/dt/pl.dtsi"
dtc -@ -O dtb -o "$OUT/cam_overlay.dtbo" "$GCAM/fpga/dt/cam_overlay.dts"
for f in kv260_gige.dtbo cam_overlay.dtbo; do
  echo "  $f  $(stat -c%s "$OUT/$f") bytes"
done
echo "DT_BUILD_DONE"
