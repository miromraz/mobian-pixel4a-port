#!/bin/sh
# Build an Android boot image (abootimg) for SM7150 devices. The stock
# Qualcomm bootloader (ABL) boots this directly from the `boot` partition;
# no U-Boot/lk2nd is involved. abootimg params match the stock sunfish
# boot_a.img header (kerneladdr 0x8000, ramdiskaddr 0x1000000,
# tagsaddr 0x100, pagesize 4096, header v0).
set -e

DEVICE="$1"

case "${DEVICE}" in
    "google-sunfish")
        DTB="qcom/sm7150-google-sunfish.dtb"
        ;;
    *)
        echo "ERROR: unsupported device ${DEVICE}"
        exit 1
        ;;
esac

KERNEL_VERSION=$(linux-version list | grep sm7150 | head -1)

# The rootfs is fastboot-flashed to the Android 'userdata' partition. Use the
# GPT PARTLABEL (a stable attribute of the device's partition) rather than a
# PARTUUID/PARTUUID from the build-time image, which would not match the
# device after flashing. Rewrite the root entry in fstab to match.
sed -i 's#^[^[:space:]#]\+\([[:space:]]\+/[[:space:]]\)#PARTLABEL=userdata\1#' /etc/fstab

echo "Creating boot image for ${DEVICE} (kernel ${KERNEL_VERSION})"

# Android bootloader boots a kernel with the DTB appended.
cat "/boot/vmlinuz-${KERNEL_VERSION}" \
    "/usr/lib/linux-image-${KERNEL_VERSION}/${DTB}" > /tmp/kernel-dtb

abootimg --create /bootimg -c kerneladdr=0x8000 -c ramdiskaddr=0x1000000 \
    -c secondaddr=0x0 -c tagsaddr=0x100 -c pagesize=4096 \
    -c cmdline="root=PARTLABEL=userdata rw rootwait console=ttyMSM0,115200n8" \
    -k /tmp/kernel-dtb -r "/boot/initrd.img-${KERNEL_VERSION}"
