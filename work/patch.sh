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
# The debos build leaves / owned by the build user; systemd-tmpfiles then refuses every
# /tmp rule ("unsafe path transition") -> /tmp/.X11-unix is never created -> kwin can't
# start Xwayland ("Failed to create Xwayland connection sockets") and all X11 apps die.
chown root:root rmnt
install -m0755 hooks/subpartitions rmnt/etc/initramfs-tools/hooks/subpartitions
install -m0755 scripts/subpartitions rmnt/etc/initramfs-tools/scripts/local-top/subpartitions
# watchdog-kick for the booted Mobian (so it doesn't reboot ~50s after boot)
install -Dm755 watchdog-kick rmnt/usr/sbin/watchdog-kick
mkdir -p rmnt/etc/modules-load.d; echo qcom_wdt > rmnt/etc/modules-load.d/qcom_wdt.conf
# Bluetooth input: uhid is needed for BLE-HID (HID-over-GATT / HOG) peripherals -- keyboards,
# mice, gamepads -- otherwise bluetoothd's input-hog profile accept fails and no /dev/input
# node is created even though the device shows "Connected". uinput lets AVRCP create the
# media-key passthrough device for BT headsets; joydev adds legacy /dev/input/js* for pads.
# All three are =m and were NOT autoloaded -> load at boot.
printf 'uhid\nuinput\njoydev\n' > rmnt/etc/modules-load.d/bluetooth-input.conf
# BT-off crash fix: turning Bluetooth OFF while a device is still connected powers off the
# WCN3990 mid-stream; the BT geni UART (88c000.serial) then runtime-autosuspends and
# geni_se_resources_off gates its clock + drops its interconnect (ICC) vote while the serial
# engine still has residual RX state from the live link -> the next bus access NoC-times-out
# -> qcom_wdt resets the WHOLE phone. Keeping the BT geni runtime-active avoids the gating.
# (Disconnect-first is safe; only the forcible down-with-live-link path hits this.)
mkdir -p rmnt/etc/udev/rules.d
printf 'ACTION=="add", SUBSYSTEM=="platform", KERNEL=="88c000.serial", ATTR{power/control}="on"\n' > rmnt/etc/udev/rules.d/90-bt-geni-no-autosuspend.rules
# Same UART, second problem: gpio41 (its RX line) is also wired up as a dedicated wake
# IRQ. TLMM deliberately keeps RAW_STATUS_EN set for edge IRQs while they are masked, so
# every byte of BT traffic latches an edge that nothing ever acks. dev_pm_arm_wake_irq()
# then arms an already-pending IRQ at dpm_suspend_noirq and irq_pm_handle_wakeup() aborts
# the suspend ~1s in, every single time (pm_wakeup_irq reported IRQ 152). Arming is gated
# on device_may_wakeup(), so clearing this is enough. Costs BT wake-from-suspend, which
# has never worked on this port anyway.
printf 'ACTION=="add", SUBSYSTEM=="platform", KERNEL=="88c000.serial", ATTR{power/wakeup}="disabled"\n' >> rmnt/etc/udev/rules.d/90-bt-geni-no-autosuspend.rules
# WCD9375 audio fix: the SoundWire paths program their data ports at stream
# prepare using no-PM register transfers, which -EIO unless the SWR bus clock
# (from the rx/tx macro, gated by the SoundWire controller's iface clock) is
# already running. Keeping the SoundWire controllers + macros runtime-active
# keeps that clock up, so the Headphones sink (RX: 62ef + rx-macro 62ee +
# va-macro 62f2) and the WCD9375 headset-mic path (TX: 62ed + tx-macro 62ec)
# prepare instead of the card dropping to profile "off".
# (Root-caused 2026-07-24; see WCD9375 memory.)
{
  printf 'ACTION=="add", SUBSYSTEM=="platform", KERNEL=="62ee0000.codec", ATTR{power/control}="on"\n'
  printf 'ACTION=="add", SUBSYSTEM=="platform", KERNEL=="62f20000.codec", ATTR{power/control}="on"\n'
  printf 'ACTION=="add", SUBSYSTEM=="platform", KERNEL=="62ef0000.soundwire", ATTR{power/control}="on"\n'
  printf 'ACTION=="add", SUBSYSTEM=="platform", KERNEL=="62ec0000.codec", ATTR{power/control}="on"\n'
  printf 'ACTION=="add", SUBSYSTEM=="platform", KERNEL=="62ed0000.soundwire", ATTR{power/control}="on"\n'
} > rmnt/etc/udev/rules.d/90-sunfish-audio-swr.rules
# ADSP Sensor Core -> iio-sensor-proxy. sunfish's sensors (LSM6DSR accel/gyro, TCS3701
# ALS+prox, LIS2MDL mag) hang off the hypervisor-fenced SSC bus owned by the ADSP, so
# userspace reads them over QMI/QRTR service 400 with libssc, not via IIO drivers.
# iio-sensor-proxy 3.9 ships drv-ssc-{accel,light,proximity} but its stock rules only
# tag light+compass on fastrpc-adsp; sunfish also serves accel and proximity. Append with
# `+=` rather than reassigning the whole list with `=`: an `=` only wins because 81 sorts
# after the stock 80- file, so it would silently regress if the package ever renumbered
# its rules. sunfish has no fused compass, but leaving the stock ssc-compass tag in place
# is harmless — that driver's discover() fails fast and the sensor is simply not offered.
printf 'ACTION=="add", SUBSYSTEM=="misc", KERNEL=="fastrpc-adsp*", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel ssc-proximity"\n' \
  > rmnt/etc/udev/rules.d/81-iio-sensor-proxy-sunfish.rules
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
# Grow the root fs to fill userdata on first boot. The image ships a ~4.1G ext4 inside a
# ~109G offset loop (loop0, created by the subpartitions initramfs hook); without this it
# stays 4.1G and fills up the moment the full app set is installed (which silently breaks
# maliit/presage -> no keyboard, etc). resize2fs is online + idempotent; the flag makes it
# a one-shot.
install -Dm644 /dev/stdin rmnt/usr/lib/systemd/system/resize-root.service <<'UNIT'
[Unit]
Description=Grow root filesystem to fill the userdata partition (first boot)
DefaultDependencies=no
After=local-fs.target
ConditionPathExists=!/var/lib/.rootfs-resized
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'resize2fs "$(findmnt -no SOURCE /)" && touch /var/lib/.rootfs-resized'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
ln -sf /usr/lib/systemd/system/resize-root.service rmnt/etc/systemd/system/multi-user.target.wants/resize-root.service
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
  # iproute2: minbase rootfs lacks `ip`; needed by the USB-net default-route dispatcher.
  apt-get install -y --no-install-recommends iproute2
  # Sensors: trixie ships iio-sensor-proxy 3.7 which has no Sensor Core support at all.
  # forky ships 3.9, which build-deps libssc-dev on arm64 and so can talk to the ADSP
  # SSC over QMI/QRTR (see the 81-iio-sensor-proxy-sunfish udev rule above). libssc-bin
  # brings `ssccli`, the standalone reader used to verify a sensor without the daemon.
  # The forky list+pin are written idempotently here because the Plasma block below
  # (which also writes them) only runs on an sddm image, and sensors are DE-agnostic.
  printf "deb http://deb.debian.org/debian forky main\n" > /etc/apt/sources.list.d/forky.list
  printf "Package: *\nPin: release n=forky\nPin-Priority: 100\n" > /etc/apt/preferences.d/99-forky-low
  apt-get update
  apt-get install -y -t forky iio-sensor-proxy libssc-bin
  # NFC: neard is the only NFC daemon in Debian and it needs libnl >= 3.11, which trixie
  # does not have (3.7.0-2). libnl-route-3-200 MUST be listed explicitly: pulling only
  # neard makes apt satisfy the libnl-3/libnl-genl bump while leaving libnl-route behind,
  # and its solution to that is to REMOVE wpasupplicant -- i.e. it silently trades WiFi
  # for NFC. Naming all three keeps it to an in-place upgrade of one soname family
  # (libnl-3.so.200 and friends are unchanged) with nothing removed.
  apt-get install -y -t forky neard libnl-3-200 libnl-genl-3-200 libnl-route-3-200
  # Plasma DE (installed by the debos recipe built with `-e plasma`): make SDDM the
  # display manager in place of Phosh, and add the two recommends-free omissions:
  #   - pkexec: separate package in Debian 13, needed by the Switch Mode launcher
  #   - kirigami-addons formcard QML module: without it the Plasma Mobile first-run
  #     wizard pages (wifi/cellular/time) render BLANK.
  # Guarded on sddm being present so this is a no-op on a Phosh base image.
  if command -v sddm >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends pkexec qml6-module-org-kde-kirigamiaddons-formcard
    # --- Plasma 6.6.5 from Debian forky (trixie ships only 6.3.6) ---
    # Partial dist-upgrade toward testing: pin forky LOW (100 < trixie 500) so only the
    # explicitly `-t forky` packages + the deps they force pull from forky; the Plasma
    # stack then upgrades to 6.6.5 (Qt 6.10). ~473 pkgs incl glibc 2.42; systemd/udev/
    # dbus/NM/pipewire/ModemManager stay trixie (hw bringup unaffected). --force-confold
    # preserves our DE configs (SDDM autologin, mode-toggle, BT-geni udev).
    # NB double quotes: this whole block is the body of `sh -ec '...'`, so a single quote
    # here silently CLOSES that string. Until this was fixed the chroot received a script
    # truncated at this line (unterminated `if` -> sh exits 2 -> set -e aborts patch.sh),
    # so nothing in the block ran at all. `bash -n` does not catch it: quote parity is even.
    printf "deb http://deb.debian.org/debian forky main\n" > /etc/apt/sources.list.d/forky.list
    printf "Package: *\nPin: release n=forky\nPin-Priority: 100\n" > /etc/apt/preferences.d/99-forky-low
    apt-get update
    apt-get install -y -t forky -o Dpkg::Options::=--force-confold \
      plasma-workspace plasma-desktop plasma-mobile
    # feedbackd drives the Plasma MOBILE SHELL haptics (lock-screen keyboard +
    # quicksettings: HapticsEffect.buttonVibrate -> org.sigxcpu.Feedback.Haptic ->
    # drv2624). Separate path from the maliit/hfd keyboard haptics above. The forky
    # upgrade can drop it, so (re)install explicitly; its theme is shipped below.
    apt-get install -y feedbackd
    # The partial upgrade can reset the dbus setuid launch-helper group to polkitd,
    # which silently breaks EVERY KAuth system-bus helper (flashlight, backlight/
    # brightness, ...) because the messagebus user can no longer exec it. Restore the
    # known-good owner/mode.
    H=/usr/lib/dbus-1.0/dbus-daemon-launch-helper
    [ -e "$H" ] && { chgrp messagebus "$H"; chmod 4754 "$H"; }
    systemctl disable phosh.service 2>/dev/null || true
    echo /usr/bin/sddm > /etc/X11/default-display-manager
    systemctl enable sddm.service
    systemctl set-default graphical.target
  fi
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

