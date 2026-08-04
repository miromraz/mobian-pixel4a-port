#!/usr/bin/env python3
"""16-bit-register / 8-bit-value i2c writer (bus already claimed by a driver).
usage: pd_i2cwrite.py <bus> <addr> <reg> <val>
"""
import ctypes, fcntl, os, sys

I2C_RDWR = 0x0707


class i2c_msg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.POINTER(ctypes.c_uint8))]


class i2c_rdwr(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(i2c_msg)), ("nmsgs", ctypes.c_uint32)]


bus, addr, reg, val = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0), int(sys.argv[4], 0)
fd = os.open(f"/dev/i2c-{bus}", os.O_RDWR)
wbuf = (ctypes.c_uint8 * 3)(reg >> 8, reg & 0xFF, val & 0xFF)
msgs = (i2c_msg * 1)(i2c_msg(addr, 0, 3, ctypes.cast(wbuf, ctypes.POINTER(ctypes.c_uint8))))
try:
    fcntl.ioctl(fd, I2C_RDWR, i2c_rdwr(msgs, 1))
    print(f"wrote {reg:#06x} = {val:#04x}")
except OSError as e:
    print(f"{reg:#06x} write failed: {e.strerror}")
