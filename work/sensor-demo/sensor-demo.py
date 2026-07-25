#!/usr/bin/env python3
"""Live view of the Pixel 4a (sunfish) ADSP Sensor Core sensors.

Reads the sensors the same way anything else on this device does: `ssccli` from
libssc, which talks QMI/protobuf to the SSC on the ADSP over QRTR service 400.
One ssccli process per sensor, output parsed line by line.

ponytail: subprocess + regex instead of binding libssc through gobject-introspection.
It is ~40 lines instead of a GLib/Qt event-loop bridge, and it proves the point
better -- ssccli is the reference reader, so what you see here is not a private
code path. If this ever needs to be a real app, use gir1.2-ssc-2 directly.

Run it on the phone:  python3 sensor-demo.py
Over ssh:  env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
             QT_QPA_PLATFORM=wayland python3 sensor-demo.py
"""

import math
import shutil
import sys
import time

from PySide6.QtCore import QProcess, Qt, QTimer, QPointF
from PySide6.QtGui import QColor, QFont, QPainter, QPen
from PySide6.QtWidgets import (QApplication, QFrame, QHBoxLayout, QLabel,
                               QProgressBar, QScrollArea, QVBoxLayout, QWidget)

from sscparse import heading, magnitude, parse_near, parse_scalar, parse_xyz

STREAM_SECONDS = 86400          # ssccli exits after --timeout; we restart it anyway

CSS = """
QWidget { background: #14161a; color: #e6e9ef; }
QLabel#title { color: #7aa2f7; font-weight: bold; }
QLabel#value { font-family: monospace; }
QLabel#hint { color: #8b93a5; font-size: 9px; }
QScrollArea { border: none; }
QFrame#card { background: #1b1e24; border-radius: 10px; }
QProgressBar { background: #232730; border: none; border-radius: 6px; height: 14px; }
QProgressBar::chunk { background: #9ece6a; border-radius: 6px; }
"""


class Bubble(QWidget):
    """Spirit level: the dot follows gravity, so tilting the phone moves it."""

    def __init__(self):
        super().__init__()
        self.setFixedSize(84, 84)
        self.ax = self.ay = 0.0

    def set_accel(self, x, y):
        self.ax, self.ay = x, y
        self.update()

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = self.width() / 2 - 4
        c = QPointF(self.width() / 2, self.height() / 2)
        p.setPen(QPen(QColor("#3b4252"), 2))
        p.drawEllipse(c, r, r)
        p.drawEllipse(c, 3, 3)
        # clamp to 1 g so a shake cannot push the dot out of the circle
        k = r / 9.81
        dx = max(-r, min(r, -self.ax * k))
        dy = max(-r, min(r, self.ay * k))
        p.setPen(Qt.NoPen)
        p.setBrush(QColor("#9ece6a"))
        p.drawEllipse(c + QPointF(dx, dy), 9, 9)


class Needle(QWidget):
    """Magnetometer direction in the phone's XY plane."""

    def __init__(self):
        super().__init__()
        self.setFixedSize(84, 84)
        self.heading = 0.0

    def set_heading(self, deg):
        self.heading = deg
        self.update()

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = self.width() / 2 - 4
        c = QPointF(self.width() / 2, self.height() / 2)
        p.setPen(QPen(QColor("#3b4252"), 2))
        p.drawEllipse(c, r, r)
        a = math.radians(self.heading - 90)
        tip = c + QPointF(math.cos(a) * (r - 8), math.sin(a) * (r - 8))
        p.setPen(QPen(QColor("#f7768e"), 4))
        p.drawLine(c, tip)


def card(title, hint, *widgets):
    frame = QFrame()
    frame.setObjectName("card")
    outer = QVBoxLayout(frame)
    t = QLabel(title)
    t.setObjectName("title")
    outer.addWidget(t)
    for w in widgets:
        outer.addWidget(w) if isinstance(w, QWidget) else outer.addLayout(w)
    h = QLabel(hint)
    h.setObjectName("hint")
    h.setWordWrap(True)
    outer.addWidget(h)
    return frame


def value_label(text="waiting for the ADSP..."):
    lbl = QLabel(text)
    lbl.setObjectName("value")
    lbl.setFont(QFont("monospace", 8))
    return lbl


