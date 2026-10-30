#!/bin/bash
# collect-ubuntu24-info.sh — inventory the KVM guest `ubuntu24` (hardware / software /
# packages / network + performance) into vm-ubuntu24/ubuntu24_info/, mirroring the
# rockylinux_info/ layout. Runs from the laptop.
#
# Read-only against guest and host EXCEPT the approved iperf3 installs (guest apt,
# host dnf, laptop apt) and a temporary iperf3 server on the guest. Set REMOVE_IPERF3=1
# to purge iperf3 again at the end; INSTALL_LAPTOP_IPERF3=0 to skip the laptop install
# (laptop↔guest tests then record SKIP).
#
# Usage: ./scripts/collect-ubuntu24-info.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

[ -f .ssh-env ] || { echo "FATAL: .ssh-env missing" >&2; exit 1; }
set -a; . ./.ssh-env; set +a
: "${SSHPASS:?SSHPASS not set}"

REMOVE_IPERF3=${REMOVE_IPERF3:-0}
INSTALL_LAPTOP_IPERF3=${INSTALL_LAPTOP_IPERF3:-1}
IPERF_PORT=${IPERF_PORT:-5201}
IPERF_TIME=${IPERF_TIME:-10}

OUT="$HERE/vm-ubuntu24/ubuntu24_info"
HW="$OUT/hardware"; OS_="$OUT/os"; PKG="$OUT/packages"; NET="$OUT/network"; PERF="$NET/performance"
VER="$OUT/verification.md"
mkdir -p "$HW" "$OS_" "$PKG" "$NET" "$PERF"

SSHOPTS="-o BatchMode=yes -o ConnectTimeout=8"
GUEST_USER=catc_ubuntu_kvm
GW=192.168.0.1

# --- verification rows -------------------------------------------------------------
: > "$VER"
{
  echo "# Verification — ubuntu24 info collection"
  echo
  echo "Run $(date -Is) from the laptop against guest \`ubuntu24\` on \`rocky-dl360\`."
  echo "Result column is what was actually observed."
  echo
  echo "| # | Check | Result |"
  echo "|---|---|---|"
} >> "$VER"
vrow() { # <id> <check> <result>
  printf '| %s | %s | %s |\n' "$1" "$2" "$3" >> "$VER"
}

# --- helpers -----------------------------------------------------------------------
# host root commands: password only ever via the local stdin pipe, never in the
# remote command string; sudo -k kills a warm ticket so the password line cannot
# fall through into the script body.
hroot() { # <label> <outfile-under-OUT-or---> ... commands on local stdin
  local label=$1; shift
  local dest=$1; shift
  {
    echo "===== $label ====="
    printf '# CMD: sudo -S -k bash -s <stdin>\n'
    ( echo "$SSHPASS"; cat ) | ssh -T $SSHOPTS rocky-dl360 'sudo -S -k -p "" bash -s' 2>/tmp/collect-host-stderr.$$
    local rc=$?
    if [ "$rc" -ne 0 ]; then
      { echo "### FAILED $label rc=$rc $(date -Is)"; cat /tmp/collect-host-stderr.$$; } >> "$OUT/host-errors.txt"
    fi
    rm -f /tmp/collect-host-stderr.$$
  } > "$dest"
}

# guest collect: gcollect <catdir> <outfile> <label> <remote-cmd...>
# The remote command is run via bash -lc so quoting survives verbatim
# (guest has no 'sort' in the default PATH for non-login sh).
gcollect() {
  local dir=$1 file=$2 label=$3; shift 3
  local cmd; cmd=$(printf '%q ' "$@")
  local out err rc
  out=$(ssh $SSHOPTS "$GUEST_USER@$G" "bash -lc $(printf '%q' "$cmd")" 2>/tmp/collect-guest-stderr.$$)
  rc=$?
  err=$(cat /tmp/collect-guest-stderr.$$ 2>/dev/null); rm -f /tmp/collect-guest-stderr.$$
  {
    echo "===== $label ====="
    printf '# CMD: %s\n' "$cmd"
    printf '%s\n' "$out"
  } >> "$dir/$file"
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    {
      echo "### FAILED $label rc=$rc $(date -Is)"
      printf '%s\n' "$err"
      echo "### CMD: $cmd"
    } >> "$dir/_errors.txt"
  fi
}

