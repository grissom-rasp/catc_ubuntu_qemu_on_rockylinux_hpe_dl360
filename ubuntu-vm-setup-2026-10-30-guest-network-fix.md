# ubuntu26 guest network fix — 2026-10-30

## Symptom

`ubuntu26` (Ubuntu 26.04 cloud image on libvirt default NAT, host `rocky-dl360` / 192.168.0.188) was "running" but had no IPv4:

- dnsmasq on the host logged zero DHCP handshakes since setup; lease table empty.
- Guest had only IPv6 link-local on `enp1s0`; `cloud-init` completed fine otherwise.
- Guest agent channel `state='disconnected'` (`qemu-guest-agent` was not in the image).

## Root causes (two)

1. **Stale MAC in guest netplan.** `/etc/netplan/50-cloud-init.yaml` matched
   `52:54:00:05:ca:d4` while the domain NIC MAC is `52:54:00:08:d9:12`
   (MAC evidently changed between VM definitions after the first boot wrote
   netplan). `dhcp4: true` therefore never applied → no DHCPDISCOVER ever sent.
2. **Netplan strict permissions (Ubuntu 26.04).** After the file was rewritten,
   netplan refused it until `chmod 0640` — its new backend rejects configs
   "accessible by others" (`Permissions for ... are too open` in syslog).

Red herrings worth remembering:

- `/run` (incl. `/run/systemd/network`, `/run/cloud-init`) is tmpfs — libguestfs
  **cannot** inspect guest runtime state; use persistent `/var/log/syslog`.
- libvirt 11.x native nft backend (`ip libvirt_network` table) only hooks
  FORWARD/POSTROUTING. There is intentionally **no `input` chain**; DHCP/DNS to
  the host relies on firewalld, where `virbr0` is bound to the `libvirt` zone.
  `firewall-cmd --get-active-zones` omits bindings whose interface didn't exist
  yet — check `--zone=libvirt --list-interfaces` instead.
- `virt-manager` is not shipped by EL10 / Rocky 10 AppStream nor EPEL 10
  (removed upstream in RHEL 10). Only `virt-manager-common` (dep of
  `virt-install`) exists. GUI = Cockpit Virtual Machines, or virt-manager on a
  laptop via `qemu+ssh://rocky-dl360/system`.

## Fix applied

1. `virsh shutdown ubuntu26`
2. `guestfish -d ubuntu26 -i`:
   - Moved broken config to `/etc/netplan/50-cloud-init.yaml.bak-mac-mismatch`
   - Wrote new `/etc/netplan/50-cloud-init.yaml`:
     ```yaml
     network:
       version: 2
       ethernets:
         enp1s0:
           dhcp4: true
           dhcp6: false
     ```
     (name-based match — no MAC dependency)
   - Wrote `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`:
     ```yaml
     network:
       config: disabled
     ```
     (prevents cloud-init regenerating netplan from its cached stale state)
   - `chmod 0640 /etc/netplan/50-cloud-init.yaml` (netplan 26.x requirement)
3. `virsh start ubuntu26` → lease obtained: **192.168.122.73**
4. In guest (SSH via `ssh -J rocky-dl360 capc@192.168.122.73`; key matches the
   one authorized by user-data):
   - `sudo apt-get install -y qemu-guest-agent`, `systemctl enable --now qemu-guest-agent.service`
     (Ubuntu 26.04 has **no** `qemu-guest-agent.socket` unit; use the service only)

## Verification (2026-10-30)

- `virsh net-dhcp-leases default` → lease for `52:54:00:08:d9:12` @ 192.168.122.73 — **PASS**
- SSH gate: `ssh -J rocky-dl360 capc@192.168.122.73 'hostname && ip -br a && ping -c1 192.168.122.1'`
  → `ubuntu26`, `enp1s0 UP 192.168.122.73/24`, gateway ping 0.145 ms — **PASS**
- Outbound: `curl -sI http://archive.ubuntu.com/` → HTTP 200 — **PASS**
- Guest agent: `virsh domifaddr --source agent` and `virsh domtime` respond — **PASS**

Note: guest reboot is fast now (~6 s cloud-init); the earlier 2-min userspace
startup was `systemd-networkd-wait-online` timing out while DHCP was broken.

---

# Host user rename capc → catc — 2026-10-30

- `groupmod -n catc capc` then `usermod -l catc -d /home/catc -m capc`, plus
  `restorecon -Rv /home/catc`, crontab/mail spool rename, AccountsService cleanup.
- All uid-1000 processes had to be dead first (usermod refuses otherwise):
  sessions terminated + `systemctl stop user@1000.service` + `pkill -KILL -u 1000`.
- **Process-survival traps** (two failed attempts before success):
  1. `setsid nohup` did NOT survive — the script stayed in the SSH session's
     systemd scope, so `loginctl terminate-user` killed it anyway.
  2. `systemd-run` from `/root` failed with `status=203/EXEC` (SELinux
     `admin_home_t` on the script). Staging the script at
     `/usr/local/sbin/` + `restorecon` fixed execution.
  Working recipe: write script to `/usr/local/sbin/`, `chmod 700`,
  `restorecon`, launch with `systemd-run --unit=<name> --on-active=5`.
- Post-rename: `ssh catc@192.168.0.188` (BatchMode) PASS; uid/gid/groups
  (wheel, libvirt) intact; `virsh list` works as catc; no `capc` left in /etc
  (except historical `-` backups and CUPS subscription artifacts, seds applied).
- Laptop `~/.ssh/config` `User capc` → `catc`; CLAUDE.md and memory updated.
- VM `ubuntu26` was found `shut off` afterwards (unrelated to rename; no journal
  error found) — restarted, re-verified: lease 192.168.122.73, SSH gate PASS.
- The Ubuntu **guest** account `capc` (from `vm-ubuntu26/user-data`) is unchanged;
  renaming it would be a separate cloud-init/seed task.