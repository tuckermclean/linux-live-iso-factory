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

# Single build epoch — pins stage3 base image and portage snapshot to the same date
BUILD_EPOCH := $(shell grep '^ARG BUILD_EPOCH=' Dockerfile | cut -d= -f2)

# Kernel version — read from versions.lock so targets stay in sync with the pin
KERNEL_VERSION := $(shell grep '^sys-kernel/monolith-kernel:' configs/portage/versions.lock | cut -d: -f2)

# Build artifact version — override with BUILD_VERSION=x.y.z for CI
BUILD_VERSION ?= $(BUILD_EPOCH)
VERSION_ENV := -e BUILD_VERSION=$(BUILD_VERSION)

# Container registry — set REGISTRY to push/pull the builder image
REGISTRY ?= ghcr.io/tuckermclean
REGISTRY_IMAGE := $(if $(REGISTRY),$(REGISTRY)/$(IMAGE_NAME),$(IMAGE_NAME))

# S3 bucket for binary package cache — override with S3_BUCKET=... if needed
S3_BUCKET ?= themonolith

# Parallelism settings (passed to container)
JOBS ?= $(shell nproc)
LOAD_AVG ?= $(shell nproc)
PARALLEL_ENV := -e JOBS=$(JOBS) -e LOAD_AVG=$(LOAD_AVG)

# Named volumes for persistent build state
BUILD_VOLUME    := monolith-build
PORTAGE_VOLUME  := monolith-repos
DISTFILES_VOLUME := monolith-distfiles
GRYPE_VOLUME    := monolith-grype-db

# Bind mounts
CONFIGS_MOUNT := -v $(PROJECT_DIR)/configs:/configs
OUTPUT_MOUNT := -v $(PROJECT_DIR)/output:/output
SCRIPTS_MOUNT := -v $(PROJECT_DIR)/scripts:/scripts:ro
ROOTFS_MOUNT := -v $(PROJECT_DIR)/rootfs:/rootfs:ro

# Volume mounts
BUILD_MOUNT      := -v $(BUILD_VOLUME):/build
PORTAGE_MOUNT    := -v $(PORTAGE_VOLUME):/var/db/repos
DISTFILES_MOUNT  := -v $(DISTFILES_VOLUME):/var/cache/distfiles
GRYPE_MOUNT      := -v $(GRYPE_VOLUME):/root/.cache/grype

# Portage log mount
LOGS_MOUNT := -v $(PROJECT_DIR)/output/portage-logs:/var/log/portage

# Common docker run options
DOCKER_RUN := docker run --rm \
	$(CONFIGS_MOUNT) $(OUTPUT_MOUNT) $(SCRIPTS_MOUNT) \
	$(ROOTFS_MOUNT) $(LOGS_MOUNT) \
	$(BUILD_MOUNT) $(PORTAGE_MOUNT) $(DISTFILES_MOUNT) \
	$(PARALLEL_ENV)
DOCKER_RUN_IT := docker run --rm -it \
	$(CONFIGS_MOUNT) $(OUTPUT_MOUNT) $(SCRIPTS_MOUNT) \
	$(ROOTFS_MOUNT) $(LOGS_MOUNT) \
	$(BUILD_MOUNT) $(PORTAGE_MOUNT) $(DISTFILES_MOUNT) \
	$(PARALLEL_ENV)
# Attestation-specific run: same as DOCKER_RUN but with the Grype DB volume
DOCKER_RUN_ATTEST := docker run --rm \
	$(CONFIGS_MOUNT) $(OUTPUT_MOUNT) $(SCRIPTS_MOUNT) \
	$(ROOTFS_MOUNT) $(LOGS_MOUNT) \
	$(BUILD_MOUNT) $(PORTAGE_MOUNT) $(DISTFILES_MOUNT) \
	$(GRYPE_MOUNT) \
	$(PARALLEL_ENV)

