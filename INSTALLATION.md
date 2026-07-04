# Installing Linux on your garnet — step by step

This is the hands-on guide. It has two halves:

1. **Core install** — everything required to get a booting Arch Linux you can
   reach from your PC over the USB cable (USB tethering + SSH). Stop here and
   you already have a working headless Linux phone.
2. **Optional / recommended** — Wi-Fi, the graphical desktop and its
   autostart, the on-screen keyboard, GPU acceleration, the touchscreen, and
   keyboard shortcuts. Add these in any order once the core works.

> **Read [`PREREQUISITES.md`](PREREQUISITES.md) first.** It covers the unlocked
> bootloader, the GARNET-ESP partition, the host packages, and the fact that
> this **wipes your Android userdata**.

> **No proprietary firmware is shipped.** Wi-Fi and GPU firmware are extracted
> from *your own* phone (Steps 5 and the GPU section). They live in firmware
> partitions that survive a LineageOS re-flash, so they're always there.

Budget an afternoon the first time. Everything lives under one root directory
(`$ROOT`), and the numbered `scripts/` run from `$ROOT/github`.

---

# Part 1 — Core install (USB tethering + SSH)

## Step 0 — clone this repo and set up the host

```bash
export ROOT=$HOME/garnet_linux
mkdir -p "$ROOT" && cd "$ROOT"
git clone https://github.com/Itzkristis/garnet-arch.git github
cd github
```

Install the host packages listed in `PREREQUISITES.md` (`clang`/`llvm`,
`device-tree-compiler`, `cpio`, `gzip`, `curl`, `bsdtar`, `git`, `make`,
`grub-efi-arm64-bin` + `grub-common`, `qemu-user-static` + binfmt).

## Step 1 — prepare the phone (one-time)

1. **Unlock the bootloader** through Xiaomi's official process (wipes the
   phone, has a waiting period — no way around it).
2. **Build and flash Mu-Silicium UEFI** to **slot B**, and make B active:

   ```bash
   fastboot flash boot_b <mu-silicium-boot-image>.img
   fastboot set_active b
   ```

   Android stays on slot A — `fastboot set_active a` goes back anytime.
3. **The retry-counter gotcha:** each power-on of slot B decrements an A/B
   retry counter (starts at 7); the bootloader only stops counting once the
   slot's GPT "successful" bit is set, which nothing does until Linux is
   installed. Until Step 5, re-run `fastboot set_active b` after every flash
   session. After that, `garnet-mark-boot-successful.service` sets the bit on
   every boot and the countdown stops for good.

## Step 2 — clone the upstream sources

This repo ships only *our* changes; the kernel, device trees, vendor modules,
and Mu-Silicium come from their own upstreams. One script pulls them all:

```bash
./scripts/00-clone-sources.sh
```

Equivalent by hand, if you prefer:

```bash
cd "$ROOT"
git clone --depth=1 -b lineage-23.2 https://github.com/LineageOS/android_kernel_xiaomi_sm7435             kernel_sm7435
git clone --depth=1 -b lineage-23.2 https://github.com/LineageOS/android_kernel_xiaomi_sm7435-devicetrees devicetrees
git clone --depth=1 -b lineage-23.2 https://github.com/LineageOS/android_kernel_xiaomi_sm7435-modules     modules
git clone --recursive https://github.com/Project-Silicium/Mu-Silicium
```

## Step 3 — apply the patches

```bash
./scripts/01-apply-patches.sh
```

`git apply`s the combined patch into `$ROOT/kernel_sm7435` and copies the two
new driver sources into place. Idempotent. (What each patch does is in the
README under "The three kernel patches".)

## Step 4 — build everything

```bash
cd "$ROOT/github"
./scripts/02-build-modules.sh                              # kernel Image + DTB + all modules
./scripts/03-make-nommgdsc-dtb.sh                          # the reset-fix DTB (required)
./scripts/07-build-qcacld.sh                               # Wi-Fi driver wlan.ko
./scripts/build-grub-efi.sh                                # grubaa64.efi
./scripts/get-busybox.sh                                   # static busybox for the initramfs
./scripts/04-stage-modules.sh                              # 43-module closure + load order
./scripts/05-pack-initramfs.sh initramfs/init-switch.sh    # the daily-driver initramfs
```

