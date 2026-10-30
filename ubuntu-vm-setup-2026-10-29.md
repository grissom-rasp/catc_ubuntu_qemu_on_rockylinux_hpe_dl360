# Ubuntu 26.04 LTS Server KVM Guest on Rocky DL360 — Setup Log

**Date:** 2026-10-29
**Workstation:** Ubuntu laptop (hp840g8.local / 192.168.0.151)
**Target host:** HPE ProLiant DL360 Gen10+ — `capc@192.168.0.188` (ssh alias `rocky-dl360`), Rocky Linux 10.2 (Red Quartz), kernel 6.12.0-211.16.1.el10_2.x86_64
**Credentials:** stored in `~/rockylinux_remote/.ssh-env` (chmod 600) — intentionally omitted from this log.

## Phase 0 — Fix Claude Code Bash tool (local prerequisite)

Every Bash tool call hung with no output. Root cause found: `~/.bash_profile` on the
laptop unconditionally `exec zsh -l`'d every login bash, so Claude Code's command
payload was discarded and an idle interactive zsh waited on stdin forever.

**Fix applied** (`~/.bash_profile`):

```sh
# Auto-launch zsh from *interactive* bash login shells only.
if [ -n "$BASH_VERSION" ] && [[ $- == *i* ]] && [ -t 0 ] && command -v zsh >/dev/null 2>&1; then
    exec zsh -l
fi
```

Verified: `echo probe-ok && pwd` returns instantly; `~/.bashrc`/`~/.profile` untouched;
interactive SSH logins still get zsh.

## Phase 1 — Passwordless SSH + sshpass to capc@192.168.0.188

- `sshpass` already installed locally (`/usr/bin/sshpass`); port 22 on 192.168.0.188 open.
- Password stored in `~/rockylinux_remote/.ssh-env` (`SSHPASS=...`, chmod 600).
- `id_ed25519` pubkey appended to `~capc/.ssh/authorized_keys` over the password
  connection; verified:
  - `ssh -o BatchMode=yes capc@192.168.0.188` → `PASSWORDLESS-OK` (user `capc`).
- Added `~/.ssh/config` alias:
  ```
  Host rocky-dl360
      HostName 192.168.0.188
      User capc
      IdentityFile ~/.ssh/id_ed25519
      IdentitiesOnly yes
  ```

> Gotcha noted: `sudo -S` over SSH gets its password via **stdin**, not environment —
> `$SUDOPASS` placed inside single-quoted remote command strings expands on the remote
> side (unset) and produces an empty sudo password. Correct pattern:
> `(echo "$SSHPASS"; cat commands.sh) | ssh -T rocky-dl360 'sudo -S -p "" bash -s'`.

## Phase 2 — Hardware virtualization check (DL360)

| Check | Result |
|---|---|
| CPU | Intel(R) Xeon(R) Silver 4310 @ 2.10GHz, 48 threads |
| **VT-x** | **Present** (`lscpu`: `Virtualization: VT-x`; `vmx` flag set) |
| VT-d / IOMMU | `/sys/class/iommu/` empty — IOMMU not enabled (BIOS or `intel_iommu=on`). **Not required for KVM; only needed for PCI passthrough.** |
| RAM | 62 GiB total, ~59 GiB available |
| Root filesystem | 70 G (`/dev/mapper/rl-root`), 64 G free |
| Prior KVM stack | none (`virsh`, `virt-install` absent); `cockpit-bridge` already present |

## Phase 3 — KVM/QEMU/libvirt + Cockpit install on the DL360

```
dnf -y install qemu-kvm libvirt virt-install libguestfs-tools cockpit cockpit-machines
systemctl enable --now virtqemud virtnetworkd virtstoraged
systemctl enable --now cockpit.socket
firewall-cmd --permanent --add-service=cockpit && firewall-cmd --reload
usermod -aG libvirt capc
```

Installed versions:

| Package | Version |
|---|---|
| qemu-kvm | 10.1.0-16.el10_2.5 |
| libvirt | 11.10.0-12.9.el10_2 (modular daemons) |
| virt-install | 5.1.0-2.el10 (virt-manager-common 5.1.0) |
| cockpit | 356.3-1.el10_2 |
| cockpit-machines | 348.1-1.el10_2 |