# ===================================================================================
echo "== phase 1: preflight + gate =="

H=$(ssh $SSHOPTS rocky-dl360 'id -un' 2>/dev/null)
if [ "$H" = "catc" ]; then vrow V1 "ssh -o BatchMode=yes rocky-dl360 'id -un'" "**PASS** — \`$H\`"; else vrow V1 "ssh -o BatchMode=yes rocky-dl360 'id -un'" "**FAIL** — got \`${H:-none}\`"; fi

G=$(ssh $SSHOPTS rocky-dl360 'virsh -c qemu:///system domifaddr ubuntu24 --source agent' 2>/dev/null \
    | awk '/52:54:00:24:00:24/ && /ipv4/ {print $NF}' | head -1 | cut -d/ -f1)
if [ -z "$G" ]; then
  G=$(ssh $SSHOPTS rocky-dl360 'ip neigh show dev br0' 2>/dev/null | awk '/52:54:00:24:00:24/ {print $1; exit}')
fi
if [ -n "$G" ]; then vrow V2 "virsh -c qemu:///system domifaddr ubuntu24 --source agent" "**PASS** — enp1s0 52:54:00:24:00:24 ipv4 $G/24"; else vrow V2 "domifaddr / ip neigh fallback" "**FAIL** — no guest address found"; fi
[ -n "$G" ] || { echo "FATAL: cannot determine guest IP" >&2; exit 1; }
echo "guest IP: $G"

GATE=$(ssh $SSHOPTS "$GUEST_USER@$G" 'ip a && ping -c1 -W2 192.168.0.1' 2>&1)
if [ $? -eq 0 ]; then
  vrow V3 "ssh $GUEST_USER@$G 'ip a && ping -c1 $GW' (gate)" "**PASS** — enp1s0 up with $G/24, gateway 0% loss"
else
  vrow V3 "ssh $GUEST_USER@$G 'ip a && ping -c1 $GW' (gate)" "**FAIL** — $(printf '%s' "$GATE" | tail -1)"
  echo "FATAL: guest gate failed" >&2; exit 1
fi

SUDO=$(ssh $SSHOPTS "$GUEST_USER@$G" 'sudo -n id -u' 2>/dev/null)
if [ "$SUDO" = "0" ]; then vrow V4 "guest sudo -n id -u" "**PASS** — \`0\` (NOPASSWD)"; else vrow V4 "guest sudo -n id -u" "**FAIL** — got \`${SUDO:-none}\`"; fi

# ===================================================================================
echo "== phase 2: baseline collection (read-only) =="
for d in "$HW" "$OS_" "$PKG" "$NET"; do : > "$d/_errors.txt"; done

# ---- hardware ----------------------------------------------------------------------
gcollect "$HW" 00-meta.txt "date" date -Is
gcollect "$HW" 00-meta.txt "hostnamectl" hostnamectl
gcollect "$HW" 00-meta.txt "uname" uname -a
gcollect "$HW" 00-meta.txt "uptime" uptime
gcollect "$HW" 00-meta.txt "lscpu-head" 'lscpu | head -40'
gcollect "$HW" 00-meta.txt "nproc" nproc

gcollect "$HW" cpu.txt "lscpu-full" lscpu
gcollect "$HW" cpu.txt "lscpu-e" 'lscpu -e'
gcollect "$HW" cpu.txt "cpuinfo-model" "grep -m1 'model name' /proc/cpuinfo"
gcollect "$HW" cpu.txt "cpuinfo-flags" "sed -n 's/^flags.*://p' /proc/cpuinfo | head -1 | tr ' ' '\n' | tr '\n' ' '"
gcollect "$HW" cpu.txt "cpufreq-governor" 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo absent'

