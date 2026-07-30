# Initramfs rescue SSH (dropbear) — recover a broken rootfs without reflashing

If the real rootfs is broken (classic case: the `/lib` symlink got replaced by a
real directory, so the dynamic loader vanishes and nothing can `exec`), the normal
sshd never comes up. The initramfs is self-contained, so an SSH server **inside the
initramfs** still works and can fix the rootfs.

This is installed and **proven working** (2026-07-31): dropbear in the initramfs,
reachable over the USB-gadget network, real rootfs mounted at `/root`.

## How it works
- The USB gadget net (NCM, `172.16.42.1`) is brought up by the initramfs
  `local-top/subpartitions` script — the network already exists inside the initramfs.
- `dropbear-initramfs` runs dropbear from `scripts/init-premount/dropbear`; it binds
  the wildcard address, so it is reachable once `subpartitions` brings up `usb0`.
- `scripts/init-bottom/dropbear` kills dropbear right before `switch_root`, so on a
  **normal** boot nothing lingers and the real sshd owns port 22.
- If the boot **hangs inside the initramfs** (or you force `break=bottom`), dropbear
  stays alive and you can log in.

## Config (on the phone)
- `/etc/dropbear/initramfs/authorized_keys` — host pubkey `realni@realni-hpelitebook840g6`.
- `/etc/dropbear/initramfs/dropbear.conf` — `DROPBEAR_OPTIONS="-p 2222 -s -j -k -I 180"`
  (port **2222**, key-only, no forwarding; does not collide with the real sshd on 22).
- `/etc/initramfs-tools/conf.d/dropbear-rescue` — `IP=off` so dropbear's
  `configure_networking` is an instant no-op (otherwise it tries DHCP on all
  interfaces and stalls ~3-4 min before dropbear starts). `subpartitions` owns `usb0`.

Rebuild after any change: `sudo update-initramfs -u -k <kernelver>` then copy
`/boot/initrd.img-<kernelver>` onto the nested ESP as `/initrd.img` (see below).

**The initrd bundles version-specific modules (`qcom-wdt`, gadget), so it must be
rebuilt for whichever kernel actually boots.** After a kernel swap: install the new
module tree + `depmod -a`, THEN `update-initramfs -c -k <newver>` and ship that initrd.

## Reach the rescue shell
```
ssh -p 2222 -i ~/.ssh/id_ed25519 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@172.16.42.1
```
You get a root shell in the initramfs. The real rootfs is at `/root` (on `/dev/loop0`).

## The fix that would have saved us (clobbered /lib symlink)
```
ls -ld /root/lib            # if it is a real directory instead of a symlink:
rm -rf /root/lib
ln -s usr/lib /root/lib     # merged-/usr: /lib -> usr/lib
sync
```
Also check `/root/bin`, `/root/sbin` (-> usr/bin, usr/sbin).

## Forcing the rescue for a drill (and getting back out)
The nested ESP holds the loader entry. Mount it from the **running** system OR from a
`chroot /root` inside the rescue shell (the initramfs busybox lacks a `--sector-size`
losetup that is safe here — use the real one under `/root`):
```
LP=$(sudo losetup --sector-size 4096 -fP --show /dev/sda15)
sudo mount ${LP}p1 /mnt/esp
# add for a drill:  append ' break=bottom' to the options line
# remove after:     delete ' break=bottom'
sudo sed -i "s/ break=bottom//" /mnt/esp/loader/entries/mobian.conf
sync; sudo umount /mnt/esp; sudo losetup -d $LP
```
With `break=bottom` the initramfs halts (dropbear alive, `usb0` up, `/root` mounted)
right before `switch_root`. Console shell is on tty0 (the display); use dropbear:2222.
To leave the drill: from the dropbear shell `chroot /root` and remove `break=bottom`
from the ESP as above, then reboot.

## Backups on the ESP
`/initrd.img.bak-june16` (original June initrd) and
`/loader/entries/mobian.conf.bak` (original entry) are kept on the ESP.
