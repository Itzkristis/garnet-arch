#!/usr/bin/env bash
#
# 03 — produce garnet-sm7435-nommgdsc.dtb: the reset-fix DTB.
#
# THE FIX for the ~11 s PMIC hard reset. When gcc-parrot registers, it unblocks
# devm_clk_get("ahb_clk") for the 7 enabled cam_cc/disp_cc/gpu_cc/video_cc
# qcom,gdsc nodes. gdsc-regulator.ko's probe then raw read-modify-writes the
# GDSCR (clearing HW_CONTROL|SW_OVERRIDE) and proxy-enables the *live* efifb
# display GDSC -> MDSS domain collapses -> NoC hang -> secure watchdog -> PMIC
# cold reset (DDR lost, no oops). Disabling those 7 nodes at the DTB level is the
# safe knob. GCC GDSCs (incl. gcc_ufs_phy_gdsc!) + hlos1_vote TBU GDSCs are kept.
#
# NOTE: re-enabling gpu_cc's GDSCs here is a prerequisite for the future GPU
# (turnip-on-KGSL) work — see README "Roadmap".
#
set -euo pipefail
ROOT="${ROOT:-$HOME/garnet_linux}"
OUT="${OUT:-$ROOT/out}"
SRC="${1:-$OUT/arch/arm64/boot/dts/vendor/qcom/garnet-sm7435.dtb}"
DST="${2:-$ROOT/dist/garnet-sm7435-nommgdsc.dtb}"

command -v fdtput >/dev/null || { echo "!! need fdtput (apt install device-tree-compiler)"; exit 1; }
[ -f "$SRC" ] || { echo "!! source DTB not found: $SRC (build it first)"; exit 1; }

mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"

# The 7 multimedia GDSC nodes (by unit address) to disable.
for addr in adf4004 af09000 af0b000 3d99108 3d9905c aaf81a4 aaf5004; do
    fdtput -t s "$DST" "/soc/qcom,gdsc@$addr" status disabled
done

echo "[+] wrote $DST (7 mm GDSC nodes disabled; original untouched)"
