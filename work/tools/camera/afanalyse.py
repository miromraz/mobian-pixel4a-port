#!/usr/bin/env python3
"""Map captured frames to focus-DAC positions by timestamp and report a focus metric.

Frames are 1280x960 32bpp as written by libcamera's `cam --file`. The metric is the
variance of the Laplacian of the green channel over a centre crop, normalised by the
squared mean so a brightness change (AGC drifting during the sweep) cannot masquerade
as a sharpness change.
"""
import os
import sys
import glob
import numpy as np

W, H, BPP = 1280, 960, 4
SETTLE = 0.35  # s to discard after each DAC write, for the coil to stop moving


def metric(path):
    buf = np.fromfile(path, dtype=np.uint8)
    if buf.size < W * H * BPP:
        return None
    img = buf[: W * H * BPP].reshape(H, W, BPP)
    g = img[:, :, 1].astype(np.float32)
    c = g[H // 2 - 200 : H // 2 + 200, W // 2 - 200 : W // 2 + 200]
    mean = c.mean()
    if mean < 1.0:
        return None
    lap = (
        -4.0 * c[1:-1, 1:-1]
        + c[:-2, 1:-1] + c[2:, 1:-1] + c[1:-1, :-2] + c[1:-1, 2:]
    )
    return float(lap.var() / (mean * mean)), float(mean)


def main(outdir):
    steps = []
    with open(os.path.join(outdir, "dac.log")) as fh:
        for line in fh:
            ts, code = line.split()
            steps.append((float(ts), code))
    if not steps:
        sys.exit("no dac.log entries")

    frames = sorted(glob.glob(os.path.join(outdir, "f*.bin")))
    buckets = {code: [] for _, code in steps}
    lumas = {code: [] for _, code in steps}

    for f in frames:
        mt = os.path.getmtime(f)
        cur = None
        for ts, code in steps:
            if mt >= ts + SETTLE:
                cur = code
            else:
                break
        if cur is None:
            continue
        r = metric(f)
        if r is None:
            continue
        buckets[cur].append(r[0])
        lumas[cur].append(r[1])

    print(f"{'DAC hi':>7} {'frames':>6} {'focus metric':>13} {'mean luma':>10}")
    results = []
    for _, code in steps:
        v = buckets[code]
        if not v:
            print(f"{code:>7} {0:>6} {'-':>13} {'-':>10}")
            continue
        m = float(np.median(v))
        lum = float(np.median(lumas[code]))
        results.append((code, m))
        print(f"{code:>7} {len(v):>6} {m:>13.4f} {lum:>10.1f}")

    if results:
        best = max(results, key=lambda x: x[1])
        worst = min(results, key=lambda x: x[1])
        print(f"\nsharpest DAC hi byte : {best[0]}  metric {best[1]:.4f}")
        print(f"softest  DAC hi byte : {worst[0]}  metric {worst[1]:.4f}")
        if worst[1] > 0:
            print(f"peak/trough ratio    : {best[1] / worst[1]:.2f}x")


if __name__ == "__main__":
    main(sys.argv[1])
