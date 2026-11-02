#!/usr/bin/env bash
# Sync the entire local project folder to the 600G SAS disk (overwriting there).
# The SAS disk may be attached locally (/mnt/sas-share) or live on np104-tplink
# (192.168.0.100, the hp840g8 laptop); skip cleanly when neither is reachable.
set -euo pipefail

SRC="/home/grissom/rockylinux_remote"
RSYNC_OPTS=(-aH --delete --info=stats2 --exclude-from="$SRC/.gitignore")

# rsync alone copies git-ignored secrets too (.ssh-env, rendered cloud-init
# user-data, seed ISOs) — the SAS mirror must never hold credentials even
# though the 600G disk is local-only. --exclude-from enforces that.

if mountpoint -q /mnt/sas-share 2>/dev/null; then
  DST="/mnt/sas-share/rockylinux_remote"
  if [[ ! -d "$DST" ]]; then
    mkdir -p "$DST"
  fi
  rsync "${RSYNC_OPTS[@]}" "$SRC/" "$DST/"
  echo "Synced $SRC -> $DST"
  exit 0
fi

NP104="np104-tplink.local"
if ssh -o BatchMode=yes -o ConnectTimeout=6 "$NP104" 'test -d /mnt/sas-share' 2>/dev/null; then
  rsync "${RSYNC_OPTS[@]}" "$SRC/" "$NP104:/mnt/sas-share/rockylinux_remote/"
  echo "Synced $SRC -> $NP104:/mnt/sas-share/rockylinux_remote"
  exit 0
fi

echo "SKIP: no SAS disk mounted locally (/mnt/sas-share) and none reachable on $NP104"