# --- USB-net uplink for headless apt-over-USB ---
# NetworkManager's built-in USB-gadget support regenerates a gateway-less usb0 connection
# (172.16.42.1/24) on every gadget (re)enumeration, so the device has no default route at
# boot. This NM dispatcher re-asserts a LOW-priority default route (+DNS) via the host
# (172.16.42.2) on each usb0 'up' using `ip route replace` (idempotent, no NM reentrancy).
# metric 900 keeps wifi/cellular preferred whenever they are present. Needs iproute2 (above).
if [ -d usbnet ]; then
  install -Dm755 usbnet/90-usb0-uplink rmnt/etc/NetworkManager/dispatcher.d/90-usb0-uplink
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
# --- IPA modem data path: load ipa LATE (after modem init) so rmnet_ipa0 comes up without
# the early-init silent SoC reset, then re-probe ModemManager; tear ipa down cleanly on
# shutdown (rebooting with it loaded hangs the SoC). cmdline module_blacklist=ipa is
# stripped in the ESP step below; the modprobe.d blacklist still blocks boot autoload.
if [ -d ipa ]; then
  install -Dm755 ipa/sbin/ipa-late-load.sh rmnt/usr/local/sbin/ipa-late-load.sh
  install -Dm755 ipa/sbin/ipa-teardown.sh  rmnt/usr/local/sbin/ipa-teardown.sh
  install -Dm644 ipa/units/ipa-late-load.service rmnt/etc/systemd/system/ipa-late-load.service
  ln -sf /etc/systemd/system/ipa-late-load.service \
    rmnt/etc/systemd/system/multi-user.target.wants/ipa-late-load.service
