#!/usr/bin/env bash
#
# 07 — build the qcacld-3.0 Wi-Fi driver (wlan.ko) as an out-of-tree module
# against the kernel you built in 02. This is the "build 4" recipe that worked.
#
# The kernel-tree modules (02) and the cnss platform deps (cnss_prealloc/cnss_nl/
# cnss_utils, built by 02 in out/) must exist first — qcacld links against their
# Module.symvers. Do NOT try to compile the cnss deps away (builds 5/6 did that
# and broke; build 4 with the deps present is correct).
#
set -euo pipefail
ROOT="${ROOT:-$HOME/garnet_linux}"
K="$ROOT/kernel_sm7435"
OUT="${OUT:-$ROOT/out}"
WLAN="$ROOT/modules/qcom/opensource/wlan/qcacld-3.0"
KV="${KV:-$(cat "$OUT/include/config/kernel.release")}"

[ -d "$WLAN" ] || { echo "!! qcacld not found at $WLAN — run 00-clone-sources.sh"; exit 1; }
[ -f "$OUT/vmlinux" ] || echo "[=] note: build the kernel + modules (02) before this"

# Profile: parrot GKI with the adrastea (WPSS) Wi-Fi. Overrides that produced the
# known-good wlan.ko (strip pktlog/FTM/debugfs to match what actually loaded):
export CONFIG_CLD_WLAN=m
export MODNAME=wlan
export WLAN_PROFILE=parrot_gki_adrastea
export DEVICE_NAME=parrot
export CONFIG_REMOVE_PKT_LOG=y
export CONFIG_QCA_WIFI_FTM=n
export CONFIG_WLAN_DEBUGFS=n
export CONFIG_WLAN_MWS_INFO_DEBUGFS=n

echo "[*] building qcacld-3.0 wlan.ko against $OUT ($KV)"
make -C "$OUT" M="$WLAN" ARCH=arm64 LLVM=1 LLVM_IAS=1 KCFLAGS="-Wno-error" \
     KBUILD_EXTRA_SYMBOLS="$OUT/Module.symvers" \
     WLAN_ROOT="$WLAN" WLAN_COMMON_ROOT=../qca-wifi-host-cmn \
     WLAN_COMMON_INC="$ROOT/modules/qcom/opensource/wlan/qca-wifi-host-cmn" \
     WLAN_FW_API="$ROOT/modules/qcom/opensource/wlan/fw-api" \
     modules

ls -la "$WLAN/wlan.ko"
echo
echo "[+] wlan.ko built. Stage it into the rootfs:"
echo "    install -Dm644 $WLAN/wlan.ko /lib/modules/$KV/updates/wlan.ko  (on the phone), then depmod -a"
echo "    wlan.ko has NO device-table alias -> udev can't autoload it; garnet-wifi-fw.service modprobes it explicitly."
echo "    REQUIRED runtime file: rootfs/lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini (gEnableFastPath=1)"