Post-install status: `virtqemud`, `virtnetworkd`, `virtstoraged`, `cockpit.socket` all
**active**; firewalld `cockpit` service already enabled (Cockpit was preinstalled —
only `cockpit-machines` needed adding). `capc` added to `libvirt` group and confirmed
via a fresh SSH login. `virsh list --all` runs as `capc` (empty list — no VMs yet).

GUI: **https://192.168.0.188:9090** (Cockpit, Virtual Machines page via cockpit-machines).

## Phase 4 — Ubuntu 26.04 cloud image + cloud-init

Files staged locally in `~/rockylinux_remote/vm-ubuntu26/` (`user-data`, `meta-data`,
`seed.iso` built with `xorriso -as mkisofs -o seed.iso -V cidata -J -R user-data meta-data`).
`user-data` creates user `capc` (NOPASSWD sudo, our ed25519 key, key-only SSH, no password),
hostname `ubuntu26`, `package_update: true`.

On the DL360 (as root, via `ssh -T rocky-dl360 'sudo -S -p "" bash -s'`):

```
cd /var/lib/libvirt/images
curl -L -o ubuntu-26.04-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img
# → 859,090,944 bytes, qcow2, virtual 3.5 GiB (codename: resolute)
qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/ubuntu-26.04-server-cloudimg-amd64.img \
  -o backing_fmt=qcow2 ubuntu26-root.qcow2 40G
cp /tmp/seed.iso /var/lib/libvirt/images/seed-ubuntu26.iso   # scp'd from the laptop

virt-install --name ubuntu26 --memory 8192 --vcpus 4 --cpu host-passthrough \
  --disk path=/var/lib/libvirt/images/ubuntu26-root.qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/seed-ubuntu26.iso,device=cdrom,bus=sata \
  --network network=default,model=virtio --os-variant ubuntu24.04 \
  --import --graphics none --console pty,target_type=serial --noautoconsole
```

Notes:
- `osinfo-query os` has **no ubuntu26.04 entry yet** → used `--os-variant ubuntu24.04`.
- **Gotcha:** seed ISO with `device=cdrom` on `bus=virtio` fails —
  "unsupported configuration: disk type of 'vdb' does not support ejectable media".
  Use `bus=sata` for the seed CD-ROM.
- VM created as **running** on libvirt `default` network (NAT, 192.168.122.x).
- **Gotcha:** `virsh` as non-root defaults to `qemu:///session`, which sees **no**
  domain and **no** networks — it silently looks like everything disappeared. Always
  use `virsh -c qemu:///system`; for `capc` the default URI is now exported in
  `~capc/.bashrc` (`export LIBVIRT_DEFAULT_URI=qemu:///system`).
- First `virsh domifaddr` poll returned no lease because the domain was started before
  the `default` network was active; restarting the domain reattaches the NIC and the
  lease appears on the next boot.

### Debugging trail — guest boots but never gets a DHCP lease

Timeline of evidence collected (all on the DL360, as root):

1. First symptom: `virsh domifaddr ubuntu26` empty, no `default.leases` entries, no
   SSH into the guest — though `virsh list` shows `running`.
2. Red herring #1: QEMU argv contained `-S`. This is **normal** for libvirt-launched
   guests (libvirt starts qemu paused, then issues `cont`); QMP `query-status` and
   `info status` both report `running`.
3. KVM acceleration confirmed healthy: `/dev/kvm` exists, `kvm_intel` loaded with
   users, nested=Y.
4. `tcpdump -i virbr0` for 15 s: **0 packets** from the guest (no ARP, no DHCP, no
   ICMPv6) while `dnsmasq` is listening on `virbr0:67` with DHCP range
   192.168.122.2–254.
5. `info registers 0`: `RIP=ffffffff96f28f0b` (Linux kernel virtual address) and
   `HLT=1`, `CPL=0` — the guest **kernel is executing**, currently halted/idle.
   `CPU time` accrues only slowly (14.5 s → 22 s across minutes).
6. Serial console captures (`virsh console` attach after boot, then from t=0 with
   `ssh -tt`): **no serial output at all** so far.

Working hypothesis at this point: guest kernel boots but wedges early (e.g. waiting
on a clocksource/IRQ), or boots fine and emits nothing on serial with a NIC that
never comes up. Fresh-VM test without `--cpu host-passthrough` + t=0 console capture
underway to separate the two. Verification runs in Phase 5.

Verification runs in Phase 5.