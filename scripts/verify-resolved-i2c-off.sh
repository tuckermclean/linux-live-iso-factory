#!/bin/sh
# Guards the DDC-trap invariant (docs/kernel-tiers.md, AGENTS.md's DDC-trap
# note): the five FB_*_I2C/FB_*_DDC bools forced off in configs/kernel.config
# exist solely to keep CONFIG_I2C from being escalated to =y by
# `olddefconfig` (which would pull i2c-core into bzImage as a silent Tier-0
# growth). scripts/tests/verify-legacy-fbdev-config.sh only checks the
# pinned, pre-build config, which has no CONFIG_I2C line at all by design and
# can never catch an escalation.
#
# This script checks a *resolved* post-olddefconfig .config instead — the
# kernel ebuild's src_install copies its final .config back to
# configs/kernel.config (bind-mounted at /configs, see CONFIGS_MOUNT in
# Makefile) once the kernel package actually builds. Run it against that
# file after `make build-packages` in CI, or against any doctored .config
# for local testing.
set -u
cfg="${1:-configs/kernel.config}"

if [ ! -f "$cfg" ]; then
    echo "FAIL: $cfg not found"
    exit 1
fi

if grep -q "^CONFIG_I2C=y$" "$cfg"; then
    echo "FAIL: CONFIG_I2C=y in $cfg (a DDC trap escalated I2C into bzImage)"
    exit 1
fi

echo "PASS: CONFIG_I2C not =y in $cfg"