.PHONY: help build-image push-image pull-image restore-cache \
        sync-portage build-packages build-packages-resume \
        extract build-rootfs \
        menuconfig-kernel menuconfig-busybox \
        iso all test shell \
        check-updates update-versions update-build-pins update-all \
        list-packages show-failed regen-manifest \
        attestation dashboard grype-db-update \
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
	@echo "  build-packages        - Step 1: cross-compile packages → binpkgs (JOBS=$(JOBS))"
	@echo "  build-packages-resume - Resume build, skip already-built"
	@echo "  build-rootfs          - Step 2: install binpkgs → squashfs + initrd"
	@echo "  extract               - Alias for build-rootfs install step only"
	@echo ""
	@echo "Configuration:"
	@echo "  menuconfig-kernel    - Configure kernel interactively"
	@echo "  menuconfig-busybox   - Configure BusyBox interactively"
	@echo ""
	@echo "ISO:"
	@echo "  iso                  - Step 3: assemble ISO from squashfs + initrd + vmlinuz"
	@echo "  all                  - Full build: image → packages → rootfs → iso"
	@echo ""
	@echo "Testing:"
	@echo "  test                 - Boot ISO in QEMU (requires qemu-system-i386)"
	@echo ""
	@echo "Attestation:"
	@echo "  attestation          - Run SBOM + license + CVE checks (requires build-rootfs first)"
	@echo "  dashboard            - Generate static HTML dashboard from local attestation artifacts"
	@echo "  grype-db-update      - Update Grype CVE database (stored in Docker volume)"
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
	@echo "  S3_BUCKET=my-bucket make restore-cache  - Pull images + portage + binpkgs (CI parity)"

# Ensure output directories exist
ensure-dirs:
	@mkdir -p $(PROJECT_DIR)/output/{packages,logs,sysroot,portage-logs,attestation,dashboard}
	@mkdir -p $(PROJECT_DIR)/configs

# Ensure persistent volumes exist
ensure-volume:
	@docker volume inspect $(PORTAGE_VOLUME) >/dev/null 2>&1 || \
		(echo "==> Creating repos volume" && \
		 docker volume create $(PORTAGE_VOLUME))
	@docker volume inspect $(DISTFILES_VOLUME) >/dev/null 2>&1 || \
		(echo "==> Creating distfiles volume" && \
		 docker volume create $(DISTFILES_VOLUME))
	@docker volume inspect $(GRYPE_VOLUME) >/dev/null 2>&1 || \
		(echo "==> Creating grype DB volume" && \
		 docker volume create $(GRYPE_VOLUME))

# Intermediate image name for the pre-crossdev stage
BASE_TOOLS_IMAGE := $(IMAGE_NAME)-base-tools

# Container name used during crossdev build (fixed name allows pre-cleanup on retry)
CROSSDEV_CONTAINER := monolith-crossdev-build

# Build the Docker image (pure factory — toolchain only, no sources)
# If REGISTRY is set, first tries to pull the BUILD_EPOCH-pinned image from the
# registry (fast path). Falls back to a local build if the pull fails or REGISTRY
# is unset. Crossdev runs as `docker run` so portage logs always land in
# output/portage-logs/. The final image is produced by `docker commit` from the
# completed crossdev container. The base-tools image ID is stamped as a label on
# the final image. On subsequent runs, if that label matches the current base-tools
# ID, the crossdev step is skipped.
build-image: ensure-dirs
	@if [ -n "$(REGISTRY)" ] && docker pull $(REGISTRY_IMAGE):$(BUILD_EPOCH) 2>/dev/null; then \
		docker tag $(REGISTRY_IMAGE):$(BUILD_EPOCH) $(IMAGE_NAME); \
		docker pull $(REGISTRY_IMAGE)-base-tools:$(BUILD_EPOCH) 2>/dev/null && \
			docker tag $(REGISTRY_IMAGE)-base-tools:$(BUILD_EPOCH) $(BASE_TOOLS_IMAGE) || true; \
		echo "==> Pulled $(IMAGE_NAME) from $(REGISTRY_IMAGE):$(BUILD_EPOCH)"; \
	else \
		[ -n "$(REGISTRY)" ] && echo "==> Registry pull failed — building locally" || true; \
		echo "==> Building base-tools stage (epoch: $(BUILD_EPOCH))"; \
		docker buildx build --target base-tools \
			$(if $(REGISTRY),--cache-from $(REGISTRY_IMAGE)-base-tools:$(BUILD_EPOCH)) \
			--cache-from $(BASE_TOOLS_IMAGE) --cache-to type=inline \
			-t $(BASE_TOOLS_IMAGE) \
			. && \
		BASE_HASH=$$(docker inspect --format='{{json .RootFS.Layers}}' $(BASE_TOOLS_IMAGE) | sha256sum | cut -d' ' -f1) && \
		EXISTING_HASH=$$(docker inspect --format='{{index .Config.Labels "base-tools-hash"}}' $(IMAGE_NAME) 2>/dev/null || true) && \
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
		fi; \
	fi

