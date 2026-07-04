#!/usr/bin/env bash
#
# 02 — build the kernel Image + DTB (via build_kernel.sh) then the full module
# set. The GKI kernel ships the whole Qualcomm platform as modules, so the
# UFS/Wi-Fi/USB bring-up is 90% choosing and ordering .ko files, not Image work.
#
# Because MODVERSIONS=y + LOCALVERSION_AUTO=y, modules must match the exact
# Image. We only add =m symbols, so out/Image stays byte-identical to the
# flashed one and never needs re-flashing when only modules change.
#
set -euo pipefail
ROOT="${ROOT:-$HOME/garnet_linux}"
K="$ROOT/kernel_sm7435"
OUT="${OUT:-$ROOT/out}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Image + DTB (this script also merges the defconfig fragments + bring-up overrides).
"$HERE/build_kernel.sh"

echo "[*] building all modules (~10 min) -> 314 .ko"
cd "$K"
ln -sfn ../devicetrees arch/arm64/boot/dts/vendor
make O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 KCFLAGS="-Wno-error" -j"$(nproc)" modules

echo
echo "[+] artifacts:"
echo "    Image : $OUT/arch/arm64/boot/Image"
echo "    DTB   : $OUT/arch/arm64/boot/dts/vendor/qcom/garnet-sm7435.dtb"
echo "    .ko   : $(find "$OUT" -name '*.ko' | wc -l) modules under $OUT"
echo
echo "Rebuild ONE module after editing it: just re-run the same 'make ... modules'"
echo "line — only the changed .o recompiles. Do NOT use single-.ko targets with"
echo "MODVERSIONS (cross-module symbol CRCs come out wrong)."
