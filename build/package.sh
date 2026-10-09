#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# File:        package.sh
# Description: Collects everything the board needs into one tarball, with the
#              licence texts and THIRD_PARTY.md. The archive records owner 0/0
#              and no user names.
# -----------------------------------------------------------------------------

set -e -u -o pipefail

GCAM=${GCAM_ROOT:?run via ./build.sh}
VER=${VERSION:?run via ./build.sh}
OUT=$GCAM/output
STAGE=$OUT/stage
DIST=$GCAM/dist

for f in kv260_gige.bit.bin kv260_gige.dtbo cam_overlay.dtbo gvsp_server; do
  [ -f "$OUT/$f" ] || { echo "missing $OUT/$f - run ./build.sh first" >&2; exit 1; }
done

rm -rf "$STAGE"; mkdir -p "$STAGE" "$DIST"
cp "$OUT"/kv260_gige.bit.bin "$OUT"/kv260_gige.dtbo "$OUT"/cam_overlay.dtbo \
   "$OUT"/gvsp_server "$STAGE/"
cp "$GCAM/board/shell.json" "$GCAM/board/install.sh" "$GCAM/board/run.sh" "$STAGE/"
mkdir -p "$STAGE/driver"
cp "$GCAM/sw/driver/u-dma-buf.c" "$GCAM/sw/driver/Makefile" "$GCAM/sw/driver/UDMABUF_BUILD.md" "$STAGE/driver/"
cp "$GCAM/LICENSE" "$GCAM/THIRD_PARTY.md" "$STAGE/"
cp "$GCAM/fpga/dt/cam_overlay.dts" "$STAGE/"
mkdir -p "$STAGE/licenses"
cp "$GCAM/licenses/GPL-2.0.txt" "$GCAM/licenses/LGPL-2.1.txt" "$STAGE/licenses/"
chmod +x "$STAGE/install.sh" "$STAGE/run.sh" "$STAGE/gvsp_server"

TAR=$DIST/gcam1g-kv260-$VER.tar.gz
tar --owner=0 --group=0 --numeric-owner --sort=name -cf - -C "$STAGE" . | gzip -9n > "$TAR"
echo "  $TAR  $(( $(stat -c%s "$TAR") / 1024 / 1024 )) MB"
tar -tzf "$TAR" | sed 's/^/    /'
echo "PACKAGE_DONE"
