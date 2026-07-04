#!/usr/bin/env bash
#
# 11 — extract the Adreno 710 GPU firmware from YOUR OWN phone.
# Run this ON THE PHONE (booted Arch, as root) — unlike 08, no host needed.
#
# Like the Wi-Fi firmware (08), these blobs are proprietary and NOT shipped in
# this repo; every garnet owner copies them from their own device. They live in
# /vendor/firmware, and "vendor" is a logical partition inside the Android
# `super` partition (sda33) — so we parse super's LP metadata, stitch vendor_a's
# extents with a dm-linear table, and mount it read-only.
#
# What kgsl (downstream gen7-3-0 gpulist) actually requests:
#   a710_sqe.fw      - SQE (ringbuffer processor) firmware
#   gmu_gen70000.bin - GMU (graphics management unit) firmware
#   a710_zap.*       - TZ-signed zap shader (mdt+b0x split and mbn)
#
set -euo pipefail
DEST="${1:-/lib/firmware}"
SUPER="${SUPER:-/dev/disk/by-partlabel/super}"

command -v dmsetup >/dev/null || { echo "!! need dmsetup (pacman -S device-mapper)"; exit 1; }

echo "[*] parsing LP metadata for vendor_a extents"
TABLE="$(python3 - "$SUPER" <<'PYEOF'
import struct, sys
f = open(sys.argv[1], "rb")
f.seek(4096); geo = f.read(4096)
assert struct.unpack("<I", geo[:4])[0] == 0x616C4467, "no LP geometry magic"
meta = 4096 * 3
f.seek(meta); hdr = f.read(256)
assert struct.unpack("<I", hdr[:4])[0] == 0x414C5030, "no LP header magic"
header_size = struct.unpack("<I", hdr[8:12])[0]
tables_size = struct.unpack("<I", hdr[44:48])[0]
po, pn, ps = struct.unpack("<III", hdr[80:92])
eo, en, es = struct.unpack("<III", hdr[92:104])
f.seek(meta + header_size); t = f.read(tables_size)
exts = [struct.unpack("<QIQI", t[eo+i*es:eo+i*es+24]) for i in range(en)]
for i in range(pn):
    p = t[po+i*ps:po+(i+1)*ps]
    name = p[:36].rstrip(b"\0").decode()
    _, first, num, _ = struct.unpack("<IIII", p[36:52])
    if name == "vendor_a":
        off = 0
        for j in range(first, first+num):
            ns, tt, td, _ = exts[j]
            assert tt == 0, "non-linear extent"
            print(f"{off} {ns} linear {sys.argv[1]} {td}")
            off += ns
        break
else:
    sys.exit("vendor_a not found in LP metadata")
PYEOF
)"
echo "$TABLE"

dmsetup create vendor_a --readonly --table "$TABLE"
dmsetup mknodes
MNT=/mnt/garnet-vendor
mkdir -p "$MNT"
trap 'umount "$MNT" 2>/dev/null; dmsetup remove vendor_a 2>/dev/null' EXIT
mount -o ro /dev/mapper/vendor_a "$MNT" 2>/dev/null || mount -t erofs -o ro /dev/mapper/vendor_a "$MNT"

echo "[*] copying a710 firmware to $DEST"
cp -v "$MNT"/firmware/a710_sqe.fw "$MNT"/firmware/gmu_gen70000.bin \
      "$MNT"/firmware/a710_zap.* "$DEST/"
sync
echo "[+] done"
