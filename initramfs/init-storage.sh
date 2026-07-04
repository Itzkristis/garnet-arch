#!/bin/busybox sh
# garnet bring-up initramfs (storage stage).
# No devtmpfs in this kernel, and no real console tty yet -> route all output to
# /dev/kmsg, which printk renders on screen via earlycon=efifb. This stage also
# loads the UFS module chain so real storage (/dev/sd*) appears, then populates
# /dev from sysfs with `mdev -s`.
BB=/bin/busybox

$BB mount -t proc     none /proc  2>/dev/null
$BB mount -t sysfs    none /sys   2>/dev/null
$BB mount -t debugfs  none /sys/kernel/debug 2>/dev/null
$BB mknod /dev/kmsg    c 1 11 2>/dev/null
$BB mknod /dev/null    c 1 3  2>/dev/null
$BB mknod /dev/zero    c 1 5  2>/dev/null
$BB mknod /dev/console c 5 1  2>/dev/null
$BB mknod /dev/tty     c 5 0  2>/dev/null
$BB --install -s /bin 2>/dev/null
export PATH=/bin HOME=/ TERM=linux

# everything below lands in the kernel log -> earlycon=efifb -> phone screen
exec > /dev/kmsg 2>&1
# /dev/kmsg writes are rate-limited by default and silently DROP our heartbeat
# bursts (observed on-device: whole dmesg-tail sections missing). Disable it.
echo on > /proc/sys/kernel/printk_devkmsg 2>/dev/null

KVER=$($BB uname -r)
echo ""
echo "############################################################"
echo "###   GARNET INITRAMFS (storage stage) ALIVE (PID $$)    ###"
echo "############################################################"
echo "## uname   : $($BB uname -a)"
echo "## kver    : $KVER"
echo "## modules : $($BB find /lib/modules/$KVER -name '*.ko' 2>/dev/null | $BB wc -l) .ko shipped"

# --- load the UFS storage chain (STRICT dependency order) ----------------
# busybox modprobe does NOT resolve modules.dep deps, so we insmod each .ko
# by full path in a precomputed topological order (load-order.list). This
# guarantees every module's symbol deps are already loaded; the kernel's
# deferred-probe then binds the devices (clocks/regulators/power/phy/iommu/
# interconnect -> ufshcd) regardless of device order.
echo "## -------- loading modules (ordered insmod) --------"
MODDIR=/lib/modules/$KVER
if [ -f "$MODDIR/load-order.list" ]; then
  nfail=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    $BB insmod "$MODDIR/$rel" || { echo "##   ! FAIL $($BB basename "$rel" .ko)"; nfail=$((nfail+1)); }
  done < "$MODDIR/load-order.list"
  echo "## ordered insmod done; failures=$nfail"
else
  echo "## !! load-order.list missing; fallback modprobe-all"
  for ko in $($BB find "$MODDIR" -name '*.ko'); do $BB modprobe "$($BB basename "$ko" .ko)"; done
fi
echo "## modules loaded: $($BB lsmod 2>/dev/null | $BB grep -cvE '^Module'); ufs_qcom=$($BB lsmod 2>/dev/null | $BB grep -c ufs_qcom)"
# let deferred-probe settle (interconnect/regulator/phy -> ufshcd bind)
$BB sleep 5

# --- wait for the UFS block device, then populate /dev -------------------
echo "## -------- waiting for UFS block device (up to 40s) --------"
i=0
while [ $i -lt 40 ]; do
  if $BB ls /sys/block 2>/dev/null | $BB grep -qE '^sd'; then
    echo "## sd* appeared after ${i}s"; break
  fi
  $BB sleep 1; i=$((i+1))
done
[ $i -ge 40 ] && echo "## !! no sd* after ${i}s (see dmesg below)"

# create /dev nodes for whatever the kernel enumerated (block + misc)
$BB mdev -s 2>/dev/null

