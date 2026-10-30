#!/bin/bash
# build-seed.sh — render cloud-init/user-data and build the NoCloud seed ISO.
# Secrets come from ~/rockylinux_remote/.ssh-env; nothing secret is committed.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

[ -f .ssh-env ] || { echo "missing $HERE/.ssh-env" >&2; exit 1; }
set -a; . ./.ssh-env; set +a
: "${SSHPASS:?SSHPASS not set in .ssh-env}"

PUBKEY=$(cat ~/.ssh/id_ed25519.pub)

# Render with python to avoid sed escaping problems with @ . / & and quotes.
python3 - "$SSHPASS" "$PUBKEY" <<'PY'
import sys, pathlib
pw, key = sys.argv[1], sys.argv[2]
src = pathlib.Path("cloud-init/user-data.template").read_text()
out = src.replace("__PASSWORD__", pw).replace("__SSH_PUBKEY__", key)
pathlib.Path("cloud-init/user-data").write_text(out)
PY
chmod 600 cloud-init/user-data

xorriso -as mkisofs -o cloud-init/seed-ubuntu24.iso \
    -V cidata -J -R cloud-init/user-data cloud-init/meta-data >/dev/null
chmod 600 cloud-init/seed-ubuntu24.iso

echo "built:"
ls -l cloud-init/user-data cloud-init/seed-ubuntu24.iso
xorriso -indev cloud-init/seed-ubuntu24.iso -pvd_info 2>/dev/null | awk -F': ' '/Volume id/{print "volume id:", $2}'
