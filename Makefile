SHELL := /bin/bash

# debug build flags
#KBUILD_EXTRA_CFLAGS = "-DCONFIG_SND_DEBUG=1 -DMYSOUNDDEBUGFULL -DAPPLE_PINSENSE_FIXUP -DAPPLE_CODECS -DCONFIG_SND_HDA_RECONFIG=1 -Wno-unused-variable -Wno-unused-function"
# normal build flags
KBUILD_EXTRA_CFLAGS = "-DAPPLE_PINSENSE_FIXUP -DAPPLE_CODECS -DCONFIG_SND_HDA_RECONFIG=1 -Wno-unused-variable -Wno-unused-function"


ifdef KERNELRELEASE
	KERNELDIR := /lib/modules/$(KERNELRELEASE)
else
	KERNELDIR := /lib/modules/$(shell uname -r)
endif

KERNELBUILD := $(KERNELDIR)/build

all:
	make -C $(KERNELBUILD) CFLAGS_MODULE=$(KBUILD_EXTRA_CFLAGS) M=$(shell pwd)/build/hda modules

clean:
	make -C $(KERNELBUILD) M=$(shell pwd)/build/hda clean

distclean: clean
	rm -rf build/ dkms.conf.orig

install:
	make INSTALL_MOD_DIR=updates -C $(KERNELBUILD) M=$(shell pwd)/build/hda CONFIG_MODULE_SIG_ALL=n modules_install
	depmod -a

# ── Testing ──────────────────────────────────────────────────────────────────

# Fast syntax check (no tools needed)
test-syntax:
	@bash tests/test-docker.sh --syntax

# Full Docker integration test (requires: sudo apt-get install docker.io)
test-docker:
	@bash tests/test-docker.sh

# Full Docker test + remove image afterwards
test-docker-clean:
	@bash tests/test-docker.sh --clean

# Multipass VM test — full Ubuntu 26.04 with real systemd
# Usage: make test-vm  (requires: sudo snap install multipass)
VM_NAME  := macbook-test
VM_IMAGE := daily:26.04

test-vm:
	@echo "=== Multipass VM test (Ubuntu 26.04) ==="
	@if ! multipass info $(VM_NAME) &>/dev/null; then \
	    echo "  Creating VM '$(VM_NAME)' from $(VM_IMAGE)..."; \
	    multipass launch $(VM_IMAGE) --name $(VM_NAME) --cpus 2 --memory 4G --disk 20G; \
	fi
	@echo "  Mounting project into VM..."
	@multipass mount "$(CURDIR)" $(VM_NAME):/project 2>/dev/null || \
	    multipass exec $(VM_NAME) -- sudo mkdir -p /project
	@echo "  Running macbook_hardware_fixer.sh in VM..."
	@multipass exec $(VM_NAME) -- sudo bash /project/macbook_hardware_fixer.sh
	@echo ""
	@echo "  Next steps:"
	@echo "    make test-vm-verify   — run verify-hardware.sh inside VM"
	@echo "    make test-vm-clean    — destroy VM"

test-vm-verify:
	@multipass exec $(VM_NAME) -- sudo bash /project/tests/verify-hardware.sh

test-vm-shell:
	@multipass exec $(VM_NAME) -- bash

test-vm-clean:
	@multipass delete $(VM_NAME) && multipass purge
	@echo "  VM '$(VM_NAME)' deleted."

# Verify hardware (run on real machine after macbook_hardware_fixer.sh)
verify:
	@sudo bash tests/verify-hardware.sh
