# NUMA backup archive — 2026-10-30 A/B experiment

Contents (all captured 2026-10-30, UTC times in file names/bodies):

- `ubuntu24-optionA-20261030.xml` / `ubuntu24-optionA-host-20261030.xml` — libvirt domain XML
  of `ubuntu24` in **Option A** (1 guest NUMA node, `<memory mode='interleave' nodeset='0-3'/>`,
  `migratable='on'`, no `<numa>` cells, no `<cputune>`). Laptop copy + host `/var/tmp/vm-archive` copy.
- `ubuntu24-optionB-20261030.xml`, `ubuntu24-optionB-defined-20261030.xml`,
  `ubuntu24-optionB-live-20261030.xml` — Option B XML: generated copy, the file `virsh define`d
  on the host, and the live `dumpxml` after boot (4 `<numa>` cells, strict `<memnode>`s,
  40 `<vcpupin>` entries, `migratable='off'`).
- `optionA-*.txt` — benchmark outputs of the Option A run (guest `/var/tmp/benchA`):
  baseline (NUMA view), sysbench cpu/memory, per-vCPU memory latency, fio randread/randwrite, iperf3.
- `optionB-*.txt` — identical benchmark suite under Option B (guest `/var/tmp/benchB`).
- `host-evidence-optionB.txt` — host `/proc/<qemu>/cmdline` memory backend, per-vCPU thread pinning
  (`Cpus_allowed_list`), per-node MemFree after the switch.

Rollback to Option A: on `rocky-dl360` run
`virsh -c qemu:///system shutdown ubuntu24 && virsh -c qemu:///system define /var/tmp/vm-archive/ubuntu24-optionA-20261030.xml && virsh -c qemu:///system start ubuntu24`
