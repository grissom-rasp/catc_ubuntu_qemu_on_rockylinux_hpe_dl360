# Legacy: `ubuntu26` (removed 2026-10-30)

The guest replaced by `ubuntu24`.

| Property | Value |
|---|---|
| Domain | `ubuntu26`, autostart disabled |
| OS | Ubuntu 26.04.1 LTS cloud image (codename `resolute`) |
| CPU / RAM | 4 vCPU (`host-passthrough`), 8192 MiB |
| Disk | `ubuntu26-root.qcow2`, 40 GiB virtual (400 MiB actual), backing `ubuntu-26.04-server-cloudimg-amd64.img` |
| CD-ROM | `seed-ubuntu26.iso`, bus `sata` |
| Network | libvirt NAT `default` → `192.168.122.73`, MAC `52:54:00:08:d9:12` |
| Guest user | `capc` — key-only, `lock_passwd: true` |
| Machine | `pc-q35-rhel10.2.0`, serial console only |

Archived before deletion: `archive/ubuntu26-domain.xml`, `archive/ubuntu26-dominfo.txt`.
Disks and the 859 MB base image were deleted with `virsh undefine --remove-all-storage`
plus an explicit `rm` of the backing file — the backing image is *not* removed by libvirt.

## Why it was replaced

1. NAT-only: no other LAN machine could initiate a connection to it.
2. Its admin account mirrored the pre-rename host user `capc`.
3. No password authentication.

## Lessons carried into the new guest

- Seed CD-ROM must use `bus=sata`; `bus=virtio` rejects ejectable media.
- Never use the default `qemu:///session` URI in non-interactive shells.
- A MAC baked into `/etc/netplan/50-cloud-init.yaml` goes stale when the domain NIC changes;
  bind by interface name and/or fix the MAC in the domain XML (done: `52:54:00:24:00:24`).
- `virsh` lease queries are meaningless for a bridged guest — read the agent or `ip neigh`.
