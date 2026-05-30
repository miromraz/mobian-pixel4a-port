#!/bin/sh
# WCN3990 BT has no NVM BD address -> hci0 unconfigured (DOWN RAW). Set a stable
# machine-id-derived address. btmgmt HANGS when stdin is /dev/null (systemd), so run it
# under a pseudo-tty via script(1). WCN3990 is a combo chip shared with WiFi: down/up
# exactly ONCE (cycling corrupts the WiFi side); only retry the btmgmt set.
for i in $(seq 1 60); do [ -e /sys/class/bluetooth/hci0 ] && break; sleep 1; done
[ -e /sys/class/bluetooth/hci0 ] || exit 0
# If the dtb already gave hci0 a valid BD address (local-bd-address), it comes up
# configured on its own -> nothing to do. This service is only the fallback.
sleep 5
hciconfig hci0 2>/dev/null | grep -q "UP RUNNING" && exit 0
MAC=$(cat /etc/machine-id | sha256sum | sed "s/^\(..\)\(..\)\(..\)\(..\)\(..\).*/02:\1:\2:\3:\4:\5/")
hciconfig hci0 down >/dev/null 2>&1
ok=0
for i in $(seq 1 30); do
  timeout 8 script -qec "btmgmt --index 0 public-addr $MAC" /dev/null </dev/null 2>&1 | grep -qi complete && { ok=1; break; }
  sleep 2
done
[ "$ok" = 1 ] && hciconfig hci0 up >/dev/null 2>&1
hciconfig hci0 2>/dev/null | grep -q "UP RUNNING"
