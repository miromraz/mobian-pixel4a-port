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
    printf 'deb http://deb.debian.org/debian forky main\n' > /etc/apt/sources.list.d/forky.list
    printf 'Package: *\nPin: release n=forky\nPin-Priority: 100\n' > /etc/apt/preferences.d/99-forky-low
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
# --- hexagonrpcd sensor daemons: serve the ADSP root PD + sensors PD FastRPC endpoints so the
# SEE/CHRE sensor firmware brings up (replaces the old stop-adsp-ssr workaround, now that the
# sar.cc:27 SSR loop is fixed at the source via the smp2p sleepstate dtb entry added below).
if [ -d hexagonrpc ]; then
  install -Dm755 hexagonrpc/bin/hexagonrpcd rmnt/usr/bin/hexagonrpcd
  install -Dm644 hexagonrpc/lib/libhexagonrpc.so.0.4 rmnt/usr/lib/aarch64-linux-gnu/libhexagonrpc.so.0.4
  mkdir -p rmnt/usr/share/qcom/sm7150/Google && cp -a hexagonrpc/share/sunfish rmnt/usr/share/qcom/sm7150/Google/
  install -Dm644 hexagonrpc/units/hexagonrpcd-adsp-rootpd.service rmnt/etc/systemd/system/hexagonrpcd-adsp-rootpd.service
  install -Dm644 hexagonrpc/units/hexagonrpcd-adsp-sensorspd.service rmnt/etc/systemd/system/hexagonrpcd-adsp-sensorspd.service
  ln -sf /etc/systemd/system/hexagonrpcd-adsp-rootpd.service \
    rmnt/etc/systemd/system/multi-user.target.wants/hexagonrpcd-adsp-rootpd.service
  ln -sf /etc/systemd/system/hexagonrpcd-adsp-sensorspd.service \
    rmnt/etc/systemd/system/multi-user.target.wants/hexagonrpcd-adsp-sensorspd.service
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
