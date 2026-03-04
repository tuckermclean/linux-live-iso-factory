# Host-side Makefile for building minimal i486 Linux
# This runs on the HOST and invokes Docker
#
# Usage:
#   make build-image         - Build the Docker image (do this first)
#   make sync-portage        - Sync Gentoo portage tree
#   make build-packages      - Cross-compile Gentoo packages
#   make extract             - Extract binpkgs to output/sysroot/
#   make build               - Build kernel + busybox
#   make iso                 - Create bootable ISO (full pipeline)
#   make test                - Test ISO in QEMU (runs on host)
#   make shell               - Drop into container shell

SHELL := /bin/bash

# Docker image name
IMAGE_NAME := i486-linux-builder

# Get absolute path to this directory
PROJECT_DIR := $(shell pwd)

# Parallelism settings (passed to container)
JOBS ?= $(shell nproc)
LOAD_AVG ?= $(shell nproc)
PARALLEL_ENV := -e JOBS=$(JOBS) -e LOAD_AVG=$(LOAD_AVG)

# Named volumes for persistent build state
BUILD_VOLUME := i486-linux-build
PORTAGE_VOLUME := i486-portage-cache

# Bind mounts
CONFIGS_MOUNT := -v $(PROJECT_DIR)/configs:/configs
OUTPUT_MOUNT := -v $(PROJECT_DIR)/output:/output
SCRIPTS_MOUNT := -v $(PROJECT_DIR)/scripts:/scripts:ro
ROOTFS_MOUNT := -v $(PROJECT_DIR)/rootfs:/rootfs:ro
PATCHES_MOUNT := -v $(PROJECT_DIR)/patches:/patches:ro

# Volume mounts
BUILD_MOUNT := -v $(BUILD_VOLUME):/build
PORTAGE_MOUNT := -v $(PORTAGE_VOLUME):/var/db/repos/gentoo

# Portage log mount
LOGS_MOUNT := -v $(PROJECT_DIR)/output/portage-logs:/var/log/portage

# Common docker run options
DOCKER_RUN := docker run --rm \
	$(CONFIGS_MOUNT) $(OUTPUT_MOUNT) $(SCRIPTS_MOUNT) \
	$(ROOTFS_MOUNT) $(PATCHES_MOUNT) $(LOGS_MOUNT) \
	$(BUILD_MOUNT) $(PORTAGE_MOUNT) \
	$(PARALLEL_ENV)
DOCKER_RUN_IT := docker run --rm -it \
	$(CONFIGS_MOUNT) $(OUTPUT_MOUNT) $(SCRIPTS_MOUNT) \
	$(ROOTFS_MOUNT) $(PATCHES_MOUNT) $(LOGS_MOUNT) \
	$(BUILD_MOUNT) $(PORTAGE_MOUNT) \
	$(PARALLEL_ENV)

.PHONY: help build-image sync-portage build-packages build-packages-resume extract \
        build build-kernel build-busybox menuconfig-kernel menuconfig-busybox \
        iso all rootfs test shell \
        check-updates update-versions list-packages show-failed \
        clean clean-build clean-all ensure-dirs

help:
	@echo "=========================================="
	@echo "  i486 Linux Build System"
	@echo "=========================================="
	@echo ""
	@echo "Docker:"
	@echo "  build-image          - Build the Docker image (do this first)"
	@echo "  shell                - Drop into container shell"
	@echo ""
	@echo "Packages (Gentoo cross-compilation):"
	@echo "  sync-portage         - Sync portage tree in cache volume"
	@echo "  build-packages       - Cross-compile packages (JOBS=$(JOBS))"
	@echo "  build-packages-resume - Resume build, skip already-built"
	@echo "  extract              - Extract binpkgs to output/sysroot/"
	@echo ""
	@echo "Kernel/BusyBox:"
	@echo "  build                - Build kernel + busybox (initrd)"
	@echo "  build-kernel         - Build kernel only"
	@echo "  build-busybox        - Build busybox only"
	@echo "  menuconfig-kernel    - Configure kernel interactively"
	@echo "  menuconfig-busybox   - Configure busybox interactively"
	@echo ""
	@echo "ISO:"
	@echo "  iso                  - Create bootable ISO (full pipeline)"
	@echo "  all                  - Alias for iso"
	@echo ""
	@echo "Testing:"
	@echo "  test                 - Boot ISO in QEMU (requires qemu-system-i386)"
	@echo ""
	@echo "Version Management:"
	@echo "  check-updates        - Show available updates vs pinned versions"
	@echo "  update-versions      - Update versions.lock with latest versions"
	@echo "  list-packages        - Show packages in world file"
	@echo "  show-failed          - Show failed packages from last build"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean                - Remove output files only"
	@echo "  clean-build          - Remove output + build volume"
	@echo "  clean-all            - Remove everything (volumes + image)"
	@echo ""
	@echo "Quick Start:"
	@echo "  1. make build-image"
	@echo "  2. make sync-portage"
	@echo "  3. make build-packages"
	@echo "  4. make extract"
	@echo "  5. make iso"
	@echo "  6. make test"

