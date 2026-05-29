#!/bin/sh

DEVICE=$1
IMAGE=$2

[ "$IMAGE" ] || exit 1

case "${DEVICE}" in
    "google-sunfish")
        ;;
    *)
        echo "ERROR: unsupported device ${DEVICE}"
        exit 1
        ;;
esac

# SM7150 devices don't have a dedicated /boot partition; the kernel lives
# in the Android boot image. Drop any /boot fstab entry from the rootfs.
sed -i '/\/boot/d' ${ROOTDIR}/etc/fstab

echo "Extracting boot image"
mv ${ROOTDIR}/bootimg ${ARTIFACTDIR}/${IMAGE}.boot.img
