#!/bin/sh
# Take one front-camera frame with a crude auto-exposure loop.
# usage: shoot.sh OUT [MODE]
OUT=${1:-/tmp/shot.raw}
MODE=${2:-1640x1232}
S=/dev/v4l-subdev16

v4l2-ctl -d $S -c test_pattern=0
v4l2-ctl -d $S -c vertical_blanking=1500

gain=0
dgain=256
exp=1200
for try in 1 2 3 4 5 6; do
	v4l2-ctl -d $S -c exposure=$exp -c analogue_gain=$gain -c digital_gain=$dgain
	sudo /home/mobian/capture.sh "$MODE" 6 "$OUT" >/dev/null 2>&1 || exit 1
	# mean of the high bytes of the last frame is a good enough light meter
	mean=$(sudo tail -c 2542848 "$OUT" | od -An -tu1 -v -N 400000 | tr -s ' ' '\n' | grep -c '^25[0-5]$')
	lvl=$(sudo tail -c 2542848 "$OUT" | od -An -tu1 -v -N 200000 | tr -s ' ' '\n' | grep -v '^$' | awk '{s+=$1; n++} END {printf "%d", s/n}')
	echo "try=$try exp=$exp gain=$gain level=$lvl saturated=$mean"
	if [ "$lvl" -gt 110 ]; then
		gain=$((gain / 3)); exp=$((exp / 2))
	elif [ "$lvl" -lt 35 ]; then
		gain=$((gain + 120)); exp=$((exp * 3 / 2))
	else
		echo "exposure ok"; break
	fi
done
ls -l "$OUT"
