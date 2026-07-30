#!/usr/bin/env python3
"""16-bit-register i2c reader that works on addresses a driver has claimed.

usage: i2cread.py <bus> <addr> <reg> [len] [repeat] [delay_s]
e.g.   i2cread.py 13 0x1a 0x0005 1 6 0.2   # imx355 frame counter
"""
import ctypes, fcntl, os, sys, time

I2C_RDWR, I2C_M_RD = 0x0707, 0x0001


class i2c_msg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.POINTER(ctypes.c_uint8))]


class i2c_rdwr(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(i2c_msg)), ("nmsgs", ctypes.c_uint32)]


bus, addr, reg = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
n = int(sys.argv[4]) if len(sys.argv) > 4 else 1
rep = int(sys.argv[5]) if len(sys.argv) > 5 else 1
delay = float(sys.argv[6]) if len(sys.argv) > 6 else 0.2

fd = os.open(f"/dev/i2c-{bus}", os.O_RDWR)
for i in range(rep):
    wbuf = (ctypes.c_uint8 * 2)(reg >> 8, reg & 0xFF)
    rbuf = (ctypes.c_uint8 * n)()
    msgs = (i2c_msg * 2)(
        i2c_msg(addr, 0, 2, ctypes.cast(wbuf, ctypes.POINTER(ctypes.c_uint8))),
        i2c_msg(addr, I2C_M_RD, n, ctypes.cast(rbuf, ctypes.POINTER(ctypes.c_uint8))),
    )
    try:
        fcntl.ioctl(fd, I2C_RDWR, i2c_rdwr(msgs, 2))
        print(f"{reg:#06x} = {bytes(rbuf).hex(' ')}")
    except OSError as e:
        print(f"{reg:#06x}: {e.strerror}")
    if i + 1 < rep:
        time.sleep(delay)
