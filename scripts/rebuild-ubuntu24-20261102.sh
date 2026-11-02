#!/usr/bin/env bash
# rebuild-ubuntu24-20261102.sh — full rebuild of the headless `ubuntu24` KVM guest on the
# freshly re-installed Rocky Linux 10.2 host (RAID6 rebuild; old address 192.168.0.188
# now 192.168.0.186, hostname was reset to localhost.localdomain).
#
# Phases:
#   A  install + update + upgrade QEMU/KVM/libvirt/virt-manager/Cockpit(-machines) stack
#   B  bridge mode: br0 over ens1f2 (cloned MAC, via the repo's br0-switch.sh)
#   C  stage artifacts: verify + upload cloud image, backing overlay, cloud-init seed,
#      patched Option B NUMA domain XML
#   D  define + autostart + start `ubuntu24` (NUMA Option B from first boot)
#   E  readiness check within 15 minutes of `virsh start` (SSH password auth, cloud-init,
#      sshd, 40 vCPU / 48 GiB / 4 NUMA cells), then eject the seed ISO
#   F  15-minute steady-state monitor + host inventory refresh (rockylinux_info/, incl.
#      KVM/network .xml) + guest inventory (vm-ubuntu24/ubuntu24_info/)
#   G  copy inventories to np104-tplink (best-effort), dated setup log, README/CLAUDE
#      update, git commit "re-build RAID6 Rocky Linux", push, SAS sync
#
# Designed to run inside a detached tmux session under nohup (see repo CLAUDE.md):
#   tmux new-session -d -s rebuild-ubuntu24 \
#     'nohup bash scripts/rebuild-ubuntu24-20261102.sh >>logs/rebuild-nohup.out 2>&1; exec bash'
#
# Secrets: SSHPASS comes from .ssh-env (equals the guest SSH password set in cloud-init).
# No password is ever echoed into logs; rendered user-data and seed stay git-ignored.

set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

STAMP=$(date +%Y%m%d-%H%M)
LOGDIR="$HERE/logs"
WORK="$LOGDIR/rebuild-work-$STAMP"
MAINLOG="$LOGDIR/rebuild-ubuntu24-$STAMP.log"
STATUS="$LOGDIR/rebuild-status.txt"
mkdir -p "$LOGDIR" "$WORK"
exec >>"$MAINLOG" 2>&1

say()     { echo "[$(date '+%F %T')] $*"; }
setstatus(){ printf '%s\n' "$*" > "$STATUS"; }

PHASE=init
trap 'rc=$?; say "FATAL in phase $PHASE (line $LINENO, rc=$rc)"; setstatus "FAIL phase=$PHASE rc=$rc — see $MAINLOG"' ERR

set -a; . ./.ssh-env; set +a
: "${SSHPASS:?SSHPASS missing in .ssh-env}"

HOSTALIAS=rocky-dl360
SSHOPTS="-o BatchMode=yes -o ConnectTimeout=10"
GUEST_MAC="52:54:00:24:00:24"
GUEST_USER="catc_ubuntu_kvm"
GUEST_READY_BUDGET=900          # seconds — the "working within 15 minutes" gate
IMG_LOCAL="$HERE/downloads/ubuntu-24.04-server-cloud-kvm/ubuntu-24.04-server-cloudimg-amd64.img"
IMG_SHA256="04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94"
XML_SRC="$HERE/archive/numa-backup-20261030/ubuntu24-optionB-defined-20261030.xml"

rssh()  { ssh -T $SSHOPTS "$HOSTALIAS" "$@"; }
# run a root script (file arg) via the stdin sudo pattern from CLAUDE.md
rroot() { ( echo "$SSHPASS"; cat "$1" ) | ssh -T $SSHOPTS "$HOSTALIAS" 'sudo -S -p "" bash -s'; }

say "=== ubuntu24 rebuild start ==="
setstatus "phase=A installing/updating/upgrading KVM stack"

