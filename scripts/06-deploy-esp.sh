#!/usr/bin/env bash
#
# 06 — deploy boot artifacts to the phone's GARNET-ESP partition.
#
# Put the phone into Mu-Silicium's USB *mass storage* mode (select on the phone).
# The whole UFS then appears on the host; GARNET-ESP shows up by PARTLABEL.
# NOTE: UFS logical block = 4096, so the ESP must be formatted
#   mkfs.vfat -F 32 -S 4096   (a 512-byte-sector FAT boots on the phone but is
# not host-mountable over mass storage — "logical sector size too small").
#
# The device letter changes between plug-ins — always re-check by PARTLABEL.
#
set -euo pipefail
ROOT="${ROOT:-$HOME/garnet_linux}"
DIST="$ROOT/dist"
MNT="${MNT:-/mnt/garnet-esp}"

ESP="$(lsblk -o NAME,PARTLABEL -rn | awk '$2=="GARNET-ESP"{print "/dev/"$1}')"
[ -n "$ESP" ] || { echo "!! GARNET-ESP not found. Is the phone in Mu-Silicium mass-storage mode?"; exit 1; }
echo "[+] GARNET-ESP = $ESP"

sudo mkdir -p "$MNT"
sudo mount "$ESP" "$MNT"
sudo mkdir -p "$MNT/EFI/BOOT" "$MNT/logs"

sudo cp -v "$DIST/grubaa64.efi"                "$MNT/EFI/BOOT/BOOTAA64.EFI"
sudo cp -v "$DIST/Image-vt"                    "$MNT/Image"
sudo cp -v "$DIST/garnet-sm7435.dtb"           "$MNT/garnet-sm7435.dtb"
sudo cp -v "$DIST/garnet-sm7435-nommgdsc.dtb"  "$MNT/garnet-sm7435-nommgdsc.dtb"
sudo cp -v "$DIST/grub.cfg"                    "$MNT/grub.cfg"
# ship whichever initramfs images your grub.cfg entries reference:
for f in initramfs-switch.gz initramfs.gz initramfs-arch.gz; do
    [ -f "$DIST/$f" ] && sudo cp -v "$DIST/$f" "$MNT/$f"
done

sync
sudo umount "$MNT"
echo "[+] ESP updated. Reboot the phone; pick the GRUB entry with the volume keys."
echo "    Read boot logs back from $ESP:/logs/ over mass storage."
