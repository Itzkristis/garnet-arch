# Linux on the Xiaomi garnet (Redmi Note 13 Pro 5G / Poco X6 5G)

Everything here exists so that **anyone with their own garnet** can do the same
thing from clean upstream sources: the kernel patches, two new drivers, the
kernel config, the init scripts, the exact module load order, the systemd
services, and a numbered script pipeline that takes you from `git clone` to a
booting phone. If you get stuck, the entire debugging saga is preserved in
[`docs/`](docs/) as a lab notebook — every dead end included.

> **Before anything else, read [`PREREQUISITES.md`](PREREQUISITES.md).** It
> covers the unlocked-bootloader requirement, host packages, and — important —
> the fact that this **wipes your Android userdata**. Then follow
> **[`INSTALLATION.md`](INSTALLATION.md)** for the step-by-step.

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
| 8 | **GPU acceleration** — the Adreno 710 executes Vulkan via **turnip on KGSL**, and **OpenGL 4.6 via zink**; glxgears runs GPU-rendered on the phone screen under Xorg | ✅ |
| 9 | **Touchscreen + on-screen keyboard** — Goodix GT9916S multitouch (10-point) via geni-SPI, sway sees it through libinput, **squeekboard** toggled by Volume-Up. The phone is usable standalone — no OTG keyboard needed | ✅ |

