#!/usr/bin/env python3
"""Turn one MIPI RAW10-packed bayer frame from camss RDI into a PNG.

usage: raw2png.py in.raw out.png [width] [height] [stride] [rggb|bggr] [rot]

Both of sunfish's sensors are mounted a quarter turn round, so `rot` defaults to
90 degrees clockwise. Pass 0 to get the sensor's own readout, or 270 for a frame
shot with both flips on (that is another 180 on top).
"""
import sys
import numpy as np
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
w = int(sys.argv[3]) if len(sys.argv) > 3 else 1640
h = int(sys.argv[4]) if len(sys.argv) > 4 else 1232
stride = int(sys.argv[5]) if len(sys.argv) > 5 else 2064

raw = np.fromfile(src, dtype=np.uint8)
raw = raw[:h * stride].reshape(h, stride)

# 5 bytes carry 4 pixels: 4 high bytes then one byte of packed low 2 bits.
groups = w // 4
p = raw[:, :groups * 5].reshape(h, groups, 5).astype(np.uint16)
lo = p[:, :, 4]
px = np.empty((h, groups, 4), dtype=np.uint16)
for i in range(4):
    px[:, :, i] = (p[:, :, i] << 2) | ((lo >> (2 * i)) & 0x3)
bayer = px.reshape(h, w).astype(np.float32)
# Sony sensors output a 64 LSB black pedestal; without removing it everything
# above the shadows gets washed out.
bayer = np.clip(bayer - 64.0, 0, None) / (1023.0 - 64.0)

# Bilinear-free debayer: average each 2x2 cell into one RGB pixel.
order = sys.argv[6] if len(sys.argv) > 6 else "rggb"
g = (bayer[0::2, 1::2] + bayer[1::2, 0::2]) / 2
if order == "bggr":
    r, b = bayer[1::2, 1::2], bayer[0::2, 0::2]
else:
    r, b = bayer[0::2, 0::2], bayer[1::2, 1::2]

# grey-world white balance, then a plain sRGB-ish gamma
rgb = np.dstack([r, g, b])
# Clipped highlights -- a window, a lamp -- have no colour left in them, so
# leaving them in the grey-world average drags the whole frame off-colour.
lit = rgb.reshape(-1, 3)
lit = lit[lit.max(axis=1) < 0.95] if (lit.max(axis=1) < 0.95).any() else lit
means = lit.mean(axis=0)
rgb *= means.mean() / np.maximum(means, 1e-6)
# Blown-out pixels keep only their surviving channel and read as a colour cast
# (a window comes out pink), so paint them white instead of balancing them.
clipped = rgb.max(axis=2) >= 0.98
hi = np.percentile(rgb, 97)
rgb = np.clip(rgb / max(hi, 1e-6), 0, 1) ** (1 / 2.2)
rgb[clipped] = 1.0

img = Image.fromarray((rgb * 255).astype(np.uint8))
rot = int(sys.argv[7]) if len(sys.argv) > 7 else 90
if rot:
    img = img.rotate(-rot, expand=True)
img.save(dst)
print(f"{dst}: {img.width}x{img.height}, rot {rot}, mean level {bayer.mean():.4f}")
