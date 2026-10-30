# Option B Test Report — `ubuntu24` with 4 guest NUMA cells, strict memnodes, vCPU pinning

**Date:** 2026-10-30 · **Window:** applied 07:09Z (shutdown → `virsh define` → start), benchmarks
07:09:33Z – 07:12:29Z (same suite as Option A: `scripts/numa-bench.sh`)
**Guest:** `ubuntu24` @ 192.168.0.174 · **Host:** `rocky-dl360` @ 192.168.0.188
**Raw outputs:** `archive/numa-backup-20261030/optionB-*.txt`,
XML: `archive/numa-backup-20261030/ubuntu24-optionB-{,defined-,live-}20261030.xml`

## Config under test (Option B — Cisco-style full pinning)

```xml
<numatune>
  <memnode cellid='0' mode='strict' nodeset='0'/>
  <memnode cellid='1' mode='strict' nodeset='1'/>
  <memnode cellid='2' mode='strict' nodeset='2'/>
  <memnode cellid='3' mode='strict' nodeset='3'/>
</numatune>
<cputune>  <!-- 40 vcpupin entries: cell i -> host node i CPUs -->
  <vcpupin vcpu='0' cpuset='0'/> ... <vcpupin vcpu='9' cpuset='27'/>
  <vcpupin vcpu='10' cpuset='6'/> ... <vcpupin vcpu='19' cpuset='33'/>
  <vcpupin vcpu='20' cpuset='12'/> ... <vcpupin vcpu='29' cpuset='39'/>
  <vcpupin vcpu='30' cpuset='18'/> ... <vcpupin vcpu='39' cpuset='45'/>
</cputune>
<cpu mode='host-passthrough' check='none' migratable='off'>
  <topology sockets='2' dies='1' clusters='1' cores='10' threads='2'/>
  <numa>
    <cell id='0' cpus='0-9'   memory='12582912' unit='KiB'/>
    <cell id='1' cpus='10-19' memory='12582912' unit='KiB'/>
    <cell id='2' cpus='20-29' memory='12582912' unit='KiB'/>
    <cell id='3' cpus='30-39' memory='12582912' unit='KiB'/>
  </numa>
</cpu>
```
Applied with the Cisco procedure: `virsh shutdown` → `virsh define optionB.xml` → `virsh start`.
Host-side confirmation after boot: QEMU vCPU threads' `Cpus_allowed_list` are single CPUs exactly
matching the pin map (e.g. vcpu6 → cpu 24); 4 memory backends `host-nodes=0..3 policy=bind`
(see `archive/numa-backup-20261030/host-evidence-optionB.txt`).

## Guest-visible baseline after switch

| Item | Observed |
|---|---|
| `NUMA node(s)` | **4** — node0 `0-9`, node1 `10-19`, node2 `20-29`, node3 `30-39`; `numactl -H`: `available: 4 nodes (0-3)`, each ≈ 12027–12092 MB |
| NIC queues | `Combined: 1` (unchanged — multiqueue not part of this NUMA A/B) |
| DHCP/IP | unchanged: `enp1s0 52:54:00:24:00:24 → 192.168.0.174/24` (fixed MAC preserved) |
| Verification gate | **PASS**: `virsh domifaddr --source agent` → 192.168.0.174; `ssh -o BatchMode=yes catc_ubuntu_kvm@192.168.0.174 'ip a && ping -c1 192.168.0.1'` → 0 % loss; ping host 192.168.0.188 PASS |

## Results (Option B)

| Benchmark | Parameters (identical to A) | Result |
|---|---|---|
| sysbench **cpu** | prime=100000, 40 thr, 60 s | **2348.44 events/s**; avg 17.03 ms, p95 20.37 ms |
| sysbench **memory bw** | 64 GiB rewrite, 40 thr, 60 s | **8788.85 MiB/s** |
| **per-vCPU memory read** | vcpu 0/5/10/20/30/39 | 7204 / 7205 / 7206 / 7148 / 7194 / 7192 **MiB/s** — tighter spread (0.8 %) at a **~7 % higher** level than A |
| fio **4k randread** | qd32, 8 jobs, direct=1, 30 s | **68.2k IOPS, 266 MiB/s** |
| fio **4k randwrite** | same | **23.6k IOPS, 92.4 MiB/s** |
| iperf3 **TCP** 8 streams → host, 30 s | | **37.0 Gbit/s** sender, 0 retransmits |
| NUMA probe (interleave-all 8 GiB write, 40 thr) | | 8108.48 MiB/s |

## Interpretation

- The structural goal is achieved: the guest now sees **4 NUMA nodes** matching the host, memory
  is strictly bound per cell, and vCPUs are pinned so compute and memory are co-located
  (cell i ↔ host node i).
- Single-thread memory bandwidth rose **~6.8–7.8 %** (6.66–6.74 GiB/s → 7.15–7.21 GiB/s) with a
  *tighter* spread — the locality win shows up exactly where theory says it should.
- Aggregate multi-thread memory bandwidth rose **+5.1 %** (8361 → 8789 MiB/s).
- CPU, disk, and network are statistically unchanged (within run-to-run noise on this idle host),
  as expected — those are not NUMA-bound at this load level.
