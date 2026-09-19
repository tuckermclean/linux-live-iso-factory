#!/bin/sh
# Intent check on configs/kernel.config (NOT the resolved .config — the CI build
# + boot-test are authoritative; this catches a dropped line early).
set -u
cfg=configs/kernel.config
fails=0

want_m="FB_CIRRUS FB_PM2 FB_PM3 FB_CYBER2000 FB_VGA16 FB_HGA FB_NVIDIA \
FB_RIVA FB_I740 FB_MATROX FB_RADEON FB_ATY128 FB_ATY FB_S3 FB_SAVAGE FB_SIS \
FB_NEOMAGIC FB_KYRO FB_3DFX FB_VOODOO1 FB_VT8623 FB_TRIDENT FB_ARK FB_SM712 \
FB_GEODE_LX FB_GEODE_GX FB_GEODE_GX1"
for s in $want_m; do
    grep -q "^CONFIG_$s=m$" "$cfg" || { echo "FAIL: CONFIG_$s is not =m"; fails=$((fails+1)); }
done

# FB_GEODE is a bool menu gate with no object file (obj-$(CONFIG_FB_GEODE) is
# empty) — =y here does not add anything to bzImage, unlike the =m drivers.
grep -q "^CONFIG_FB_GEODE=y$" "$cfg" || { echo "FAIL: CONFIG_FB_GEODE gate is not =y"; fails=$((fails+1)); }

# Chip sub-options: atyfb/matroxfb/sisfb build with no chip support at their
# Kconfig defaults, so the top-level symbol alone would ship a useless .ko.
want_y="FB_MATROX_MILLENIUM FB_MATROX_MYSTIQUE FB_MATROX_G FB_ATY_CT FB_ATY_GX \
FB_SIS_300 FB_SIS_315"
for s in $want_y; do
    grep -q "^CONFIG_$s=y$" "$cfg" || { echo "FAIL: CONFIG_$s is not =y"; fails=$((fails+1)); }
done
grep -q "^CONFIG_FB_MATROX_I2C=m$" "$cfg" || { echo "FAIL: CONFIG_FB_MATROX_I2C is not =m"; fails=$((fails+1)); }

# DDC traps: these are `bool`s whose default-y would escalate the tristate
# FB_DDC to =y, which selects CONFIG_I2C=y — i2c-core built into bzImage, a
# silent Tier-0 growth. Force off, and never "fix" this by turning them on.
want_off="FB_RADEON_I2C FB_3DFX_I2C FB_CYBER2000_DDC FB_NVIDIA_I2C FB_SAVAGE_I2C"
for s in $want_off; do
    grep -q "^# CONFIG_$s is not set$" "$cfg" || { echo "FAIL: CONFIG_$s must be '# CONFIG_$s is not set'"; fails=$((fails+1)); }
done

# The actual invariant the five DDC lines above exist to protect — I2C must
# never be promoted to a built-in — is checked against the *resolved*
# post-olddefconfig .config in the build job (scripts/verify-resolved-i2c-off.sh),
# not here: configs/kernel.config has no CONFIG_I2C line at all (by design, we
# don't hand-write symbols olddefconfig derives), so a grep against it can
# never fire.

# Mechanism-excluded and scope-excluded symbols must stay off. FB_ASILIANT and
# FB_IMSTT are bool-only (depends on FB = y) — there is no =m form, so the
# only way to enable them is a Tier-0 decision this change does not make.
want_excluded="FB_ASILIANT FB_IMSTT FB_VIRTUAL FB_ARC FB_N411 FB_METRONOME \
FB_IBM_GXT4500 FB_CARMINE FB_MB862XX FB_OPENCORES FB_S1D13XXX FB_UDL FB_SMSCUFX"
for s in $want_excluded; do
    grep -q "^# CONFIG_$s is not set$" "$cfg" || { echo "FAIL: CONFIG_$s must stay '# CONFIG_$s is not set'"; fails=$((fails+1)); }
done

# Covenant: never bake firmware blobs.
grep -q "^CONFIG_EXTRA_FIRMWARE=" "$cfg" && { echo "FAIL: CONFIG_EXTRA_FIRMWARE must not be set"; fails=$((fails+1)); }

[ "$fails" -eq 0 ] && echo "ALL PASS" || exit 1
