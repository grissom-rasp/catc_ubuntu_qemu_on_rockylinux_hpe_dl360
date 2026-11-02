# Time synchronization to Hong Kong time (HKT) — 2026-11-02

Both the Rocky Linux host (`rocky-dl360`, 192.168.0.186) and the `ubuntu24` KVM
guest (192.168.0.172) are now on **`Asia/Hong_Kong` (HKT, UTC+8)**, synced over
the Internet via **hk.pool.ntp.org** (with existing pools kept as fallback).

## Before

- Both clocks were already **correct at UTC** (chronyd / systemd-timesyncd
  synchronized); no drift existed.
- Host timezone was `America/New_York` (left over from the fresh install) —
  local time displayed 13 h behind HKT.
- Guest timezone was `Etc/UTC`.

## Changes

### Rocky host (chronyd)

- `timedatectl set-timezone Asia/Hong_Kong`
- `/etc/chrony.conf`: prepended `server 0/1/2.hk.pool.ntp.org iburst prefer`;
  the stock rocky pool lines below remain as fallback. `systemctl restart chronyd`.
- Verified: `System clock synchronized: yes`; active source `^* 38.60.227.120`
  (hk.pool stratum 2, offset ≈ +27 µs); `ott136.hkcable.com.hk` also in the mix.

### ubuntu24 guest (systemd-timesyncd)

- `sudo timedatectl set-timezone Asia/Hong_Kong`
- `/etc/systemd/timesyncd.conf.d/hk.conf`:
  `NTP=0.hk.pool.ntp.org 1.hk.pool.ntp.org 2.hk.pool.ntp.org`
  (`FallbackNTP=ntp.ubuntu.com`); `systemctl restart systemd-timesyncd`.
- Verified: `Local time: Mon 2026-11-02 22:17:47 HKT`; synchronized via
  `0.hk.pool.ntp.org` (118.143.17.82).

### Persistence

- `cloud-init/user-data.template` now carries `timezone: Asia/Hong_Kong`, so
  any future `ubuntu24` rebuild boots straight into HKT (the timesyncd drop-in
  above is applied by the same runbook when rebuilding — or re-add it manually;
  clock accuracy itself comes from Ubuntu's default fallbacks until then).
- Host inventory time section refreshed: `rockylinux_info/os/host.txt`.

## Notes

- RTC stays in UTC on both machines (`RTC in local TZ: no`) — standard practice.
- The guest keeps its time via systemd-timesyncd (Ubuntu default); the host via
  chronyd (RHEL default). Both pull from the Internet NTP pool — no local NTP
  server is involved.
