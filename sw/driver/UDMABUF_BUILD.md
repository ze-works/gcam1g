# u-dma-buf: the packet-ring DMA buffer

## What it is

[`u-dma-buf`](https://github.com/ikwzm/udmabuf) is a small Linux kernel module by Ichiro
Kawazome. It reserves a CMA-backed DMA buffer, exposes it as `/dev/udmabufN`, and puts its
physical address and size under `/sys/class/u-dma-buf/udmabufN/`. The licence is 2-clause
BSD, and the copy in this directory (`u-dma-buf.c`) is unmodified.

## Why this project needs it

The PL writes finished GVSP packets into a 128 MB slot ring in DDR (16384 slots of 8192
bytes). `gvsp_server` reads the ring from user space and sends the packets out, so it needs
a pointer to that physical memory. `u-dma-buf` provides it: `udmabuf0=134217728` reserves
exactly the 128 MB the ring needs, and `gvsp_server` maps it from `/dev/udmabuf0`.

There is no prebuilt `.ko` here, because a kernel module only loads into the kernel
version it was built for. Building from source matches whatever kernel the board runs.

## Building it

This is an ordinary out-of-tree Kbuild module. The [`Makefile`](Makefile) in this
directory drives the running kernel's own build system. You need `build-essential`, which
brings `make` and a C compiler, and headers matching `uname -r`:

```sh
sudo apt install build-essential linux-headers-$(uname -r)
make
```

That produces `u-dma-buf.ko`. `install.sh` runs this step for you, and only when the
module is not already loaded or installed, so you do not normally run it by hand.

## Loading it

```sh
sudo insmod u-dma-buf.ko udmabuf0=134217728    # 128 MB, exactly what the packet ring needs
```

With any other size, or without the module, `gvsp_server` refuses to start. It reads the
ring geometry the PL was built with from the read-only CSRs at `0x6C` / `0x70` and compares
it with its own.

## Making it persist across reboots

A reboot clears the bitstream, the camera overlay and this module. `install.sh` loads all
three again, so running it after each reboot is enough. To have the module load at boot
instead, install it into the module tree once:

```sh
sudo make modules_install
sudo depmod
echo u-dma-buf | sudo tee /etc/modules-load.d/u-dma-buf.conf
echo "options u-dma-buf udmabuf0=134217728" | sudo tee /etc/modprobe.d/u-dma-buf.conf
```

`install.sh` tries `modprobe u-dma-buf udmabuf0=134217728` before it builds anything, so
a module installed this way is used without a recompile.

## Upstream

You can also install directly from
[`github.com/ikwzm/udmabuf`](https://github.com/ikwzm/udmabuf), which supports DKMS and so
rebuilds itself across kernel updates. Either way, load it with the size this project
needs: `udmabuf0=134217728`.
