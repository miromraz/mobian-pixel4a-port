#!/bin/bash
# Mid-stream: write the PDAF regs directly over i2c, read them back. Tells us if
# they are writable/persistent at all, independent of the kernel driver path.
set -e
W=4032; H=3024
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
v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=250 --stream-to=/dev/null >/dev/null 2>&1 &
CAP=$!
sleep 0.7
echo "-- before --"; for r in 0x3030 0x3032 0x7bcd; do python3 /home/mobian/i2cread.py 12 0x1a $r; done
echo "-- write 1 --"
for rv in "0x3030 1" "0x3032 1" "0x7bcd 1"; do python3 /home/mobian/pd_i2cwrite.py 12 0x1a $rv; done
sleep 0.3
echo "-- after --"; for r in 0x3030 0x3032 0x7bcd; do python3 /home/mobian/i2cread.py 12 0x1a $r; done
wait $CAP
echo i2ctest-done
