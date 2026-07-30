#!/bin/sh
# Capture raw frames from either camera through camss RDI0.
# usage: capture.sh [front|rear] [WIDTHxHEIGHT] [FRAMES] [OUT]
set -e
CAM=${1:-front}
case "$CAM" in
front)	S="imx355 13-001a"; PHY=msm_csiphy2; MODE=${2:-1640x1232};;
rear)	S="imx363 12-001a"; PHY=msm_csiphy0; MODE=${2:-4032x3024};;
*)
	echo "usage: $0 [front|rear] [WIDTHxHEIGHT] [FRAMES] [OUT]" >&2; exit 1
	;;
esac
FRAMES=${3:-5}
OUT=${4:-/tmp/frame.raw}
W=${MODE%x*}; H=${MODE#*x}
M=/dev/media0

media-ctl -d $M -r
media-ctl -d $M -l "\"$PHY\":1->\"msm_csid0\":0[1]"
media-ctl -d $M -l "\"msm_csid0\":1->\"msm_vfe0_rdi0\":0[1]"
for p in "$S\":0" "$PHY\":0" "$PHY\":1" 'msm_csid0":0' 'msm_csid0":1' \
         'msm_vfe0_rdi0":0' 'msm_vfe0_rdi0":1'; do
	media-ctl -d $M -V "\"$p[fmt:SRGGB10_1X10/${W}x${H}]"
done

v4l2-ctl -d /dev/video0 --set-fmt-video=width=$W,height=$H,pixelformat=pRAA
rm -f "$OUT"
# Scale the guard with the frame count: killing v4l2-ctl mid-stream leaves the
# subdevs marked streaming (WARN in call_s_stream) and every later capture then
# fails with an empty file until the modules are reloaded.
timeout $((15 + FRAMES * 8)) v4l2-ctl -d /dev/video0 --stream-mmap --stream-count="$FRAMES" --stream-to="$OUT"
ls -l "$OUT"
