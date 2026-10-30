# Option A Test Report — `ubuntu24` baseline NUMA config (interleave, unpinned, 1 guest node)

**Date:** 2026-10-30 · **Window:** 07:05:04Z – 07:07:59Z (run inside guest, ~3 min of benchmarks;
full A/B experiment, including setup and the B run, completed in ~15 min: 06:57Z–07:12Z)
**Guest:** `ubuntu24` @ 192.168.0.174 (Ubuntu 24.04.5, kernel 6.8.0-147-generic), 40 vCPU / 48 GiB
**Host:** `rocky-dl360` @ 192.168.0.188, Rocky 10.2, 48 CPUs / 4 NUMA nodes
**Suite:** `scripts/numa-bench.sh` (identical for A and B) — raw outputs in
`archive/numa-backup-20261030/optionA-*.txt`

## Config under test (Option A — as-shipped)

```xml
<memory unit='KiB'>50331648</memory>
<vcpu placement='static'>40</vcpu>
<numatune><memory mode='interleave' nodeset='0-3'/></numatune>
<cpu mode='host-passthrough' check='none' migratable='on'>
  <topology sockets='2' dies='1' clusters='1' cores='10' threads='2'/>
</cpu>
<!-- no <numa> cells, no <cputune>; NIC virtio without vhost queues -->
```
QEMU memory backend confirmed on host: `host-nodes=[0,1,2,3], policy=interleave`; QEMU thread
affinity `0-47` (unpinned).

## Guest-visible baseline

| Item | Observed |
|---|---|
| `NUMA node(s)` | **1** — `node0 CPU(s): 0-39`, `node 0 size: 48161 MB` (`numactl -H`: `available: 1 nodes (0)`) |
| NIC queues | `ethtool -l enp1s0` → `Combined: 1` (single virtio queue) |
| Hugepages | `HugePages_Total: 0`, 2 MiB |
| RAM | 47 GiB usable, no swap |

## Results (Option A)

| Benchmark | Parameters | Result |
|---|---|---|
| sysbench **cpu** | prime=100000, 40 threads, 60 s | **2346.53 events/s**; latency avg 17.04 ms, p95 20.37 ms |
| sysbench **memory bw** | 64 GiB rewrite, 40 threads, 60 s | **8360.84 MiB/s** |
| **per-vCPU memory read** (pinned single thread, 1 GiB, 10 s) | vcpu 0/5/10/20/30/39 | 6719 / 6737 / 6663 / 6728 / 6735 / 6642 **MiB/s** — spread ≈ 1.2 %, i.e. no visible per-vCPU penalty (as expected: guest thinks it has 1 node, host interleaves pages so every vCPU sees the same average remote fraction) |
| fio **4k randread** | qd32, 8 jobs, direct=1, 30 s, 2 GiB file | **69.9k IOPS, 273 MiB/s** |
| fio **4k randwrite** | same | **25.6k IOPS, 99.9 MiB/s** |
| iperf3 **TCP** 8 streams → host:5201, 30 s | | **35.8 Gbit/s** sender, 0 retransmits |
| NUMA probe (interleave-all, 8 GiB write, 40 thr, 20 s) | | 7847.56 MiB/s |

## Interpretation

- Option A behaves as designed: elastic, uniform, no starvation (host per-node free stayed
  14.5–15.1 GiB during the run). Single-thread memory bandwidth is uniform across all vCPUs
  *because every page is equally likely to be remote* — the average hides the penalty.
- The measurable win of locality shows up as **lower variance and lower p95 latency** under
  load, not as higher averages on an idle-ish guest — see Option B report for the comparison.
- NIC is single-queue in both options (multiqueue was deliberately *not* changed in this A/B
  test to isolate NUMA), so network numbers are comparable and bounded by one queue.