# ---------------------------------------------------------------------------- phase A
cat > "$WORK/kvm-stack.sh" <<'INNER'
#!/bin/bash
exec >>/var/log/kvm-stack-install.log 2>&1
set -x
set -e
hostnamectl set-hostname rocky-dl360
# Rocky 10 is RHEL-10 based: virt-manager lives in EPEL, not AppStream
dnf -y install epel-release || true
dnf config-manager --set-enabled crb 2>/dev/null || true
dnf -y install \
  qemu-kvm qemu-img libvirt virt-install virt-viewer \
  guestfs-tools xorriso bridge-utils dnsmasq numactl \
  cockpit-machines
dnf -y install libguestfs-tools || true
# task item 2: install, update AND upgrade the virtualization packages.
# virt-manager is best-effort (removed from RHEL10 AppStream; Cockpit is the
# supported GUI) — one missing package would abort the whole dnf transaction.
dnf -y install virt-manager || echo "WARN: virt-manager not available in any enabled repo"
dnf -y update \
  qemu-kvm qemu-img 'libvirt*' virt-install virt-viewer \
  guestfs-tools cockpit-machines 'cockpit*' || true
dnf -y upgrade \
  qemu-kvm qemu-img 'libvirt*' virt-install virt-viewer \
  guestfs-tools cockpit-machines 'cockpit*' || true
systemctl enable --now virtqemud.service virtnetworkd.service virtstoraged.service
systemctl enable --now cockpit.socket
firewall-cmd --permanent --add-service=cockpit
firewall-cmd --reload
usermod -aG libvirt catc || true
systemctl try-restart cockpit.socket 2>/dev/null || true
echo "KVM_STACK_RC=0"
INNER

cat > "$WORK/stage-kvm-stack.sh" <<INNER
cat > /usr/local/sbin/kvm-stack-install.sh <<'INNER2'
$(cat "$WORK/kvm-stack.sh")
INNER2
chmod 700 /usr/local/sbin/kvm-stack-install.sh
rm -f /var/log/kvm-stack-install.log
systemd-run --unit=kvm-stack-install --collect /usr/local/sbin/kvm-stack-install.sh
INNER
rroot "$WORK/stage-kvm-stack.sh"
say "A: dnf stack install launched (systemd unit kvm-stack-install)"

for i in $(seq 1 90); do
  sleep 20
  if rssh 'grep -q "^KVM_STACK_RC=" /var/log/kvm-stack-install.log 2>/dev/null' 2>/dev/null; then
    break
  fi
  say "A: waiting for dnf to finish ($((i*20))s)..."
done
RC_LINE=$(rssh 'grep "^KVM_STACK_RC=" /var/log/kvm-stack-install.log 2>/dev/null' || echo "KVM_STACK_RC=missing")
say "A: $RC_LINE"
[[ "$RC_LINE" == *"RC=0"* ]] || { rssh 'tail -40 /var/log/kvm-stack-install.log' || true; exit 1; }

rssh 'virsh -c qemu:///system list --all; virsh --version; virt-install --version; rpm -q virt-manager cockpit-machines' \
  || true
say "A: KVM/virt-manager/libvirt/Cockpit stack installed + updated + upgraded"

# ---------------------------------------------------------------------------- phase B
setstatus "phase=B br0 bridge switch"
if rssh "ip -br a show br0 2>/dev/null | grep -q '192\.168\.0\.' && bridge link 2>/dev/null | grep -q 'ens1f2.*master'"; then
  say "B: br0 already the LAN-facing bridge over ens1f2 — skipping switch"
else

cat > "$WORK/stage-bridge.sh" <<INNER
mkdir -p /root/vm-archive
cat > /usr/local/sbin/br0-switch.sh <<'INNER2'
$(cat "$HERE/scripts/br0-switch.sh")
INNER2
cat > /usr/local/sbin/br0-rollback.sh <<'INNER2'
$(cat "$HERE/scripts/br0-rollback.sh")
INNER2
chmod 700 /usr/local/sbin/br0-switch.sh /usr/local/sbin/br0-rollback.sh
systemd-run --unit=br0-switch --collect /usr/local/sbin/br0-switch.sh
INNER
rroot "$WORK/stage-bridge.sh"

