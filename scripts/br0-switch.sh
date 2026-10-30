#!/bin/bash
# br0-switch.sh — convert the single cabled NIC (ens1f2) into a Linux bridge br0
# so KVM guests can sit directly on the 192.168.0.0/24 LAN and DHCP from the router.
#
# SAFETY: run detached via `systemd-run --collect` so an SSH drop cannot abort it.
# It asserts the bridge TOPOLOGY (port attached, br0 owns the IP, ens1f2 does not),
# not merely reachability, and auto-rolls-back on failure.
#
# Usage (as root):  systemd-run --unit=br0-switch --collect /usr/local/sbin/br0-switch.sh
# Log:              /var/log/br0-switch.log
# Manual rollback:  /usr/local/sbin/br0-rollback.sh

set -uo pipefail

IF=${IF:-ens1f2}
BR=${BR:-br0}
GW=${GW:-192.168.0.1}
DEADLINE=${DEADLINE:-120}   # seconds to reach a fully-formed bridge

LOG=/var/log/br0-switch.log
exec >>"$LOG" 2>&1
echo "=== $(date -Is) br0-switch start (if=$IF br=$BR) ==="

ORIG=$(nmcli -g GENERAL.CONNECTION dev show "$IF" 2>/dev/null)
[ -z "$ORIG" ] || [ "$ORIG" = "--" ] && {
    # The device may already be enslaved (no active standalone profile).
    ORIG=$(nmcli -t -f NAME,DEVICE,SLAVE con show \
           | awk -F: -v i="$IF" -v br="$BR" '$2==i && $3==br {print $1; exit}')
}
if [ -z "${ORIG:-}" ] || [ "$ORIG" = "--" ]; then
    echo "FATAL: cannot determine the NM profile for $IF"
    exit 1
fi
echo "device profile: $ORIG"

NIC_MAC=$(cat /sys/class/net/"$IF"/address)
echo "NIC MAC: $NIC_MAC"

mkdir -p /root/vm-archive
nmcli -f ALL con show "$ORIG" > "/root/vm-archive/${ORIG// /_}-profile.txt"

restore_orig() {
    echo "rolling back to plain $IF profile"
    nmcli con mod "$ORIG" connection.master "" connection.slave-type "" 2>/dev/null
    nmcli con down "$BR" 2>/dev/null
    nmcli con delete "$BR" 2>/dev/null
    nmcli con up "$ORIG" 2>/dev/null
}

# Stray duplicate profile for the same device can steal it on activation.
for p in $(nmcli -t -f NAME,TYPE,DEVICE con show | awk -F: -v i="$IF" '$2=="802-3-ethernet" && $3=="" {print $1}'); do
    if [ "$p" != "$ORIG" ]; then
        echo "disabling stray profile: $p"
        nmcli con mod "$p" connection.autoconnect no
    fi
done

if ! nmcli con show "$BR" >/dev/null 2>&1; then
    nmcli con add type bridge ifname "$BR" con-name "$BR" \
        ipv4.method auto ipv6.method auto \
        bridge.stp no bridge.forward-delay 0 || {
        echo "FATAL: bridge profile creation failed"; exit 1; }
fi

# Keep the router's lease stable: br0 presents the NIC's MAC, and it must
# auto-activate its ports or the bridge stays NO-CARRIER.
nmcli con mod "$BR" \
    connection.autoconnect-slaves 1 \
    ethernet.cloned-mac-address "$NIC_MAC" \
    ipv4.method auto ipv6.method auto || {
    echo "FATAL: bridge tuning failed"; exit 1; }

nmcli con mod "$ORIG" \
    connection.master "$BR" connection.slave-type bridge \
    connection.autoconnect yes || {
    echo "FATAL: could not enslave $ORIG to $BR"; restore_orig; exit 1; }

# Detach the NIC from its old standalone activation, then bring the bridge up.
nmcli con down "$ORIG" >/dev/null 2>&1
nmcli con up "$BR" || { echo "FATAL: br0 activation failed"; restore_orig; exit 1; }

check() {
    ip -br link show "$BR" 2>/dev/null | grep -q 'NO-CARRIER' && return 1
    ip -4 -br a show "$BR" 2>/dev/null | grep -q '192\.168\.' || return 1
    ip -4 -br a show "$IF" 2>/dev/null | grep -q '192\.168\.' && return 1
    ping -c1 -W2 "$GW" >/dev/null 2>&1 || return 1
    return 0
}

for _ in $(seq 1 $((DEADLINE / 5))); do
    if check; then
        echo "OK: $BR is the LAN-facing bridge; gateway $GW reachable"
        ip -4 -br a show "$BR"; ip -br link show "$BR"
        exit 0
    fi
    sleep 5
done

echo "FAIL: bridge did not form within ${DEADLINE}s; last state:"
ip -4 -br a show "$BR" 2>&1; ip -br link show "$BR" 2>&1 || true
restore_orig
sleep 10
if ping -c1 -W2 "$GW" >/dev/null 2>&1; then
    echo "rollback OK ($(ip -4 -br a show "$IF"))"
else
    echo "rollback FAILED - use the DL360 console (tty2) or iLO: nmcli con up \"$ORIG\""
fi
exit 1
