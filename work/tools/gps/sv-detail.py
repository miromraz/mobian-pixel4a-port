#!/usr/bin/env python3
"""Dump per-satellite GNSS detail (status + C/N0) from the sunfish LOC engine.

satellites-in-view can be almanac-derived; the only proof the RF front-end is
alive is a non-zero signal_to_noise_ratio_bhz or a SEARCHING/TRACKING status.
One client does lock->start->register->listen (a LOC session is bound to the
client that started it).
"""
import sys, gi
gi.require_version('Qmi', '1.0'); gi.require_version('Qrtr', '1.0')
from gi.repository import Qmi, Qrtr, GLib

SECS = int(sys.argv[1]) if len(sys.argv) > 1 else 60
SESSION = 0x10

def log(m): print(m, flush=True)

class SV:
    def __init__(self): self.loop = GLib.MainLoop(); self.best = {}; self.n = 0
    def run(self):
        ok, self.nid = Qrtr.get_node_for_uri("qrtr://0")
        Qrtr.Bus.new(5000, None, self.on_bus)
        GLib.timeout_add_seconds(SECS, self.finish)
        self.loop.run(); return 0
    def on_bus(self, _s, r):
        self.bus = Qrtr.Bus.new_finish(r)
        Qmi.Device.new_from_node(self.bus.get_node(self.nid), None, self.on_new)
    def on_new(self, _s, r):
        self.dev = Qmi.Device.new_from_node_finish(r)
        self.dev.open(Qmi.DeviceOpenFlags.EXPECT_INDICATIONS, 15, None, self.on_open)
    def on_open(self, _s, r):
        self.dev.open_finish(r)
        self.dev.allocate_client(Qmi.Service.LOC, Qmi.CID_NONE, 15, None, self.on_alloc)
    def on_alloc(self, _s, r):
        self.cli = self.dev.allocate_client_finish(r)
        self.cli.connect('gnss-sv-info', self.on_sv)
        i = Qmi.MessageLocSetEngineLockInput.new(); i.set_lock_type(Qmi.LocLockType.NONE)
        self.cli.set_engine_lock(i, 10, None, lambda c, rr: self.start())
    def start(self):
        i = Qmi.MessageLocStartInput.new()
        i.set_session_id(SESSION)
        try: i.set_intermediate_report_state(Qmi.LocIntermediateReportState.ENABLE)
        except Exception: pass
        try: i.set_minimum_interval_between_position_reports(1000)
        except Exception: pass
        self.cli.start(i, 10, None, lambda c, rr: self.reg())
    def reg(self):
        i = Qmi.MessageLocRegisterEventsInput.new()
        m = (Qmi.LocEventRegistrationFlag.POSITION_REPORT |
             Qmi.LocEventRegistrationFlag.GNSS_SATELLITE_INFO |
             Qmi.LocEventRegistrationFlag.NMEA |
             Qmi.LocEventRegistrationFlag.ENGINE_STATE)
        i.set_event_registration_mask(m)
        self.cli.register_events(i, 10, None, lambda c, rr: log("engine started, listening..."))
    def on_sv(self, cli, out):
        self.n += 1
        lst = out.get_list()
        if not lst: return
        if isinstance(lst, tuple): lst = lst[1]
        for e in lst:
            snr = getattr(e, 'signal_to_noise_ratio_bhz', 0) or 0
            st = getattr(e, 'satellite_status', None)
            sid = getattr(e, 'gnss_satellite_id', 0)
            k = (str(getattr(e, 'system', '?')), sid)
            prev = self.best.get(k, (0,))
            if snr >= prev[0]:
                self.best[k] = (snr, st, int(getattr(e,'valid_information',0) or 0),
                                getattr(e,'elevation_degrees',None), getattr(e,'azimuth_degrees',None),
                                getattr(e,'health_status',None))
    def finish(self):
        log(f"--- {self.n} SV indications over {SECS}s; {len(self.best)} distinct SVs ---")
        tracked = [(k, v) for k, v in self.best.items() if v[0] > 0]
        for k, v in sorted(self.best.items(), key=lambda x: -x[1][0])[:8]:
            log(f"  {k[0]:>3} id={k[1]:<4} peak_snr={v[0]:<7} status={v[1]} valid=0b{v[2]:08b} elev={v[3]} az={v[4]} health={v[5]}")
        log(f"RESULT: {len(tracked)} satellites with NON-ZERO C/N0")
        self.loop.quit(); return False

sys.exit(SV().run())
