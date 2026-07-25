#!/usr/bin/env python3
"""Parsing of `ssccli` measurement lines. Pure stdlib so it can be checked anywhere.

Run the self-check:  python3 sscparse.py
"""

import math
import re

# Anchored on purpose. ssccli's stderr is merged into its stdout by the caller, and GLib
# warnings can contain the word "measurement:" followed by a number -- an unanchored search
# happily reads those as a reading and paints a bogus value on screen.
_PREFIX = r"^\s*\w+ sensor measurement: "
# Also deliberate: a bare "." matches [\d.]+ and then float(".") raises inside the readyRead
# slot, which on Qt means the exception surfaces from the event loop.
_NUM = r"-?\d+(?:\.\d+)?"

_XYZ = re.compile(_PREFIX + rf"X=({_NUM}) Y=({_NUM}) Z=({_NUM})")
_SCALAR = re.compile(_PREFIX + rf"({_NUM})(?=\s|$)")
_NEARFAR = re.compile(_PREFIX + r"(NEAR|FAR)\b")


def parse_xyz(line):
    """(x, y, z) floats from an accelerometer/magnetometer line, or None."""
    m = _XYZ.match(line)
    return tuple(float(v) for v in m.groups()) if m else None


def parse_scalar(line):
    """The single float from a light-sensor line, or None."""
    m = _SCALAR.match(line)
    return float(m.group(1)) if m else None


def parse_near(line):
    """True for NEAR, False for FAR, None if the line is not a proximity reading."""
    m = _NEARFAR.match(line)
    return None if not m else m.group(1) == "NEAR"


def magnitude(x, y, z):
    return math.sqrt(x * x + y * y + z * z)


def heading(x, y):
    """Field direction in the phone's XY plane, degrees counter-clockwise from +X.

    This is a raw field direction, NOT a compass bearing: it is uncalibrated, not
    tilt-compensated, and not referenced to magnetic north. Good enough to show the
    magnetometer responding to a magnet; not good enough to navigate by.
    """
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def _selfcheck():
    # Lines below are verbatim ssccli 0.4.2 output captured on sunfish 2026-07-25.
    a = parse_xyz("Accelerometer sensor measurement: X=0.897607 Y=-0.232826 Z=9.723631 m/s²")
    assert a == (0.897607, -0.232826, 9.723631), a
    assert abs(magnitude(*a) - 9.767748) < 1e-6, magnitude(*a)

    m = parse_xyz("Magnetometer sensor measurement: X=-18.731251 Y=-37.443752 Z=-22.556252 μT")
    assert m == (-18.731251, -37.443752, -22.556252), m
    assert abs(magnitude(*m) - 47.5571) < 1e-4, magnitude(*m)  # plausible Earth field

    assert parse_scalar("Light sensor measurement: 67.334595 Lux") == 67.334595
    assert parse_near("Proximity sensor measurement: FAR") is False
    assert parse_near("Proximity sensor measurement: NEAR") is True

    # Hostile lines that MUST NOT be read as measurements. The first one is the reason the
    # patterns are anchored: unanchored, it parsed as -1 lux and got painted on the screen.
    for bad in ("** (ssccli:1): WARNING **: failed to read measurement: -1",
                "** (ssccli:1632): WARNING **: Mount matrix provided by firmware is all 0",
                "Light sensor measurement: . Lux",              # float('.') raises
                "Light sensor measurement: Lux",
                "Accelerometer sensor disabled",
                "  leading junk Light sensor measurement: 5.0 Lux",
                ""):
        assert parse_xyz(bad) is None, bad
        assert parse_scalar(bad) is None, bad
        assert parse_near(bad) is None, bad

    # a real line must not be rejected by the anchoring
    assert parse_scalar("Light sensor measurement: 0 Lux") == 0.0
    assert parse_xyz("Accelerometer sensor measurement: X=1 Y=-2 Z=3 m/s²") == (1.0, -2.0, 3.0)

    # heading is measured from +X, counter-clockwise
    assert abs(heading(10, 0) - 0.0) < 1e-9, heading(10, 0)
    assert abs(heading(0, 10) - 90.0) < 1e-9, heading(0, 10)
    assert abs(heading(10, 10) - 45.0) < 1e-9, heading(10, 10)
    assert abs(heading(-10, 0) - 180.0) < 1e-9, heading(-10, 0)
    assert abs(heading(0, -10) - 270.0) < 1e-9, heading(0, -10)
    assert 0 <= heading(-3, -4) < 360

    print("sscparse self-check OK")


if __name__ == "__main__":
    _selfcheck()