class SensorDemo(QWidget):
    def __init__(self, use_sudo):
        super().__init__()
        self.use_sudo = use_sudo
        self.closing = False
        self.dbus_iface = None
        self.setWindowTitle("sunfish ADSP sensors")
        self.setStyleSheet(CSS)
        self.counts = {}

        self.accel = value_label()
        self.bubble = Bubble()
        row = QHBoxLayout()
        row.addWidget(self.bubble)
        row.addWidget(self.accel, 1)

        self.light = value_label()
        self.light_bar = QProgressBar()
        self.light_bar.setRange(0, 1000)
        self.light_bar.setTextVisible(False)

        self.prox = value_label()
        self.prox.setFont(QFont("monospace", 14, QFont.Bold))

        self.mag = value_label()
        self.needle = Needle()
        magrow = QHBoxLayout()
        magrow.addWidget(self.needle)
        magrow.addWidget(self.mag, 1)

        self.status = QLabel("")
        self.status.setObjectName("hint")
        self.status.setWordWrap(True)

        # Everything lives in a scroll area: the phone runs this window at whatever size
        # the mode toggle gives it, and cards squeezed below their minimum overlap instead
        # of clipping. Scrolling is the cheap fix that holds at any size.
        inner = QWidget()
        lay = QVBoxLayout(inner)
        lay.addWidget(card("ACCELEROMETER — LSM6DSR", "Tilt the phone: the dot follows gravity. "
                           "Flat and face-up is X≈0 Y≈0 Z≈+9.81 m/s².", row))
        lay.addWidget(card("AMBIENT LIGHT — TCS3701", "Shade the top of the screen and the lux "
                           "value drops; a torch pushes it into the thousands.",
                           self.light, self.light_bar))
        lay.addWidget(card("PROXIMITY — TCS3701", "Only prints when it changes. Cover the top "
                           "of the screen with your hand to flip it to NEAR.", self.prox))
        lay.addWidget(card("MAGNETOMETER — LIS2MDL", "The needle points along the measured field. "
                           "Earth's field is ~25-65 µT; a magnet saturates it.", magrow))
        lay.addWidget(self.status)
        lay.addStretch(1)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        # the phone renders this at a HiDPI scale factor; never scroll sideways,
        # wrap or shrink instead so every value stays on screen
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        scroll.setWidget(inner)
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(scroll)

        self.procs = {}
        for name, handler in (("accelerometer", self.on_accel), ("light", self.on_light),
                              ("proximity", self.on_prox), ("magnetometer", self.on_mag)):
            self.start(name, handler)

        # iio-sensor-proxy's own view of the accelerometer — this is what KWin uses to
        # auto-rotate, so it shows the sensors are wired into the desktop, not just readable.
        self.orientation = "?"
        QTimer.singleShot(0, self.poll_orientation)

    def start(self, name, handler):
        argv = ["ssccli", "--sensor", name, "--timeout", str(STREAM_SECONDS)]
        if self.use_sudo:
            argv = ["sudo", "-n"] + argv
        proc = QProcess(self)
        proc.setProcessChannelMode(QProcess.MergedChannels)
        proc.readyReadStandardOutput.connect(lambda p=proc, h=handler: self.drain(p, h))
        started = time.monotonic()

        def respawn(*_, p=proc, n=name, h=handler, t0=started):
            if self.closing:
                return
            # The old QProcess is parented to this widget, so without deleteLater it stays
            # alive as a child forever -- with a fast-failing ssccli that is an unbounded
            # leak of processes objects and their lambdas.
            p.finished.disconnect()
            p.errorOccurred.disconnect()
            p.readyReadStandardOutput.disconnect()
            p.deleteLater()
            # Back off when ssccli dies immediately (missing binary, `sudo -n` with no
            # NOPASSWD, ADSP down) so a failure does not become a respawn storm.
            delay = 1000 if time.monotonic() - t0 > 2 else 5000
            QTimer.singleShot(delay, lambda: self.start(n, h))

        # ssccli stops at --timeout, and a sensor can be dropped if the ADSP restarts.
        # errorOccurred matters as much as finished: on FailedToStart, Qt emits ONLY
        # errorOccurred, so without this a sensor would die silently and never come back.
        proc.finished.connect(respawn)
        proc.errorOccurred.connect(respawn)
        proc.start(argv[0], argv[1:])
        self.procs[name] = proc

    def drain(self, proc, handler):
        while proc.canReadLine():
            handler(bytes(proc.readLine()).decode(errors="replace").strip())

    def tick(self, name):
        self.counts[name] = self.counts.get(name, 0) + 1
        self.status.setText("samples: " + "   ".join(
            f"{k} {v}" for k, v in sorted(self.counts.items()))
            + f"\niio-sensor-proxy orientation: {self.orientation}")

    def on_accel(self, line):
        xyz = parse_xyz(line)
        if not xyz:
            return
        x, y, z = xyz
        self.accel.setText(f"X {x:+6.2f}  Y {y:+6.2f}  Z {z:+6.2f}  m/s²\n"
                           f"|a| {magnitude(x, y, z):6.3f} m/s²  (1 g = 9.81)")
        self.bubble.set_accel(x, y)
        self.tick("accel")

    def on_light(self, line):
        lux = parse_scalar(line)
        if lux is None:
            return
        self.light.setText(f"{lux:9.2f} lux")
        self.light_bar.setValue(min(1000, int(lux)))
        self.tick("light")

    def on_prox(self, line):
        near = parse_near(line)
        if near is None:
            return
        self.prox.setText("NEAR" if near else "FAR")
        self.prox.setStyleSheet("color: %s" % ("#f7768e" if near else "#9ece6a"))
        self.tick("prox")

    def on_mag(self, line):
        xyz = parse_xyz(line)
        if not xyz:
            return
        x, y, z = xyz
        deg = heading(x, y)
        self.mag.setText(f"X {x:+7.2f}  Y {y:+7.2f}  Z {z:+7.2f}  µT\n"
                         f"|B| {magnitude(x, y, z):6.2f} µT   direction {deg:5.1f}°")
        self.needle.set_heading(deg)
        self.tick("mag")

    def poll_orientation(self):
        # Build the interface once. Constructing a QDBusInterface introspects the remote
        # object synchronously, and doing that every second on the GUI thread means a
        # wedged sensor-proxy freezes the whole UI for the D-Bus timeout.
        if self.dbus_iface is None:
            try:
                from PySide6.QtDBus import QDBusConnection, QDBusInterface
                self.dbus_iface = QDBusInterface(
                    "net.hadess.SensorProxy", "/net/hadess/SensorProxy",
                    "net.hadess.SensorProxy", QDBusConnection.systemBus())
            except Exception as exc:                   # DBus is a nice-to-have here
                self.orientation = f"unavailable ({exc.__class__.__name__})"
                return                                 # do not retry; nothing will change
        self.orientation = str(self.dbus_iface.property("AccelerometerOrientation") or "?")
        if not self.closing:
            QTimer.singleShot(2000, self.poll_orientation)

    def closeEvent(self, event):
        # Stops respawn and the orientation timer from resurrecting work during teardown.
        self.closing = True
        for proc in self.procs.values():
            proc.finished.disconnect()                 # else respawn fires during exit
            proc.errorOccurred.disconnect()
            proc.kill()
        event.accept()


def main():
    if not shutil.which("ssccli"):
        sys.exit("ssccli not found - install it with: sudo apt install -t forky libssc-bin")
    app = QApplication(sys.argv)
    # ssccli normally works unprivileged (AF_QIPCRTR is not root-only); --sudo is the
    # escape hatch if a local policy restricts the QRTR socket.
    win = SensorDemo(use_sudo="--sudo" in sys.argv)
    win.resize(480, 900)
    # The phone's logical screen is narrower than a default-sized window (Plasma runs at a
    # 2x scale factor), so an unmaximized window hangs off the right edge. Maximised is the
    # right default on a phone anyway; on a desktop it is still just a window.
    win.showMaximized()
    # `--grab FILE` writes a PNG of the window ~8 s in, once every sensor has reported.
    # Wayland forbids grabbing another process's window and spectacle needs a portal, so
    # self-grabbing is the only way to check this UI from a shell over ssh.
    if "--grab" in sys.argv:
        i = sys.argv.index("--grab") + 1
        if i >= len(sys.argv):
            sys.exit("--grab needs a file path")
        path = sys.argv[i]
        QTimer.singleShot(8000, lambda: win.grab().save(path))
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
