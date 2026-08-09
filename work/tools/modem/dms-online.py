#!/usr/bin/env python3
"""dms-online: persistent QMI DMS client that replicates qcril's readiness
sequence to try to bring the sunfish modem online, breaking the mainline
`--dms-set-operating-mode=online` -> DeviceNotReady (QMI err 52) wall.

ONE Qmi.Device + ONE DMS client for the whole lifecycle in one MainLoop --
the thing qmicli can't do (its client dies with the process, so any state the
modem streams to "the client that owns power" never reaches the set request).
See ../../../DEBUG-modem-online.md and android-capture CAPTURE_FINDINGS.md.

Sequence (mirrors qcril_qmi_dms_init + radio-power gate):
  open(EXPECT_INDICATIONS) -> allocate DMS client
  -> set_event_report (register for op-mode + related state indications)
  -> connect "event-report" indication, log everything
  -> get_operating_mode (expect 'offline')
  -> [optionally wait for first event-report indication = modem streaming to us]
  -> set_operating_mode(ONLINE); report SUCCESS vs DeviceNotReady literally
  -> if that fails, replicate qcril's two-step: set LOW_POWER then ONLINE
  -> poll get_operating_mode a few times; keep listening.
On exit / SIGINT / failure: set operating mode back to OFFLINE (baseline).

qrtr:// open pattern is copied verbatim from tools/gps/loc-follow.py (proven):
NOT DeviceOpenFlags.PROXY, NOT a GFile URI.
"""
import argparse
import datetime
import signal
import sys

import gi
gi.require_version("Qmi", "1.0")
gi.require_version("Qrtr", "1.0")
from gi.repository import Qmi, Qrtr, GLib  # noqa: E402


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


