#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# File:        fpga.sh
# Description: Packages the custom IPs, builds the block design and generates
#              the bitstream. Checks that Vivado and the board definition files
#              are present first, because a missing board definition otherwise
#              fails minutes into the build with an error that does not name
#              the cause.
# -----------------------------------------------------------------------------

set -u -o pipefail

GCAM=${GCAM_ROOT:?run via ./build.sh}
OUT=$GCAM/output/fpga
PART=xck26-sfvc784-2LV-c

VIV=${VIVADO_BIN:-/tools/Xilinx/Vivado/2024.2/bin}
if [ ! -x "$VIV/vivado" ]; then
  if command -v vivado >/dev/null 2>&1; then
    VIV=$(dirname "$(command -v vivado)")
  else
    echo "Vivado 2024.2 not found." >&2
    echo "  Set VIVADO_BIN=/path/to/Vivado/2024.2/bin, or put vivado on PATH." >&2
    exit 1
  fi
fi

for v in ETH_BYTES PKT_MHZ DATA_MHZ NUM_TAP GV_PPB; do
  [ -n "${!v:-}" ] && export "$v"
done

BOARD_ROOTS=()
[ -n "${XILINX_LOCAL_USER_DATA:-}" ] && BOARD_ROOTS+=("$XILINX_LOCAL_USER_DATA")
[ -n "${HOME:-}" ] && BOARD_ROOTS+=("$HOME/.Xilinx")
BOARD_ROOTS+=("$(dirname "$VIV")/data/xhub/boards")

find_board() {
  local root
  for root in "${BOARD_ROOTS[@]}"; do
    [ -d "$root" ] || continue
    find "$root" -type d -iname "$1" -print -quit 2>/dev/null | grep -q . && return 0
  done
  return 1
}

MISSING=""
find_board kv260_som     || MISSING="$MISSING kv260_som"
find_board kv260_carrier || MISSING="$MISSING kv260_carrier"
if [ -n "$MISSING" ]; then
  echo "KV260 board files not found:$MISSING" >&2
  echo "  fpga/scripts/build.tcl sets board_part/board_connections for the KV260" >&2
  echo "  SOM and carrier; those definitions ship separately from a bare Vivado" >&2
  echo "  install." >&2
  echo "  Install them: Vivado > Tools > Xilinx Board Store, search \"kv260\"," >&2
  echo "  install kv260_som and kv260_carrier. Or point XILINX_LOCAL_USER_DATA at" >&2
  echo "  a directory holding a downloaded board_files/ tree with those boards." >&2
  exit 1
fi

mkdir -p "$OUT"

rm -rf "$OUT/ip_repo"

echo "=== 1) package custom IPs ==="
VIVADO=$VIV/vivado bash "$GCAM/fpga/scripts/package_all.sh" \
  "$GCAM" "$OUT" "$PART" > "$OUT/package_all.log" 2>&1
pkg_rc=$?
tail -25 "$OUT/package_all.log"
[ "$pkg_rc" -ne 0 ] && { echo "PACKAGE FAILED (rc=$pkg_rc) - abort (see $OUT/package_all.log)"; exit 1; }

echo "=== 1b) packaged RTL vs repo RTL ==="
bad=0
while IFS= read -r f; do
  base=$(basename "$f")
  hits=$(find "$GCAM/rtl" -name "$base" 2>/dev/null | wc -l)
  if [ "$hits" -gt 1 ]; then
    echo "  AMBIGUOUS: $base matches $hits files under rtl/ - cannot tell which is canonical"
    bad=1; continue
  fi
  src=$(find "$GCAM/rtl" -name "$base" 2>/dev/null | head -1)
  [ -z "$src" ] && continue
  cmp -s "$f" "$src" || { echo "  MISMATCH: ${f#$OUT/ip_repo/} != ${src#$GCAM/}"; bad=1; }
done < <(find "$OUT/ip_repo" -name '*.sv' 2>/dev/null)
[ "$bad" = 1 ] && { echo "PACKAGED RTL MISMATCH - abort"; exit 1; }
echo "  match"

echo "=== 2) block design -> bitstream ==="
GCAM_ROOT="$GCAM" FULLFAB_OUT="$OUT" \
  "$VIV/vivado" -mode batch -nojournal -log "$OUT/build.log" \
  -source "$GCAM/fpga/scripts/build.tcl" > "$OUT/build.console" 2>&1
grep -E "BUILD_ROOT|BUILD_OUT|RUN_STATUS|FINAL_WNS|FINAL_WORST|FINAL_BIT|BUILD_ALL_DONE" \
  "$OUT/build.console"
BIT=$(ls "$OUT"/.fullfabz/fullfabz.runs/impl_1/*.bit 2>/dev/null | head -1)
[ -z "$BIT" ] && { echo "BUILD FAILED - see $OUT/build.console"; exit 1; }

echo "=== 3) bootgen ==="
mkdir -p "$GCAM/output"
cp "$BIT" "$OUT/kv260_gige.bit"
printf 'all:\n{\n  [destination_device = pl] kv260_gige.bit\n}\n' > "$OUT/kv260_gige.bif"
( cd "$OUT" && "$VIV/bootgen" -image kv260_gige.bif -arch zynqmp -o kv260_gige.bit.bin -w ) | tail -1
cp "$OUT/kv260_gige.bit.bin" "$GCAM/output/kv260_gige.bit.bin"
echo "bit.bin: $GCAM/output/kv260_gige.bit.bin ($(stat -c%s "$GCAM/output/kv260_gige.bit.bin") bytes)"
echo "FPGA_BUILD_DONE"
