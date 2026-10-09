# Makefile - build u-dma-buf.ko as an out-of-tree kernel module.
#
#   make                                   # build u-dma-buf.ko for the running kernel
#   sudo insmod u-dma-buf.ko udmabuf0=134217728
#
# Needs build-essential and linux-headers-$(uname -r); see UDMABUF_BUILD.md.
# install.sh drives this automatically - you do not need to run it by hand.

obj-m := u-dma-buf.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

modules_install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: all modules_install clean
