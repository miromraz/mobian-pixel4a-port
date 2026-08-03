#!/bin/bash
# Measure Continuous-AF convergence against the SYSTEM libcamera.
# Arg: number of runs. Alternates parking the lens at 0 / 4095 (both extremes).
# Reports converged LensPosition (-> focus_absolute), scan frames, and #sweeps.
RUNS=${1:-6}
SD=$(for d in /sys/class/video4linux/*; do grep -q lc898219xi "$d/name" 2>/dev/null && basename "$d"; done) || true
pkill -TERM -x cam 2>/dev/null || true; sleep 3
for t in 1 2 3 4 5 6; do IDX=$(cam -l 2>/dev/null | sed -n 's/^\([0-9]\+\): .*i2c-bus@0.*/\1/p'); [ -n "$IDX" ] && break; sleep 3; done
echo "lens=$SD cam=$IDX"
L=/tmp/afc.log
for r in $(seq "$RUNS"); do
  if [ $((r % 2)) -eq 0 ]; then PARK=4095; else PARK=0; fi
  for i in 1 2 3 4 5; do v4l2-ctl -d "/dev/$SD" --set-ctrl focus_absolute=$PARK >/dev/null 2>&1; done
  cam -c "$IDX" --capture=140 --metadata --stream role=viewfinder,width=1280,height=960 > "$L" 2>&1
  BEST=$(grep "Sweep end" "$L" | tail -1 | grep -oE 'Best focus: [0-9.]+' | grep -oE '[0-9.]+')
  SCAN=$(grep -c "AfState = 1" "$L")
  SWEEPS=$(grep -c "Starting focus sweep" "$L")
  FABS=$(python3 -c "print(round(${BEST:-0}/100*4095))" 2>/dev/null)
  printf "run %d park=%-4s converged_lenspos=%-6s fabs=%-5s scanframes=%-4s sweeps=%s\n" "$r" "$PARK" "${BEST:-NA}" "$FABS" "$SCAN" "$SWEEPS"
done