A few hardware facts to orient you: garnet is an A/B device, Mu-Silicium lives
on **slot B** (`boot_b`), and the kernel is LineageOS's downstream
**5.10.252** GKI tree (`uname -r` reports `-dirty` because of our patches —
that's expected).

---

## Repository layout

```
github/
├── README.md                     ← you are here (what works + how it works)
├── PREREQUISITES.md              ← read first (hardware, bootloader, host packages)
├── INSTALLATION.md               ← the step-by-step install + optional extras
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

## Installation

The full step-by-step is in **[`INSTALLATION.md`](INSTALLATION.md)**. It's in
two halves: a **core install** that gets you a booting Arch Linux reachable
from your PC over the USB cable (USB tethering + SSH), and an **optional /
recommended** half for Wi-Fi, the sway desktop and its autostart, the
on-screen keyboard, GPU acceleration, the touchscreen, and keyboard shortcuts
(including how to add your own).

The short version of the pipeline (all scripts run from `$ROOT/github`, with
`$ROOT=$HOME/garnet_linux`):

```bash
./scripts/00-clone-sources.sh          # upstream kernel/dts/modules/Mu-Silicium
./scripts/01-apply-patches.sh          # our 3 patches + 2 new drivers
./scripts/02-build-modules.sh          # Image + DTB + modules
./scripts/03-make-nommgdsc-dtb.sh      # the ~11 s reset-fix DTB (required)
./scripts/07-build-qcacld.sh           # Wi-Fi driver
./scripts/build-grub-efi.sh            # grubaa64.efi
./scripts/get-busybox.sh               # static busybox
./scripts/04-stage-modules.sh          # module closure + load order
./scripts/05-pack-initramfs.sh initramfs/init-switch.sh
# phone in Mu-Silicium mass-storage mode for the next three:
./scripts/09-bootstrap-arch-rootfs.sh  # ⚠️ wipes userdata → Arch + services
./scripts/08-extract-firmware.sh /mnt/archroot/lib/firmware/adrastea
./scripts/06-deploy-esp.sh             # artifacts → GARNET-ESP
```

Then reboot, pick the Arch GRUB entry, and `ssh root@172.16.42.1` over USB.
See [`INSTALLATION.md`](INSTALLATION.md) for the details, the host-side USB
tethering setup, and all the optional pieces.
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

## GPU acceleration — turnip on KGSL

The Adreno 710 now runs real work. Since the 5.10 downstream kernel has no
drm/msm (and never will for this SoC), the route is the one Android
custom-driver folks use: **Mesa turnip (Vulkan) talking straight to
`/dev/kgsl-3d0`**, with **zink** translating OpenGL onto it. freedreno's
GL driver was never an option — it needs drm/msm.

Four pieces had to line up:

1. **A DTB that powers the GPU** (`scripts/10-make-gpu-dtb.sh`). The reset-fix
   DTB disabled all 7 multimedia GDSC nodes; the GPU pair
   (`gpu_cc_cx_gdsc`/`gpu_cc_gx_gdsc`) turned out to be safe to re-enable —
   unlike the display one that caused the 11 s reset, the GPU domain is off at
   boot and has no proxy-enable, so `gdsc-regulator`'s probe just registers
   them. The same DTB adds `ddr_device_type = <7>` to `/memory`: Android's
   bootloader injects it at runtime, GRUB doesn't, and without it kgsl dies at
   probe with a cryptic `Unable to read qcom,bus-freq` while resolving its
   per-DDR bus tables. (7 = LPDDR4X, straight from the XBL log's
   "LP4 DDR detected".)
2. **Firmware from the phone itself** (`scripts/11-extract-gpu-firmware.sh`):
   `a710_sqe.fw`, `gmu_gen70000.bin` and the TZ-signed `a710_zap` shader live
   in `/vendor/firmware` — and *vendor* is a logical partition inside Android's
   `super`, so the script parses super's LP metadata, stitches the extents
   with a dm-linear table, and mounts it read-only. Runs on the phone, no
   host needed.
3. **The kernel stack, loaded deliberately**: `msm_kgsl.ko` and its 13-module
   dependency closure (gpucc-parrot, sched-walt, dcvs, gunyah, dma heaps…)
   are staged in `/lib/modules/$KV/gpu/` but **blacklisted**, and
   `garnet-gpu.service` modprobes them in order at boot — udev coldplug never
   touches them (coldplugging this exact zoo is a proven SoC-killer).
4. **Mesa built on the phone** (~20 min, 8 cores): version 26.1.4 with
   `-Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl -Dgallium-drivers=zink`,
   plus the community A710/A720 device-table injection (A710 = chip id
   `0x07010000`, a730 magic regs) — upstream Mesa still has no A710 entry.

Result, all verified on the device: `vulkaninfo` reports **"Turnip Adreno
(TM) 710"**, a headless fence test proves the GPU executes command buffers
(GMU boot + SQE + zap all silent-clean in dmesg), and under the existing
fbdev Xorg, **`glxinfo` reports OpenGL 4.6 via zink, accelerated** — with
presentation through Mesa's software-copy path:

```sh
export VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json
export LD_LIBRARY_PATH=/usr/local/lib LIBGL_DRIVERS_PATH=/usr/local/lib/dri
export MESA_LOADER_DRIVER_OVERRIDE=zink LIBGL_KOPPER_DRI2=1 MESA_VK_WSI_DEBUG=sw
glxgears   # GPU-rendered gears on the phone screen
```

(`MESA_VK_WSI_DEBUG=sw` is the trick worth remembering: the fbdev X server
has no DRI3, so zink can't create a normal swapchain — that variable forces
Vulkan WSI's CPU-copy present path, which is exactly right for a
GPU-renders/CPU-scanout machine. Don't read too much into glxgears numbers;
tiny gears are cheaper to draw on a CPU than to copy out of a GPU — the win
shows up in real shader work at real resolutions.)

### Is it actually accelerated? Measuring it

"Hardware accelerated" means the Adreno 710 is drawing the pixels, not the CPU
(llvmpipe, the software rasteriser). You don't guess from how it looks — you
read three independent signals:

1. **The renderer string** (the app names its GL renderer):
   - GL apps: `glxinfo -B | grep -i "OpenGL renderer"` → `zink Vulkan …
     Turnip Adreno (TM) 710` (hardware) vs `llvmpipe` (software).
   - Firefox: `about:support` → **"WebGL 2 Driver Renderer"**.
2. **The GPU busy counters** (the un-fakeable one):
   ```bash
   watch -n0.5 'cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage \
                    /sys/class/kgsl/kgsl-3d0/clock_mhz'
   ```
   Climbing % and the clock jumping toward **940 MHz** = the GPU is working.
   Stuck at `0 % / 345 MHz` while something renders = it's all on the CPU.
3. **The CPU reaction** — `top`/`htop`: software rendering pins all 8 cores;
   hardware offloads them.

**To compare, run the same workload twice and flip the driver** — hardware
(`MESA_LOADER_DRIVER_OVERRIDE=zink`) vs software (`LIBGL_ALWAYS_SOFTWARE=1`):

```bash
# Hardware (turnip + zink):
gpu-env glmark2
# Software (llvmpipe), same scenes:
LIBGL_ALWAYS_SOFTWARE=1 DISPLAY=:0 glmark2
```

`glmark2` prints a single score. Measured on this phone (five representative
scenes, fbdev Xorg):

| Scene | Hardware (turnip/zink) | Software (llvmpipe) | GPU speedup |
|---|---|---|---|
| build | 269 FPS | 177 FPS | 1.5× |
| texture | 262 FPS | 226 FPS | 1.2× |
| shading | 258 FPS | 140 FPS | 1.8× |
| **refract** | **75 FPS** | **15 FPS** | **5.0×** |
| **glmark2 Score** | **225** | **156** | **1.4× overall** |

Read the *pattern*, not just the overall score. Simple fills (`texture`,
`bump`) barely differ — llvmpipe on 8 fast cores keeps up. Shader-heavy scenes
are where the GPU pulls away (`refract` **5×**), and a brutal fragment shader
like [volumeshader.com](https://volumeshader.com/run/) pegs the GPU at
100 %/940 MHz where llvmpipe would crawl. The overall gap is "only" 1.4×
because every frame is a fixed-cost CPU copy to the framebuffer (no scanout),
which blunts the lead on the cheap scenes.

### What's accelerated and what isn't (the honest map)

There is **no DRM/KMS display driver** on this SoC (drm/msm has no gen7 support
on 5.10) — only `simpledrm`/fbdev, a dumb framebuffer. That single fact decides
everything:

- ✅ **GL/Vulkan apps under Xorg** (`gpu-env <app>`): fully accelerated. Firefox
  WebGL, glmark2, emulators, `mpv --vo=gpu` scaling — the GPU does the work,
  one CPU copy reaches the screen.
- ✅ **Headless Vulkan / compute** (`vulkaninfo`, llama.cpp's Vulkan backend):
  works with no display path at all.
- ❌ **sway and native Wayland apps**: **software (llvmpipe).** wlroots' GL
  renderer needs EGL + **GBM**, and its Vulkan renderer needs
  `VK_EXT_physical_device_drm` — both require a DRM render node, which KGSL is
  not. So the compositor and Wayland-native apps composite on CPU. This is why
  Firefox launched from sway shows `llvmpipe` in `about:support`, while the
  same Firefox under Xorg+`gpu-env` is accelerated.
- ➖ **foot / terminals**: CPU by nature (text rasterisation) — the GPU
  wouldn't help regardless.

So today the accelerated-desktop path is **Xorg + a WM + `gpu-env`**, not sway.
Making sway itself GPU-composited is the big open item — it needs either a real
KMS driver for the SM7435 display, or a wlroots renderer patched to use turnip
without a DRM device and present via a CPU copy to `simpledrm`. Neither is a
quick fix; both are tracked in the roadmap.

---

## Touchscreen — the phone becomes self-contained

The panel's touch layer is a **Goodix GT9916S** (Berlin-D) on a geni SPI bus,
dual-sourced with a Focaltech FT3683G (the driver probes strap GPIOs and
picks itself). Bring-up was three unglamorous discoveries:

1. **The SPI engine only does GSI DMA.** This SE's FIFO interface is fused
   off (`GENI_IF_FIFO_DISABLE_RO`), so `gpi.ko` (the GENI DMA engine) must
   load **before** `spi-msm-geni.ko` — otherwise every transfer fails `-22`
   and the goodix probe dies at power-on. `garnet-touch.service` encodes the
   order; the modules are blacklisted against udev coldplug like the GPU set.
2. **The touch rail's enable pin lives on the PM6150L's GPIO block**, so
   `pinctrl-spmi-gpio.ko` is part of the stack too (without it the fixed
   regulator defers forever — and so does gpio-keys, so `/dev/input` is
   entirely empty; that one took a minute to notice).
3. **Firmware from vendor**, same story as GPU/Wi-Fi: `goodix_firmware_CSOT.bin`
   + config (script `11` grabs them). The driver flashes the IC at probe.

Result: `goodix_ts` on `/dev/input/event1`, 10-point multitouch at the full
1220×2712, ~240 Hz report rate. sway needs `WLR_BACKENDS=drm,libinput`
(the old recipe's `WLR_LIBINPUT_NO_DEVICES=1` era is over) — and then
**squeekboard** gives a proper on-screen keyboard, so the phone is usable
with zero external hardware. First thing typed on the phone itself:
`fastfetch`, which now reports "GPU: Qualcomm Turnip Adreno (TM) 710".

### Showing the keyboard — Volume-Up, not auto-show

squeekboard's automatic show-on-focus is unreliable here, and chasing it
turned up two real gotchas worth writing down:

- **The dbus-bus leak.** Launching sway with `runuser -u alarm` from a root
  shell leaks root's `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus`
  into the session, so squeekboard registers `sm.puri.OSK0` on *root's* bus
  and nothing on the alarm user bus can reach it. `garnet-sway` (in
  `rootfs/usr/local/bin/`) forces the right bus. This is also what made the
  auto-show signalling flaky.
- **The empty layout.** squeekboard reads the letters layout from
  `org.gnome.desktop.input-sources sources`; on a non-GNOME system that key
  is empty ("No system layout present") and squeekboard has nothing to show.
  The sway config sets it: `gsettings set … sources "[('xkb', 'us')]"`.

Even with both fixed, auto-show stays finicky because the Wayland **seat
advertises a keyboard capability** (`capabilities: 6` = keyboard+touch) — the
"keyboard" being the volume button and the touch panel's own `KEY_POWER`/
`KEY_WAKEUP` gesture keys — and squeekboard suppresses the OSK when it thinks
a hardware keyboard is present. Rather than fight that, the keyboard is bound
to a hardware button. The **power button is PMIC-managed and never reaches
Linux as an input device**, so the only usable button is **Volume-Up**
(`KEY_VOLUMEUP` → `XF86AudioRaiseVolume`, on `gpio-keys`):

```
# ~/.config/sway/config
exec gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
exec squeekboard
bindsym --no-repeat XF86AudioRaiseVolume exec /usr/local/bin/toggle-osk
```

`toggle-osk` just flips squeekboard's `Visible` property over dbus. Tap
Volume-Up to summon the keyboard, tap again to dismiss it.

Two kernel bugs surfaced along the way, both now fixed in
`kernel-new-drivers/simpledrm.c`: the 5.10 `drm_fb_memcpy_dstclip()` helper
trusts both the damage clip (can point past the framebuffer) and the
framebuffer pitch (sway's pixman renderer pads strides; the helper used it
for the *destination* too, drifting off the end of the scanout mapping —
kernel oops with the DRM modeset lock held, recoverable only by reboot).
The blit now clamps the clip and walks src/dst with separate pitches.

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
- **The pmk8350 RTC is read-only from Linux** — the SPMI arbiter's ownership
  table gives the RTC peripheral to TZ/XBL, so writes NACK no matter what.
  Do **not** add `allow-set-time` to the `rtc@6100` DT node: the kernel's
  clock-sync worker then retries the blocked write ~1/s forever, and about an
  hour of that storm most likely ended in a TZ **crashdump**. Instead the
  clock is kept by `garnet-rtc-restore/save`: an offset file
  (`system − rtc`, saved while NTP-synced) re-applied at every boot before
  the network — correct time even offline.
- **The A/B retry countdown is stopped by the GPT "successful" bit** (bit 54
  on `boot_b`'s entry) — `garnet-mark-boot-successful.service` sets it every
  boot. `fastboot set_active b` clears it, so the service matters after every
  flash session; before Linux is installed, re-arm by hand (see Step 1).

---

## Roadmap (not yet done)

- **OTG keyboard**: host mode works in software; blocked on hardware — a
  powered OTG hub is needed because the SM7435's OTG 5 V boost goes through
  pmic_glink → ADSP charger firmware that we don't run. *(Much less urgent
  now that the touchscreen + on-screen keyboard work.)*
- **GPU-accelerated compositor**: turnip/zink work now (see the GPU section
  above), but sway still renders with pixman/llvmpipe — wlroots' GLES renderer
  wants EGL+GBM (needs a real DRM driver) and its Vulkan renderer wants
  `VK_EXT_physical_device_drm`, which a KGSL-backed turnip can't offer. Next
  ideas: patch wlroots' Vulkan renderer to accept a DRM-less device, or keep
  the compositor on CPU and run the heavy apps on GL-via-zink / Vulkan
  directly (works today under Xorg).
- **Audio**: nothing plays yet. The SM7435 audio path is the Qualcomm
  ASoC/LPASS + q6 (ADSP) stack with the vendor `snd-soc-*` modules — likely the
  highest-value next milestone (turns this into a media-capable device), and
  fiddly for the usual Qualcomm reasons.
- **Camera**: hard. Qualcomm CAMSS/CamX is proprietary and heavy; low priority.
- **Wi-Fi stability**: the link occasionally drops (`No route to host` for a
  few seconds) — probably qcacld power-save; worth pinning down.
- **Durability**: `fsck.vfat` the ESP, trim the initramfs module set. (The
  slot-B re-arm is automated now — `garnet-mark-boot-successful.service`.)

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