gcollect "$HW" virtualization.txt "systemd-detect-virt" systemd-detect-virt
gcollect "$HW" virtualization.txt "virt-what" 'virt-what 2>/dev/null || echo "virt-what not installed"'
gcollect "$HW" virtualization.txt "hypervisor-flag" "grep -m1 hypervisor /proc/cpuinfo || echo none"
gcollect "$HW" virtualization.txt "dmesg-virt" "sudo -n dmesg | grep -iE 'hypervisor|qemu|kvm' | head -20"

gcollect "$HW" memory.txt "free-h" free -h
gcollect "$HW" memory.txt "free-m" free -m
gcollect "$HW" memory.txt "meminfo" cat /proc/meminfo
gcollect "$HW" memory.txt "thp" 'cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo absent'
gcollect "$HW" memory.txt "ksm" 'cat /sys/kernel/mm/ksm/run 2>/dev/null || echo absent'

gcollect "$HW" storage.txt "lsblk" lsblk
gcollect "$HW" storage.txt "lsblk-detail" 'lsblk -o NAME,MODEL,SERIAL,SIZE,ROTA,TRAN,MOUNTPOINTS'
gcollect "$HW" storage.txt "lsblk-discard" 'lsblk -D'
gcollect "$HW" storage.txt "df-hT" df -hT
gcollect "$HW" storage.txt "df-i" df -i
gcollect "$HW" storage.txt "findmnt" findmnt
gcollect "$HW" storage.txt "partitions" cat /proc/partitions
gcollect "$HW" storage.txt "swap" 'swapon --show || true'

gcollect "$HW" pci-usb.txt "lspci" 'lspci -nnk'
gcollect "$HW" pci-usb.txt "lsusb" 'lsusb 2>/dev/null || echo "lsusb not installed"'

# ---- os ----------------------------------------------------------------------------
gcollect "$OS_" 00-meta.txt "date" date -Is
gcollect "$OS_" 00-meta.txt "hostname" hostname
gcollect "$OS_" 00-meta.txt "uname" uname -a
gcollect "$OS_" 00-meta.txt "os-release" cat /etc/os-release
gcollect "$OS_" 00-meta.txt "dpkg-arch" dpkg --print-architecture
gcollect "$OS_" 00-meta.txt "lsb-release" 'lsb_release -a 2>/dev/null || echo "lsb_release not installed"'
gcollect "$OS_" 00-meta.txt "cloud-init-status" 'cloud-init status --long'

gcollect "$OS_" kernel.txt "cmdline" cat /proc/cmdline
gcollect "$OS_" kernel.txt "uname-r" uname -r
gcollect "$OS_" kernel.txt "lsmod-head" 'lsmod | head -40'
gcollect "$OS_" kernel.txt "lsmod-count" 'lsmod | wc -l'
gcollect "$OS_" kernel.txt "dmesg-tail" 'sudo -n dmesg -T | tail -200'
gcollect "$OS_" kernel.txt "sysctl-net-vm" "sysctl -a 2>/dev/null | grep -E '^(net|vm)\\.' | head -40"

gcollect "$OS_" systemd.txt "default-target" 'systemctl get-default'
gcollect "$OS_" systemd.txt "failed-units" 'sudo -n systemctl --failed --no-legend'
gcollect "$OS_" systemd.txt "running-count" 'systemctl list-units --type=service --state=running --no-legend | wc -l'
gcollect "$OS_" systemd.txt "enabled-units" 'systemctl list-unit-files --state=enabled --no-legend'
gcollect "$OS_" systemd.txt "systemd-analyze" 'systemd-analyze 2>/dev/null | head -5'
gcollect "$OS_" systemd.txt "blame" 'systemd-analyze blame 2>/dev/null | head -15'
gcollect "$OS_" systemd.txt "key-services" 'systemctl status ssh.service ssh.socket cockpit.socket qemu-guest-agent.service --no-pager 2>&1 | head -60'

