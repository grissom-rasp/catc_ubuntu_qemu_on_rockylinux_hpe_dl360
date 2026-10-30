# Installation Guideline — Headless Ubuntu 24.04 LTS KVM Guest on Rocky Linux 10.2 (HPE DL360 Gen10+)

**Date:** 2026-10-30
**Host:** `rocky-dl360` — HPE ProLiant DL360 Gen10+, Rocky Linux 10.2 (Red Quartz), kernel 6.12
**Guest:** `ubuntu24` — Ubuntu 24.04 LTS (noble) cloud image, headless, bridged
**Replaces:** `ubuntu26` — Ubuntu 26.04 cloud image on libvirt NAT (4 vCPU / 8 GiB / 40 G)
**Operator workstation:** Ubuntu laptop `192.168.0.100` (the older `192.168.0.151` in
`CLAUDE.md` was stale; corrected in this work)

---

## 1. Target topology

```
                192.168.0.0/24  (LAN, DHCP served by the router 192.168.0.1)
                                        │
                            ┌───────────┴────────────┐
                            │                        │
                   rocky-dl360 .188            ubuntu24 .174 (DHCP)
                   ┌──────────────────┐       ┌──────────────────┐
                   │ ens1f2 ══ br0    │◄─────►│ enp1s0 virtio    │
                   │ Rocky 10.2 host  │  L2   │ Ubuntu 24.04     │
                   │ 48 threads/62 GiB│ bridge│ 40 vCPU / 48 GiB │
                   │ libvirt 11.10    │       │ 200 G thin qcow2 │
                   └──────────────────┘       └──────────────────┘
                            │
                    virbr0 192.168.122.1/24  (libvirt NAT, kept for future guests)
```

Because the guest is an L2 peer on the LAN, every LAN machine can reach it directly and
the Rocky host can reach it too — unlike macvtap, which would block host↔guest traffic.

---

## 2. Sizing decisions and their rationale

The requested hardware was 64 GB RAM, 48 vCPU, 300 GB disk. Three of those cannot be
honoured safely on this host; the agreed values are below.

| Parameter | Requested | Built | Why |
|---|---|---|---|
| RAM | 64 GB | **48 GiB** (`--memory 49152`) | Host `MemTotal` is 62.3 GiB. A 64 GB guest cannot be backed by physical RAM; the host would OOM-kill qemu or itself. 48 GiB leaves ~10–14 GiB for the host, page cache and Cockpit. |
| vCPU | 48 | **40** (`sockets=2,cores=10,threads=2`) | The Xeon Silver 4310 exposes 48 logical CPUs. 48 vCPU consumes every thread, leaving nothing for libvirt, storage I/O or the host kernel. 40 leaves 8 threads. |
| Disk | 300 G | **200 G virtual**, thin | A qcow2 is thin-provisioned: 200 G is a ceiling, not a reservation (actual usage after install ≈ 2 GiB). The host's `rl-root` holds `/var/lib/libvirt/images` and has only ~61 GiB free, so the *real* near-term limit is ~61 GiB. Growth path in §9. |
| Network | bridge on 192.168.0.0/24 + DHCP | **Linux bridge `br0`**, DHCP from the router | The host is itself on that subnet; running a DHCP server on the host would conflict with the router. A bridge makes the guest a normal LAN host. |
| "Shared memory" | — | ordinary RAM | Interpreted as normal anonymous guest RAM shared with the host via overcommit/THP. No hugepages are configured on this host (KSM off, THP `always`). |

> NUMA: the host has **4 nodes of ~15.7 GiB**. A 48 GiB guest cannot bind to one node, so
> the domain is created with `<memory mode='interleave' nodeset='0-3'/>`
> (`--numatune 0-3,memory.mode=interleave`) to spread memory evenly instead of making
> every access to three quarters of RAM remote.

---

## 3. Prerequisites

Already present on the host and verified during this build:

- `qemu-kvm` 10.1, `libvirt` 11.10 (modular daemons `virtqemud`/`virtnetworkd`/`virtstoraged`),
  `virt-install` 5.1, `guestfish`, `xorriso`, `qemu-img`, `cockpit` + `cockpit-machines`.
- VT-x enabled (VT-d/IOMMU is **not** enabled — only needed for PCI passthrough).
- `catc` in groups `wheel` and `libvirt`; passwordless **sudo is not** configured.

Operator-side conventions used throughout (from `CLAUDE.md`):

```bash
# root command over SSH: password goes in on stdin, never in the command string
( echo "$SSHPASS"; cat script.sh ) | ssh -T -o BatchMode=yes rocky-dl360 'sudo -S -p "" bash -s'
```

Always address the system instance of libvirt explicitly (`virsh -c qemu:///system`),
otherwise a non-interactive shell falls back to `qemu:///session` and sees no domains.

---

## 4. Phase 1 — Remove the old guest

Archive first, then delete; `--remove-all-storage` unlinks the disks listed in the domain
XML but **not** the qcow2 backing file.

```bash
install -d -m 700 /root/vm-archive
virsh -c qemu:///system dumpxml ubuntu26 > /root/vm-archive/ubuntu26-domain.xml
virsh -c qemu:///system domblklist ubuntu26 >> /root/vm-archive/ubuntu26-dominfo.txt

virsh -c qemu:///system shutdown ubuntu26        # waited <= 60 s, guest agent present
virsh -c qemu:///system undefine ubuntu26 --remove-all-storage
rm -f /var/lib/libvirt/images/ubuntu-26.04-server-cloudimg-amd64.img   # 859 MB base
virsh -c qemu:///system pool-refresh images
```

Result: `virsh list --all` empty, pool free space back to ~63 GiB. The domain XML and
inventory are preserved in `archive/`.

The old seed ISO contained **no** password (`lock_passwd: true`, key-only), so only the
archived XML is retained; no secret was involved.

---

## 5. Phase 2 — Convert `ens1f2` into bridge `br0`

`ens1f2` is the only cabled NIC and carries the host's own SSH address, so this is the one
step that can lock the operator out. It is executed by a detached unit with an automatic
rollback.

### 5.1 The failure that was hit first (worth knowing)

A first attempt created the bridge profile and re-pointed `ens1f2` at it, but **did not set
`connection.autoconnect-slaves`**. NetworkManager created `br0` with no port attached:

```
br0  DOWN  <NO-CARRIER>       # no port
ens1f2 UP  192.168.0.188/24  # still standalone, still serving SSH
```

A ping test to the gateway passed — over the *old* path — so the script reported success
while the bridge was inert. The corrected script therefore asserts **topology**, not just
reachability:

- `br0` has an `192.168.0.x` address,
- `ens1f2` has **no** IPv4 address,
- `br0` is not `NO-CARRIER`,
- the gateway answers.

### 5.2 Procedure

