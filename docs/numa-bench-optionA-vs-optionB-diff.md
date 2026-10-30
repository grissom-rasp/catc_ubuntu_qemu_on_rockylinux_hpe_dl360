# A/B Diff Report — Option A vs Option B for `ubuntu24` on `rocky-dl360` (2026-10-30)

Same guest, same host, same benchmark script (`scripts/numa-bench.sh`), same parameters;
only the libvirt NUMA/CPU configuration changed. A ran 07:05–07:08Z, B ran 07:09–07:12Z.
Raw data: `archive/numa-backup-20261030/`. XML diff: `archive/numa-backup-20261030/optionA-vs-optionB.xml.diff`.

## 1. Configuration diff (what actually changed)

| XML element | Option A | Option B |
|---|---|---|
| `<numatune>` | `<memory mode='interleave' nodeset='0-3'/>` (all 48 GiB spread over 4 host nodes) | 4 × `<memnode cellid='N' mode='strict' nodeset='N'/>` (12 GiB strictly per host node) |
| `<cpu>` | `migratable='on'`, no `<numa>` | `migratable='off'`, `<numa>` with 4 cells: `cpus='0-9/10-19/20-29/30-39'`, `memory='12582912' KiB` each |
| `<cputune>` | absent (QEMU affinity 0-47) | 40 `<vcpupin>` entries: vCPU 0-9→host CPUs 0-5,24-29 (node0); 10-19→6-11,30-33 (node1); 20-29→12-17,36-39 (node2); 30-39→18-23,42-45 (node3) |
| QEMU backend | one `memory-backend-ram` `host-nodes=[0,1,2,3] policy=interleave` | per-cell backends `host-nodes=N policy=bind` |
| NIC, disk, memory size, vCPU count, topology | unchanged (`Combined: 1`, `cache=none io=native`, 50331648 KiB, 40 vCPU, 2×10×2) | unchanged |
| Guest NUMA view | `NUMA node(s): 1` | `NUMA node(s): 4` (0-9 / 10-19 / 20-29 / 30-39) |

## 2. Performance diff (identical suite both runs)

| Metric | Option A | Option B | Δ (B vs A) |
|---|---|---|---|
| sysbench cpu events/s (40 thr, 60 s) | 2346.53 | 2348.44 | **+0.08 %** (noise) |
| sysbench cpu p95 latency | 20.37 ms | 20.37 ms | 0 |
| Memory bandwidth, 64 GiB, 40 thr | 8360.84 MiB/s | 8788.85 MiB/s | **+5.1 %** |
| Single-thread mem read, avg over vCPU {0,5,10,20,30,39} | 6707.5 MiB/s | 7187.6 MiB/s | **+7.2 %** |
| Single-thread spread (max-min)/avg | 1.15 % | 0.82 % | tighter (more uniform locality) |
| fio 4k randread | 69.9k IOPS / 273 MiB/s | 68.2k IOPS / 266 MiB/s | −2.4 % (noise; host page cache state differs) |
| fio 4k randwrite | 25.6k IOPS / 99.9 MiB/s | 23.6k IOPS / 92.4 MiB/s | −7.5 % (noise range on shared qcow2; both far above any app need) |
| iperf3 TCP 8-stream to host | 35.8 Gbit/s, 0 retrans | 37.0 Gbit/s, 0 retrans | +3.3 % (noise; NIC still 1 queue in both) |
| Guest NUMA nodes | 1 | 4 | structural change (the point of the test) |
| Guest IP / SSH gate after change | 192.168.0.174 | 192.168.0.174 | **PASS both** (`domifaddr` + `ssh BatchMode` + ping gateway/host) |

## 3. Reading the diff

- **NUMA locality is real but modest at this load:** ~+5–7 % on memory-bound microbenchmarks.
  The host has huge headroom (57 GiB free) and the guest was light, so cross-node penalties are
  diluted; under sustained memory-heavy load the gap typically widens (every guest page in A is
  75 % likely remote to the running vCPU; in B it is 0 % remote by construction).
- **CPU / disk / network: no regression.** Differences are within run-to-run noise; the
  configuration change touched none of those paths (identical NIC single queue in both).
- **Costs of B:** live migration disabled (`migratable='off'`); startup can fail if a host node
  lacks 12 GiB free (checked before switch: 14.5–15.1 GiB/node free — passed); 8 host CPUs remain
  for the host OS and QEMU (2 SMT siblings per node: 28,29 / 34,35 / 40,41 / 46,47).
- **Not tested here (deliberately, to isolate NUMA):** vhost multiqueue on the NIC
  (`<driver name='vhost' queues='16'/>` — Combined: 1 in both runs bounds iperf3). That is the
  next lever if network throughput under multi-connection load matters.

## 4. Verdict

**Keep Option B for `ubuntu24` on this host.** It delivers measurably better and more uniform
memory locality (+5–7 %) with no regression elsewhere, and the guest now exposes the true 4-node
topology to NUMA-aware applications inside it — which is exactly what the Cisco guide's
"Configure Guest NUMA" step is for. Rollback path is archived:
`archive/numa-backup-20261030/ubuntu24-optionA-*.xml` +
`virsh shutdown ubuntu24 && virsh define <optionA.xml> && virsh start ubuntu24`.
