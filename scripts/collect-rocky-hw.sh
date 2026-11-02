#!/usr/bin/env bash
# collect-rocky-hw.sh — refresh rockylinux_info/hardware/ from the live DL360.
# Same file layout as the 2026-10-29 collection (00-meta, cpu, cpu-numa-mem, numa,
# memory, dmidecode, pci, storage, smart, network-hw, firmware, block-raid,
# _errors). Read-only against the host; root reads go through the .ssh-env
# stdin sudo pattern. The folder is git-ignored (serials/UUIDs/MACs) — local
# reference only, never pushed.
#
# Usage: ./scripts/collect-rocky-hw.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
[ -f .ssh-env ] || { echo "FATAL: .ssh-env missing" >&2; exit 1; }
set -a; . ./.ssh-env; set +a
: "${SSHPASS:?SSHPASS not set}"

OUT="$HERE/rockylinux_info/hardware"
mkdir -p "$OUT"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cat > "$STAGE/remote.sh" <<'REMOTE'
#!/bin/bash
export LC_ALL=C
D=/var/tmp/hwinv
rm -rf "$D"; mkdir -p "$D"
E="$D/_errors.txt"; : > "$E"

r(){ # r <file> <section label> <command...>
  local f="$1" label="$2"; shift 2
  { echo "=== $label ==="; "$@"; } >> "$D/$f" 2>>"$E" || echo "FAILED: $label rc=$?" >> "$E"
}

# --- 00-meta -------------------------------------------------------------------------
r 00-meta.txt "date -Is"        date -Is
r 00-meta.txt "hostname"        hostname
r 00-meta.txt "hostnamectl"     hostnamectl status
r 00-meta.txt "uname -a"        uname -a
r 00-meta.txt "uptime"          uptime
lscpu | head -30 >> "$D/00-meta.txt"

# --- cpu / numa / memory -------------------------------------------------------------
r cpu.txt       "lscpu"                 lscpu
r cpu.txt       "lscpu -e"              lscpu -e
r cpu.txt       "model name"            grep -m1 "model name" /proc/cpuinfo
r cpu.txt       "cpu MHz range"         sh -c 'awk -F: "/cpu MHz/{print \$2}" /proc/cpuinfo | sort -n | sed -n "1p;\$p"'
r cpu.txt       "flags"                 grep -m1 flags /proc/cpuinfo
r cpu.txt       "nproc --all"           nproc --all
r cpu.txt       "cpufreq governor"      sh -c 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "absent (no cpufreq on this host)"'

r numa.txt      "numactl -H"            numactl -H
for nd in /sys/devices/system/node/node[0-9]*; do
  r numa.txt   "node $(basename "$nd") meminfo" grep -E "MemTotal|MemFree|MemUsed|Active|Inactive" "$nd/meminfo"
  r numa.txt   "node $(basename "$nd") distance" cat "$nd/distance"
done

r memory.txt    "lsmem"                 lsmem
r memory.txt    "free -h"               free -h
r memory.txt    "free -m"               free -m
r memory.txt    "/proc/meminfo"         cat /proc/meminfo
r memory.txt    "THP enabled"           cat /sys/kernel/mm/transparent_hugepage/enabled
r memory.txt    "KSM run"               cat /sys/kernel/mm/ksm/run

r cpu-numa-mem.txt "lscpu"              lscpu
r cpu-numa-mem.txt "numactl --hardware" numactl --hardware
r cpu-numa-mem.txt "free -h"            free -h

# --- dmidecode / firmware ------------------------------------------------------------
r dmidecode.txt "dmidecode"             dmidecode
r firmware.txt  "dmidecode -t bios"     dmidecode -t bios
{ echo "=== fwupdmgr get-devices ==="
  if command -v fwupdmgr >/dev/null; then fwupdmgr get-devices; else echo "fwupdmgr not installed"; fi
} >> "$D/firmware.txt" 2>>"$E"
{ echo "=== fwupdmgr get-updates ==="
  if command -v fwupdmgr >/dev/null; then fwupdmgr get-updates; else echo "fwupdmgr not installed"; fi
} >> "$D/firmware.txt" 2>>"$E" || echo "fwupd get-updates nonzero (usually 'no updates')" >> "$E"

# --- pci / usb -----------------------------------------------------------------------
r pci.txt       "lspci -nn"             lspci -nn
r pci.txt       "lspci -nnk"            lspci -nnk
r 00-meta.txt   "usb"                   lsusb

# --- storage -------------------------------------------------------------------------
r storage.txt   "lsblk (model/serial/rota/tran)" lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,ROTA,TRAN
r storage.txt   "lsblk -D (discard)"    lsblk -D
r storage.txt   "lsblk -s"              lsblk -s
r storage.txt   "df -hT"                df -hT
r storage.txt   "findmnt /"             findmnt /
r storage.txt   "/proc/partitions"      cat /proc/partitions
r storage.txt   "RAID controller (lspci)" sh -c "lspci -nn | grep -iE 'raid|storage'"
r storage.txt   "smartctl tools"        sh -c 'command -v storcli ssacli sas3ircu 2>/dev/null || echo "no HPE/Avago RAID CLI installed"'
r block-raid.txt "lsblk"                lsblk
r block-raid.txt "/proc/mdstat"         cat /proc/mdstat

for d in $(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}'); do
  r smart.txt  "smartctl -i -H $d"    smartctl -i -H "$d"
done
r smart.txt     "smartctl -i -H /dev/sr0" smartctl -i -H /dev/sr0

