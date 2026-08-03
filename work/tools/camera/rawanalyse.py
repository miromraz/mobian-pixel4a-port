#!/usr/bin/env python3
"""Focus metric from clean raw camss captures (rawsweep.sh).
RAW10 packed (MIPI), 2016x1512, stride 2528. Extracts the Gr green subplane and
reports luma^2-normalised variance-of-Laplacian over a crop, median over frames.
Usage: rawanalyse.py OUTDIR [gy0 gy1 gx0 gx1]   (green-plane coords, 756x1008)
"""
import os, sys, glob, re
import numpy as np

W, H, STRIDE = 2016, 1512, 2528
FRAME = STRIDE * H  # 3822336
GCROP = (60, 700, 280, 520)  # green-plane (756x1008): the rack region


def unpack_raw10(buf):
    """buf: one frame bytes -> HxW uint16 (10-bit)."""
    rows = buf[:FRAME].reshape(H, STRIDE)[:, :W * 5 // 4]  # 2520 bytes/row
    g = rows.reshape(H, W // 4, 5).astype(np.uint16)
    hi = g[:, :, :4] << 2
    lo = g[:, :, 4]
    px = hi.copy()
    px[:, :, 0] |= (lo >> 0) & 3
    px[:, :, 1] |= (lo >> 2) & 3
    px[:, :, 2] |= (lo >> 4) & 3
    px[:, :, 3] |= (lo >> 6) & 3
    return px.reshape(H, W)


def frames(path):
    b = np.fromfile(path, dtype=np.uint8)
    n = b.size // FRAME
    for i in range(n):
        yield b[i * FRAME:(i + 1) * FRAME]


def metric(raw, crop):
    img = unpack_raw10(raw)
    gr = img[0::2, 1::2].astype(np.float32)  # Gr subplane, 756x1008
    y0, y1, x0, x1 = crop
    c = gr[y0:y1, x0:x1]
    m = c.mean()
    if m < 1:
        return None
    lap = (-4.0 * c[1:-1, 1:-1] + c[:-2, 1:-1] + c[2:, 1:-1]
           + c[1:-1, :-2] + c[1:-1, 2:])
    return float(lap.var() / (m * m)), float(m)


def main():
    outdir = sys.argv[1]
    crop = tuple(int(x) for x in sys.argv[2:6]) if len(sys.argv) >= 6 else GCROP
    files = sorted(glob.glob(os.path.join(outdir, "pos*.raw")),
                   key=lambda f: int(re.search(r"pos(\d+)", f).group(1)))
    res = []
    print("gcrop =", crop)
    print("%7s %6s %13s %10s" % ("pos", "frames", "sharpness", "luma"))
    for f in files:
        pos = int(re.search(r"pos(\d+)", f).group(1))
        vals, lums = [], []
        for fr in frames(f):
            r = metric(fr, crop)
            if r:
                vals.append(r[0]); lums.append(r[1])
        if not vals:
            print("%7d %6d %13s" % (pos, 0, "-")); continue
        m = float(np.median(vals))
        res.append((pos, m))
        print("%7d %6d %13.4f %10.1f" % (pos, len(vals), m, float(np.median(lums))))
    if res:
        best = max(res, key=lambda x: x[1]); worst = min(res, key=lambda x: x[1])
        print("\npeak   pos=%d sharpness=%.4f" % best)
        print("trough pos=%d sharpness=%.4f" % worst)
        print("peak/trough = %.2fx" % (best[1] / worst[1]))


if __name__ == "__main__":
    main()
