#!/bin/bash
# Phase 1: turn the (Phosh) userdata-nested.simg template into a Plasma BASE by
# swapping the p2 rootfs for the debos-built Plasma rootfs + the device firmware.
# The nested ESP (p1) is left untouched HERE; patch.sh (phase 2) replaces the kernel,
# dtb and initrd on it and installs the whole module tree, then applies the device
# tweaks + Plasma config on top.
set -e
cd /home/realni/pixel-a4-linux/mobian/work
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
# Firmware ONLY (WCN3990 wifi/BT, ath10k, qcom). The rest of this overlay -- its
# usr/lib/modules tree, boot/vmlinuz-* and usr/lib/linux-image-*/qcom dtbs -- is built for
# 7.1.0-rc3 and is now superseded: patch.sh installs the full module tree straight from KSRC
# and writes the kernel + dtb to the ESP. Copying the overlay wholesale would leave a stale
# rc3 module tree sitting next to the real one, so take just the firmware.
echo "=== inject device firmware (wcn3990/ath10k/qcom) ==="
mkdir -p rmnt/usr/lib/firmware
cp -a "$OVERLAY"/usr/lib/firmware/. rmnt/usr/lib/firmware/
# No depmod here: patch.sh owns /lib/modules and runs modules_install (which depmods).

echo "=== p2 (root) AFTER swap ==="; df -h rmnt | tail -1
echo "=== sanity: plasma + firmware present? ==="
ls -d rmnt/usr/share/plasma/shells/org.kde.plasma.mobileshell 2>/dev/null && echo "  plasma OK"
# Assert the ADSP firmware specifically: it is the overlay's real payload (remoteproc boots
# qcom/sm7150/google/sunfish/adsp.mbn, ~16 MB) and audio + every sensor depends on it. Do NOT
# assert the ath10k files here -- the overlay's copies are stubs and patch.sh installs the
# real ones later anyway.
[ -s rmnt/usr/lib/firmware/qcom/sm7150/google/sunfish/adsp.mbn ] && echo "  adsp firmware OK"
ls rmnt/usr/bin/sddm 2>/dev/null && echo "  sddm OK"
# Modules are deliberately NOT checked here -- patch.sh installs them in phase 2.

sync; umount rmnt
losetup -d "$LOOP"
echo "=== repack to userdata-nested.simg ==="
rm -f userdata-nested.simg
img2simg nested.img userdata-nested.simg
rm -f nested.img
chown realni:realni userdata-nested.simg
ls -la userdata-nested.simg
echo PREP_DONE
