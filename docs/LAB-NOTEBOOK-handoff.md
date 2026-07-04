# Handoff — Linux on Xiaomi garnet

_Last updated: 2026-07-03._ See `status.md` for full state + findings.

## 🎉 MILESTONE 5 COMPLETE (2026-07-03): WI-FI FULLY WORKING
`wlan0` up, WPA2 handshake completes, DHCP (<phone-wifi-ip>), internet + pacman over Wi-Fi,
VHT80 MCS9 866 Mbit PHY at −45 dBm, 0 TX drops, 0 kernel errors.

**The wlan.ko that worked was already on disk: build 4** (`modules/.../qcacld-3.0/wlan.ko`,
7.3 MB, 2026-07-02 23:34, MODNAME=wlan, profile parrot_gki_adrastea, overrides
`CONFIG_REMOVE_PKT_LOG=y CONFIG_QCA_WIFI_FTM=n CONFIG_WLAN_DEBUGFS=n
CONFIG_WLAN_MWS_INFO_DEBUGFS=n`). Builds 5/6 (log tails in build_qcacld{5,6}.log) were an
UNNEEDED detour: they tried to compile away the cnss_prealloc/cnss_nl/cnss_utils deps — but
those modules were already built in `out/` AND already staged on the phone. (Build 6's error:
`CONFIG_WLAN_FEATURE_CONNECTIVITY_LOGGING=n` is the wrong symbol; the file is gated by
`CONFIG_QCACLD_WLAN_CONNECTIVITY_LOGGING`. Irrelevant now — build 4 is fine as-is.)

**Root cause of the 4-way-handshake failure — memorize this one:**
- Symptom: scan OK, assoc OK, AP retries EAPOL 1/4, supplicant replies 2/4 (visible in tcpdump
  — tcpdump taps BEFORE the driver drop!), AP never accepts → "pre-shared key may be
  incorrect" (PSK was byte-identical to the host's working NM profile). `ip -s link` showed
  **TX dropped == TX packets (100 %)**.
- Cause: our Kbuild compiles ONLY `ol_tx_ll_fastpath.c` (WLAN_FEATURE_FASTPATH), whose
  `ol_tx_ll_wrapper()` requires `hif_is_fastpath_mode_enabled()` at runtime or it
  `qdf_print + QDF_BUG(0)` (both invisible) and returns the skb → HDD drops it. Runtime switch
  = ini `gEnableFastPath` (default **false**), read from
  **`/lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini`** (MSM_PLATFORM build ⇒ that exact path).
  Android ships this ini in /vendor; bare Arch had none.
- Fix (persisted on phone): that ini with `gEnableFastPath=1` (+`wlanConsoleLogLevelsBitmap=0x3f`
  for future debugging) → rmmod wlan; modprobe wlan → handshake completed instantly.

**Wi-Fi persistence (all done, survives reboot — untested until next reboot):**
- `wlan.ko` in `/lib/modules/<kver>/updates/` + depmod. No MODULE_DEVICE_TABLE aliases ⇒ udev
  can NOT autoload it ⇒ `garnet-wifi-fw.service` ends with `…; modprobe icnss2; sleep 5;
  modprobe wlan`.
- `wpa_supplicant@wlan0` enabled, conf `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`.
- networkd: `25-wlan0.network` (DHCP, RouteMetric=100); `20-usb0.network` gateway now
  `[Route] Gateway=172.16.42.2 Metric=300` so Wi-Fi is preferred, USB is fallback.
- Host NAT for USB-internet had to be re-applied after host reboot (ip_forward + MASQUERADE) —
  still not persisted on the host; with Wi-Fi up it matters less.

