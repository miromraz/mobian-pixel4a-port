#!/usr/bin/env python3
"""
Extract per-mode SensorResolutionData / RegSettingsInfo register sequences from a
Qualcomm CamX sensor-module blob (com.qti.sensormodule.*.bin) and dump each mode's
geometry + ordered (addr, data) register writes.

Builds on parse_sensormodule.py (same container: 72-byte schema records at 240,
VALUE pool right after). See that file for the container write-up.

Per-mode grouping (proven by walking the schema record order):
    streamConfiguration, downScaleFactor, integrationInfo, regSetting,
    <N register triples: slaveAddr/registerData/delayUs>,
    ZZHDRInfo, HDR3ExposureInfo, RemosaicTypeInfo, capability

Register encoding (proven against the driver's known 4032x3024 table):
  - The register ADDRESS list is stored inline inside the regSetting node's own
    VALUE blob, as variable-length records. Each record's u64[0] is a node-id
    marker K that increments by 3 per register; u64[1] is the literal 16-bit
    address. Self-syncing on K+3 recovers the ordered address list regardless of
    record length (16-bit-data regs use longer records).
  - The register DATA is the value in the 3rd ("delayUs") slot of each unrolled
    slaveAddr/registerData/delayUs triple, in the same order. (The "registerData"
    slot is always 0 for sensor regs; the binarydumper packs the byte into delayUs.)

Facts only. Do NOT commit the .bin (repos are public / blob-free).
"""
import struct, sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import parse_sensormodule as P


def u64(f, POOL, o):
    return struct.unpack('<Q', f[POOL + o:POOL + o + 8])[0]


def parse_addr_blob(f, POOL, off, size, count):
    """Recover `count` register addresses from a regSetting VALUE blob by
    self-syncing on the incrementing node-id marker K (u64[0] of each record)."""
    n = size // 8
    words = [u64(f, POOL, off + i * 8) for i in range(n)]
    addrs = []
    pos = 0
    K = words[0]
    while pos + 1 < len(words) and len(addrs) < count:
        addrs.append(words[pos + 1])
        # find next record: next word equal to K+3
        nxt = None
        for j in range(pos + 2, len(words)):
            if words[j] == K + 3:
                nxt = j
                break
        if nxt is None:
            break
        pos = nxt
        K += 3
    return addrs


def modes(f, POOL, recs, id2rec):
    """Yield dict per mode: geometry + ordered [(addr, data), ...]."""
    out = []
    i = 0
    n = len(recs)
    while i < n:
        tid, nm, fl = recs[i]
        if nm == 'streamConfiguration':
            sc_off, sc_sz = fl[2], fl[3]
            # walk to the regSetting in this group
            j = i + 1
            regfl = None
            while j < n and recs[j][1] != 'regSetting':
                if recs[j][1] == 'streamConfiguration':
                    break
                j += 1
            if j < n and recs[j][1] == 'regSetting':
                regfl = recs[j][2]
                # collect the triple run after regSetting
                k = j + 1
                data = []
                while k < n and recs[k][1] in ('slaveAddr', 'registerData', 'delayUs'):
                    if recs[k][1] == 'delayUs':
                        data.append(u64(f, POOL, recs[k][2][2]))
                    k += 1
                addrs = parse_addr_blob(f, POOL, regfl[2], regfl[3], len(data))
                # The address inline-list and the delayUs data list are offset by
                # one relative to each other (proven: the 0x0348..0x034f crop block
                # only reproduces the driver under this shift). Register i takes
                # data[i-1]; register 0 (0x0112) is a known boundary artifact.
                pairs = [(addrs[k], data[k - 1]) for k in range(len(addrs))]
                out.append(dict(sc_off=sc_off, sc_sz=sc_sz,
                                regs=pairs,
                                ntriples=len(data), naddr=len(addrs)))
                i = k
                continue
        i += 1
    return out


def geom(f, POOL, sc_off, sc_sz):
    """Decode a streamConfiguration blob. Fields are u64. Layout (proven):
    [dt, x0, y0, w, h, bpp, ?, ?] repeated per output stream."""
    nw = sc_sz // 8
    w = [u64(f, POOL, sc_off + i * 8) for i in range(nw)]
    streams = []
    # each stream = 8 u64: datatype, x, y, width, height, bpp, a, b
    for s in range(0, nw, 8):
        blk = w[s:s + 8]
        if len(blk) == 8:
            streams.append(dict(dt=blk[0], w=blk[3], h=blk[4], bpp=blk[5]))
    return streams


if __name__ == '__main__':
    path = sys.argv[1]
    f, POOL, recs, id2rec = P.load(path)
    ms = modes(f, POOL, recs, id2rec)
    print(f"# recovered {len(ms)} modes\n")
    for idx, m in enumerate(ms):
        st = geom(f, POOL, m['sc_off'], m['sc_sz'])
        g = " | ".join(f"dt{s['dt']:#x} {s['w']}x{s['h']} {s['bpp']}bpp" for s in st)
        print(f"=== mode {idx}: {g}   (regs: {m['naddr']} addr / {m['ntriples']} data)")
        if '--regs' in sys.argv:
            for a, d in m['regs']:
                print(f"    {a:#06x} = {d:#04x}")
            print()
