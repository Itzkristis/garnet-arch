#!/usr/bin/env bash
#
# 00 — clone the upstream sources this project builds on.
# Everything is LineageOS lineage-23.2 (Android 5.10.252 GKI) for the
# Xiaomi SM7435 "parrot" / garnet, plus the Mu-Silicium UEFI firmware.
#
# Layout produced (matches the scripts' expectations):
#   $ROOT/kernel_sm7435   kernel source (gets patched by 01-apply-patches.sh)
#   $ROOT/devicetrees     device trees (symlinked in as dts/vendor at build)
#   $ROOT/modules         out-of-tree vendor modules (incl. qcacld-3.0 Wi-Fi)
#   $ROOT/Mu-Silicium     UEFI firmware / bootloader project
#
set -euo pipefail
ROOT="${ROOT:-$HOME/garnet_linux}"
BR="${BR:-lineage-23.2}"
mkdir -p "$ROOT"; cd "$ROOT"

clone() { [ -d "$2/.git" ] || git clone --depth=1 -b "$BR" "$1" "$2"; }

clone https://github.com/LineageOS/android_kernel_xiaomi_sm7435            kernel_sm7435
clone https://github.com/LineageOS/android_kernel_xiaomi_sm7435-devicetrees devicetrees
clone https://github.com/LineageOS/android_kernel_xiaomi_sm7435-modules     modules

# Mu-Silicium tracks its own default branch.
[ -d Mu-Silicium/.git ] || git clone --recursive https://github.com/Project-Silicium/Mu-Silicium

echo "[+] sources cloned under $ROOT"
