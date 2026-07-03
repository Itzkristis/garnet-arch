#!/usr/bin/env bash
#
# Build the downstream LineageOS SM7435 ("parrot") kernel + a standalone
# (fully-flattened) garnet DTB, suitable for a UEFI / mainline-style boot via
# Mu-Silicium (EFI stub / GRUB / systemd-boot) rather than the Android
# bootloader.
#
# Bring-up profile: LTO / CFI / SHADOW_CALL_STACK disabled (fast builds,
# tolerant of a very new host clang, no KMI enforcement needed off-Android).
#
# Usage:
#   ./build_kernel.sh            # build with LLVM/clang (default)
#   TC=gcc ./build_kernel.sh     # fall back to aarch64-linux-gnu- GCC
#   ./build_kernel.sh menuconfig # open menuconfig on the merged config
#
set -euo pipefail

ROOT="${ROOT:-$HOME/garnet_linux}"
K="$ROOT/kernel_sm7435"
DT="$ROOT/devicetrees"
OUT="${OUT:-$ROOT/out}"
JOBS="${JOBS:-$(nproc)}"
TC="${TC:-clang}"

# Target is relative to the dts tree (the kernel's %.dtb rule prepends
# arch/arm64/boot/dts/); the built artifact lands under $OUT at the full path.
DTB_TARGET="vendor/qcom/garnet-sm7435.dtb"
DTB_OUT="arch/arm64/boot/dts/vendor/qcom/garnet-sm7435.dtb"

[ -f "$K/Makefile" ] || { echo "!! kernel tree not found at $K"; exit 1; }
[ -d "$DT/qcom" ]    || { echo "!! devicetrees not found at $DT"; exit 1; }

export ARCH=arm64
# Very new host clang on a 5.10 tree: don't fail the build on new warnings.
export KCFLAGS="${KCFLAGS:-} -Wno-error"

if [ "$TC" = "gcc" ]; then
    export CROSS_COMPILE=aarch64-linux-gnu-
    MK=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
    echo "[*] toolchain: GCC ($(aarch64-linux-gnu-gcc --version | head -1))"
else
    export LLVM=1 LLVM_IAS=1
    MK=(ARCH=arm64 LLVM=1 LLVM_IAS=1)
    echo "[*] toolchain: LLVM ($(clang --version | head -1))"
fi

cd "$K"

# The kernel ships arch/arm64/boot/dts/vendor as a symlink pointing into the
# AOSP source layout. Repoint it at our cloned devicetrees repo so `dtbs`
# and our explicit garnet target resolve.
ln -sfn "$DT" arch/arm64/boot/dts/vendor
echo "[+] dts/vendor -> $(readlink arch/arm64/boot/dts/vendor)"

mkdir -p "$OUT"

# --- merged defconfig: GKI base + parrot SoC + garnet device fragments ------
# Base fragments: GKI + parrot SoC + garnet device. Optionally add the
# self-contained bring-up fragment (essential platform drivers forced =y so the
# kernel reaches serial console + UFS root without Android's vendor_dlkm/
# initramfs). Enable with BRINGUP=1.
FRAGMENTS=(
    arch/arm64/configs/gki_defconfig
    arch/arm64/configs/vendor/parrot_GKI.config
    arch/arm64/configs/vendor/garnet_GKI.config
)
if [ "${BRINGUP:-0}" = "1" ]; then
    echo "[*] BRINGUP=1: including garnet_bringup.config (platform drivers -> built-in)"
    FRAGMENTS+=("$ROOT/garnet_bringup.config")
fi

echo "[*] merging defconfig (${#FRAGMENTS[@]} fragments)"
ARCH=arm64 ./scripts/kconfig/merge_config.sh -O "$OUT" "${FRAGMENTS[@]}"

# --- bring-up overrides -----------------------------------------------------
echo "[*] applying bring-up config overrides"
./scripts/config --file "$OUT/.config" \
    -d LTO_CLANG_THIN -d LTO_CLANG_FULL -e LTO_NONE \
    -d CFI_CLANG \
    -d SHADOW_CALL_STACK \
    -d BUILD_ARM64_DT_OVERLAY \
    -d MODULE_SIG -d MODULE_SIG_ALL \
    -e IKCONFIG -e IKCONFIG_PROC

make -s O="$OUT" "${MK[@]}" olddefconfig

if [ "${1:-}" = "menuconfig" ]; then
    make O="$OUT" "${MK[@]}" menuconfig
    exit 0
fi

# --- build ------------------------------------------------------------------
echo "[*] building Image (-j$JOBS)"
make O="$OUT" "${MK[@]}" -j"$JOBS" Image

echo "[*] building garnet DTB"
make O="$OUT" "${MK[@]}" -j"$JOBS" "$DTB_TARGET"

echo
echo "=== artifacts ==="
ls -la "$OUT/arch/arm64/boot/Image" "$OUT/$DTB_OUT"
