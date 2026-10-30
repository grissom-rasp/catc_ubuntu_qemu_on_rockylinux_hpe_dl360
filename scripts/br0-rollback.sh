#!/bin/bash
# br0-rollback.sh — return ens1f2 to a plain (non-bridged) NM profile.
# Use from the DL360 console / iLO if br0 ever breaks connectivity.
set -uo pipefail
IF=${IF:-ens1f2}
BR=${BR:-br0}
LOG=/var/log/br0-switch.log
exec >>"$LOG" 2>&1
echo "=== $(date -Is) manual rollback ==="

ORIG=$(nmcli -g connection.master,connection.id con show 2>/dev/null | awk -F: -v br="$BR" '$1==br{print $2; exit}')
if [ -z "${ORIG:-}" ]; then
    # fall back: any ethernet profile bound to the interface
    ORIG=$(nmcli -t -f NAME,TYPE,DEVICE con show | awk -F: -v i="$IF" '$2=="ethernet" && $3==i{print $1; exit}')
fi
ORIG=${ORIG:-"Wired connection 7"}
echo "slave profile: $ORIG"

nmcli con mod "$ORIG" connection.master "" connection.slave-type ""
nmcli con down "$BR" 2>/dev/null
nmcli con delete "$BR" 2>/dev/null
nmcli con up "$ORIG"
ip -4 -br a show "$IF"
