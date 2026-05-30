#!/bin/sh
# WCN3990 WiFi: ath10k_snoc must probe EXACTLY ONCE, after the WLAN firmware QMI
# service (WLFW) is up - else the WLAN PD rejects the host-cap (rejected: 90).
# So ath10k_snoc is blacklisted from autoload; load it here after WLFW appears.
RP=/sys/class/remoteproc/remoteproc2
[ "$(cat $RP/state 2>/dev/null)" = running ] || { echo start > $RP/state; sleep 6; }
for i in $(seq 1 45); do
  timeout 3 qrtr-lookup 2>/dev/null | grep -qi "ATH10k WLAN firmware" && break
  sleep 1
done
modprobe ath10k_snoc 2>/dev/null
