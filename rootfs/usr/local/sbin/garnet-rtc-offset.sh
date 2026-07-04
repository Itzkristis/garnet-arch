#!/usr/bin/env bash
# The pmk8350 RTC is READ-ONLY from Linux: the SPMI arbiter's ownership table
# gives the RTC peripheral to TZ/XBL, so every write NACKs ("Write to RTC
# control register failed") — no DT property changes that. Do NOT re-add
# `allow-set-time` to the rtc@6100 node: it makes the kernel's RTC-sync loop
# hammer the blocked register ~1/s in dmesg, forever.
#
# The counter does run continuously on battery, so wall time survives
# power-off as rtc + offset:
#   save:    offset = system_time - rtc   (only while NTP-synchronized)
#   restore: system_time = rtc + offset   (early boot, before network)
set -euo pipefail
RTC=/sys/class/rtc/rtc0/since_epoch
OFF=/var/lib/garnet/rtc-offset

case "${1:-}" in
restore)
    [ -r "$RTC" ] && [ -r "$OFF" ] || { echo "no rtc or no saved offset yet"; exit 0; }
    target=$(( $(cat "$RTC") + $(cat "$OFF") ))
    now=$(date +%s)
    delta=$(( target - now )); [ "$delta" -lt 0 ] && delta=$(( -delta ))
    if [ "$delta" -gt 5 ]; then
        date -u -s "@$target" >/dev/null
        echo "clock set from rtc+offset: $(date -u)"
    else
        echo "clock already within ${delta}s of rtc+offset"
    fi
    ;;
save)
    [ -r "$RTC" ] || { echo "no rtc0 (rtc-pm8xxx not loaded?)"; exit 0; }
    [ "$(timedatectl show -p NTPSynchronized --value)" = yes ] \
        || { echo "not NTP-synchronized — not saving a bad offset"; exit 0; }
    mkdir -p "$(dirname "$OFF")"
    echo $(( $(date +%s) - $(cat "$RTC") )) > "$OFF"
    echo "saved offset: $(cat "$OFF") s"
    ;;
*)
    echo "usage: $0 save|restore" >&2; exit 1
    ;;
esac
