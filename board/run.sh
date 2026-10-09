#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# File:        run.sh
# Description: Starts the camera server on the board. Options select the
#              test pattern instead of the camera, the address to advertise,
#              and the network interface to send from.
# -----------------------------------------------------------------------------

set -u -o pipefail

OUR_IP=""
IFACE=""
SRC_SEL=0x001
PIXFMT=0x02180014
MODE=camera
while [ $# -gt 0 ]; do
  case "$1" in
    --tpg)    SRC_SEL=0x000; PIXFMT=0x01080001; MODE="test pattern"; shift ;;
    --our-ip) OUR_IP="${2:?}"; shift 2 ;;
    --iface)  IFACE="${2:?}";  shift 2 ;;
    *) echo "usage: $0 [--tpg] [--our-ip <addr>] [--iface <name>]" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

if [ -n "$IFACE" ]; then
  [ -n "$OUR_IP" ] || OUR_IP=$(ip -4 -o addr show dev "$IFACE" scope global \
                                  | awk '{split($4,a,"/"); print a[1]; exit}')
elif [ -n "$OUR_IP" ]; then
  IFACE=$(ip -4 -o addr show scope global \
            | awk -v ip="$OUR_IP" '{split($4,a,"/"); if (a[1]==ip) {print $2; exit}}')
else
  read -r IFACE OUR_IP < <(ip -4 -o addr show scope global \
            | awk '{split($4,a,"/"); print $2, a[1]; exit}')
fi
[ -n "$OUR_IP" ] || { echo "could not determine our IP - pass --our-ip" >&2; exit 1; }
[ -n "$IFACE" ]  || { echo "could not determine the interface for $OUR_IP - pass --iface <name>" >&2; exit 1; }
echo "serving $MODE on $OUR_IP ($IFACE)"

WIRE_BYTES=8050
MTU=$(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null || true)
if [ -z "$MTU" ]; then
  echo "could not read the MTU of $IFACE" >&2
  exit 1
fi
if [ "$MTU" -lt "$WIRE_BYTES" ]; then
  echo "refusing to start: $IFACE has MTU $MTU, but this build needs $WIRE_BYTES" >&2
  echo "  Raise it:  sudo ip link set $IFACE mtu 9000" >&2
  echo "  Make it permanent with your netplan or NetworkManager configuration." >&2
  echo "  The viewing host does not need it for the test pattern: the packet size is" >&2
  echo "  negotiated (Aravis does this by itself). The camera stream needs jumbo frames." >&2
  exit 1
fi

[ -e /dev/udmabuf0 ] || { echo "/dev/udmabuf0 missing - run install.sh first" >&2; exit 1; }

pl_loaded() { grep -qix '0x0*a0020000' /sys/class/uio/uio*/maps/map0/addr 2>/dev/null; }
if ! pl_loaded; then
  echo "loading the kv260_gige PL (not loaded since boot)"
  xmutil unloadapp >/dev/null 2>&1 || true
  xmutil loadapp kv260_gige >/dev/null \
    || { echo "xmutil loadapp kv260_gige failed - run install.sh first" >&2; exit 1; }
  pl_loaded || { echo "the kv260_gige PL did not appear after loadapp" >&2; exit 1; }
fi
if [ "$MODE" = camera ] && [ ! -d /sys/kernel/config/device-tree/overlays/gcam1g-cam ]; then
  echo "the camera overlay is not applied (it is cleared by a reboot)." >&2
  echo "  Re-run the installer from the extracted tarball:  sudo ./install.sh" >&2
  echo "  or stream the test pattern:                       sudo gcam1g-run --tpg" >&2
  exit 1
fi

systemctl stop gvcp 2>/dev/null || true
systemctl reset-failed gvcp 2>/dev/null || true
sleep 1

SINCE=$(date '+%Y-%m-%d %H:%M:%S')

SD_OUT=$(systemd-run --unit=gvcp \
  --setenv=GVSP_FULLFAB=1 \
  --setenv=GVSP_W=1920 \
  --setenv=GVSP_H=1080 \
  --setenv=GVSP_PIXFMT="$PIXFMT" \
  --setenv=GVSP_LEADER_FIX=1 \
  --setenv=GVSP_MBPS=950 \
  --setenv=GVSP_SRC_SEL="$SRC_SEL" \
  --setenv=GVSP_BATCH=8 \
  /usr/local/bin/gvsp_server --serve --our-ip "$OUR_IP" 2>&1)
SD_RC=$?
if [ "$SD_RC" -ne 0 ]; then
  echo "systemd-run failed to start the gvcp unit (exit $SD_RC):" >&2
  echo "$SD_OUT" >&2
  exit 1
fi

sleep 3

if ! systemctl is-active --quiet gvcp; then
  echo "gvcp is not running - it did not stay up. Reason:" >&2
  systemctl status gvcp --no-pager 2>&1 | tail -20 >&2
  exit 1
fi

journalctl -u gvcp --no-pager -o cat --since "$SINCE" | grep -v DISCOVERY | tail -8
echo "RUN DONE.  Open arv-viewer-0.8 (Aravis) on a host in the same subnet."