**Wi-Fi debugging playbook (qcacld logging is a BLACK HOLE — don't bother):**
qcacld QDF_TRACE goes to the wlan_logging sock-svc ring buffer; console output is gated by
BOTH per-category masks AND `wlanConsoleLogLevelsBitmap` (default 0x1e excludes INFO_HIGH
where all the interesting DATA-path messages live), and even fully opened we got nothing.
What actually worked — ftrace on the phone (`/sys/kernel/tracing`, NOT under debugfs):
1. `events/skb/kfree_skb` + `hist:keys=stacktrace` trigger → found the drop site
   (`hdd_hard_start_xmit`) without any driver cooperation. (`location` field is
   pointer-hashed; `.sym` modifier or stacktrace keys decode it.)
2. kprobes: `r:pstate ol_txrx_get_peer_state $retval` → peer state was 2 (CONN, correct);
   `p/r on ol_tx_data` → returned the skb (= rejected); `ol_tx_ll_fast` never hit → the
   `else QDF_BUG(0)` branch in `ol_tx_ll_wrapper` → fastpath disabled → ini. Gotchas:
   `tracing_on` must be 1 (kprobe_profile counts hits even when the buffer is off — that
   mismatch cost 20 min); wpa_supplicant temp-disables the network with growing backoff after
   failures — use `wpa_cli bssid_ignore clear` + `select_network 0` to force a fresh attempt.
3. `tcpdump -i wlan0 ether proto 0x888e` sees TX frames that the driver later drops — RX
   presence + AP retry pattern is what proves "our reply never hits the air".

**Next steps (updated):** RTC (`rtc-pm8xxx`) into boot path · ACM serial console re-add ·
OTG keyboard physical test (needs powered hub) · desktop (fbdev Wayland) · re-arm slot B ·
consider promoting Wi-Fi to the boot default path and demoting USB gadget to on-demand ·
GPU via turnip-on-KGSL (research done 2026-07-03, see "GPU plan" below).

## 🎉 MILESTONE 7 (2026-07-03): DESKTOP — Stage 1 (X11+i3) AND Stage 2 (simpledrm+sway) DONE
Both verified visually by dumping `/dev/fb0` over SSH and rendering to PNG on the host
(`ffmpeg -f rawvideo -pix_fmt bgra -s 1220x2712 -i fb.raw -frames:v 1 out.png` — ignore the
"trailing 3712 bytes" packet warning; the fb region is padded past the visible area).
- **Stage 1:** Xorg + xf86-video-fbdev + i3 + xterm work on efifb. Config:
  `/etc/X11/xorg.conf.d/10-fbdev.conf`, i3 default config copied to skip the wizard.
  Launch over SSH: `Xorg :0 vt2 -ac -noreset &` then `DISPLAY=:0 i3 &`. fastfetch in xterm
  on the phone screen showed "Snapdragon 7s Gen 2" (DTB compatible fix confirmed live) and
  a GPU line (llvmpipe). GOTCHA: never `pkill -f "Xorg :0"` over SSH — the pattern matches
  the SSH command line itself and kills your own session; use `pkill -x Xorg`.
- **Stage 2: simpledrm BACKPORTED, /dev/dri/card0 EXISTS, SWAY RUNS.**
  New file `kernel_sm7435/drivers/gpu/drm/tiny/simpledrm.c` (+Kconfig/Makefile entries,
  `CONFIG_DRM_SIMPLEDRM=m`) — v5.14 driver adapted to 5.10: no drm_aperture (coexists with
  efifb — fbcon stays on /dev/fb0, both write the same scanout memory, VT discipline keeps
  them apart), no shadow-plane helpers (vmap-per-blit like 5.10's tiny/cirrus.c), local
  blit dispatcher (5.10 lacks drm_fb_blit_dstclip; XRGB/ARGB8888 memcpy + 565/888
  conversion paths), no clk/regulator code. **Module-only: Image unchanged, no reboot was
  needed.** KEY 5.10 QUIRKS discovered: (a) this downstream tree REMOVED the
  /chosen/simple-framebuffer platform-device population from drivers/of/platform.c, so the
  module self-creates its platform device from params (defaults = garnet GOP fb:
  base 0xb8000000, 1220x2712, stride 4880, a8r8g8b8; `simpledrm.auto_dev=0` to disable);
  (b) 5.10's `drm_fb_memcpy_dstclip()` has no dst_pitch arg — it reuses fb->pitches[0],
  fine here because hw stride == fb pitch (probe refuses otherwise); (c) DRM core +
  DRM_GEM_SHMEM_HELPER were already =y in the GKI Image (only FBDEV_EMULATION is off —
  no fbcon-on-DRM, which we don't need). Landlock wishlist item is DEAD: 5.13+ only.
  Persisted: simpledrm.ko in `updates/`, `/etc/modules-load.d/simpledrm.conf`.
- **sway session recipe (no input devices yet):** `systemctl enable --now seatd` (done);
  alarm user in seat,video,input,wheel groups (done); `loginctl enable-linger alarm`
  (done — otherwise logind DELETES /run/user/1000 with sway's wayland socket in it when
  the last alarm login exits; cost us a broken session). Run:
  `runuser -u alarm -- env XDG_RUNTIME_DIR=/run/user/1000 WLR_LIBINPUT_NO_DEVICES=1
  WLR_BACKENDS=drm sway`. Apps: `env XDG_RUNTIME_DIR=/run/user/1000
  WAYLAND_DISPLAY=wayland-1 foot`. Verified: swaybar + wallpaper on screen.
- **Shared terminal (phone screen + SSH simultaneously):** foot runs
  `tmux new -A -s phone` inside sway (launch apps via `su - alarm -c "…"`, NOT bare
  runuser — foot needs alarm's HOME/cwd, inherited /root broke it). Attach from anywhere:
  `ssh -t alarm@<ip> tmux attach -t phone` (pw alarm). tmux mirrors keystrokes/output to
  all clients; sizes to the smallest one; `Ctrl-b d` detaches.
- **Root for the alarm user: opendoas** (`/etc/doas.conf`: `permit nopass :wheel`).
  `su` + Enter also works (root pw is empty). Root SSH stays key-only.
- Landlock note: pacman sandbox workaround (DisableSandbox*) stays permanently on this
  kernel.

## Display/desktop plan (discussed 2026-07-03 — Stages 1+2 DONE same day, see Milestone 7)
Constraint: we have `/dev/fb0` (efifb, dumb framebuffer), NO DRM/KMS device. That decides
everything — wlroots (sway/Phosh/cage), mutter (GNOME) and kwin (Plasma) all hard-require
DRM; Weston dropped its fbdev backend in 10.0. kmscube is not a desktop (DRM+GLES test
tool — keep it in mind as the smoke test once DRM+turnip exist).
- **Stage 1 (works today, zero kernel work): Xorg + xf86-video-fbdev** — the only
  mainstream display server that still runs on a dumb fb. Session: i3 or XFCE
  (keyboard-driven; our first input is the OTG keyboard). 
- **Stage 2 (recommended next kernel step): backport `simpledrm`** (~1k lines, mainline
  5.14+, we're 5.10) — wraps the firmware fb as a real DRM/KMS device. Same dumb scanout
  but unlocks ALL Wayland compositors, software-rendered. Then: **sway** as the daily
  desktop; **Phosh** later when touch works. No disp_cc/mm-GDSC risk.
- **Stage 3 (dangerous, later): downstream msm_drm/SDE from the display techpack** —
  real KMS + panel control; same mm-GDSC neighborhood as the GPU plan. Pairs with
  turnip-on-KGSL for acceleration (see GPU plan below; GBM-less accel is its own puzzle —
  Termux-style tricks).
Decision: avoid GNOME/Plasma (Wayland needs DRM; X11 sessions being phased out; too heavy
for CPU rendering). Path = Xorg+fbdev+i3 → simpledrm+sway → (touch) Phosh.

## GPU plan — turnip on KGSL (researched 2026-07-03, not started)
Decision from discussion with user: the viable GPU route on our 5.10 downstream kernel is
**Mesa turnip (Vulkan) over the downstream KGSL interface**, NOT freedreno GL.
- **freedreno GL is impossible here:** it requires the drm/msm kernel driver, and 5.10
  drm/msm has no Adreno 7xx support. GL would come via **zink on turnip** instead.
- **turnip has a KGSL backend:** build Mesa with `-Dfreedreno-kgsl=true` → talks to
  `/dev/kgsl-3d0` (this is how Android/Termux setups run Vulkan on stock kernels).
- **Adreno 710 (our GPU, Snapdragon 7s Gen 2) is NOT in upstream Mesa** — A710/A720 support
  is experimental, community-patched turnip only (reverse-engineered "magic regs" tables,
  e.g. a710-720.py injections). Reference build repos:
  github.com/The412Banner/Banners-Turnip · github.com/K11MCH1/AdrenoToolsDrivers.
- **Prerequisites on our side (the real work, ~2-3 sessions, crash risk in step 1):**
  1. Re-enable `gpu_cc` clock controller + the GPU GDSCs — they are among the 7 mm GDSC
     nodes we disabled in `garnet-sm7435-nommgdsc.dtb` for the 11 s reset fix. Likely safer
     than disp_cc was (GPU domain is not live at boot, unlike the efifb scanout), but same
     class of hardware. Load deliberately/sequenced, NEVER via udev coldplug (proven crash).
     Current dmesg symptom: `kgsl-smmu 3da0000: Couldn't get clock: gpu_cc_cx_gmu`.
  2. `msm_kgsl.ko` is parked in `/lib/modules-full.bak/kernel/drivers/gpu/msm/` on the phone.
     Needs Adreno SQE + GMU firmware + TZ-signed zap shader for a710, extracted from the
     phone's own vendor/modem partitions (same procedure as the WPSS `adrastea/` extraction).
  3. Build Mesa turnip aarch64 with KGSL backend + community A710 patches (on-phone build or
     cross). Test headless first: `vulkaninfo`.
  4. Scanout stays fbdev (`/dev/fb0`) — no DRM display driver, so compositor output is a CPU
     copy of GPU-rendered buffers. Acceptable for desktop, not full-speed.
- **fastfetch note:** even with working turnip, fastfetch's GPU line stays empty — it
  enumerates DRM/PCI devices and KGSL is neither. Cosmetic only.
- Agreed ordering: keyboard (powered hub) → fbdev Wayland desktop → this GPU work.

## 2026-07-03 session 2: Wi-Fi reboot fix + USB HOST MODE UP
- **Wi-Fi after reboot was down because of boot timing, not the driver:** wlan0 appears
  ~130 s into boot (slow boot), but `wpa_supplicant@wlan0`'s wait for the device unit times
  out at 90 s → service lands inactive. Fix (persisted): `garnet-wifi-fw.service` ExecStart
  chain now ends `…; modprobe wlan; sleep 3; systemctl start wpa_supplicant@wlan0 --no-block`.
  Also fixed: `systemd-networkd-wait-online` drop-in (`--any`) so it stops failing at boot.
- **SSH over Wi-Fi works: `ssh root@<phone-wifi-ip>`** (host and phone on the same LAN) —
  this frees the USB port for role experiments. IP is DHCP; check the router or the phone
  screen if it changes.
- **USB HOST MODE VERIFIED (software side complete):** over Wi-Fi SSH:
  `echo "" > /sys/kernel/config/usb_gadget/g1/UDC` (unbind gadget), then
  `echo host > /sys/module/extcon_fake_vbus/parameters/mode` → dwc3-msm switches role,
  **xhci-hcd registers, USB2+USB3 buses + root hubs appear, no crash** (`lsusb` shows
  1d6b:0002/0003; usbutils installed). Controller auto-enters low power with nothing
  attached; if a plugged device isn't detected, bounce the mode (`none` → `host`).
  Switch back: `echo peripheral > …/mode` then `systemctl restart garnet-usb-gadget`.
  After reboot the gadget service runs as before — host mode is opt-in at runtime.
- **VBUS blocker (the remaining OTG work):** the phone does NOT source 5 V. dwc3-msm has no
  vbus regulator; the garnet DTB has no charger/OTG-boost node; on SM7435 the OTG boost is
  commanded via pmic_glink → charger firmware on ADSP (not running). Options: (a) **powered
  OTG hub / Y-cable — recommended, zero kernel work**; (b) research ADSP pmic_glink charging
  stack (deep); (c) direct SPMI pokes at the charger boost (risky, hardware-specific).
  "`msm-usb-hsphy 88e3000.hsphy: Could not get usb psy`" in dmesg is the missing
  power-supply class — benign.
- **Cosmetic: fastfetch CPU name fixed via DTB.** fastfetch names the SoC from the LAST entry
  of `/sys/firmware/devicetree/base/compatible` (was `qcom,qrd` → showed "qrd"; for qcom it
  prints the model verbatim unless it starts with "x"/"sc"). Both dist DTBs now have
  `compatible = "qcom,parrot-qrd", "qcom,parrot", "qcom,qrd", "qcom,sm7435",
  "qcom,Snapdragon 7s Gen 2"` (last entry is what fastfetch shows; nothing in kernel/userspace
  matches root compatible — verified by grep). ESP copies updated in-place from the phone
  (`/dev/sda32` mounted at /mnt/esp over SSH — no mass-storage round-trip needed anymore).
  Effective next reboot. The "2 x … (4+4)" prefix is separate (two CPU clusters report
  distinct package ids) — left as is.

## TL;DR — ALL FOUR MILESTONES DONE IN ONE DAY (2026-07-02)
M1 Linux boots (prior) · M2 UFS storage · M3 Arch+systemd+console on screen · **M4 SSH over
USB: `ssh root@172.16.42.1` (entry 10, gadget service = phys → fake-vbus → dwc3-msm, udev
blacklisted for those 4; PC auto-DHCPs from the phone) — AND INTERNET + PACMAN WORK.**
Internet sharing: host NM profile `garnet-usb` pins 172.16.42.2/24 on the gadget iface
(survives replug; a fresh DHCP lease had silently replaced the manual addr once — symptom:
phone can't reach gateway), host does sysctl ip_forward + iptables MASQUERADE out the uplink
(re-apply after host reboot or persist), phone has `Gateway=172.16.42.2` persisted in
networkd + static resolv.conf (1.1.1.1). **pacman gotcha: kernel lacks Landlock → enable
`DisableSandboxFilesystem`+`DisableSandboxSyscalls` in pacman.conf** (done; add
`CONFIG_SECURITY_LANDLOCK` to the next kernel build wishlist alongside `CONFIG_DEVMEM`);
keyring initialized; htop installed as proof. Working access: entry 9 = local console,
**entry 10 = daily driver (SSH + internet)**. Next: RTC in boot path, ACM serial console
re-add, OTG host mode (keyboard), Wi-Fi, desktop (fbdev Wayland first).

## 🚧 Milestone 5 (Wi-Fi) — PLATFORM SIDE DONE (2026-07-02 night), driver build remains
All over SSH, no reboots needed. **Working: WPSS remoteproc boots stock firmware
(`remoteproc3` = `qcom,parrot-wpss-pas` @8a00000, fw `adrastea/wpss.mdt` — extracted from the
phone's own `modem_b` partition `image/adrastea/` → `/lib/firmware/adrastea/`, 64 MB incl.
`bd_*.bin` board files) → glink/qrtr/QMI up → `icnss2: WLAN FW is ready: 0x487`.**
Module chain (now in phone tree, persisted as `garnet-wifi-fw.service`): qcom_ipcc → qcom_aoss
→ qcom_glink_smem → smp2p (module is `smp2p.ko`, NOT qcom_smp2p!) → qrtr-smd → qcom_q6v5_pas
(+ `echo start > /sys/class/remoteproc/remoteproc3/state`; downstream doesn't auto-boot) →
icnss2. 26-module closure shipped from modstage; icnss2+q6v5_pas blacklisted from udev autoload.
adsp/cdsp/mss remoteprocs also registered (harmless; no fw staged for them).
**REMAINING: build qcacld-3.0** (`~/garnet_linux/modules/qcom/opensource/wlan/`) as external
modules against `out/` — that creates `wlan0`; then `pacman -S wpa_supplicant iw` (internet via
USB works) + connect. Also still open: slow-boot investigation (one entry-10 boot took ~2 min —
looked "dead" because console is quiet now; journal will say which job stalled), RTC module into
boot path, OTG host mode later (fake-vbus v3 has runtime `mode` param: peripheral/host/none at
`/sys/module/extcon_fake_vbus/parameters/mode`; `panic_on_oops=0` persisted on phone).

## Milestone 2 history (2026-07-02): UFS WORKS, /dev/sd* enumerated
GRUB entry 7 (default) boots the 43-module storage initramfs with the mm-GDSC-disabled DTB and
brings up the **entire internal UFS**: all LUNs, main GPT with 71 partitions, ~224 GiB disk
(video: `pics/VID20260702141744.mp4`). Five blockers were root-caused and fixed today, in order:
1. **~11 s PMIC hard reset** — gcc registration unblocked the 7 multimedia `qcom,gdsc` probes;
   `gdsc-regulator.ko` raw-RMWs GDSCRs + proxy-enables the live (efifb) display GDSC → MDSS
   collapse → PS_HOLD drop (XBL logfs: `Reset by PSHOLD / Hard Reset`).
   Fix: `garnet-sm7435-nommgdsc.dtb` (7 nodes `status=disabled`).
2. **cpufreq gate** — `ufs_qcom_probe()` defers until CPU0 has a cpufreq policy.
   Fix: + `qcom-cpufreq-hw.ko`.
3. **qfprom nvmem devlink (dormant)** — ufshc reads fuse cell `boot_conf`.
   Fix: + `nvmem_qfprom.ko`.
4. **SPMI SDAM nvmem cell (`ufs_dev`) — the INVISIBLE one**: supplier device didn't exist →
   fw_devlink `needs_suppliers` wait list → no devlink object, no dmesg, `-517 after 0 usecs`.
   Only `waiting_for_supplier=1` betrays it. Fix: + SPMI chain (`regmap-spmi`,
   `qti-regmap-debugfs`, `spmi-pmic-arb`, `qcom-spmi-pmic`, `nvmem_qcom-spmi-sdam`).
5. (Instrumentation) `/dev/kmsg` ratelimit, self-matching greps, wrong sysfs names — see the
   silent-defer checklist below.
**NEW WORKFLOW (v8, on ESP): the initramfs mounts GARNET-ESP and writes full logs to
`ESP:/logs/boot-N.txt` (+ `-live.txt` refreshed every heartbeat). Read files over mass storage —
no more screen photos.** `initcall_debug` removed from entry 7 again (faster boots).
**Milestone 3 underway (same day):** user chose **Arch Linux ARM on the old userdata partition**
(Android sacrificed). userdata = phone `sda34` / host `sdX34` (223.9 GiB) → reformatted ext4
label `archroot`, ArchLinuxARM-aarch64 tarball extracted from the host over mass storage.
**GRUB entry 8 (default): `initramfs-arch.gz`** — 43-module chain → mount archroot by GPT name
+ ESP → **chroot smoke test PASSED on device** (`ESP:/logs/arch-1.txt`): *Arch Linux ARM,
aarch64, 165 packages, bash 5.3.12, glibc 2.43 on our 5.10.252 kernel, rc=0*. Root password
emptied for future console login. (Gotcha fixed on the way: initramfs had no `/tmp`, so the
first test's output redirect failed silently — rc/output_bytes now always logged.)
**🎉 MILESTONE 3 CONFIRMED ON DEVICE:** `Welcome to Arch Linux ARM`, full systemd boot with
**0 failed units**, fbcon console on the phone screen, **auto-login root shell on tty1**
(`login[553]: ROOT LOGIN ON tty1`). Journals in `ESP:/logs/systemd-{0,1}.txt`. Cosmetic only:
spmi transaction-failed(0x3) once, udev ACL warnings, ESP FAT dirty bit. No RTC yet (clock says
May 28) → add `rtc-pm8xxx`. OTG keyboard doesn't work: no USB stack loaded at all (host mode
additionally needs VBUS boost). **Milestone 4 in progress — crash saga resolved to a udev-coldplug problem:** installing the
FULL 314-module tree into Arch let systemd-udevd autoload the whole zoo (dispcc/camcc/gpucc/
videocc, kgsl, icnss2, q6v5, sdhci…). Under `fw_devlink=on` those probes were silently blocked
(benign no-op boots); after adding `fw_devlink=permissive` (needed for USB) every boot crashed
— entry 10 → Xiaomi crashdump, even gadget-masked entry 9 → delayed hard reset (late clk/
regulator cleanup or kgsl touching unpowered mm hardware — same class as the 11 s reset).
**USB itself is EXONERATED: boot-#3 log shows ssusb/hsphy/ssphy/eud ALL BOUND cleanly.**
Fix: Arch `/lib/modules/<kver>` pruned to a **47-module allowlist** (the 43 + phy-msm-snps-hs +
phy-msm-ssusb-qmp + dwc3-msm + rtc-pm8xxx), depmod'd; full tree parked at
`/lib/modules-full.bak` (move modules back one-by-one as hardware gets enabled properly).
GRUB: **entry 9 = SAFE Arch** (`systemd.mask=garnet-usb-gadget.service`, default), **entry 10 =
USB gadget test** (cmdline adds `fw_devlink=permissive consoleblank=0` on both). Gadget script
v3 writes sync'd breadcrumbs to `ESP:/logs/usb-bisect.txt` before/after each step, forces
`mode=peripheral` at t+3 s (no eud needed), refuses dummy_udc. Host watcher armed for
`1d6b:0104`; on enumeration: PC gets DHCP from phone, `ssh root@172.16.42.1`.

**🎉 USB SOLVED (2026-07-02 late evening) — see status.md for the 5-cause chain.** Short form:
never use dwc3-msm's sysfs `mode` to start a role (NULL-wq oops → crashdump); feed it a cable
event via extcon instead. **`extcon-fake-vbus.ko`** (in-tree, `drivers/extcon/extcon-fake-vbus.c`,
`obj-m` in extcon Makefile) binds the `qcom,msm-eud` node, registers the extcon on a child pdev
named `fake_vbus.0` (dwc3-msm blackholes extcon names containing "eud"; names copy from parent
dev; phandle lookup matches `parent->of_node` — both facts load-bearing), reports EXTCON_USB=1.
Load order: phys → fake-vbus → dwc3-msm; driver then does role-start itself, UDC appears,
configfs NCM gadget binds, **enumeration + ping verified from the entry-11 initramfs (172.16.42.1,
3 ms)**. Host-side gotcha: NetworkManager can drop a manually-added address — verify with
`ip route get 172.16.42.1` before blaming the phone (ARP via `arping -I` worked all along).
`CONFIG_DEVMEM=y` still worth adding next kernel build.
Mu-Silicium Discord: no specific USB intel ("downstream will really not be usable" sentiment).
**Lessons paid for in boots:** (1) `switch_root` MUST be `exec`'d (PID 1) — capturing its exit
code by dropping exec guarantees exit-1 failure; (2) partition uevents lag disk enumeration —
findpart needs a retry loop (added); (3) NEVER give Arch the full module tree — udev coldplug
loads the mm-cc/kgsl zoo and crashes the SoC (pruned 47-module allowlist live, full tree parked
at `/lib/modules-full.bak`); (4) `consoleblank=0` or fbcon blanks at 10 min and looks like a
crash. GRUB default = entry 9 (stable Arch milestone, re-verified after the exec fix).

**Kernel rebuilt for systemd (`Image-vt` on ESP, boot-confirmed):** +`DEVTMPFS(+MOUNT)`,
`FHANDLE`, `VT`, `FB_EFI`, `FRAMEBUFFER_CONSOLE`, `AUTOFS`; same KVER, all 43 modules rebuilt
and restaged into **`initramfs-switch.gz`** (bring-up → ESP breadcrumb `switchroot-last.txt` →
mount archroot → devtmpfs → `exec switch_root` into systemd; on failure it stays alive
repeating the reason on screen). **GRUB entry 9 = default**, cmdline `console=tty0` (+earlycon
kept). Rootfs prepped for blind boot: machine-id seeded, `garnet-esplog.service` → journal to
`ESP:/logs/systemd-N.txt`, root autologin on tty1, firstboot masked. Entries 0–8 = old kernel
rollback. Expected on screen: penguin-less fbcon text, systemd unit output, `login:` autologin
root shell. Diagnose failures from ESP logs (`switchroot-last.txt`, `systemd-*.txt`).
Then: USB gadget (dwc3) console; re-arm slot B (`fastboot set_active b`) — many retries used.

## Environment / paths
| Thing | Location |
|-------|----------|
| Project root | `~/garnet_linux` |
| Kernel source (5.10.252, `lineage-23.2`) | `~/garnet_linux/kernel_sm7435` (now **-dirty**, 3 patches) |
| Device trees (`dts/vendor` symlink target) | `~/garnet_linux/devicetrees` |
| Kernel build output (Image + **314 .ko**) | `~/garnet_linux/out` |
| **Staged boot artifacts** | `~/garnet_linux/dist/` |
| Scratch (initramfs tree, module staging, esp.img, video frames) | session scratchpad |

`uname -r` = **`5.10.252-gki-gad48dfa7447a-dirty`** (modules must live in `/lib/modules/<that>/`).

### `dist/` artifacts
- `grubaa64.efi`, `Image-garnet-efifb` (== `out/…/Image`), `garnet-sm7435.dtb` — unchanged.
- **`garnet-sm7435-nommgdsc.dtb` (NEW, session 3)** — copy of the DTB with the 7 enabled
  cam_cc/disp_cc/gpu_cc/video_cc GDSC nodes set `status=disabled` via
  `fdtput -t s … /soc/qcom,gdsc@{adf4004,af09000,af0b000,3d99108,3d9905c,aaf81a4,aaf5004} status
  disabled`. GCC GDSCs (incl. `gcc_ufs_phy_gdsc`) + hlos1_vote TBU GDSCs untouched. **On ESP.**
- `grub.cfg` — **8-entry menu, default = entry 7** (storage initramfs + nommgdsc DTB). **On ESP.**
- `initramfs.gz` — storage initramfs **v5: 37 modules** (+ `qcom-cpufreq-hw.ko`). /init evolution
  this session: v2 +cpufreq module; v3 +`printk_devkmsg=on` (the default ratelimit silently DROPS
  heartbeat bursts — big earlier confusion source); v4 correct bind-check device names
  (`1d87000.ufsphy_mem`, not `.ufsphy`!) + `@@` prefix on all our output so the dmesg grep can
  exclude itself (recursion polluted v3); v5 heartbeat prints **devlink statuses touching ufshc**
  (`/sys/class/devlink/*1d84000.ufshc*/status` — names the blocking supplier), **`probe of …`
  lines from `initcall_debug`** (GRUB entry 7 now passes `initcall_debug` — every probe attempt +
  return code, catches SILENT defers), ufs/tcxo clk presence, ufs regulator presence.
  **On ESP as `initramfs-storage.gz`.** Unpacked tree: session-3 scratchpad `irfs-x/`
  (re-extractable from the .gz itself).
  **v5 verdict (one boot):** the silent defer was fw_devlink blocking ufshc on the dormant
  supplier **`221c8000.qfprom`** (nvmem cells `ufs_dev`/`boot_conf`); `probe of 1d84000.ufshc
  returned -517 after 0 usecs` = probe fn never entered, which is why dmesg was empty. All other
  suppliers verified available. **v6: + `nvmem_qfprom.ko` = 38 modules** — fixed that link, but
  ufshc still deferred. **v7 (on ESP): + the SPMI chain (`regmap-spmi`, `qti-regmap-debugfs`,
  `spmi-pmic-arb`, `qcom-spmi-pmic`, `nvmem_qcom-spmi-sdam`) = 43 modules.** The second nvmem
  cell (`ufs_dev`) lives in **pmk8350 `sdam@7000` behind SPMI**; with no SPMI drivers that
  supplier *device never exists*, so 5.10 fw_devlink holds ufshc on the **invisible
  `needs_suppliers` list** — no devlink object, nothing in `/sys/class/devlink`; only the
  per-device sysfs attr **`waiting_for_supplier`** (now in the heartbeat) betrays it.
  Full silent-defer checklist: (1) `waiting_for_supplier` attr; (2) devlink `status` =
  `dormant`; (3) `initcall_debug` — in this tree the devlink check is INSIDE the timed window,
  so `-517 after 0 usecs` = supplier-blocked, driver code never entered.
- `initramfs.gz` — **storage initramfs**: BusyBox + 36 `.ko` + ordered `/init`.
- `initramfs-diag-pstore.gz` — **diag initramfs**: mounts pstore, proves ramoops attach, cycles
  `console-ramoops` tail on screen (source `scratchpad/irfs-diag/`).
- `initramfs-storage-noufs.gz` / `initramfs-storage-nogcc.gz` — bisect variants (load-order minus
  `ufs_qcom.ko`, minus `ufs_qcom.ko`+`gcc-parrot.ko`).
- `initramfs-busybox-only.gz` — the Milestone-1 RAM-only initramfs (rollback).

## Source patches (why the tree is `-dirty`)
1. `scripts/basic/cc-wrapper.c` — the downstream wrapper fails the build on *any* compiler warning
   not in a tiny allowlist; host clang 22 emits many. Neutered so warnings never fail the build
   (real errors still do). **Required to `make modules` at all.**
2. `drivers/interconnect/qcom/icc-rpmh.c` — `is_voter_disabled()` now returns true for `"disp"`/
   `"disp2"` unconditionally. The display RSC `rsc@af20000` never probes, so its "disp" bcm-voter is
   absent; without this, `mc_virt`/`gem_noc`/`mmss_noc` fail to register and block UFS + the SMMU.
3. `drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c` — `qsmmuv500_tbu_register()` skips (`return 0`) a TBU
   whose probe failed instead of aborting the whole `apps-smmu`. The multimedia TBUs fail (no mmss
   power); UFS uses the **anoc** TBU (SID `0x80`), which binds fine.

## Rebuild the modules (from scratch, ~10 min)
```bash
cd ~/garnet_linux/kernel_sm7435
ln -sfn ../devicetrees arch/arm64/boot/dts/vendor
# (cc-wrapper.c patch must be present, else the build dies on the first warning)
make O=../out ARCH=arm64 LLVM=1 LLVM_IAS=1 KCFLAGS="-Wno-error" -j"$(nproc)" modules
# rebuild ONE module after a patch (correct MODVERSIONS CRCs) — just re-run the same line;
# only the changed .o recompiles + a fast full modpost. Do NOT use single-.ko targets
# (KBUILD_MODPOST_WARN) with MODVERSIONS — cross-module symbol CRCs come out wrong.
```
Config already has: `REGULATOR_RPMH=m` (the driver the DTB needs), `SCSI_UFS_QCOM=m`, `ARM_SMMU=m`,
`SM_GCC_PARROT=m`, `QCOM_CLK_RPMH=m`, `PHY_QCOM_UFS*=m`, `INTERCONNECT_QCOM_PARROT=m`,
`QCOM_{SMEM,SCM,COMMAND_DB,RPMH,RPMHPD}=m`, `REGULATOR_QCOM_RPMH=m` (mainline, unused here).

## Stage the UFS module closure into the initramfs
`scratchpad/stage_modules.sh` does it end-to-end. The gist:
1. `make … INSTALL_MOD_PATH=<stage> modules_install` (runs depmod).
2. Closure = `modprobe -d <stage> -S <kver> --show-depends <leaves>` unioned. Leaves incl.
   `ufs_qcom arm_smmu phy-qcom-ufs-qmp-v4-parrot gcc-parrot clk-rpmh pinctrl-parrot rpmhpd
   qcom_rpmh cmd-db smem qcom-scm qnoc-parrot icc-rpmh icc-bcm-voter` **and `rpmh-regulator`**.
3. Copy that subset into `irfs/lib/modules/<kver>/`, `depmod -b irfs -F out/System.map <kver>`.
4. **Load order** (`irfs/lib/modules/<kver>/load-order.list`): `tsort` of `modules.dep`, filtered to
   the shipped set, `qcom_hwspinlock` forced first (smem needs its device at runtime). `/init`
   `insmod`s these in order; deferred-probe then binds devices regardless of order.

## NEW (2026-07-02): mass-storage workflow — no more fastboot esp.img round-trips
Mu-Silicium has a **USB mass storage mode** (user selects it on the phone) that exposes the whole
UFS: `GARNET-ESP` = `/dev/sdb32` (find with `lsblk -o NAME,PARTLABEL`). The ESP was **reformatted
in-place with `mkfs.vfat -F 32 -S 4096`** (UFS logical block = 4096; the old 512-byte-sector FAT
booted on the phone but was NOT host-mountable over mass storage — "logical sector size too small").
Now: `sudo mount /dev/sdb32 <dir>` → edit files → `umount` + `sync`. Current ESP contents:
`EFI/BOOT/BOOTAA64.EFI`, `Image`, `garnet-sm7435.dtb`, `grub.cfg` (**stale: 7-entry menu**), and
`initramfs-{diag,storage,noufs,nogcc,bb}.gz` (diag = pstore/ramoops dumper; noufs/nogcc =
load-order bisect variants; bb = milestone-1 rollback).
ESP is current as of session 3 part 2: `garnet-sm7435-nommgdsc.dtb`, 8-entry `grub.cfg`
(default = 7), and the 37-module `initramfs-storage.gz` are all on it. Note the mass-storage
device letter can change between plug-ins (`sdb32` → `sdc32`) — always re-check
`lsblk -o NAME,PARTLABEL | grep GARNET-ESP`.
Fallback if the 4096-sector FAT won't boot: `dd` the old 512-sector `scratchpad/esp.img` back
to `/dev/sdb32` (or `fastboot flash GARNET-ESP esp.img`).

Other on-phone log sources found via mass storage: `logfs` (sdb13, vfat) = Qualcomm XBL-UEFI logs
(5-boot rotation, no Mu-Silicium/GRUB entries); `oops` (sdb15) = Xiaomi "LAST KMSG" records, but
only harvested by Android/recovery boots (our crashes never appear). `crash_history`/`minidump`/
`rawdump` exist but unexamined.

## Repack initramfs + build esp.img (OLD fastboot path — superseded by mass storage above)
```bash
cd <scratchpad>/irfs
find . -print0 | sort -z | cpio --null -o -H newc | gzip -9 > ~/garnet_linux/dist/initramfs.gz
cd <scratchpad>
rm -f esp.img && truncate -s 256M esp.img && mkfs.vfat -F 32 -n GARNETESP esp.img
sudo mount -o loop esp.img m && sudo mkdir -p m/EFI/BOOT
sudo cp ~/garnet_linux/dist/grubaa64.efi       m/EFI/BOOT/BOOTAA64.EFI
sudo cp ~/garnet_linux/dist/Image-garnet-efifb m/Image
sudo cp ~/garnet_linux/dist/garnet-sm7435.dtb  m/garnet-sm7435.dtb
sudo cp ~/garnet_linux/dist/grub.cfg           m/grub.cfg
sudo cp ~/garnet_linux/dist/initramfs.gz       m/initramfs.gz
sync && sudo umount m
```
(No arm64 mtools on host; passwordless `sudo` works, so loop-mount is fine. Only `initramfs.gz`
changes between iterations — Image/DTB/GRUB are constant.)

## Boot flow (current)
Power on slot B → Mu-Silicium → GRUB **menu** (5 s timeout; volume keys move selection, power
selects; user-confirmed working). Default = entry 0 DIAG on the (stale) ESP copy; the updated
`dist/grub.cfg` makes entry 7 (reset-fix test) the default once copied over. Iterate by editing
the ESP over mass storage — reflashing is only needed if the ESP itself breaks.

## Flash + boot — OLD fastboot path (phone in fastboot, serial `<your-fastboot-serial>`)
```bash
fastboot flash GARNET-ESP esp.img   # targets the GPT label; can't hit the wrong partition
fastboot set_active b               # re-arm slot B (A/B retry counter) — do EVERY flash
fastboot reboot                     # watch the phone screen
```
No serial/adb → the **phone screen is the only output**. Photograph it (drop into `~/garnet_linux/
pics/`; images/video are readable here — extract video frames with `ffmpeg -i vid.mp4 -vf fps=1 …`).
`/init` reprints diagnostics every 20 s in the heartbeat, so any late photo catches the state.

## `/init` behavior (storage stage)
Mounts proc/sys/**debugfs**, mknods a minimal `/dev`, `exec >/dev/kmsg` (→ efifb), ordered-`insmod`
the 36 modules, `mdev -s`, waits ≤40 s for `sd*`, then loops every 20 s printing:
`sd*` count · `ufshcd-qcom` bind status · **`/sys/kernel/debug/devices_deferred`** · UFS/regulator
dmesg tail. Emits dmesg line-by-line (one `write()` per line) to stay under the `/dev/kmsg` size
limit.

## Diag initramfs (pstore/ramoops recovery) — built + tested 2026-07-02
The flashed DTB has `/reserved-memory/ramoops@0xa7000000` (2 MB console zone) and the kernel has
`PSTORE_RAM/PSTORE_CONSOLE=y`. `initramfs-diag.gz` (GRUB entry 0, default) mounts `/sys/fs/pstore`,
prints attach proof (dmesg ramoops lines, `/sys/module/pstore/parameters/backend`), and cycles the
last ~132 lines of `console-ramoops` on screen in 3 windows × 44 lines every 25 s. Source:
`scratchpad/irfs-diag/`.

**Verified on-device:** the DT ramoops works every boot — `ramoops_region` (bogus node, no reg)
fails with `-22` (benign), then `ramoops@0xa7000000` registers: `pstore: Registered ramoops as
persistent store backend`, `console [ramoops0] enabled`, `ramoops: using 0x400000@0xa7000000`.
Do NOT add `ramoops.mem_address=…` cmdline params: they create a second conflicting ramoops device
over the same region with a different zone layout (tried, reverted).

**Capture verdict (key finding):** STORAGE boot (crash at ~11 s, console recorded from ~6.1 s) →
warm reboot → DIAG boot shows **pstore EMPTY**. Stock Xiaomi warm resets preserve this region (the
`oops` partition holds harvested LAST KMSG records), so the ~11 s reset is a **DDR-losing hard
reset (PMIC-level / XBL scrub on abnormal reset), not a kernel panic**. pstore cannot capture this
crash; use the screen (efifb renders dmesg up to the death) + bisect instead. DIAG boot itself runs
350 s+ stable → the reset needs the module set.

Unexplained (now moot, pre-ESP-rework): one `fastboot reboot` attempt went away 90 s and returned
to a **wedged** ABL fastboot (getvar OK at first, then all commands hung; retry consumed exactly 1).

## The ~11 s reset — LOCALIZED (session 3); one boot needed to confirm the fix
- **Frame-level timeline from the crash video** (`pics/VID20260701235318.mp4`, 120 fps; blackout
  at video t≈28.7 s; extract with `ffmpeg -ss 27 -to 29.2 -i … -vf fps=30 g%03d.png`, last lit
  frame = g051):
  `rpmh_regulator_probe` 9.5–10.15 s (gcc/TBU GDSCs get `pm6450_s1_level`; benign
  `smpb9/ldob8/ldob17/ldog2..6: could not find RPMh address`) → `gcc-parrot …: Registered GCC
  clocks` 10.19 → `cam_cc_camss_top_gdsc: supplied by pm6450_s1_level` 10.20 →
  **`disp_cc_mdss_core_gdsc: supplied by pm6450_s1_level` 10.22 = last line ever.** Screen black
  ≤0.3 s later. `disp_cc_mdss_core_int2_gdsc` (next in probe order) never printed.
- **Why (code):** `gdsc-regulator.c` probe order is gated by `devm_clk_get("ahb_clk")` → all 7
  enabled mm GDSCs (cam/disp/gpu/video CC) probe the moment gcc registers. Probe then (a)
  raw-RMWs GDSCR clearing `HW_CONTROL|SW_OVERRIDE` (no clk mgmt, before regulator_register), and
  (b) for `disp_cc_mdss_core_gdsc`, `qcom,proxy-consumer-enable` + shipped `proxy-consumer.ko`
  **enables it at probe**. The MDSS domain is live (efifb scanout) → collapse/hang → secure
  watchdog → PMIC cold reset (instant black screen, DDR lost, no oops).
- **Fix candidate:** boot **GRUB entry 7** (`garnet-sm7435-nommgdsc.dtb` + storage initramfs).
  Expected: probes sail past 10.2 s, UFS binds, heartbeat shows `/dev/sd*`.
- **If entry 7 still resets:** bisect entries 2/3/4 (predictions now: 2 = resets, 3 = clean —
  without gcc the mm GDSCs defer forever, 4 = resets), then single-step the last modules in
  `/init` with `sleep 2` + markers.

## A/B slot gotcha
Each power-on decrements slot B `retry-count` (starts 7); nothing marks success → eventually
`unbootable` → bootloops on slot A. **Fix:** `fastboot set_active b` (re-arms to 7). Check:
`fastboot getvar slot-retry-count:b` / `slot-unbootable:b`.

## References
- Kernel: `github.com/LineageOS/android_kernel_xiaomi_sm7435` (`lineage-23.2`, 5.10.252)
- DTs: `…_sm7435-devicetrees` · Modules: `…_sm7435-modules` (both `lineage-23.2`)
- Mu-Silicium: `github.com/Project-Silicium/Mu-Silicium`
