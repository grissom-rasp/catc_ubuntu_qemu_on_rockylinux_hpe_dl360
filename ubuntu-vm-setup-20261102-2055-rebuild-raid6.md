# ubuntu24 rebuild on the RAID6-rebuilt Rocky host — 2026-11-02

Rocky Linux 10.2 was re-installed from scratch after the RAID6 rebuild
(hostname reset to localhost.localdomain, old `192.168.0.188` lease gone — DHCP
now gives `192.168.0.186`, same NIC MAC `8c:84:74:0d:de:2a` on `ens1f2`).
This run rebuilt the whole stack per `docs/installation-guideline.md`:

1. QEMU/KVM 10.x + libvirt (modular daemons) + virt-install + **virt-manager** +
   guestfs-tools + **cockpit-machines** installed, then updated and upgraded.
2. `br0` bridge over `ens1f2` via `scripts/br0-switch.sh` (cloned MAC keeps the
   DHCP lease stable; auto-rollback on failure).
3. Guest `ubuntu24` rebuilt from the local verified cloud image
   (`downloads/ubuntu-24.04-server-cloud-kvm/`, sha256 checked on both ends):
   200 G qcow2 overlay on the backing image, cloud-init NoCloud seed ISO
   (`cloud-init/user-data.template`), **NUMA Option B** domain XML applied from
   first boot (`archive/numa-backup-20261030/ubuntu24-optionB-defined-20261030.xml` —
   40 vCPU 2×10×2 across 4 cells, 48 GiB strict per-node, vCPUs pinned node-local),
   MAC `52:54:00:24:00:24`, bridge `br0`, headless serial console, autostart on.
4. Readiness gate: guest SSH-ready after **54s** (≤ 15 min budget).
   Verification log: `logs/ubuntu24-verify-20261102-2055.txt` (password SSH auth,
   cloud-init done, sshd active, guest sees 4 NUMA nodes).
5. Seed ISO ejected post-install (same as 2026-10-30 build).
6. Inventories refreshed: host → `rockylinux_info/` (incl. `kvm/` with domain +
   network .xml, nmprofiles, qemu.conf), guest → `vm-ubuntu24/ubuntu24_info/`
   (hardware/os/packages/network + iperf3).
7. Managed via Cockpit at https://192.168.0.186:9090 (Virtual Machines page);
   virt-manager 5.x also on the DL360 GNOME desktop.

Run log: `logs/rebuild-ubuntu24-20261102-2055.log`; monitor sample: `logs/monitor-*`.
