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
  the center-of-frame cell. Added a guard to avoid a SIGFPE on an all-black
  line (the branch's only divide-by-zero hazard).
- **AGC merge.** Our VBLANK-extending AGC is preserved verbatim. The
  brightness/AE-disable/manual-exposure controls were merged *around* it:
  `exposureMSV /= brightness` at the top of `updateExposure()`; the
  `ae_enabled`/`exposure_value` gate at the top of `process()` returns before
  our VBLANK path runs, so manual mode simply bypasses the whole AGC/VBLANK
  loop. `init()/configure()/queueRequest()` were added to `Agc`.
- **`setSensorControls` signal widened** `Signal<const ControlList&>` →
  `Signal<const ControlList&, const ControlList&>` through `soft.mojom`,
  `software_isp.{h,cpp}` and the `simple` pipeline handler.

## P1 fix — luma-invariant sharpness metric (`swstats_cpu.cpp`)

The carried metric normalized `1000 * Σ(Δg)² / Σg`: the numerator scales as
luma² but the divisor `Σg` only as luma¹, so the whole metric scaled with
luma. An AGC/exposure drift then read as a sharpness change (destabilizing the
focus-loss re-scan and biasing peak selection). Fixed by normalizing with the
center-cell green **mean squared** instead:

    stats.sharpness += 1000000 * Σ(Δg)² / meanGc²      (meanGc = ΣgC / nC)

where `ΣgC`/`nC` are accumulated over the same center 5×5 cell as `Σ(Δg)²`.
This makes the metric luma-invariant (matching the offline `afanalyse.py`,
which divides by mean²). The `1e6` factor keeps the integer ratio in a useful
range; absolute scale is irrelevant since the AF loop only compares sharpness
across positions. Both divisor terms now scale as luma², so exposure cancels.

**Verified** offline by replaying both formulas on a real frame scaled ×2
(simulating +1 stop): old metric ratio **2.00×** (scales with luma — the bug),
new metric ratio **1.00×** (luma-invariant — fixed). Build-verified under
`-Werror` on aarch64; deployed; AF pipeline healthy (lens found, sweep
triggers, no regression). The macros are shared by all 8 Bayer line variants,
so the one edit covers every format.

## P2/P4/P5/P6/P7 — search, settle, window, monitor, confidence

Measured on a lit textured target (CD rack, 10-30 cm) with a clean reference
built from raw camss RDI captures (`rawsweep.sh`/`rawanalyse.py`) — libcamera's
own AF corrupts any focus sweep, so the reference must bypass it.

Reference (raw, luma²-normalised VoL, AF window): focus curve rises 0.11→**0.31**
at fabs≈3072 then falls, 2.56× peak/trough — a real, smooth optimum.

- **P4 coarse-to-fine + parabola.** `step /= 10` (fine phase never ran) → `/= 4`
  so a real fine pass runs (verified live: coarse step 2 → fine step 0.5, 102
  steps), plus parabolic interpolation through the best three fine samples for a
  sub-step peak. Neighbours tracked in the sweep, falls back to the best sample.
- **P5 per-step settle.** Measured: the closed-loop VCM settles in **under one
  frame** (a 3900→3100 jump reads the settled value on frame 0), so a 2-frame
  per-step skip is ample; frames during motion are discarded.
- **P2 monitor/hysteresis.** Replaced the single-frame `|Δ|>0.3·max` re-scan
  trigger with a rolling baseline (EMA) + `trigger_threshold` 40 % + `sensitivity`
  10 consecutive frames. Unit-tested: ±15 % noise over 300 frames → 0 re-scans;
  a sustained 60 % drop → re-scan at frame 29. Live 3-min static hold → 0
  spurious re-scans.
- **P7 confidence.** `Focused` now requires peak > 1.5× the sweep's defocus
  floor (`sharpness_min`), not `sharpness_max>0`. Live: 2.13× peak/floor →
  Focused; a flat scene (≈1×) → Failed.
- **P6 window.** Widened from the single `[0.6,0.8)` cell to the central 3×3
  (`[0.2,0.8)`) so off-centre subjects still drive focus.

### SOLVED — the ~500-code shortfall was a byte/pixel unit bug in the stats window

The residual "converges to fabs≈2590 while the optimum is ≈3072" was **not** the
AF search, **not** attribution/latency, and **not** the sharpness formula. It was
the AF stats *window* landing on the wrong part of the frame.

Proof (decisive experiment, `swstats_cpu.cpp:255` instrumented to log the online
`stats->sharpness` vs the commanded position, lens parked in `AfModeManual`):

- online metric, measured **statically** with the lens parked, peaks at
  **fabs≈2560** — so it is a bad *statistic*, not a lens-attribution lag (a
  parked lens has no dynamics);
- on the **same** frames, the sharpness of the actual output image over the
  *same* window peaks at ≈2944 — the statistic disagrees with its own imagery.

Root cause (`swstats_cpu.cpp`, `SWSTATS_ACCUMULATE_LINE_STATS`): the horizontal
window test `(5*x)/window_.width` divides the loop index `x` by the **pixel**
width — but for CSI2-packed inputs (the live path is
`2016x1512-RGGB-10-CSI2P`, sampler `statsGBRG10PLine0`) `x` counts **bytes**
(`x += 5`, `widthInBytes = width*5/4`). So the horizontal `[0.2,0.8)` gate
collapsed to roughly `[0.16,0.48)` of the frame and shifted **left of centre**,
onto nearer scene content that focuses ~250-500 codes short. The vertical gate
(`y` in lines) was unaffected — which is why the shift was purely horizontal and
looked like a constant offset.

**Fix:** gate on `xGateW`, the sample loop's actual x-extent (`window_.width`
for unpacked formats, `widthInBytes` for the four CSI2-packed samplers). One new
variable, four one-line assignments, and the divisor in the macro. The metric
formula, subsampling and normalisation are unchanged.

