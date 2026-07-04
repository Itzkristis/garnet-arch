#!/usr/bin/env bash
#
# 08 — extract the WPSS (Wi-Fi co-processor) firmware from YOUR OWN phone.
#
# IMPORTANT: this firmware is proprietary Qualcomm/Xiaomi and is NOT redistributed
# in this repo. Every garnet owner extracts it from their own device — it already
# ships in the phone's firmware partitions and SURVIVES a LineageOS re-flash
# (firmware partitions are not wiped by a userdata wipe). This is the correct and
# only lawful way to obtain it.
#
# Source: the modem partition's image/adrastea/ directory (wpss.mdt + wpss.bNN
# segments + bd_*.bin board-data files, ~64 MB). Destination: the Arch rootfs at
# /lib/firmware/adrastea/. icnss2 loads it to reach "WLAN FW is ready".
#
# Prereq: phone in Mu-Silicium USB mass-storage mode (whole UFS visible on host).
#
set -euo pipefail
DEST="${1:?usage: 08-extract-firmware.sh <dest dir, e.g. /mnt/archroot/lib/firmware/adrastea>}"
MNT="${MNT:-/mnt/garnet-modem}"

# Find the active modem partition by PARTLABEL (modem_a or modem_b — match your slot).
MODEM="$(lsblk -o NAME,PARTLABEL -rn | awk '$2 ~ /^modem_[ab]$/{print "/dev/"$1}' | head -1)"
[ -n "$MODEM" ] || { echo "!! modem partition not found. Phone in mass-storage mode?"; exit 1; }
echo "[+] modem partition = $MODEM"

sudo mkdir -p "$MNT"
# Modem image is typically EROFS or ext4 (read-only). Try both.
sudo mount -o ro "$MODEM" "$MNT" 2>/dev/null || sudo mount -t erofs -o ro "$MODEM" "$MNT"

SRC="$(find "$MNT" -type d -name adrastea 2>/dev/null | head -1)"
[ -n "$SRC" ] || { echo "!! image/adrastea/ not found under $MNT"; sudo umount "$MNT"; exit 1; }
echo "[+] found firmware at $SRC"

sudo mkdir -p "$DEST"
sudo cp -av "$SRC/." "$DEST/"
sync
sudo umount "$MNT"
echo "[+] adrastea firmware copied to $DEST ($(sudo du -sh "$DEST" | cut -f1))"
echo "    (Later, the GPU work needs Adreno SQE/GMU fw + zap shader extracted the same way.)"
