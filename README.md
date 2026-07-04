# Linux on the Xiaomi garnet (Redmi Note 13 Pro 5G / Poco X6 5G)

Everything here exists so that **anyone with their own garnet** can do the same
thing from clean upstream sources: the kernel patches, two new drivers, the
kernel config, the init scripts, the exact module load order, the systemd
services, and a numbered script pipeline that takes you from `git clone` to a
booting phone. If you get stuck, the entire debugging saga is preserved in
[`docs/`](docs/) as a lab notebook — every dead end included.

> **Before anything else, read [`PREREQUISITES.md`](PREREQUISITES.md).** It
> covers the unlocked-bootloader requirement, host packages, and — important —
> the fact that this **wipes your Android userdata**.

> **No proprietary firmware is shipped.** The WPSS Wi-Fi firmware (and later
> the GPU firmware) is Qualcomm/Xiaomi property. You extract it from *your own*
> phone with `scripts/08-extract-firmware.sh` — it lives in firmware partitions
> that survive a LineageOS re-flash, so it's always there to grab.

---

## What works today

| # | Milestone | State |
|---|-----------|-------|
| 1 | Linux boots — BusyBox initramfs as PID 1, output on the phone screen via `earlycon=efifb` | ✅ |
| 2 | **UFS storage** — all LUNs and the 71-partition GPT show up as `/dev/sd*` | ✅ |
| 3 | **Arch Linux ARM + systemd** with a framebuffer console on the phone screen, root autologin | ✅ |
| 4 | **SSH over USB** — plug into a PC, `ssh root@172.16.42.1`, with internet and pacman working | ✅ |
| 5 | **Wi-Fi** — WPA2, DHCP, internet on `wlan0` (VHT80 MCS9, 866 Mbit) | ✅ |
| 6 | USB **host mode** — xhci comes up, a keyboard enumerates. Software done; needs a **powered OTG hub** because the phone can't source 5 V | 🚧 |
| 7 | **Desktop on the phone screen** — X11 + i3 on efifb, and a backported **simpledrm** giving `/dev/dri/card0` → **sway (Wayland)** | ✅ |

A few hardware facts to orient you: garnet is an A/B device, Mu-Silicium lives
on **slot B** (`boot_b`), and the kernel is LineageOS's downstream
**5.10.252** GKI tree (`uname -r` reports `-dirty` because of our patches —
that's expected).

---

## Repository layout

```
github/
├── README.md                     ← you are here
├── PREREQUISITES.md              ← read first (hardware, bootloader, host packages)
├── scripts/                      ← the pipeline (00–06 in order; others as needed)
│   ├── 00-clone-sources.sh       clone kernel/dts/modules/Mu-Silicium (lineage-23.2)
│   ├── 01-apply-patches.sh       apply the 3 patches + drop in the 2 new drivers
│   ├── build_kernel.sh           merge defconfig + build Image + DTB
│   ├── 02-build-modules.sh       build Image/DTB then all 314 .ko
│   ├── 03-make-nommgdsc-dtb.sh   the ~11 s reset fix (disable 7 mm GDSC nodes)
│   ├── 04-stage-modules.sh       compute the 43-module closure + load order
│   ├── 05-pack-initramfs.sh      pack an initramfs (storage or switch /init)
│   ├── 06-deploy-esp.sh          copy artifacts to GARNET-ESP over mass storage
│   ├── 07-build-qcacld.sh        build the Wi-Fi driver wlan.ko (qcacld-3.0)
│   ├── 08-extract-firmware.sh    pull WPSS firmware from YOUR phone (not shipped)
│   ├── 09-bootstrap-arch-rootfs.sh  install Arch onto userdata + our services
│   ├── build-grub-efi.sh         build grubaa64.efi (BOOTAA64.EFI)
│   └── get-busybox.sh            fetch a static aarch64 busybox for the initramfs
├── patches/                      ← kernel patches (git diff, one per file + combined)
├── kernel-new-drivers/           ← extcon-fake-vbus.c, simpledrm.c (new files)
├── config/                       ← garnet_bringup.config, grub.cfg (the ESP menu)
├── initramfs/                    ← the real /init scripts + load-order.list + module list
├── rootfs/                       ← systemd services, network/wpa/blacklist configs,
│                                   WCNSS ini (the Wi-Fi fix), USB-gadget script
├── docs/                         ← LAB-NOTEBOOK-{status,handoff}.md (the full debugging log)
└── dist-manifests/               ← sha256 manifest of the build outputs
```

---

## Installation — the full walkthrough

Seven stages: get this repo, prepare the phone, get the sources, patch them,
build everything, put it on the phone, and start the desktop. Budget an
afternoon the first time.

### Step 0 — clone this repo and set up the host

```bash
# Everything in this project lives under one root directory:
export ROOT=$HOME/garnet_linux
mkdir -p "$ROOT" && cd "$ROOT"

git clone https://github.com/Itzkristis/garnet-arch.git github
cd github
```

Host packages you'll need (names vary by distro — see `PREREQUISITES.md` for
the full list): `clang`/`llvm`, `device-tree-compiler`, `cpio`, `gzip`, `curl`,
`bsdtar`, `git`, `make`, `grub-efi-arm64-bin` + `grub-common`, and
`qemu-user-static` with binfmt for the rootfs chroot. A recent clang is
completely fine — one of our patches exists precisely so a modern compiler can
build this 5.10 tree.

