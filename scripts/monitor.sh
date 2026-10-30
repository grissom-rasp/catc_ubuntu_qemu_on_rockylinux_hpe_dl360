#!/bin/bash
# monitor.sh — 15-minute steady-state sampling of the Rocky host and the Ubuntu guest.
# Runs from the laptop. Usage: ./scripts/monitor.sh [guest-ip] [minutes]
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
G=${1:?usage: monitor.sh <guest-ip> [minutes]}
MIN=${2:-15}
OUT="$HERE/logs/monitor-$(date +%Y%m%d-%H%M)"
mkdir -p "$OUT"

: > "$OUT/host.log"
: > "$OUT/guest.log"
echo "sampling $MIN min into $OUT (guest $G)"

HOST_CMD='
ts=$(date -Is)
echo "## $ts"
echo "load: $(cat /proc/loadavg)"
echo "vmstat: $(vmstat 1 2 | tail -1)"
awk "/MemTotal|MemAvailable|SwapFree|AnonHugePages|Dirty/{printf \"%s=%s \", \$1, \$2} END{print \"\"}" /proc/meminfo
printf "ksm_run=%s ksm_shared=%s\n" "$(cat /sys/kernel/mm/ksm/run 2>/dev/null)" "$(awk "/pages_shared/{print \$2}" /sys/kernel/mm/ksm/meminfo 2>/dev/null)"
for n in 0 1 2 3; do printf "node%s_memfree_kb=%s " "$n" "$(awk "/MemFree/{print \$4}" /sys/devices/system/node/node$n/meminfo 2>/dev/null)"; done; echo
virsh -c qemu:///system domstats ubuntu24 --state --cpu-total --balloon 2>/dev/null | tr "\n" " "; echo
grep -E "ens1f2|br0|virbr0" /proc/net/dev
cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io 2>/dev/null | tr "\n" ";"; echo
echo "failed_units=$(systemctl --failed --no-legend 2>/dev/null | wc -l) err_msgs_60s=$(journalctl -p err --since -60s --no-pager 2>/dev/null | wc -l)"
'

GUEST_CMD='
lsb=""; ts=$(date -Is)
echo "## $ts"
echo "load: $(cat /proc/loadavg)"
echo "vmstat: $(vmstat 1 2 | tail -1)"
awk "/MemTotal|MemAvailable|SwapFree/{printf \"%s=%s \", \$1, \$2} END{print \"\"}" /proc/meminfo
echo "disk: $(df -h / | tail -1)"
echo "failed_units=$(systemctl --failed --no-legend 2>/dev/null | wc -l) err_msgs_60s=$(journalctl -p err --since -60s --no-pager 2>/dev/null | wc -l)"
echo "kern_warn: $(journalctl -k -p warning --since -60s --no-pager 2>/dev/null | wc -l)"
echo "sockets: $(ss -s | awk "/TCP:/{print}")"
echo "net: $(ip -s link show enp1s0 | tail -3 | tr "\n" " ")"
'

for i in $(seq 1 $((MIN * 2))); do
    ssh -o BatchMode=yes -o ConnectTimeout=8 rocky-dl360 "$HOST_CMD" >>"$OUT/host.log" 2>&1
    ssh -o BatchMode=yes -o ConnectTimeout=8 "catc_ubuntu_kvm@$G" "$GUEST_CMD" >>"$OUT/guest.log" 2>&1
    sleep 30
done
echo "done: $OUT"