Run as root via a transient unit so an SSH drop cannot abort it mid-flight
(`nohup`/`setsid` die with the SSH session's scope on this host; `systemd-run` does not):

```bash
install -m 700 -o root -g root br0-switch.sh /usr/local/sbin/br0-switch.sh
restorecon -v /usr/local/sbin/br0-switch.sh     # SELinux: admin_home_t is not executable
systemd-run --unit=br0-switch --collect /usr/local/sbin/br0-switch.sh
```

The script (`scripts/br0-switch.sh`) does:

1. Records the incumbent NM profile name (`Wired connection 7`) and saves it to
   `/root/vm-archive/`.
2. Disables autoconnect on the unused duplicate `ens1f2` profile so nothing can steal the
   device.
3. Creates `br0` (`ipv4.method auto`, `bridge.stp no`, `bridge.forward-delay 0`,
   `ethernet.cloned-mac-address = NIC MAC`), and sets `connection.autoconnect-slaves 1`.
4. Turns the incumbent profile into the bridge port:
   `nmcli con mod "Wired connection 7" connection.master br0 connection.slave-type bridge`.
5. Brings `br0` up and waits up to 120 s for the topology check above.
6. On failure, strips the slave settings, deletes `br0`, and re-activates the original
   profile (with a second connectivity check and a console/iLO instruction if even that
   fails).

Cloned MAC is why the host kept `192.168.0.188`: the DHCP request uses the same MAC and
client-id as before. Manual rollback: `scripts/br0-rollback.sh`, or from the DL360's own
GNOME console on tty2 (`CLAUDE.md` notes the DL360 has a monitor attached) or iLO.

Verified result:

```
br0    UP  192.168.0.188/24  8c:84:74:0d:de:2a
ens1f2 UP                    master br0 state forwarding      (no IPv4)
default via 192.168.0.1 dev br0
```

### 5.3 firewalld

`br0` lands in the default `public` zone, which already allows `ssh`. `ens1f2` keeps an
inert binding that firewalld re-adds because NetworkManager owns the device; it is
cosmetic. `br_netfilter` is **not** loaded on this host, so bridged guest↔LAN frames bypass
netfilter entirely — the host firewall only filters traffic addressed to the host itself.

---

## 6. Phase 3 — cloud-init seed

Rendered from `cloud-init/user-data.template` by `scripts/build-seed.sh`, which substitutes
the password from `.ssh-env` and the laptop's public key, then builds the ISO with the
mandatory NoCloud volume label:

```bash
xorriso -as mkisofs -o cloud-init/seed-ubuntu24.iso -V cidata -J -R \
        cloud-init/user-data cloud-init/meta-data
```

`-V cidata` is not optional: cloud-init's NoCloud datasource matches on the volume label,
and a wrong label means the VM boots with no user and no SSH.

What the template guarantees:

| Requirement | Mechanism |
|---|---|
| Admin user `catc_ubuntu_kvm` with sudo | `users:` entry, `sudo: ALL=(ALL) NOPASSWD:ALL`, groups `adm,sudo` |
| Password supplied by the operator | `plain_text_passwd`, `lock_passwd: false`, `chpasswd: {expire: false}` — value lives only in `~/rockylinux_remote/.ssh-env` and the seed ISO |
| SSH password login, **persistent across reboots** | `ssh_pwauth: true` **and** a `write_files` drop-in `/etc/ssh/sshd_config.d/00-catc-password-auth.conf` |
| Key login | `ssh_authorized_keys` with the laptop `id_ed25519.pub` |
| Guest agent | `packages: [qemu-guest-agent]` + `systemctl enable --now` |
| No stale netplan | domain NIC has a **fixed MAC** (`52:54:00:24:00:24`) |

The sshd detail matters: sshd uses the **first** value it reads per keyword, and drop-ins
are read in lexical order (`Include /etc/ssh/sshd_config.d/*.conf`) at the top of
`sshd_config`. The image ships `60-cloudimg-settings.conf` with
`PasswordAuthentication no`. A `60-*` file would lose; a **`00-*` file wins outright**.

Verified inside the guest:

```
/etc/ssh/sshd_config.d/00-catc-password-auth.conf
/etc/ssh/sshd_config.d/50-cloud-init.conf        # written by cloud-init (ssh_pwauth: true)
/etc/ssh/sshd_config.d/60-cloudimg-settings.conf

$ sudo sshd -T | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|usepam|permitrootlogin)'
passwordauthentication yes
kbdinteractiveauthentication yes
usepam yes
permitrootlogin no
```

The seed ISO contains the password in cleartext: it is `0600 root:root` on the host and is
**ejected after first boot** (see §7.4), so a running VM has no such medium attached.

---

## 7. Phase 4 — Image, disk, domain

### 7.1 Base image

```bash
cd /var/lib/libvirt/images
curl -fL -o noble-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
echo "04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94  noble-server-cloudimg-amd64.img" \
  | sha256sum -c
```

→ 621,284,352 bytes, qcow2, virtual 3.5 GiB. Always pin a checksum; this is the entire root
filesystem of the guest.

### 7.2 Thin overlay

```bash
qemu-img create -f qcow2 -F qcow2 -o backing_fmt=qcow2 \
  -b /var/lib/libvirt/images/noble-server-cloudimg-amd64.img \
  /var/lib/libvirt/images/ubuntu24-root.qcow2 200G
restorecon -v /var/lib/libvirt/images/{noble-server-cloudimg-amd64.img,ubuntu24-root.qcow2,seed-ubuntu24.iso}
```

`restorecon` matters: files created by root outside libvirt keep `unconfined_u` in the user
field and must carry `virt_image_t` to be usable by `svirt_t` in enforcing mode.

### 7.3 Domain creation

```bash
virt-install --connect qemu:///system \
  --name ubuntu24 \
  --description "Ubuntu 24.04 LTS server cloud image, headless, bridged br0" \
  --os-variant ubuntu24.04 \
  --memory 49152 \
  --vcpus 40,sockets=2,cores=10,threads=2 \
  --cpu host-passthrough \
  --numatune 0-3,memory.mode=interleave \
  --disk path=/var/lib/libvirt/images/ubuntu24-root.qcow2,bus=virtio,cache=none,io=native,discard=unmap,detect_zeroes=unmap \
  --disk path=/var/lib/libvirt/images/seed-ubuntu24.iso,device=cdrom,bus=sata \
  --network bridge=br0,model=virtio,mac=52:54:00:24:00:24 \
  --graphics none --console pty,target_type=serial \
  --import --noautoconsole --autostart
```

Non-obvious flags:

- **`--vcpus 40,sockets=2,cores=10,threads=2`** — without an explicit topology virt-install
  renders 40 vCPUs as *40 sockets*, which misinforms the guest scheduler about SMT.
- **`--numatune ... memory.mode=interleave`** — 48 GiB cannot fit in one 15.7 GiB node;
  `strict` would fail outright.
- **`discard=unmap,detect_zeroes=unmap`** — lets `fstrim` return blocks to the thin qcow2.
- **seed on `bus=sata`** — a `device=cdrom` on `bus=virtio` fails with
  "disk type of 'vdb' does not support ejectable media".
- **fixed `mac=`** — prevents the netplan/cloud-init MAC-mismatch bug that broke the
  previous guest.
- `--autostart` — the removed guest had autostart disabled; this one starts with the host.

### 7.4 Post-boot: eject the seed

```bash
virsh -c qemu:///system change-media ubuntu24 sda --eject --live --config
```

After the eject, `cloud-init status` reports `disabled` on later boots (no datasource).
That is expected and harmless: nothing in the guest depends on the seed.

---

## 8. Phase 5 — Verification

Full PASS/FAIL table in [`verification-matrix.md`](verification-matrix.md). Summary:

- Guest obtained `192.168.0.174/24` by **DHCP from the LAN router** through `br0`.
- Key SSH, **password-only SSH**, and `sudo -n` all work from the laptop.
- Guest → gateway, guest → host, guest → laptop, guest → Internet, **host → guest** — all
  0 % packet loss.
- After `change-media --eject` + `virsh reboot`, password-only SSH still works (uptime
  1 minute, new session) — the reboot-persistence requirement passes.

---

## 9. Operations

```bash
# console (from an interactive terminal; Ctrl+] to exit)
virsh -c qemu:///system console ubuntu24

# state / config
virsh -c qemu:///system dominfo ubuntu24
virsh -c qemu:///system domstats ubuntu24 --state --cpu-total --balloon

# graceful stop / start (autostart is enabled)
virsh -c qemu:///system shutdown ubuntu24
virsh -c qemu:///system start ubuntu24

# find today's address (DHCP may renumber after a router restart)
virsh -c qemu:///system domifaddr ubuntu24 --source agent
ip neigh show dev br0 | grep 52:54:00:24:00:24
```

**Growing the disk.** The 200 G ceiling can be raised and then extended inside the guest
(`growpart`/`resize2fs`), but the host filesystem must have the space first:

- now: ~61 GiB free on `rl-root`;
- `/home` (`rl-home`) has ~487 GiB free and could host a second dir pool with
  `semanage fcontext -a -t virt_image_t "/home/libvirt-images(/.*)?`;
- long term, the DL360 has a second LUN — **`sdb`, 1.2 TB, entirely unused** (unpartitioned,
  unmounted, absent from `/etc/fstab`; `sda` is the 600 GB disk that already carries the
  `rl-*` LVM volumes) — partition it, `mkfs.xfs`, label it, mount it, label `virt_image_t`,
  and define a new dir pool. That is the real "grow later" path.

**Seed regeneration** (if the password or key changes): `./scripts/build-seed.sh`, scp the
ISO, re-attach with `change-media --insert`, `virsh reboot`, then eject again. Changing the
password inside a running guest is simpler: `sudo passwd catc_ubuntu_kvm`.

---

## 9a. Cockpit Web UI on the guest

Cockpit is available from Ubuntu 24.04 `universe` and listens on **9090/tcp** (HTTPS,
self-signed certificate on first use):

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
     cockpit cockpit-networkmanager cockpit-packagekit cockpit-storaged
sudo systemctl enable --now cockpit.socket
```

Verified (`cockpit 314-1`): `cockpit.socket` `enabled` + `active`, listening on `*:9090`,
`curl -k https://192.168.0.174:9090/` → **200** from the laptop, and the PAM login endpoint
returns **200** for `catc_ubuntu_kvm` with the correct password, **401** for a wrong one.

- Admin view comes from the `sudo` group membership — no extra Cockpit role needed.
- `ufw` is inactive on the guest, so no firewall change was required. If `ufw` is ever
  enabled, run `sudo ufw allow 9090/tcp` (or restrict it to 192.168.0.0/24).
- URL: **https://192.168.0.174:9090** — the browser will warn about the self-signed
  certificate; that is expected.
- `cockpit.socket` is socket-activated and enabled, so it survives reboots. The Ubuntu
  package does **not** ship `cockpit-machines`, so the guest's Cockpit has no Virtual
  Machines page — guests are managed from Rocky's Cockpit or `virsh`.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `br0` exists but is `NO-CARRIER`; host keeps its old IP | `connection.autoconnect-slaves` not set | `nmcli con mod br0 connection.autoconnect-slaves 1` then `nmcli con up br0` |
| Host SSH died after the bridge switch | NIC was being reconfigured | Wait for the watchdog; otherwise console: `nmcli con up "Wired connection 7"` |
| Host reachable on a different `192.168.0.x` | Router gave a new lease | Find by MAC: `ip neigh`, or the router's lease page; update `~/.ssh/config` |
| Guest has no IPv4 | DHCP not reachable through the bridge, or ufw | `virsh console ubuntu24`, `ip a`, `systemctl status systemd-networkd`, `sudo ufw status` |
| Password SSH refused after a reboot | a later drop-in disabled it | `sudo sshd -T \| grep -i passwordauth`; ensure `00-*.conf` sorts first |
| VM won't start, AVC denials | wrong SELinux label on disk | `restorecon -vF /var/lib/libvirt/images/*` |
| `virsh list` empty | default URI is `qemu:///session` | always pass `-c qemu:///system` |

---

## 11. Security notes

- The password appears in the seed ISO and in the guest's shadow database only. The ISO is
  `0600 root`, is git-ignored, and is ejected after provisioning.
- `PermitRootLogin no`, password auth limited to the admin account, key auth also enabled.
- The guest is on the LAN with host firewall bypassed for bridged frames (no
  `br_netfilter`): the guest's own sshd/ufw is its perimeter. `ufw` is installed but
  **inactive** by default on the cloud image; enable it deliberately if required.
- Consider a DHCP reservation for MAC `52:54:00:24:00:24` on the router so the guest always
  gets the same address.
