#!/usr/bin/env python3
"""loc-follow: persistent QMI LOC client for sunfish (Pixel 4a mainline).

Owns ONE Qmi.Device + ONE LOC client through the whole
start -> register -> listen lifecycle in a single process/MainLoop --
the thing qmicli structurally cannot do (a LOC session dies with the
client that started it). See ../../../DEBUG-gps.md.

Sequence (mirrors ModemManager's mm-shared-qmi.c order):
  open(PROXY) -> allocate LOC client -> SET_ENGINE_LOCK=none
  -> SET_NMEA_TYPES=all -> START(session 0x10) -> REGISTER_EVENTS
  -> print indications until --seconds elapses or SIGINT.

Modes:
  (default)      diagnostic: run for --seconds, print indications, exit.
  --serve        long-running daemon: run the real engine forever and fan
                 every NMEA sentence out to all connected unix + tcp clients
                 (geoclue [network-nmea] dials the unix socket; gpsd the tcp).
  --test-fix L,L synthetic: no QMI at all -- serve a valid 1 Hz GGA/RMC stream
                 for LAT,LON on the same sockets. The indoor end-to-end proof.
"""
import argparse
import datetime
import os
import signal
import sys

import gi
gi.require_version("Qmi", "1.0")
gi.require_version("Qrtr", "1.0")
from gi.repository import Qmi, Qrtr, GLib, Gio  # noqa: E402

DEFAULT_LOC_SESSION_ID = 0x10  # MM's DEFAULT_LOC_SESSION_ID; NOT 0 (qmicli untested)


def ts():
    return datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]


def log(msg):
    print(f"[{ts()}] {msg}", flush=True)


def opt(obj, name):
    """Read an optional TLV getter. libqmi getters return (ok, value)."""
    fn = getattr(obj, name, None)
    if fn is None:
        return None
    try:
        r = fn()
    except Exception:
        return None
    if isinstance(r, tuple):
        return r[1] if r and r[0] and len(r) > 1 else None
    return r


def nmea_checksum(body):
    """XOR of every char between '$' and '*' (body excludes both)."""
    cs = 0
    for ch in body:
        cs ^= ord(ch)
    return f"{cs:02X}"


def nmea_sentence(body):
    return f"${body}*{nmea_checksum(body)}"


def synth_nmea(lat, lon):
    """A valid GGA + RMC pair for lat,lon at the current UTC second."""
    now = datetime.datetime.now(datetime.timezone.utc)
    hhmmss = now.strftime("%H%M%S.00")
    ddmmyy = now.strftime("%d%m%y")

    def dm(v, deg_width):
        hemi_pos = v >= 0
        v = abs(v)
        d = int(v)
        m = (v - d) * 60.0
        return f"{d:0{deg_width}d}{m:07.4f}", hemi_pos

    lat_s, lat_pos = dm(lat, 2)
    lon_s, lon_pos = dm(lon, 3)
    ns = "N" if lat_pos else "S"
    ew = "E" if lon_pos else "W"
    # GGA: fix quality 1, 8 sats, HDOP 0.9, alt 280m, geoid 45m
    gga = nmea_sentence(
        f"GPGGA,{hhmmss},{lat_s},{ns},{lon_s},{ew},1,08,0.9,280.0,M,45.0,M,,")
    # RMC: status A(valid), speed 0.0kn, course 0.0, mode A(autonomous)
    rmc = nmea_sentence(
        f"GPRMC,{hhmmss},A,{lat_s},{ns},{lon_s},{ew},0.0,0.0,{ddmmyy},,,A")
    return [gga, rmc]


