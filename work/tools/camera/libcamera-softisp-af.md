# Contrast-detect autofocus for libcamera `simple` + software ISP (0.7.2 port)

Ports the out-of-tree contrast-detect AF from GitLab `tui/libcamera`
(`millicam_af_6`) onto our patched libcamera **0.7.2** tree. Deliverable patch:
`libcamera-softisp-af.patch` (applies on top of
`libcamera-agc-vblank-and-dpc.patch`). Compile-verified natively on x86-64.

## Upstream commits carried

Applied in order, adapted to 0.7.2 APIs and to our local changes:

| commit | subject | carried? |
|-|-|-|
| `84d8dbba` | software_isp: Add brightness control | yes |
| `b4fe4244` | software_isp: Add AGC disable control | yes |
| `5f010580` | software_isp: Add manual exposure control | yes |
| `4ba05039` | software_isp: Add focus control (core) | yes |
| `684ec195` | software_isp: Add autofocus (core) | yes |
| `4da3fec3` | AF: detect focus loss | yes |
| `da42da56` | af: less phases, center window, status | yes (mcam hunks dropped) |
| `3ac05187` | af: slower focus, green metric | yes |
| `4312a90e` | af: reindent | yes |
| `8064c4f3` | libipa fixedpoint: move float conv inline | **dropped** |

`8064c4f3` was dropped: no AF/AGC patch references `fixedpoint`, so it is
neither a prerequisite nor needed. All `src/apps/mcam/*` hunks were dropped —
that demo app does not exist in 0.7.2.

## Conflicts resolved against 0.7.2 (the branch was based on a newer/other base)

- **`YamlObject` → `ValueNode`.** In 0.7.2 the simple-IPA algorithm base is
  `init(IPAContext&, const ValueNode&)`. The branch used `YamlObject`; kept as
  `ValueNode` in `af.{h,cpp}` and `agc.{h,cpp}` (build error without this).
