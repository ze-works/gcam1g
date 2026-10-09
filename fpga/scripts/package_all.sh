#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# File:        package_all.sh
# Description: Packages every custom IP for the block design. One table holds
#              the file list, top module and name of each, and the table is
#              checked against the block design before anything is built.
# -----------------------------------------------------------------------------

set -u -o pipefail
ROOT="${1:?gcam1g root}"
OUT="${2:?out dir}"
PART="${3:-xck26-sfvc784-2LV-c}"
VIVADO="${VIVADO:-vivado}"
GEN="$ROOT/fpga/scripts/package_ip_generic.tcl"

declare -a IPS=(
  "tpg|tpg|rtl/tpg/tpg_regs.sv,rtl/tpg/tpg_gen.sv,rtl/tpg/tpg.sv"
  "pixpipe|pixpipe|rtl/pixpipe/pixpipe_pfc_packer.sv,rtl/pixpipe/pixpipe.sv"
  "gvsp|gvsp|rtl/gvsp/gvsp_proto_pkg.sv,rtl/gvsp/gvsp_segmenter.sv,rtl/gvsp/gvsp_packet_builder.sv,rtl/gvsp/gvsp.sv"
  "eth_tx|eth_tx|rtl/eth_tx/eth_tx_fifo.sv,rtl/eth_tx/eth_tx_udp_ip.sv,rtl/eth_tx/eth_tx_framer.sv,rtl/eth_tx/eth_tx.sv"
  "eth_wr|eth_wr|rtl/eth_wr/eth_wr_pkt.sv,rtl/eth_wr/eth_wr.sv"
  "ctrl|ctrl|rtl/ctrl/gcam1g_regs_pkg.sv,rtl/ctrl/ctrl.sv"
  "mipi_src|mipi_src|rtl/mipi_src/mipi_src.sv"
  "src_mux2|src_mux2|rtl/src_mux2/src_mux2.sv"
  "yuv2rgb|yuv2rgb|rtl/yuv2rgb/yuv2rgb.sv"
  "clk_rx_mon|clk_rx_mon|rtl/clk_rx_mon/clk_rx_mon.sv"
)

mkdir -p "$OUT"
rm -rf "$OUT/ip_repo"
rm -f "$OUT"/pkg_*.log

rc=0
BD_TCL="$ROOT/fpga/bd/kv260_fullfab_bd.tcl"
pre=0
for row in "${IPS[@]}"; do
  IFS='|' read -r name top files <<<"$row"
  IFS=',' read -ra fs <<<"$files"
  for f in "${fs[@]}"; do
    [ -f "$ROOT/$f" ] || { echo "  missing file: $name -> $f"; pre=1; }
  done
  topf=""
  for f in "${fs[@]}"; do [ "$(basename "$f")" = "$top.sv" ] && topf=$f; done
  if [ -z "$topf" ]; then
    echo "  top file not in the list: $name declares top=$top but $top.sv is absent"; pre=1
  else
    grep -q "^module[[:space:]]\+$top\b" "$ROOT/$topf" 2>/dev/null \
      || { echo "  top mismatch: $name declares top=$top, not found in $topf"; pre=1; }
    [ "${fs[${#fs[@]}-1]}" = "$topf" ] \
      || { echo "  top is not last: put $topf at the end of the file list for $name"; pre=1; }
  fi
  grep -q "user.org:gcam:$name:" "$BD_TCL" \
    || { echo "  IP not used by the block design: $name"; pre=1; }
done
for v in $(grep -oE 'user\.org:gcam:[a-z0-9_]+' "$BD_TCL" | cut -d: -f3 | sort -u); do
  printf '%s\n' "${IPS[@]}" | cut -d'|' -f1 | grep -qx "$v" \
    || { echo "  required by the block design but missing from the table: $v"; pre=1; }
done
[ "$pre" = 1 ] && { echo "IPS TABLE BROKEN — abort"; exit 1; }

PY=${PYTHON:-}
if [ -z "$PY" ]; then
  for c in /usr/bin/python3 python3 python; do
    if "$c" -c 'print("PYOK")' 2>/dev/null | grep -q PYOK; then PY=$c; break; fi
  done
fi
if [ -z "$PY" ]; then
  echo "  python3 not found - skipping the port cross-check (it would only surface during the block design build)" >&2
else
  "$PY" "$(dirname "$0")/check_bd_ports.py" "$ROOT" "$BD_TCL" "${IPS[@]}" || {
    echo "BD PORT CHECK FAILED — abort"; exit 1; }
fi
echo "IP table OK (${#IPS[@]} IPs; files, top modules and block design names all agree)"
for row in "${IPS[@]}"; do
  IFS='|' read -r name top files <<<"$row"
  abs=""
  IFS=',' read -ra fs <<<"$files"
  for f in "${fs[@]}"; do abs+="${abs:+,}$ROOT/$f"; done
  echo "==== packaging $name ===="
  if "$VIVADO" -mode batch -nolog -nojournal -source "$GEN" \
      -tclargs part="$PART" name="$name" top="$top" files="$abs" out="$OUT" \
      > "$OUT/pkg_$name.log" 2>&1 && grep -q IP_PACKAGE_OK "$OUT/pkg_$name.log"; then
    echo "  OK $name"
  else
    echo "  FAIL $name (see $OUT/pkg_$name.log)"; rc=1
  fi
done
n=$(ls -1 "$OUT/ip_repo" 2>/dev/null | wc -l)
if [ "$n" -ne "${#IPS[@]}" ]; then
  echo "  expected ${#IPS[@]} IPs in ip_repo, found $n: $(ls -1 "$OUT/ip_repo" 2>/dev/null | tr '\n' ' ')"
  rc=1
else
  echo "ip_repo IPs: $n (expected ${#IPS[@]})"
fi
if [ "$rc" = 0 ] && [ -n "$PY" ]; then
  "$PY" "$(dirname "$0")/check_bd_ports.py" --packaged "$OUT/ip_repo" \
    "$ROOT" "$BD_TCL" "${IPS[@]}" || rc=1
fi
echo "PACKAGE_ALL done (rc=$rc)"
exit $rc