fi
# --- NFC: keep the adapter polling. The ST54J binds via nxp-nci_i2c (kernel commits
# d47a99447bad + 6546445451c6; the DT enable-gpios rename is ff0004e857d9), and neard
# comes from apt above, but neard itself never polls on its own: StartPollLoop has to be
# called by a D-Bus client, and neard drops the loop again after each target it activates.
# Plasma Mobile ships no NFC client at all, so without this unit the hardware is bound,
# powered and completely inert -- tapping a tag does nothing.
#
# This does cost battery: an armed poll loop pulses the RF field continuously. It is not
# gated on screen state, because the only cheap signal available (backlight brightness)
# was not verified to track blanking on this panel, and a wrong guess there would mean
# NFC silently never polls. `systemctl disable --now nfc-poll` if the drain matters more.
install -Dm755 /dev/stdin rmnt/usr/local/bin/nfc-poll <<'EOF'
#!/bin/sh
A=/org/neard/nfc0
while :; do
  if [ "$(busctl --system get-property org.neard $A org.neard.Adapter Polling 2>/dev/null)" \
       != "b true" ]; then
    busctl --system set-property org.neard $A org.neard.Adapter Powered b true 2>/dev/null
    busctl --system call org.neard $A org.neard.Adapter StartPollLoop s Initiator \
      >/dev/null 2>&1
  fi
  sleep 2
done
EOF
install -Dm644 /dev/stdin rmnt/etc/systemd/system/nfc-poll.service <<'EOF'
[Unit]
Description=Keep the NFC adapter polling for tags
Requires=neard.service
After=neard.service

