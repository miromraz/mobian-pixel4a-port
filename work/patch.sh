#!/bin/sh
set -e
cd /home/realni/pixel-a4-linux/mobian/work
KVER=7.1.0-rc3-sm7150+

simg2img userdata-nested.simg nested.img
LOOP=$(losetup --sector-size 4096 -P --show -f nested.img)
echo "loop=$LOOP"
mkdir -p rmnt emnt
mount "${LOOP}p2" rmnt
RUUID=$(blkid -s UUID -o value "${LOOP}p2"); echo "root UUID=$RUUID"
install -m0755 hooks/subpartitions rmnt/etc/initramfs-tools/hooks/subpartitions
install -m0755 scripts/subpartitions rmnt/etc/initramfs-tools/scripts/local-top/subpartitions
# watchdog-kick for the booted Mobian (so it doesn't reboot ~50s after boot)
install -Dm755 watchdog-kick rmnt/usr/sbin/watchdog-kick
mkdir -p rmnt/etc/modules-load.d; echo qcom_wdt > rmnt/etc/modules-load.d/qcom_wdt.conf
# IPA (IP Accelerator) driver triggers a silent SoC reset ~13s into Mobian (confirmed via
# live console: last msg every cycle is "ipa 1e40000.ipa: IPA driver setup completed").
# It's only network offload -> blacklist it so the device boots to Phosh.
mkdir -p rmnt/etc/modprobe.d; printf 'blacklist ipa\ninstall ipa /bin/true\n' > rmnt/etc/modprobe.d/blacklist-ipa.conf
# A/B slot persistence: mark the current boot slot successful at every boot, else the
# bootloader falls back to the other slot after ~7 reboots and soft-bricks the device.
# qbootctl here is the pmOS aarch64 build (musl). musl's loader path (/lib/ld-musl-*)
# does NOT collide with glibc's (/lib/ld-linux-*), so we bundle the musl runtime
# side-by-side and run the unmodified binary on Debian.
install -Dm755 qbootctl rmnt/usr/sbin/qbootctl
install -Dm755 ld-musl-aarch64.so.1 rmnt/lib/ld-musl-aarch64.so.1
ln -sf ld-musl-aarch64.so.1 rmnt/lib/libc.musl-aarch64.so.1
install -Dm644 /dev/stdin rmnt/usr/lib/systemd/system/qbootctl-mark.service <<'UNIT'
[Unit]
Description=Mark current Android A/B boot slot successful
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/qbootctl -m
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
mkdir -p rmnt/etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/qbootctl-mark.service rmnt/etc/systemd/system/multi-user.target.wants/qbootctl-mark.service
# Mobian watchdog: let systemd PID1 own /dev/watchdog from the very start (no gap after switch_root).
mkdir -p rmnt/etc/systemd/system.conf.d
printf "[Manager]\nRuntimeWatchdogSec=0\nRebootWatchdogSec=off\n" > rmnt/etc/systemd/system.conf.d/watchdog.conf
# (drop the late OpenRC-style watchdog-kick service so it doesn't fight systemd for the device)
rm -f rmnt/etc/systemd/system/sysinit.target.wants/watchdog-kick.service rmnt/usr/lib/systemd/system/watchdog-kick.service
# fstab root -> UUID (offset loop has no PARTLABEL); match the / entry's device field
sed -i "s#^[^[:space:]#]\+\([[:space:]]\+/[[:space:]]\)#UUID=$RUUID\1#" rmnt/etc/fstab
echo "fstab: $(grep -E '[[:space:]]/[[:space:]]' rmnt/etc/fstab)"
for d in proc sys dev dev/pts; do mount --bind "/$d" "rmnt/$d"; done

echo "chroot-arch=$(chroot rmnt /bin/sh -c 'uname -m')"
chroot rmnt /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/sbin/update-initramfs -u -k "$KVER"

for d in dev/pts dev sys proc; do umount "rmnt/$d"; done

echo "verifying losetup.real is util-linux (not busybox)..."
mkdir -p /tmp/initck && rm -rf /tmp/initck/*
( cd /tmp/initck && zstd -dc "/home/realni/pixel-a4-linux/mobian/work/rmnt/boot/initrd.img-$KVER" | cpio -idm 'sbin/losetup.real' 'usr/sbin/losetup.real' 2>/dev/null )
LR=$(find /tmp/initck -name losetup.real | head -1)
SZ=$(wc -c < "$LR" 2>/dev/null || echo 0)
echo "losetup.real path=$LR size=$SZ"
if [ "$SZ" -gt 400000 ] || [ "$SZ" -lt 50000 ]; then
  echo "ABORT: losetup.real looks like busybox/garbage (size $SZ), not util-linux (~199120)"; exit 9
fi
echo "OK: losetup.real is util-linux"

cp "rmnt/boot/initrd.img-$KVER" newinitrd
umount rmnt
mount "${LOOP}p1" emnt
cp newinitrd emnt/initrd.img
# route the LIVE kernel console to the USB ACM serial (ttyGS0 -> host ttyACM0) so we
# can watch Mobian's console up to the reboot moment (cold reset clears ramoops).
grep -q 'console=ttyGS0' emnt/loader/entries/mobian.conf || sed -i 's#\(console=tty0\)#\1 console=ttyGS0,115200n8#' emnt/loader/entries/mobian.conf
# also blacklist IPA on the cmdline (strongest: prevents udev autoload too)
grep -q 'module_blacklist=ipa' emnt/loader/entries/mobian.conf || sed -i 's#\(rootwait\)#\1 module_blacklist=ipa#' emnt/loader/entries/mobian.conf
grep -q 'watchdog.open_timeout=0' emnt/loader/entries/mobian.conf || sed -i 's#\(rootwait\)#\1 watchdog.open_timeout=0 loglevel=7 ignore_loglevel#' emnt/loader/entries/mobian.conf
# collapse any accumulated duplicate params from earlier regens
sed -i 's#\( watchdog.open_timeout=0 loglevel=7 ignore_loglevel\)\{1,\}# watchdog.open_timeout=0 loglevel=7 ignore_loglevel#' emnt/loader/entries/mobian.conf
# root is mounted via an OFFSET loop on userdata -> resolve by fs UUID (PARTLABEL/PARTUUID don't apply to a bare-fs loop)
sed -i "s#root=PARTLABEL=mobian_root#root=UUID=$RUUID#" emnt/loader/entries/mobian.conf
sed -i "s#root=UUID=[^ ]* rw#root=UUID=$RUUID rw#" emnt/loader/entries/mobian.conf
echo "loader options now:"; grep '^options' emnt/loader/entries/mobian.conf
sync
umount emnt
losetup -d "$LOOP"
rm -f userdata-nested.simg
img2simg nested.img userdata-nested.simg
rm -f nested.img newinitrd
chown realni:realni userdata-nested.simg
ls -la userdata-nested.simg
echo PATCH_DONE
