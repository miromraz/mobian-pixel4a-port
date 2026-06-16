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

## Open issue (not yet fixed): keyboard haptics
Plasma Mobile/KDE does NOT use feedbackd (Phosh did). Vibrator HW works
(event3 = drv2624:haptics). Maliit keyboard haptics go through Qt feedback, not
feedbackd — currently no vibration on keypress. Needs further investigation.
