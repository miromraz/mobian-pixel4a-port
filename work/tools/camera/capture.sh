#!/bin/sh
# Front camera (imx355 on CSIPHY2) capture through camss RDI0.
# usage: capture.sh [WIDTHxHEIGHT] [FRAMES] [OUT]
set -e
MODE=${1:-1640x1232}
FRAMES=${2:-5}
OUT=${3:-/tmp/frame.raw}
W=${MODE%x*}; H=${MODE#*x}
M=/dev/media0
S="imx355 13-001a"

media-ctl -d $M -r
media-ctl -d $M -l "\"msm_csiphy2\":1->\"msm_csid0\":0[1]"
media-ctl -d $M -l "\"msm_csid0\":1->\"msm_vfe0_rdi0\":0[1]"
for p in "$S\":0" 'msm_csiphy2":0' 'msm_csiphy2":1' 'msm_csid0":0' 'msm_csid0":1' \
         'msm_vfe0_rdi0":0' 'msm_vfe0_rdi0":1'; do
	media-ctl -d $M -V "\"$p[fmt:SRGGB10_1X10/${W}x${H}]"
done

v4l2-ctl -d /dev/video0 --set-fmt-video=width=$W,height=$H,pixelformat=pRAA
rm -f "$OUT"
v4l2-ctl -d /dev/video0 --stream-mmap --stream-count="$FRAMES" --stream-to="$OUT"
ls -l "$OUT"
