#!/usr/bin/env python3
"""
Parse a Qualcomm CamX/chi-cdk "sensor module" binary (com.qti.sensormodule.*.bin),
the serialized output of the binarydumper. Recovers the actuator / OIS / EEPROM
register-level programming.

Container format (reverse-engineered from com.qti.sensormodule.metric_imx363.bin,
"Parameter Parser V1.3.2"):
  - Header text at offset 0.
  - SCHEMA: flat array of 72-byte descriptor records starting at file offset 240.
      record = name[32] + 5 x little-endian u64:
        f0 = type (1=struct/composite, 0=leaf)
        f1 = parent marker (0xffffffff for leaves)
        f2 = dataOffset  -> offset into the VALUE segment (see POOL below)
        f3 = size (bytes) of this leaf's value (0 => value not stored here)
        f4 = node id (monotonic 1..N); used as the field-name key
    The schema UNROLLS every array element as its own descriptor triple
    (slaveAddr / registerData / delayUs ...), so each register write has a
    dedicated id.
  - VALUE segment ("POOL") begins right after the last schema record.
    A leaf's value = little-endian u64 at POOL + f2 (for f3==8).
    Composite headers hold [id, x, 1, firstChildId].

NOTE: the binarydumper reuses the generic {slaveAddr, registerData, delayUs}
triple names for EEPROM MemoryMapInfo, so the 3rd ("delayUs") slot actually
carries the I2C slave address there (constant 0x7C).

Usage: python3 parse_sensormodule.py <file.bin>
Facts only; do NOT commit the .bin (repos are public/blob-free).
"""
import struct, sys

def load(path):
    f = open(path, 'rb').read()
    off = 240
    id2rec = {}
    recs = []
    while off + 72 <= len(f):
        rec = f[off:off+72]
        name = rec[:32].split(b'\0')[0]
        if not name or any(b > 127 for b in name):
            break
        try:
            nm = name.decode('ascii')
        except UnicodeDecodeError:
            break
        fl = struct.unpack('<5Q', rec[32:72])
        recs.append((fl[4], nm, fl))
        id2rec[fl[4]] = (nm, fl)
        off += 72
    return f, off, recs, id2rec   # off == POOL base

def val(f, POOL, o):
    return struct.unpack('<Q', f[POOL+o:POOL+o+8])[0]

if __name__ == '__main__':
    path = sys.argv[1] if len(sys.argv) > 1 else 'com.qti.sensormodule.metric_imx363.bin'
    f, POOL, recs, id2rec = load(path)
    print(f"schema records: {len(recs)}   VALUE pool base: {POOL:#x}   max id: {max(id2rec)}")

    # --- top-level driver slaveInfo: [4]=8-bit slave addr (7-bit = >>1) ---
    # top-level records are the first entries; their f2 is the struct offset in POOL.
    for tid, nm, fl in recs:
        if nm in ('sensorDriverData', 'actuatorDriver', 'EEPROMDriverData',
                  'OISDriver') and fl[2] is not None and fl[3]:
            s8 = val(f, POOL, fl[2] + 4*8)
            print(f"{nm:16s} slave 8-bit {s8:#04x} -> 7-bit {s8>>1:#04x}")

    # --- actuator registerParam (the only one in the module) ---
    rp = [i for i,(n,fl) in id2rec.items() if n == 'registerParam']
    for i in rp:
        n, fl = id2rec[i]
        n_u64 = max(1, fl[3]//8)
        vals = [val(f, POOL, fl[2]+k*8) for k in range(n_u64)]
        print(f"actuator registerParam id{i:#x} @off {fl[2]:#x}: {[hex(x) for x in vals]}")

    # --- EEPROM MemoryMap: walk slaveAddr/registerData/delayUs leaves ---
    # find the first EEPROM slaveAddr leaf (size 8)
    eep0 = next((i for i,(n,fl) in sorted(id2rec.items())
                 if n=='slaveAddr' and fl[3]==8), None)
    if eep0:
        i = eep0; cnt = 0; slaves = set()
        while i in id2rec and id2rec[i][0] == 'slaveAddr':
            slaves.add(val(f, POOL, id2rec[i+2][1][2]))   # 3rd slot = real slave
            cnt += 1; i += 3
        print(f"EEPROM memmap entries: {cnt}  distinct slave-slot values: "
              f"{sorted(hex(x) for x in slaves)}")
