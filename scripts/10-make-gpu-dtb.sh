#!/usr/bin/env bash
#
# 10 — produce garnet-sm7435-gpu.dtb: the nommgdsc reset-fix DTB, but with the
# two GPU GDSC nodes left ENABLED so kgsl (Adreno 710) can power the GPU.
#
# Differences from 03-make-nommgdsc-dtb.sh:
#   * gpu_cc_cx_gdsc (@3d99108) and gpu_cc_gx_gdsc (@3d9905c) stay enabled.
#     Safe: unlike the display GDSC that caused the ~11 s PMIC reset, the GPU
#     domain is OFF at boot and these nodes have no proxy-consumer-enable, so
#     gdsc-regulator's probe just clears HW_CONTROL/SW_OVERRIDE and registers
#     them as regulators (verified live 2026-07-04, two boots, no reset).
#   * /memory gets ddr_device_type = 7 (LPDDR4X). Android's bootloader injects
#     this at runtime; our GRUB devicetree path does not, and without it kgsl's
#     adreno_device_probe dies with "Unable to read qcom,bus-freq" (-22) while
#     resolving the qcom,bus-freq-ddr7/-ddr8 power-level properties. The value
#     comes from the XBL boot log ("LP4 DDR detected" — logfs partition).
#
set -euo pipefail
ROOT="${ROOT:-$HOME/garnet_linux}"
OUT="${OUT:-$ROOT/out}"
SRC="${1:-$OUT/arch/arm64/boot/dts/vendor/qcom/garnet-sm7435.dtb}"
DST="${2:-$ROOT/dist/garnet-sm7435-gpu.dtb}"

command -v fdtput >/dev/null || { echo "!! need fdtput (pacman -S dtc / apt install device-tree-compiler)"; exit 1; }
[ -f "$SRC" ] || { echo "!! source DTB not found: $SRC (build it first)"; exit 1; }

mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"

# Disable the 5 non-GPU multimedia GDSC nodes (cam_cc/disp_cc/video_cc).
for addr in adf4004 af09000 af0b000 aaf81a4 aaf5004; do
    fdtput -t s "$DST" "/soc/qcom,gdsc@$addr" status disabled
done

# DDR type for kgsl's per-DDR bus tables (7 = LPDDR4X, 8 = LPDDR5).
fdtput -t u "$DST" /memory ddr_device_type 7

echo "[+] wrote $DST (GPU GDSCs enabled, 5 other mm GDSCs disabled, ddr_device_type=7)"
