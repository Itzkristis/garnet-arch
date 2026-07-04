#!/usr/bin/env bash
#
# 01 — apply the 3 load-bearing kernel patches + drop in the 2 new drivers.
# Run after 00-clone-sources.sh. Idempotent (git apply --check gates each).
#
# Patches (why each exists — see ../README.md and the top of each .patch):
#   scripts/basic/cc-wrapper.c   neuter "forbidden warning" -> build with host clang
#   drivers/interconnect/qcom/icc-rpmh.c   force-disable the "disp" bcm-voter
#   drivers/iommu/.../arm-smmu-qcom.c      skip unbound multimedia TBUs (keep anoc/UFS)
#   drivers/gpu/drm/tiny/{Kconfig,Makefile} + drivers/extcon/Makefile  wire new modules
# New drivers (copied in, not patched):
#   drivers/extcon/extcon-fake-vbus.c    fake VBUS extcon -> dwc3-msm role (USB gadget)
#   drivers/gpu/drm/tiny/simpledrm.c     v5.14 simpledrm backported to 5.10 (/dev/dri/card0)
#
set -euo pipefail
ROOT="${ROOT:-$HOME/garnet_linux}"
K="$ROOT/kernel_sm7435"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # github/

[ -f "$K/Makefile" ] || { echo "!! kernel not at $K — run 00-clone-sources.sh first"; exit 1; }

echo "[*] applying kernel patches"
cd "$K"
if git apply --check "$HERE/patches/all-kernel-patches.patch" 2>/dev/null; then
    git apply "$HERE/patches/all-kernel-patches.patch"
    echo "[+] patches applied"
else
    echo "[=] patches already applied (or conflict) — skipping"
fi

echo "[*] installing new driver sources"
cp -v "$HERE/kernel-new-drivers/extcon-fake-vbus.c" "$K/drivers/extcon/extcon-fake-vbus.c"
cp -v "$HERE/kernel-new-drivers/simpledrm.c"        "$K/drivers/gpu/drm/tiny/simpledrm.c"

echo "[+] tree is ready to build (will report as -dirty, expected)"
