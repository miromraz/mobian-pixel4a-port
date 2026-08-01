# Mobian on the Google Pixel 4a (`sunfish`, SM7150)

Debian 13 "trixie" + **Plasma Mobile/Desktop** running on a **mainline Linux kernel**
on the Pixel 4a, with drivers reverse-engineered for this device.

**What it feels like today:** a small Linux computer that boots reliably, has working
display, WiFi, Bluetooth, sound, sensors and cameras. **It is not yet a usable phone** —
there is no mobile data and battery life is mediocre. Treat it as a
second device, not your daily driver.

> ⚠️ **This will erase your phone**, requires an unlocked bootloader, and is not
> supported by Google or Debian. You are expected to be comfortable with `fastboot`
> and recovering a device that won't boot. Nothing here is guaranteed.

---

## Kernel source

The mainline kernel is the whole point of this project. It lives in a separate tree —
this repo carries only the userspace, recipe and device fixes, not the built kernel.

- Tree: **[github.com/miromraz/linux](https://github.com/miromraz/linux)**
- Branch **`sunfish-venus-v7.2`** — 74 commits on top of `sm7150-mainline/linux`
  `v7.2`. **This is the branch that matches this repo**; build it for the image below.
- Branch **`sunfish-fuel-gauge-v7.2`** — 3 further commits (PM6150 fuel gauge, charger,
  charge-status), submitted upstream as
  [sm7150-mainline/linux#58](https://github.com/sm7150-mainline/linux/pull/58).

> ⚠️ The repo's **default branch is `v7.1`, which is NOT this port.** Check out
> `sunfish-venus-v7.2` explicitly.

---

## What works

| | |
|-|-|
| Boot, display, touch, GPU (a630) | ✅ |
| Plasma Mobile + Desktop, one-tap mode toggle | ✅ |
| WiFi (2.4/5 GHz) | ✅ |
| Bluetooth, incl. BLE input devices | ✅ |
| Speakers, headphones, built-in microphone | ✅ |
| Sensors: accelerometer, light, proximity (auto-rotate) | ✅ |
| Battery, charging, USB-C | ✅ |
| Haptics, torch | ✅ |
| Front camera (IMX355, 8 MP stills) | ✅ cold boot, non-root |
| Rear camera (IMX363, 12 MP stills) | ✅ camss is RDI-only so debayering is on the CPU; preview uses a 2×2-binned 2016×1512 mode, shutter lag ~1.5 s |
| NFC (ST54J via `nxp-nci`), incl. MIFARE Classic tag reading | ✅ needs `neard`; no card emulation / HCE |
| Hardware video **decode** (H.264/VP8/VP9/HEVC) | ✅ MPEG-2 is masked |
| Suspend / resume | ✅ works, but it's a shallow sleep — see below |

## What doesn't

| | |
|-|-|
| **Mobile data / calls / SMS** | ❌ SIM is read and the control plane comes up, but the radio never goes online. Known to be a software problem — the same hardware registers fine under LineageOS. |
| **GPS** | ❌ not started. |
| Deep sleep / good battery life | ⚠️ suspend works but only saves ~20% versus idling awake, because the SoC never reaches its real low-power states. Under active investigation. |
| Video **encode** | ❌ needs CVP support. |
| Headphone jack detection | ❌ (headphones work, they're just not auto-detected.) |
| Magnetometer, gyroscope | ⚠️ readable, but nothing in the desktop consumes them. |

---

## Installing it

### You need

- A **Pixel 4a (sunfish)** with an **unlocked bootloader**
  (`fastboot flashing unlock` — this wipes the device).
- A Linux host with `fastboot`, `debos` (or Docker/podman to run it), `abootimg`,
  and ~20 GB free.
- A USB-C cable, ideally plugged into a **direct** port rather than a hub.
- **Firmware from your own phone** — see the next section. We cannot ship it.

### Step 1 — Get the vendor firmware off your own device

Some hardware only works with proprietary Qualcomm/Google/Cirrus firmware, which this
repo does not contain.

**The easy path:** almost all of it is already published by the SM7150 community as
[`sm7150-mainline/firmware-google-sunfish`](https://github.com/sm7150-mainline/firmware-google-sunfish)
(also packaged for postmarketOS as
[`firmware-google-sunfish`](https://pkgs.postmarketos.org/package/master/postmarketos/aarch64/firmware-google-sunfish)).
That covers the DSP, modem, WiFi, Bluetooth, video and audio-calibration blobs — the
`lib/firmware/` and `usr/share/qcom/` trees drop straight into the rootfs:

```
lib/firmware/qcom/sm7150/google/sunfish/   adsp.mbn cdsp.mbn venus.mbn modem.mbn
                                           wlanmdsp.mbn ipa_fws.mbn a615_zap.mbn
                                           adspr.jsn adsps.jsn adspua.jsn
                                           cdspr.jsn modemr.jsn modemuw.jsn
lib/firmware/qca/                          crbtfw01.tlv crnv01.bin      # Bluetooth
usr/share/qcom/sm7150/Google/sunfish/      ACDB audio calibration + ADSP modules
```

**The one exception — you must supply this yourself.** The Cirrus speaker-protection
firmware is *not* in that repo, because it's Cirrus DSP code plus Google's per-device
tuning. Copy it off your own phone (or a factory image). It is **optional**: without it
audio still works, just quieter, because the amplifier runs without its protection DSP.

```
/lib/firmware/cirrus/
    cs35l41-dsp1-spk-prot.wmfw           cs35l41-dsp1-spk-prot.bin
    cs35l41-dsp1-spk-prot-google-sunfish.wmfw
    cs35l41-dsp1-spk-prot-google-sunfish-spk.bin
    cs35l41-dsp1-spk-prot-google-sunfish-ear.bin
```

WiFi also needs `ath10k` firmware for WCN3990 with `variant=google_sunfish`; that part
comes from `linux-firmware`, which *is* redistributable.

The "Binary build inputs" section of [`docs/internals.md`](docs/internals.md) lists the
remaining non-source inputs `patch.sh` expects (`qbootctl` and its musl loader from a
postmarketOS rootfs, the ath10k files, and an optional `ssh-authorized-keys` for
headless bringup).

### Step 2 — Build the kernel

Like the vendor firmware, the built kernel is **not** committed here — it's stale
within a couple of weeks. Build it yourself and populate the overlay.

Check out **`sunfish-venus-v7.2`** (see [Kernel source](#kernel-source) above) and build
it with `ARCH=arm64` and an aarch64 cross toolchain, then drop the outputs into
`recipe/devices/sm7150/overlay-google-sunfish/`:

```
boot/vmlinuz-$KVER
usr/lib/modules/$KVER/                                     # from make modules_install
usr/lib/linux-image-$KVER/qcom/sm7150-google-sunfish.dtb
```

The debos `overlay` action in `recipe/devices/sm7150/packages-base.yaml` injects these
raw artifacts into the rootfs, and `install-kernel.sh` then runs `depmod` and builds the
initramfs for them. (`kernel-config-*.txt` is the exact config used.)

### Step 3 — Build the image

The rootfs is built with the **debos** recipe in `recipe/`, then `work/patch.sh`
injects the mainline kernel, initramfs hooks and device fixes and repacks everything
into a sparse `userdata-nested.simg`.

### Step 4 — Flash

The stock bootloader **cannot** boot a mainline kernel directly, so the chain is
`ABL → U-Boot → systemd-boot → kernel`. U-Boot goes on the `boot` partition, in **both**
slots.

The image we boot came from **[Tauchgang](https://gitlab.postmarketos.org/tauchgang)**,
postmarketOS's initiative for stable U-Boot releases on Linux Mobile devices — a small
patchset kept deliberately close to upstream U-Boot. Its porting guide lives in
`tauchgang-ci/doc/porting.md`, and there's a `#tauchgang:postmarketos.org` Matrix room.

Upstream U-Boot builds Qualcomm phones generically these days (no per-device defconfig):

```sh
make CROSS_COMPILE=aarch64-linux-gnu- O=.output qcom_defconfig qcom-phone.config
```

Linaro also publishes Qualcomm U-Boot releases at
[git.codelinaro.org/linaro/qcomlt/u-boot](https://git.codelinaro.org/linaro/qcomlt/u-boot/-/releases).

> **What we can verify about our image:** it is `u-boot-nodtb.bin` with a
> `google,sunfish` / `qcom,sm7150` device tree appended, packaged as an **Android boot
> image header v0, page size 4096**. We have *not* re-derived the exact build and
> packaging steps for sunfish from scratch, so if you do, please contribute them.
>
> Flash it **exactly as built**. Repackaging the same U-Boot into a v2 boot-image header
> produced a non-booting device for us — header v0 or nothing.

```sh
fastboot flash boot_a u-boot.img
fastboot flash boot_b u-boot.img
fastboot erase dtbo                        # skipping this hangs at the Google logo
fastboot flash userdata userdata-nested.simg
fastboot --set-active=a                    # reset the A/B retry counter
fastboot reboot
```

To get into the bootloader: hold **Power + Volume-Down**.

### First boot

Give it about **90 seconds** to reach a login. The device also brings up USB
networking, so from the host:

```sh
ssh mobian@172.16.42.1      # password: 147147
```

---

## If something goes wrong

| Symptom | Cause |
|-|-|
| Boots straight into fastboot | The `boot` partition doesn't contain a valid U-Boot. Reflash it. |
| Hangs on the Google logo | You skipped `fastboot erase dtbo`. |
| Ping works but SSH is "connection refused" for minutes | Filesystem check after an unclean shutdown, or the first-boot race. Wait, then power-cycle once. **This is not a brick — don't reflash.** |
| No WiFi or Bluetooth after reflashing | Vendor firmware was wiped. Redo Step 1. |
| Bluetooth won't power on | Check for an rfkill soft block: `cat /sys/class/rfkill/*/soft`. |
| Wrong or garish screen colours | Intermittent display-init glitch. Reboot. |
| Very slow boot (many minutes) | Usually a debug kernel cmdline (verbose logging / serial console). |

---

## Contributing / help wanted

The most valuable things anyone could pick up right now:

1. **Mobile data.** The biggest gap, and known to be software-only.
2. **Deep sleep.** Suspend works, but the SoC never enters its low-power states. The
   blocker is localised: the RPMh sleep set keeps the crystal oscillator voted on, and
   the device resets during the device-suspend phase if QUP wrapper 0 is allowed to
   fully idle. `docs/internals.md` has the details.
3. **Camera**, **GPS**, video **encode**.

If you have another SM7150 device, a few findings here are probably relevant to you
too and are cheap to check — in particular, a single unbound driver can leave every
voltage rail pinned at its maximum corner via `sync_state()`:

```sh
dmesg | grep "sync_state() pending"
cat /sys/devices/platform/soc@0/*/state_synced
```

Issues and patches welcome. Kernel patches destined for upstream should go to the
usual mailing lists; device-tree and board changes are better routed through
`sm7150-mainline`.

## Credits

- Kernel: the [sm7150-mainline](https://github.com/sm7150-mainline/linux) fork.
- Boot approach adapted from the postmarketOS sdm845/sm7150 work
  (U-Boot + systemd-boot, nested rootfs inside `userdata`).
- Userspace DSP/sensor plumbing builds on
  [hexagonrpc](https://github.com/linux-msm/hexagonrpc) and
  [libssc](https://codeberg.org/DylanVanAssche/libssc).
- Device drivers (drv2624 haptics, stmfts touch, `qcom_qg` fuel gauge) reverse-engineered
  for this device.

Technical background and the debugging history live in
[`docs/internals.md`](docs/internals.md).
