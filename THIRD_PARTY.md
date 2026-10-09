# Third-party components

The code written for this project is under the MIT licence (`LICENSE`). The components
below are not, and keep their own licences.

| Component | Where | Licence |
|---|---|---|
| u-dma-buf | `sw/driver/u-dma-buf.c`; `driver/` in the release tarball | BSD-2-Clause |
| Camera device tree overlay | `fpga/dt/cam_overlay.dts`; `cam_overlay.dtbo` and `cam_overlay.dts` in the release tarball | GPL-2.0 |
| GNU C Library (glibc) 2.39 | statically linked into `gvsp_server` in the release tarball | LGPL-2.1 |
| GCC runtime (libstdc++, libgcc) 13.3 | statically linked into `gvsp_server` in the release tarball | GPL-3.0 with the GCC Runtime Library Exception |
| AMD Vivado IP | inside the bitstream `kv260_gige.bit.bin` | AMD licence terms |

The full licence texts are in `licenses/`.

## u-dma-buf

Copyright (C) 2015-2026 Ichiro Kawazome. Distributed as unmodified source under the
2-clause BSD licence, which is reproduced at the top of the file. Upstream:
https://github.com/ikwzm/udmabuf

## Camera device tree overlay

The AP1302 node follows `boards/kv260/smartcam/kv260-smartcam.dtsi` from Xilinx
kria-apps-firmware, (C) Copyright 2020 - 2021, Xilinx, Inc., licensed GPL-2.0. The
overlay is therefore GPL-2.0 as well. Its source is in this repository and is included
in the release tarball next to the compiled `.dtbo`. The overlay is loaded by the kernel
as data and is not linked with any other part of this project.

## glibc

`gvsp_server` in the release tarball is statically linked against glibc 2.39 as shipped
by Ubuntu 24.04 (`libc6-dev-arm64-cross` 2.39-0ubuntu8cross1, corresponding to Ubuntu
glibc 2.39-0ubuntu8). glibc is licensed under the GNU Lesser General Public License,
version 2.1 (`licenses/LGPL-2.1.txt`).

You can rebuild `gvsp_server` against a modified glibc. The complete source of the
application is in `sw/`, and `./build.sh sw` builds it; set `CROSS_CXX` to use your own
toolchain. The glibc source is attached to the GitHub release as
`glibc-2.39-0ubuntu8-source.tar`, and is also available from Ubuntu:

```sh
apt source glibc=2.39-0ubuntu8
```

or from https://launchpad.net/ubuntu/+source/glibc/2.39-0ubuntu8

## GCC runtime

libstdc++ and libgcc are covered by the GCC Runtime Library Exception, which places no
licence conditions on the application they are linked into.

## AMD Vivado IP

The block design uses IP from AMD Vivado 2024.2 (MIPI CSI-2 RX Subsystem, `axi_iic`,
`smartconnect` and others). Their source is not part of this repository. The generated
logic is part of the bitstream, which is provided for use on the AMD Kria KV260 under
AMD's licence terms.
