#!/bin/bash
# Sweep V4L2_CID_FOCUS_ABSOLUTE on the lc898219xi lens subdev while streaming the
# rear camera, so a focus metric can be computed per lens position afterwards.
#
# The lens driver autosuspends 1 s after the last control write and loses its
# position, so each dwell re-asserts the target repeatedly rather than setting
# it once.
OUT=/home/mobian/afcap
rm -rf "$OUT"; mkdir -p "$OUT"

SD=$(for d in /sys/class/video4linux/*; do
        grep -q lc898219xi "$d/name" 2>/dev/null && basename "$d"
     done)
[ -z "$SD" ] && { echo "FATAL: no lc898219xi subdev"; exit 1; }
echo "lens subdev: /dev/$SD"

pkill -TERM -x cam 2>/dev/null; sleep 3
for try in 1 2 3 4 5 6; do
  IDX=$(cam -l 2>/dev/null | sed -n 's/^\([0-9]\+\): .*i2c-bus@0.*/\1/p')
  [ -n "$IDX" ] && break
  sleep 3
done
[ -z "$IDX" ] && { echo "FATAL: cannot resolve rear camera"; exit 1; }
echo "rear index=$IDX"

cam -c "$IDX" --capture=700 --stream role=viewfinder,width=1280,height=960 \
    --file="$OUT/f#.bin" > "$OUT/cam.log" 2>&1 &
CAM=$!
sleep 6
grep -m1 "Using camera" "$OUT/cam.log" || { echo "FATAL: camera did not open"; kill -TERM $CAM; exit 1; }

for POS in 0 512 1024 1536 2048 2560 3072 3584 4095; do
  echo "$(date +%s.%N) $POS" >> "$OUT/dac.log"
  for i in 1 2 3 4 5 6 7 8; do
    v4l2-ctl -d "/dev/$SD" --set-ctrl focus_absolute=$POS >/dev/null 2>&1
    sleep 0.2
  done
done

wait $CAM 2>/dev/null
echo "frames: $(ls "$OUT"/f*.bin 2>/dev/null | wc -l)"
tail -1 "$OUT/cam.log"