Outputs land in `$ROOT/dist/`. sha256 sums for cross-checking are in
`dist-manifests/dist-artifacts.txt` (you never need the author's binaries — the
scripts regenerate everything).

## Step 5 — put it on the phone

Boot the phone into Mu-Silicium and select **USB mass-storage mode** (the whole
UFS appears on your PC as a block device — no fastboot needed for daily work):

```bash
./scripts/09-bootstrap-arch-rootfs.sh                                  # ⚠️ DESTROYS userdata → Arch + our services
./scripts/08-extract-firmware.sh /mnt/archroot/lib/firmware/adrastea   # your phone's WPSS Wi-Fi fw
./scripts/06-deploy-esp.sh                                             # Image/DTB/grub.cfg/initramfs → GARNET-ESP
```

`09` also sets an **empty root password** and enables the core services (USB
gadget, boot-successful, RTC, etc.), so the first SSH login needs no password.

## Step 6 — boot it

Reboot the phone. Mu-Silicium chainloads GRUB from the ESP; pick a menu entry
with the **volume keys** (power = enter). The daily-driver entry is the Arch
systemd one. If something goes wrong, the init scripts write logs to
`GARNET-ESP:/logs/`, readable over mass-storage mode.

## Step 7 — connect over USB (tethering + SSH)

Once Arch boots, `garnet-usb-gadget.service` brings up a USB network gadget: the
phone is **172.16.42.1**, your PC gets a new network interface on the same
`172.16.42.0/24` link.

On the PC:

```bash
# Find the new interface (name varies, e.g. enp0s20f0u7 / usb0):
ip -br link | grep -iE 'usb|enp.*u'

# If it didn't auto-configure, give it the peer address:
sudo ip addr add 172.16.42.2/24 dev <iface>
sudo ip link set <iface> up

# You're in (empty root password — just press Enter):
ssh root@172.16.42.1
```

**Sharing your PC's internet to the phone** (so `pacman` works before Wi-Fi) —
this is the "USB tethering" part. On the PC, NAT the phone's link out through
your real uplink (`<wan>` = your internet interface, e.g. `wlan0`/`eth0`):

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -o <wan> -j MASQUERADE
sudo iptables -A FORWARD -i <iface> -o <wan> -j ACCEPT
sudo iptables -A FORWARD -i <wan> -o <iface> -m state --state RELATED,ESTABLISHED -j ACCEPT
```

Then on the phone point the default route at the PC and add DNS:

```bash
ip route add default via 172.16.42.2
echo 'nameserver 1.1.1.1' > /etc/resolv.conf
ping -c1 archlinux.org        # confirm internet
pacman -Syu                   # now you can install packages
```

That's the whole core install. **You now have a Linux phone reachable over USB
with working internet.** Everything below is optional polish.

---

# Part 2 — Optional / recommended

Do these in any order. Each assumes you can SSH into the phone (Step 7).

## Wi-Fi (recommended — untethers the phone)

The Wi-Fi driver (`wlan.ko`) and firmware are already installed by Steps 4–5.
Bring up `wlan0` with `wpa_supplicant` + `systemd-networkd` (or edit
`/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` with your SSID/PSK — the unit
`wpa_supplicant@wlan0` is enabled by the `09` bootstrap):

```bash
wpa_passphrase "YourSSID" "YourPassword" >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
systemctl restart wpa_supplicant@wlan0
# wlan0 appears ~130 s into boot on this slow-boot kernel; be patient.
ip -br addr show wlan0
```

Once Wi-Fi is up you can SSH over it instead of USB (find the phone's IP with
`ip -br addr show wlan0`). See the README's Wi-Fi section for the one-line
`gEnableFastPath` fix — already applied in this repo — that made TX work at all.

## GPU acceleration (turnip Vulkan + zink OpenGL)

Gives the Adreno 710 real acceleration. Three parts (full detail in the README
"GPU acceleration" section):

```bash
# On the host — a DTB with the GPU power domains enabled:
./scripts/10-make-gpu-dtb.sh
# copy dist/garnet-sm7435-gpu.dtb to the ESP and boot GRUB entry 12 (the GPU DTB)

# On the phone — extract the Adreno firmware from your own /vendor:
./scripts/11-extract-gpu-firmware.sh