# identity: account inventory only — shadow, password aging, private keys and
# authorized_keys contents are deliberately NOT collected (header notes this).
{
  echo "===== identity (accounts only) ====="
  echo "# NOTE: /etc/shadow, passwd -S, ssh private keys and authorized_keys contents are intentionally excluded."
} >> "$OS_/identity.txt"
gcollect "$OS_" identity.txt "id" id
gcollect "$OS_" identity.txt "passwd" getent passwd
gcollect "$OS_" identity.txt "group" getent group
gcollect "$OS_" identity.txt "sudo-l" 'sudo -n -l'
gcollect "$OS_" identity.txt "who" who

gcollect "$OS_" sshd.txt "sshd-T" 'sudo -n sshd -T 2>/dev/null | head -60'
gcollect "$OS_" sshd.txt "ssh-dir" 'ls -l /etc/ssh/ 2>/dev/null'
gcollect "$OS_" sshd.txt "host-key-fingerprints" 'ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub 2>/dev/null'
gcollect "$OS_" sshd.txt "ssh-units" 'systemctl is-active ssh.service ssh.socket; systemctl is-enabled ssh.socket'

gcollect "$OS_" firewall.txt "ufw" 'sudo -n ufw status verbose 2>&1 | head -10'
gcollect "$OS_" firewall.txt "nft" 'sudo -n nft list ruleset 2>/dev/null | head -40 || echo "no nft ruleset"'
gcollect "$OS_" firewall.txt "iptables" 'sudo -n iptables -L -n -v 2>/dev/null | head -20 || echo "iptables not present"'

gcollect "$OS_" time-locale.txt "timedatectl" 'timedatectl 2>/dev/null || date'
gcollect "$OS_" time-locale.txt "date" date
gcollect "$OS_" time-locale.txt "locale" locale
gcollect "$OS_" time-locale.txt "timezone" 'cat /etc/timezone 2>/dev/null || readlink -f /etc/localtime'

gcollect "$OS_" logs.txt "journal-errors" 'sudo -n journalctl --no-pager -p err -n 200 2>&1'
gcollect "$OS_" logs.txt "journal-kernel-warn" 'sudo -n journalctl --no-pager -k -p warning -n 100 2>&1'
gcollect "$OS_" logs.txt "cloud-init-log" 'sudo -n tail -n 50 /var/log/cloud-init.log 2>/dev/null || echo "no cloud-init.log"'
gcollect "$OS_" logs.txt "var-log" 'ls -la /var/log/ | head -20'

# ---- packages ----------------------------------------------------------------------
gcollect "$PKG" 00-meta.txt "date" date -Is
gcollect "$PKG" 00-meta.txt "hostname" hostname
gcollect "$PKG" 00-meta.txt "apt-version" 'apt-get --version | head -1'
gcollect "$PKG" 00-meta.txt "dpkg-version" 'dpkg --version | head -1'
gcollect "$PKG" 00-meta.txt "os" "grep PRETTY /etc/os-release"

