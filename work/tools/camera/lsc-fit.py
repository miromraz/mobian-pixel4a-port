#!/usr/bin/env python3
"""Fit a lens-shading-correction (LSC) gain mesh from a raw flat field.

Input:  an averaged MIPI RAW10-packed SRGGB flat field (as written by
        lsc-capture.sh, same packing as capture.sh / raw2png.py).
Output: a 17x13 RGB float gain mesh as (a) a libcamera YAML fragment,
        (b) a PNG of the three gain surfaces, (c) a max-gain/stops summary.

    ./lsc-fit.py FIELD.raw OUT_PREFIX [WxH] [STRIDE] [rggb|bggr]
    ./lsc-fit.py --selftest

ORIENTATION: the mesh is emitted in SENSOR-NATIVE orientation -- exactly the
raw buffer as read off camss RDI, with NO display rotation applied. The IMX363
is mounted a quarter turn round (DT rotation=270); the consumer must apply the
mesh to the raw Bayer frame before it rotates for display. Rows of the mesh run
along the raw buffer's height, columns along its width.

Gains are >= 1.0 (brighten the periphery, never darken); each channel is
normalised so its own minimum gain is exactly 1.0. Gr and Gb are combined into
a single G, so the mesh is RGB (3 channels), which corrects colour shading as
well as luminance shading.
"""
import sys
import numpy as np

NX, NY = 17, 13          # mesh: 17 wide (raw width), 13 tall (raw height)
PEDESTAL = 64.0          # Sony 64-LSB black level, subtract before any gain maths
MAXCODE = 1023.0         # 10-bit
# v4l2 bytesperline for the modes we capture (padded past w*5//4).
STRIDES = {(4032, 3024): 5040, (2016, 1512): 2528, (1640, 1232): 2064}


