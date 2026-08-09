#!/usr/bin/env python3
"""Inject Qualcomm gpsOneXTRA predicted-orbit data into the sunfish GNSS engine.

Without this the receiver has NO ephemeris/almanac at all (validity reads
1980-01-06, 0 hours) and every acquisition is a blind cold search, which cannot
pull in satellites at the low C/N0 you get indoors or at a window.

Opens via the Qrtr node route (NOT a GFile "qrtr://0", NOT DeviceOpenFlags.PROXY
-- both fail on QRTR; see loc-follow.py).

usage: xtra-inject.py <xtra.bin> [chunk_bytes]
"""
import sys, gi
gi.require_version('Qmi', '1.0'); gi.require_version('Qrtr', '1.0')
from gi.repository import Qmi, Qrtr, GLib

PATH = sys.argv[1]
CHUNK = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
DATA = open(PATH, 'rb').read()
PARTS = (len(DATA) + CHUNK - 1) // CHUNK

def log(m): print(m, flush=True)

class Inj:
    def __init__(self):
        self.loop = GLib.MainLoop(); self.rc = 1; self.part = 0
    def run(self):
        ok, self.node_id = Qrtr.get_node_for_uri("qrtr://0")
        if not ok: log("FATAL: bad uri"); return 1
        Qrtr.Bus.new(5000, None, self.on_bus)
        GLib.timeout_add_seconds(180, self.timeout)
        self.loop.run(); return self.rc
    def timeout(self):
        log(f"TIMEOUT at part {self.part}/{PARTS}"); self.loop.quit(); return False
    def fail(self, w, e): log(f"FATAL {w}: {e}"); self.loop.quit()
    def on_bus(self, _s, res):
        try: self.bus = Qrtr.Bus.new_finish(res)
        except GLib.Error as e: return self.fail("bus", e.message)
        node = self.bus.get_node(self.node_id)
        if node is None: return self.fail("node", "missing")
        Qmi.Device.new_from_node(node, None, self.on_new)
    def on_new(self, _s, res):
        try: self.dev = Qmi.Device.new_from_node_finish(res)
        except GLib.Error as e: return self.fail("new_from_node", e.message)
        self.dev.open(Qmi.DeviceOpenFlags.EXPECT_INDICATIONS, 15, None, self.on_open)
    def on_open(self, _s, res):
        try: self.dev.open_finish(res)
        except GLib.Error as e: return self.fail("open", e.message)
        self.dev.allocate_client(Qmi.Service.LOC, Qmi.CID_NONE, 15, None, self.on_alloc)
    def on_alloc(self, _s, res):
        try: self.cli = self.dev.allocate_client_finish(res)
        except GLib.Error as e: return self.fail("alloc LOC", e.message)
        log(f"LOC client CID={self.cli.get_cid()}; {len(DATA)} bytes in {PARTS} parts of {CHUNK}")
        self.cli.connect('inject-xtra-data', self.on_ind)
        self.send(1)
    def send(self, n):
        self.part = n
        off = (n - 1) * CHUNK
        i = Qmi.MessageLocInjectXtraDataInput.new()
        i.set_total_size(len(DATA))
        i.set_total_parts(PARTS)
        i.set_part_number(n)
        i.set_part_data(list(DATA[off:off + CHUNK]))
        self.cli.inject_xtra_data(i, 20, None, self.on_ack, None)
    def on_ack(self, cli, res, _):
        try: cli.inject_xtra_data_finish(res).get_result()
        except GLib.Error as e: return self.fail(f"ack part {self.part}", e.message)
    def on_ind(self, cli, out):
        st = None
        try: st = out.get_indication_status()
        except Exception: pass
        if self.part % 10 == 0 or self.part in (1, PARTS):
            log(f"  part {self.part}/{PARTS} status={st}")
        if st not in (None, Qmi.LocIndicationStatus.SUCCESS):
            log(f"FAILED at part {self.part}: {st}"); return self.loop.quit()
        if self.part >= PARTS:
            log("ALL PARTS INJECTED"); self.rc = 0; return self.loop.quit()
        self.send(self.part + 1)

sys.exit(Inj().run())
