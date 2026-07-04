#!/usr/bin/env bash
#
# helper — provide a static aarch64 busybox for the initramfs (05 needs it).
# Prefer distro packages; fall back to the official prebuilt static binary.
#
set -euo pipefail
ROOT="${ROOT:-$HOME/garnet_linux}"
IRFS="${IRFS:-$ROOT/irfs}"
mkdir -p "$IRFS/bin"

if command -v aarch64-linux-gnu-gcc >/dev/null && [ -d /usr/src/busybox ]; then
    echo "[*] build busybox yourself for full control (defconfig + CONFIG_STATIC=y, ARCH=arm64)"
fi

# Official prebuilt static aarch64 busybox:
URL="https://busybox.net/downloads/binaries/1.35.0-aarch64-linux-musl/busybox"
echo "[*] fetching static aarch64 busybox"
curl -L "$URL" -o "$IRFS/bin/busybox"
chmod +x "$IRFS/bin/busybox"

echo "[*] installing applet symlinks"
( cd "$IRFS" && ./bin/busybox --install -s bin 2>/dev/null || \
  for a in sh mount umount insmod mdev find sort gzip cpio cat ls sleep echo mkdir; do
      ln -sf busybox "bin/$a"; done )
echo "[+] busybox ready at $IRFS/bin/busybox"
