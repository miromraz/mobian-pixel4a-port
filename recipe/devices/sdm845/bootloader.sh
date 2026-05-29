#!/bin/sh

DEVICE="$1"
OFFSET=0

ROOTPART=$(grep -vE '^#' /etc/fstab | grep -E '[[:space:]]/[[:space:]]' | awk '{ print $1; }')
KERNEL_VERSION=$(linux-version list)

case "${DEVICE}" in
    "oneplus6")
        DTB_VENDOR="oneplus"
        DTB_VARIANTS="enchilada fajita"
        ;;
    "pocof1")
        DTB_VENDOR="xiaomi"
        DTB_VARIANTS="beryllium-tianma beryllium-ebbg"
        ;;
    *)
        echo "ERROR: unsupported device ${DEVICE}"
        exit 1
        ;;
esac

# Create a bootimg for each variant
for variant in ${DTB_VARIANTS}; do
    echo "Creating boot image for variant ${variant}"

    # Append DTB to kernel
    cat /boot/vmlinuz-${KERNEL_VERSION} /usr/lib/linux-image-${KERNEL_VERSION}/qcom/sdm845-${DTB_VENDOR}-${variant}.dtb > /tmp/kernel-dtb

    # Create the bootimg as it's the only format recognized by the Android bootloader
    abootimg --create /bootimg-${variant} -c kerneladdr=0x8000 \
        -c ramdiskaddr=0x1000000 -c secondaddr=0x0 -c tagsaddr=0x100 -c pagesize=4096 \
        -c cmdline="mobile.root=${ROOTPART} mobian.vendor=${DTB_VENDOR} mobian.variant=${variant} init=/sbin/init mobile.rw quiet splash" \
        -k /tmp/kernel-dtb -r /boot/initrd.img-${KERNEL_VERSION}
done
