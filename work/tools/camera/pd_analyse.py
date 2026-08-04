#!/usr/bin/env python3
"""IMX363 Type-2 PDAF experiment analysis.

Works on the CLEAN raw camss captures produced by rawsweep.sh:
RAW10 packed (MIPI), 2016x1512, stride 2528, 4 frames/file.

Subcommands
  locate  OFF.raw ON.raw
      Diff a PD-off vs PD-on capture of the SAME scene/focus and report where
      and how the pixels changed. Prints the modulo-N phase histogram of the
      changed pixels so the PD lattice pitch/offset falls out.

  disp   ON.raw  [--pitch P] [--phx a b] [--phase-map ...]
      Given the located PD lattice, split the two shielded phases, correlate
      them over a window and print a signed disparity for the file.

  curve  DIR      sweep of pos*.raw -> disparity per focus position (the money
      plot: disparity vs focus_absolute).

Everything empirical: nothing here needs vendor SPC/defocus calibration.
"""
import os, sys, glob, re
import numpy as np

# Defaults for the binned mode; override with env PD_W/PD_H/PD_STRIDE.
W = int(os.environ.get("PD_W", 2016))
H = int(os.environ.get("PD_H", 1512))
STRIDE = int(os.environ.get("PD_STRIDE", 2528))
FRAME = STRIDE * H


def unpack_raw10(buf):
    rows = buf[:FRAME].reshape(H, STRIDE)[:, :W * 5 // 4]
    g = rows.reshape(H, W // 4, 5).astype(np.uint16)
    hi = g[:, :, :4] << 2
    lo = g[:, :, 4]
    px = hi.copy()
    px[:, :, 0] |= (lo >> 0) & 3
    px[:, :, 1] |= (lo >> 2) & 3
    px[:, :, 2] |= (lo >> 4) & 3
    px[:, :, 3] |= (lo >> 6) & 3
    return px.reshape(H, W).astype(np.float32)


def mean_frame(path):
    b = np.fromfile(path, dtype=np.uint8)
    n = b.size // FRAME
    acc = np.zeros((H, W), np.float32)
    for i in range(n):
        acc += unpack_raw10(b[i * FRAME:(i + 1) * FRAME])
    return acc / max(n, 1), n


def cmd_locate(off_path, on_path):
    off, no = mean_frame(off_path)
    on, non = mean_frame(on_path)
    d = np.abs(on - off)
    thr = 20.0  # 10-bit codes; PD pixels swing hard, scene noise stays low
    mask = d > thr
    ys, xs = np.nonzero(mask)
    print("frames off/on = %d/%d" % (no, non))
    print("changed pixels: %d / %d (%.3f%%)" %
          (mask.sum(), mask.size, 100.0 * mask.sum() / mask.size))
    print("mean |diff| overall = %.2f, over changed = %.2f, max = %.1f" %
          (d.mean(), d[mask].mean() if mask.any() else 0, d.max()))
    if not mask.any():
        print("NO CHANGE -> PD output not visibly present at this setting")
        return
    # Modulo-phase histograms to reveal the lattice pitch/offset.
    for N in (2, 4, 8, 16, 32):
        hy = np.bincount(ys % N, minlength=N)
        hx = np.bincount(xs % N, minlength=N)
        print("mod %-2d  row%%: %s" % (N, hy.tolist()))
        print("       col%%: %s" % hx.tolist())
    # Bounding region of the changed pixels (AF window footprint).
    print("changed-pixel bbox rows[%d..%d] cols[%d..%d]" %
          (ys.min(), ys.max(), xs.min(), xs.max()))
    # Row occupancy: which image rows contain PD pixels (sparse-in-image vs block)
    rows_with = np.unique(ys)
    print("rows containing PD px: %d distinct; sample stride: %s" %
          (len(rows_with), np.diff(rows_with[:12]).tolist()))
    cols_with = np.unique(xs)
    print("cols containing PD px: %d distinct; sample stride: %s" %
          (len(cols_with), np.diff(cols_with[:12]).tolist()))


def highpass_plane(img, py, px):
    """One Bayer sub-plane, minus a 3x3 box blur of itself (kills scene, keeps
    pixel-scale anomalies like shielded PD pixels)."""
    p = img[py::2, px::2]
    k = np.ones((3, 3), np.float32) / 9.0
    # separable box blur via cumulative sums (no scipy)
    from numpy.lib.stride_tricks import sliding_window_view as swv
    pad = np.pad(p, 1, mode='reflect')
    blur = (swv(pad, (3, 3)).mean(axis=(-1, -2)))
    return p - blur


def cmd_fft(path, label=""):
    """Single-frame periodicity detector. An injected PD lattice concentrates
    high-pass energy at sharp spatial frequencies; scene/noise does not."""
    b = np.fromfile(path, dtype=np.uint8)
    img = unpack_raw10(b[:FRAME])
    print("=== fft %s %s ===" % (label, os.path.basename(path)))
    for name, (py, px) in {"R": (0, 0), "Gr": (0, 1), "Gb": (1, 0), "B": (1, 1)}.items():
        hp = highpass_plane(img, py, px)
        # central crop, power of two-ish, windowed
        h, w = hp.shape
        cy, cx = h // 2, w // 2
        s = 512
        c = hp[cy - s:cy + s, cx - s:cx + s]
        win = np.hanning(c.shape[0])[:, None] * np.hanning(c.shape[1])[None, :]
        F = np.abs(np.fft.fftshift(np.fft.fft2(c * win)))
        F[F.shape[0] // 2, F.shape[1] // 2] = 0  # kill DC
        # zero a small DC neighbourhood
        m = F.copy()
        cyy, cxx = m.shape[0] // 2, m.shape[1] // 2
        m[cyy - 3:cyy + 4, cxx - 3:cxx + 4] = 0
        peak = m.max()
        mean = m.mean()
        pj = np.unravel_index(np.argmax(m), m.shape)
        # spatial freq (cycles/pixel) of the peak
        fy = (pj[0] - cyy) / m.shape[0]
        fx = (pj[1] - cxx) / m.shape[1]
        print("  %-2s peak/mean=%6.1f  peakfreq=(%.3f,%.3f) cyc/px  -> pitch~(%s,%s)px" %
              (name, peak / mean,
               fy, fx,
               ("%.1f" % abs(1 / fy)) if fy else "inf",
               ("%.1f" % abs(1 / fx)) if fx else "inf"))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "locate":
        cmd_locate(sys.argv[2], sys.argv[3])
    elif cmd == "fft":
        cmd_fft(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
    else:
        print(__doc__)
        sys.exit(1)
