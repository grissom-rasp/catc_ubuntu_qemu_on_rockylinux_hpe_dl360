# Verification Matrix — `ubuntu24` on `rocky-dl360`

Run 2026-10-30. Guest IP at verification time: **192.168.0.174** (DHCP from 192.168.0.1).
Every row is a command with an observable result; the result column is what was actually
observed.

## Host (`rocky-dl360`, 192.168.0.188)

| # | Check | Result |
|---|---|---|
| H1 | `ssh -o BatchMode=yes rocky-dl360 'id -un'` | **PASS** — `catc` |
| H2 | root via stdin pattern (`sudo -S`) | **PASS** — `id -u` → `0` |
| H3 | `ip -4 -br a show br0` | **PASS** — `192.168.0.188/24` |
| H4 | `bridge link show` | **PASS** — `ens1f2 … master br0 state forwarding` |
| H5 | `ping -c3 192.168.0.1` | **PASS** — 0 % loss, 0.22 ms avg |
| H6 | `ping -c3 192.168.0.174` (host → guest) | **PASS** — 0 % loss, 0.35 ms avg |
| H7 | `virsh -c qemu:///system list` | **PASS** — `ubuntu24` running |
| H8 | `virsh dominfo` | **PASS** — 40 CPU, 49 152 MiB, autostart `enable` |
| H9 | `dumpxml` topology | **PASS** — `sockets='2' cores='10' threads='2'`, `memory mode='interleave' nodeset='0-3'`, `host-passthrough` |
| H10 | `systemctl is-active virtqemud virtnetworkd virtstoraged firewalld cockpit.socket` | **PASS** — all active |
| H11 | `virsh net-info default` | **PASS** — active, `virbr0` (NAT preserved) |
| H12 | `firewall-cmd --get-active-zones` | **PASS** — `public: br0`, `libvirt: virbr0` |
| H13 | Pool / disk accounting | **PASS** — overlay 200 GiB virtual, ≈2 GiB actual |
| H14 | SELinux labels on images | **PASS** — `system_u:object_r:virt_image_t:s0` |
| H15 | `systemctl --failed` | **PASS** — none |

## Guest (`ubuntu24`, 192.168.0.174)

| # | Check | Result |
|---|---|---|
| G1 | `virsh domifaddr ubuntu24 --source agent` | **PASS** — `enp1s0 52:54:00:24:00:24 ipv4 192.168.0.174/24` |
| G2 | `cloud-init status --long` | **PASS** — `status: done` |
| G3 | Key SSH from laptop | **PASS** — `catc_ubuntu_kvm`, `ubuntu24` |
| G4 | **Password-only SSH** (no key) | **PASS** — `passwordauthentication yes` path used |
| G5 | `sudo -n id -u` | **PASS** — `0` |
| G6 | `nproc` / `free -g` | **PASS** — 40 / 47 GiB usable |
| G7 | Root filesystem | **PASS** — `/dev/vda1 193G, 1% used`, disk `vda 200G` |
| G8 | `sshd -T` effective config | **PASS** — `passwordauthentication yes`, `kbdinteractiveauthentication yes`, `usepam yes`, `permitrootlogin no` |
| G9 | Drop-in ordering | **PASS** — `00-catc-password-auth.conf` present and effective |
| G10 | `systemctl is-enabled ssh.socket ssh.service` | **PASS** — both `enabled`; `ssh.service` active |
| G11 | `ufw status` | **PASS** — `inactive` (does not block 22) |
| G12 | Guest → gateway 192.168.0.1 | **PASS** — 0 % loss, 0.57 ms |
| G13 | Guest → host 192.168.0.188 | **PASS** — 0 % loss, 0.27 ms |
| G14 | Guest → laptop 192.168.0.100 | **PASS** — 0 % loss, 0.41 ms |
| G15 | Guest → Internet (`curl -sI http://archive.ubuntu.com/`) | **PASS** — `HTTP/1.1 200 OK` |
| G16 | DNS resolution | **PASS** — `getent hosts archive.ubuntu.com` resolves |
| G17 | `qemu-guest-agent` service | **PASS** — active |
| G18 | `systemctl --failed` | **PASS** — none |
| G19 | netplan MAC vs live MAC | **PASS** — fixed MAC `52:54:00:24:00:24` in both |
| G20 | Seed ISO ejected (`domblklist`) | **PASS** — `sda  -` |
| G21 | **Reboot persistence**: `virsh reboot` → password-only SSH | **PASS** — login succeeded, `uptime -p` = 1 minute, new session |
| G22 | SSH after reboot still enabled | **PASS** — `ssh.socket enabled`, `ssh.service active` |
| G23 | Cockpit installed | **PASS** — `cockpit 314-1`, `cockpit-ws`, `cockpit-bridge` |
| G24 | Cockpit service | **PASS** — `cockpit.socket` enabled + active, listening `*:9090` |
| G25 | Cockpit reachable from laptop | **PASS** — `https://192.168.0.174:9090` → 200 (self-signed cert) |
| G26 | Cockpit PAM login as `catc_ubuntu_kvm` | **PASS** — correct password → 200; wrong password → 401 |

## Notes on two results worth explaining

- **G21** is the requirement-critical one. It was run *after* the seed ISO was ejected, so it
  also proves the guest does not depend on the cloud-init medium — the password auth comes
  from files on disk (`00-*.conf`, guest shadow) and from `ssh.socket` being enabled.
- **`cloud-init status`** afterwards reports `disabled`: with the NoCloud seed gone, cloud-init
  finds no datasource. Expected; not a fault.

## Not run / not applicable

- `virsh net-dhcp-leases default` — the guest is **not** on the libvirt NAT network. Its
  lease lives in the LAN router; the address was obtained via the guest agent and `ip neigh`.
- PCI/VT-d passthrough — IOMMU is disabled in firmware and not needed here.