gcollect "$PKG" installed-packages.tsv "dpkg-query-all" "dpkg-query -W -f='\${binary:Package}\t\${Version}\t\${Architecture}\n' | sort"
gcollect "$PKG" installed-count.txt "total-count" 'dpkg-query -W | wc -l'
{
  echo "===== per-arch counts (derived locally from installed-packages.tsv) ====="
  awk -F'\t' '{c[$3]++} END {for (a in c) printf "%s\t%d\n", a, c[a]}' "$PKG/installed-packages.tsv" | sort
} >> "$PKG/installed-count.txt"
gcollect "$PKG" key-packages.txt "key-packages" "dpkg-query -W -f='\${binary:Package}\t\${Version}\t\${db:Status-Status}\n' qemu-guest-agent cockpit cockpit-ws cockpit-bridge openssh-server linux-image-generic ufw netplan.io cloud-init unattended-upgrades systemd-resolved networkd-dispatcher iperf3 2>&1"
gcollect "$PKG" apt-sources.txt "sources-list-d" 'ls -la /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null'
gcollect "$PKG" apt-sources.txt "sources-content" 'cat /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null'
gcollect "$PKG" apt-sources.txt "apt-cache-policy" 'apt-cache policy 2>/dev/null | head -20'
gcollect "$PKG" apt-history.txt "apt-history" 'sudo -n zcat -f /var/log/apt/history.log* 2>/dev/null | tail -n 200'
gcollect "$PKG" apt-history.txt "apt-log-dir" 'ls -la /var/log/apt/ 2>/dev/null'
gcollect "$PKG" updates.txt "upgradable" 'apt list --upgradable 2>/dev/null'
gcollect "$PKG" updates.txt "upgradable-count" 'apt list --upgradable 2>/dev/null | grep -c upgradable'
gcollect "$PKG" other-managers.txt "snap" 'snap list 2>/dev/null || echo "snap not installed/no snaps"'
gcollect "$PKG" other-managers.txt "pip3" 'command -v pip3 >/dev/null && pip3 list 2>/dev/null | head -20 || echo "pip3 not installed"'
gcollect "$PKG" other-managers.txt "flatpak" 'flatpak list 2>/dev/null || echo "flatpak not installed"'
gcollect "$PKG" other-managers.txt "node" 'command -v node npm 2>/dev/null || echo "node/npm not installed"'
gcollect "$PKG" held-packages.txt "apt-mark-showhold" 'apt-mark showhold 2>/dev/null || true'

# ---- network -----------------------------------------------------------------------
gcollect "$NET" 00-meta.txt "date" date -Is
gcollect "$NET" 00-meta.txt "hostname" hostname
gcollect "$NET" 00-meta.txt "ip-br-addr" ip -br addr

gcollect "$NET" interfaces.txt "ip-br-link" ip -br link
gcollect "$NET" interfaces.txt "ip-addr" ip addr show
gcollect "$NET" interfaces.txt "ip-route" ip route show
gcollect "$NET" interfaces.txt "ip-neigh" ip neigh show
gcollect "$NET" interfaces.txt "ss-tulnp" 'sudo -n ss -tulnp'
gcollect "$NET" interfaces.txt "ss-s" ss -s

gcollect "$NET" netplan.txt "netplan-dir" 'ls -la /etc/netplan/ 2>/dev/null'
gcollect "$NET" netplan.txt "netplan-content" 'sudo -n cat /etc/netplan/*.yaml 2>/dev/null'
gcollect "$NET" netplan.txt "networkctl" 'networkctl status enp1s0 2>/dev/null | head -20 || echo "networkctl n/a"'
gcollect "$NET" netplan.txt "dhcp-lease" 'sudo -n cat /run/systemd/netif/leases/* 2>/dev/null | head -20 || echo "no lease file visible"'

gcollect "$NET" dns.txt "resolvectl" 'resolvectl status 2>/dev/null | head -30 || systemd-resolve --status 2>/dev/null | head -30'
gcollect "$NET" dns.txt "resolv-conf-link" 'readlink -f /etc/resolv.conf'
gcollect "$NET" dns.txt "resolv-conf" 'cat /etc/resolv.conf'
gcollect "$NET" dns.txt "resolve-probe" 'getent hosts archive.ubuntu.com'
gcollect "$NET" dns.txt "resolvectl-query" 'resolvectl query archive.ubuntu.com 2>/dev/null | head -5'

