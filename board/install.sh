#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# File:        install.sh
# Description: Installs the camera onto the board. Run it on the board itself,
#              as root, from the directory the release tarball was extracted
#              into.
# -----------------------------------------------------------------------------

set -u -o pipefail

[ "$(id -u)" = 0 ] || { echo "run as root: sudo ./install.sh" >&2; exit 1; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP=/lib/firmware/xilinx/kv260_gige

install -d "$APP" || { echo "could not create $APP" >&2; exit 1; }
install -m 0644 "$HERE/kv260_gige.bit.bin" "$HERE/kv260_gige.dtbo" \
                "$HERE/shell.json" "$APP/" \
  || { echo "could not install firmware files into $APP - check the tarball extracted fully" >&2
       exit 1; }

xmutil unloadapp >/dev/null 2>&1 || true
xmutil loadapp kv260_gige \
  || { echo "xmutil loadapp kv260_gige failed - no PL bitstream is loaded" >&2
       exit 1; }
LISTAPPS=$(xmutil listapps) \
  || { echo "xmutil listapps failed after loadapp reported success" >&2; exit 1; }
echo "$LISTAPPS" | grep kv260_gige \
  || { echo "kv260_gige is not listed as loaded - loadapp did not really take" >&2
       exit 1; }

OVERLAY_DIR=/sys/kernel/config/device-tree/overlays/gcam1g-cam
HAVE_CAM=0
if [ -d "$OVERLAY_DIR" ]; then
  if [ -e /dev/i2c-4 ]; then
    echo "camera overlay already applied (/dev/i2c-4 present) - leaving it alone"
    HAVE_CAM=1
  else
    echo "camera overlay is already applied, but no camera was detected (/dev/i2c-4 absent)."
    echo "  Not retrying: re-applying an already-applied overlay wedges the I2C bus."
    echo "  If you just connected a camera, power-cycle (reboot) the board and re-run"
    echo "  this script - a fresh boot clears the overlay along with the PL."
    echo "  Meanwhile: sudo gcam1g-run --tpg"
  fi
else
  install -d "$OVERLAY_DIR" || { echo "could not create $OVERLAY_DIR" >&2; exit 1; }
  if ! cat "$HERE/cam_overlay.dtbo" > "$OVERLAY_DIR/dtbo"; then
    rmdir "$OVERLAY_DIR" 2>/dev/null
    echo "camera overlay apply failed - removed the unconfigured overlay directory" >&2
    echo "so a re-run starts clean (nothing was left half-applied)" >&2
    exit 1
  fi
  sleep 2
  if [ -e /dev/i2c-4 ]; then
    echo "camera overlay applied: /dev/i2c-4"
    HAVE_CAM=1
    echo "waiting for the camera firmware to finish loading..."
    last=-1; quiet=0; waited=0
    while [ "$waited" -lt 120 ]; do
      cur=$(dmesg | grep -ci ap1302)
      if [ "$cur" = "$last" ]; then quiet=$((quiet + 2)); else quiet=0; last=$cur; fi
      [ "$quiet" -ge 20 ] && break
      sleep 2; waited=$((waited + 2))
    done
    [ "$quiet" -ge 20 ] || echo "note: the camera driver was still busy after 120 s"
  else
    echo "camera overlay applied, but no /dev/i2c-4 - continuing without a camera (test pattern only)"
    echo "  If you connect a camera later, power-cycle (reboot) the board before re-running this script."
  fi
fi
if [ "$HAVE_CAM" = 1 ] && ! dmesg | grep -qi ap1302; then
  echo "note: /dev/i2c-4 is present but the kernel did not report an AP1302."
  echo "      If the camera does not appear, use: sudo gcam1g-run --tpg"
fi

UDMABUF_SIZE=134217728
if [ -e /dev/udmabuf0 ]; then
  echo "u-dma-buf already loaded (/dev/udmabuf0 present) - leaving it alone"
elif modprobe u-dma-buf udmabuf0=$UDMABUF_SIZE 2>/dev/null; then
  echo "u-dma-buf loaded (module was already installed)"
else
  HAVE_BUILD_TOOLS=1
  command -v make >/dev/null 2>&1 || HAVE_BUILD_TOOLS=0
  { command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; } || HAVE_BUILD_TOOLS=0
  [ -d "/lib/modules/$(uname -r)/build" ] || HAVE_BUILD_TOOLS=0

  if [ "$HAVE_BUILD_TOOLS" = 1 ]; then
    echo "building u-dma-buf for $(uname -r) (see driver/UDMABUF_BUILD.md)"
    make -C "/lib/modules/$(uname -r)/build" M="$HERE/driver" modules \
      && insmod "$HERE/driver/u-dma-buf.ko" udmabuf0=$UDMABUF_SIZE
  fi

  if [ ! -e /dev/udmabuf0 ]; then
    echo
    echo "Everything else installed. Only the DMA buffer (u-dma-buf) is missing."
    echo
    echo "Two ways forward:"
    echo "  1) Install a compiler and kernel headers, then re-run this script:"
    echo "       sudo apt install build-essential linux-headers-\$(uname -r)"
    echo "       sudo ./install.sh"
    echo "  2) Install the module from upstream instead (also supports DKMS):"
    echo "       https://github.com/ikwzm/udmabuf"
    echo "     Either way, load it with the size this project needs:"
    echo "       udmabuf0=$UDMABUF_SIZE   (128 MB, for the packet ring)"
    exit 1
  fi
fi
[ -e /dev/udmabuf0 ] && echo "udmabuf0: $(cat /sys/class/u-dma-buf/udmabuf0/size) bytes" \
                     || { echo "u-dma-buf did not come up" >&2; exit 1; }

install -m 0755 "$HERE/gvsp_server" /usr/local/bin/gvsp_server \
  || { echo "could not install gvsp_server to /usr/local/bin" >&2; exit 1; }
install -m 0755 "$HERE/run.sh"      /usr/local/bin/gcam1g-run \
  || { echo "could not install run.sh as /usr/local/bin/gcam1g-run" >&2; exit 1; }

echo
if [ "$HAVE_CAM" = 1 ]; then
  echo "INSTALL DONE.  Start the camera with:  sudo gcam1g-run"
  echo "               Or the PL test pattern:  sudo gcam1g-run --tpg"
else
  echo "INSTALL DONE.  No camera detected. Start the PL test pattern with:"
  echo "               sudo gcam1g-run --tpg"
fi