# Ensure output directories exist
ensure-dirs:
	@mkdir -p $(PROJECT_DIR)/output/{packages,logs,sysroot,portage-logs}
	@mkdir -p $(PROJECT_DIR)/configs

# Build the Docker image
build-image:
	@echo "==> Building Docker image '$(IMAGE_NAME)'"
	docker build -t $(IMAGE_NAME) .

# Ensure portage volume exists
ensure-volume:
	@docker volume inspect $(PORTAGE_VOLUME) >/dev/null 2>&1 || \
		(echo "==> Creating portage cache volume" && \
		 docker volume create $(PORTAGE_VOLUME))

# Sync portage tree in volume
sync-portage: ensure-volume ensure-dirs
	@echo "==> Syncing portage tree"
	$(DOCKER_RUN) $(IMAGE_NAME) emerge --sync

# Build all packages (with parallel jobs)
build-packages: ensure-volume ensure-dirs
	@echo "==> Building packages ($(JOBS) parallel jobs)"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/build-packages.sh

# Resume build (skip already-built packages)
build-packages-resume: ensure-volume ensure-dirs
	@echo "==> Resuming package build ($(JOBS) parallel jobs)"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/build-packages.sh --resume

# Extract packages to sysroot
extract: ensure-dirs
	@echo "==> Extracting packages to sysroot"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/extract-packages.sh

# Build kernel and busybox
build: ensure-dirs
	@echo "==> Building kernel and busybox"
	$(DOCKER_RUN) $(IMAGE_NAME) make build

# Build kernel only
build-kernel: ensure-dirs
	@echo "==> Building kernel"
	$(DOCKER_RUN) $(IMAGE_NAME) make build-kernel

# Build busybox only
build-busybox: ensure-dirs
	@echo "==> Building busybox"
	$(DOCKER_RUN) $(IMAGE_NAME) make build-busybox

# Interactive kernel configuration
menuconfig-kernel: ensure-dirs
	@echo "==> Running kernel menuconfig"
	$(DOCKER_RUN_IT) $(IMAGE_NAME) make menuconfig-kernel

# Interactive busybox configuration
menuconfig-busybox: ensure-dirs
	@echo "==> Running busybox menuconfig"
	$(DOCKER_RUN_IT) $(IMAGE_NAME) make menuconfig-busybox

# Build root filesystem (squashfs)
rootfs: ensure-dirs
	@echo "==> Building root filesystem"
	$(DOCKER_RUN) $(IMAGE_NAME) make rootfs

# Create bootable ISO (full pipeline: build + initrd + rootfs + iso)
iso: ensure-dirs
	@echo "==> Creating bootable ISO"
	$(DOCKER_RUN) $(IMAGE_NAME) make iso

# Build everything
all: iso

# Test ISO in QEMU (on host)
test:
	@if [ ! -f "$(PROJECT_DIR)/output/boot.iso" ]; then \
		echo "Error: output/boot.iso not found. Run 'make iso' first."; \
		exit 1; \
	fi
	@echo "==> Booting ISO in QEMU (Ctrl+A X to exit)"
	@echo "    For graphical: qemu-system-i386 -cdrom output/boot.iso -m 64M"
	qemu-system-i386 \
		-cdrom $(PROJECT_DIR)/output/boot.iso \
		-m 64M \
		-cpu 486 \
		-nographic \
		-serial mon:stdio

# Check for available updates
check-updates: ensure-volume ensure-dirs
	@echo "==> Checking for package updates"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/update-versions.sh check

# Update versions.lock with latest versions
# The script writes directly to /configs/portage/versions.lock (bind-mounted)
update-versions: ensure-volume ensure-dirs
	@echo "==> Updating versions.lock"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/update-versions.sh update

# List packages in world file
list-packages:
	@echo "==> Packages in world file:"
	@grep -v '^#' $(PROJECT_DIR)/configs/portage/world | grep -v '^$$' || true

# Show failed packages from last build
show-failed:
	@echo "==> Failed packages:"
	@cat $(PROJECT_DIR)/output/.failed-packages 2>/dev/null || echo "(none or no build run yet)"
	@echo ""
	@echo "==> Logs available in: output/logs/"

# Drop into container shell
shell: ensure-volume ensure-dirs
	@echo "==> Dropping into container shell"
	$(DOCKER_RUN_IT) $(IMAGE_NAME) /bin/bash

# Clean output directory only
clean:
	@echo "==> Cleaning output directory"
	rm -rf $(PROJECT_DIR)/output/*

# Clean all build artifacts (output + build volume)
clean-build: clean
	@echo "==> Removing build volume"
	docker volume rm $(BUILD_VOLUME) 2>/dev/null || true

# Clean everything including Docker image and all volumes
clean-all: clean-build
	@echo "==> Removing portage cache volume"
	docker volume rm $(PORTAGE_VOLUME) 2>/dev/null || true
	@echo "==> Removing Docker image"
	docker rmi $(IMAGE_NAME) 2>/dev/null || true