def stride_for(w, h):
    return STRIDES.get((w, h), (w * 5 // 4 + 7) & ~7)


def unpack_raw10(buf, w, h, stride):
    """One RAW10-packed frame (bytes) -> HxW uint16 (10-bit codes)."""
    rows = buf[:h * stride].reshape(h, stride)[:, :w * 5 // 4]
    g = rows.reshape(h, w // 4, 5).astype(np.uint16)
    lo = g[:, :, 4]
    px = g[:, :, :4] << 2
    for i in range(4):
        px[:, :, i] |= (lo >> (2 * i)) & 3
    return px.reshape(h, w)


def pack_raw10(plane, stride):
    """HxW uint16 (10-bit) -> RAW10-packed bytes (for synthetic fields)."""
    h, w = plane.shape
    groups = w // 4
    q = plane[:, :groups * 4].reshape(h, groups, 4).astype(np.uint16)
    out = np.zeros((h, stride), np.uint8)
    for i in range(4):
        out[:, i:groups * 5:5] = (q[:, :, i] >> 2).astype(np.uint8)
    lo = ((q[:, :, 0] & 3) | ((q[:, :, 1] & 3) << 2)
          | ((q[:, :, 2] & 3) << 4) | ((q[:, :, 3] & 3) << 6))
    out[:, 4:groups * 5:5] = lo.astype(np.uint8)
    return out.tobytes()


def demux(bayer, order="rggb"):
    """HxW Bayer -> dict of the four half-res channel planes (float32)."""
    a = bayer[0::2, 0::2].astype(np.float32)
    b = bayer[0::2, 1::2].astype(np.float32)
    c = bayer[1::2, 0::2].astype(np.float32)
    d = bayer[1::2, 1::2].astype(np.float32)
    if order == "bggr":
        return {"R": d, "Gr": c, "Gb": b, "B": a}
    return {"R": a, "Gr": b, "Gb": c, "B": d}


def block_stat(plane, ny, nx, stat):
    """Reduce a plane to an ny x nx grid, one robust statistic per cell."""
    out = np.empty((ny, nx), np.float64)
    for i, rb in enumerate(np.array_split(plane, ny, axis=0)):
        for j, cb in enumerate(np.array_split(rb, nx, axis=1)):
            out[i, j] = stat(cb)
    return out


# A cell this far below the brightest one means the field was not usable (a
# cell at the pedestal would divide to an infinite gain). Real phone vignetting
# is 1-2 stops; 6 stops only happens on a bad capture, so refuse rather than
# emit a mesh that blows up in the shader. lsc-capture.sh gates on this too,
# but the fitter can be pointed straight at a file.
MIN_CELL_FRAC = 1.0 / 64.0


def surface_to_gain(surf):
    """Low-pass channel surface -> gain mesh normalised to min gain == 1.0."""
    peak = float(surf.max())
    if not np.isfinite(peak) or peak <= 0.0:
        raise ValueError("flat field is empty after black-level subtraction "
                         "- wrong pedestal, wrong geometry, or a dark frame")
    if float(surf.min()) < peak * MIN_CELL_FRAC:
        raise ValueError("flat field falls off by more than 6 stops "
                         "(min cell %.1f vs peak %.1f) - the shot was not flat; "
                         "re-shoot per lsc-calibration.md"
                         % (float(surf.min()), peak))
    gain = peak / surf
    return gain / gain.min()


def fit_mesh(bayer, order="rggb", nx=NX, ny=NY):
    """Raw Bayer field -> {'r','g','b': ny x nx gain meshes}.

    Black-level subtract, demux, combine Gr/Gb -> G, then build each channel's
    low-pass surface with a per-cell MEDIAN (rejects hot/dead pixels; the raw
    path has no defect correction) and invert to a gain mesh.
    """
    ch = demux(np.clip(bayer.astype(np.float32) - PEDESTAL, 0, None), order)
    g = 0.5 * (ch["Gr"] + ch["Gb"])
    planes = {"r": ch["R"], "g": g, "b": ch["B"]}
    return {k: surface_to_gain(block_stat(p, ny, nx, np.median))
            for k, p in planes.items()}


def emit_yaml(mesh, path):
    def fmt(m):
        return "\n".join(
            "        [ " + ", ".join(f"{v:.4f}" for v in row) + " ]"
            + ("," if i < m.shape[0] - 1 else "")
            for i, row in enumerate(m))
    with open(path, "w") as f:
        f.write(
            "# Lens shading correction mesh for IMX363 rear (Pixel 4a).\n"
            "# SENSOR-NATIVE orientation: apply to the raw Bayer frame BEFORE\n"
            "# display rotation (DT rotation=270). Gains >= 1.0, min per\n"
            "# channel == 1.0. Grid is %d wide x %d tall (x=raw width,\n"
            "# y=raw height), row-major.\n" % (NX, NY))
        f.write("LensShadingCorrection:\n")
        f.write("    x_size: %d\n    y_size: %d\n" % (NX, NY))
        for name in ("r", "g", "b"):
            f.write("    %s:\n%s\n" % (name, fmt(mesh[name])))
    return path


def emit_png(mesh, path, cell=22, gap=8):
    from PIL import Image
    gmax = max(mesh[k].max() for k in mesh)
    panels = []
    for name in ("r", "g", "b"):
        m = mesh[name]
        norm = (m - 1.0) / max(gmax - 1.0, 1e-6)         # 1.0 -> black, max -> white
        img = (np.clip(norm, 0, 1) * 255).astype(np.uint8)
        img = np.repeat(np.repeat(img, cell, 0), cell, 1)
        rgb = np.zeros((*img.shape, 3), np.uint8)
        idx = {"r": 0, "g": 1, "b": 2}[name]
        rgb[:, :, idx] = img
        panels.append(rgb)
    h = panels[0].shape[0]
    strip = np.zeros((h, gap, 3), np.uint8)
    row = panels[0]
    for p in panels[1:]:
        row = np.concatenate([row, strip, p], axis=1)
    Image.fromarray(row).save(path)
    return path


def summary(mesh):
    lines = ["channel  max_gain  vignetting(stops)"]
    for name in ("r", "g", "b"):
        mx = float(mesh[name].max())
        lines.append("  %s      %6.3f      %6.3f" % (name, mx, np.log2(mx)))
    # colour shading: do the normalised R/G/B surfaces actually differ?
    drg = float(np.abs(mesh["r"] - mesh["g"]).max())
    dbg = float(np.abs(mesh["b"] - mesh["g"]).max())
    lines.append("max |R-G| = %.3f   max |B-G| = %.3f gain "
                 "(colour shading present if > ~0.05)" % (drg, dbg))
    return "\n".join(lines)


def run(field_path, prefix, w, h, stride, order):
    buf = np.fromfile(field_path, dtype=np.uint8)
    bayer = unpack_raw10(buf, w, h, stride)
    mesh = fit_mesh(bayer, order)
    y = emit_yaml(mesh, prefix + ".yaml")
    p = emit_png(mesh, prefix + ".png")
    print(summary(mesh))
    print("wrote %s and %s" % (y, p))


# --------------------------------------------------------------------------
# Self-check: no real flat field exists yet, so validate against synthetic
# data with a KNOWN falloff, off-centre optical axis, per-channel colour
# shading, injected hot/dead pixels and noise.
# --------------------------------------------------------------------------
def _synth_falloff(ph, pw, cx, cy, k, power):
    """cos^4-style radial falloff on a half-res channel plane, off-centre axis."""
    yy, xx = np.mgrid[0:ph, 0:pw].astype(np.float64)
    r2 = ((xx - cx) / pw) ** 2 + ((yy - cy) / ph) ** 2
    return 1.0 / (1.0 + k * r2) ** power        # 1.0 at the axis, darker outward


def _synth_field(w, h, stride, gradient=0.0, seed=0):
    """Build a RAW10-packed synthetic flat field + return the noise-free
    per-Bayer-channel falloff planes (ground truth)."""
    rng = np.random.default_rng(seed)
    ph, pw = h // 2, w // 2
    cx, cy = pw * 0.58, ph * 0.44               # deliberately off-centre axis
    # per-channel falloff differs -> exercises colour shading
    fall = {
        "R":  _synth_falloff(ph, pw, cx, cy, k=2.6, power=2.0),
        "Gr": _synth_falloff(ph, pw, cx, cy, k=1.8, power=2.0),
        "Gb": _synth_falloff(ph, pw, cx, cy, k=1.8, power=2.0),
        "B":  _synth_falloff(ph, pw, cx, cy, k=1.3, power=2.0),
    }
    # linear illumination gradient across the raw width (sensor coords, centred)
    xx = (np.mgrid[0:ph, 0:pw][1] - (pw - 1) / 2.0) / pw
    illum = 1.0 + gradient * xx
    amp = 560.0                                  # ~60% of full scale at the axis
    bayer = np.empty((h, w), np.uint16)
    pos = {"R": (0, 0), "Gr": (0, 1), "Gb": (1, 0), "B": (1, 1)}
    for name, (oy, ox) in pos.items():
        clean = PEDESTAL + amp * fall[name] * illum
        noisy = clean + rng.normal(0, np.sqrt(np.maximum(clean, 1)) * 0.7)
        bayer[oy::2, ox::2] = np.clip(np.round(noisy), 0, MAXCODE)
    # inject hot (max) and dead (pedestal) pixels the median must reject
    for val in (MAXCODE, PEDESTAL):
        ys = rng.integers(0, h, 400)
        xs = rng.integers(0, w, 400)
        bayer[ys, xs] = val
    return pack_raw10(bayer, stride), fall


def _gt_gain(fall_channel, nx, ny):
    """Ground-truth gain mesh: cell-mean of the noise-free falloff, inverted
    and normalised the same way the fitter normalises."""
    surf = block_stat(fall_channel, ny, nx, np.mean)
    return surface_to_gain(surf)


def selftest():
    w, h = 2016, 1512                            # binned rear mode
    stride = stride_for(w, h)

    # 1. recover a known mesh from a noisy, hot-pixel-ridden synthetic field
    buf, fall = _synth_field(w, h, stride, gradient=0.0, seed=1)
    bayer = unpack_raw10(np.frombuffer(buf, np.uint8), w, h, stride)
    mesh = fit_mesh(bayer)
    gt = {"r": _gt_gain(fall["R"], NX, NY),
          "g": _gt_gain(0.5 * (fall["Gr"] + fall["Gb"]), NX, NY),
          "b": _gt_gain(fall["B"], NX, NY)}
    worst = 0.0
    for k in ("r", "g", "b"):
        rel = np.abs(mesh[k] - gt[k]) / gt[k]
        worst = max(worst, float(rel.max()))
        print("  %s: max_gain fit=%.3f gt=%.3f  max rel err=%.2f%%"
              % (k, mesh[k].max(), gt[k].max(), rel.max() * 100))
    TOL = 0.02
    print("  overall worst relative mesh error: %.2f%% (tol %.0f%%)"
          % (worst * 100, TOL * 100))
    assert worst < TOL, "mesh does not match ground truth within %.0f%%" % (TOL * 100)

    # 2. colour shading must be separable: R falls off faster than B here, so
    #    their normalised gain surfaces must genuinely differ.
    drg = float(np.abs(mesh["r"] - mesh["g"]).max())
    dbg = float(np.abs(mesh["b"] - mesh["g"]).max())
    print("  colour-shading separation: max|R-G|=%.3f max|B-G|=%.3f" % (drg, dbg))
    assert drg > 0.05 and dbg > 0.05, "per-channel surfaces not separable"

    # 3. the 0/180-degree average must cancel a linear illumination gradient.
    #    Rotating the phone 180 negates the gradient in sensor coords; averaging
    #    the two raw frames leaves the lens falloff alone.
    ba, fa = _synth_field(w, h, stride, gradient=+0.40, seed=2)
    bb, fb = _synth_field(w, h, stride, gradient=-0.40, seed=3)
    ua = unpack_raw10(np.frombuffer(ba, np.uint8), w, h, stride).astype(np.float64)
    ub = unpack_raw10(np.frombuffer(bb, np.uint8), w, h, stride).astype(np.float64)
    avg = np.clip(np.round(0.5 * (ua + ub)), 0, MAXCODE).astype(np.uint16)
    m_single = fit_mesh(unpack_raw10(np.frombuffer(ba, np.uint8), w, h, stride))
    m_avg = fit_mesh(avg)
    gt_flat = {"r": _gt_gain(fall["R"], NX, NY),
               "g": _gt_gain(0.5 * (fall["Gr"] + fall["Gb"]), NX, NY),
               "b": _gt_gain(fall["B"], NX, NY)}
    e_single = max(float(np.abs(m_single[k] - gt_flat[k]).max()) for k in gt_flat)
    e_avg = max(float(np.abs(m_avg[k] - gt_flat[k]).max()) for k in gt_flat)
    print("  gradient present: single-shot mesh err=%.3f  0/180-avg err=%.3f"
          % (e_single, e_avg))
    assert e_avg < e_single * 0.5, "0/180 averaging did not cancel the gradient"

    print("SELFTEST PASSED")


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--selftest":
        selftest()
        return
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    field, prefix = sys.argv[1], sys.argv[2]
    if len(sys.argv) > 3:
        w, h = (int(x) for x in sys.argv[3].lower().split("x"))
    else:
        w, h = 4032, 3024
    stride = int(sys.argv[4]) if len(sys.argv) > 4 else stride_for(w, h)
    order = sys.argv[5] if len(sys.argv) > 5 else "rggb"
    run(field, prefix, w, h, stride, order)


if __name__ == "__main__":
    main()