# Push builder image to registry
push-image: build-image
	@if [ -z "$(REGISTRY)" ]; then \
		echo "Error: set REGISTRY=<registry/repo> — e.g. REGISTRY=ghcr.io/youruser make push-image"; \
		exit 1; \
	fi
	docker tag $(IMAGE_NAME) $(REGISTRY_IMAGE):$(BUILD_EPOCH)
	docker tag $(IMAGE_NAME) $(REGISTRY_IMAGE):latest
	docker push $(REGISTRY_IMAGE):$(BUILD_EPOCH)
	docker push $(REGISTRY_IMAGE):latest
	docker tag $(BASE_TOOLS_IMAGE) $(REGISTRY_IMAGE)-base-tools:$(BUILD_EPOCH)
	docker tag $(BASE_TOOLS_IMAGE) $(REGISTRY_IMAGE)-base-tools:latest
	docker push $(REGISTRY_IMAGE)-base-tools:$(BUILD_EPOCH)
	docker push $(REGISTRY_IMAGE)-base-tools:latest
	@echo "==> Pushed $(REGISTRY_IMAGE):$(BUILD_EPOCH) and :latest (+ base-tools)"

# Pull builder image from registry and tag locally
pull-image:
	@if [ -z "$(REGISTRY)" ]; then \
		echo "Error: set REGISTRY=<registry/repo> — e.g. REGISTRY=ghcr.io/youruser make pull-image"; \
		exit 1; \
	fi
	docker pull $(REGISTRY_IMAGE):$(BUILD_EPOCH)
	docker tag $(REGISTRY_IMAGE):$(BUILD_EPOCH) $(IMAGE_NAME)
	docker pull $(REGISTRY_IMAGE)-base-tools:latest || true
	docker tag $(REGISTRY_IMAGE)-base-tools:latest $(BASE_TOOLS_IMAGE) || true
	@echo "==> Pulled and tagged as $(IMAGE_NAME) (+ base-tools)"

# Restore all caches as CI does: pull builder images, sync portage, restore binpkgs from S3.
# Requires: REGISTRY set (defaults to ghcr.io/tuckermclean), S3_BUCKET set, AWS credentials in env.
# This is the manual equivalent of the CI cache-restore steps before `make build-packages`.
restore-cache: ensure-dirs ensure-volume
	@if [ -z "$(REGISTRY)" ]; then \
		echo "Error: set REGISTRY=<registry/repo>"; exit 1; \
	fi
	@echo "==> Pulling builder images from $(REGISTRY)"
	$(MAKE) pull-image
	@echo "==> Syncing portage tree"
	$(MAKE) sync-portage
	@echo "==> Restoring binary packages from s3://$(S3_BUCKET)/packages/$(BUILD_EPOCH)/"
	aws s3 sync --no-sign-request s3://$(S3_BUCKET)/packages/$(BUILD_EPOCH)/ $(PROJECT_DIR)/output/packages/

# Sync portage tree in volume
sync-portage: ensure-volume ensure-dirs
	@echo "==> Syncing portage tree (pinned: $(BUILD_EPOCH))"
	$(DOCKER_RUN) $(IMAGE_NAME) emerge-webrsync --revert=$(BUILD_EPOCH)

# Build all packages: kernel, busybox, and userland (with parallel jobs)
build-packages: ensure-volume ensure-dirs
	@echo "==> Building packages ($(JOBS) parallel jobs)"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/build-packages.sh

# Resume build (skip already-built packages)
build-packages-resume: ensure-volume ensure-dirs
	@echo "==> Resuming package build ($(JOBS) parallel jobs)"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/build-packages.sh --resume

# Install pre-built packages into the sysroot (step 2a)
extract: ensure-volume ensure-dirs
	@echo "==> Installing packages from binpkgs"
	$(DOCKER_RUN) $(VERSION_ENV) $(IMAGE_NAME) /scripts/extract-packages.sh

# Interactive kernel menuconfig — saves result to configs/kernel.config
# Bypasses portage's environment sanitization (which breaks ncurses TUI) by
# driving tar/patch/make directly. CROSS_COMPILE not needed for menuconfig.
menuconfig-kernel: ensure-volume ensure-dirs
	@echo "==> Running kernel menuconfig"
	$(DOCKER_RUN_IT) -e TERM $(IMAGE_NAME) sh -c \
	    'set -e; \
	     KVER=$(KERNEL_VERSION); \
	     PATCH=/configs/overlay/sys-kernel/monolith-kernel/files/linux-$${KVER%.*}-gcc15-std-gnu11.patch; \
	     SRCDIR=/tmp/kernel-menuconfig; \
	     rm -rf "$$SRCDIR" && mkdir -p "$$SRCDIR"; \
	     echo "==> Extracting linux-$${KVER}.tar.xz ..."; \
	     tar xf /var/cache/distfiles/linux-$${KVER}.tar.xz -C "$$SRCDIR" --strip-components=1; \
	     cd "$$SRCDIR"; \
	     patch -p1 < "$$PATCH"; \
	     [ -f /configs/kernel.config ] && cp /configs/kernel.config .config || make ARCH=i386 allnoconfig; \
	     make ARCH=i386 olddefconfig; \
	     make ARCH=i386 menuconfig && cp .config /configs/kernel.config && echo "==> Config saved to configs/kernel.config"'