# On the phone — build Mesa with turnip(KGSL) + zink (see the README for flags).
```

`garnet-gpu.service` (installed by `09`) loads the kernel side every boot and
no-ops on non-GPU DTBs. After this, run any X11 GL app through the `gpu-env`
wrapper; `vulkaninfo` reports "Turnip Adreno (TM) 710".

## Touchscreen

The Goodix GT9916S multitouch panel is brought up by `garnet-touch.service`
(installed by `09`) — no manual steps; it loads the geni-SPI + goodix stack in
order and the panel appears as `/dev/input/event1`. Firmware is grabbed by
`scripts/11-extract-gpu-firmware.sh` (it pulls the touch blobs too).

## The graphical desktop (sway) — and autostart

Everything for the desktop is installed; you just enable it. To start it once
by hand:

```bash
runuser -u alarm -- /usr/local/bin/garnet-sway
```

`garnet-sway` is a small launcher that sets the right environment (the alarm
user's dbus bus, the `drm,libinput` backend). **To start the desktop
automatically on every boot**, enable the service:

```bash
systemctl enable --now garnet-desktop.service
```

That brings up sway, the wallpaper/bar, the on-screen keyboard, and your
shortcuts on every boot, as the `alarm` user. (Don't disable
`loginctl enable-linger alarm` — logind would wipe `/run/user/1000` and the
wayland socket with it.)

Run an app into a running session from an SSH window:

```bash
su - alarm -c "env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 foot"
```

## On-screen keyboard (Volume-Up toggle)

The desktop autostarts **squeekboard**. Its automatic show-on-focus is
unreliable on this device (the seat looks like it has a hardware keyboard —
the volume button and the touch panel's gesture keys), so the keyboard is
toggled by a hardware button instead. The power button is PMIC-managed and
never reaches Linux, so the toggle is **Volume-Up**:

```
# ~/.config/sway/config  (already set up if you used garnet-sway's config)
exec gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
exec squeekboard
bindsym --no-repeat XF86AudioRaiseVolume exec /usr/local/bin/toggle-osk
```

Tap **Volume-Up** to summon the keyboard, tap again to dismiss it. `toggle-osk`
just flips squeekboard's visibility over dbus. The `gsettings` line is required
— without a layout set there, squeekboard has nothing to show ("No system
layout present").

## Keyboard shortcuts

The sway config ships two app shortcuts (Alt = `Mod1`; sway's own `$mod` is
Super):

```
bindsym Mod1+t exec foot       # Alt+t  → terminal
bindsym Mod1+w exec firefox    # Alt+w  → Firefox
bindsym Mod1+q kill            # Alt+q  → close the focused window
```

These need a real keyboard (an OTG keyboard, or a Bluetooth one later) — the
on-screen keyboard can't easily send Alt-combos.

### Adding your own shortcut (mini-tutorial)

A sway binding is one line in `~/.config/sway/config`:

```
bindsym <keys> exec <command>
```

- **`<keys>`** — modifiers joined with `+`, then the key. Modifiers:
  `Mod1` = Alt, `Mod4`/`$mod` = Super, `Shift`, `Control`. Letter keys are just
  their letter (`t`, `w`); find any other key's name by running `wev` in the
  session and pressing it, or `xkbcli interactive-wayland`.
- **`exec <command>`** — any shell command. Wrap multi-word commands normally;
  use `exec` once.

Examples:

```
bindsym Mod1+f exec firefox                                   # Alt+f  → Firefox
bindsym Mod1+Shift+s exec grim ~/shot.png                     # Alt+Shift+s → screenshot
bindsym $mod+q kill                                           # Super+q → close window
bindsym --no-repeat XF86AudioRaiseVolume exec /usr/local/bin/toggle-osk
```

Add `--no-repeat` for actions that should fire once per press (toggles), not
repeatedly while held. After editing the config, reload without logging out:

```bash
su - alarm -c "env XDG_RUNTIME_DIR=/run/user/1000 SWAYSOCK=$(ls /run/user/1000/sway-ipc*.sock | head -1) swaymsg reload"
```

New bindings take effect immediately. If a binding does nothing, check the key
name with `wev` and confirm the modifier (Alt is `Mod1`, not `Alt`).
