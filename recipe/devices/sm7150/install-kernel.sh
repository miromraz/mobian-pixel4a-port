#!/bin/sh
# The overlay already dropped the kernel image, modules and dtb into the
# rootfs (no Debian .deb — the host is Arch and can't run bindeb-pkg).
# Here we just finish the in-chroot setup: depmod + build the initramfs.
set -e

KVER=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | grep sm7150 | head -1)
if [ -z "${KVER}" ]; then
    echo "ERROR: no sm7150 kernel found in /boot" >&2
    exit 1
fi

echo "Setting up kernel ${KVER}"
depmod "${KVER}"
update-initramfs -c -k "${KVER}"
ls -l "/boot/vmlinuz-${KVER}" "/boot/initrd.img-${KVER}"
