# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this directory is

A workspace (not a git repo) of notes, scripts, and logs for remotely administering a bare-metal **HPE ProLiant DL360 Gen10+**, hostname of record `rocky-dl360`:

- Session normally runs on an **Ubuntu** laptop (`hp840g8.local`, **192.168.0.100** — verified 2026-10-30; the older `.151` was stale); every real target is reached **remotely over SSH** from here.
- Target host: `catc@192.168.0.188`, **Rocky Linux 10.2** (kernel 6.12), ssh alias `rocky-dl360` (passwordless, ed25519).
- `rocky-dl360`'s **sudo password equals its SSH password**, but sudo over SSH gets it via **stdin**, not env: see the pattern below.

## Credentials handling

- SSH/sudo password lives in `~/rockylinux_remote/.ssh-env` (`SSHPASS=...`, chmod 600) — `set -a && . .ssh-env && set +a` before use.
- **Never** write credentials into markdown logs, CLAUDE.md, commit messages, or command output that gets logged.

## Remote-command patterns (critical)

Bash expands inside the quoting you choose — two traps:

```bash
# WRONG: $SSHPASS expands on the REMOTE side (unset there) → empty sudo password
ssh rocky-dl360 'echo "$SSHPASS" | sudo -S true'

# CORRECT: pipe stdin locally; sudo -S consumes the first line, the rest goes to `bash -s`
( echo "$SSHPASS"; cat batch.sh ) | ssh -T -o BatchMode=yes rocky-dl360 'sudo -S -p "" bash -s'
```

- Prefer `ssh -T -o BatchMode=yes rocky-dl360 '<script>'`; batch remote work into one script per call.
- Long remote ops (dnf, image downloads): `run_in_background: true`, then read the task output file.

## KVM / Cockpit facts (set up 2026-10-29, guest replaced 2026-10-30)

- Installed: qemu-kvm 10.1, libvirt 11.10 (**modular daemons** — manage `virtqemud`/`virtnetworkd`/`virtstoraged`, not monolithic `libvirtd`), virt-install 5.1, libguestfs-tools, cockpit 356 + cockpit-machines.
- Services: `virtqemud/virtnetworkd/virtstoraged` + `cockpit.socket` enabled; firewalld has the `cockpit` service.
- Desktop: the DL360 **does** have a monitor attached and runs GNOME on Wayland (GDM on tty2) — graphics via the integrated Matrox MGA G200eH3 (iLO/BMC video). Do not assume it is headless.
- `virt-manager` 5.1 is **installed locally on the DL360** (2026-10-30) and can be launched from its GNOME desktop.
- GUI options: **virt-manager on the DL360 desktop**, **Cockpit at https://192.168.0.188:9090** (Virtual Machines page), or `virt-manager` from the laptop against `qemu+ssh://rocky-dl360/system` as a remote fallback.
- **Cockpit is also installed inside the `ubuntu24` guest** (cockpit 314): https://192.168.0.174:9090, PAM login as `catc_ubuntu_kvm`, socket-activated and enabled. It has no cockpit-machines package, so no VM page there.
- VM images live in `/var/lib/libvirt/images/` on the DL360.
- VT-x is enabled; VT-d/IOMMU is **not** (fine unless doing PCI passthrough).
- **Current guest (2026-10-30): `ubuntu24`** — Ubuntu 24.04 LTS headless cloud image, 40 vCPU
  (2×10×2), 48 GiB, 200 GiB thin qcow2, admin `catc_ubuntu_kvm` (sudo, key **and** password
  SSH, persists reboots), autostart enabled, serial console only.
- **LAN networking is now bridged**: `br0` over `ens1f2`, host keeps `192.168.0.188` via
  cloned MAC; the guest DHCPs from the router on 192.168.0.0/24 and is reachable from every
  LAN host *and* from Rocky. The NAT network `default`/`virbr0` still exists but is unused.
- `virsh net-dhcp-leases default` is **not** how to find the guest address any more — use
  `virsh -c qemu:///system domifaddr ubuntu24 --source agent` or `ip neigh … | grep 52:54:00:24:00:24`.
- The guest NIC MAC is fixed at `52:54:00:24:00:24` on purpose: a MAC baked into netplan went
  stale and silently killed DHCP on the previous guest.
- Host `sudo -n` does **not** work for `catc`; root actions need the stdin pattern below.
- `nohup`/`setsid` do not survive an SSH disconnect on this host — stage scripts in
  `/usr/local/sbin` and launch with `systemd-run --unit=… --collect`.

- `catc` is in the `libvirt` group, so plain `virsh ...` works over fresh SSH sessions.

## Local backup to 600G SAS disk

- 600G SAS disk: `/dev/sda` (HPE EG000600JXLV), mounted at `/mnt/sas-share`
  (btrfs), owned by `grissom-sas:grissom-sas`.
- Project mirror on that disk: `/mnt/sas-share/rockylinux_remote`
  (created/maintained with `scripts/sync-to-sas.sh`). Localhost copy is canonical;
  sync **overwrites** the SAS copy (rsync `-aH --delete`).
- A Claude Code `PostToolUse` (Bash) hook in `.claude/settings.local.json` runs
  `scripts/run-on-git-sync.sh`, which only invokes `scripts/sync-to-sas.sh` when
  the Bash command contains `git sync`. Project-scoped only.

## Directory layout

- `vm-ubuntu26/` — retired guest's cloud-init and seed (kept for history).
- `cloud-init/` — live cloud-init `meta-data` and `user-data.template`; the rendered
  `user-data` and `seed-ubuntu24.iso` are git-ignored (they contain the password).
- `scripts/` — `build-seed.sh`, `br0-switch.sh`, `br0-rollback.sh`, `monitor.sh`.
- `docs/` — installation guideline, verification matrix, monitoring analysis, legacy notes.
- `archive/` — XML/inventory of the removed `ubuntu26` domain.
- `ubuntu-vm-setup-YYYY-MM-DD.md` — step-by-step setup/ops logs for work done on the DL360. Append new work there (or a fresh dated log) rather than editing history.
- `.ssh-env` — credential env, chmod 600.

## Host-side gotchas

- `~/.bash_profile` on the laptop must not `exec zsh -l` unconditionally — non-interactive login bash must survive (Claude Code's Bash tool, `bash -lc`). The exec is guarded by `[[ $- == *i* ]] && [ -t 0 ]`; keep that guard.