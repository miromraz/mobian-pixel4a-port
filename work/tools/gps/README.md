# loc-follow

A small persistent QMI **LOC** (GNSS) client for the Pixel 4a (`sunfish`) mainline
Linux port. It owns **one** `Qmi.Device` and **one** allocated LOC client through the
whole `open → set-engine-lock → set-nmea-types → start → register-events → listen`
lifecycle inside a single `GLib.MainLoop` — the thing `qmicli` structurally cannot do
(a LOC session dies with the client/process that started it). This is the only route
to getting GNSS indications off this device. Background: `../../../DEBUG-gps.md`.

Python 3 + `gi` only (`python3-gi`, `gir1.2-qmi-1.0` 1.38, `libqmi-glib5` 1.38 — all
already installed on the phone from forky). Diagnostic tool, not production.

## Run (on the phone)

    ssh mobian@172.16.42.1
    python3 ~/loc-follow.py --seconds 120        # --verbose for per-satellite detail

It prints the **Start** and **Register** results explicitly (control-plane vs
data-plane discriminator), then every indication with a timestamp: raw NMEA
sentences verbatim, position reports (lat/lon/fix-status even when invalid), and
satellites-in-view counts. On SIGINT or after `--seconds`, it does LOC **Stop**,
releases the client, and exits cleanly. Indoors, expect `$GPGSV` at best, likely
silence — proving the *pipeline* does not need a fix.

## Daemon / desktop-location mode

`--serve` runs the same LOC lifecycle forever and fans every NMEA sentence out
(CRLF-terminated) to all connected clients on two listeners:

* an **AF_UNIX** socket (`--nmea-socket`, default `/run/gps-share.sock`, mode
  0666) — geoclue's `[network-nmea]` source dials in here as a client;
* an **AF_INET** socket (`--tcp-port`, default `5000` on 127.0.0.1; `0`
  disables) — gpsd dials in here via `DEVICES="tcp://127.0.0.1:5000"`.

Clients coming and going never disturb the engine or each other.

    /usr/local/bin/loc-follow.py --serve                 # real engine
    /usr/local/bin/loc-follow.py --test-fix "50.0755,14.4378"   # synthetic

`--test-fix "LAT,LON"` skips QMI entirely and serves a valid 1 Hz `$GPGGA` +
`$GPRMC` stream (correct NMEA checksum, live UTC) for that coordinate — the
indoor end-to-end proof that engine->socket->geoclue->D-Bus works with no sky.

Installed pieces (see `../../../DEBUG-gps.md` for the deploy map):
`/usr/local/bin/loc-follow.py`, `gps-nmea.service` (runs `--serve`),
`/etc/default/gpsd` (optional gpsd path), and the additive `[network-nmea]`
+ `[gps-test]` edits to `/etc/geoclue/geoclue.conf`.

## Deploy (from repo root)

    tar cz -C work/tools/gps loc-follow.py | ssh mobian@172.16.42.1 'tar xz -C ~'   # diagnostic only

For the full desktop-location install, copy each file to its explicit path
(never a top-level `lib/` tar member) — see DEBUG-gps.md.
