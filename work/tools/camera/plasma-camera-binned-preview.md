# plasma-camera: preview on the binned sensor mode

`plasma-camera-binned-preview.patch` applies to **plasma-camera 26.04.1-1** (Debian forky).
Verified on sunfish, kernel 7.1.0-sm7150+, libcamera 0.7.2-1, 2026-07-30.

## Why

Mainline camss on SM7150 exposes only the RDI path (raw Bayer, no hardware
demosaic), so libcamera 0.7.2 debayers on the CPU. plasma-camera asks libcamera
for a single `StreamRole::Viewfinder` stream, and libcamera's simple pipeline
handler answers with the sensor's *largest* mode — 4032x3024 on the rear imx363.
Software-ISP'ing 12 MP every frame is what heats the SoC.

The same single stream is also what a photo is taken from (`Worker::capture()`
just keeps 5 preview frames, and `processCaptureImage()` saves `frames.head()`),
so simply capping the stream size would cap photos too. The sensor mode is
shared, so a cheap preview and a 12 MP still cannot coexist — the config has to
be switched around the shutter. Note this also means the "role-aware default in
libcamera's simple pipeline handler" idea does *not* help here: plasma-camera
asks for the Viewfinder role for its stills as well.

The patch therefore:

- asks for a 1440x1080 preview stream, which makes libcamera pick the imx363's
  2x2-binned 2016x1512 mode (kernel commit `b209f9859cef`);
- on `capture()`, restarts the view finder with the untouched (max-resolution)
  config, drops 6 frames so the AGC settles, keeps the 5 capture frames, then
  restarts back on the preview config.

Restart reuses the existing `stopViewFinder()`/`startViewFinder()` pair (the same
path the front/rear camera switch already uses); `stopViewFinder()` releases the
camera, so `reconfigure()` re-`acquire()`s it.

Belongs upstream (plasma-camera), together with libcamera's own
`\todo Implement a better way` on the simple pipeline handler's default size.

## Why 1440x1080 and not the native 2016x1512

Measured both, rear camera, same scene:

| requested preview size | sensor mode libcamera picked (`/dev/video0`) | process CPU |
|-|-|-|
| `Size(1440, 1080)` | 2016x1512 binned, 2528 B/line | **63%** |
| `Size(2016, 1512)` | 4032x3024 full, 5040 B/line | 120% |
| stock (sensor max) | 4032x3024 full, 5040 B/line | 186-190% |

Counter-intuitive but reproducible: asking for *exactly* the binned mode size
makes the simple pipeline handler select the **full** sensor mode and downscale
in software, which is the expensive thing. Asking for a smaller-than-any-mode
size is what makes it drop to the binned mode. So 1440x1080 wins on both counts
(right sensor mode *and* fewer output pixels to blit); do not "tidy" it up to
2016x1512.

## Measured result (rear imx363)

- `/dev/video0` while previewing: 2016x1512, 2528 B/line, 3 822 336 B
  (was 4032x3024, 5040, 15 240 960).
- CPU: 186-190% -> 62-64% (29 threads either way).
- Thermals, app streaming, sampled every 30 s:
  - before: 51 C idle -> 76-82 C @30s -> 85/88 C @120s, **still climbing**
  - after: 47 C idle -> 53-54 C @30s -> **flat 54-56 C out to 240 s**
- Front imx355 is not regressed: it also drops to its binned 1640x1232 mode,
  174% -> 136% CPU. (Front stays expensive because that mode runs at a much
  higher frame rate; unrelated to this patch.)
- Photo: 3024x4024 saved (the app rotates 90 deg in software), i.e. 4024x3024
  out of the sensor's 4032x3024 mode — libcamera's CPU debayer drops 8 columns.
  The still path is byte-identical to stock, so stock saves the same size.
  12.2 MP, definitely not the 2016x1512 preview size.
- Shutter lag, 5 consecutive shots: **1.36-1.56 s** to the file appearing,
  1.99-2.19 s until it is fully written. That is ~11 full-resolution frames
  (6 AGC settle + 5 kept) plus one camera stop/configure/start. Stock is
  ~0.5 s (5 frames, no restart), so the patch costs about 1 s of shutter lag.
  Slower, but the preview no longer cooks the phone.
- Stability: 5 shots in a row all produced a file and the preview came back at
  2016x1512 every time; a rapid double tap produced one photo and did not hang
  (the second tap lands while `m_stillConfig` is already true, so it only
  restarts the frame collection). No deadlock from calling `stop()` out of the
  frame-handling path.

### Known caveat (not fixed)

`m_stillSkipFrames` is decremented in `processRequestDataAndEmit()`, which can
also run for invocations that were already queued before the reconfigure and
find an empty done-queue. So the AGC settle can be slightly shorter than 6 real
frames. Photos came out correctly exposed (mean luma ~135 on a normal indoor
scene), so it was left alone; the fix would be to make `processRequestData()`
return whether it consumed a buffer.

## Rebuild (on device)

    sudo apt install -t forky dpkg-dev build-essential
    # deb-src for forky must be enabled:
    #   echo 'deb-src http://deb.debian.org/debian forky main' | sudo tee /etc/apt/sources.list.d/src-forky.list && sudo apt update
    mkdir -p ~/src && cd ~/src
    apt-get source plasma-camera
    sudo apt-get build-dep -y -t forky plasma-camera     # -t forky is required, trixie qt6-*-dev conflicts
    cd plasma-camera-26.04.1
    patch -p1 < .../plasma-camera-binned-preview.patch
    DEB_BUILD_OPTIONS=parallel=3 dpkg-buildpackage -b -us -uc
    sudo apt install ../plasma-camera_26.04.1-1_arm64.deb

Two traps hit while doing this:

- **Cap the parallelism.** `parallel=6` on 8 cores with no swap took the phone
  down mid-build (abrupt reset, no oops in the previous boot's log).
  `parallel=3` is fine and the app builds in a couple of minutes.
- `dpkg-buildpackage -nc` (incremental) **skips `dh_auto_build` entirely**
  because `debian/debhelper-build-stamp` already exists — you get a repackaged
  *old* binary with no warning. `rm -f debian/debhelper-build-stamp` first.

## What the shippable artifact is

The rebuilt `plasma-camera_26.04.1-1_arm64.deb` (on the phone at
`~mobian/src/`, installed `/usr/bin/plasma-camera` md5
`f9f0836a0b527d1e585b2067f26cd11d`; the stock binary is
`17565122580900f2f105058adfd945bc`).

It carries the **same version string as the archive package**, so a plain
`apt upgrade` will silently replace it with the stock build. Baking this into
the image therefore needs one of:

- apply the patch and rebuild during image build, and `apt-mark hold
  plasma-camera` (or bump the version to `26.04.1-1+sunfish1` so apt keeps it), or
- ship the prebuilt `.deb` in the image and hold the package.

Either way the hold/version bump is the part that must not be forgotten. Not
wired into `patch.sh` here — deliberately left for the maintainer to decide.