[Service]
ExecStart=/usr/local/bin/nfc-poll
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/nfc-poll.service \
  rmnt/etc/systemd/system/multi-user.target.wants/nfc-poll.service
# --- Idle power: bind venus so rpmhpd/interconnect sync_state() can fire.
# venus is blacklisted for autoload, so nothing ever binds aa00000.video-codec, and it is the
# last unbound consumer of rpmhpd + the config/mmss/gem NoCs. While a provider has an unbound
# consumer, sync_state() never runs: rpmhpd_aggregate_corner() then pins EVERY rail to its
# maximum corner in the RPMh SLEEP set as well as the active set, and the NoCs keep the
# boot-time INT_MAX bandwidth clamp. Measured effect of loading it: state_synced 0 -> 1, every
# INT_MAX gone, cx/mx down to corner 64, and DDR DVFS starts actually switching frequency
# (was count:1 on two frequencies for a whole boot). Loaded late so a video firmware fault
# leaves the phone up and reachable instead of wedging the boot.
{
  printf '[Unit]\n'
  printf 'Description=Bind venus so rpmhpd/interconnect sync_state() can fire\n'
  printf 'After=systemd-user-sessions.service sshd.service\n'
  printf '[Service]\n'
  printf 'Type=oneshot\n'
  printf 'RemainAfterExit=yes\n'
  printf 'ExecStart=/sbin/modprobe venus_dec\n'
  printf '[Install]\n'
  printf 'WantedBy=multi-user.target\n'
} > rmnt/etc/systemd/system/venus-rpmhpd-sync.service
ln -sf /etc/systemd/system/venus-rpmhpd-sync.service \
  rmnt/etc/systemd/system/multi-user.target.wants/venus-rpmhpd-sync.service
# --- hexagonrpcd sensor daemons: serve the ADSP root PD + sensors PD FastRPC endpoints so the
# SEE/CHRE sensor firmware brings up (replaces the old stop-adsp-ssr workaround, now that the
# sar.cc:27 SSR loop is fixed at the source via the smp2p sleepstate dtb entry added below).
if [ -d hexagonrpc ]; then
  install -Dm755 hexagonrpc/bin/hexagonrpcd rmnt/usr/bin/hexagonrpcd
  install -Dm644 hexagonrpc/lib/libhexagonrpc.so.0.4 rmnt/usr/lib/aarch64-linux-gnu/libhexagonrpc.so.0.4
  # NOTE: sensors/config/s5_lsm6dsr.json deliberately DIFFERS from the stock capture.
  # Its .orient block is x=+y y=-x z=+z, i.e. stock's -y/+x/+z plus 180 deg about Z.
  # Without that half-turn iio-sensor-proxy reports "bottom-up" while the phone is
  # upright, so KWin auto-rotates to Rotation 2 instead of 8 and the screen sits
  # upside down. ACCEL_MOUNT_MATRIX in udev does NOT help: the ssc-accel backend
  # ignores it and takes the matrix from the ADSP (which returns all zeros).
  # Do not "restore" this file from a fresh vendor capture without re-applying it.
  mkdir -p rmnt/usr/share/qcom/sm7150/Google && cp -a hexagonrpc/share/sunfish rmnt/usr/share/qcom/sm7150/Google/
  install -Dm644 hexagonrpc/units/hexagonrpcd-adsp-rootpd.service rmnt/etc/systemd/system/hexagonrpcd-adsp-rootpd.service
  install -Dm644 hexagonrpc/units/hexagonrpcd-adsp-sensorspd.service rmnt/etc/systemd/system/hexagonrpcd-adsp-sensorspd.service
  ln -sf /etc/systemd/system/hexagonrpcd-adsp-rootpd.service \
    rmnt/etc/systemd/system/multi-user.target.wants/hexagonrpcd-adsp-rootpd.service
  ln -sf /etc/systemd/system/hexagonrpcd-adsp-sensorspd.service \
    rmnt/etc/systemd/system/multi-user.target.wants/hexagonrpcd-adsp-sensorspd.service
