#!/bin/sh
# Host-side capture: keep the USB-net iface up at 172.16.42.2 and log every push
# the device makes to :9999. Each Mobian boot's initramfs pushes pstore (the
# PREVIOUS boot's console = the reboot cause). Writes to /tmp/pstore-cap.log.
IF=enp0s20f0u1
LOG=/tmp/pstore-cap.log
: > "$LOG"
( while :; do
    ip link set "$IF" up 2>/dev/null
    ip addr add 172.16.42.2/24 dev "$IF" 2>/dev/null
    sleep 1
  done ) &
echo "listening on 0.0.0.0:9999 -> $LOG"
exec python3 - "$LOG" <<'PY'
import socket, sys, time
log = sys.argv[1]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 9999)); s.listen(5)
while True:
    c, a = s.accept()
    with open(log, "ab") as f:
        f.write(("######## CONNECTION %s from %s ########\n" % (time.strftime("%H:%M:%S"), a[0])).encode())
        while True:
            d = c.recv(4096)
            if not d: break
            f.write(d); f.flush()
    c.close()
PY