- **`SwStatsCpu` stats functions.** 0.7.2 already has a *newer* multi-buffer
  design than the branch base: line functions take `(const uint8_t *src[],
  SwIspStats &stats)` and write to per-buffer `stats_[i]`, which
  `finishFrame()` reduces into `sharedStats_`. The branch's `(const uint8_t
  *src[])` → `(..., int y)` change was re-applied as `(..., SwIspStats &stats,
  int y)` across **all 8** line variants (our tree has extra 10P/12P/GBRG
  variants the branch lacked). The `y` argument is threaded through the two
  header call sites and `processBayerFrame2`.
- **sharpness must reach the IPA.** Because our tree reduces per-buffer stats
  in `finishFrame()`, `sharedStats_->sharpness` is now zeroed and summed there
  (and zeroed per-buffer in `startFrame()`). Without this the IPA would read a
  stale/garbage sharpness. This is the key coherence fix over a literal replay.
- **sharpness macro.** The branch left write-only `r0/r1/b0/b1` shift
  registers that trip `-Wunused-but-set-variable` under our `werror` build. Its
  final metric only uses the green channel, so I kept just `g0/g1` and the
  identical computation `sharpness += (g-g0)*(g-g0)` (skip-one-pixel), gated to
  the center-of-frame cell, normalized `1000*sharpness/sumG`. Byte-identical
  numerics, minus the dead registers. Added a `if (sumG)` guard to the
  normalization to avoid a SIGFPE on an all-black line (the branch's only
  divide-by-zero hazard).
- **AGC merge.** Our VBLANK-extending AGC is preserved verbatim. The
  brightness/AE-disable/manual-exposure controls were merged *around* it:
  `exposureMSV /= brightness` at the top of `updateExposure()`; the
  `ae_enabled`/`exposure_value` gate at the top of `process()` returns before
  our VBLANK path runs, so manual mode simply bypasses the whole AGC/VBLANK
  loop. `init()/configure()/queueRequest()` were added to `Agc`.
- **`setSensorControls` signal widened** `Signal<const ControlList&>` →
  `Signal<const ControlList&, const ControlList&>` through `soft.mojom`,
  `software_isp.{h,cpp}` and the `simple` pipeline handler.

## Controls exposed (visible in `cam --list-controls`)

`ctrlMap` is exported as the IPA's `ipaControls` (`soft_simple.cpp:182`), so
these appear in the camera's `ControlInfoMap`:

All standard AF controls used below exist in **0.7.2** core control IDs
(`control_ids_core.yaml`, not draft-namespaced): `AfMode`
(`Manual`/`Auto`/`Continuous`), `AfState` (`Idle`/`Scanning`/`Focused`/
`Failed`), `AfTrigger` (`Start`/`Cancel`).

| control | type / range | default | meaning |
|-|-|-|-|
| `AfMode` | enum {Manual, Auto, Continuous} | **Continuous** | focus policy (see below) |
| `AfTrigger` | enum {Start=0, Cancel=1} | Start | `Start` begins a scan (Auto/Continuous only); `Cancel` aborts and leaves the lens put |
| `LensPosition` | float 0..100 | 50 | manual focus / override; authoritative in Manual, a transient nudge in Auto/Continuous |
| `AeEnable` | bool | true | AGC on/off |
| `Brightness` | float 0..2 | 1 | AE target multiplier |
| `ExposureValue` | float 0..0.5 | 0.5 | manual exposure fraction when `AeEnable=false` |

Per-frame **metadata** reported by the AF algorithm: `AfState` (the real
enum, mapped from the algorithm's phase) and `LensPosition` (current position
0..100).

### AfMode behaviour

- **Manual** — the algorithm never moves the lens; `LensPosition` is honoured
  directly. `AfState` is always `Idle`.
- **Auto** — scans only on `AfTrigger = Start`; no automatic re-scan. `AfState`
  goes `Idle → Scanning → Focused|Failed`.
- **Continuous** — scans on trigger *and* re-scans automatically when focus is
  lost (the `4da3fec3` focus-loss detector, now gated to this mode only). The
  first frame's focus-loss check (`sharpness_max == 0`) auto-initiates the
  initial scan, matching the `AfModeContinuous` "immediately initiate" contract.

**Default = Continuous:** a phone camera application expects the preview to
stay focused without issuing an explicit trigger, so the camera is usable
out of the box.

`AfState` reports `Failed` (not `Focused`) when a scan ends without any
sharpness gradient (`sharpness_max == 0`, e.g. a flat or dark scene), so
success is never reported unconditionally. This is a weak confidence test; a
peak-vs-plateau ratio would be stronger (noted in-code).

### Fixed vs. carried defects

- **`AfTrigger` semantics corrected:** `Start` (0) begins a scan, `Cancel` (1)
  aborts it. The branch's inverted `== 1`-means-start is gone.
- **`AfState` used for status** instead of the branch's abuse of `AeState`
  (which corrupted an exposure-convergence control apps legitimately read).
- **`ExposureValue` default fixed** from `1.0` (outside its advertised
  `0..0.5` range) to `0.5`.
- **Still carried (documented, not fixed):** `LensPosition → VCM` omits the
  `+ focus_min` offset (harmless when `focus_min == 0`; see tunables).

## AF algorithm tunables (`af.cpp` / `ipa_context.h` `focus` struct)

- **Sweep step:** starts at `2` (`restart()`), `step /= 10` per phase. Since
  the phase loop continues only while `step > 0.2`, in practice this is a
  single coarse pass at step 2 over 0..100, then it locks at the best position
  (the nominal fine phase's `0.2` fails the `> 0.2` test). Search window for a
  would-be next phase is best ± `step*spread`, `spread = 5`.
- **Settle skip:** `skip = 10` frames after any large lens move (also on
  manual `LensPosition` change and `restart`); decremented once per frame,
  stats ignored until zero.
- **Focus-lost re-trigger (Continuous mode only):** while locked, if
  `|sharpness − sharpness_max| > 0.3 * sharpness_max` (30%), it restarts a
  sweep. Disabled in Auto and Manual.
- **Sharpness window:** the center cell of a 5×5 grid, i.e.
  `(5*x)/window_.width == 3 && (5*y)/window_.height == 3`. Metric is the
  green-channel skip-one-pixel first difference squared, summed over that cell
  and normalized `1000 * Σ(g−g0)² / Σg` per line.
- **LensPosition → VCM:** `focus_pos/100 * (focus_max − focus_min)` written to
  `V4L2_CID_FOCUS_ABSOLUTE`. (Omits the `+ focus_min` offset — carried bug,
  harmless when `focus_min == 0`.)

## What must exist on the kernel side (nothing here works without it)

AF is a no-op until the media graph provides a lens actuator:

- A **`MEDIA_ENT_F_LENS` V4L2 sub-device** — a VCM driver (dw9714 / ak7375 /
  dw976x-class) exposing `V4L2_CID_FOCUS_ABSOLUTE`.
- That sub-device linked to the sensor as an **ancillary entity** via the
  `lens-focus` fwnode/DT phandle (parsed by
  `v4l2_async_register_subdev_sensor()`), so libcamera's
  `CameraSensor::focusLens()` returns non-null.

Without it: `sensor_->focusLens()` is null → `configInfo.lensControls` is empty
→ IPA logs "No camera lens found! Focus control disabled", `focus_min =
focus_max = 0`, and `setFocusPosition()` is never called (the AF loop still
runs but drives nothing). The Pixel 4a DT today has **no** VCM node and no
`lens-focus` property for `imx363`/`imx355` (research doc §4), so this port is
the software half only — the actuator bring-up is the remaining blocker.

## Build verification

```
meson setup bld -Dpipelines=simple -Dipas=simple -Dtest=false \
  -Ddocumentation=disabled -Dgstreamer=disabled -Dcam=enabled \
  -Dqcam=disabled -Dlc-compliance=disabled -Dpycamera=disabled
ninja -C bld    # clean, 26/26 targets, incl. algorithms_af.cpp.o,
                # ipa_soft_simple.so, libcamera.so.0.7.2
```

Native x86-64 (Manjaro, gcc, `-Werror`). Runtime AF is **not** testable: no VCM
kernel driver exists yet.
