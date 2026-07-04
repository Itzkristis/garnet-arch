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


# --- SWITCH_ROOT STAGE: mount archroot and hand PID 1 to systemd ----------
findpart() {
  for u in /sys/class/block/*/uevent; do
    if $BB grep -qi "^PARTNAME=$1$" "$u" 2>/dev/null; then
      echo "/dev/$($BB basename "$($BB dirname "$u")")"; return 0
    fi
  done
  return 1
}
ROOTDEV=$(findpart userdata)
ESPDEV=$(findpart GARNET-ESP)
echo "## ROOT=$ROOTDEV ESP=$ESPDEV"
$BB mkdir -p /newroot /esp /tmp

# leave a breadcrumb on the ESP before we leap
if [ -n "$ESPDEV" ] && $BB mount -t vfat -o sync "$ESPDEV" /esp 2>/dev/null; then
  $BB mkdir -p /esp/logs
  { echo "=== switch_root attempt $($BB date 2>/dev/null) uptime=$($BB cut -d. -f1 /proc/uptime)s ==="
    echo "root=$ROOTDEV"; $BB dmesg | $BB tail -30; } > /esp/logs/switchroot-last.txt
  sync; $BB umount /esp
fi

REASON=""
# partition uevents can lag whole-disk enumeration; re-find for up to 15s
i=0
while [ -z "$ROOTDEV" ] && [ $i -lt 15 ]; do $BB sleep 1; ROOTDEV=$(findpart userdata); i=$((i+1)); done
[ -z "$ROOTDEV" ] && REASON="userdata partition never appeared"

if [ -z "$REASON" ]; then
  MOUT=$($BB mount -t ext4 "$ROOTDEV" /newroot 2>&1) || REASON="ext4 mount failed: $MOUT"
fi
if [ -z "$REASON" ] && [ ! -x /newroot/usr/lib/systemd/systemd ]; then
  REASON="systemd binary missing in /newroot (ls: $($BB ls /newroot 2>/dev/null | $BB tr '\n' ' '))"
fi
if [ -z "$REASON" ]; then
  $BB mount -t devtmpfs devtmpfs /newroot/dev 2>/dev/null || echo "## devtmpfs mount failed"
  echo "## switch_root -> systemd in 3s"
  $BB sleep 3
  $BB umount /sys/kernel/debug 2>/dev/null
  $BB umount /proc 2>/dev/null; $BB umount /sys 2>/dev/null
  # exec is MANDATORY: switch_root must run as PID 1
  exec $BB switch_root /newroot /usr/lib/systemd/systemd
  REASON="exec switch_root returned — should be impossible"
  $BB mount -t proc none /proc 2>/dev/null
fi

# failure: persist the reason to ESP and repeat it on screen forever
if $BB mount -t vfat -o sync "$ESPDEV" /esp 2>/dev/null; then
  echo "$($BB date 2>/dev/null) FAIL: $REASON" >> /esp/logs/switchroot-fail.txt; sync; $BB umount /esp
fi
while true; do
  echo "==== [switch-fail hb $($BB cut -d. -f1 /proc/uptime)s] root='$ROOTDEV' REASON: $REASON ===="
  $BB sleep 20
done
