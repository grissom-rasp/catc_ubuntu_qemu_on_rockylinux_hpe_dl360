# Monitoring and Optimization — 15-Minute Steady State

**Window:** 2026-10-30 02:40–02:55 UTC (22:40–22:55 EDT), 30 samples at 30 s
**Method:** `scripts/monitor.sh` — laptop-side sampler; one SSH round-trip per host and per
guest per sample, raw logs kept in `logs/monitor-20261030-0240/`.
**Guest address during the run:** 192.168.0.174 · `ubuntu24` · 40 vCPU / 48 GiB.

## 1. Headline numbers

| Metric | Rocky host | Ubuntu guest |
|---|---|---|
| CPU user / system / **idle** | 0.5 % / 0.8 % / **98.3 %** | 0.0 % / 0.0 % / **100 %** |
| **CPU steal** | **0.0 %** | **0.0 %** |
| iowait | 0.0 % | 0.0 % |
| Memory available | 57.0–57.1 GiB of 62.3 GiB | 46.1–46.3 GiB of 48.2 GiB |
| Swap used | 0 of 31 GiB | **none configured** |
| Failed systemd units | 1 (`uid-renamer.service`, stale) | 0 |
| Journal errors (real) first 60 % of samples | **0** | **0** |
| Transparent hugepages | `always`, 3.2 GiB AnonHugePages | n/a |
| KSM | off (`run=0`) | n/a |

**Distribution across the 4 host NUMA nodes** (minimum free over the window):
node0 12.87 GiB · node1 12.95 GiB · node2 13.22 GiB · node3 13.72 GiB — the interleave policy
is doing its job; no node is starved.

## 2. What the one "spike" actually was

Host load average rose 0.54 → 3.09 → **11.95** → 7.28 → 4.57 between 22:49 and 22:52 while
CPU idle stayed at 96–98 %. The same samples show guest block I/O `bi/bo ≈ 4 700/5 200`
blocks/s. That is the **Cockpit `apt-get install` inside the guest**: qemu’s I/O threads sat
in `D` state on the qcow2, and Linux counts uninterruptible tasks in load average. It is
not CPU contention, not steal, and not a host defect — and it is the expected signature of
a package install on a thin qcow2 sharing `rl-root` with the host OS.

Correlation checked: `journalctl -p err` for that window is empty.

> Measurement note: the sampler’s `err_msgs_60s` counter reads 1 when a window is clean,
> because `journalctl` prints a single `-- No entries --` line. Any value **> 1** is one real
> entry; two samples showed 2, which resolved to the unprivileged-`journalctl` permission
> hint, not a fault.

## 3. Rocky Linux — proposed optimizations

Ordered by value per unit of risk.

1. **Clear the stale failed unit.** `uid-renamer.service` is a transient `systemd-run` unit
   left by the 2026-10-30 `capc → catc` rename; it lives in `/run` and will vanish on reboot,
   but it pollutes `systemctl --failed` today.
   `sudo systemctl reset-failed uid-renamer.service`
2. ~~Set the static hostname~~ — **empty** (`hostnamectl --static` → nothing). Every journal
   line is tagged `localhost.localdomain`, which makes cross-host log correlation painful.
   `sudo hostnamectl set-hostname rocky-dl360`
3. **Desktop overhead on a hypervisor.** `gnome-shell` 359 MiB, `ptyxis` 340 MiB,
   `mutter` 103 MiB, `gnome-software` 108 MiB, `gnome-remote-desktop` 85 MiB ≈ **1 GiB and a
   continuously wakeful compositor**, while the guest is 100 % idle. If the physical
   console is only for occasional maintenance:
   `sudo systemctl set-default multi-user.target` (Cockpit on :9090 keeps the same UI reach).
   Keep `graphical.target` if the on-console virt-manager is genuinely used.
4. **Storage ceiling is the real constraint.** 200 GiB is virtual; ≈61 GiB is physical on
   `rl-root`. The second LUN, **`sdb` (1.2 T), is unused** and both disks report `ROTA=0`
   (that figure comes from the MR416i-a virtual disks and says nothing about the physical
   media). Moving the pool to a dedicated filesystem on `sdb` removes the risk of the guest
   filling `/` and taking the host down, and isolates guest I/O from the OS.