gcollect "$NET" ethtool.txt "ethtool-i" 'ethtool -i enp1s0 2>/dev/null || echo "ethtool not installed"'
gcollect "$NET" ethtool.txt "ethtool" 'ethtool enp1s0 2>/dev/null || echo "ethtool not installed"'
gcollect "$NET" ethtool.txt "ethtool-k" 'ethtool -k enp1s0 2>/dev/null | head -20 || echo "ethtool not installed"'
gcollect "$NET" ethtool.txt "ethtool-S" 'sudo -n ethtool -S enp1s0 2>/dev/null | head -30 || echo "ethtool -S n/a"'

gcollect "$NET" connectivity.txt "ping-gateway" 'ping -c3 -W2 192.168.0.1 2>&1'
gcollect "$NET" connectivity.txt "ping-host" 'ping -c3 -W2 192.168.0.188 2>&1'
gcollect "$NET" connectivity.txt "ping-laptop" 'ping -c3 -W2 192.168.0.100 2>&1'
gcollect "$NET" connectivity.txt "curl-archive" 'curl -sI -m 10 http://archive.ubuntu.com/ | head -3'

# redact any user:pass@ in captured apt sources
if grep -qE 'https?://[^/ ]+:[^@ ]+@' "$PKG/apt-sources.txt" 2>/dev/null; then
  sed -i -E 's#(https?://)[^/ ]+:[^@ ]+@#\1REDACTED@#g' "$PKG/apt-sources.txt"
  echo "### REDACTED user:pass@ in apt-sources.txt $(date -Is)" >> "$PKG/_errors.txt"
fi

echo "== phase 2 done =="

# ===================================================================================
echo "== phase 3: iperf3 installs (approved mutations) =="
INSTALL_LOG="$PERF/iperf3-install.txt"
: > "$INSTALL_LOG"
{
  echo "===== iperf3 install log ====="
  echo "# Run $(date -Is). These are the only remote mutations of this collection."
  echo
  echo "===== guest: apt-get update -qq && apt-get install -y iperf3 ====="
  # debconf pre-seed: never start the packaged iperf3 daemon (we run our own on $IPERF_PORT)
  ssh $SSHOPTS "$GUEST_USER@$G" 'echo "iperf3 iperf3/start_daemon boolean false" | sudo -n debconf-set-selections' >/dev/null 2>&1
  ssh $SSHOPTS "$GUEST_USER@$G" 'sudo -n apt-get update -qq && sudo -n DEBIAN_FRONTEND=noninteractive DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold install iperf3' 2>&1
  echo "rc=$?"
  echo "# CMD: iperf3 --version (guest)"
  ssh $SSHOPTS "$GUEST_USER@$G" 'iperf3 --version' 2>&1
  echo
  echo "===== host: dnf -y install iperf3 (via sudo -S -k stdin) ====="
} >> "$INSTALL_LOG"
( echo "$SSHPASS"; printf '%s\n' 'set -e' 'dnf -y install iperf3' 'iperf3 --version' ) \
  | ssh -T $SSHOPTS rocky-dl360 'sudo -S -k -p "" bash -s' >> "$INSTALL_LOG" 2>&1
echo "rc=$?" >> "$INSTALL_LOG"
{
  echo
  echo "===== laptop: apt-get install -y iperf3 (INSTALL_LAPTOP_IPERF3=$INSTALL_LAPTOP_IPERF3) ====="
} >> "$INSTALL_LOG"
if [ "$INSTALL_LAPTOP_IPERF3" = "1" ]; then
  if command -v iperf3 >/dev/null 2>&1; then
    echo "already installed: $(iperf3 --version | head -1)" >> "$INSTALL_LOG"
  else
    { echo "# CMD: sudo apt-get install -y iperf3 (laptop)"; sudo apt-get install -y iperf3 2>&1; echo "rc=$?"; } >> "$INSTALL_LOG"
    iperf3 --version 2>&1 | head -1 >> "$INSTALL_LOG"
  fi
else
  echo "skipped by INSTALL_LAPTOP_IPERF3=0" >> "$INSTALL_LOG"
fi

