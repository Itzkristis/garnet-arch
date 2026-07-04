#!/usr/bin/env bash
#
# helper — build grubaa64.efi (the arm64 EFI GRUB that Mu-Silicium chainloads as
# BOOTAA64.EFI). A standalone image with the modules GRUB needs baked in, so it
# runs off the ESP with no external /boot/grub. The menu itself is grub.cfg on
# the ESP (config/grub.cfg.esp), NOT embedded, so you can edit entries in place.
#
set -euo pipefail
ROOT="${ROOT:-$HOME/garnet_linux}"
OUTEFI="${1:-$ROOT/dist/grubaa64.efi}"

command -v grub-mkimage >/dev/null || command -v grub-mkstandalone >/dev/null || {
    echo "!! need GRUB arm64-efi tools (Debian/Ubuntu: apt install grub-efi-arm64-bin grub-common)"; exit 1; }

# Minimal embedded config: look for /grub.cfg at the image's prefix (the ESP root).
emb="$(mktemp)"; printf 'search --file --set=root /grub.cfg\nset prefix=($root)/\nconfigfile /grub.cfg\n' > "$emb"

grub-mkimage -O arm64-efi -o "$OUTEFI" -p / -c "$emb" \
    part_gpt part_msdos fat ext2 normal linux configfile echo test search \
    search_fs_file search_fs_uuid search_label loadenv gzio all_video \
    efi_gop efinet font gfxterm terminal ls cat help reboot halt

rm -f "$emb"
echo "[+] wrote $OUTEFI  (copy to ESP as EFI/BOOT/BOOTAA64.EFI via 06-deploy-esp.sh)"
