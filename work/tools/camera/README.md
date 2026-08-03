# Camera bring-up tools (Pixel 4a / sunfish)

Both cameras work on mainline: the 8 MP IMX355 front (CSIPHY2) and the 12 MP
IMX363 rear (CSIPHY0). Everything below runs on the phone except `raw2png.py`,
which develops a captured frame on the host.

## Capture

    ./capture.sh [front|rear] [WIDTHxHEIGHT] [FRAMES] [OUT]
    ./shoot.sh   [front|rear] OUT [MODE]      # same, with a crude auto-exposure loop

`capture.sh` wires the sensor -> CSIPHY -> CSID0 -> VFE0 RDI0 -> /dev/video0 and
writes MIPI RAW10-packed SRGGB frames (`pRAA`). Front defaults to 1640x1232
(also verified at the full 3280x2464), rear to 4032x3024. No root needed --
`mobian` is in the `video` group.

Develop a frame on the host:

    ./raw2png.py frame.raw out.png 1640 1232 2064            # front
    ./raw2png.py frame.raw out.png 4032 3024 5040            # rear

**Both sensors are mounted a quarter turn round**, so a frame straight off the
RDI is 90 degrees out and `raw2png.py` turns it clockwise by default. Pass `0` as
a seventh argument to see the sensor's own readout. The DT tells applications
about this with `rotation = <270>` on both nodes -- get that number wrong and
libcamera's correction is wrong with it (90 instead of 270 put every preview
upside down).

Pass `bggr` as the sixth argument for a frame shot with both flips on -- that is
another 180 degrees, and it swaps the bayer order, so such a frame wants
`bggr 270`. The imx363's own default used to be flips-on until the driver was
fixed.

The frame is bayer with no ISP: `raw2png.py` removes the 64 LSB black pedestal,
does a 2x2 bin, grey-world white balance and a gamma curve. Good enough to see
whether the camera works, not a photo pipeline.

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

Is the rear camera dark or broken? Point the torch at whatever it faces:

    echo 100 | sudo tee /sys/class/leds/white:flash/brightness

A frame that goes from the bare pedestal to a visible level means the whole path
is fine and the lens is just looking at something dark. Note that the imx363's
own `test_pattern` control is not usable -- selecting a pattern makes the sensor
stop emitting pixel data altogether, so the frames arrive as zeroes.

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

The rear camera then needed none of this fighting: with the same CSIPHY fix in
place its 636 MHz link -- 1272 Mbps per lane, nearly double the front's -- worked
on the first try. Its driver is out-of-tree (`sdm670-mainline`, Pixel 3a). Its one
real bug was the flip defaults above.

## Rear autofocus

The rear module's focus actuator is an **ON Semi LC898219XI at i2c 7-bit 0x72 on
bus 12**, and its coil rail (`cam_vaf`, 2.85 V) hangs off pm6150l GPIO12. Both were
recovered from the stock Android CamX sensor-module blob and then confirmed on the
device -- register `0xF0` reads `0xa5`, the chip's signature. `parse_sensormodule.py`
is the parser for those blobs; point it at a `com.qti.sensormodule.*.bin` from a
vendor partition. It also decodes the OIS and EEPROM slave addresses.

The driver is imported from `sdm670-mainline` (same tree and tag as `imx363.c`) and
the DT declares the rail, the actuator node and `lens-focus`, which is all the v4l2
core needs to build the sensor->lens ancillary link. Focus is then a plain control:

    v4l2-ctl -d /dev/$(...lc898219xi subdev...) --set-ctrl focus_absolute=3584

Range is 0..4095. **The lens autosuspends one second after the last write and loses
its position**, so anything holding a focus setting has to re-assert it -- that is
what the dwell loop in `afsweep.sh` is for.

    ./afsweep.sh              # on the phone: sweep focus while streaming, dump frames
    ./afanalyse.py /home/mobian/afcap   # focus metric per lens position

`afanalyse.py` normalises the sharpness metric by mean luma squared, because the
software ISP's AGC drifts during a sweep and an unnormalised metric happily
reports exposure changes as focus changes. Sweep against a **textured subject at
10-30 cm**: aimed at a blank or dark surface the metric measures amplified sensor
noise and the curve is flat no matter what the coil does.

OIS is not supported and is not planned. The controller is an LC898123F40 at 0x3e
(it also fronts the EEPROM reads); no driver for it exists in any public tree, it
has no published register map, and it needs a proprietary DSP firmware pushed over
i2c on every power-up.
