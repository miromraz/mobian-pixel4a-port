#!/usr/bin/env python3
"""SLG51000 wire-level probe tool. Run as root on the phone.

Reset primitive + probe for the Dialog SLG51000 camera PMIC on i2c-9 @0x75.
Power-up sequence taken from the vendor GPL driver (android.googlesource.com
kernel/msm android-msm-sunfish-4.14, drivers/regulator/slg51000-regulator.c):

  dlg,cs-gpios[1] = pm6150l DT gpio6 = gpiochip1 line 5 -> HIGH, wait 5 ms  (cam buck)
  dlg,cs-gpios[0] = pm6150l DT gpio4 = gpiochip1 line 3 -> HIGH, wait 2 ms  (chip select)
  dlg,enable-gpios[0] = DT gpio1 = line 0 -> LOW
  dlg,enable-gpios[1] = DT gpio5 = line 4 -> LOW
  every register access is retried up to 10x with 3-6 ms between tries

DT gpio N == gpiochip1 line N-1 (checked against Volume Up = <&pm6150l_gpios 2>
showing up on line 1).

The chip latches on once it has answered, so only the first ACK after a real
power cycle proves anything.

usage: slgprobe.py [vendor|permute|read] [--release]
"""
import ctypes, fcntl, os, subprocess, sys, time

I2C_RDWR = 0x0707
I2C_M_RD = 0x0001
BUS = "/dev/i2c-9"
ADDR = 0x75

CAM_BUCK, CS, EN1, EN2 = 5, 3, 0, 4
SYSCTL_PATN_ID_B0 = 0x0009


class i2c_msg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.POINTER(ctypes.c_uint8))]


class i2c_rdwr(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(i2c_msg)), ("nmsgs", ctypes.c_uint32)]


def read_reg(fd, reg, n=1):
    wbuf = (ctypes.c_uint8 * 2)(reg >> 8, reg & 0xFF)
    rbuf = (ctypes.c_uint8 * n)()
    msgs = (i2c_msg * 2)(
        i2c_msg(ADDR, 0, 2, ctypes.cast(wbuf, ctypes.POINTER(ctypes.c_uint8))),
        i2c_msg(ADDR, I2C_M_RD, n, ctypes.cast(rbuf, ctypes.POINTER(ctypes.c_uint8))),
    )
    fcntl.ioctl(fd, I2C_RDWR, i2c_rdwr(msgs, 2))
    return bytes(rbuf)


def try_read(fd, label, reg=SYSCTL_PATN_ID_B0, n=3, retries=1):
    """Vendor retries every access up to 10x, 3-6 ms apart."""
    for i in range(retries):
        try:
            print(f"  {label}: ACK  {reg:#06x} = {read_reg(fd, reg, n).hex(' ')}"
                  f"{'' if i == 0 else f' (try {i + 1})'}")
            return True
        except OSError as e:
            if i + 1 == retries:
                print(f"  {label}: NAK ({e.strerror})"
                      f"{'' if retries == 1 else f' after {retries} tries'}")
            time.sleep(0.004)
    return False


def drive(line, value):
    subprocess.run(["gpioset", "-z", "-C", "slgprobe", "-c", "gpiochip1",
                    f"{line}={value}"], check=True)


def release():
    subprocess.run("pkill -f 'gpioset.*slgprobe'", shell=True)


def held():
    out = subprocess.run(["gpioinfo", "-c", "gpiochip1"], capture_output=True,
                         text=True).stdout
    return [l.split()[1].rstrip(":") for l in out.splitlines() if "slgprobe" in l]


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "vendor"
    if mode == "--release":
        release()
        return

    fd = os.open(BUS, os.O_RDWR)
    print(f"lines already held: {held() or 'none'}")
    print("baseline, nothing driven:")
    if try_read(fd, "0x75"):
        print("!! chip already answering -- it is latched on, power cycle "
              "before trusting any result below")

    if mode == "read":
        os.close(fd)
        return

    if mode == "vendor":
        print(f"cam buck line {CAM_BUCK} -> 1, 5 ms")
        drive(CAM_BUCK, 1)
        time.sleep(0.005)
        try_read(fd, "buck only")

        print(f"chip select line {CS} -> 1, 2 ms")
        drive(CS, 1)
        time.sleep(0.002)
        ok = try_read(fd, "buck+cs", retries=10)

        print(f"enables line {EN1} -> 0, line {EN2} -> 0")
        drive(EN1, 0)
        drive(EN2, 0)
        time.sleep(0.005)
        ok = try_read(fd, "buck+cs+enables low", retries=10) or ok

        if not ok:
            print("still nothing; trying enables HIGH (vendor drives them low, "
                  "so this is off-spec)")
            release()
            time.sleep(0.05)
            drive(CAM_BUCK, 1)
            drive(CS, 1)
            drive(EN1, 1)
            drive(EN2, 1)
            time.sleep(0.02)
            ok = try_read(fd, "all four high", retries=10) or ok

        if ok:
            for reg, name in ((0x0000, "0x0000"), (0x0009, "patn id b0..b2"),
                              (0x1000, "ldo1 block"), (0x0006, "sysctl")):
                try_read(fd, name, reg=reg, n=3, retries=10)
        print(f"lines held on exit: {held() or 'none'}")

    os.close(fd)


main()
