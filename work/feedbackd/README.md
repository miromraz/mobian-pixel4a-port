# Haptics on Plasma Mobile (sunfish)

Restores keypress/button haptics under Plasma Mobile, ported from the pmOS
sm7150 device package.

## Install (live)
    install -D -m0644 google,sunfish.json /usr/share/feedbackd/themes/google,sunfish.json
    pkill -f /usr/libexec/feedbackd   # reload (D-Bus re-activates with new theme)

## Why this is all that's needed on Mobian
- Kernel drv2624 driver already loaded -> /dev/input/event3 "drv2624:haptics".
- Mobian's stock /usr/lib/udev/rules.d/90-feedbackd.rules ALREADY tags event3
  with FEEDBACKD_TYPE=vibra and grants the session user uaccess. So unlike pmOS
  we do NOT need the extra 90-feedbackd-drv2624.rules.
- The ONLY missing piece was this device theme. feedbackd matches it by the DT
  compatible "google,sunfish" -> google,sunfish.json. Without it feedbackd fell
  back to "default" which has no key-pressed pattern.

Verified: `fbcli -E key-pressed` plays the VibraPattern after the theme is loaded.
