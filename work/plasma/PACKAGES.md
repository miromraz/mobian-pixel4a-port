# Plasma packages required on the device (for the bake-phase recipe)

Installed live on sunfish and verified. The debos recipe (`packages-plasma.yaml`)
must list these explicitly, because Mobian builds with `recommends: false` — so
recommended QML runtime modules are NOT pulled automatically and must be named.

## Core
- `plasma-mobile`      (Plasma Mobile shell + session `plasma-mobile.desktop`)
- `plasma-desktop`     (Plasma Desktop session `plasma.desktop`)
- `sddm`               (display manager, autologin)
- `pkexec`             (SEPARATE package in Debian 13 — needed by the Switch Mode
                        launcher; NOT pulled by plasma with --no-install-recommends)

## QML runtime modules that recommends:false / --no-install-recommends drops
These caused blank pages in the Plasma Mobile first-run wizard (WiFi/cellular/
time/system-navigation) and the homescreen settings. Root cause was the missing
`org.kde.kirigamiaddons.formcard` module. Install explicitly:
- `qml6-module-org-kde-kirigamiaddons-formcard`   (pulls -datetime)
- `qml6-module-org-kde-kirigamiaddons-datetime`

NOTE: a full audit of "recommended qml6 modules not installed" found formcard was
the ONLY missing *recommended* one; the others (labs-components, settings, sounds,
statefulapp) are available but not required by the installed set. If other Plasma
apps show blank pages later, re-run the audit:
    dpkg-query -W -f='${Recommends}\n' | tr ',|' '\n\n' | awk '{print $1}' \
      | grep '^qml6-module-' | sort -u \
      | while read m; do dpkg -s "$m" >/dev/null 2>&1 || echo "$m"; done

## Keyboard haptics (SOLVED)
Debian's maliit-keyboard uses **Qt5Feedback**, whose only stock backend (mmk =
QFeedbackFileInterface) plays SOUND, not vibration — so keypress haptics were dead
(Phosh used squeekboard+feedbackd; that path is gone). The vibrator HW is fine
(event3 = drv2624:haptics). Fix = the hfd haptic backend chain:

  maliit (key-press-feedback=true) -> Qt5Feedback -> libqtfeedback_hfd
    -> hfd-service (VibratorFF impl) -> /dev/input/event3 (drv2624)

Required (now in include/packages-plasma.yaml):
- `hfd-service`            (Lomiri Hardware Feedback Daemon; has a VibratorFF impl)
- `libqt5feedback5-hfd`    (the Qt5Feedback vibration backend; mmk only does sound)
  (pulls libdeviceinfo0, libyaml-cpp0.8)

Config (now in patch.sh via dconf system db, work/plasma/dconf-maliit-haptics):
- `org.maliit.keyboard.maliit key-press-feedback = true`

No per-user setup needed for the permission gate: hfd-service ships an AccountsService
extension (com.lomiri.hfd.AccountsService.Settings) whose `AllowGeneralVibration`
defaults TRUE; accounts-daemon loads it at boot. Verified persistent across reboot.

NOTE: the feedbackd theme in work/feedbackd/ is a SEPARATE path — it only helps
libfeedback apps (gnome-calls, notifications), NOT the maliit keyboard.
