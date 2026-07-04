# Project Status — Linux on Xiaomi garnet via Mu-Silicium

_Last updated: 2026-07-03_

## Goal
Run a mainline-style Linux userspace (Arch / Debian / Fedora — **not** postmarketOS, unsupported)
on the Xiaomi Redmi Note 13 Pro 5G / Poco X6 5G (**codename: garnet**) using **Mu-Silicium UEFI**
as the firmware/bootloader layer.

## 🎉 Milestone 1 (done): Linux userspace BOOTS on the device
Mu-Silicium → GRUB → our downstream **5.10.252** kernel + garnet DTB → a **BusyBox initramfs
as PID 1**, shown live on the phone screen via `earlycon=efifb` (no serial). First Linux userspace
on garnet.

## 🎉 Milestone 2 (DONE 2026-07-02): UFS STORAGE WORKS — /dev/sd* enumerated
Full internal UFS is up from our kernel: all LUNs enumerate (`sda`…`sde`, main Android GPT with
71 partitions incl. GARNET-ESP, ~224 GiB whole-disk). Video evidence `pics/VID20260702141744.mp4`.
Final module count: **43** (see chain below — 9 distinct blockers were peeled).
**Workflow upgrade that ends photo-debugging:** kernel has VFAT+EXT4 built-in → initramfs v8 now
mounts GARNET-ESP and writes `ESP:/logs/boot-N.txt` (full dmesg+partitions+blkid at success) and
`boot-N-live.txt` (refreshed every 20 s heartbeat) — pull them over mass storage.

## Milestone 2 history (kept for the record)
We built the kernel **modules** (the old build made only Image+DTB, zero `.ko`) and worked the UFS
probe dependency chain from userspace, loading a curated **36-module** set from the initramfs.
Every layer that blocked UFS is now resolved (see "UFS bring-up chain" below):
interconnect ✅, SMMU ✅, gcc clocks ✅, **rpmh regulators ✅**.

**Current blocker:** with the regulators finally coming up, the phone **resets at ~10.5–11 s uptime**
during regulator/clock/UFS bring-up (screen goes black, no visible oops). This code path was never
reached before (gcc/regulators used to defer), so the reset is *new*. We are **one step** from
`/dev/sd*`. Diagnosing the reset is the immediate next task.

**2026-07-02 session 2 findings:** built a pstore/ramoops capture pipeline + a 7-entry GRUB menu
ESP editable over Mu-Silicium **mass storage** (fastboot no longer needed). ramoops verifiably
works every boot, but after the ~11 s reset **pstore is empty → the reset loses DDR → it is a
PMIC-level hard reset, not a kernel panic** (stock warm resets preserve this region — the Xiaomi
`oops` partition proves it). A no-modules diag boot runs 350 s+ stable.

**2026-07-02 session 3 findings (host-only, phone not attached): reset localized to the
multimedia-GDSC probes.** Re-mined the existing 120 fps crash video frame-by-frame — the last
line ever rendered is `disp_cc_mdss_core_gdsc: supplied by pm6450_s1_level` at **10.22 s**,
preceded by `gcc-parrot: Registered GCC clocks` (10.19) and `cam_cc_camss_top_gdsc: supplied by …`
(10.20). Code analysis (`gdsc-regulator.c`): every `qcom,gdsc` probe was deferred on
`devm_clk_get("ahb_clk")` until gcc registered; then each probe does a **raw GDSCR
read-modify-write clearing HW_CONTROL|SW_OVERRIDE before regulator_register**, and
`disp_cc_mdss_core_gdsc` additionally gets **proxy-consumer-enabled at probe**. The display is
live (efifb scanout) — perturbing the MDSS GDSC / touching `0xaf0b000` (int2, whose print never
appeared) collapses/hangs the display domain → NoC hang → secure watchdog → **PMIC cold reset,
DDR lost**. Matches every symptom. **Fix candidate built:** `dist/garnet-sm7435-nommgdsc.dtb`
(the 7 enabled cam_cc/disp_cc/gpu_cc/video_cc GDSC nodes set `status=disabled`; GCC +
hlos1_vote GDSCs kept for UFS/SMMU) + **GRUB entry 7** (now the default) boots it with the full
storage initramfs.

