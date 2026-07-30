# Front camera bring-up tools (Pixel 4a / sunfish)

The 8 MP IMX355 front camera works on mainline. Everything below runs on the phone
except `raw2png.py`, which develops a captured frame on the host.

## Capture

    ./capture.sh [WIDTHxHEIGHT] [FRAMES] [OUT]     # default 1640x1232, 5 frames
    ./shoot.sh   OUT [MODE]                        # same, with a crude auto-exposure loop

`capture.sh` wires imx355 -> CSIPHY2 -> CSID0 -> VFE0 RDI0 -> /dev/video0 and writes
MIPI RAW10-packed SRGGB frames (`pRAA`). Verified at 1640x1232 and full 3280x2464.
No root needed -- `mobian` is in the `video` group.

Develop a frame on the host:

    ./raw2png.py frame.raw out.png 1640 1232 2064      # stride 4112 for 3280x2464

The frame is bayer with no ISP: `raw2png.py` does a 2x2 bin, grey-world white
balance and a gamma curve. Good enough to see whether the camera works, not a
photo pipeline.

## Diagnostics

`slgprobe.py` -- wire-level probe for the SLG51000 camera PMIC on i2c-9 @0x75. It
drives the power-up sequence by hand (gpiochip1 line 5 = buck, high, 5 ms, then
line 3 = chip select, high, 2 ms) and does a 16-bit register read. Useful if the
rails ever stop coming up. **The chip latches on once it has answered**, so only
the first ACK after a real power cycle proves anything.

`i2cread.py BUS ADDR REG [LEN] [REPEAT] [DELAY]` -- 16-bit-register i2c read that
works on an address a kernel driver has already claimed. The decisive
sensor-is-really-streaming check:

    sudo ./i2cread.py 13 0x1a 0x0005 1 6 0.3    # imx355 frame counter must advance

## What was wrong (for the next person)

1. SLG51000 never ACKed: `dlg,cs-gpios` has two entries and the *second* one is the
   enable of the buck feeding the chip. It must go high 5 ms before the first
   (the real chip select). Mainline only ever fetched entry 0.
2. The module could not autoload: no OF match table, so the DT device's `of:`
   modalias matched nothing.
3. Frames never arrived even though the sensor was streaming: `camss` asked for
   300 MHz on the `csiphyN` branches, which pulls their shared parent
   `cphy_rx_clk_src` down with it. 300 MHz cannot carry four lanes at 720 Mbps --
   the PHY raised interrupts at the frame rate but the CSID never saw a valid
   packet. The vendor runs cphy_rx at 384/400 MHz and also enables CSIPHY0's
   clock for every PHY.

The rear IMX363 has no mainline driver, so only the front camera works.
