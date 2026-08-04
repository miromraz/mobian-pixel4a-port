# Lens-shading calibration (IMX363 rear, Pixel 4a / sunfish)

The rear camera darkens toward the corners and casts green, because there is no
lens-shading correction anywhere: the module EEPROM is blank and the vendor
`lsc34` data is Titan-hardware format we can never run (see
`../../../docs/camera/vendor-calibration-schema.md`). We fix it by shooting our
own flat field and fitting a gain mesh.

Two steps: **capture** a flat field on the phone, **fit** the mesh on the host.

## 1. Shoot the flat field (on the phone)

    ./lsc-capture.sh rear 4032x3024 32 /home/mobian/lsc-field.raw --pair

What you need:

- **Surface**: a uniform matte white target filling the whole frame — a sheet
  of printer paper, a clean white wall, or a lightbox. Matte, not glossy: glare
  is not flat. No print, no texture, no seams.
- **Lighting**: soft and even. Diffuse daylight or a bounced lamp. Avoid a
  single hard light (that IS a gradient) and avoid the camera shadowing its own
  target. Get close enough that the paper fills the frame and is out of focus.
- **Exposure**: aim for ~60% of full scale. The script prints the per-channel
  mean and **refuses** the shot if any channel is clipping (near saturation) or
  the field is too dark for good SNR. A good field sits at 50-70%.

### Why `--pair` (strongly recommended)

Real calibration uses an integrating sphere. We are shooting a wall, where the
illumination itself almost always has a gradient (one side brighter). `--pair`
takes a second capture with the phone **rotated 180 degrees** and averages the
two. Rotating the phone negates any linear illumination gradient in the
sensor's own coordinates, so the average cancels it and leaves only the lens
falloff. The self-check proves this works (a synthetic gradient drops from 1.76
to 0.04 gain error). Without `--pair` your mesh will bake the room's lighting
gradient into the "lens" correction.

The script prompts you to rotate when it is ready; keep the phone aimed at the
same surface. The two raw buffers are averaged directly — the sensor reads its
Bayer pattern in native phase both times, so nothing is rotated.

### What "good" looks like

    channel  mean%full  %clipped(>=1000)
      R         58.9      0.0000
      Gr        61.2      0.0000
      Gb        61.1      0.0000
      B         63.4      0.0000

    uniformity (measured vignetting, corner/centre):
      r  max gain 1.9x = 0.93 stops
      g  max gain 1.6x = 0.68 stops
      b  max gain 1.5x = 0.58 stops
    PASS -- wrote averaged flat field to /home/mobian/lsc-field.raw

Non-zero clipping, a channel under 30%, or over 85% -> `REFUSED`, re-shoot.

## 2. Fit the mesh (on the host)

Copy the field over and run the fitter:

    scp mobian@172.16.42.1:/home/mobian/lsc-field.raw .
    ./lsc-fit.py lsc-field.raw lsc-mesh 4032x3024

It writes `lsc-mesh.yaml` (the tuning fragment), `lsc-mesh.png` (the three gain
surfaces, one per channel — eyeball for smoothness and a plausible bowl shape),
and prints the max gain and vignetting in stops per channel plus whether the
R/G/B surfaces differ (they should — that difference is the colour-shading
correction that kills the green cast).

Validate the fitter itself at any time, with no hardware:

    ./lsc-fit.py --selftest

## Mesh format and orientation

- **17 x 13 grid, RGB, float gains.** 17 nodes across the raw buffer width, 13
  across its height, row-major. Gr and Gb are combined into one G.
- **Gains are >= 1.0**, each channel normalised so its own minimum is exactly
  1.0. The mesh brightens the periphery; it never darkens. `log2(max gain)` is
  the measured vignetting in stops.
- **Orientation: sensor-native.** The mesh matches the raw Bayer buffer exactly
  as camss delivers it off RDI — no display rotation applied. The IMX363 is
  mounted a quarter turn round (`rotation = <270>` in the DT). The consumer must
  apply the mesh to the raw frame **before** it rotates for display. Apply it to
  the display-rotated image instead and the correction is rotated 90 degrees off
  the vignette it is supposed to cancel.
