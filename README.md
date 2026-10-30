# catc_ubuntu_qemu_on_rockylinux_hpe_dl360

Headless **Ubuntu 24.04 LTS** KVM guest on a bare-metal **HPE ProLiant DL360 Gen10+**
running **Rocky Linux 10.2**, with the guest bridged directly onto the
`192.168.0.0/24` LAN.

| Item | Value |
|---|---|
| Host | `rocky-dl360` — Rocky Linux 10.2, `192.168.0.188`, KVM/libvirt 11.10 |
| Guest domain | `ubuntu24` — Ubuntu 24.04 LTS cloud image (noble) |
| Guest address | DHCP from the LAN router (last seen `192.168.0.174`) |
| Guest hardware | 40 vCPU (2×10×2), 48 GiB RAM, 200 GiB thin qcow2 |
| Guest admin | `catc_ubuntu_kvm` — sudo, key **and** password SSH, persists reboots |
| Networking | Linux bridge `br0` on `ens1f2`; libvirt NAT `default` left intact |
| Web UI | Cockpit on the guest at **https://192.168.0.174:9090** (PAM login) |

## Documentation

- [`docs/installation-guideline.md`](docs/installation-guideline.md) — the full build
  procedure, rationale for the sizing choices, rollback runbook.
- [`docs/verification-matrix.md`](docs/verification-matrix.md) — every check with its
  PASS/FAIL result.
- [`docs/monitoring-and-optimization.md`](docs/monitoring-and-optimization.md) — 15-minute
  steady-state analysis and the resulting proposals.
- [`docs/legacy-ubuntu26.md`](docs/legacy-ubuntu26.md) — the guest this replaced.
- [`docs/ubuntu-24-04-kvm-installation-guide.md`](docs/ubuntu-24-04-kvm-installation-guide.md) —
  alternative deploy/monitor walkthrough (from the copilot branch; needs `VM_PASSWORD` set).

## Layout

```
cloud-init/    meta-data + user-data.template (rendered file and seed ISO are git-ignored)
scripts/       build-seed.sh, br0-switch.sh, br0-rollback.sh, monitor.sh,
               install_ubuntu_24_kvm.sh, monitor_kvm_vm.sh, collect-ubuntu24-info.sh,
               sync-to-sas.sh, run-on-git-sync.sh
archive/       XML/inventory of the removed ubuntu26 domain
docs/          guideline, verification, monitoring, legacy notes
vm-ubuntu24/   guest info inventory (git-ignored)
vm-ubuntu26/   retired guest cloud-init/seed (history)
```

Reproduce the seed (secrets come from `.ssh-env`, never committed):

```bash
./scripts/build-seed.sh
```