class NmeaFanout:
    """Server on an AF_UNIX and an AF_INET(127.0.0.1) listener. Every NMEA
    sentence is written (CRLF-terminated) to all currently-connected clients;
    a client coming or going never disturbs the others or the daemon."""

    def __init__(self, unix_path, tcp_port):
        self.conns = set()
        self.service = Gio.SocketService.new()
        self.service.connect("incoming", self._on_incoming)
        if unix_path:
            try:
                if os.path.exists(unix_path):
                    os.unlink(unix_path)  # /run is tmpfs but survives daemon restart
            except OSError as e:
                log(f"WARN: could not unlink stale {unix_path}: {e}")
            addr = Gio.UnixSocketAddress.new(unix_path)
            self.service.add_address(addr, Gio.SocketType.STREAM,
                                     Gio.SocketProtocol.DEFAULT, None)
            os.chmod(unix_path, 0o666)  # geoclue runs as its own unpriv user
            log(f"unix listener: {unix_path} (0666)")
        if tcp_port:
            iaddr = Gio.InetSocketAddress.new_from_string("127.0.0.1", tcp_port)
            self.service.add_address(iaddr, Gio.SocketType.STREAM,
                                     Gio.SocketProtocol.TCP, None)
            log(f"tcp listener: 127.0.0.1:{tcp_port}")
        self.service.start()

    def _on_incoming(self, _service, conn, _src):
        self.conns.add(conn)
        try:
            peer = conn.get_remote_address()
        except GLib.Error:
            peer = None
        log(f"client connected ({peer}); {len(self.conns)} now")
        return True  # keep the connection open; we own its lifetime

    def broadcast(self, line):
        data = (line.rstrip("\r\n") + "\r\n").encode()
        dead = []
        for c in self.conns:
            # ponytail: sync write; NMEA is a few tiny lines/sec on loopback,
            # so a full send buffer (=> block) is not a realistic concern.
            try:
                c.get_output_stream().write_all(data, None)
            except GLib.Error:
                dead.append(c)
        for c in dead:
            self.conns.discard(c)
            try:
                c.close(None)
            except GLib.Error:
                pass
        if dead:
            log(f"dropped {len(dead)} disconnected client(s); {len(self.conns)} left")


class TestFixServer:
    """Synthetic mode: no QMI. Serve a valid GGA/RMC stream at 1 Hz for a
    fixed coordinate. This is the indoor end-to-end proof for geoclue."""

    def __init__(self, lat, lon, unix_path, tcp_port):
        self.lat, self.lon = lat, lon
        self.unix_path, self.tcp_port = unix_path, tcp_port
        self.loop = GLib.MainLoop()

    def run(self):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, self._quit)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, self._quit)
        self.fanout = NmeaFanout(self.unix_path, self.tcp_port)
        log(f"TEST-FIX serving synthetic {self.lat},{self.lon} at 1 Hz")
        GLib.timeout_add_seconds(1, self._tick)
        self.loop.run()
        return 0

    def _tick(self):
        for s in synth_nmea(self.lat, self.lon):
            self.fanout.broadcast(s)
        return GLib.SOURCE_CONTINUE

    def _quit(self):
        log("signal -> stopping test-fix server")
        self.loop.quit()
        return GLib.SOURCE_REMOVE


