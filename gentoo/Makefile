# Host-side Makefile for Gentoo cross-compilation system
#
# This runs on the HOST and invokes Docker to build i486-linux-musl packages.
#
# Usage:
#   make build-image      - Build the Docker image (includes toolchain)
#   make build-packages   - Cross-compile all packages from world file
#   make extract          - Extract binpkgs to output/sysroot/
#   make shell            - Debug access to container

SHELL := /bin/bash

# Docker image name
IMAGE_NAME := i486-gentoo-crossdev

# Get absolute path to this directory
PROJECT_DIR := $(shell pwd)

# Docker volume for portage cache (avoids re-syncing each run)
PORTAGE_VOLUME := gentoo-portage-cache

# Mount points
CONFIGS_MOUNT := -v $(PROJECT_DIR)/configs:/etc/portage-cross:ro
OUTPUT_MOUNT := -v $(PROJECT_DIR)/output:/output
PATCHES_MOUNT := -v $(PROJECT_DIR)/patches:/patches:ro
LOGS_MOUNT := -v $(PROJECT_DIR)/output/portage-logs:/var/log/portage

# Portage cache volume (persistent across runs)
PORTAGE_CACHE := -v $(PORTAGE_VOLUME):/var/db/repos/gentoo

# Parallelism settings (passed to container)
JOBS ?= $(shell nproc)
LOAD_AVG ?= $(shell nproc)
PARALLEL_ENV := -e JOBS=$(JOBS) -e LOAD_AVG=$(LOAD_AVG)

# Common docker run options
DOCKER_RUN := docker run --rm $(CONFIGS_MOUNT) $(OUTPUT_MOUNT) $(PATCHES_MOUNT) $(LOGS_MOUNT) $(PORTAGE_CACHE)

.PHONY: help build-image build-packages build-packages-resume extract \
        check-updates update-versions validate-versions shell clean clean-all \
        sync-portage list-packages show-failed

help:
	@echo "=========================================="
	@echo "  Gentoo i486-linux-musl Cross-Compiler"
	@echo "=========================================="
	@echo ""
	@echo "Setup:"
	@echo "  build-image        - Build the Docker image (includes toolchain)"
	@echo ""
	@echo "Building:"
	@echo "  build-packages     - Cross-compile all packages (parallel, JOBS=$(JOBS))"
	@echo "  build-packages-resume - Resume build, skipping already-built packages"
	@echo "  extract            - Extract binpkgs to output/sysroot/"
	@echo ""
	@echo "  Override parallelism: make build-packages JOBS=4 LOAD_AVG=4"
	@echo ""
	@echo "Version Management:"
	@echo "  check-updates      - Show available updates vs pinned versions"
	@echo "  update-versions    - Update versions.lock with latest versions"
	@echo "  validate-versions  - Check versions.lock format"
	@echo ""
	@echo "Maintenance:"
	@echo "  sync-portage       - Sync portage tree in cache volume"
	@echo "  list-packages      - Show packages in world file"
	@echo "  show-failed        - Show failed packages from last build"
	@echo "  shell              - Drop into container shell"
	@echo "  clean              - Remove output files"
	@echo "  clean-all          - Remove output, cache volume, and image"
	@echo ""
	@echo "Workflow:"
	@echo "  1. make build-image"
	@echo "  2. make build-packages"
	@echo "  3. make extract"
	@echo "  4. cp -a output/sysroot/* ../rootfs-build/"

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
sync-portage: ensure-volume
	@echo "==> Syncing portage tree"
	$(DOCKER_RUN) $(IMAGE_NAME) emerge --sync

# Build all packages (with parallel jobs)
build-packages: ensure-volume
	@echo "==> Building packages ($(JOBS) parallel jobs)"
	@mkdir -p $(PROJECT_DIR)/output/{packages,logs,sysroot}
	$(DOCKER_RUN) $(PARALLEL_ENV) $(IMAGE_NAME) /scripts/build-packages.sh

# Resume build (skip already-built packages)
build-packages-resume: ensure-volume
	@echo "==> Resuming package build ($(JOBS) parallel jobs)"
	@mkdir -p $(PROJECT_DIR)/output/{packages,logs,sysroot}
	$(DOCKER_RUN) $(PARALLEL_ENV) $(IMAGE_NAME) /scripts/build-packages.sh --resume

# Extract packages to sysroot
extract:
	@echo "==> Extracting packages to sysroot"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/extract-packages.sh

# Check for available updates
check-updates: ensure-volume
	@echo "==> Checking for package updates"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/update-versions.sh check

# Update versions.lock with latest versions
update-versions: ensure-volume
	@echo "==> Updating versions.lock"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/update-versions.sh update
	@echo "==> Copying updated versions.lock to host"
	docker run --rm $(OUTPUT_MOUNT) $(IMAGE_NAME) \
		cp /etc/portage-cross/versions.lock /output/versions.lock.new
	@if [ -f $(PROJECT_DIR)/output/versions.lock.new ]; then \
		mv $(PROJECT_DIR)/output/versions.lock.new $(PROJECT_DIR)/configs/versions.lock; \
		echo "==> Updated configs/versions.lock"; \
	fi

# Validate versions.lock format
validate-versions:
	@echo "==> Validating versions.lock"
	$(DOCKER_RUN) $(IMAGE_NAME) /scripts/update-versions.sh validate

# List packages in world file
list-packages:
	@echo "==> Packages in world file:"
	@grep -v '^#' $(PROJECT_DIR)/configs/world | grep -v '^$$' || true

# Show failed packages from last build
show-failed:
	@echo "==> Failed packages:"
	@cat $(PROJECT_DIR)/output/.failed-packages 2>/dev/null || echo "(none or no build run yet)"
	@echo ""
	@echo "==> Logs available in: output/logs/"

# Drop into container shell
shell: ensure-volume
	@echo "==> Dropping into container shell"
	docker run --rm -it $(CONFIGS_MOUNT) $(OUTPUT_MOUNT) $(PATCHES_MOUNT) $(LOGS_MOUNT) $(PORTAGE_CACHE) $(IMAGE_NAME) /bin/bash

# Clean output files
clean:
	@echo "==> Cleaning output directory"
	rm -rf $(PROJECT_DIR)/output/*

# Clean everything including cache volume and image
clean-all: clean
	@echo "==> Removing portage cache volume"
	docker volume rm $(PORTAGE_VOLUME) 2>/dev/null || true
	@echo "==> Removing Docker image"
	docker rmi $(IMAGE_NAME) 2>/dev/null || true
