#!/bin/sh
# Fetch Qualcomm gpsOneXTRA predicted orbits and inject them into the GNSS engine.
#
# Without this the engine has NO ephemeris/almanac (validity reads 1980-01-06,
# 0 hours), so every acquisition is a blind cold search: satellites-in-view stays
# 0 and weak-signal acquisition is impossible. After injection the engine gets
# 7 days of predicted orbits and reports the full constellation.
#
# The server list comes from the modem itself:
#   qmicli -d qrtr://0 --loc-get-predicted-orbits-data-source
set -e
DIR=/var/lib/gps
FILE=$DIR/xtra3grcej.bin
mkdir -p "$DIR"

for host in path1 path2 path3; do
    if curl -sSf --max-time 60 -o "$FILE.new" "https://$host.xtracloud.net/xtra3grcej.bin"; then
        mv "$FILE.new" "$FILE"
        break
    fi
done
[ -s "$FILE" ] || { echo "no XTRA data available"; exit 1; }

/usr/local/sbin/gps-xtra-inject.py "$FILE"
# Time matters as much as orbits: without it the engine can't predict Doppler.
qmicli -d qrtr://0 --loc-inject-time >/dev/null 2>&1 || true
qmicli -d qrtr://0 --loc-get-predicted-orbits-data-validity 2>&1 | tail -1

# A coarse position lets the engine predict Doppler and compute a sky view; without
# it satellites-in-view stays 0 even with valid orbits. Set GPS_COARSE_LAT/LON in
# /etc/default/gps-xtra (any accuracy within ~100 km is fine).
[ -r /etc/default/gps-xtra ] && . /etc/default/gps-xtra
if [ -n "$GPS_COARSE_LAT" ] && [ -n "$GPS_COARSE_LON" ]; then
    qmicli -d qrtr://0 --loc-inject-position-latitude="$GPS_COARSE_LAT" \
                       --loc-inject-position-longitude="$GPS_COARSE_LON" >/dev/null 2>&1 || true
fi