class LocFollow:
    def __init__(self, seconds, verbose, serve=False,
                 unix_path=None, tcp_port=0):
        self.seconds = seconds
        self.verbose = verbose
        self.serve = serve
        self.unix_path = unix_path
        self.tcp_port = tcp_port
        self.fanout = None
        self.loop = GLib.MainLoop()
        self.bus = None
        self.device = None
        self.client = None
        self.stopping = False
        self.rc = 1

    # ---- lifecycle ----
    def run(self):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, self.on_sigint)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, self.on_sigint)
        if self.serve:
            # bring listeners up first so geoclue/gpsd can connect any time,
            # even before / independent of the engine producing sentences.
            self.fanout = NmeaFanout(self.unix_path, self.tcp_port)
        ok, self.node_id = Qrtr.get_node_for_uri("qrtr://0")
        if not ok:
            log("FATAL: couldn't parse qrtr://0")
            return 1
        log(f"looking up QRTR node {self.node_id} ...")
        Qrtr.Bus.new(5000, None, self.on_bus)
        self.loop.run()
        return self.rc

    def fail(self, what, err):
        log(f"FATAL: {what}: {err}")
        self.rc = 1
        self.shutdown()

    def on_bus(self, _src, res):
        try:
            self.bus = Qrtr.Bus.new_finish(res)
        except GLib.Error as e:
            return self.fail("Qrtr.Bus.new", e.message)
        node = self.bus.get_node(self.node_id)
        if node is None:
            return self.fail("bus.get_node", f"no node {self.node_id} on the qrtr bus")
        log(f"got QRTR node {self.node_id}; creating QMI device ...")
        Qmi.Device.new_from_node(node, None, self.on_new)

    def on_new(self, _src, res):
        try:
            self.device = Qmi.Device.new_from_node_finish(res)
        except GLib.Error as e:
            return self.fail("Device.new_from_node", e.message)
        # QRTR multiplexes clients in the kernel router; no qmi-proxy involved.
        self.device.open(Qmi.DeviceOpenFlags.EXPECT_INDICATIONS, 15, None, self.on_open)

    def on_open(self, _src, res):
        try:
            self.device.open_finish(res)
        except GLib.Error as e:
            return self.fail("Device.open", e.message)
        log("device open; allocating LOC client ...")
        self.device.allocate_client(Qmi.Service.LOC, Qmi.CID_NONE, 15, None, self.on_alloc)

    def on_alloc(self, _src, res):
        try:
            self.client = self.device.allocate_client_finish(res)
        except GLib.Error as e:
            return self.fail("allocate_client(LOC)", e.message)
        log(f"LOC client allocated, CID={self.client.get_cid()}")
        self.set_engine_lock()

    # ---- step 1: engine lock = none (NO_PERMISSION tolerated) ----
    def set_engine_lock(self):
        i = Qmi.MessageLocSetEngineLockInput.new()
        i.set_lock_type(Qmi.LocLockType.NONE)
        self.client.set_engine_lock(i, 10, None, self.on_engine_lock)

    def on_engine_lock(self, _src, res):
        try:
            out = self.client.set_engine_lock_finish(res)
            out.get_result()  # raises on error
            log("SET_ENGINE_LOCK=none: OK")
        except GLib.Error as e:
            log(f"SET_ENGINE_LOCK=none: non-fatal ({e.message})")
        self.set_nmea_types()

    # ---- step 2: nmea types = all ----
    def set_nmea_types(self):
        i = Qmi.MessageLocSetNmeaTypesInput.new()
        t = Qmi.LocNmeaType
        all_types = (t.GGA | t.RMC | t.GSV | t.GSA | t.VTG | t.PQXFI | t.PSTIS)
        i.set_nmea_types(all_types)
        self.client.set_nmea_types(i, 10, None, self.on_nmea_types)

    def on_nmea_types(self, _src, res):
        try:
            self.client.set_nmea_types_finish(res).get_result()
            log("SET_NMEA_TYPES=all: OK")
        except GLib.Error as e:
            log(f"SET_NMEA_TYPES=all: non-fatal ({e.message})")
        self.start()

    # ---- step 3: START (session 0x10) then REGISTER (MM order) ----
    def start(self):
        i = Qmi.MessageLocStartInput.new()
        i.set_session_id(DEFAULT_LOC_SESSION_ID)
        i.set_fix_recurrence_type(Qmi.LocFixRecurrenceType.PERIODIC_FIXES)
        i.set_minimum_interval_between_position_reports(1000)
        i.set_intermediate_report_state(Qmi.LocIntermediateReportState.DISABLE)
        self.client.start(i, 10, None, self.on_start)

    def on_start(self, _src, res):
        try:
            self.client.start_finish(res).get_result()
            log("START(session=0x10, periodic, 1000ms): >>> SUCCESS <<<")
        except GLib.Error as e:
            return self.fail("START", e.message)  # START failing is a real finding
        self.register_events()

    def register_events(self):
        i = Qmi.MessageLocRegisterEventsInput.new()
        f = Qmi.LocEventRegistrationFlag
        mask = (f.NMEA | f.POSITION_REPORT | f.GNSS_SATELLITE_INFO | f.ENGINE_STATE)
        i.set_event_registration_mask(mask)
        self.client.register_events(i, 10, None, self.on_register)

    def on_register(self, _src, res):
        try:
            self.client.register_events_finish(res).get_result()
            log("REGISTER_EVENTS(nmea|position|sv|engine): >>> SUCCESS <<<")
        except GLib.Error as e:
            return self.fail("REGISTER_EVENTS", e.message)
        # both control-plane calls succeeded; now listen.
        self.client.connect("nmea", self.on_ind_nmea)
        self.client.connect("position-report", self.on_ind_position)
        self.client.connect("gnss-sv-info", self.on_ind_sv)
        self.client.connect("engine-state", self.on_ind_engine)
        self.rc = 0  # start+register proven; success bar for the pipeline
        if self.serve:
            log("SERVE: engine running; fanning NMEA to clients forever "
                "(indoors: NMEA/SV at best, likely silence) ...")
            return  # run forever; no shutdown timer
        log(f"listening for indications for {self.seconds}s "
            f"(indoors: NMEA/SV at best, likely silence) ...")
        GLib.timeout_add_seconds(self.seconds, self.on_timeout)

    # ---- indications ----
    def on_ind_nmea(self, _client, out):
        s = opt(out, "get_nmea_string")
        if s is not None:
            if self.fanout is not None:
                self.fanout.broadcast(s)
            log(f"NMEA: {s.rstrip()}")

    def on_ind_position(self, _client, out):
        status = opt(out, "get_session_status")
        lat = opt(out, "get_latitude")
        lon = opt(out, "get_longitude")
        used = opt(out, "get_satellites_used")
        log(f"POSITION: status={status} lat={lat} lon={lon} sats_used={used}")

    def on_ind_sv(self, _client, out):
        lst = opt(out, "get_list")
        n = len(lst) if lst is not None else 0
        log(f"SV-INFO: satellites-in-view={n}")
        if self.verbose and lst:
            for sv in lst:
                log(f"    sv={sv}")

    def on_ind_engine(self, _client, out):
        st = opt(out, "get_engine_state")
        log(f"ENGINE-STATE: {st}")

    # ---- shutdown ----
    def on_sigint(self):
        log("SIGINT/SIGTERM -> shutting down")
        self.shutdown()
        return GLib.SOURCE_REMOVE

    def on_timeout(self):
        log(f"--seconds {self.seconds} elapsed -> shutting down")
        self.shutdown()
        return GLib.SOURCE_REMOVE

    def shutdown(self):
        if self.stopping:
            return
        self.stopping = True
        if self.client is not None:
            i = Qmi.MessageLocStopInput.new()
            i.set_session_id(DEFAULT_LOC_SESSION_ID)
            self.client.stop(i, 10, None, self.on_stop)
        else:
            self.quit()

    def on_stop(self, _src, res):
        try:
            self.client.stop_finish(res).get_result()
            log("STOP: OK")
        except GLib.Error as e:
            log(f"STOP: {e.message}")
        try:
            self.device.release_client(
                self.client, Qmi.DeviceReleaseClientFlags.RELEASE_CID,
                10, None, self.on_release)
        except Exception as e:
            log(f"release_client dispatch failed: {e}")
            self.quit()

    def on_release(self, _src, res):
        try:
            self.device.release_client_finish(res)
            log("client released")
        except GLib.Error as e:
            log(f"release_client: {e.message}")
        self.quit()

    def quit(self):
        if self.loop.is_running():
            self.loop.quit()


