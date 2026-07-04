# Prerequisites — before you start

This repo reproduces a Linux bring-up on **your own** Xiaomi garnet. Nothing here
is device-locked, but you supply the hardware, the firmware (extracted from your
own phone), and an unlocked bootloader.

## Hardware / device
- **Xiaomi Redmi Note 13 Pro 5G or Poco X6 5G — codename `garnet`** (SoC SM7435
  "parrot"). Other SoCs/devices will not work without their own DTB + drivers.
- **Bootloader unlocked** (Xiaomi unlock; you accept the data wipe + warranty
  implications). Find your fastboot serial with `fastboot devices` — it is
  per-device; wherever the docs show a specific serial, substitute yours.
- A **USB cable** to the PC. For USB *host mode* (keyboard) you additionally need
  a **powered OTG hub / Y-cable** — the phone can't source 5 V VBUS.
- ⚠️ **This destroys the Android userdata partition.** Milestone 3 onward
  reformats userdata for the Linux rootfs. Back up anything you care about.

## Firmware — you extract it, this repo does not ship it
The WPSS Wi-Fi firmware (and later the GPU firmware) is proprietary
Qualcomm/Xiaomi and is **not redistributable**. It already lives in your phone's
firmware partitions and survives a LineageOS re-flash. `scripts/08-extract-firmware.sh`
pulls it from your own device over Mu-Silicium mass-storage mode.

## Firmware/bootloader layer
- **Mu-Silicium UEFI** installed on a boot slot (this project uses **slot B**,
  `boot_b`). Build/flash per the Mu-Silicium project
  (`github.com/Project-Silicium/Mu-Silicium`). GRUB (`grubaa64.efi`) is
  chainloaded as `BOOTAA64.EFI` from the ESP; build it with
  `scripts/build-grub-efi.sh`.
- A **GARNET-ESP** FAT partition formatted `mkfs.vfat -F 32 -S 4096` (UFS logical
  block is 4096; a 512-byte-sector FAT boots but isn't host-mountable over mass
  storage).

## Build host (Linux)
- `clang` / `llvm` (recent is fine — a patch neutralizes the tree's warning
  gate), optional `aarch64-linux-gnu-` GCC.
- `device-tree-compiler` (`fdtput`), `cpio`, `gzip`, `curl`, `bsdtar` (libarchive),
  `git`, `make`.
- `grub-efi-arm64-bin` + `grub-common` (for `build-grub-efi.sh`).
- `qemu-user-static` + binfmt (for the `chroot` step in `09-bootstrap-arch-rootfs.sh`).
- **Passwordless `sudo`** (the ESP/rootfs loop + mass-storage mounts use it).
- ~30 GB free disk for kernel + modules + rootfs staging.

## A/B slot gotcha
Every power-on decrements slot B's retry counter (starts at 7) until the
slot's GPT "successful" bit is set; at zero the phone silently falls back to
slot A. Once the rootfs is installed, `garnet-mark-boot-successful.service`
sets the bit on every boot and the countdown stops. Before that — and right
after any `fastboot set_active b`, which clears the bit — re-arm by hand:
`fastboot set_active b` (`fastboot getvar slot-retry-count:b` to check).

## The only outputs (in `../dist/`, rebuildable by the scripts)
`grubaa64.efi`, `Image`/`Image-vt`, `garnet-sm7435.dtb` +
`garnet-sm7435-nommgdsc.dtb`, and the `initramfs-*.gz` set. These are build
products — you regenerate them, you don't need the author's copies. Their sha256
are in `dist-manifests/dist-artifacts.txt` if you want to compare.