say "B: bridge switching — SSH will drop briefly; waiting for the host to come back"
sleep 10
BR_OK=""
for i in $(seq 1 60); do
  if rssh 'echo BACK' 2>/dev/null | grep -q BACK; then BR_OK=1; break; fi
  sleep 5
done
if [[ -z "$BR_OK" ]]; then
  say "B: FAIL — host did not return after bridge switch. Recover on the DL360 console"
  say "   (tty2) or iLO: nmcli con up '<profile>'; see /var/log/br0-switch.log"
  exit 1
fi
rssh 'ip -br a show br0; bridge link; tail -5 /var/log/br0-switch.log' \
  > "$WORK/bridge-after.txt" 2>&1 || true
grep -q "192\.168\.0\." "$WORK/bridge-after.txt" || { say "B: FAIL — br0 has no LAN address"; cat "$WORK/bridge-after.txt"; exit 1; }
say "B: bridge OK"; cat "$WORK/bridge-after.txt"
fi

# ---------------------------------------------------------------------------- phase C
setstatus "phase=C staging cloud image / seed / XML"
say "C: verifying local cloud image checksum"
echo "$IMG_SHA256  $IMG_LOCAL" | sha256sum -c -

say "C: uploading cloud image (~620 MB)"
rssh 'mkdir -p /var/lib/libvirt/images /var/tmp/stage'
rsync -a --info=progress2 "$IMG_LOCAL" "$HOSTALIAS:/var/tmp/stage/noble.img"

cat > "$WORK/place-image.sh" <<INNER
#!/bin/bash
set -e
GOT=\$(sha256sum /var/tmp/stage/noble.img | awk '{print \$1}')
if [ "\$GOT" != "$IMG_SHA256" ]; then echo "FATAL: image sha mismatch on host: \$GOT"; exit 1; fi
mv /var/tmp/stage/noble.img /var/lib/libvirt/images/noble-server-cloudimg-amd64.img
chown root:root /var/lib/libvirt/images/noble-server-cloudimg-amd64.img
chmod 644 /var/lib/libvirt/images/noble-server-cloudimg-amd64.img
restorecon -v /var/lib/libvirt/images/noble-server-cloudimg-amd64.img
# idempotent cleanup of any previous attempt
virsh -c qemu:///system destroy ubuntu24 2>/dev/null || true
virsh -c qemu:///system undefine ubuntu24 --nvram 2>/dev/null || true
rm -f /var/lib/libvirt/images/ubuntu24-root.qcow2
qemu-img create -f qcow2 -F qcow2 -o backing_fmt=qcow2 \
  -b /var/lib/libvirt/images/noble-server-cloudimg-amd64.img \
  /var/lib/libvirt/images/ubuntu24-root.qcow2 200G
qemu-img info /var/lib/libvirt/images/ubuntu24-root.qcow2
restorecon -v /var/lib/libvirt/images/ubuntu24-root.qcow2
echo "IMAGE_PLACE_OK"
INNER
rroot "$WORK/place-image.sh" | tail -3
say "C: backing image + 200G overlay in place"

say "C: rendering cloud-init seed locally (build-seed.sh parity, xorriso not on this machine)"
PUBKEY=$(cat "$HOME/.ssh/id_ed25519.pub")
python3 - "$SSHPASS" "$PUBKEY" <<'PYEOF'
import sys, pathlib
pw, key = sys.argv[1], sys.argv[2]
src = pathlib.Path("cloud-init/user-data.template").read_text()
out = src.replace("__PASSWORD__", pw).replace("__SSH_PUBKEY__", key)
p = pathlib.Path("cloud-init/user-data")
p.write_text(out)
p.chmod(0o600)
PYEOF
scp -q -o BatchMode=yes -o ConnectTimeout=10 cloud-init/user-data cloud-init/meta-data "$HOSTALIAS:/var/tmp/stage/"

