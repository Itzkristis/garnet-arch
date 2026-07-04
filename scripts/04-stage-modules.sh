#!/usr/bin/env bash
#
# 04 — compute the 43-module bring-up closure + topological load order and stage
# it into an initramfs tree. This is the heart of the storage/switch initramfs.
#
# The set was grown one blocker at a time (see README "The UFS onion"); the
# leaves below pull in everything needed for: UFS storage, SMMU, gcc clocks,
# rpmh regulators, cpufreq, qfprom + SPMI nvmem (the invisible fw_devlink
# blocker), and interconnect. The exact resulting order is checked in as
# ../initramfs/load-order.list; this script regenerates it from your build.
#
# busybox modprobe does NOT resolve modules.dep, so /init insmods these in
# tsort order (see ../initramfs/init-*.sh).
#
set -euo pipefail
ROOT="${ROOT:-$HOME/garnet_linux}"
OUT="${OUT:-$ROOT/out}"
KV="${KV:-$(cat "$OUT/include/config/kernel.release")}"
STAGE="${STAGE:-$ROOT/modstage}"          # temp modules_install target
IRFS="${IRFS:-$ROOT/irfs}"                # initramfs tree to populate

# Leaf modules — the closure of their deps is the shipped set.
LEAVES=(
  ufs_qcom arm_smmu phy-qcom-ufs-qmp-v4-parrot gcc-parrot clk-rpmh
  pinctrl-parrot rpmhpd qcom_rpmh cmd-db smem qcom-scm qnoc-parrot
  icc-rpmh icc-bcm-voter rpmh-regulator qcom-cpufreq-hw nvmem_qfprom
  regmap-spmi qti-regmap-debugfs spmi-pmic-arb qcom-spmi-pmic
  nvmem_qcom-spmi-sdam
)

echo "[*] modules_install -> $STAGE (runs depmod)"
make -C "$ROOT/kernel_sm7435" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     INSTALL_MOD_PATH="$STAGE" modules_install

echo "[*] resolving dependency closure of ${#LEAVES[@]} leaves"
mapfile -t CLOSURE < <(
  for m in "${LEAVES[@]}"; do
    modprobe -d "$STAGE" -S "$KV" --show-depends "$m" 2>/dev/null
  done | awk '/^insmod/{print $2}' | sort -u
)

echo "[*] copying $( { echo "${CLOSURE[@]}"; } | wc -w ) modules into $IRFS"
mkdir -p "$IRFS/lib/modules/$KV"
for ko in "${CLOSURE[@]}"; do
  rel="${ko#"$STAGE"/lib/modules/"$KV"/}"
  mkdir -p "$IRFS/lib/modules/$KV/$(dirname "$rel")"
  cp "$ko" "$IRFS/lib/modules/$KV/$rel"
done
depmod -b "$IRFS" -F "$OUT/System.map" "$KV"

echo "[*] generating load-order.list (tsort, qcom_hwspinlock forced first)"
LO="$IRFS/lib/modules/$KV/load-order.list"
{
  echo kernel/drivers/hwspinlock/qcom_hwspinlock.ko
  awk '{for(i=2;i<=NF;i++)print $i" "$1; print $1" "$1}' \
      "$IRFS/lib/modules/$KV/modules.dep" 2>/dev/null | tsort 2>/dev/null | tac
} | awk '!seen[$0]++' > "$LO" || true
echo "[+] staged into $IRFS ; load order in $LO"
echo "    (reference known-good order: ../initramfs/load-order.list)"