5. **Queue scheduler.** `sdb` uses `mq-deadline` on non-rotational media. Once I/O is moved
   to a dedicated volume, `none` is usually better; measure before/after with the same
   30 s sampler rather than switching blind:
   `echo none | sudo tee /sys/block/sdb/queue/scheduler`
6. **KSM off.** Correct today (single guest, abundant RAM). Enable `ksmtuned` only when
   several similar guests are planned — it trades CPU for density.
7. **Hugepages.** 2 MiB THP with `always` is already active and sufficient. 1 GiB hugepages
   would need `default_hugepagesz=1G hugepagesz=1G hugepages=48` on the kernel cmdline and a
   reboot, and pin 48 GiB permanently — not worth it for one guest.
8. **firewalld hygiene.** `public` still lists the now-enslaved `ens1f2`; harmless (an L2 port
   has no addresses) but noisy. Note that `br_netfilter` is not loaded, so bridged guest
   traffic bypasses the host firewall entirely — deliberate, documented, and the reason the
   guest’s own `ufw`/`sshd` matters.
9. **Backup of the domain definition** — cheap and easy to forget:
   `virsh -c qemu:///system dumpxml ubuntu24 > /root/vm-archive/ubuntu24-$(date +%F).xml`

## 4. Ubuntu guest — proposed optimizations

1. **No swap at all.** 48 GiB of RAM makes it unlikely to matter, but a kernel OOM-kill in a
   guest with zero swap is abrupt. A 4 GiB swapfile is a five-minute insurance policy:
   `sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`
   plus an `/etc/fstab` entry.
2. **Cloud-image baggage.** `snapd`, `apport`, `open-vm-tools` and `lxd-installer.socket` are
   all enabled on a KVM guest where they do nothing. `open-vm-tools` is for VMware and
   actively misleading here; `apport` writes crash reports nobody reads; `snapd` costs
   memory and mount noise.
   `sudo systemctl disable --now open-vm-tools apport lxd-installer.socket`
   (leave `snapd` unless you have no snaps — `snap list` first).
3. **Unattended upgrades are on** (`Update-Package-Lists 1`, `Unattended-Upgrade 1`,
   automatic reboot unset ⇒ never). Keep them, but pin the behaviour explicitly and
   exclude anything that would restart the services you care about:
   add `Unattended-Upgrade::Automatic-Reboot "false";` uncommented to
   `/etc/apt/apt.conf.d/50unattended-upgrades`.
4. **Clock.** `systemd-timesyncd` is active (chrony is not installed); the guest is UTC while
   the host is `America/New_York`. Set the same zone for log correlation:
   `sudo timedatectl set-timezone America/New_York`
   (or standardise the host on UTC — either way, be consistent).
5. **Guest has one NUMA node** (`node0: 0-39`) although the host has four. That is the right
   default for a single VM: the host’s `interleave` policy hides host topology, and the
   guest scheduler treats all 40 CPUs uniformly.
6. **Cockpit footprint** is negligible (socket-activated). If `ufw` is ever enabled, add
   `sudo ufw allow 9090/tcp` (or scope it to `192.168.0.0/24`).
7. **Thin-disk hygiene is already correct**: `fstrim.timer` is enabled on the guest and the
   disk uses `discard=unmap`, so deleted blocks return to the qcow2.

## 5. What is *not* a problem (checked and cleared)

- No CPU steal in the guest despite 40 vCPU on 48 threads — the guest is idle, so the
  reservation is free today; it becomes the binding constraint only under sustained load.
- No memory pressure on either side; `MemAvailable` never dipped below 57 GiB (host) or
  46 GiB (guest).
- No I/O errors, no packet errors or drops on `br0`/`ens1f2`, no network resets.
- No AVC denials, no service failures, no reboot loops, no clock drift.

## 6. Reference: is this host big enough for the Catalyst Center VM?

`docs/deployment-requirements.md` (Cisco Catalyst Center on Ubuntu KVM) specifies
**32 vCPU, 256 GiB RAM, 3 TB SSD, 180 MB/s, 2 000–2 500 IOPS**. This DL360 has
**62 GiB RAM and a 1.2 TB disk**, so it meets the vCPU and I/O shape but **cannot meet the
256 GiB memory or the 3 TB storage requirement**. If `ubuntu24` is meant as the Catalyst
Center appliance, it will fail the platform check regardless of tuning; the options are a
larger-memory host (or several hosts), or running Catalyst Center elsewhere. Flagged here
because it changes what “correctly sized” means for this VM.