# --- network hardware ----------------------------------------------------------------
r network-hw.txt "ip -br link"          ip -br link
r network-hw.txt "ip -br addr"          ip -br addr
r network-hw.txt "NIC pci"              sh -c "lspci -nn | grep -iE 'ethernet|network'"
r network-hw.txt "bridge link"          bridge link
r network-hw.txt "bonding"              sh -c 'ls /proc/net/bonding 2>/dev/null || echo "no bonding"'
for n in $(ls /sys/class/net | grep -v "^lo$"); do
  r network-hw.txt "ethtool -i $n"      ethtool -i "$n"
  r network-hw.txt "ethtool $n"         ethtool "$n"
  r network-hw.txt "ethtool -l $n (channels)" ethtool -l "$n"
done

echo "HWINV_DONE"
REMOTE

echo "== running remote hardware inventory (root)..."
( echo "$SSHPASS"; cat "$STAGE/remote.sh" ) | ssh -T -o BatchMode=yes rocky-dl360 'sudo -S -p "" bash -s' \
  > "$STAGE/run.log" 2>&1 || true
grep -q HWINV_DONE "$STAGE/run.log" || { echo "FATAL: remote inventory failed:"; cat "$STAGE/run.log" "$STAGE/remote.sh" >&2; exit 1; }

rsync -q rocky-dl360:/var/tmp/hwinv.tgz "$STAGE/" 2>/dev/null || {
  # tar on the host, then fetch
  ssh -o BatchMode=yes rocky-dl360 'tar -C /var/tmp -czf /var/tmp/hwinv.tgz hwinv'
  rsync -q rocky-dl360:/var/tmp/hwinv.tgz "$STAGE/"
}
tar -xzf "$STAGE/hwinv.tgz" -C "$STAGE/"
cp -a "$STAGE/hwinv/." "$OUT/"
# the staged dir/tarball are root-owned — clean them via the root channel
( echo "$SSHPASS"; echo 'rm -rf /var/tmp/hwinv /var/tmp/hwinv.tgz' ) | ssh -T -o BatchMode=yes rocky-dl360 'sudo -S -p "" bash -s' || true

TODAY=$(date '+%F')
cat > "$OUT/README.md" <<EOF
# Hardware inventory — rocky-dl360

- **Host:** HPE ProLiant DL360 Gen10 Plus (\`rocky-dl360\`, 192.168.0.186); OS Rocky Linux 10.2, \$(uname -r on host at collection time)
- **Collected:** \$(date -Is) — post RAID6-rebuild OS re-install (2026-11-02); read-only
- **Method:** \`ssh rocky-dl360\`, \`LC_ALL=C\`; privileged reads via \`sudo -S\` over stdin; regenerated by \`scripts/collect-rocky-hw.sh\`
- **Layout note:** the pre-rebuild host exposed two MR416i-a volumes (600 G + 1.2 T); after the RAID6 rebuild there is a single ~1.7 T volume (\`sda\`).

## Files

| File | Contents |
|------|----------|
| \`00-meta.txt\` | Date, hostname/hostnamectl, \`uname -a\`, uptime, first 30 lines of \`lscpu\`, \`lsusb\`. |
| \`cpu.txt\` | Full \`lscpu\`, \`lscpu -e\`, model/MHz range/flags, \`nproc --all\`, cpufreq governor (absent on this host). |
| \`memory.txt\` | \`lsmem\`, \`free -h\`, \`free -m\`, full \`/proc/meminfo\`, THP enabled, KSM run state. |
| \`numa.txt\` | \`numactl -H\`, per-node sysfs \`meminfo\` and \`distance\` for nodes 0–3. |
| \`dmidecode.txt\` | **ROOT** full DMI dump: system, baseboard, BIOS, processor, memory DIMM slots (populated sizes). |
| \`pci.txt\` | \`lspci -nn\` and \`lspci -nnk\` (vendor/device IDs and kernel driver per device). |
| \`storage.txt\` | \`lsblk\` (model/serial/rota/tran), \`lsblk -D\`, \`lsblk -s\`, \`df -hT\`, \`findmnt\`, \`/proc/partitions\`, RAID controller PCI, RAID CLI presence. |
| \`smart.txt\` | **ROOT, best effort** \`smartctl -i -H\` per whole disk. Disks are RAID virtual disks; SMART is not exposed behind the MR416i-a. |
| \`network-hw.txt\` | \`ip -br link/addr\`, per-NIC \`ethtool -i\`, \`ethtool\`, channel counts, NIC \`lspci\`, \`bridge link\`, bonding (none). |
| \`firmware.txt\` | **ROOT** BIOS DMI, \`fwupdmgr get-devices\` / \`get-updates\` (if fwupd installed). |
| \`block-raid.txt\` | \`lsblk\` + \`/proc/mdstat\` (hardware RAID → mdstat empty). |
| \`cpu-numa-mem.txt\` | Compact CPU/NUMA/memory summary (same as the rebuild runbook writes). |
| \`_errors.txt\` | Shared stderr log: per-command failure headers and known limitations. |

## Sensitivity

\`dmidecode.txt\`, \`storage.txt\`, \`smart.txt\`, and \`network-hw.txt\` contain hardware serial
numbers, UUIDs, WWNs/LUN IDs, and MAC-related identifiers. Treat this directory as sensitive;
do not publish or commit it without redaction (it is git-ignored).
EOF

echo "== collected into $OUT"
ls -la "$OUT"
