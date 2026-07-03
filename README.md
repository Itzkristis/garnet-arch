# Linux on the Xiaomi garnet (Redmi Note 13 Pro 5G / Poco X6 5G)

Mainline-style Linux userspace (Arch Linux ARM) on the **Xiaomi garnet**
(SoC **SM7435 "parrot"**, Snapdragon 7s Gen 2), booted via **Mu-Silicium UEFI**
instead of the Android bootloader — no downstream Android userspace, no
postmarketOS.

This folder is a reproducibility kit: the exact **kernel patches**, **new
drivers**, **config**, **init scripts**, **module load order**, **systemd
service / config references**, and **step-by-step scripts** to rebuild
everything from clean upstream sources. The big binary outputs stay in
`../dist/` (see `dist-manifests/dist-artifacts.txt` for their sha256).

The authoritative running log of *how* each problem was solved lives in the
project root: **`../status.md`** and **`../handoff.md`**. Read those for the full
frame-by-frame debugging story; this README is the map.

---

## What works today

| # | Milestone | State |
|---|-----------|-------|
| 1 | Linux userspace boots (BusyBox initramfs as PID 1, on the phone screen via `earlycon=efifb`) | ✅ |
| 2 | **UFS storage** — all LUNs + 71-partition GPT enumerate (`/dev/sd*`) | ✅ |
| 3 | **Arch Linux ARM + systemd + fbcon console** on the phone screen, root autologin | ✅ |
| 4 | **SSH over USB** — `ssh root@172.16.42.1` (NCM gadget, DHCP to the PC), internet + pacman | ✅ |
| 5 | **Wi-Fi** — WPA2 + DHCP + internet over `wlan0` (VHT80 MCS9, 866 Mbit) | ✅ |
| 6 | USB **host mode** (xhci up, keyboard enumerates) — software done, needs a **powered OTG hub** (phone can't source 5 V VBUS) | 🚧 |
| 7 | **Desktop on screen** — X11+i3 on efifb, and backported **simpledrm** → `/dev/dri/card0` → **sway (Wayland)** | ✅ |

Hardware facts: A/B device, Mu-Silicium on **slot B** (`boot_b`); fastboot serial
`<your-fastboot-serial>`; `uname -r` = `5.10.252-gki-gad48dfa7447a-dirty`.

---

## Repository layout

```
github/
├── README.md                     ← you are here
├── scripts/                      ← numbered reproduction pipeline (run in order)
│   ├── 00-clone-sources.sh       clone kernel/dts/modules/Mu-Silicium (lineage-23.2)
│   ├── 01-apply-patches.sh       apply the 3 patches + drop in 2 new drivers
│   ├── build_kernel.sh           merge defconfig + build Image + DTB
│   ├── 02-build-modules.sh       build Image/DTB then all 314 .ko
│   ├── 03-make-nommgdsc-dtb.sh   the ~11 s reset fix (disable 7 mm GDSC nodes)
│   ├── 04-stage-modules.sh       compute the 43-module closure + load order
│   ├── 05-pack-initramfs.sh      pack an initramfs (storage or switch /init)
│   └── 06-deploy-esp.sh          copy artifacts to GARNET-ESP over mass storage
├── patches/                      ← kernel source patches (git diff, one per file + combined)
├── kernel-new-drivers/           ← extcon-fake-vbus.c, simpledrm.c (new files)
├── config/                       ← garnet_bringup.config, grub.cfg (the ESP menu)
├── initramfs/                    ← the real /init scripts + load-order.list + module list
├── rootfs/                       ← reference systemd services & configs (Wi-Fi/USB/network)
└── dist-manifests/               ← sha256 manifest of the prebuilt ../dist/ binaries
```

---

## Quick start (rebuild from scratch)

Host needs: `clang`/`llvm` (a modern one is fine — that's what a patch is for),
`aarch64` cross tools optional, `device-tree-compiler` (`fdtput`), `cpio`,
`gzip`, passwordless `sudo` for the loop/mass-storage mounts.

```bash
export ROOT=$HOME/garnet_linux            # everything is relative to this
./scripts/00-clone-sources.sh             # clone upstream (lineage-23.2)
./scripts/01-apply-patches.sh             # patch + install new drivers
./scripts/02-build-modules.sh             # Image + DTB + 314 modules (~10 min after Image)
./scripts/03-make-nommgdsc-dtb.sh         # produce the reset-fix DTB
./scripts/04-stage-modules.sh             # 43-module closure -> $ROOT/irfs
./scripts/05-pack-initramfs.sh initramfs/init-switch.sh   # pack the daily-driver initramfs
# put the phone in Mu-Silicium mass-storage mode, then:
./scripts/06-deploy-esp.sh                # copy Image/DTB/grub.cfg/initramfs to GARNET-ESP
```

Reboot, pick the GRUB entry with the volume keys, read logs back from
`GARNET-ESP:/logs/` over mass storage. (The prebuilt `../dist/` artifacts let you
skip straight to `06-deploy-esp.sh` if you don't want to rebuild.)

---

## The three kernel patches (why the tree is `-dirty`)

All in `patches/` (applied by `01-apply-patches.sh`):

1. **`scripts/basic/cc-wrapper.c`** — the downstream wrapper fails the build on
   *any* new compiler warning; host clang emits many the 5.10 tree predates.
   Neutered so warnings never fail the build (real errors still do). **Required
   to `make modules` at all.**
2. **`drivers/interconnect/qcom/icc-rpmh.c`** — force `is_voter_disabled("disp"/
   "disp2") = true`. The display RSC never probes, so its "disp" bcm-voter is
   absent; without this, `mc_virt`/`gem_noc`/`mmss_noc` never register and block
   UFS + the SMMU.
3. **`drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c`** — `qsmmuv500_tbu_register()`
   skips (`return 0`) an unbound multimedia TBU instead of aborting the whole
   `apps-smmu`. UFS uses the **anoc** TBU (SID `0x80`), which binds fine.

Plus wiring for the two **new drivers** in `kernel-new-drivers/`:

- **`extcon-fake-vbus.c`** — fake VBUS extcon that binds the `qcom,msm-eud` node
  and permanently reports `EXTCON_USB=1`, feeding dwc3-msm the cable event retail
  EUD never sends. Registers on a child pdev named `fake_vbus.0` (dwc3-msm
  blackholes extcon names containing "eud"). Enables the USB gadget (M4) and host
  mode (M6).
- **`simpledrm.c`** — v5.14 simpledrm **backported to 5.10** (no drm_aperture, no
  shadow-plane helpers, local blit dispatcher). Wraps the firmware framebuffer as
  a real `/dev/dri/card0`, unlocking every Wayland compositor (M7). Module-only —
  the Image is untouched.

---

## The UFS onion — 9 blockers peeled to reach `/dev/sd*`

Milestone 2 was a dependency chain, each layer found on-device via
`/sys/kernel/debug/devices_deferred` + dmesg. Captured concretely in
`initramfs/load-order.list` (the exact insmod order) and
`initramfs/init-storage.sh` (the diagnostic /init). In order:

1. busybox `modprobe` ignores `modules.dep` → ordered `insmod` from a
   `tsort` list instead.
2. Interconnect providers fail on the absent "disp" bcm-voter → patch #2.
3. SMMU aborts on unbound multimedia TBUs → patch #3.
4. `gcc-parrot` defers on ARC regulators driven by the **downstream**
   `rpmh-regulator.ko` (not the mainline `qcom-rpmh-regulator.ko`) → ship the
   right driver.
5. Regulators come up → the mm GDSC probes fire → **~11 s PMIC hard reset** →
   `03-make-nommgdsc-dtb.sh` (disable the 7 mm GDSC nodes).
6. `ufshc` defers on cpufreq → ship `qcom-cpufreq-hw.ko`.
7. `ufshc` still deferred *silently* (`-517 after 0 usecs`) → fw_devlink blocked
   on the `qfprom` nvmem supplier → ship `nvmem_qfprom.ko`.
8. …still deferred: the second nvmem cell (`ufs_dev`) lives in **pmk8350
   `sdam@7000` behind SPMI**, a device that doesn't exist without SPMI drivers →
   the **invisible** fw_devlink `needs_suppliers` wait (only `waiting_for_supplier`
   sysfs betrays it) → ship the SPMI chain (`regmap-spmi`, `qti-regmap-debugfs`,
   `spmi-pmic-arb`, `qcom-spmi-pmic`, `nvmem_qcom-spmi-sdam`).
9. → **UFS probes, link-up, all LUNs + partitions enumerate. Done.**

---

## The Wi-Fi one-liner that cost hours

`wlan0` associated, scanned, and received fine, but the WPA2 4-way handshake
failed with a bogus "pre-shared key may be incorrect" — because our qcacld build
compiles **only** the fastpath TX path, whose runtime switch `gEnableFastPath`
**defaults to false**, so 100 % of host TX (including EAPOL 2/4) was silently
dropped. The fix is one line in `rootfs/lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini`:
`gEnableFastPath=1`. qcacld's own logging is a black hole — it was found with
ftrace `kfree_skb` histograms + kprobes (playbook in `../handoff.md`).

---

## Key operational learnings

- **Modules must match the exact Image** (`MODVERSIONS=y` + `LOCALVERSION_AUTO=y`).
  We only add `=m` symbols, so `out/Image` stays byte-identical to the flashed one
  and never needs re-flashing when only modules change.
- **busybox `modprobe` doesn't resolve deps** → insmod in `tsort` order.
- **`gdsc-regulator.ko` probe is destructive on live domains** — never let it
  touch clock-controller domains firmware left running (the efifb display).
  DTB-level `status=disabled` is the safe knob.
- **Mu-Silicium mass-storage mode** exposes the whole UFS; edit the ESP directly,
  no fastboot. UFS logical block = **4096** → format the ESP `mkfs.vfat -F 32 -S 4096`.
- **A/B slot B decrements a retry counter every power-on** and nothing marks
  success → `fastboot set_active b` re-arms it (starts at 7).

---

## Roadmap (not yet done)

- **OTG keyboard**: host mode works in software; needs a **powered OTG hub**
  (SM7435 OTG boost = pmic_glink → ADSP charger fw we don't run).
- **RTC**: ship `rtc-pm8xxx` via SPMI (clock currently wrong).
- **GPU**: **turnip (Vulkan) over KGSL** + zink for GL (freedreno GL impossible on
  5.10). Requires re-enabling `gpu_cc`/GPU GDSCs (currently disabled by the
  reset-fix DTB), extracting Adreno SQE/GMU fw + zap shader, and a community A710
  turnip build. Full plan in `../handoff.md`.
- **Durability**: re-arm slot B, `fsck.vfat` the ESP, trim the initramfs module set.

---

## Upstream sources

- Kernel: `github.com/LineageOS/android_kernel_xiaomi_sm7435` (`lineage-23.2`, 5.10.252)
- Device trees: `…_sm7435-devicetrees` · Modules: `…_sm7435-modules` (both `lineage-23.2`)
- Firmware/bootloader: `github.com/Project-Silicium/Mu-Silicium`