# ===================================================================================
echo "== phase 4: iperf3 performance tests =="
: > "$PERF/_errors.txt"
pcollect() { # same as gcollect but into performance dir
  local file=$1 label=$2; shift 2
  gcollect "$PERF" "$file" "$label" "$@"
}

# start one server on the guest (daemon mode survives the SSH session)
ssh $SSHOPTS "$GUEST_USER@$G" "sudo -n iperf3 -s -D -p $IPERF_PORT --pidfile /tmp/iperf3-srv.pid --logfile /tmp/iperf3-srv.log" 2>&1
sleep 1
ssh $SSHOPTS "$GUEST_USER@$G" "sudo -n pgrep -a iperf3 || cat /tmp/iperf3-srv.log 2>/dev/null" >> "$INSTALL_LOG" 2>&1

iperf_summary() { # extract a one-line summary from iperf3 txt output
  grep -E 'sender|receiver' "$1" 2>/dev/null | tail -2 | tr '\n' ' ' | sed 's/  */ /g'
}

iperf_row() { # <id> <label> <file> <rc>
  local id=$1 label=$2 file=$3 rc=$4
  if [ "$rc" -eq 0 ] && grep -q receiver "$PERF/$file" 2>/dev/null; then
    vrow "$id" "$label" "**PASS** — $(iperf_summary "$PERF/$file" | cut -c1-160)"
  else
    vrow "$id" "$label" "**FAIL** — see network/performance/_errors.txt"
    { echo "### FAILED $label rc=$rc $(date -Is)"; } >> "$PERF/_errors.txt"
  fi
}

run_local_iperf() { # <id> <label> <outfile> <extra args...>
  local id=$1 label=$2 file=$3; shift 3
  if ! command -v iperf3 >/dev/null 2>&1; then
    vrow "$id" "$label" "**SKIP** — iperf3 not installed on laptop (INSTALL_LAPTOP_IPERF3=0)"
    echo "### SKIPPED $label $(date -Is): no local iperf3" >> "$PERF/_errors.txt"
    return
  fi
  iperf3 -c "$G" -p "$IPERF_PORT" -t "$IPERF_TIME" "$@" > "$PERF/$file" 2>>"$PERF/_errors.txt"
  local rc=$?
  iperf_row "$id" "$label" "$file" "$rc"
  # JSON variant
  iperf3 -c "$G" -p "$IPERF_PORT" -t "$IPERF_TIME" -J "$@" > "$PERF/${file%.txt}.json" 2>>"$PERF/_errors.txt" || true
}

run_host_iperf() { # <id> <label> <outfile> <extra args...>
  local id=$1 label=$2 file=$3; shift 3
  ssh $SSHOPTS rocky-dl360 "iperf3 -c $G -p $IPERF_PORT -t $IPERF_TIME $*" > "$PERF/$file" 2>>"$PERF/_errors.txt"
  local rc=$?
  iperf_row "$id" "$label" "$file" "$rc"
}

run_local_iperf V5 "iperf3 laptop→guest TCP -t ${IPERF_TIME}s" iperf3-laptop-to-guest.txt
run_local_iperf V6 "iperf3 laptop→guest reverse (-R, guest→laptop)" iperf3-laptop-reverse.txt -R
run_host_iperf  V7 "iperf3 host(rocky-dl360)→guest TCP" iperf3-host-to-guest.txt
run_host_iperf  V8 "iperf3 host→guest reverse (-R)" iperf3-host-reverse.txt -R

