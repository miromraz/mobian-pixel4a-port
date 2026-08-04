#!/bin/bash
# Clean raw camss RDI capture at an arbitrary sensor mode, for the PDAF
# experiment. PD output itself is toggled OUT OF BAND via the imx363 module
# params (/sys/module/imx363/parameters/pdaf_*), read at each stream start.
# Args: WIDTH HEIGHT OUTDIR pos [pos ...]
# Prints the negotiated bytesperline (stride) so the unpacker uses the truth.
set -e
W="$1"; H="$2"; OUT="$3"; shift 3
rm -rf "$OUT"; mkdir -p "$OUT"
SD=$(for d in /sys/class/video4linux/*; do grep -q lc898219xi "$d/name" 2>/dev/null && basename "$d"; done) || true
[ -z "$SD" ] && { echo "FATAL no lens"; exit 1; }
pkill -TERM -x cam 2>/dev/null || true; sleep 2

S="imx363 12-001a"; PHY=msm_csiphy0; M=/dev/media0
media-ctl -d $M -r
media-ctl -d $M -l "\"$PHY\":1->\"msm_csid0\":0[1]"
media-ctl -d $M -l "\"msm_csid0\":1->\"msm_vfe0_rdi0\":0[1]"
for p in "$S\":0" "$PHY\":0" "$PHY\":1" 'msm_csid0":0' 'msm_csid0":1' \
         'msm_vfe0_rdi0":0' 'msm_vfe0_rdi0":1'; do
  media-ctl -d $M -V "\"$p[fmt:SRGGB10_1X10/${W}x${H}]"
done
v4l2-ctl -d /dev/video0 --set-fmt-video=width=$W,height=$H,pixelformat=pRAA >/dev/null
echo -n "NEGOTIATED "; v4l2-ctl -d /dev/video0 --get-fmt-video | grep -E "Width/Height|Bytes|Size Image" | tr '\n' ' '; echo

for POS in "$@"; do
  for i in 1 2 3 4; do v4l2-ctl -d "/dev/$SD" --set-ctrl focus_absolute=$POS >/dev/null 2>&1; done
  v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=4 --stream-to="$OUT/pos${POS}.raw" >/dev/null 2>&1
  echo "captured pos $POS -> $(stat -c %s "$OUT/pos${POS}.raw" 2>/dev/null)"
done
echo "done"