fi
# --- sunfish audio (kernel branch sunfish-audio-tdm): SEC_TDM speaker machine-driver
# module + saved mixer state (SEC_TDM_RX_0 routing + moderate amp volumes), plus the
# built-in-mic stack: RT5514P codec on tertiary TDM (snd-soc-rt5514 + rl6231 PLL lib)
# and the q6afe TDM-control-field plumbing the capture port needs.
if [ -d kernel ]; then
  install -Dm644 kernel/snd-soc-sm8250.ko \
    "rmnt/lib/modules/$KVER/kernel/sound/soc/qcom/snd-soc-sm8250.ko"
  install -Dm644 kernel/q6afe.ko \
    "rmnt/lib/modules/$KVER/kernel/sound/soc/qcom/qdsp6/q6afe.ko"
  install -Dm644 kernel/q6afe-dai.ko \
    "rmnt/lib/modules/$KVER/kernel/sound/soc/qcom/qdsp6/q6afe-dai.ko"
  install -Dm644 kernel/snd-soc-rt5514.ko \
    "rmnt/lib/modules/$KVER/kernel/sound/soc/codecs/snd-soc-rt5514.ko"
  install -Dm644 kernel/snd-soc-rl6231.ko \
    "rmnt/lib/modules/$KVER/kernel/sound/soc/codecs/snd-soc-rl6231.ko"
  # q6dsp-lpass-clocks publishes its drvdata before registering clocks; without
  # that, an ADSP restart re-parents the still-prepared LPASS orphan clocks and
  # calls .prepare with a NULL drvdata. That oops happens under the clock
  # framework's prepare_lock, so it also wedges UFS runtime-resume and the rootfs.
  install -Dm644 kernel/snd-q6dsp-common.ko \
    "rmnt/lib/modules/$KVER/kernel/sound/soc/qcom/qdsp6/snd-q6dsp-common.ko"
  # Suspend fix. The bootloader leaves the APSS watchdog running, so qcom-wdt sets
  # WDOG_HW_RUNNING and the watchdog core pings it from a kernel worker. Workers are
  # frozen while suspended and the stock qcom_wdt_suspend() only stops the hardware once
  # userspace has opened /dev/watchdog, so it kept biting mid-suspend and resetting the
  # phone -- which looked exactly like a broken resume. NB this module is listed in
  # modules-load.d, so it is loaded from the INITRAMFS; the update-initramfs below is what
  # actually makes this take effect, not the copy into /lib/modules.
  install -Dm644 kernel/qcom-wdt.ko \
    "rmnt/lib/modules/$KVER/kernel/drivers/watchdog/qcom-wdt.ko"
  # Rest of the suspend chain, all autoloaded (no modules-load.d entry needed).
  # smp2p_sleepstate tells the ADSP over SMP2P that we are going down, so it stops
  # handing us sensor reverse-RPC we can no longer service; without it the DSP takes a
  # fatal error on the requests that were already in flight when the freezer ran.
  install -Dm644 kernel/smp2p_sleepstate.ko \
    "rmnt/lib/modules/$KVER/kernel/drivers/soc/qcom/smp2p_sleepstate.ko"
  # fastrpc freezes in its invoke wait instead of aborting it, so a task sitting in a
  # FastRPC call is a freezable sleep rather than an -ERESTARTSYS the caller mishandles.
  install -Dm644 kernel/fastrpc.ko \
    "rmnt/lib/modules/$KVER/kernel/drivers/misc/fastrpc.ko"
  # soundwire-qcom stops touching the hardware once the ADSP is gone; the bus clock is
  # owned by the LPASS macros, so post-SSR register access there is an external abort.
  install -Dm644 kernel/soundwire-qcom.ko \
    "rmnt/lib/modules/$KVER/kernel/drivers/soundwire/soundwire-qcom.ko"
  # i2c-qcom-cci never armed its autosuspend timer, so the camera control interface sat
  # runtime-active with its clocks on for the whole uptime (nothing uses the camera, so the
  # first get/put that would have idled it never came). That held 8 camcc clocks and kept
  # the RPMh XO vote up: bi_tcxo prepare count 93 -> 15 with this in place.
  install -Dm644 kernel/i2c-qcom-cci.ko \
    "rmnt/lib/modules/$KVER/kernel/drivers/i2c/busses/i2c-qcom-cci.ko"
  depmod -b rmnt "$KVER"
  install -Dm644 kernel/asound.state rmnt/var/lib/alsa/asound.state
  # UCM2 profile: PipeWire/WirePlumber pick up the card as a desktop sink
  # ("Internal stereo speakers"); hw volumes fixed safe, softvol on top.
  install -Dm644 "kernel/ucm/Google/sunfish/HiFi.conf" \
    rmnt/usr/share/alsa/ucm2/Google/sunfish/HiFi.conf
  install -Dm644 "kernel/ucm/conf.d/sm8250/google-GooglePixel4a.conf" \
    rmnt/usr/share/alsa/ucm2/conf.d/sm8250/google-GooglePixel4a.conf
  install -Dm644 "kernel/ucm/conf.d/sm8250/Google Pixel 4a.conf" \
    "rmnt/usr/share/alsa/ucm2/conf.d/sm8250/Google Pixel 4a.conf"
  # Force the sink to S16 (the sec-TDM link runs 16-bit slots; a 24-bit
  # PipeWire stream is accepted by the DSP but comes out inaudible).
  install -Dm644 kernel/wireplumber/51-sunfish-s16.conf \
    rmnt/etc/wireplumber/wireplumber.conf.d/51-sunfish-s16.conf
  # CS35L41 CSPL speaker-protection DSP firmware (stock vendor blobs) —
  # UCM preloads it and routes PCM through the DSP; unlocks stock gain 17.
  # The -google-sunfish-{ear,spk} set gives each amp its own tuning
  # (DT cirrus,subsystem-id + sound-name-prefix); plain pair = fallback.
  for f in kernel/cirrus/*; do
    install -Dm644 "$f" "rmnt/lib/firmware/cirrus/${f##*/}"
  done
