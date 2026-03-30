# Host-side Makefile for building minimal i486 Linux
# This runs on the HOST and invokes Docker
#
# Usage:
#   make build-image         - Build the Docker image (do this first)
#   make sync-portage        - Sync Gentoo portage tree
#   make build-packages      - Cross-compile all packages (kernel, busybox, userland)
#   make extract             - Extract binpkgs to output/sysroot/
#   make iso                 - Create bootable ISO (initrd + rootfs + iso)
#   make test                - Boot ISO in QEMU (runs on host)
#   make shell               - Drop into container shell

SHELL := /bin/bash

# Docker image name
IMAGE_NAME := monolith-builder

# Get absolute path to this directory
PROJECT_DIR := $(shell pwd)

# Image version derived from the pinned stage3 date in Dockerfile
IMAGE_VERSION := $(shell grep '^ARG STAGE3_DATE=' Dockerfile | cut -d= -f2)

# Container registry — set REGISTRY to push/pull the builder image
# e.g.: make push-image REGISTRY=ghcr.io/youruser
REGISTRY ?=
REGISTRY_IMAGE := $(if $(REGISTRY),$(REGISTRY)/$(IMAGE_NAME),$(IMAGE_NAME))

# Parallelism settings (passed to container)
JOBS ?= $(shell nproc)
LOAD_AVG ?= $(shell nproc)
PARALLEL_ENV := -e JOBS=$(JOBS) -e LOAD_AVG=$(LOAD_AVG)

# Named volumes for persistent build state
BUILD_VOLUME := monolith-build
PORTAGE_VOLUME := monolith-portage-cache

# Bind mounts
CONFIGS_MOUNT := -v $(PROJECT_DIR)/configs:/configs
OUTPUT_MOUNT := -v $(PROJECT_DIR)/output:/output
SCRIPTS_MOUNT := -v $(PROJECT_DIR)/scripts:/scripts:ro
ROOTFS_MOUNT := -v $(PROJECT_DIR)/rootfs:/rootfs:ro

# Volume mounts
BUILD_MOUNT := -v $(BUILD_VOLUME):/build
PORTAGE_MOUNT := -v $(PORTAGE_VOLUME):/var/db/repos/gentoo

# Portage log mount
LOGS_MOUNT := -v $(PROJECT_DIR)/output/portage-logs:/var/log/portage

# Common docker run options
DOCKER_RUN := docker run --rm \
	$(CONFIGS_MOUNT) $(OUTPUT_MOUNT) $(SCRIPTS_MOUNT) \
	$(ROOTFS_MOUNT) $(LOGS_MOUNT) \
	$(BUILD_MOUNT) $(PORTAGE_MOUNT) \
	$(PARALLEL_ENV)
DOCKER_RUN_IT := docker run --rm -it \
	$(CONFIGS_MOUNT) $(OUTPUT_MOUNT) $(SCRIPTS_MOUNT) \
	$(ROOTFS_MOUNT) $(LOGS_MOUNT) \
	$(BUILD_MOUNT) $(PORTAGE_MOUNT) \
	$(PARALLEL_ENV)

.PHONY: help build-image push-image pull-image \
        sync-portage build-packages build-packages-resume extract \
        menuconfig-kernel menuconfig-busybox \
        iso all test shell \
        check-updates update-versions update-build-pins update-all \
        list-packages show-failed \
        clean clean-build clean-all ensure-dirs ensure-volume

