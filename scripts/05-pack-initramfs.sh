#!/usr/bin/env bash
#
# 05 — pack an initramfs tree (from 04-stage-modules.sh, plus a busybox rootfs
# and one of the ../initramfs/init-*.sh scripts as /init) into a cpio.gz.
#
# Which /init:
#   init-storage.sh  bring UFS up in RAM, log to ESP:/logs, heartbeat every 20 s
#                    (the diagnostic milestone-2 image; stays in RAM, no rootfs)
#   init-switch.sh   bring-up chain -> mount ext4 'archroot' -> devtmpfs ->
#                    exec switch_root into systemd (the daily-driver image)
#
set -euo pipefail
ROOT="${ROOT:-$HOME/garnet_linux}"
IRFS="${IRFS:-$ROOT/irfs}"
INIT="${1:?usage: 05-pack-initramfs.sh <init-storage.sh|init-switch.sh> [out.gz]}"
OUTGZ="${2:-$ROOT/dist/initramfs.gz}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

[ -d "$IRFS/lib/modules" ] || { echo "!! run 04-stage-modules.sh first"; exit 1; }

# busybox: a static aarch64 busybox must exist in the tree. If you don't have one
# staged yet, drop a static aarch64 busybox at $IRFS/bin/busybox and symlink the
# applets (busybox --install -s). This repo assumes $IRFS already has a rootfs.
[ -x "$IRFS/bin/busybox" ] || echo "!! warning: no $IRFS/bin/busybox — add a static aarch64 busybox"

cp "$HERE/initramfs/$(basename "$INIT")" "$IRFS/init"
chmod +x "$IRFS/init"

echo "[*] packing $IRFS -> $OUTGZ"
( cd "$IRFS" && find . -print0 | sort -z | cpio --null -o -H newc --quiet ) | gzip -9 > "$OUTGZ"
echo "[+] wrote $OUTGZ ($(du -h "$OUTGZ" | cut -f1))"