def main():
    ap = argparse.ArgumentParser(description="persistent QMI LOC client (sunfish GNSS)")
    ap.add_argument("--seconds", type=int, default=120, help="diagnostic listen duration (default 120)")
    ap.add_argument("--verbose", action="store_true", help="dump per-SV detail")
    ap.add_argument("--serve", action="store_true",
                    help="run forever; fan NMEA to unix + tcp clients (geoclue/gpsd)")
    ap.add_argument("--nmea-socket", default="/run/gps-share.sock",
                    help="unix listener path (default /run/gps-share.sock)")
    ap.add_argument("--tcp-port", type=int, default=5000,
                    help="tcp listener port on 127.0.0.1; 0 disables (default 5000)")
    ap.add_argument("--test-fix", metavar="LAT,LON",
                    help="synthetic mode: serve a 1 Hz GGA/RMC stream for LAT,LON (no QMI)")
    args = ap.parse_args()

    if args.test_fix:
        lat, lon = (float(x) for x in args.test_fix.split(","))
        sys.exit(TestFixServer(lat, lon, args.nmea_socket, args.tcp_port).run())

    sys.exit(LocFollow(args.seconds, args.verbose, serve=args.serve,
                       unix_path=args.nmea_socket, tcp_port=args.tcp_port).run())


if __name__ == "__main__":
    main()
