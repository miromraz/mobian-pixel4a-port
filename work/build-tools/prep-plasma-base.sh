#!/bin/bash
# Phase 1: turn the (Phosh) userdata-nested.simg template into a Plasma BASE by
# swapping the p2 rootfs for the debos-built Plasma rootfs + the device overlay
# (kernel modules / firmware / dtb). The nested ESP (p1) is left untouched: same
# kernel version, so its existing kernel+initrd still boot. patch.sh (phase 2)
# then applies all the device tweaks + Plasma config on top.
set -e
cd /home/realni/pixel-a4-linux/mobian/work
KVER=7.1.0-rc3-sm7150+
OVERLAY=/home/realni/pixel-a4-linux/mobian/mobian-recipes/devices/sm7150/overlay-google-sunfish
ROOTFS_TAR=/home/realni/pixel-a4-linux/mobian/mobian-recipes/rootfs-arm64-plasma-nonfree.tar.gz

echo "=== expand template ==="
simg2img userdata-nested.simg nested.img
LOOP=$(losetup --sector-size 4096 -P --show -f nested.img)
echo "loop=$LOOP"
echo "=== nested partition layout ==="
sgdisk -p "$LOOP" 2>/dev/null || fdisk -l "$LOOP" 2>/dev/null || true

mkdir -p rmnt
mount "${LOOP}p2" rmnt
echo "=== p2 (root) BEFORE swap ==="; df -h rmnt | tail -1

echo "=== wipe old rootfs + untar Plasma rootfs ==="
find rmnt -mindepth 1 -maxdepth 1 -exec rm -rf {} +
tar -xpzf "$ROOTFS_TAR" -C rmnt
echo "=== inject device overlay (kernel/modules/dtb/firmware) ==="
cp -a "$OVERLAY"/. rmnt/
echo "=== depmod (host, -b) ==="
depmod -b rmnt "$KVER"

echo "=== p2 (root) AFTER swap ==="; df -h rmnt | tail -1
echo "=== sanity: plasma + modules present? ==="
ls -d rmnt/usr/share/plasma/shells/org.kde.plasma.mobileshell 2>/dev/null && echo "  plasma OK"
ls -d rmnt/usr/lib/modules/$KVER 2>/dev/null && echo "  modules OK"
ls rmnt/usr/bin/sddm 2>/dev/null && echo "  sddm OK"

sync; umount rmnt
losetup -d "$LOOP"
echo "=== repack to userdata-nested.simg ==="
rm -f userdata-nested.simg
img2simg nested.img userdata-nested.simg
rm -f nested.img
chown realni:realni userdata-nested.simg
ls -la userdata-nested.simg
echo PREP_DONE