**2026-07-02 session 3, part 2: 🎉 THE ~11 s RESET IS FIXED — confirmed on device.** Entry 7
booted through the old death point and ran 76 s+ stable: GCC registered, **zero cam/disp GDSC
probes** (disabled nodes), all PARROT ICC providers registered, apps-smmu up (TBU skips working),
all 36 modules loaded with `failures=0`. **New blocker (next onion layer): `1d84000.ufshc` stays
in `devices_deferred`, sd*=0.** Root cause found in source: downstream `ufs_qcom_probe()` calls
`ufs_cpufreq_status()` which returns `-EPROBE_DEFER` until a cpufreq policy exists for CPU0
(`CONFIG_ARM_QCOM_CPUFREQ_HW=m`) — and we never shipped a cpufreq driver. All six UFS supplies
(L24B/L13B/L19B/L5B/L16B + gcc_ufs_phy_gdsc) map to rails that registered fine, and
1d87000.ufsphy is not deferred, so cpufreq is the only blocker in the probe path. **Fix shipped
to ESP:** `qcom-cpufreq-hw.ko` (zero module deps, vermagic OK; DT node `qcom,cpufreq-hw-epss`
with xo/gpll0 clocks we already provide; all 8 CPUs have `qcom,freq-domain` links) added to the
initramfs → **37 modules**, loaded right before `ufs_qcom`; heartbeat now also prints
`cpufreq-policies=N`. Awaiting the next entry-7 boot.

## Device facts
| Item | Value |
|------|-------|
| Codename | `garnet` |
| Model | Redmi Note 13 Pro 5G / Poco X6 5G |
| SoC | **SM7435 "parrot"** (Snapdragon 7s Gen 2) |
| Partition scheme | **A/B** — Mu-Silicium on **slot B** (`boot_b`) |
| Bootloader | Unlocked · fastboot serial **`<your-fastboot-serial>`** |
| UFS master SID | `0x80` (apps_smmu), served by the **anoc** TBU |

## What's done ✅
### Firmware + kernel + DTB (host) — unchanged from Milestone 1
- Mu-Silicium UEFI on `boot_b`; `grubaa64.efi` (BOOTAA64) injects DTB + cmdline.
- Standalone flattened **`garnet-sm7435.dtb`**; kernel `Image` with `earlycon=efifb`.
- **`out/arch/arm64/boot/Image` is byte-identical to the flashed `dist/Image-garnet-efifb`** —
  all our config changes are `=m` (modules), so the kernel itself is unchanged / not re-flashed.

### NEW this session — modules + UFS bring-up
- **Built the kernel modules** (`make modules` → 314 `.ko`). Required neutering the downstream
  "forbidden warning" wrapper (host clang 22 emits warnings the 5.10 tree predates) — see patches.
- Config: added `CONFIG_QCOM_RPMHPD=m` and `CONFIG_REGULATOR_QCOM_RPMH=m` (the latter turned out to
  be the *mainline* driver — the DTB needs the *downstream* `rpmh-regulator.ko`, added later).
- Computed the **UFS module dependency closure** (36 modules, ~2.5 MB) and a **topological load
  order** (`load-order.list` via `tsort`), staged into the initramfs `/lib/modules/<kver>/`.
- Rewrote `/init` to load modules **in dependency order with `insmod`** (busybox `modprobe` does
  NOT resolve deps), populate `/dev` with `mdev -s` (no devtmpfs), mount debugfs, and **reprint key
  diagnostics every 20 s in the heartbeat** (deferred-device list + UFS/regulator dmesg) so a phone
  photo always catches the freshest state.

## UFS bring-up chain — layers peeled (in order) 🔎
Each layer below was a distinct blocker found on-device (via `/sys/kernel/debug/devices_deferred`
+ dmesg) and fixed. `uname -r` = `5.10.252-gki-gad48dfa7447a-dirty`.

