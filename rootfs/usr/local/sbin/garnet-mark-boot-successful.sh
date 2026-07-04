#!/usr/bin/env bash
# Mark boot_b "successful" in its GPT entry so the bootloader stops
# decrementing the A/B retry counter on every power-on (nothing else ever
# marks success — Android's boot-control HAL isn't running here, so slot B
# silently counts down 7 boots and falls back to slot A).
#
# Qualcomm slot state lives in GPT entry attribute bits 48..55:
#   48-49 priority · 50 active · 51-53 retry count · 54 successful · 55 unbootable
# `fastboot set_active b` re-arms retries but CLEARS bit 54 — hence this runs
# every boot (idempotent; skips the GPT rewrite when the bits are already set).
set -euo pipefail

PART=$(readlink -f /dev/disk/by-partlabel/boot_b)   # e.g. /dev/sde42
NUM=${PART##*[a-z]}
DISK=${PART%"$NUM"}

FLAGS=$(sgdisk --info="$NUM" "$DISK" | awk '/Attribute flags/{print $3}')
VAL=$((16#$FLAGS))
if (( (VAL >> 54) & 1 && ((VAL >> 51) & 7) == 7 )); then
    echo "boot_b already successful, retry=7 (flags $FLAGS)"
    exit 0
fi

sgdisk --attributes="$NUM":set:51 --attributes="$NUM":set:52 \
       --attributes="$NUM":set:53 --attributes="$NUM":set:54 "$DISK"
echo "boot_b marked successful, retry re-armed (was $FLAGS)"