fi
# --- MCFG modem carrier-config RFS tree, extracted from the stock vendor partition
# (super -> vendor_a -> rfs/msm/mpss/readonly). The patched tqftpserv above (wcn/bin/tqftpserv,
# which adds a /readonly/vendor/mbn/ -> this tree mapping) serves it so the modem LOADS its
# 25 PDC carrier configs (qmicli --pdc-list-configs; was empty before). NOTE: modem still
# won't bring RF online (DeviceNotReady) -> no registration/data; this is a required
# prerequisite, not the full fix. See memory sunfish_modem_bringup.
if [ -d mcfg ]; then
  mkdir -p rmnt/usr/local/share/tqftp-ro
  cp -a mcfg/readonly rmnt/usr/local/share/tqftp-ro/
fi

# --- Plasma Mobile + Plasma Desktop + Steam-Deck-style mode toggle (config files) ---
# DE packages come from the recipe (`-e plasma`); the DM wiring + extra packages are in
# the chroot apt block above. Here we drop the sunfish-specific config: SDDM autologin
# (default = Plasma Mobile), and the pkexec-driven "Switch Mode" launcher that flips the
# autologin session (plasma-mobile.desktop <-> plasma.desktop) and relaunches the
# graphical stack. NOTE: a plain `systemctl restart sddm` does NOT switch — Plasma 6 runs
# kwin/plasmashell as user@ services that survive it; plasma-mode-switch ends the user
# session (loginctl terminate-user) and relaunches sddm from a transient system unit.
if [ -d plasma ]; then
  install -Dm755 plasma/plasma-mode-switch                    rmnt/usr/local/bin/plasma-mode-switch
  install -Dm644 plasma/org.mobian.plasma-mode-switch.policy  rmnt/usr/share/polkit-1/actions/org.mobian.plasma-mode-switch.policy
  install -Dm644 plasma/plasma-mode-switch.desktop            rmnt/usr/share/applications/plasma-mode-switch.desktop
  install -Dm644 plasma/zz-autologin.conf                     rmnt/etc/sddm.conf.d/zz-autologin.conf
  # Screen orientation per mode: Plasma Mobile -> portrait, Plasma Desktop -> landscape.
  # Autostart entry runs in both shells, reads the autologin Session= and rotates DSI-1
  # (native portrait panel: rotation none=portrait, right=landscape) so each toggle lands
  # in the matching orientation.
  install -Dm755 plasma/plasma-mode-orientation               rmnt/usr/local/bin/plasma-mode-orientation
  install -Dm644 plasma/plasma-mode-orientation.desktop       rmnt/etc/xdg/autostart/plasma-mode-orientation.desktop
  # Disable the KScreenLocker auto-lock + lock-on-resume system-wide. On the msm_dpu
  # (Adreno 618) driver a freshly-spawned kscreenlocker_greet cannot create its EGL
  # surface while the panel is blanked ("Could not create EGL surface" / eglSwapBuffers
  # 0x300d surface:0x0), so reboot/switch — which come up locked — strand the device on
  # a black, unrenderable lockscreen. /etc/xdg is in XDG_CONFIG_DIRS so this is the
  # home-dir-independent default; a user kscreenlockerrc still overrides it.
  install -Dm644 plasma/kscreenlockerrc                       rmnt/etc/xdg/kscreenlockerrc
  # Screenshot helper: KWin's ScreenShot2 capture hangs if the panel is DPMS-blanked
  # (waits for a frame that never comes). This wakes the display + nudges a repaint, then
  # captures via spectacle (needs kde-spectacle, from the recipe). Saves ~/Pictures/Screenshots.
  install -Dm755 plasma/screenshot                            rmnt/usr/local/bin/screenshot
fi
# --- Default to the Halcyon homescreen instead of Folio ---
# Folio's bottom app dock renders as an empty translucent band over the wallpaper when
# no favourites are pinned (its frosted-glass backdrop doesn't help on this GPU), which
# reads as a graphics glitch. Halcyon (grid homescreen) has no such dock. A fresh user's
# default homescreen comes from the mobileshell package 'defaults' file.
MSHELL_DEFAULTS=rmnt/usr/share/plasma/shells/org.kde.plasma.mobileshell/contents/defaults
if [ -f "$MSHELL_DEFAULTS" ]; then
  sed -i 's|^Containment=org.kde.plasma.mobile.homescreen.folio|Containment=org.kde.plasma.mobile.homescreen.halcyon|' "$MSHELL_DEFAULTS"