**Result (measured live):** the online static curve now peaks at **fabs≈2817**
(matching VoL over the correct centred window); Continuous AF converges at
**fabs≈2836** (6-run range 2672-2918, was ≈2590). Converged sharpness over the
reference rack crop rose from **88.3 % → 96.8 %** of the exhaustive-sweep
optimum (3072). Before/after spine text: `docs/camera/af-spine-before-after.png`
(and `af-spine-fabs{2590,2836,3072}.png`).

Note on the residual 2836 vs 3072: the scene is a tilted multi-depth rack (a
per-region focus map spans fabs 2560-3584). 3072 is the optimum of the specific
left-of-centre crop the offline `rawanalyse.py` uses; the *centred* AF window's
honest VoL optimum is ≈2816-2944. Reaching exactly 3072 would require
subject/window selection on the off-centre rack, which is a policy choice, not a
statistic bug — and the byte/pixel gate bug is almost certainly present upstream
for any CSI2-packed input using this AF stats window (worth reporting).

### P3 (kernel `>>4`) and S2 (EEPROM) — investigated, not shipped

- **P3:** the clean curve shows the used focus range spans only DAC ±128 and the
  peak plateau is ~8 DAC codes wide (broad DoF). The `>>4` mapping already
  reaches *every* DAC code in that range at finer-than-DoF resolution, so
  removing it gives **no measurable sharpness gain** on the test scene (its only
  benefit is extended macro/infinity range, untestable with a fixed subject, and
  it would need search bounds to avoid regressing mid-range AF). Not flashed.
- **S2:** the module EEPROM responds (reg 0x0010 = 0x1b90) but the `AFOffset`
  block (rel 0x14, 9 B) reads **all zeros** — blank on this unit, no calibrated
  bounds. Per the schema's lack of a CRC, trusted the measurement instead.

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
  and normalized `1e6 * Σ(g−g0)² / meanGc²` per line (luma-invariant, see the
  P1 fix section above).
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
