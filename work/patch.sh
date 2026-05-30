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
# ath10k WCN3990 runtime firmware (passive — only used once ath10k_snoc loads, after the
# mpss modem rproc is up). board-2.bin carries variant=google_sunfish; firmware-5.bin is the
# 60-byte QCA-ATH10K API header (real WLAN fw = wlanmdsp.mbn, already in /lib/firmware/qcom).
install -Dm644 ath10k-WCN3990-board-2.bin    rmnt/usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin
install -Dm644 ath10k-WCN3990-firmware-5.bin rmnt/usr/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin
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

# --- SSH access for autonomous host-driven work over USB-net (172.16.42.1) ---
# Install openssh-server in the qemu-binfmt aarch64 chroot. Needs DNS for apt, so
# swap in the host resolv.conf for the duration and restore the image's after.
RESOLV_LINK=
[ -L rmnt/etc/resolv.conf ] && RESOLV_LINK=$(readlink rmnt/etc/resolv.conf)
rm -f rmnt/etc/resolv.conf; cp /etc/resolv.conf rmnt/etc/resolv.conf
chroot rmnt /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive sh -ec '
  apt-get update
  apt-get install -y --no-install-recommends openssh-server
  ssh-keygen -A                 # generate host keys (postinst may skip under qemu)
  systemctl enable ssh
  # qcom modem/WiFi/BT userspace: qrtr-ns + rmtfs (bring libqrtr1 too, needed by
  # the prebuilt tqftpserv/pd-mapper). Their services are enabled by the packages.
  apt-get install -y --no-install-recommends qrtr-tools rmtfs
'
rm -f rmnt/etc/resolv.conf
[ -n "$RESOLV_LINK" ] && ln -s "$RESOLV_LINK" rmnt/etc/resolv.conf
# host pubkey -> mobian (uid 1000) authorized_keys; passwordless sudo for non-interactive ops
if [ -f ssh-authorized-keys ]; then
  install -d -m700 rmnt/home/mobian/.ssh
  install -m600 ssh-authorized-keys rmnt/home/mobian/.ssh/authorized_keys
  chown -R 1000:1000 rmnt/home/mobian/.ssh
  printf 'mobian ALL=(ALL) NOPASSWD:ALL\n' > rmnt/etc/sudoers.d/90-mobian-nopasswd
  chmod 440 rmnt/etc/sudoers.d/90-mobian-nopasswd
fi

# --- WCN3990 WiFi + Bluetooth bringup (qcom mainline userspace, replicating pmOS) ---
# qrtr-ns + rmtfs come from apt above; tqftpserv + pd-mapper are prebuilt (built on-device
# against Debian libs: tqftpserv->libqrtr+libzstd, pd-mapper->libqrtr+liblzma).
if [ -d wcn ]; then
  install -Dm755 wcn/bin/tqftpserv  rmnt/usr/local/bin/tqftpserv
  install -Dm755 wcn/bin/pd-mapper  rmnt/usr/local/bin/pd-mapper
  install -Dm755 wcn/sbin/wcn-wifi-bringup.sh rmnt/usr/local/sbin/wcn-wifi-bringup.sh
  install -Dm755 wcn/sbin/wcn-bt-addr.sh      rmnt/usr/local/sbin/wcn-bt-addr.sh
  for u in tqftpserv pd-mapper wcn-wifi wcn-bt; do
    install -Dm644 "wcn/units/$u.service" "rmnt/etc/systemd/system/$u.service"
    ln -sf "/etc/systemd/system/$u.service" \
      "rmnt/etc/systemd/system/multi-user.target.wants/$u.service"
  done
  # ath10k_snoc must probe ONCE, after WLFW is up (else "host capability rejected: 90")
  echo 'blacklist ath10k_snoc' > rmnt/etc/modprobe.d/ath10k-snoc-blacklist.conf
  # pd-mapper + fw loads need the device firmware dir on the search path
  echo 'w /sys/module/firmware_class/parameters/path - - - - /lib/firmware/qcom/sm7150/google/sunfish' \
    > rmnt/etc/tmpfiles.d/qcom-fw-path.conf
fi
# never auto-suspend: Phosh idle-suspend tears down the USB gadget (looks like a shutdown)
for t in sleep suspend hibernate hybrid-sleep; do ln -sf /dev/null "rmnt/etc/systemd/system/$t.target"; done

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
# Bluetooth: WCN3990 has no BD address in NVM, so hci0 comes up unconfigured (DOWN RAW).
# Inject a stable locally-administered local-bd-address into the boot dtb (loaded via the
# loader 'devicetree' line) so hci_qca configures hci0 at probe. Bytes are little-endian
# (= display 02:91:00:5f:00:01). wcn-bt.service remains as a runtime fallback.
BT_NODE=/soc@0/geniqup@8c0000/serial@88c000/bluetooth
if fdtget emnt/sm7150-google-sunfish.dtb "$BT_NODE" compatible >/dev/null 2>&1; then
  fdtput -t bx emnt/sm7150-google-sunfish.dtb "$BT_NODE" local-bd-address 0x01 0x00 0x5f 0x00 0x91 0x02
  echo "dtb local-bd-address: $(fdtget -t bx emnt/sm7150-google-sunfish.dtb "$BT_NODE" local-bd-address 2>&1)"
else
  echo "WARN: bluetooth node not found in dtb, skipping local-bd-address"
fi
sync
umount emnt
losetup -d "$LOOP"
rm -f userdata-nested.simg
img2simg nested.img userdata-nested.simg
rm -f nested.img newinitrd
chown realni:realni userdata-nested.simg
ls -la userdata-nested.simg
echo PATCH_DONE