### Step 1 — prepare the phone (one-time)

1. **Unlock the bootloader** through Xiaomi's official unlock process. Yes, it
   wipes the phone; yes, there's a waiting period. There's no way around it.
2. **Build and flash Mu-Silicium UEFI.** Follow the
   [Mu-Silicium](https://github.com/Project-Silicium/Mu-Silicium) project's own
   README to build the garnet image, then flash it to **slot B** and make B
   active:

   ```bash
   fastboot flash boot_b <mu-silicium-boot-image>.img
   fastboot set_active b
   ```

   Android stays intact on slot A — you can always `fastboot set_active a` to
   go back.
3. **Know the retry-counter gotcha:** every power-on of slot B decrements an
   A/B retry counter (it starts at 7), and nothing ever marks the boot as
   successful. When it hits zero the phone silently falls back to slot A. The
   fix is simply re-running `fastboot set_active b` — do it after every flash
   session and you'll never be surprised.

### Step 2 — clone the upstream sources

This repo ships only *our* changes. The kernel, device trees, vendor modules,
and Mu-Silicium come from their own upstreams. One script pulls them all into
`$ROOT`:

```bash
./scripts/00-clone-sources.sh
```

For transparency, here is exactly what that fetches and from where — you can
run these by hand instead if you prefer:

```bash
cd "$ROOT"

# Kernel + device trees + vendor modules — LineageOS, branch lineage-23.2 (5.10.252):
git clone --depth=1 -b lineage-23.2 https://github.com/LineageOS/android_kernel_xiaomi_sm7435             kernel_sm7435
git clone --depth=1 -b lineage-23.2 https://github.com/LineageOS/android_kernel_xiaomi_sm7435-devicetrees devicetrees
git clone --depth=1 -b lineage-23.2 https://github.com/LineageOS/android_kernel_xiaomi_sm7435-modules     modules
# (the modules tree contains qcacld-3.0, the Wi-Fi driver built later by 07)

# Mu-Silicium UEFI firmware/bootloader:
git clone --recursive https://github.com/Project-Silicium/Mu-Silicium
```

Two more downloads happen later, done for you by the scripts: the Arch Linux
ARM rootfs tarball (`09-bootstrap-arch-rootfs.sh` fetches it from
`os.archlinuxarm.org`) and a static aarch64 busybox (`get-busybox.sh` fetches
it from `busybox.net`). Proprietary firmware is **never** downloaded — that
comes off your own phone in Step 5.

### Step 3 — apply the patches

```bash
./scripts/01-apply-patches.sh
```

That's it — the script `git apply`s the combined patch into
`$ROOT/kernel_sm7435` and copies the two new driver sources into place. It's
idempotent, so running it twice is harmless.

If you'd rather do it manually (or want to see exactly what changes):

```bash
cd "$ROOT/kernel_sm7435"
git apply "$ROOT/github/patches/all-kernel-patches.patch"

# The two brand-new drivers are plain file copies, not patches:
cp "$ROOT/github/kernel-new-drivers/extcon-fake-vbus.c" drivers/extcon/
cp "$ROOT/github/kernel-new-drivers/simpledrm.c"        drivers/gpu/drm/tiny/
```

`patches/` also contains each patch as a separate file with a header
explaining why it exists, if you want to cherry-pick. What each one does is
covered in [The three kernel patches](#the-three-kernel-patches-why-the-tree-is--dirty)
below.

### Step 4 — build everything

```bash
cd "$ROOT/github"
./scripts/02-build-modules.sh         # kernel Image + DTB + all 314 modules (~10 min after the Image)
./scripts/03-make-nommgdsc-dtb.sh     # the reset-fix DTB (without it the phone hard-resets ~11 s in)
./scripts/07-build-qcacld.sh          # the Wi-Fi driver, wlan.ko
./scripts/build-grub-efi.sh           # grubaa64.efi (becomes BOOTAA64.EFI on the ESP)
./scripts/get-busybox.sh              # static busybox for the initramfs
./scripts/04-stage-modules.sh         # compute the 43-module closure + load order
./scripts/05-pack-initramfs.sh initramfs/init-switch.sh   # pack the daily-driver initramfs
```

Outputs land in `$ROOT/dist/`. If you want to check your build against the
author's, sha256 sums are in `dist-manifests/dist-artifacts.txt` — but you
don't need the author's binaries for anything; the scripts regenerate all of
them.

### Step 5 — put it on the phone

Boot the phone into Mu-Silicium and select **USB mass-storage mode** — this
exposes the whole UFS to your PC as a block device, so no fastboot needed for
day-to-day work. Then:

```bash
./scripts/09-bootstrap-arch-rootfs.sh   # ⚠️ DESTROYS userdata → installs Arch + our services
./scripts/08-extract-firmware.sh /mnt/archroot/lib/firmware/adrastea   # your phone's WPSS Wi-Fi fw
./scripts/06-deploy-esp.sh              # copy Image/DTB/grub.cfg/initramfs to the GARNET-ESP partition
```

(If you don't have a GARNET-ESP partition yet, see `PREREQUISITES.md` — it must
be formatted `mkfs.vfat -F 32 -S 4096` because the UFS logical block size is
4096.)

### Step 6 — boot it

Reboot the phone. Mu-Silicium chainloads GRUB from the ESP; pick a menu entry
with the **volume keys**. If something goes wrong, the init scripts write logs
to `GARNET-ESP:/logs/`, which you can read back over mass-storage mode.

A sane first run is to walk the milestones in order rather than jumping
straight to the desktop: boot the diagnostic `init-storage.sh` initramfs and
confirm `/dev/sd*` appears → boot into Arch and check systemd reaches the
console → plug into your PC and `ssh root@172.16.42.1` → bring up Wi-Fi →
start sway. Each stage has a GRUB entry.

### Step 7 — start sway

SSH in (`ssh root@172.16.42.1`), make sure `/dev/dri/card0` exists (simpledrm
autoloads via `modules-load.d`), then:

```bash
runuser -u alarm -- env XDG_RUNTIME_DIR=/run/user/1000 WLR_LIBINPUT_NO_DEVICES=1 WLR_BACKENDS=drm sway
```

Run apps into the session from another SSH window:

```bash
su - alarm -c "env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 foot"
```

Swap `foot` for any Wayland app. Handy combo: have foot run
`tmux new -A -s phone`, then `ssh -t alarm@172.16.42.1 tmux attach -t phone`
from the PC mirrors the phone's terminal into your SSH session.

Note: `seatd`, the alarm user's groups, and `loginctl enable-linger alarm` are
already set up by the `09` bootstrap — don't disable linger, or logind wipes
`/run/user/1000` (and sway's socket with it) when the last login exits.

---

## The three kernel patches (why the tree is `-dirty`)

All in `patches/`, applied by `01-apply-patches.sh`:

1. **`scripts/basic/cc-wrapper.c`** — the downstream build wrapper treats *any*
   new compiler warning as a fatal error, and a modern clang emits plenty the
   5.10 tree never anticipated. Neutered so warnings never kill the build
   (real errors still do). Without this you can't `make modules` at all.
2. **`drivers/interconnect/qcom/icc-rpmh.c`** — force
   `is_voter_disabled("disp"/"disp2") = true`. The display RSC never probes on
   this setup, so its "disp" bcm-voter doesn't exist; without the patch,
   `mc_virt`/`gem_noc`/`mmss_noc` never register, which blocks UFS and the SMMU.
3. **`drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c`** — make
   `qsmmuv500_tbu_register()` skip an unbound multimedia TBU (`return 0`)
   instead of aborting the entire `apps-smmu`. UFS uses the **anoc** TBU
   (SID `0x80`), which binds fine.

Plus the wiring (Kconfig/Makefile entries) for the two **new drivers** in
`kernel-new-drivers/`:

- **`extcon-fake-vbus.c`** — a fake VBUS extcon that binds the `qcom,msm-eud`
  node and permanently reports `EXTCON_USB=1`, feeding dwc3-msm the cable
  event that retail EUD hardware never sends. It registers on a child pdev
  named `fake_vbus.0` because dwc3-msm blackholes any extcon whose name
  contains "eud". This is what makes the USB gadget (milestone 4) and host
  mode (milestone 6) possible.
- **`simpledrm.c`** — the v5.14 simpledrm driver **backported to 5.10** (no
  drm_aperture, no shadow-plane helpers, a local blit dispatcher). It wraps
  the firmware framebuffer as a real `/dev/dri/card0`, which unlocks every
  Wayland compositor (milestone 7). Module-only — the kernel Image is
  untouched.

---

## The UFS onion — 9 blockers peeled to reach `/dev/sd*`

Getting storage up wasn't one bug, it was a dependency chain nine layers deep,
each found on-device via `/sys/kernel/debug/devices_deferred` and dmesg. The
concrete result is `initramfs/load-order.list` (the exact insmod order) and
`initramfs/init-storage.sh` (the diagnostic /init). In order:

1. busybox `modprobe` ignores `modules.dep` → switched to ordered `insmod`
   from a `tsort`-generated list.
2. Interconnect providers fail on the absent "disp" bcm-voter → patch #2.
3. The SMMU aborts on unbound multimedia TBUs → patch #3.
4. `gcc-parrot` defers on ARC regulators that need the **downstream**
   `rpmh-regulator.ko`, not the mainline `qcom-rpmh-regulator.ko` → ship the
   right driver.
5. Regulators come up → the multimedia GDSC probes fire → **~11 s PMIC hard
   reset** → `03-make-nommgdsc-dtb.sh` disables the 7 mm GDSC nodes in the DTB.
6. `ufshc` defers on cpufreq → ship `qcom-cpufreq-hw.ko`.
7. `ufshc` still deferred *silently* (`-517 after 0 usecs`) → fw_devlink was
   waiting on the `qfprom` nvmem supplier → ship `nvmem_qfprom.ko`.
8. …still deferred: the second nvmem cell (`ufs_dev`) lives in **pmk8350
   `sdam@7000` behind SPMI**, a device that can't exist without SPMI drivers.
   This is the *invisible* fw_devlink `needs_suppliers` wait — only the
   `waiting_for_supplier` sysfs attribute betrays it → ship the whole SPMI
   chain (`regmap-spmi`, `qti-regmap-debugfs`, `spmi-pmic-arb`,
   `qcom-spmi-pmic`, `nvmem_qcom-spmi-sdam`).
9. → **UFS probes, link-up, every LUN and partition enumerates. Done.**

---

## The Wi-Fi one-liner that cost hours

Wi-Fi looked *almost* fine. `wlan0` came up, scanned every network in the
house, associated to the AP, and received frames without a hiccup. But the
WPA2 handshake failed every single time, and wpa_supplicant kept insisting the
password was wrong. It wasn't.

What was actually happening: our qcacld build only compiles the "fastpath" TX
path, and fastpath has a runtime switch — `gEnableFastPath` — that **defaults
to off**. With it off, the driver quietly threw away every packet the phone
tried to send. Receiving worked, transmitting didn't, and the handshake died
because our half of it (EAPOL message 2/4) never left the device. No error, no
log line, nothing.

The fix is one line in `rootfs/lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini`:

```ini
gEnableFastPath=1
```

Finding it was the hard part. qcacld's own logging tells you nothing useful,
so the drops were tracked down with ftrace `kfree_skb` histograms and kprobes
instead. If you ever have to debug this driver, the full playbook is in the
lab notebook — start there, not in the driver's logs.

---

## Key operational learnings

- **Modules must match the exact Image** (`MODVERSIONS=y` +
  `LOCALVERSION_AUTO=y`). We only ever add `=m` symbols, so `out/Image` stays
  byte-identical to the flashed one — module-only changes never require
  re-flashing the kernel.
- **busybox `modprobe` doesn't resolve dependencies** → insmod in `tsort`
  order.
- **`gdsc-regulator.ko`'s probe is destructive on live power domains** — never
  let it touch clock-controller domains the firmware left running (that's the
  efifb display dying). `status = "disabled"` at the DTB level is the safe knob.
- **Mu-Silicium mass-storage mode is your best friend** — it exposes the whole
  UFS, so you edit the ESP directly and read boot logs back; no fastboot
  round-trips.
- **Re-arm slot B** (`fastboot set_active b`) after every flash session — see
  Step 1.

---

## Roadmap (not yet done)

- **OTG keyboard**: host mode works in software; blocked on hardware — a
  powered OTG hub is needed because the SM7435's OTG 5 V boost goes through
  pmic_glink → ADSP charger firmware that we don't run.
- **RTC**: ship `rtc-pm8xxx` over SPMI (the clock is currently wrong).
- **GPU**: the plan is **turnip (Vulkan) over KGSL** with zink for GL —
  freedreno's GL driver is impossible on a 5.10 KGSL kernel. Needs the
  `gpu_cc`/GPU GDSCs re-enabled (currently disabled by the reset-fix DTB),
  Adreno SQE/GMU firmware + zap shader extracted from the phone, and a
  community A710 turnip build. Full plan in the lab notebook.
- **Durability**: automate the slot-B re-arm, `fsck.vfat` the ESP, trim the
  initramfs module set.

---

## Provenance / caveats

Honesty section. Most of this repo is verbatim from the working setup: the
**patches** were extracted straight from the kernel git tree (the combined
patch is verified to apply cleanly), and the **`init-*.sh`,
`load-order.list`, and module list** were unpacked from the actual working
initramfs images. A few pieces are **faithful reconstructions** from the lab
notebook because the live copies only exist on the phone — each one carries a
`RECONSTRUCTED — verify against docs/` header:
`rootfs/etc/systemd/system/garnet-*.service` and
`rootfs/usr/local/sbin/garnet-usb-gadget-up.sh`. The `07`/`08`/`09` scripts
encode the documented procedures but haven't been re-run end-to-end from a
clean host — treat them as a well-signposted path rather than a certified one,
and cross-check `docs/` when a step surprises you.

## Upstream sources

- Kernel: [`LineageOS/android_kernel_xiaomi_sm7435`](https://github.com/LineageOS/android_kernel_xiaomi_sm7435) (`lineage-23.2`, 5.10.252)
- Device trees: [`…_sm7435-devicetrees`](https://github.com/LineageOS/android_kernel_xiaomi_sm7435-devicetrees) · Modules: [`…_sm7435-modules`](https://github.com/LineageOS/android_kernel_xiaomi_sm7435-modules) (both `lineage-23.2`)
- Firmware/bootloader: [`Project-Silicium/Mu-Silicium`](https://github.com/Project-Silicium/Mu-Silicium)
