#!/bin/sh
#
# RECONSTRUCTED from status.md / handoff.md (the live copy is on the phone) —
# verify against those notes. Assembles the configfs USB gadget once the
# phy/extcon/dwc3-msm chain is loaded (by garnet-usb-gadget.service) and a UDC
# has appeared. Single NCM ethernet function -> the PC gets a DHCP lease from
# the phone -> ssh root@172.16.42.1.
#
# Load order that must already be done: phy-msm-snps-hs -> phy-msm-ssusb-qmp ->
# extcon-fake-vbus (reports EXTCON_USB=1) -> dwc3-msm (starts peripheral role).
# NEVER start the role via dwc3-msm's sysfs `mode` (NULL-wq oops -> crashdump).
#
set -e
G=/sys/kernel/config/usb_gadget/g1

# Wait up to 20 s for a UDC to appear (dwc3-msm started the role from the cable event).
i=0; until [ -n "$(ls /sys/class/udc 2>/dev/null)" ] || [ $i -ge 20 ]; do sleep 1; i=$((i+1)); done
UDC="$(ls /sys/class/udc 2>/dev/null | head -1)"
[ -n "$UDC" ] || { echo "no UDC after 20s"; exit 1; }

mkdir -p "$G"; cd "$G"
echo 0x1d6b > idVendor; echo 0x0104 > idProduct         # Linux Foundation / Multifunction Composite
mkdir -p strings/0x409
echo "garnet0001"        > strings/0x409/serialnumber
echo "garnet"            > strings/0x409/manufacturer
echo "garnet Linux NCM"  > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "NCM" > configs/c.1/strings/0x409/configuration
echo 250   > configs/c.1/MaxPower

mkdir -p functions/ncm.usb0
ln -sf functions/ncm.usb0 configs/c.1/ 2>/dev/null || true

echo "$UDC" > UDC                                        # bind -> enumerate

# Bring up the interface; networkd (20-usb0.network) assigns 172.16.42.1/24 + DHCP server.
ip link set usb0 up 2>/dev/null || true
echo "gadget bound to $UDC"
