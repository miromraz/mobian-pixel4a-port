#!/bin/bash
# Configure the RDI pipeline, start a long stream to /dev/null, and read the
# PDAF gating registers back over i2c mid-stream to confirm the module-param
# writes reach the sensor. Args: WIDTH HEIGHT
set -e
W="$1"; H="$2"
pkill -TERM -x cam 2>/dev/null || true; sleep 1
S="imx363 12-001a"; PHY=msm_csiphy0; M=/dev/media0
media-ctl -d $M -r
media-ctl -d $M -l "\"$PHY\":1->\"msm_csid0\":0[1]"
media-ctl -d $M -l "\"msm_csid0\":1->\"msm_vfe0_rdi0\":0[1]"
for p in "$S\":0" "$PHY\":0" "$PHY\":1" 'msm_csid0":0' 'msm_csid0":1' \
         'msm_vfe0_rdi0":0' 'msm_vfe0_rdi0":1'; do
  media-ctl -d $M -V "\"$p[fmt:SRGGB10_1X10/${W}x${H}]"
done
v4l2-ctl -d /dev/video0 --set-fmt-video=width=$W,height=$H,pixelformat=pRAA >/dev/null
v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=150 --stream-to=/dev/null >/dev/null 2>&1 &
CAP=$!
sleep 0.7
for r in 0x3030 0x3032 0x7bcd; do python3 /home/mobian/i2cread.py 12 0x1a $r; done
wait $CAP
echo regcheck-done