fi
# --- Keyboard/button haptics under Plasma Mobile (feedbackd theme) ---
# Plasma/KDE does not use feedbackd by default, but it works once the device theme is
# present: Mobian's stock 90-feedbackd.rules already tags the drv2624 vibrator
# (/dev/input/event3) as FEEDBACKD_TYPE=vibra with uaccess. This sunfish theme (ported
# from pmOS) defines the key-pressed/button-pressed VibraPatterns; without it feedbackd
# falls back to "default" which has no keypress haptic for this device.
if [ -d feedbackd ]; then
  install -Dm644 "feedbackd/google,sunfish.json" "rmnt/usr/share/feedbackd/themes/google,sunfish.json"
fi
# Maliit keyboard keypress haptics: ship the gsetting default key-press-feedback=true via
# the dconf system db. The vibration itself needs hfd-service + libqt5feedback5-hfd (from
# the recipe) which provide the Qt5Feedback haptic backend (VibratorFF -> drv2624);
# AccountsService AllowGeneralVibration defaults true once accounts-daemon loads hfd's
# extension at boot.
if [ -d plasma ] && [ -f plasma/dconf-maliit-haptics ]; then
  install -Dm644 plasma/dconf-maliit-haptics rmnt/etc/dconf/db/local.d/00-plasma-mobile-haptics
  mkdir -p rmnt/etc/dconf/profile
  if [ ! -f rmnt/etc/dconf/profile/user ]; then
    printf 'user-db:user\nsystem-db:local\n' > rmnt/etc/dconf/profile/user
  elif ! grep -q '^system-db:local$' rmnt/etc/dconf/profile/user; then
    echo 'system-db:local' >> rmnt/etc/dconf/profile/user
  fi
  chroot rmnt /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin dconf update 2>/dev/null || true
fi
# maliit-keyboard ships a buggy ExtendedKeysSelector.qml (the long-press accent popup): it
# references a `Theme` object that this Debian build does not provide anywhere (used in no
# other maliit qml, no Theme module), so the popup throws "ReferenceError: Theme is not
# defined" and renders glitched. Hardcode the two colours (Breeze: highlight blue / white)
# so the popup renders. `@`-delimited sed because the colour value contains `#`.
EKS=rmnt/usr/lib/aarch64-linux-gnu/maliit/keyboard2/qml/keys/ExtendedKeysSelector.qml
if [ -f "$EKS" ]; then
  sed -i 's@color: key.highlight ? Theme.selectionColor : Theme.fontColor@color: key.highlight ? "#3daee9" : "white"@' "$EKS"
fi

# Suspend/resume works (see the qcom-wdt + fastrpc + BT-wake fixes above), so sleep is ENABLED.
# It used to be masked because resume lost the USB gadget link: NM treats usb0 as an "external"
# (assumed) device, and on resume it dropped usb0 to unmanaged->disconnected and then auto-
# activated the generic DHCP profile 'Wired connection 1' instead of usb0's own static profile.
# There is no DHCP server on that link, so the phone stayed unreachable until a reboot. The fix
# is to let usb0's own profile autoconnect and outrank the generic one. NM stores the gadget
# connection in its own state dir, so patch it there if present and fall back to a keyfile.
# hibernate stays masked: there is no swap on this device.
for t in hibernate hybrid-sleep; do ln -sf /dev/null "rmnt/etc/systemd/system/$t.target"; done
# A real keyfile in /etc, not a conf.d default: NM's generated gadget profile sets
# autoconnect=false EXPLICITLY, and connection defaults never override an explicit value.
# Deliberately NO mac-address= -- NM's own generated profile pins the gadget MAC, which would
# stop the profile matching if that MAC is ever regenerated, leaving the phone unreachable.
# Match on interface-name only.
install -Dm600 /dev/stdin rmnt/etc/NetworkManager/system-connections/usb0.nmconnection <<'EOF'
[connection]
id=usb0
uuid=25007016-8683-4e15-a9b7-fa81ee015876
type=ethernet
autoconnect=true
autoconnect-priority=100
interface-name=usb0

[ipv4]
address1=172.16.42.1/24
gateway=172.16.42.2
method=manual

