#!/bin/sh
# Take one frame with a crude auto-exposure loop.
# usage: shoot.sh [front|rear] OUT [MODE]
CAM=${1:-front}
OUT=${2:-/tmp/shot.raw}
case "$CAM" in
front) SENSOR="imx355 13-001a"; MODE=${3:-1640x1232};;
rear)  SENSOR="imx363 12-001a"; MODE=${3:-4032x3024};;
*) echo "usage: $0 [front|rear] OUT [MODE]" >&2; exit 1;;
esac
S=$(media-ctl -d /dev/media0 -e "$SENSOR")
W=${MODE%x*}; H=${MODE#*x}
# One frame is the packed 10-bit stride times the height.
FRAME=$(( (W * 5 / 4) * H ))

v4l2-ctl -d $S -c test_pattern=0
v4l2-ctl -d $S -c vertical_blanking=1500

gain=0
dgain=1024
exp=1200
for try in 1 2 3 4 5 6; do
	v4l2-ctl -d $S -c exposure=$exp -c analogue_gain=$gain -c digital_gain=$dgain
	sudo /home/mobian/capture.sh "$CAM" "$MODE" 3 "$OUT" >/dev/null 2>&1 || exit 1
	# Light meter: mean of the high bytes from the middle of the last frame --
	# metering the first rows means metering whatever is at the top of the
	# picture, which for a room with a window underexposes everything else by
	# several stops. Every fifth byte
	# carries the packed low bits of four pixels and is nearly random even on a
	# black frame, so it has to be dropped or the meter reads ~35 on anything.
	mean=$(sudo tail -c $((FRAME / 2)) "$OUT" | od -An -tu1 -v -N 400000 | tr -s ' ' '\n' | grep -v '^$' | awk 'NR % 5 != 0 {if ($1 > 250) c++} END {print c + 0}')
	lvl=$(sudo tail -c $((FRAME / 2)) "$OUT" | od -An -tu1 -v -N 200000 | tr -s ' ' '\n' | grep -v '^$' | awk 'NR % 5 != 0 {s += $1; n++} END {printf "%d", s / n}')
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