# The efifb screen fits only ~55 lines, so rather than one big dump (which
# scrolls the important part away), we REPRINT the key diagnostics every 20s in
# the loop below. That keeps the deferred-device reason + UFS/regulator dmesg as
# the newest (bottom-of-screen) output, so a photo always catches it.
LOG=""
if $BB ls /sys/block 2>/dev/null | $BB grep -qE '^sd'; then
  echo "## ===== SUCCESS: real block devices present ====="
  $BB cat /proc/partitions | $BB head -24

  # --- persist full logs to the ESP (vfat is built into the kernel) --------
  # Find the GARNET-ESP partition by GPT name from uevent, mount it, and keep
  # a full dmesg + status file there, refreshed every heartbeat. Ends the
  # photograph-the-screen era: pull the file over mass storage afterwards.
  ESPDEV=""
  for u in /sys/class/block/*/uevent; do
    if $BB grep -qi '^PARTNAME=GARNET-ESP' "$u" 2>/dev/null; then
      ESPDEV="/dev/$($BB basename "$($BB dirname "$u")")"; break
    fi
  done
  $BB mkdir -p /esp
  if [ -n "$ESPDEV" ] && $BB mount -t vfat -o sync "$ESPDEV" /esp 2>/dev/null; then
    $BB mkdir -p /esp/logs
    N=$($BB ls /esp/logs 2>/dev/null | $BB wc -l)
    LOG="/esp/logs/boot-${N}.txt"
    {
      echo "=== garnet storage boot #$N ==="
      $BB uname -a
      echo "--- /proc/partitions ---"; $BB cat /proc/partitions
      echo "--- blkid ---"
      for p in /dev/sd*; do [ -b "$p" ] && $BB blkid "$p" 2>/dev/null; done
      echo "--- dmesg ---"; $BB dmesg
    } > "$LOG" 2>&1
    sync
    echo "## ESP mounted ($ESPDEV) -> full log at ESP:/logs/$($BB basename $LOG)"
  else
    echo "## !! ESP mount failed (dev='$ESPDEV')"
  fi
fi

$BB setsid $BB sh -c 'exec $BB sh </dev/console >/dev/console 2>&1' 2>/dev/null
while true; do
  up=$($BB cut -d. -f1 /proc/uptime)
  nsd=$($BB ls /sys/block 2>/dev/null | $BB grep -cE '^sd')
  bnd=$($BB ls /sys/bus/platform/drivers/ufshcd-qcom 2>/dev/null | $BB grep -c 1d84)
  echo ""
  ncpufreq=$($BB ls /sys/devices/system/cpu/cpufreq 2>/dev/null | $BB grep -c policy)
  echo "==== [hb ${up}s] sd*=${nsd}  ufshcd-qcom-bound=${bnd}  cpufreq-policies=${ncpufreq}  ufs_qcom=$($BB lsmod 2>/dev/null | $BB grep -c ufs_qcom) ===="
  echo "-- DEFERRED devices (device : waiting-on) --"
  $BB cat /sys/kernel/debug/devices_deferred 2>/dev/null | while IFS= read -r l; do echo "@@  $l"; done
  for d in 1d87000.ufsphy_mem 1d84000.ufshc; do
    if [ -e /sys/bus/platform/devices/$d ]; then
      drv=$($BB readlink /sys/bus/platform/devices/$d/driver 2>/dev/null)
      wfs=$($BB cat /sys/bus/platform/devices/$d/waiting_for_supplier 2>/dev/null)
      echo "@@ bind: $d -> ${drv:-UNBOUND}  waiting_for_supplier=${wfs:-?}"
    else
      echo "@@ bind: $d -> NO SUCH DEVICE"
    fi
  done
  sdam=$($BB ls -d /sys/bus/platform/devices/*sdam* 2>/dev/null | $BB tr '\n' ' ')
  echo "@@ sdam devices: ${sdam:-none}"
  echo "-- devlinks touching ufshc (status tells which supplier blocks) --"
  for dl in /sys/class/devlink/*1d84000.ufshc*; do
    [ -e "$dl/status" ] || continue
    echo "@@ $($BB basename "$dl") : $($BB cat "$dl/status")"
  done
  echo "-- probe attempts (initcall_debug) --"
  $BB dmesg | $BB grep -E 'probe of (1d84000|1d87000)' | $BB grep -v '@@' | $BB tail -6 | while IFS= read -r l; do echo "@@  $l"; done
  echo "-- ufs/tcxo clks in clk debugfs --"
  echo "@@  $($BB ls /sys/kernel/debug/clk 2>/dev/null | $BB grep -iE 'ufs|tcxo' | $BB tr '\n' ' ')"
  echo "-- ufs-relevant regulators registered --"
  echo "@@  $($BB cat /sys/class/regulator/*/name 2>/dev/null | $BB grep -iE 'pm6450_l(5|13|16|19|24)$|ufs' | $BB tr '\n' ' ')"
  echo "-- ufshc/ufsphy/regulator dmesg (ours filtered out) --"
  $BB dmesg | $BB grep -iE '1d84000|1d87000|ufshc|ufsphy|ufs_qcom|vdda|vccq|rpmh-regulator|phy-qcom-ufs|qmp|scsi|sd[a-g]' | $BB grep -vE '@@|====|filtered|probe of' | $BB tail -10 | while IFS= read -r l; do echo "@@  $l"; done
  if [ "$nsd" -gt 0 ]; then $BB cat /proc/partitions | $BB head -12 | while IFS= read -r l; do echo "@@  $l"; done; fi
  if [ -n "$LOG" ]; then
    { echo "=== hb ${up}s ==="; $BB cat /sys/kernel/debug/devices_deferred 2>/dev/null; $BB dmesg; } > "${LOG%.txt}-live.txt" 2>/dev/null
    sync
  fi
  $BB sleep 20
done
