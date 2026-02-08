# Host-side Makefile for building minimal i486 Linux
# This runs on the HOST and invokes Docker
#
# Usage:
#   make build-image       - Build the Docker image
#   make menuconfig-kernel - Configure kernel interactively
#   make menuconfig-busybox - Configure busybox interactively
#   make build             - Build kernel + busybox
#   make iso               - Create bootable ISO
#   make test              - Test ISO in QEMU (runs on host, not in container)
#   make shell             - Drop into container shell for debugging

SHELL := /bin/bash

# Docker image name
IMAGE_NAME := i486-linux-builder

# Get absolute path to this directory
PROJECT_DIR := $(shell pwd)

# Mount points
CONFIGS_MOUNT := -v $(PROJECT_DIR)/configs:/configs
OUTPUT_MOUNT := -v $(PROJECT_DIR)/output:/output
BUILD_MOUNT := -v i486-linux-build:/build
ROOTFS_MOUNT := -v $(PROJECT_DIR)/rootfs:/rootfs
SCRIPTS_MOUNT := -v $(PROJECT_DIR)/scripts:/scripts
SYSROOT_MOUNT := -v i486-linux-sysroot:/sysroot:ro

# Common docker run options (build mount enables incremental compilation)
DOCKER_RUN := docker run --rm $(CONFIGS_MOUNT) $(OUTPUT_MOUNT) $(BUILD_MOUNT) $(ROOTFS_MOUNT) $(SCRIPTS_MOUNT) $(SYSROOT_MOUNT)
DOCKER_RUN_IT := docker run --rm -it $(CONFIGS_MOUNT) $(OUTPUT_MOUNT) $(BUILD_MOUNT) $(ROOTFS_MOUNT) $(SCRIPTS_MOUNT) $(SYSROOT_MOUNT)

.PHONY: help build-image menuconfig-kernel menuconfig-busybox build rootfs iso all \
        clean clean-kernel clean-busybox clean-build clean-all test shell copy-default-configs

help:
	@echo "=========================================="
	@echo "  Minimal i486 Linux Build System"
	@echo "=========================================="
	@echo ""
	@echo "Docker:"
	@echo "  build-image        - Build the Docker image (do this first)"
	@echo "  shell              - Drop into container shell"
	@echo ""
	@echo "Configuration:"
	@echo "  menuconfig-kernel  - Configure Linux kernel interactively"
	@echo "  menuconfig-busybox - Configure BusyBox interactively"
	@echo "  copy-default-configs - Copy default configs to ./configs/"
	@echo ""
	@echo "Building:"
	@echo "  build              - Build kernel + busybox"
	@echo "  iso                - Create bootable ISO"
	@echo "  all                - Build everything"
	@echo ""
	@echo "Testing:"
	@echo "  test               - Boot ISO in QEMU (requires qemu-system-i386)"
	@echo "  test-docker        - Boot ISO in QEMU inside container"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean              - Remove output files only"
	@echo "  clean-kernel       - Clean kernel object files (force full rebuild)"
	@echo "  clean-busybox      - Clean busybox object files (force full rebuild)"
	@echo "  clean-build        - Remove all build artifacts (output + build/)"
	@echo "  clean-all          - Remove everything including Docker image"
	@echo ""
	@echo "Quick Start:"
	@echo "  1. make build-image"
	@echo "  2. make copy-default-configs  (optional: use defaults)"
	@echo "  3. make menuconfig-kernel     (optional: customize)"
	@echo "  4. make menuconfig-busybox    (optional: customize)"
	@echo "  5. make iso"
	@echo "  6. make test"

# Build the Docker image
build-image:
	@echo "==> Building Docker image '$(IMAGE_NAME)'"
	docker build -t $(IMAGE_NAME) .

# Copy default configs to host
copy-default-configs:
	@echo "==> Copying default configs to ./configs/"
	@mkdir -p $(PROJECT_DIR)/configs
	$(DOCKER_RUN) $(IMAGE_NAME) make copy-default-configs

# Interactive kernel configuration
# Requires -it for interactive terminal
menuconfig-kernel:
	@echo "==> Running kernel menuconfig"
	@mkdir -p $(PROJECT_DIR)/configs
	$(DOCKER_RUN_IT) $(IMAGE_NAME) make menuconfig-kernel

# Interactive busybox configuration
menuconfig-busybox:
	@echo "==> Running busybox menuconfig"
	@mkdir -p $(PROJECT_DIR)/configs
	$(DOCKER_RUN_IT) $(IMAGE_NAME) make menuconfig-busybox

# Build kernel and busybox
build:
	@echo "==> Building kernel and busybox"
	@mkdir -p $(PROJECT_DIR)/output
	$(DOCKER_RUN) $(IMAGE_NAME) make build

# Build root filesystem (squashfs)
rootfs:
	@echo "==> Building root filesystem"
	@mkdir -p $(PROJECT_DIR)/output
	$(DOCKER_RUN) $(IMAGE_NAME) make rootfs

# Create bootable ISO
iso:
	@echo "==> Creating bootable ISO"
	@mkdir -p $(PROJECT_DIR)/output
	$(DOCKER_RUN) $(IMAGE_NAME) make iso

# Build everything
all:
	@echo "==> Building everything"
	@mkdir -p $(PROJECT_DIR)/configs $(PROJECT_DIR)/output
	$(DOCKER_RUN) $(IMAGE_NAME) make all

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

# Test ISO in QEMU (inside container - useful if host doesn't have qemu)
test-docker:
	@if [ ! -f "$(PROJECT_DIR)/output/boot.iso" ]; then \
		echo "Error: output/boot.iso not found. Run 'make iso' first."; \
		exit 1; \
	fi
	@echo "==> Booting ISO in QEMU inside container"
	$(DOCKER_RUN_IT) --device=/dev/kvm:/dev/kvm 2>/dev/null || true && \
	$(DOCKER_RUN_IT) $(IMAGE_NAME) make test

# Drop into container shell
shell:
	@echo "==> Dropping into container shell"
	$(DOCKER_RUN_IT) $(IMAGE_NAME) /bin/bash

# Clean kernel build artifacts (for full kernel rebuild)
clean-kernel:
	@echo "==> Cleaning kernel build artifacts"
	$(DOCKER_RUN) $(IMAGE_NAME) make clean-kernel

# Clean busybox build artifacts (for full busybox rebuild)
clean-busybox:
	@echo "==> Cleaning busybox build artifacts"
	$(DOCKER_RUN) $(IMAGE_NAME) make clean-busybox

# Clean output directory only
clean:
	@echo "==> Cleaning output directory"
	rm -rf $(PROJECT_DIR)/output/*

# Clean all build artifacts (output + kernel + busybox object files)
clean-build:
	@echo "==> Cleaning all build artifacts"
	rm -rf $(PROJECT_DIR)/output/*
	docker volume rm i486-linux-build 2>/dev/null || true

# Clean everything including Docker image
clean-all: clean-build
	@echo "==> Removing Docker image"
	docker rmi $(IMAGE_NAME) 2>/dev/null || true
