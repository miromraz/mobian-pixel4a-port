#!/bin/sh

DEVICE="$1"

# Refresh /boot/grub/grub.cfg
update-grub

# Install grub to the MBR/ESP
if [ "$DEVICE" != "pc" ]; then
    grub-install --target=x86_64-efi --removable /dev/vda
else
    grub-install /dev/vda
fi

# Fix devicenames in grub.cfg
sed -i 's/vda/sda/g' /boot/grub/grub.cfg