[ipv6]
addr-gen-mode=default
method=link-local
EOF
# Do NOT add a system-sleep hook to "help" this along: systemd-sleep runs post hooks BEFORE
# logind announces the wake, so NM still has usb0 strictly unmanaged at that point. A hook that
# waits for the IP just blocks resume for its whole timeout and then fails; measured 78 s to
# recover with a 30 s hook vs 48 s (a ~3 s recovery) with no hook at all, for a 45 s alarm.

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
# --- Audio+sensors kernel: sleepstate SMP2P + masked 32-pad LPI pinctrl + sec-TDM
# speaker audio (see kernel branch sunfish-audio-tdm). The dtb is built from source
# (already carries sleepstate + gpio-reserved-ranges); the fdtput blocks below remain
# as idempotent no-ops / BT-address refresh.
if [ -d kernel ]; then
  cp kernel/vmlinuz.efi emnt/vmlinuz.efi
  cp kernel/sm7150-google-sunfish.dtb emnt/sm7150-google-sunfish.dtb
fi
# Fast-boot console: strip serial consoles from the base entry. Routing the verbose kernel
# log out ttyMSM0/ttyGS0 @115200 synchronously (amplified by the sar.cc ADSP SSR spam)
# throttled boot to ~8 min. Keep only the framebuffer console.
# (Re-add ` console=ttyGS0,115200n8` here if you need the USB-serial debug capture.)
sed -i -e 's# console=ttyGS0,115200n8##g' -e 's# console=ttyMSM0,115200n8##g' emnt/loader/entries/mobian.conf
# IPA must stay RUNTIME-LOADABLE: the modem data path needs ipa loaded LATE, after modem
# init (see ipa-late-load.service). The modprobe.d `install ipa /bin/true` already blocks
# udev/boot autoload, so a kernel-cmdline blacklist is redundant AND would make the kernel
# refuse `modprobe -i ipa`. Strip it from the base entry if present.
sed -i 's# module_blacklist=ipa##g' emnt/loader/entries/mobian.conf
# Quiet boot. The 05-30 base ships verbose `loglevel=7 ignore_loglevel` (+ a DUPLICATED
# watchdog.open_timeout=0) which floods the throttled console -> ~8 min boot. Normalise
# robustly (idempotent on re-run, works whatever the base state): strip the verbose flags,
# dedup watchdog.open_timeout=0, then ensure exactly one `quiet` right after it.
sed -i -E 's#( loglevel=7| ignore_loglevel| quiet)##g' emnt/loader/entries/mobian.conf
sed -i -E 's#  +# #g' emnt/loader/entries/mobian.conf
sed -i -E 's#( watchdog\.open_timeout=0)+# watchdog.open_timeout=0#' emnt/loader/entries/mobian.conf
grep -q 'watchdog.open_timeout=0' emnt/loader/entries/mobian.conf || sed -i 's# rootwait# rootwait watchdog.open_timeout=0#' emnt/loader/entries/mobian.conf
sed -i 's# watchdog\.open_timeout=0# watchdog.open_timeout=0 quiet#' emnt/loader/entries/mobian.conf
# fw_devlink defaults to sync_state=strict, which merely PRINTS "sync_state() pending due to X"
# and waits forever for X to bind. Three consumers on this device never bind (venus is
# blacklisted, ipa is late-loaded, and 506a000.gmu has no driver at all because mainline's
# adreno grabs the GMU node with of_find_device_by_node instead of binding it). The result was
# that gcc + gpucc NEVER ran clk_sync_state, so their unused clocks were never gated, and the
# NoC/rpmhpd clamps only lifted if something happened to bind later. `timeout` forces sync_state
# once the deferred-probe timeout expires (CONFIG_DRIVER_DEFERRED_PROBE_TIMEOUT=10 is set).
grep -q 'fw_devlink.sync_state=' emnt/loader/entries/mobian.conf || sed -i 's#^options #options fw_devlink.sync_state=timeout #' emnt/loader/entries/mobian.conf
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
# ADSP: the SEE firmware's remote_proc_state sensor needs the AP-side "sleepstate" SMP2P
# outbound entry. Without it CHRE watchdog-kills the sensor PD every ~10s (sar.cc:27) and the
# sound card tears down with it. Add the smp2p-adsp sleepstate-out entry (idempotent).
D=emnt/sm7150-google-sunfish.dtb
if ! fdtget "$D" /smp2p-adsp/sleepstate-out qcom,entry-name >/dev/null 2>&1; then
  fdtput -c "$D" /smp2p-adsp/sleepstate-out
  fdtput -t s "$D" /smp2p-adsp/sleepstate-out qcom,entry-name sleepstate
  fdtput -t u "$D" /smp2p-adsp/sleepstate-out "#qcom,smem-state-cells" 1
fi
echo "dtb sleepstate entry: $(fdtget "$D" /smp2p-adsp/sleepstate-out qcom,entry-name 2>&1)"
sync
umount emnt
losetup -d "$LOOP"
rm -f userdata-nested.simg
img2simg nested.img userdata-nested.simg
rm -f nested.img newinitrd
chown realni:realni userdata-nested.simg
ls -la userdata-nested.simg
echo PATCH_DONE