1. **busybox modprobe ignores modules.dep** → symptom: `Unknown symbol … (err -2)` storms.
   Fix: `/init` does ordered `insmod` from a `tsort`-generated `load-order.list`.
2. **Interconnect providers fail** (`mc_virt`, `gem_noc`, `mmss_noc`: "failed to register ICC
   provider"). Root: they list a **"disp" bcm-voter** that lives under the display RSC
   `rsc@af20000`, which never probes → `of_bcm_voter_get("disp")` = `-EPROBE_DEFER` forever.
   Fix (patch `icc-rpmh.c`): force `is_voter_disabled("disp"/"disp2")=true` — the driver's own
   NULL-safe disabled-voter path skips it; all NoCs then register. UFS needs `mc_virt`+`gem_noc`.
3. **SMMU aborts** (`QSMMUV500 cannot continue!`): the multimedia TBUs (`mnoc_hf_*`, `compute_*`,
   `sf_0`, plus `lpass`/`pcie`) fail probe — their vote-GDSC power needs the mmss stack we don't
   run. Fix (patch `arm-smmu-qcom.c`): `qsmmuv500_tbu_register` **skips** an unbound TBU
   (`return 0`) instead of aborting. The **anoc** TBU (UFS SID 0x80) binds → `apps-smmu` comes up.
4. **gcc-parrot (`100000.clock-controller`) defers** on `vdd_cx`/`vdd_mxa` (`cx.lvl`/`mx.lvl` ARC
   regulators) → `aggre1_noc` (needs a gcc clock) defers → **UFS defers**. Root: those ARC
   regulators **and UFS's own LDOs `L24B/L13B/L19B`** are driven by the **downstream
   `rpmh-regulator.ko` (`CONFIG_REGULATOR_RPMH`)**, NOT the mainline `qcom-rpmh-regulator.ko` we
   first shipped. Fix: add `rpmh-regulator.ko` to the closure/load-order.
5. **Regulators supply** (`gcc_ufs_phy_gdsc: supplied by pm6450_s1_level`, etc.) — then the phone
   **hard-reset at ~10.5–11 s**. Root cause: gcc registration unblocked the 7 multimedia
   `qcom,gdsc` probes (`devm_clk_get("ahb_clk")` was the gate); `gdsc-regulator.ko` raw-RMWs
   GDSCR and proxy-enables the *live* (efifb) display GDSC → MDSS collapse → PS_HOLD drop →
   PMIC hard reset (XBL log: `PM: Reset by PSHOLD / Hard Reset`). Fix: those 7 nodes disabled in
   `garnet-sm7435-nommgdsc.dtb`. **Confirmed fixed on device** (76 s+ stable, SMMU + all ICC up).
6. **`1d84000.ufshc` deferred on cpufreq**: downstream `ufs_qcom_probe()` →
   `ufs_cpufreq_status()` → `-EPROBE_DEFER` until CPU0 has a cpufreq policy
   (`CONFIG_ARM_QCOM_CPUFREQ_HW=m`, driver never loaded). Fixed: `qcom-cpufreq-hw.ko` shipped
   (37th module) — confirmed on device (`cpufreq-policies=2`, EM perf domains created).
7. **`1d84000.ufshc` still deferred — SILENTLY.** v5 instrumentation (initcall_debug + devlink
   status in heartbeat) nailed it in one boot: `probe of 1d84000.ufshc returned -517 after
   0 usecs` (probe fn never entered — fw_devlink blocks in `device_links_check_suppliers`, hence
   zero dmesg) and exactly one non-available devlink:
   **`platform:221c8000.qfprom--platform:1d84000.ufshc : dormant`** — ufshc needs nvmem cells
   `ufs_dev`/`boot_conf` from QFPROM and no nvmem driver was loaded. All clks/regulators/PHY/ICC/
   SMMU suppliers verified available.
8. **`nvmem_qfprom.ko` shipped (v6)** — qfprom devlink went `available`, but ufshc *still*
   deferred at `-517 after 0 usecs`. Two corrections to the model: (a) in this tree
   `device_links_check_suppliers` is *inside* `really_probe`, i.e. inside the initcall_debug
   timer — so 0-usec defers ARE devlink blocks; (b) 5.10 fw_devlink has an **invisible** wait
   list (`needs_suppliers`): when the supplier *device doesn't exist at all*, no devlink object
   is created, nothing shows in `/sys/class/devlink`, and the block is only visible via the
   `waiting_for_supplier` sysfs attribute.
9. **The phantom supplier: `ufs_dev` nvmem cell = `pmk8350 sdam@7000` behind SPMI** — no SPMI
   driver loaded → the sdam device is never enumerated → ufshc waits forever. (The driver never
   even reads `ufs_dev`; only fw_devlink cares.) Fix (v7, 43 modules, on ESP): shipped the SPMI
   chain — `regmap-spmi`, `qti-regmap-debugfs`, `spmi-pmic-arb`, `qcom-spmi-pmic`,
   `nvmem_qcom-spmi-sdam`. Heartbeat now prints `waiting_for_supplier` + sdam device presence.
   **← CONFIRMED: UFS probed, link-up, all LUNs + partitions enumerated. MILESTONE 2 COMPLETE.**

## RESOLVED blocker: ~11 s reset (kept for the record; fix confirmed on device 2026-07-02)
- **Exact death point (from 120 fps video, frame-level):** boot is fine through
  `rpmh_regulator_probe` (9.5–10.15 s, gcc/TBU GDSCs get supplies, benign `could not find RPMh
  address` warnings), `gcc-parrot: Registered GCC clocks` (10.19 s), then
  `cam_cc_camss_top_gdsc: supplied by pm6450_s1_level` (10.20) and
  **`disp_cc_mdss_core_gdsc: supplied by pm6450_s1_level` (10.22) is the last line ever printed.**
- **Mechanism:** gcc registration unblocks `devm_clk_get("ahb_clk")` for all 7 enabled
  cam_cc/disp_cc/gpu_cc/video_cc `qcom,gdsc` devices. `gdsc-regulator.ko`'s probe does a raw
  GDSCR RMW (clears `HW_CONTROL|SW_OVERRIDE`) on the mm clock-controller register space with no
  clock management, and `disp_cc_mdss_core_gdsc` (`qcom,proxy-consumer-enable` + shipped
  `proxy-consumer.ko`) is *enabled* at probe. The display is actively scanning out efifb; the
  next probe (`disp_cc_mdss_core_int2_gdsc` @ 0xaf0b000 — its print never appeared) or the
  proxy-enable collapses/hangs the live MDSS domain → bus/NoC hang → secure watchdog → PMIC
  cold reset (screen dies instantly, DDR lost, no oops — all as observed).
- **Fix candidate (staged in `dist/`, needs copying to ESP):** `garnet-sm7435-nommgdsc.dtb`
  with those 7 GDSC nodes `status=disabled` (fdtput; original DTB untouched). GCC GDSCs
  (`gcc_ufs_phy_gdsc`!) and hlos1_vote TBU GDSCs kept. `dist/grub.cfg` gained **entry 7**
  (storage initramfs + new DTB) and its `default` is now 7.

## 🎉 Milestone 3 (DONE 2026-07-02): ARCH LINUX BOOTS TO A ROOT SHELL ON SCREEN
**`Welcome to Arch Linux ARM` + full systemd boot (0 failed units, both test boots) + fbcon
console on the phone display + auto-login `ROOT LOGIN ON tty1`.** Journal auto-dumped to
`ESP:/logs/systemd-N.txt` by our service. Known cosmetic noise: one `spmi pmic_arb transaction
failed (0x3)`, udev ACL warnings, ESP FAT dirty-bit warning. **No RTC** (clock wrong, May 28) —
add `rtc-pm8xxx` via SPMI later. No input devices yet (OTG keyboard dead: USB is never
initialized — no dwc3 modules shipped; host mode also needs VBUS boost). Boot chain:
Mu-Silicium → GRUB entry 9 → `Image-vt` → `initramfs-switch.gz` (43 modules) → `switch_root`
→ systemd → tty1 root shell.

## Milestone 3 history
Decisions (user): **sacrifice Android's userdata; distro = Arch Linux ARM.**
1. ✅ v8 ESP logging verified (`ESP:/logs/boot-0.txt` complete: dmesg + partitions + blkid).
2. ✅ userdata identified: phone `sda34` / host mass-storage `sdX34`, 223.9 GiB,
   PARTLABEL=`userdata`. Reformatted **ext4, label `archroot`** from the host over mass storage.
3. ✅ ArchLinuxARM-aarch64-latest.tar.gz (818 MB) downloaded + `bsdtar -xpf` onto it (2.1 GiB,
   root password emptied, `/etc/garnet-release` marker).
4. ✅ **CHROOT SMOKE TEST PASSED on device** (`ESP:/logs/arch-1.txt`, rc=0):
   `Arch Linux ARM (aarch64, kernel 5.10.252-gki-…-dirty) — 165 packages, bash 5.3.12,
   glibc 2.43`. Arch userland runs on our kernel. `initramfs-arch.gz` = GRUB entry 8 (default).
   (First attempt logged nothing: the initramfs had no `/tmp`, so the output redirect silently
   failed — fixed + chroot rc/output_bytes now always logged.)
   systemd boot is NOT possible yet: kernel lacks DEVTMPFS/FHANDLE/VT — that's the next kernel
   rebuild, now easy since `Image` lives on the ESP and is replaced by file copy; modules must
   be rebuilt/re-staged together with it.
5. 🔄 **Kernel rebuilt for systemd** (`Image-vt`, 29.5 MB, on ESP): +`DEVTMPFS(+MOUNT)`,
   `FHANDLE`, `VT`, `FB_EFI` (real /dev/fb0 from UEFI GOP), `FRAMEBUFFER_CONSOLE`, `AUTOFS`.
   All 43 modules rebuilt/restaged (same KVER `…7447a-dirty`, vermagic verified).
   **GRUB entry 9 (new default):** `Image-vt` + `initramfs-switch.gz` (43-module bring-up →
   ESP breadcrumb → mount archroot → devtmpfs → `switch_root` into systemd) +
   `console=tty0`. Rootfs prepped for blind boot: machine-id seeded, `garnet-esplog.service`
   (journal → `ESP:/logs/systemd-N.txt`), root autologin on tty1, firstboot masked.
   Entries 0–8 keep the old kernel as rollback. ← awaiting the boot.
## 🎉 MILESTONE 5 COMPLETE (2026-07-03): WI-FI WORKS — WPA2 + DHCP + internet over wlan0
WPSS co-processor boots stock fw (extracted from modem_b → /lib/firmware/adrastea) via TZ PAS;
glink/qrtr/QMI up; **`icnss2: WLAN FW is ready`**. Persisted as `garnet-wifi-fw.service`.
**qcacld-3.0 `wlan.ko` loaded (build 4 from 2026-07-02 was already good!), wlan0 associates to
the home AP at VHT80 MCS9 (866 Mbit PHY, −45 dBm), DHCP lease, curl/pacman over Wi-Fi work.**
Boot path persisted: `garnet-wifi-fw.service` now ends with `modprobe wlan` (no udev alias —
must be explicit); `wpa_supplicant@wlan0` enabled (conf was pre-staged); `25-wlan0.network`
DHCP metric 100; usb0 gateway demoted to metric 300 so Wi-Fi wins when both are up.
**THE bug (hours of debugging): `gEnableFastPath=1` was missing.** The driver was built with
only the fastpath TX path compiled (`ol_tx_ll_fastpath.c`), but the runtime switch is an ini
option defaulting to FALSE — Android ships it in `/vendor/etc/wifi/WCNSS_qcom_cfg.ini`, we had
no ini at all. Result: assoc + RX + scan all work (firmware/mgmt path), but `ol_tx_ll_wrapper()`
**silently drops 100 % of host TX** (incl. EAPOL 2/4) → AP retries 1/4 → supplicant reports
"4-Way Handshake failed - pre-shared key may be incorrect" with a PROVEN-correct PSK.
Fix: `/lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini` (path = `WLAN_INI_FILE`, MSM_PLATFORM
build) containing `gEnableFastPath=1`. See handoff.md "Wi-Fi debugging playbook" for how it
was found (ftrace kprobes + hist triggers; qcacld's own logging is a black hole).

## 🎉🎉 MILESTONE 4 COMPLETE (2026-07-02 ~20:30): SSH INTO THE PHONE OVER USB
**`ssh root@172.16.42.1` works.** Boot chain: entry 10 → Image-vt → initramfs-switch →
Arch/systemd → `garnet-usb-gadget.service` (runs at multi-user+10 s, strictly sequential:
phys → fake-vbus → dwc3-msm; udev autoload of those 4 modules is **blacklisted** — udev's
arbitrary-order coldplug of them was the last crash) → NCM gadget → networkd DHCP-server leases
the PC an address (PC got 172.16.42.14) → sshd. Ping 2.1 ms. 0 failed units. Phone clock now
synced over SSH (still add `rtc-pm8xxx` to the service later).
Serial console (ACM/ttyGS0) temporarily dropped from the gadget to match the proven minimal
config — re-add after a stability soak.

## Milestone 4 history: USB networking bring-up (the crash saga)
**Verified end-to-end from the initramfs (entry 11 v6): gadget enumerates on the PC
(`1d6b:0104 Multifunction Composite Gadget`), NCM ethernet link up, ARP + ICMP work —
`ping 172.16.42.1` = 3/3 packets, ~3 ms.** Remaining: wire the same recipe into Arch (entry 10)
→ sshd is already waiting there.

**The USB crash saga — full causal chain (5 distinct root causes):**
1. Full module tree in Arch → **udev coldplug loaded the mm-cc/kgsl zoo** → delayed SoC crashes
   (fixed: pruned 47-module allowlist).
2. Forcing role via **sysfs `mode_store` shortcut** → `dwc3_ext_event_notify` queues on a NULL
   workqueue → **kernel oops** → (with panic-on-oops/dload active under Arch) → **TZ orange
   crashdump**. Caught only when the initramfs environment survived the oops and preserved the
   backtrace (`mode_store → dwc3_msm_set_role → dwc3_ext_event_notify → __queue_work`, x0=0).
3. The driver's designed trigger is an **extcon cable event**; retail EUD hardware never sends
   one. Fix: **`extcon-fake-vbus.ko`** (new in-tree module, `drivers/extcon/extcon-fake-vbus.c`)
   binds the `qcom,msm-eud` DT node and permanently reports `EXTCON_USB=1`.
4. v5 failed silently: **dwc3-msm special-cases extcon devices whose name contains "eud"**
   (spoof-connect logic) — and extcon names are copied from the parent device
   (`88e0000.qcom,msm-eud`). Fix (v6): register the extcon on a child platform device named
   `fake_vbus.0` whose `of_node` still points at the EUD node (extcon phandle lookup matches on
   `parent->of_node`, name comes out clean).
5. (Also: `qcom,use-pdc-interrupts`/`usb-role-switch` quirks turned out to be red herrings;
   power/clocks were never the issue — v3/v4 proved GDSC+clk handling safe.)

## Milestone 4 original staging notes (historical)
All host-side work done; needs one entry-9 boot with the USB cable plugged into the PC.
- **Kernel already had everything built-in:** configfs + libcomposite + `f_ncm/f_ecm/f_rndis/
  f_acm` all `=y`; loadable pieces are `eud.ko` (extcon cable detect), `phy-msm-snps-hs.ko`
  (USB2 phy), `phy-msm-ssusb-qmp.ko` (USB3 phy), `dwc3-msm.ko` (controller). DT: `ssusb@a600000`
  (`qcom,dwc-usb3-msm`, extcon=EUD, all supplies/clks/ICC are rails we already bring up; no
  status=disabled anywhere; no DTB changes needed).
- **Arch rootfs now has the FULL 314-module tree** (`/lib/modules/<kver>/`, depmod done) —
  native `modprobe` works from here on.
- **`garnet-usb-gadget.service`** (enabled): modprobes the chain, waits ≤20 s for a UDC,
  **falls back to `echo peripheral > /sys/.../*.ssusb/mode`** (dwc3-msm sysfs, forces device
  role if EUD doesn't report the cable), then assembles configfs gadget `g1`: **NCM ethernet
  (usb0) + ACM serial (ttyGS0)**, binds UDC.
- **networkd**: usb0 = 172.16.42.1/24 + **DHCP server** → PC autoconfigures.
- **Access:** `ssh root@172.16.42.1` (host ed25519 key preinstalled in authorized_keys) or
  `ssh alarm@172.16.42.1` (pw `alarm`); serial fallback: PC sees `/dev/ttyACM0` → autologin
  root getty at 115200.
- Diagnose failures from `ESP:/logs/systemd-N.txt` (gadget script runs with `set -x`).
- If SS phy misbehaves: drop to USB2 (`maximum-speed=high-speed` DTB tweak) — SSH needs nothing
  more.

## 🚧 Milestone 6 (2026-07-03): USB HOST MODE — software side DONE, VBUS remains
Over Wi-Fi SSH (`ssh root@<phone-wifi-ip>`): gadget unbound, fake-vbus flipped to `host` →
dwc3-msm role-switched, **xhci-hcd registered, USB2+USB3 root hubs up, no crash**. HID/evdev/
USB-storage are built-in, so a keyboard enumerates as soon as it has power. **The phone cannot
source VBUS 5 V** (no charger driver; SM7435 OTG boost = pmic_glink → ADSP charger fw we don't
run) → **use a powered OTG hub/Y-cable**. Wi-Fi reboot-timing bug also fixed this session
(wpa_supplicant now started by garnet-wifi-fw.service after wlan loads).

## Later milestones
- **OTG keyboard (USB host mode):** same dwc3 stack + role switch + PMIC VBUS boost (5 V out).
- **RTC:** ship `rtc-pm8xxx` (SPMI works) so the clock is right (currently thinks it's May 28).
- **Desktop:** interim CPU-rendered Wayland (cage/weston on /dev/fb0) once input exists.
- **GPU (researched 2026-07-03):** route = **turnip (Vulkan) over KGSL** + zink for GL;
  freedreno GL impossible on 5.10 (needs drm/msm with a7xx). Adreno 710 only in
  community-patched Mesa (experimental). Blockers: gpu_cc/GDSCs currently disabled in DTB,
  kgsl fw/zap extraction, Mesa build. Full plan in `handoff.md` "GPU plan".
- **Durability:** re-arm slot B (`fastboot set_active b`) — many boots consumed retries;
  `fsck.vfat` the ESP; trim the initramfs module set.
3. **Rootfs:** put an aarch64 distro ext4 on a partition; `switch_root`. Add DEVTMPFS + init system.
4. **Console + input:** kernel rebuild for fbcon/simpledrm + VT + DEVTMPFS; USB HID keyboard.
5. **Durability:** mark slot B successful so `set_active b` isn't needed each boot.

## Key operational learnings 🔑
1. **Building modules with host clang 22** requires neutering `scripts/basic/cc-wrapper.c` (it fails
   the build on *any* new compiler warning). After that, full `make modules` is clean.
2. **`MODVERSIONS=y` + `LOCALVERSION_AUTO=y`** → modules must match the exact kernel. We only add
   `=m` symbols, so `out/Image` == flashed Image and the modules load. Rebuild single `.ko` via full
   incremental `make modules` (correct cross-module symbol CRCs), not `KBUILD_MODPOST_WARN=1`.
3. **busybox `modprobe` does not resolve deps** → load in `tsort` order with `insmod`.
4. **`/sys/kernel/debug/devices_deferred`** is the key on-device diagnostic for "why didn't X probe".
5. **Downstream vs mainline drivers matter:** the DTB uses `qcom,rpmh-{arc,vrm}-regulator` (→
   `rpmh-regulator.ko`), `qcom,ufshc`, `qcom,qsmmuv500-tbu`, etc. Pick the driver by DT `compatible`.
6. A/B: each power-on decrements slot B `retry-count` (starts 7); nothing marks success →
   `fastboot set_active b` re-arms. We re-arm on every flash.
7. **Mu-Silicium mass storage mode** exposes the whole UFS to the host (`GARNET-ESP` = `sdb32` by
   PARTLABEL) — the ESP is now edited directly, no fastboot. UFS logical block = **4096**, so the
   ESP was reformatted `mkfs.vfat -F 32 -S 4096` (512-byte-sector FAT boots on the phone but is
   unmountable on the host over mass storage).
8. **ramoops/pstore works** via the DTB node `ramoops@0xa7000000` (the sibling `ramoops_region`
   node is bogus and fails −22, benign). Don't add `ramoops.*` cmdline params — a second ramoops
   device over the same region conflicts. Crash capture only survives *warm* resets; the ~11 s
   reset is hard (DDR lost).
9. On-phone log partitions: `oops` (sdb15) = Xiaomi LAST-KMSG records but only harvested by
   Android/recovery boots; `logfs` (sdb13, vfat) = Qualcomm XBL-UEFI logs (5-boot rotation).
10. The **GRUB menu on the ESP** (8 entries: diag / storage / noufs / nogcc / storage+clk-pd-ignore
   / busybox / no-initramfs / storage+nommgdsc-DTB) makes every test a volume-key selection — one
   boot per experiment, zero host interaction.
11. **Downstream `gdsc-regulator.ko` probe is destructive on live domains:** it raw-RMWs the GDSCR
   (clears HW_CONTROL/SW_OVERRIDE) before regulator_register and honors `qcom,proxy-consumer-enable`
   at probe. Never let it touch clock-controller domains that firmware left running (the efifb
   display!) or whose AHB clock state is unknown. DTB-level `status=disabled` on the mm GDSC nodes
   is the safe knob (`fdtput -t s <dtb> /soc/qcom,gdsc@<addr> status disabled`).
12. **Filming the screen at 120 fps beats photos for crashes:** frame-stepping the video recovered
   ~15 dmesg lines past what stills showed and pinned the death to a 0.1 s window.

## Source patches applied (kernel tree is `-dirty`)
- `scripts/basic/cc-wrapper.c` — disable "forbidden warning" → build promotion.
- `drivers/interconnect/qcom/icc-rpmh.c` — `is_voter_disabled()` force-disables `disp`/`disp2`.
- `drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c` — `qsmmuv500_tbu_register()` skips unbound TBUs.
- `drivers/extcon/extcon-fake-vbus.c` — NEW module: fake VBUS extcon for dwc3-msm (M4).
- `drivers/gpu/drm/tiny/simpledrm.c` (+Kconfig/Makefile) — NEW module: v5.14 simpledrm
  backported to 5.10 (M7); self-creates its platform device (garnet fb defaults baked in).

## 🎉 MILESTONE 7 (2026-07-03): DESKTOP ON SCREEN — X11+i3 AND Wayland/sway
Stage 1: Xorg(fbdev)+i3+xterm on efifb — verified via fb screenshot over SSH.
Stage 2: simpledrm backport → **/dev/dri/card0** → **sway (Wayland) with swaybar+wallpaper
on the phone screen**, module-only (Image untouched, no reboot needed). Both recipes +
5.10 quirks in handoff.md Milestone 7. Remaining for a usable desktop: input (OTG keyboard
awaits powered hub; touchscreen driver unexplored).

## Paths / recipes — see `handoff.md`.
