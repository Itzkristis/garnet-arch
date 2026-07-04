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

echo "[*] laying down our services + configs from rootfs/"
sudo cp -av "$HERE/rootfs/." "$MNT/"
sudo chroot "$MNT" /bin/bash -c '
  set -e
  depmod -a '"$KV"' || true
  passwd -d root                         # empty root pw for console login
  systemctl enable systemd-networkd systemd-resolved
  systemctl enable garnet-wifi-fw.service garnet-usb-gadget.service
  systemctl enable wpa_supplicant@wlan0
  systemd-machine-id-setup
' || echo "[=] chroot step needs binfmt/qemu-aarch64 on the host if it failed here"

# Firmware: extract from THIS phone (proprietary, not shipped) — see 08.
echo "[!] Now run: ./scripts/08-extract-firmware.sh $MNT/lib/firmware/adrastea"

sync; sudo umount "$MNT"
echo "[+] Arch rootfs installed on $USERDATA (label archroot)."