# guest → internet: try a few public iperf3 servers; fallback to a curl download probe
{
  echo "===== guest→internet iperf3 attempts ====="
  for srv in iperf3.velocityth.net bouygues.testdebit.info ping.online.net; do
    echo "# CMD: iperf3 -c $srv -p $IPERF_PORT -t $IPERF_TIME --connect-timeout 3000 (from guest)"
    ssh $SSHOPTS "$GUEST_USER@$G" "iperf3 -c $srv -p $IPERF_PORT -t $IPERF_TIME --connect-timeout 3000 -J" 2>&1 | tail -c 4000
    echo "rc=$? (server $srv)"
    echo
  done
  echo "===== fallback: curl download probe from guest ====="
  echo "# CMD: curl -o /dev/null -w speed (from guest, archive.ubuntu.com)"
  ssh $SSHOPTS "$GUEST_USER@$G" "curl -o /dev/null -m 30 -s -w 'speed_download=%{speed_download} bytes/s time=%{time_total}s http=%{http_code}\n' http://archive.ubuntu.com/ubuntu/dists/noble/Release" 2>&1
} > "$PERF/iperf3-internet.txt" 2>&1
if grep -q '"end"' "$PERF/iperf3-internet.txt" 2>/dev/null; then
  vrow V9 "iperf3 guest→internet (public server)" "**PASS** — $(grep -oE '[0-9.]+ [GMK]?bits/sec' "$PERF/iperf3-internet.txt" | tail -1)"
elif grep -q 'speed_download=' "$PERF/iperf3-internet.txt"; then
  vrow V9 "iperf3 guest→internet" "**SKIP** (no public server reachable) — curl probe: $(grep -o 'speed_download=[^ ]* .*' "$PERF/iperf3-internet.txt" | head -1)"
else
  vrow V9 "iperf3 guest→internet" "**FAIL** — see network/performance/iperf3-internet.txt"
fi

# stop the server
ssh $SSHOPTS "$GUEST_USER@$G" "sudo -n pkill -F /tmp/iperf3-srv.pid && echo server-stopped || echo server-stop-rc=$?" >> "$INSTALL_LOG" 2>&1

# ===================================================================================
echo "== phase 5: keep/remove iperf3 =="
DEC="$PERF/iperf3-decision.txt"
{
  echo "===== iperf3 keep/remove decision ====="
  echo "REMOVE_IPERF3=$REMOVE_IPERF3  (run $(date -Is))"
  if [ "$REMOVE_IPERF3" = "1" ]; then
    echo "Decision: REMOVE. Commands:"
    echo "  guest: sudo -n apt-get purge -y iperf3"
    echo "  host:  dnf -y remove iperf3   (via sudo -S -k stdin)"
    ssh $SSHOPTS "$GUEST_USER@$G" 'sudo -n DEBIAN_FRONTEND=noninteractive apt-get purge -y iperf3' 2>&1
    echo "guest purge rc=$?"
    ( echo "$SSHPASS"; printf '%s\n' 'dnf -y remove iperf3' ) | ssh -T $SSHOPTS rocky-dl360 'sudo -S -k -p "" bash -s' 2>&1
    echo "host remove rc=$?"
  else
    echo "Decision: KEEP installed — small footprint, reusable for future monitor.sh runs."
    echo "Remove later with: guest 'sudo apt-get purge -y iperf3'; host via the sudo-stdin dnf remove pattern."
  fi
} > "$DEC"

# ===================================================================================
echo "== phase 6: credential sweep =="
SWEEP=$(grep -rlF -- "$SSHPASS" "$OUT" 2>/dev/null | wc -l)
if [ "$SWEEP" -eq 0 ]; then vrow V10 "credential sweep: grep -rlF \$SSHPASS over $OUT" "**PASS** — 0 matches"; else vrow V10 "credential sweep" "**FAIL** — $SWEEP file(s) contain the credential"; fi

echo >> "$VER"
echo "## Not run / not applicable" >> "$VER"
echo >> "$VER"
echo "- \`virsh net-dhcp-leases default\` — the guest is bridged on \`br0\`, not on the libvirt NAT network; its lease lives in the LAN router." >> "$VER"
echo "- cpufreq governor, physical SMART/PCI passthrough — not applicable inside a KVM guest (recorded in hardware/_errors.txt where relevant)." >> "$VER"

echo "== all phases done; output in $OUT =="
exit 0