help:
	@echo "=========================================="
	@echo "  The Monolith"
	@echo "=========================================="
	@echo ""
	@echo "Docker:"
	@echo "  build-image          - Build the Docker image (factory, no sources)"
	@echo "  push-image           - Push image to registry (set REGISTRY=...)"
	@echo "  pull-image           - Pull image from registry (set REGISTRY=...)"
	@echo "  shell                - Drop into container shell"
	@echo ""
	@echo "Packages (Gentoo cross-compilation — kernel, busybox, userland):"
	@echo "  sync-portage          - Sync portage tree in cache volume"
	@echo "  build-packages        - Cross-compile all packages (JOBS=$(JOBS))"
	@echo "  build-packages-resume - Resume build, skip already-built"
	@echo "  extract               - Copy live sysroot to output/sysroot/"
	@echo ""
	@echo "Configuration:"
	@echo "  menuconfig-kernel    - Configure kernel interactively"
	@echo "  menuconfig-busybox   - Configure BusyBox interactively"
	@echo ""
	@echo "ISO:"
	@echo "  iso                  - Create bootable ISO (initrd + rootfs + iso)"
	@echo "  all                  - Full build: image → packages → extract → iso"
	@echo ""
	@echo "Testing:"
	@echo "  test                 - Boot ISO in QEMU (requires qemu-system-i386)"
	@echo ""
	@echo "Version Management:"
	@echo "  check-updates        - Show available updates vs pinned versions"
	@echo "  update-versions      - Update versions.lock with latest versions"
	@echo "  update-build-pins    - Update stage3 date + epoch in Dockerfile"
	@echo "  update-all           - Update everything (build pins + package versions)"
	@echo "  list-packages        - Show packages in world file"
	@echo "  show-failed          - Show failed packages from last build"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean                - Remove output files only"
	@echo "  clean-build          - Remove output + build volume"
	@echo "  clean-all            - Remove everything (volumes + image)"
	@echo ""
	@echo "Quick Start:"
	@echo "  make build-image     - Build Docker image (once, or after Dockerfile changes)"
	@echo "  make sync-portage    - Sync portage tree (once, or to get package updates)"
	@echo "  make all             - Build everything and produce boot.iso"
	@echo "  make test            - Boot ISO in QEMU"
	@echo ""
	@echo "Registry (optional):"
	@echo "  REGISTRY=ghcr.io/user make push-image   - Push to registry"
	@echo "  REGISTRY=ghcr.io/user make pull-image   - Pull from registry"

# Ensure output directories exist
ensure-dirs:
	@mkdir -p $(PROJECT_DIR)/output/{packages,logs,sysroot,portage-logs}
	@mkdir -p $(PROJECT_DIR)/configs

# Ensure portage volume exists
ensure-volume:
	@docker volume inspect $(PORTAGE_VOLUME) >/dev/null 2>&1 || \
		(echo "==> Creating portage cache volume" && \
		 docker volume create $(PORTAGE_VOLUME))

# Intermediate image name for the pre-crossdev stage
BASE_TOOLS_IMAGE := $(IMAGE_NAME)-base-tools

# Container name used during crossdev build (fixed name allows pre-cleanup on retry)
CROSSDEV_CONTAINER := monolith-crossdev-build

# Build the Docker image (pure factory — toolchain only, no sources)
# Crossdev runs as `docker run` so portage logs always land in output/portage-logs/.
# The final image is produced by `docker commit` from the completed crossdev container.
# The base-tools image ID is stamped as a label on the final image. On subsequent
# runs, if that label matches the current base-tools ID, the crossdev step is skipped.
build-image: ensure-dirs
	@echo "==> Building base-tools stage (stage3: $(IMAGE_VERSION))"
	docker buildx build --target base-tools \
		--cache-from $(BASE_TOOLS_IMAGE) --cache-to type=inline \
		-t $(BASE_TOOLS_IMAGE) \
		.
	@BASE_HASH=$$(docker inspect --format='{{json .RootFS.Layers}}' $(BASE_TOOLS_IMAGE) | sha256sum | cut -d' ' -f1); \
	EXISTING_HASH=$$(docker inspect --format='{{index .Config.Labels "base-tools-hash"}}' $(IMAGE_NAME) 2>/dev/null || true); \
	if [ -n "$$EXISTING_HASH" ] && [ "$$BASE_HASH" = "$$EXISTING_HASH" ]; then \
		echo "==> Image $(IMAGE_NAME) is up to date — base-tools unchanged, skipping crossdev"; \
	else \
		[ -n "$$EXISTING_HASH" ] \
			&& echo "==> Base-tools layers changed — rebuilding crossdev toolchain" \
			|| echo "==> Building crossdev toolchain (logs → output/portage-logs/)"; \
		docker rm -f $(CROSSDEV_CONTAINER) 2>/dev/null || true; \
		docker run --name $(CROSSDEV_CONTAINER) \
			$(LOGS_MOUNT) \
			$(BASE_TOOLS_IMAGE) \
			bash -c 'set -e && \
			    crossdev --target "$$CROSS_TARGET" --stable --gcc 15 --portage --verbose && \
			    echo "cross-$$CROSS_TARGET/gcc static-libs" \
			        > /etc/portage/package.use/cross-gcc-static && \
			    emerge --update --newuse "cross-$$CROSS_TARGET/gcc" && \
			    rm -rf /var/cache/distfiles/* && \
			    mkdir -p \
			        /usr/$$CROSS_TARGET/etc/portage/{package.use,package.accept_keywords,package.mask,package.env,env} \
			        /build /configs /output /initrd' && \
		docker commit \
			--change 'ENV BUILD_DIR=/build' \
			--change 'ENV CONFIGS_DIR=/configs' \
			--change 'ENV OUTPUT_DIR=/output' \
			--change "LABEL base-tools-hash=$$BASE_HASH" \
			$(CROSSDEV_CONTAINER) $(IMAGE_NAME) && \
		docker rm $(CROSSDEV_CONTAINER) && \
		echo "==> Image $(IMAGE_NAME) ready"; \
	fi

