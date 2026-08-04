#!/bin/sh
# Capture an averaged raw flat field for lens-shading calibration.
# Runs ON THE PHONE. Deploy alongside capture.sh and lsc-fit.py.
#
#   ./lsc-capture.sh [rear|front] [WxH] [FRAMES] [OUT] [--pair]
#
# Averages FRAMES raw frames to kill noise, then REFUSES the shot if the field
# is unusable (any channel near saturation, or too dark for good SNR). A good
# flat field sits around 50-70% of full scale.
#
# --pair (strongly recommended): shoot a second field with the phone rotated
# 180 degrees and average the two. We shoot a wall/paper, not an integrating
# sphere, so the illumination itself has a gradient; a 0/180 pair cancels any
# linear gradient (it negates in sensor coords), leaving only the lens falloff.
# The two raw buffers are averaged directly -- the sensor's Bayer phase is
# native in both, so no rotation of the buffer is applied.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
CAM=${1:-rear}
MODE=${2:-4032x3024}
FRAMES=${3:-32}
OUT=${4:-/home/mobian/lsc-field.raw}
PAIR=0
for a in "$@"; do [ "$a" = "--pair" ] && PAIR=1; done

pkill -f plasma-camera 2>/dev/null || true
sleep 1

A=/tmp/lsc_a.raw
echo "== capturing $FRAMES frames ($CAM $MODE) =="
"$DIR/capture.sh" "$CAM" "$MODE" "$FRAMES" "$A"

B=""
if [ "$PAIR" = 1 ]; then
	printf '\n>> Rotate the phone 180 degrees now, keep it aimed at the same\n'
	printf '>> flat surface, then press Enter to capture the second field.\n'
	read _
	B=/tmp/lsc_b.raw
	echo "== capturing $FRAMES frames (180 deg) =="
	"$DIR/capture.sh" "$CAM" "$MODE" "$FRAMES" "$B"
fi

MODE="$MODE" OUT="$OUT" A="$A" B="$B" DIR="$DIR" python3 - <<'PY'
import os, importlib.util, numpy as np
d = os.environ["DIR"]
spec = importlib.util.spec_from_file_location("lf", os.path.join(d, "lsc-fit.py"))
lf = importlib.util.module_from_spec(spec); spec.loader.exec_module(lf)

w, h = (int(x) for x in os.environ["MODE"].lower().split("x"))
stride = lf.stride_for(w, h)
frame = h * stride
PED, MAX = lf.PEDESTAL, lf.MAXCODE

def average(path):
    b = np.fromfile(path, dtype=np.uint8)
    n = b.size // frame
    if n == 0:
        raise SystemExit("REFUSE: %s has no complete frame (got %d bytes)" % (path, b.size))
    acc = np.zeros((h, w), np.float64)
    for i in range(n):
        acc += lf.unpack_raw10(b[i*frame:(i+1)*frame], w, h, stride)
    print("  averaged %d frames from %s" % (n, os.path.basename(path)))
    return acc / n

fields = [average(os.environ["A"])]
if os.environ.get("B"):
    fields.append(average(os.environ["B"]))
field = sum(fields) / len(fields)

# --- usability gate, per Bayer channel ---
ch = lf.demux(field)
full = MAX - PED
refused = []
print("\nchannel  mean%full  %clipped(>=1000)")
for name in ("R", "Gr", "Gb", "B"):
    c = ch[name]
    mean_frac = (c.mean() - PED) / full
    clip_frac = float((c >= 1000).mean())
    print("  %-3s     %6.1f      %8.4f" % (name, mean_frac*100, clip_frac*100))
    if clip_frac > 0.001:
        refused.append("%s clipping (%.3f%% >= 1000, near saturation)" % (name, clip_frac*100))
    if mean_frac < 0.30:
        refused.append("%s too dark (%.0f%% of full scale, poor SNR)" % (name, mean_frac*100))
    if mean_frac > 0.85:
        refused.append("%s too bright (%.0f%% of full scale, risks clipping)" % (name, mean_frac*100))

# --- uniformity diagnostic (the vignetting the mesh will correct) ---
bayer = np.clip(np.round(field), 0, MAX).astype(np.uint16)
mesh = lf.fit_mesh(bayer)
print("\nuniformity (measured vignetting, corner/centre):")
for k in ("r", "g", "b"):
    mx = float(mesh[k].max())
    print("  %s  max gain %.2fx = %.2f stops" % (k, mx, np.log2(mx)))

if refused:
    print("\nREFUSED -- field not usable:")
    for r in refused:
        print("  - " + r)
    print("Re-shoot: a flat field wants an evenly-lit matte surface at ~60% "
          "of full scale, no glare, no shadows.")
    raise SystemExit(1)

# write the averaged field, repacked RAW10 so lsc-fit.py reads it like a frame
open(os.environ["OUT"], "wb").write(lf.pack_raw10(bayer, stride))
print("\nPASS -- wrote averaged flat field to %s" % os.environ["OUT"])
print("Now fit on the host:  ./lsc-fit.py %s lsc-mesh %dx%d"
      % (os.path.basename(os.environ["OUT"]), w, h))
PY
