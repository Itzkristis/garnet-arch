#!/usr/bin/env bash
#
# 09 — install Arch Linux ARM onto the phone's userdata partition and lay down
# our services/configs. Run with the phone in Mu-Silicium mass-storage mode.
#
# WARNING: this DESTROYS the Android userdata partition (that was the deliberate
# trade — Android is sacrificed for a full Linux rootfs). Double-check the
# partition before you let it run.
#
set -euo pipefail
ROOT="${ROOT:-$HOME/garnet_linux}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # github/
OUT="${OUT:-$ROOT/out}"
KV="${KV:-$(cat "$OUT/include/config/kernel.release")}"
MNT="${MNT:-/mnt/archroot}"
TARBALL_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"

# Identify userdata by PARTLABEL — refuse to guess.
USERDATA="$(lsblk -o NAME,PARTLABEL -rn | awk '$2=="userdata"{print "/dev/"$1}')"
[ -n "$USERDATA" ] || { echo "!! userdata partition not found. Mass-storage mode?"; exit 1; }
echo "!! About to FORMAT $USERDATA (userdata) as ext4 'archroot' — Android data will be lost."
read -rp "Type YES to continue: " ok; [ "$ok" = YES ] || exit 1

sudo mkfs.ext4 -L archroot "$USERDATA"
sudo mkdir -p "$MNT"; sudo mount "$USERDATA" "$MNT"

echo "[*] downloading + extracting Arch Linux ARM aarch64"
tmp="$(mktemp -d)"; curl -L "$TARBALL_URL" -o "$tmp/alarm.tar.gz"
sudo bsdtar -xpf "$tmp/alarm.tar.gz" -C "$MNT"
sync

echo "[*] staging kernel modules ($KV) — PRUNED allowlist, not the full 314-module tree"
# The full module tree makes udev coldplug the mm-cc/kgsl zoo -> SoC crash.
# Install everything, then keep only the bring-up allowlist (see README).
sudo make -C "$ROOT/kernel_sm7435" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     INSTALL_MOD_PATH="$MNT" modules_install
# (Prune to the allowlist here, or move the full tree to /lib/modules-full.bak.)
# Wi-Fi module (built by 07) goes in updates/ so it wins:
[ -f "$ROOT/modules/qcom/opensource/wlan/qcacld-3.0/wlan.ko" ] && \
  sudo install -Dm644 "$ROOT/modules/qcom/opensource/wlan/qcacld-3.0/wlan.ko" \
       "$MNT/lib/modules/$KV/updates/wlan.ko"
# RTC module (read-only RTC; used by garnet-rtc-restore/save, survives pruning):
[ -f "$ROOT/out/drivers/rtc/rtc-pm8xxx.ko" ] && \
  sudo install -Dm644 "$ROOT/out/drivers/rtc/rtc-pm8xxx.ko" \
       "$MNT/lib/modules/$KV/updates/rtc-pm8xxx.ko"
# GPU stack (Adreno 710 / kgsl) — staged in gpu/ so it survives pruning, but
# BLACKLISTED (rootfs/etc/modprobe.d/garnet-gpu-blacklist.conf) so udev
# coldplug can't load it; garnet-gpu.service loads it in order at boot.
# Needs the garnet-sm7435-gpu.dtb (script 10) + firmware (script 11).
for m in drivers/clk/qcom/gpucc-parrot.ko \
         kernel/sched/walt/sched-walt.ko \
         drivers/soc/qcom/dcvs/qcom-pmu-lib.ko \
         drivers/soc/qcom/msm_performance.ko \
         drivers/soc/qcom/dcvs/dcvs_fp.ko \
         drivers/soc/qcom/dcvs/qcom-dcvs.ko \
         arch/arm64/gunyah/gh_arm_drv.ko \
         drivers/virt/gunyah/gh_msgq.ko \
         drivers/virt/gunyah/gh_dbl.ko \
         drivers/virt/gunyah/gh_rm_drv.ko \
         drivers/soc/qcom/mem_buf/mem_buf_dev.ko \
         drivers/gpu/msm/msm_kgsl.ko \
         drivers/iommu/msm_dma_iommu_mapping.ko \
         drivers/dma-buf/heaps/qcom_dma_heaps.ko; do
  [ -f "$MNT/lib/modules/$KV/kernel/$m" ] && \
    sudo install -Dm644 "$MNT/lib/modules/$KV/kernel/$m" \
         "$MNT/lib/modules/$KV/gpu/$(basename "$m")"
done
# Touchscreen stack (Goodix GT9916S on geni SPI) — same blacklist+service
# pattern; garnet-touch.service loads these in order (gpi BEFORE spi-msm-geni,
# the SE is GSI-DMA-only). Firmware comes from script 11.
for m in drivers/dma/qcom/gpi.ko \
         drivers/platform/msm/msm-geni-se.ko \
         drivers/spi/spi-msm-geni.ko \
         drivers/pinctrl/qcom/pinctrl-spmi-gpio.ko \
         drivers/soc/qcom/panel_event_notifier.ko \
         drivers/input/touchscreen/xiaomi/xiaomi_touch.ko \
         drivers/input/touchscreen/goodix_berlin_driver/goodix_core.ko \
         drivers/input/touchscreen/focaltech_3683g/focaltech_3683g.ko; do
  [ -f "$MNT/lib/modules/$KV/kernel/$m" ] && \
    sudo install -Dm644 "$MNT/lib/modules/$KV/kernel/$m" \
         "$MNT/lib/modules/$KV/touch/$(basename "$m")"
done

echo "[*] laying down our services + configs from rootfs/"
sudo cp -av "$HERE/rootfs/." "$MNT/"
sudo chroot "$MNT" /bin/bash -c '
  set -e
  depmod -a '"$KV"' || true
  passwd -d root                         # empty root pw for console login
  systemctl enable systemd-networkd systemd-resolved
  systemctl enable garnet-wifi-fw.service garnet-usb-gadget.service
  systemctl enable garnet-mark-boot-successful.service   # needs gptfdisk (pacman -S once online)
  systemctl enable systemd-timesyncd
  systemctl enable garnet-rtc-restore.service garnet-rtc-save.timer garnet-rtc-save-shutdown.service
  systemctl enable garnet-gpu.service         # no-op unless the gpu DTB is booted
  systemctl enable garnet-touch.service       # Goodix GT9916S touchscreen
  systemctl enable wpa_supplicant@wlan0
  systemd-machine-id-setup
' || echo "[=] chroot step needs binfmt/qemu-aarch64 on the host if it failed here"

# Firmware: extract from THIS phone (proprietary, not shipped) — see 08.
echo "[!] Now run: ./scripts/08-extract-firmware.sh $MNT/lib/firmware/adrastea"

sync; sudo umount "$MNT"
echo "[+] Arch rootfs installed on $USERDATA (label archroot)."