# Interactive BusyBox menuconfig — saves result to configs/portage/savedconfig/sys-apps/busybox
menuconfig-busybox: ensure-volume ensure-dirs
	@echo "==> Running BusyBox menuconfig"
	$(DOCKER_RUN_IT) $(IMAGE_NAME) i486-linux-musl-emerge --config sys-apps/busybox

# Build squashfs + initrd from sysroot populated by build-packages (step 2)
# build-packages exports output/sysroot/ directly, so no extract step needed here.
# To re-extract from binpkgs without rebuilding, use: make extract
build-rootfs: ensure-volume ensure-dirs
	@echo "==> Building root filesystem"
	$(DOCKER_RUN) $(VERSION_ENV) $(IMAGE_NAME) /scripts/build-rootfs.sh
	@echo "==> Building initramfs"
	$(DOCKER_RUN) $(VERSION_ENV) $(IMAGE_NAME) /scripts/build-initrd.sh

# Assemble bootable ISO from squashfs + initrd + vmlinuz (step 3)
iso: ensure-dirs
	@echo "==> Creating bootable ISO"
	$(DOCKER_RUN) $(VERSION_ENV) $(IMAGE_NAME) /scripts/build-iso.sh

# Build everything: image → packages → rootfs → iso
all: build-image sync-portage build-packages build-rootfs iso

# Run the three-pillar attestation pipeline (SBOM + licenses + CVEs)
# Requires: output/sysroot/ must exist (run build-rootfs first)
# All pillars always run — never stops on failure — artifacts always written
attestation: ensure-volume ensure-dirs
	@echo "==> Running attestation pipeline (build: $(BUILD_VERSION))"
	$(DOCKER_RUN_ATTEST) $(VERSION_ENV) $(IMAGE_NAME) /scripts/attestation.sh \
		--sysroot /output/sysroot \
		--iso /output/themonolith-$(BUILD_VERSION).iso \
		--build-tag $(BUILD_VERSION) \
		--overrides /configs/attestation/cpe-overrides.yaml \
		--policy /configs/attestation/license-policy.yaml \
		--output-dir /output/attestation

# Generate static HTML attestation dashboard from local attestation artifacts
dashboard: ensure-dirs
	@echo "==> Generating attestation dashboard"
	$(DOCKER_RUN_ATTEST) $(IMAGE_NAME) python3 /scripts/generate-dashboard.py \
		--input-dir /output/attestation \
		--output-dir /output/dashboard

# Update the Grype vulnerability database (stored in monolith-grype-db volume)
grype-db-update: ensure-volume
	@echo "==> Updating Grype vulnerability database"
	$(DOCKER_RUN_ATTEST) $(IMAGE_NAME) grype db update

# Test ISO in QEMU (on host)
test:
	@if [ ! -f "$(PROJECT_DIR)/output/themonolith-$(BUILD_VERSION).iso" ]; then \
		echo "Error: output/themonolith-$(BUILD_VERSION).iso not found. Run 'make iso' first."; \
		exit 1; \
	fi
	@echo "==> Booting ISO in QEMU (Ctrl+A X to exit)"
	@echo "    For graphical: qemu-system-i386 -cdrom output/themonolith-$(BUILD_VERSION).iso -m 64M"
	qemu-system-i386 \
		-cdrom $(PROJECT_DIR)/output/themonolith-$(BUILD_VERSION).iso \
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

# Regenerate monolith-kernel Manifest (run once after changing the ebuild)
regen-manifest: ensure-dirs
	$(DOCKER_RUN_IT) $(IMAGE_NAME) \
	    ebuild /configs/overlay/sys-kernel/monolith-kernel/monolith-kernel-$(KERNEL_VERSION).ebuild manifest

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
	@echo "==> Removing repos volume"
	docker volume rm $(PORTAGE_VOLUME) 2>/dev/null || true
	@echo "==> Removing distfiles volume"
	docker volume rm $(DISTFILES_VOLUME) 2>/dev/null || true
	@echo "==> Removing grype DB volume"
	docker volume rm $(GRYPE_VOLUME) 2>/dev/null || true
	@echo "==> Removing Docker image"
	docker rmi $(IMAGE_NAME) 2>/dev/null || true