# Push builder image to registry
push-image: build-image
	@if [ -z "$(REGISTRY)" ]; then \
		echo "Error: set REGISTRY=<registry/repo> — e.g. REGISTRY=ghcr.io/youruser make push-image"; \
		exit 1; \
	fi
	docker tag $(IMAGE_NAME) $(REGISTRY_IMAGE):$(IMAGE_VERSION)
	docker tag $(IMAGE_NAME) $(REGISTRY_IMAGE):latest
	docker push $(REGISTRY_IMAGE):$(IMAGE_VERSION)
	docker push $(REGISTRY_IMAGE):latest
	@echo "==> Pushed $(REGISTRY_IMAGE):$(IMAGE_VERSION) and :latest"

# Pull builder image from registry and tag locally
pull-image:
	@if [ -z "$(REGISTRY)" ]; then \
		echo "Error: set REGISTRY=<registry/repo> — e.g. REGISTRY=ghcr.io/youruser make pull-image"; \
		exit 1; \
	fi
	docker pull $(REGISTRY_IMAGE):$(IMAGE_VERSION)
	docker tag $(REGISTRY_IMAGE):$(IMAGE_VERSION) $(IMAGE_NAME)
	@echo "==> Pulled and tagged as $(IMAGE_NAME)"

# Sync portage tree in volume
sync-portage: ensure-volume ensure-dirs
	@echo "==> Syncing portage tree"
	$(DOCKER_RUN) $(IMAGE_NAME) emerge --sync

# Build all packages: kernel, busybox, and userland (with parallel jobs)
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

# Interactive kernel menuconfig — saves result to configs/kernel.config
menuconfig-kernel: ensure-volume ensure-dirs
	@echo "==> Running kernel menuconfig"
	$(DOCKER_RUN_IT) $(IMAGE_NAME) emerge --config sys-kernel/linux-live

# Interactive BusyBox menuconfig — saves result to configs/portage/savedconfig/sys-apps/busybox
menuconfig-busybox: ensure-volume ensure-dirs
	@echo "==> Running BusyBox menuconfig"
	$(DOCKER_RUN_IT) $(IMAGE_NAME) i486-linux-musl-emerge --config sys-apps/busybox

# Create bootable ISO (initrd + rootfs + iso)
iso: ensure-dirs
	@echo "==> Building initramfs"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/build-initrd.sh
	@echo "==> Building root filesystem"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/build-rootfs.sh
	@echo "==> Creating bootable ISO"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/build-iso.sh

# Build everything: image → packages → extract → iso
all: build-image sync-portage build-packages extract iso

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

# Check for available updates (portage packages)
check-updates: ensure-volume ensure-dirs
	@echo "==> Checking for package updates"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/update-versions.sh check

# Update versions.lock with latest portage package versions
update-versions: ensure-volume ensure-dirs
	@echo "==> Updating versions.lock"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/update-versions.sh update

# Update stage3 date + SOURCE_DATE_EPOCH in Dockerfile (runs on host, no Docker needed)
update-build-pins:
	@echo "==> Updating Dockerfile build pins (stage3 date, epoch)"
	$(PROJECT_DIR)/scripts/update-build-pins.sh update

# Update everything: Dockerfile pins + portage package versions
update-all: update-build-pins update-versions
	@echo "==> All pins updated. Run 'make build-image' to rebuild the factory."

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