class DmsOnline:
    def __init__(self, seconds, wait_ind, all_fields, two_step, retry_delay):
        self.seconds = seconds
        self.wait_ind = wait_ind        # secs to wait for 1st indication pre-online (0=skip)
        self.all_fields = all_fields    # enable every SetEventReport field, else op-mode only
        self.two_step = two_step        # try LOW_POWER then ONLINE if direct ONLINE fails
        self.retry_delay = retry_delay  # secs before a second ONLINE attempt
        self.loop = GLib.MainLoop()
        self.bus = None
        self.device = None
        self.client = None
        self.node_id = None
        self.got_indication = False
        self.online_ok = False
        self.stopping = False
        self.rc = 1

    # ---- lifecycle ----
    def run(self):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, self.on_sigint)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, self.on_sigint)
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
        self.device.open(Qmi.DeviceOpenFlags.EXPECT_INDICATIONS, 15, None, self.on_open)

    def on_open(self, _src, res):
        try:
            self.device.open_finish(res)
        except GLib.Error as e:
            return self.fail("Device.open", e.message)
        log("device open; allocating DMS client ...")
        self.device.allocate_client(Qmi.Service.DMS, Qmi.CID_NONE, 15, None, self.on_alloc)

    def on_alloc(self, _src, res):
        try:
            self.client = self.device.allocate_client_finish(res)
        except GLib.Error as e:
            return self.fail("allocate_client(DMS)", e.message)
        log(f"DMS client allocated, CID={self.client.get_cid()}")
        # connect the SetEventReport indication before registering for it
        try:
            self.client.connect("event-report", self.on_event_report)
            log("connected 'event-report' indication signal")
        except Exception as e:
            log(f"WARN: could not connect 'event-report' ({e}); polling only")
        self.set_event_report()

    # ---- step 1: DMS set_event_report (qcril_qmi_dms_init) ----
    def set_event_report(self):
        i = Qmi.MessageDmsSetEventReportInput.new()
        i.set_operating_mode_reporting(True)
        fields = ["operating_mode"]
        if self.all_fields:
            i.set_activation_state_reporting(True)
            i.set_pin_state_reporting(True)
            i.set_power_state_reporting(True)
            i.set_prl_init_reporting(True)
            i.set_uim_state_reporting(True)
            i.set_wireless_disable_state_reporting(True)
            fields += ["activation", "pin", "power", "prl", "uim", "wireless_disable"]
        log(f"SET_EVENT_REPORT fields={fields}")
        self.client.set_event_report(i, 10, None, self.on_set_event_report)

    def on_set_event_report(self, _src, res):
        try:
            self.client.set_event_report_finish(res).get_result()
            log("SET_EVENT_REPORT: OK")
        except GLib.Error as e:
            log(f"SET_EVENT_REPORT: non-fatal ({e.message})")
        self.get_op_mode(self.after_first_get)

    # ---- step 2: get_operating_mode (expect offline) ----
    def get_op_mode(self, cb):
        self.client.get_operating_mode(None, 10, None,
                                       lambda s, r: self._on_get_op_mode(r, cb))

    def _on_get_op_mode(self, res, cb):
        mode = None
        try:
            out = self.client.get_operating_mode_finish(res)
            out.get_result()
            mode = opt(out, "get_mode")
            reason = opt(out, "get_offline_reason")
            log(f"GET_OPERATING_MODE: mode={mode} offline_reason={reason}")
        except GLib.Error as e:
            log(f"GET_OPERATING_MODE: error ({e.message})")
        if cb:
            cb(mode)

    def after_first_get(self, _mode):
        # readiness gate: optionally wait for the modem to stream us an
        # event-report indication (proof it treats us as the power owner)
        # before firing ONLINE -- variant (a).
        if self.wait_ind > 0:
            log(f"waiting up to {self.wait_ind}s for first DMS event-report "
                f"indication before ONLINE ...")
            self._gate_deadline = self.wait_ind
            GLib.timeout_add_seconds(1, self._gate_tick)
        else:
            self.set_online(first=True)

    def _gate_tick(self):
        if self.got_indication:
            log("gate: indication received -> proceeding to ONLINE")
            self.set_online(first=True)
            return GLib.SOURCE_REMOVE
        self._gate_deadline -= 1
        if self._gate_deadline <= 0:
            log("gate: no indication within window -> proceeding to ONLINE anyway")
            self.set_online(first=True)
            return GLib.SOURCE_REMOVE
        return GLib.SOURCE_CONTINUE

    # ---- step 3: set_operating_mode(ONLINE) -- THE test ----
    def set_online(self, first):
        i = Qmi.MessageDmsSetOperatingModeInput.new()
        i.set_mode(Qmi.DmsOperatingMode.ONLINE)
        tag = "first" if first else "retry"
        log(f">>> SET_OPERATING_MODE(ONLINE) [{tag}] sending ...")
        self.client.set_operating_mode(
            i, 15, None, lambda s, r: self.on_set_online(r, first))

    def on_set_online(self, res, first):
        try:
            self.client.set_operating_mode_finish(res).get_result()
            self.online_ok = True
            self.rc = 0
            log("<<< SET_OPERATING_MODE(ONLINE): >>> SUCCESS <<<")
            self.get_op_mode(None)
            self.begin_poll()
            return
        except GLib.Error as e:
            log(f"<<< SET_OPERATING_MODE(ONLINE): FAILED err={e.code} ({e.message})")
        # failure path
        if first and self.two_step:
            log("two-step: modem rejected direct ONLINE; trying LOW_POWER first "
                "(qcril set op-mode 1 then 0) ...")
            self.set_low_power()
        elif first and self.retry_delay > 0:
            log(f"retry: will resend ONLINE in {self.retry_delay}s (variant c)")
            GLib.timeout_add_seconds(self.retry_delay,
                                     lambda: (self.set_online(first=False),
                                              GLib.SOURCE_REMOVE)[1])
        else:
            log("no more ONLINE strategies; listening for indications then exit")
            self.begin_poll()

    def set_low_power(self):
        i = Qmi.MessageDmsSetOperatingModeInput.new()
        i.set_mode(Qmi.DmsOperatingMode.LOW_POWER)
        log(">>> SET_OPERATING_MODE(LOW_POWER) sending ...")
        self.client.set_operating_mode(i, 15, None, self.on_set_low_power)

    def on_set_low_power(self, _src, res):
        try:
            self.client.set_operating_mode_finish(res).get_result()
            log("SET_OPERATING_MODE(LOW_POWER): OK")
        except GLib.Error as e:
            log(f"SET_OPERATING_MODE(LOW_POWER): FAILED err={e.code} ({e.message})")
        # then, after a beat, ONLINE again
        d = max(self.retry_delay, 2)
        log(f"two-step: sending ONLINE again in {d}s ...")
        GLib.timeout_add_seconds(
            d, lambda: (self.set_online(first=False), GLib.SOURCE_REMOVE)[1])

    # ---- step 4: poll op-mode + keep listening ----
    def begin_poll(self):
        self._polls_left = 4
        GLib.timeout_add_seconds(2, self._poll_tick)
        log(f"listening for indications for {self.seconds}s ...")
        GLib.timeout_add_seconds(self.seconds, self.on_timeout)

    def _poll_tick(self):
        self.get_op_mode(None)
        self._polls_left -= 1
        return GLib.SOURCE_CONTINUE if self._polls_left > 0 else GLib.SOURCE_REMOVE

    # ---- indications ----
    def on_event_report(self, _client, out):
        self.got_indication = True
        mode = opt(out, "get_operating_mode")
        power = opt(out, "get_power_state")
        pin1 = opt(out, "get_pin1_status")
        log(f"EVENT-REPORT: operating_mode={mode} power_state={power} pin1={pin1}")

    # ---- shutdown (restore OFFLINE baseline) ----
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
        if self.client is not None and self.online_ok:
            # only restore baseline if WE changed it; leave a failed run as-is
            log("restoring baseline: SET_OPERATING_MODE(OFFLINE) ...")
            i = Qmi.MessageDmsSetOperatingModeInput.new()
            i.set_mode(Qmi.DmsOperatingMode.OFFLINE)
            self.client.set_operating_mode(i, 10, None, self.on_restore)
        elif self.client is not None:
            self.release()
        else:
            self.quit()

    def on_restore(self, _src, res):
        try:
            self.client.set_operating_mode_finish(res).get_result()
            log("restored OFFLINE")
        except GLib.Error as e:
            log(f"restore OFFLINE: {e.message}")
        self.release()

    def release(self):
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
            log("DMS client released")
        except GLib.Error as e:
            log(f"release_client: {e.message}")
        self.quit()

    def quit(self):
        if self.loop.is_running():
            self.loop.quit()


def main():
    ap = argparse.ArgumentParser(description="QMI DMS online bring-up experiment (sunfish)")
    ap.add_argument("--seconds", type=int, default=30,
                    help="listen duration after the set attempts (default 30)")
    ap.add_argument("--wait-ind", type=int, default=0,
                    help="secs to wait for first DMS event-report indication before "
                         "sending ONLINE (variant a; 0=send immediately)")
    ap.add_argument("--all-fields", action="store_true",
                    help="enable every SetEventReport field, not just operating-mode "
                         "(variant b)")
    ap.add_argument("--two-step", action="store_true",
                    help="if direct ONLINE fails, try LOW_POWER then ONLINE "
                         "(replicates qcril op-mode 1->0)")
    ap.add_argument("--retry-delay", type=int, default=0,
                    help="secs before a second ONLINE attempt after a failure "
                         "(variant c; 0=no retry)")
    args = ap.parse_args()
    sys.exit(DmsOnline(args.seconds, args.wait_ind, args.all_fields,
                       args.two_step, args.retry_delay).run())


if __name__ == "__main__":
    main()
