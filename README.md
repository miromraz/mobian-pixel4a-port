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

`sunfish-venus-v7.2` is that tree's default branch, so a plain `git clone` lands on it.
The other ~90 branches there are older topic branches and upstream snapshots — ignore them.

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
| NFC (ST54J via `nxp-nci`), incl. MIFARE Classic tag reading | ✅ no card emulation / HCE. Needs `neard` — but ⚠️ `apt install neard` **removes `wpasupplicant`**, i.e. it will take your WiFi with it. Install it deliberately, and reinstall `wpasupplicant` afterwards. `neard` also never polls until a D-Bus client asks it to. |
| Hardware video **decode** (H.264/VP8/VP9/HEVC) | ✅ MPEG-2 is masked |
| Suspend / resume | ✅ works, but it's a shallow sleep — see below |

## What doesn't

| | |
|-|-|
| **Mobile data / calls / SMS** | ❌ SIM is read and the control plane comes up, but the radio never goes online (`DeviceNotReady`, no band table). Known to be a software problem — the same hardware, same radio image registers fine under LineageOS. Every AP-side avenue we know of is now closed by test rather than by guess. |
| **GPS** | ❌ the AP-side stack is complete — the QMI LOC engine starts, streams NMEA, and gets gpsOneXTRA assistance injected — but the GNSS receiver reports 0 dB-Hz on every satellite. Same spot, same antenna, Android gets a 3.8 m fix in 39 s. So GNSS RF is dead for the same reason cellular RF is, and it is not a separate bug. |
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

### Step 2b — Build hexagonrpcd

Also not committed, and required: without it **no sensor comes up**. It serves the ADSP
root-PD and sensors-PD FastRPC endpoints that the SEE/CHRE sensor firmware needs.

Build [github.com/linux-msm/hexagonrpc](https://github.com/linux-msm/hexagonrpc) with the
three patches in [`docs/hexagonrpc-series/`](docs/hexagonrpc-series/) applied (they sit on
top of upstream `23a6964`), then place `hexagonrpcd` and `libhexagonrpc.so.0.4` where
`patch.sh` expects them — see `HEXRPCD` / `HEXRPCLIB` below.

### Step 3 — Build the image

The rootfs is built with the **debos** recipe in `recipe/`, then `work/patch.sh`
injects the mainline kernel, initramfs hooks and device fixes and repacks everything
into a sparse `userdata-nested.simg`.

`patch.sh` needs root — it loop-mounts the nested GPT — and takes every path from the
environment, so it also runs on a build box with no kernel checkout:

|var|what|default|
|-|-|-|
|`WORK`|dir holding `userdata-nested.simg` and the binary inputs|the author's laptop path — **set this**|
|`KSRC`|kernel build tree; supplies the modules, `KIMG` and `KDTB`|`…/kernel/linux-fork`|
|`MODTREE`|a pre-installed `lib/modules/$KVER` tree, used *instead of* `KSRC` (35 MB stripped vs an 11 GB build tree)|unset|
|`KIMG`|zboot `vmlinuz.efi`. An uncompressed `Image` will **not** boot here|`$KSRC/arch/arm64/boot/vmlinuz.efi`|
|`KDTB`|`sm7150-google-sunfish.dtb`|`$KSRC/arch/arm64/boot/dts/qcom/`|
|`HEXRPCD` / `HEXRPCLIB`|hexagonrpcd binary and `libhexagonrpc.so.0.4` from Step 2b|`work/hexagonrpc/{bin,lib}/`|

Produce a `MODTREE` with
`make modules_install INSTALL_MOD_PATH=<dir> INSTALL_MOD_STRIP=1`. A typical off-laptop run:

```sh
sudo WORK=/mnt/sunfish-image MODTREE=/mnt/sunfish-image/modstage \
     KIMG=/mnt/sunfish-image/kernel/vmlinuz.efi \
     KDTB=/mnt/sunfish-image/kernel/sm7150-google-sunfish.dtb \
     sh work/patch.sh
```

`patch.sh` validates all of these before it does any work, so a missing input fails in
milliseconds rather than after the whole chroot. It also asserts that `KSRC`/`MODTREE`
really carries `KVER`: a module built from a different kernel loads as "invalid module
format" and that subsystem then silently never comes up.

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
> image header v0, page size 4096**.
>
> **Build and packaging, re-derived and verified 2026-08-07** (this closes the "we have not
> re-derived it" gap that used to be here). From
> [sm7150-mainline/u-boot](https://github.com/sm7150-mainline/u-boot) — the `tauchgang`
> branch; the running binary reports its commit, e.g. `2026.01-rc3-gf8c04469e828`:
>
> ```sh
> make CROSS_COMPILE=aarch64-linux-gnu- O=.output \
>      qcom_defconfig qcom-phone.config tauchgang.config
> make CROSS_COMPILE=aarch64-linux-gnu- O=.output \
>      CONFIG_DEFAULT_DEVICE_TREE=qcom/sm7150-google-sunfish
> ```
>
> `tauchgang.config` is the third fragment and is **mandatory** — it enables `CONFIG_BLKMAP`,
> which the nested-ESP `preboot` depends on. Then package it:
>
> ```sh
> gzip -9 -c .output/u-boot-nodtb.bin > kpayload.bin        # ~1.26 MB source binary
> cat .output/dts/upstream/src/arm64/qcom/sm7150-google-sunfish.dtb >> kpayload.bin
> mkbootimg --kernel kpayload.bin --ramdisk <any ramdisk> \
>   --base 0x0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
>   --second_offset 0xf00000 --tags_offset 0x100 \
>   --pagesize 4096 --header_version 0 \
>   --os_version 13.0.0 --os_patch_level 2023-08 -o u-boot.img
> ```
>
> The control DTB is **appended after the gzip stream** (ABL does not supply it). `mkbootimg`
> zeroes `second_addr` when `second_size` is 0, so patch that 4-byte field at offset 28 back
> to `0x00f00000` afterwards — it lies outside the image `id` hash. The stock image also
> carries a ramdisk that U-Boot ignores; keeping it makes the header byte-comparable to the
> original. Verify by diffing every header field against a dump of the shipped `boot_a`:
> only `kernel_size` and `id` should differ.
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

> **If you have repartitioned for Android dual-boot**, the nested image no longer lives in
> `userdata` — flash it to the partition you created for Linux instead
> (`fastboot flash linux userdata-nested.simg`), and cap any post-install `resize2fs` at
> that partition's size rather than the whole of former `userdata`. The initramfs looks for
> partlabel `linux` first and falls back to `userdata`, so one image works either way; U-Boot's
> `preboot` does **not** fall back, so it must name the same partition (see
> [docs/internals.md](docs/internals.md)).

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
