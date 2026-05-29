#!/bin/sh
set -e
W=/home/realni/pixel-a4-linux/mobian/work
KVER=7.1.0-rc3-sm7150+
KDIR=/home/realni/pixel-a4-linux/kernel/linux-fork/arch/arm64/boot
DTB=/home/realni/pixel-a4-linux/mobian/mobian-recipes/devices/sm7150/overlay-google-sunfish/usr/lib/linux-image-$KVER/qcom/sm7150-google-sunfish.dtb
cd "$W"

echo "=== extract root ext4 from nested image p2 ==="
simg2img userdata-nested.simg nested.img
LOOP=$(losetup --sector-size 4096 -P --show -f nested.img)
dd if="${LOOP}p2" of=rootfs.ext4 bs=8M conv=fsync status=none
losetup -d "$LOOP"; rm -f nested.img
# grow the fs a little so /boot kernel+initrd fit, then mount
e2fsck -fy rootfs.ext4 >/dev/null 2>&1 || true
resize2fs rootfs.ext4 5G >/dev/null 2>&1 || true
echo "rootfs.ext4: $(ls -la rootfs.ext4 | awk '{print $5}')"

echo "=== populate /boot + extlinux ==="
mkdir -p rmnt; mount -o loop rootfs.ext4 rmnt
# drop the old subpartition machinery, install minimal serial debug
rm -f rmnt/etc/initramfs-tools/hooks/subpartitions rmnt/etc/initramfs-tools/scripts/local-top/subpartitions
install -m0755 debugsh rmnt/etc/initramfs-tools/scripts/local-top/debugsh
mkdir -p rmnt/boot/extlinux
cp "$KDIR/Image" "rmnt/boot/vmlinuz-$KVER"            # uncompressed Image for U-Boot booti
cp "$DTB" "rmnt/boot/sm7150-google-sunfish.dtb"
# fstab: root on the real userdata partition
sed -i "s#^[^[:space:]#]\+\([[:space:]]\+/[[:space:]]\)#PARTLABEL=userdata\1#" rmnt/etc/fstab
sed -i "\#[[:space:]]/boot[[:space:]]#d" rmnt/etc/fstab
echo "fstab:"; cat rmnt/etc/fstab

echo "=== regenerate clean initrd ==="
for d in proc sys dev dev/pts; do mount --bind "/$d" "rmnt/$d"; done
chroot rmnt /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin update-initramfs -c -k "$KVER" >/tmp/regen.log 2>&1
tail -3 /tmp/regen.log
for d in dev/pts dev sys proc; do umount "rmnt/$d"; done

echo "=== write extlinux.conf ==="
cat > rmnt/boot/extlinux/extlinux.conf <<E
default mobian
timeout 30
menu title Mobian sunfish
label mobian
    menu label Mobian (sunfish)
    kernel /boot/vmlinuz-$KVER
    fdt /boot/sm7150-google-sunfish.dtb
    initrd /boot/initrd.img-$KVER
    append root=PARTLABEL=userdata rw rootwait console=tty0 console=ttyMSM0,115200n8
E
cat rmnt/boot/extlinux/extlinux.conf
echo "=== /boot contents ==="; ls -la rmnt/boot/ rmnt/boot/extlinux/
sync; umount rmnt

echo "=== make sparse for fastboot ==="
img2simg rootfs.ext4 userdata-extlinux.simg
rm -f rootfs.ext4
chown realni:realni userdata-extlinux.simg
ls -la userdata-extlinux.simg
echo EXTLINUX_BUILD_DONE
