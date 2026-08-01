# Porting internals (sunfish / SM7150)

Background for people working *on* the port. For installation, see the
[README](../README.md).

---

## Boot architecture

The Pixel 4a's stock unlocked bootloader (ABL) cannot boot a raw mainline kernel
boot.img directly, so the chain mirrors the postmarketOS sdm845/sm7150 approach:

```
ABL (stock, unlocked)
  -> U-Boot "Tauchgang" (qcom mainline U-Boot, on the `boot` partition)
     -> systemd-boot (EFI)
        -> mainline kernel (vmlinuz.efi) + initrd + sm7150-google-sunfish.dtb
           -> initramfs (local-top hook, see work/scripts/subpartitions)
              -> switch_root -> Mobian (Debian 13) systemd
```

### Nested GPT inside `userdata`
The root filesystem is **not** a normal partition. A small GPT disk image
(`FAT32 ESP` holding systemd-boot + kernel + initrd + dtb, plus an `ext4` root) is
flashed **inside** the Android `userdata` partition. The nested image is created on
4096-byte logical sectors (`deviceinfo_rootfs_image_sector_size=4096`).

### Root discovery (the tricky part)
The initramfs exposes the nested root via an **offset loop device**:

```sh
losetup -o 537919488 --show -f /dev/disk/by-partlabel/userdata
# 537919488 = root partition start sector (131328) * 4096
```

> ⚠️ `losetup --sector-size 4096 -P` **panics/stalls the kernel** on this device.
> The plain offset loop (no `-P`, no `--sector-size`) is what works. The root is then
> mounted by `root=UUID=<fs-uuid>` (a bare-fs loop has no PARTLABEL/PARTUUID).

---

## Key findings & fixes

### 1. The ~13 s reboot was the **IPA driver**, not the watchdog
The device rebooted ~13 s into Mobian, in a loop. After a long detour through the
qcom watchdog, a **live USB-serial console** (`console=ttyGS0` → host `/dev/ttyACM0`)
showed the last kernel message on **every** cycle was:

```
ipa 1e40000.ipa: IPA driver setup completed successfully
<instant silent SoC reset — no panic, no watchdog msg, no "reboot:">
```

The reset is a **cold/PMIC-level reset** that clears DRAM (so `ramoops`/`pstore`
comes up empty next boot — pstore capture is useless for this fault). IPA (IP
Accelerator, network offload) is not needed to boot, so the fix is to disable it:

```
# kernel cmdline:           module_blacklist=ipa
# /etc/modprobe.d/blacklist-ipa.conf:
blacklist ipa
install ipa /bin/true
```

`CONFIG_QCOM_IPA=m`, so no kernel rebuild is required.

### 2. Watchdog: let the kernel core feed it
The bootloader arms the qcom APSS watchdog. The kernel watchdog **core** auto-pings a
HW-running watchdog **forever** (`CONFIG_WATCHDOG_OPEN_TIMEOUT=0`) — but **only until
userspace opens `/dev/watchdog`**. systemd's `RuntimeWatchdogSec` opens it then fails
to keep it alive. The robust answer is therefore to **never open it from userspace**:

- initramfs: `modprobe qcom_wdt` (so the core adopts + auto-pings it) — do **not** kick it
- Mobian: `RuntimeWatchdogSec=0` (don't let systemd take the device)
- cmdline: `watchdog.open_timeout=0`

(This held the device through initramfs and early Mobian; it was never the cause of the
~13 s reboot — that was IPA.)

### 3. Build & flash
- The base rootfs is built with the **debos** recipe in `recipe/` (Mobian
  mobian-recipes + an sm7150 / google-sunfish device target).
- `work/patch.sh` injects the mainline kernel, the initramfs hooks
  (`work/hooks/subpartitions`, `work/scripts/subpartitions`), the IPA blacklist, the
  watchdog config, and the systemd-boot cmdline into the nested image, then repacks it
  to a sparse `userdata-nested.simg`.
- Flash:
  ```sh
  fastboot flash userdata userdata-nested.simg
  fastboot --set-active=a     # reset A/B retry count
  fastboot reboot
  ```
- To reach ABL fastboot for flashing: hold **Power + Volume-Down**. (Our debug USB
  gadget enumerates as `18d1:d001` with **no** fastboot function, so `fastboot` cannot
  talk to it while the device is cycling.)

---

## Debug capture pipeline (no serial cable)

The initramfs brings up a **USB gadget** (NCM net `172.16.42.1` + ACM serial) and the
host runs:

- `work/host-capture.sh` — keeps `enp0s20f0u1` at `172.16.42.2` and listens on
  `:9999` for the initramfs diag push.
- Live kernel console: add `console=ttyGS0,115200n8` to the cmdline (needs
  `CONFIG_U_SERIAL_CONSOLE=y`) and `cat /dev/ttyACM0` on the host (stop ModemManager
  first). This streams the kernel log **through the reboot** — it's what caught IPA.

These are debug aids; strip them (`console=ttyGS0`, verbose `loglevel`, the diag push)
for a clean daily-driver image.

---

## Layout

```
work/
  patch.sh              # inject kernel + hooks + fixes into the nested image, repack
  hooks/subpartitions   # initramfs build hook (bundles real util-linux losetup)
  scripts/subpartitions # initramfs local-top: wdt, USB gadget, offset-loop root, diag
  host-capture.sh       # host-side USB-net listener for the diag push
  watchdog-kick*        # (legacy) OpenRC-style kicker, kept for reference
recipe/                 # Mobian debos recipe + sm7150 device target (no binaries)
kernel-config-*.txt     # the mainline kernel .config used for the build
```

### Binary build inputs (not in repo — gitignored)
`patch.sh` expects these next to it in `work/`; they are device/distro blobs or build
outputs, not source. The first two are overridable by environment variable and are
documented with the rest of the build knobs in the README ("Step 3 — Build the image");
`patch.sh` preflights all of them before doing any work.
- the **kernel** `vmlinuz.efi` (zboot — an uncompressed `Image` will not boot) and
  `sm7150-google-sunfish.dtb`, from branch `sunfish-venus-v7.2`. Overridable as
  `KIMG` / `KDTB`; both default to inside `KSRC`.
- **`hexagonrpcd`** + `libhexagonrpc.so.0.4`, built from `linux-msm/hexagonrpc` with
  `docs/hexagonrpc-series/` applied. Overridable as `HEXRPCD` / `HEXRPCLIB`, defaulting to
  `work/hexagonrpc/bin/` and `work/hexagonrpc/lib/`. Missing these costs you every sensor.
- `qbootctl` + `ld-musl-aarch64.so.1` — the pmOS aarch64 (musl) `qbootctl` and its
  loader, bundled into the rootfs for the A/B `mark-boot-successful` oneshot. musl's
  loader path doesn't collide with Debian's glibc, so the binary runs unmodified.
  (Pull both from a pmOS sm7150 rootfs: `usr/bin/qbootctl`, `lib/ld-musl-aarch64.so.1`.)
- `ath10k-WCN3990-board-2.bin` + `ath10k-WCN3990-firmware-5.bin` — ath10k WCN3990
  runtime firmware copied into the rootfs. `board-2.bin` must carry
  `variant=google_sunfish`; `firmware-5.bin` is the 60-byte QCA-ATH10K API header.
- `ssh-authorized-keys` (optional) — if present, `patch.sh` apt-installs
  `openssh-server` (in the qemu-binfmt chroot), enables `ssh.service`, drops this
  file into `/home/mobian/.ssh/authorized_keys`, and adds a `NOPASSWD:ALL` sudoers
  rule for `mobian`. Enables key-only SSH over USB-net (172.16.42.1) for headless
  bringup. Dev-device convenience — drop the sudoers line for anything shipped.

## Credits / lineage
- Kernel: [sm7150-mainline](https://github.com/sm7150-mainline/linux) fork.
- Boot approach adapted from the postmarketOS sdm845/sm7150 work (U-Boot + systemd-boot,
  nested rootfs in `userdata`).
- Drivers (drv2624 haptics, stmfts touch, qcom_qg) reverse-engineered for this device.
