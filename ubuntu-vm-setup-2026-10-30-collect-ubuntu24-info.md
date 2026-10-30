# ubuntu24 info collection — 2026-10-30

## What was done

Collected a full local inventory of the KVM guest **`ubuntu24`** (Ubuntu 24.04.5
LTS, bridged on host `br0`, IP 192.168.0.174, MAC `52:54:00:24:00:24`) running on
`rocky-dl360` (192.168.0.188) into **`vm-ubuntu24/ubuntu24_info/`** (50 files,
~336K) — the guest counterpart of `rockylinux_info/`:

- `hardware/` — vCPU/storage/memory/PCI-USB (40 vCPU Xeon Silver 4310 passthrough,
  48 GiB, `vda` 200 GiB virtio)
- `os/` — kernel, systemd, identity, effective sshd, firewall, time/locale, journals
- `packages/` — 705 installed debs (`installed-packages.tsv`), key packages,
  apt sources/history, upgradable, held, other managers
- `network/` — interfaces, netplan, DNS, ethtool, connectivity
- `network/performance/` — iperf3 install log + laptop↔guest, host↔guest and
  internet probes
- `verification.md` — V1–V10 gate/results table
- per-folder `README.md` indexes; top `README.md` with machine-at-a-glance and the
  do-not-publish note (tree is git-ignored, same sensitivity class as
  `rockylinux_info/`)

Deliverable script: **`scripts/collect-ubuntu24-info.sh`** (run once from the
laptop; knobs `REMOVE_IPERF3`, `INSTALL_LAPTOP_IPERF3`, `IPERF_PORT`, `IPERF_TIME`).

## How it ran

1. Preflight gate on the host (`ssh -o BatchMode=yes rocky-dl360 'id -un'` → `catc`),
   guest IP via `virsh -c qemu:///system domifaddr ubuntu24 --source agent`,
   guest gate `ip a && ping -c1 192.168.0.1`, guest `sudo -n id -u` → 0.
2. Read-only 4-category collection over BatchMode SSH as `catc_ubuntu_kvm@$G`
   (privileged reads `sudo -n`), one command per `ssh`, `===== label =====` /
   `# CMD:` headers, failures into per-category `_errors.txt`.
3. iperf3 installs (debconf pre-seeded `iperf3/start_daemon boolean false` to avoid
   the interactive prompt; `--force-confold`), then the test matrix with the
   guest as server on :5201 (stopped afterwards via `pkill -F /tmp/iperf3-srv.pid`).
4. Credential sweep `grep -rlF "$SSHPASS" vm-ubuntu24/ubuntu24_info/` → 0 matches.

## Mutation register

| # | Mutation | Where |
|---|---|---|
| M1 | `apt-get install -y iperf3` (3.16) | guest `ubuntu24` |
| M2 | `dnf -y install iperf3` (3.17.1) via `sudo -S -k` stdin | host `rocky-dl360` |
| M3 | `apt install iperf3` (3.20) | laptop |
| M4 | iperf3 server started/stopped on guest :5201 | guest (confirmed stopped) |
| M5 | `REMOVE_IPERF3=0` → **keep** iperf3 (see `network/performance/iperf3-decision.txt`) | — |
| M6 | workspace writes: `vm-ubuntu24/ubuntu24_info/**`, this log, `.gitignore` line, `scripts/collect-ubuntu24-info.sh` | repo (uncommitted; tree ignored) |

No firewalld/ufw/nft changes, no service enable/disable, no sysctl, no libvirt
changes, no `/etc/shadow` or key material collected.

## Verification summary (full table: `vm-ubuntu24/ubuntu24_info/verification.md`)

| # | Check | Result |
|---|---|---|
| V1 | host SSH `id -un` | **PASS** — `catc` |
| V2 | `domifaddr ubuntu24 --source agent` | **PASS** — enp1s0 52:54:00:24:00:24 ipv4 192.168.0.174/24 |
| V3 | guest gate `ip a && ping -c1 192.168.0.1` | **PASS** — up, gateway 0% loss |
| V4 | guest `sudo -n id -u` | **PASS** — `0` (NOPASSWD) |
| V5 | iperf3 laptop→guest | **PASS** — 938 Mbits/sec receiver (≈1 GbE LAN limit) |
| V6 | iperf3 guest→laptop (`-R`) | **PASS** — 938 Mbits/sec receiver |
| V7 | iperf3 host→guest | **PASS** — 37.4 Gbits/sec receiver |
| V8 | iperf3 guest→host (`-R`) | **PASS** — 60.3 Gbits/sec receiver |
| V9 | iperf3 guest→internet | **SKIP** — no public iperf3 server reachable; curl probe http=200 (144 900 B/s on a small file) |
| V10 | credential sweep over output tree | **PASS** — 0 matches |

## Notes / lessons

- First run hung on the guest iperf3 debconf dialog ("Start iperf3 as a daemon?");
  fixed by pre-seeding `iperf3 iperf3/start_daemon boolean false` +
  `-o Dpkg::Options::=--force-confold` before `apt-get`.
- Multi-word remote commands failed rc=127 under the non-login shell; the collector
  now wraps each command in `bash -lc`, and every first-run failure was re-collected
  manually (`_errors.txt` entries marked `[superseded … 2026-10-30]`).
- Host root still only via the stdin pattern `( echo "$SSHPASS"; cat cmds ) |
  ssh -T -o BatchMode=yes rocky-dl360 'sudo -S -k -p "" bash -s'`; `sudo -n` does
  not work for `catc` on the host. Guest uses `sudo -n` only.
- The 1 GbE laptop↔guest ceiling is the LAN uplink, not the VM; host↔guest over
  the in-host bridge reaches tens of Gbit/s.
