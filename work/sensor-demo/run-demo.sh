#!/bin/sh
# Restart the sensor demo on the phone's Wayland session, fully detached.
# Detaching matters: a child that keeps the ssh channel's fds open makes the ssh
# invocation hang even after the command finishes.
# Run it ON the phone (patterns here must not be pkill'd from an ssh command line).
set -u
# Scope both to this user: an unscoped `pkill -f sensor-demo.py` also matches someone
# else's `vim sensor-demo.py`, and `pkill -x ssccli` would hit unrelated manual runs.
# The [.] keeps the pattern from matching a shell whose own command line contains it
# (that is how these kills silently killed their own ssh session twice).
pkill -u "$(id -u)" -f 'python3 .*sensor-demo[.]py' 2>/dev/null
pkill -u "$(id -u)" -x ssccli 2>/dev/null
sleep 1

cd "$(dirname "$0")" || exit 1
setsid env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
	QT_QPA_PLATFORM=wayland \
	python3 sensor-demo.py --grab /tmp/sensor-demo.png \
	</dev/null >/tmp/demo.log 2>&1 &

sleep 14
echo "app pid: $(pgrep -f 'sensor-demo[.]py' | head -1)"
echo "ssccli streams: $(pgrep -c ssccli 2>/dev/null || true)"
echo "screenshot: $(ls -l /tmp/sensor-demo.png 2>/dev/null || echo MISSING)"
echo "--- log ---"
head -20 /tmp/demo.log
