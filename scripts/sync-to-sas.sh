#!/usr/bin/env bash
# Sync the entire local project folder to the 600G SAS disk (overwriting there).
set -euo pipefail

SRC="/home/grissom/rockylinux_remote"
DST="/mnt/sas-share/rockylinux_remote"

if [[ ! -d "$DST" ]]; then
  sudo mkdir -p "$DST"
fi
sudo chown -R grissom:grissom "$DST"

# --exclude-from=.gitignore: rsync alone copies git-ignored secrets too
# (.ssh-env, rendered cloud-init user-data, seed ISOs) — the SAS mirror must
# never hold credentials even though the 600G disk is local-only.
rsync -aH --delete --info=stats2 --exclude-from="$SRC/.gitignore" "$SRC/" "$DST/"

echo "Synced $SRC -> $DST"