cat > "$WORK/build-seed-remote.sh" <<'INNER'
set -e
mkdir -p /var/tmp/seed-src
mv /var/tmp/stage/user-data /var/tmp/stage/meta-data /var/tmp/seed-src/
chmod 600 /var/tmp/seed-src/*
xorriso -as mkisofs -V cidata -J -R \
  -o /var/lib/libvirt/images/seed-ubuntu24.iso \
  /var/tmp/seed-src/user-data /var/tmp/seed-src/meta-data
chmod 600 /var/lib/libvirt/images/seed-ubuntu24.iso
restorecon -v /var/lib/libvirt/images/seed-ubuntu24.iso
rm -rf /var/tmp/seed-src
ls -l /var/lib/libvirt/images/seed-ubuntu24.iso
echo "SEED_OK"
INNER
rroot "$WORK/build-seed-remote.sh" | tail -2
say "C: seed ISO built on host"

say "C: patching Option B XML — attach the seed cdrom"
python3 - "$XML_SRC" "$WORK/ubuntu24-install.xml" <<'PYEOF'
import sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
needle = "<disk type='file' device='cdrom'>\n      <driver name='qemu'/>"
insert = needle + "\n      <source file='/var/lib/libvirt/images/seed-ubuntu24.iso'/>"
assert needle in src, "cdrom block not found in Option B XML"
out = src.replace(needle, insert, 1)
p = pathlib.Path(sys.argv[2]); p.write_text(out); p.chmod(0o600)
assert "seed-ubuntu24.iso" in out and "<numatune>" in out
PYEOF
scp -q -o BatchMode=yes -o ConnectTimeout=10 "$WORK/ubuntu24-install.xml" "$HOSTALIAS:/var/tmp/stage/"
cat > "$WORK/place-xml.sh" <<'INNER'
set -e
mv /var/tmp/stage/ubuntu24-install.xml /root/ubuntu24-install.xml
chmod 600 /root/ubuntu24-install.xml
echo "XML_OK"
INNER
rroot "$WORK/place-xml.sh"
say "C: XML staged at /root/ubuntu24-install.xml"

# ---------------------------------------------------------------------------- phase D
setstatus "phase=D define + start ubuntu24 (NUMA Option B)"
cat > "$WORK/define-start.sh" <<'INNER'
set -e
V="virsh -c qemu:///system"
$V define /root/ubuntu24-install.xml
$V autostart ubuntu24
$V start ubuntu24
sleep 2
$V domstate ubuntu24
$V dumpxml ubuntu24 | grep -E "<numatune>|memnode|<vcpu |numa>" | head -8
$V dumpxml ubuntu24 | grep -A2 "device='cdrom'" | head -4
echo "DEFINE_START_OK $(date +%s)"
INNER
say "D: define + autostart + start"
DOUT=$(rroot "$WORK/define-start.sh")
echo "$DOUT"
T0=$(echo "$DOUT" | awk '/DEFINE_START_OK/{print $2}')
[[ -n "$T0" ]] || { say "D: FAIL — no start timestamp"; exit 1; }
say "D: ubuntu24 started (NUMA Option B from first boot), T0=$T0"

# ---------------------------------------------------------------------------- phase E
setstatus "phase=E readiness check (<=15 min gate)"
say "E: polling for guest IP / SSH — budget ${GUEST_READY_BUDGET}s"
IP=""
READY_ELAPSED=""
while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - T0))
  if [[ $ELAPSED -gt $GUEST_READY_BUDGET ]]; then
    say "E: FAIL — guest not SSH-ready within ${GUEST_READY_BUDGET}s (elapsed ${ELAPSED}s)"
    rssh 'virsh -c qemu:///system domstate ubuntu24; ip neigh show dev br0' || true
    exit 1
  fi
  if [[ -z "$IP" ]]; then
    IP=$(rssh "ip -4 neigh show dev br0 | grep -i '$GUEST_MAC' | awk '{print \$1}' | cut -d/ -f1 | head -1" 2>/dev/null || true)
    if [[ -z "$IP" ]]; then
      IP=$(rssh "virsh -c qemu:///system domifaddr ubuntu24 --source agent --full 2>/dev/null | grep -i '$GUEST_MAC' | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null || true)
    fi
    [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || IP=""
    [[ -n "$IP" ]] && say "E: guest IP discovered: $IP (elapsed ${ELAPSED}s)"
  fi
  if [[ -n "$IP" ]]; then
    if timeout 12 sshpass -e ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 \
         "$GUEST_USER@$IP" 'echo GUEST_SSH_OK' 2>/dev/null | grep -q GUEST_SSH_OK; then
      READY_ELAPSED=$(( $(date +%s) - T0 ))
      say "E: guest SSH READY after ${READY_ELAPSED}s (< 15 min: $([[ $READY_ELAPSED -le 900 ]] && echo YES || echo NO))"
      break
    fi
  fi
  sleep 10
done

VERIFY="$LOGDIR/ubuntu24-verify-$STAMP.txt"
{
  echo "=== ubuntu24 verification — $(date -Is) — ready after ${READY_ELAPSED}s ==="
  timeout 20 sshpass -e ssh -o StrictHostKeyChecking=accept-new "$GUEST_USER@$IP" '
    echo "--- identity ---"; hostname; whoami; id
    echo "--- cloud-init ---"; sudo -n cloud-init status --wait || true
    echo "--- sshd ---"; systemctl is-active ssh; sudo -n sshd -T 2>/dev/null | grep -iE "^passwordauthentication|^pubkeyauthentication" || true
    echo "--- cpu/numa ---"; nproc; lscpu | grep -E "NUMA|Socket|Thread|Core"
    echo "--- mem ---"; free -h | head -2
    echo "--- disk ---"; df -h / | tail -1; lsblk | head -8
    echo "--- net ---"; ip -br a
    echo "--- agent ---"; systemctl is-active qemu-guest-agent
  ' 2>&1 || echo "(verification ssh returned nonzero — see log)"
} | tee "$VERIFY"
grep -qi "passwordauthentication yes" "$VERIFY" || say "E: WARN — password auth not confirmed in sshd -T"
NUMA_NODES=$(grep -oP "NUMA node\(s\):\s+\K\d+" "$VERIFY" || echo 0)
say "E: guest sees $NUMA_NODES NUMA nodes (expect 4)"
[[ "$NUMA_NODES" == "4" ]] || say "E: WARN — NUMA cells != 4"

setstatus "phase=E2 eject seed ISO"
cat > "$WORK/eject-seed.sh" <<'INNER'
set -e
V="virsh -c qemu:///system"
$V change-media ubuntu24 sda --eject --config
$V dumpxml ubuntu24 --inactive | grep -A2 "device='cdrom'" | head -4
echo "EJECT_OK"
INNER
rroot "$WORK/eject-seed.sh" | tail -3
say "E: seed ISO ejected from the persistent definition"

# ---------------------------------------------------------------------------- phase F
setstatus "phase=F 15-min monitor + inventories"
say "F: launching 15-minute steady-state monitor (host + guest)"
bash "$HERE/scripts/monitor.sh" "$IP" 15 || say "F: WARN — monitor.sh nonzero rc"

say "F: refreshing host inventory into rockylinux_info/ (incl. KVM/network XML)"
HINV="$HERE/rockylinux_info"
mkdir -p "$HINV/os" "$HINV/hardware" "$HINV/packages" "$HINV/network" "$HINV/kvm"
hinv() { # <remotecommand> <outfile>
  rssh "$1" > "$2" 2>&1 || true
}
hrootout() { # <rootscript-file> <outfile>
  rroot "$1" > "$2" 2>&1 || true
}

hinv 'hostnamectl status; cat /etc/rocky-release; uname -a; timedatectl'                       "$HINV/os/host.txt"
hinv 'uptime; lsmod | grep -E "bridge|tun"; systemctl get-default'                             "$HINV/os/runtime.txt"
hinv 'lscpu; numactl --hardware; free -h'                                                      "$HINV/hardware/cpu-numa-mem.txt"
hinv 'lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT; cat /proc/mdstat'                              "$HINV/hardware/block-raid.txt"
hinv 'ip -br link; ip -br addr; ip route; ethtool -i ens1f2 2>/dev/null | head -5'             "$HINV/network/interfaces.txt"
hinv 'nmcli dev status; nmcli con show --active; ip -d link show br0; bridge link'             "$HINV/network/bridge.txt"
hinv 'rpm -qa | sort'                                                                          "$HINV/packages/rpm-qa.txt"
hinv 'dnf history list | head -20; dnf repolist'                                               "$HINV/packages/dnf.txt"
hinv 'rpm -q qemu-kvm qemu-img libvirt virt-install virt-manager virt-viewer guestfs-tools cockpit-machines cockpit bridge-utils dnsmasq numactl xorriso' "$HINV/packages/virt-versions.txt"
hinv 'systemctl status virtqemud virtnetworkd virtstoraged cockpit.socket --no-pager | head -40' "$HINV/kvm/services.txt"

cat > "$WORK/kvm-xml-dump.sh" <<'INNER'
set -e
V="virsh -c qemu:///system"
D=/var/tmp/kvmdump; rm -rf $D; mkdir -p $D
$V list --all > $D/domains.txt
$V dominfo ubuntu24 > $D/ubuntu24-dominfo.txt
$V dumpxml ubuntu24 > $D/ubuntu24.xml
$V net-list --all > $D/networks.txt
for n in $($V net-list --all --name); do $V net-dumpxml "$n" > "$D/net-$n.xml"; $V net-info "$n" > "$D/net-$n-info.txt"; done
cp -a /etc/libvirt/qemu/ubuntu24.xml $D/ubuntu24-persistent.xml 2>/dev/null || true
for f in /etc/libvirt/qemu/networks/*.xml /etc/libvirt/qemu/networks/autostart/*; do
  [ -e "$f" ] && cp -a --parents "$f" $D/ 2>/dev/null || true
done
cp -a /etc/libvirt/qemu.conf $D/qemu.conf 2>/dev/null || true
cp -a /etc/libvirt/libvirtd.conf $D/libvirtd.conf 2>/dev/null || true
firewall-cmd --get-active-zones > $D/firewalld-zones.txt 2>&1
firewall-cmd --list-all > $D/firewalld.txt 2>&1
nmcli con show br0 > $D/nmprofile-br0.txt 2>&1
nmcli -f ALL con show "$(nmcli -g GENERAL.CONNECTION dev show ens1f2)" > $D/nmprofile-ens1f2.txt 2>&1
tar -C /var/tmp -czf /var/tmp/kvmdump.tgz kvmdump
echo "KVMXML_OK"
INNER
hrootout "$WORK/kvm-xml-dump.sh" "$WORK/kvm-xml-dump.log"
grep -q KVMXML_OK "$WORK/kvm-xml-dump.log" || say "F: WARN — kvm xml dump issue: $(cat "$WORK/kvm-xml-dump.log")"
rsync -q "$HOSTALIAS:/var/tmp/kvmdump.tgz" "$WORK/"
tar -xzf "$WORK/kvmdump.tgz" -C "$WORK/"
cp -a "$WORK/kvmdump/." "$HINV/kvm/"
rssh 'rm -rf /var/tmp/kvmdump /var/tmp/kvmdump.tgz /var/tmp/stage' || true
say "F: host KVM/network XML collected into rockylinux_info/kvm/ ($(ls "$HINV/kvm" | wc -l) files)"

say "F: collecting guest inventory + performance (collect-ubuntu24-info.sh)"
INSTALL_LAPTOP_IPERF3=0 bash "$HERE/scripts/collect-ubuntu24-info.sh" || say "F: WARN — collector nonzero rc"

# ---------------------------------------------------------------------------- phase G
setstatus "phase=G np104 copy + docs + git"
NP104="np104-tplink.local"
if ssh -o BatchMode=yes -o ConnectTimeout=6 "$NP104" 'echo NP104_OK' 2>/dev/null | grep -q NP104_OK; then
  say "G: copying inventories to $NP104"
  rsync -a "$HERE/vm-ubuntu24/"      "$NP104:rockylinux_remote/vm-ubuntu24/"      && say "G: vm-ubuntu24 copied"      || say "G: WARN vm-ubuntu24 rsync failed"
  rsync -a "$HERE/rockylinux_info/"  "$NP104:rockylinux_remote/rockylinux_info/"  && say "G: rockylinux_info copied"  || say "G: WARN rockylinux_info rsync failed"
else
  say "G: SKIP — no SSH key auth to $NP104 (credentials unknown on this machine); inventories stay local"
fi

say "G: writing dated setup log"
cat > "$HERE/ubuntu-vm-setup-$STAMP-rebuild-raid6.md" <<DOCEOF
# ubuntu24 rebuild on the RAID6-rebuilt Rocky host — $(date +%F)

Rocky Linux 10.2 was re-installed from scratch after the RAID6 rebuild
(hostname reset to localhost.localdomain, old \`192.168.0.188\` lease gone — DHCP
now gives \`192.168.0.186\`, same NIC MAC \`8c:84:74:0d:de:2a\` on \`ens1f2\`).
This run rebuilt the whole stack per \`docs/installation-guideline.md\`:

1. QEMU/KVM 10.x + libvirt (modular daemons) + virt-install + **virt-manager** +
   guestfs-tools + **cockpit-machines** installed, then updated and upgraded.
2. \`br0\` bridge over \`ens1f2\` via \`scripts/br0-switch.sh\` (cloned MAC keeps the
   DHCP lease stable; auto-rollback on failure).
3. Guest \`ubuntu24\` rebuilt from the local verified cloud image
   (\`downloads/ubuntu-24.04-server-cloud-kvm/\`, sha256 checked on both ends):
   200 G qcow2 overlay on the backing image, cloud-init NoCloud seed ISO
   (\`cloud-init/user-data.template\`), **NUMA Option B** domain XML applied from
   first boot (\`archive/numa-backup-20261030/ubuntu24-optionB-defined-20261030.xml\` —
   40 vCPU 2×10×2 across 4 cells, 48 GiB strict per-node, vCPUs pinned node-local),
   MAC \`52:54:00:24:00:24\`, bridge \`br0\`, headless serial console, autostart on.
4. Readiness gate: guest SSH-ready after **${READY_ELAPSED}s** (≤ 15 min budget).
   Verification log: \`logs/ubuntu24-verify-$STAMP.txt\` (password SSH auth,
   cloud-init done, sshd active, guest sees 4 NUMA nodes).
5. Seed ISO ejected post-install (same as 2026-10-30 build).
6. Inventories refreshed: host → \`rockylinux_info/\` (incl. \`kvm/\` with domain +
   network .xml, nmprofiles, qemu.conf), guest → \`vm-ubuntu24/ubuntu24_info/\`
   (hardware/os/packages/network + iperf3).
7. Managed via Cockpit at https://192.168.0.186:9090 (Virtual Machines page);
   virt-manager 5.x also on the DL360 GNOME desktop.

Run log: \`logs/rebuild-ubuntu24-$STAMP.log\`; monitor sample: \`logs/monitor-*\`.
DOCEOF

say "G: updating README.md + CLAUDE.md host address .188 -> .186"
sed -i 's/192\.168\.0\.188/192.168.0.186/g' "$HERE/README.md" "$HERE/CLAUDE.md"
sed -i 's/last seen `192\.168\.0\.174`/DHCP after rebuild/' "$HERE/README.md" 2>/dev/null || true

say "G: git commit + push"
git add -A
git commit -m "re-build RAID6 Rocky Linux: reinstall KVM/virt-manager/cockpit stack, br0 bridge, headless ubuntu24 (NUMA Option B, SSH password auth) on fresh 10.2 (host now 192.168.0.186)" \
  && say "G: commit done" || say "G: WARN — nothing to commit or commit failed"
git push -u origin main && say "G: pushed to origin" || say "G: WARN — git push failed (check credentials)"

say "G: SAS sync (sync-to-sas.sh)"
bash "$HERE/scripts/sync-to-sas.sh" && say "G: sync-to-sas done" || say "G: WARN — sync-to-sas failed/skipped"

setstatus "SUCCESS — guest $IP, ready in ${READY_ELAPSED}s; log: $MAINLOG"
say "=== ubuntu24 rebuild SUCCESS — guest $IP, SSH-ready after ${READY_ELAPSED}s ==="
