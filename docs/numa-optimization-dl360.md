# NUMA Optimization Guideline — HP ProLiant DL360 Gen10+ (`rocky-dl360`) KVM Host and `ubuntu24` Guest

**Date:** 2026-10-30 · **Author context:** written after reading the Cisco Catalyst Center 3.2.x
on Ubuntu KVM deployment guide page *"Optimize Catalyst Center VM performance"* (Configure Guest
NUMA) and after measuring the live topology of this host and guest.
**Source page:** <https://www.cisco.com/c/en/us/td/docs/cloud-systems-management/network-automation-and-management/catalyst-center/catalyst-center-va/kvm/ubuntu/deploy-guide/3-2-x/cisco-catalyst-center-on-ubuntu-kvm-deployment-guide/postdeployment-changes/configure-guest-numa.html>

---

## 1. Why NUMA matters on this machine

`rocky-dl360` is a **2-socket Intel Xeon Silver 4310** (48 logical CPUs = 2 × 12 cores × 2 SMT
threads) with **4 NUMA nodes** (sub-NUMA clustering: each socket splits into 2 nodes of 6 cores):

| Host NUMA node | CPUs (core, SMT sibling) | Memory | Distance to other nodes |
|---|---|---|---|
| node0 | `0-5, 24-29`  (siblings: 0/24, 1/25, … 5/29) | ~16.5 GiB | 10 local / **20 cross** |
| node1 | `6-11, 30-35` | ~15.9 GiB | 20 |
| node2 | `12-17, 36-41` | ~16.5 GiB | 20 |
| node3 | `18-23, 42-47` | ~16.5 GiB | 20 |

Cross-node memory access (distance 20) costs roughly **2× the latency** of local (10) and eats
UPI interconnect bandwidth. NUMA configuration of a VM is about making each vCPU's **compute** and
its **memory** live on the same host node.

Measured current state of `ubuntu24` (2026-10-30):

- QEMU cmdline: `-smp 40,sockets=2,cores=10,threads=2`, memory backend
  `host-nodes=[0,1,2,3], policy=interleave`, QEMU affinity `0-47` (unpinned).
- Domain XML: `<numatune><memory mode='interleave' nodeset='0-3'/></numatune>`, **no `<numa>`
  cells**, no `<cputune>/<vcpupin>`; NIC is virtio with **no** `<driver name='vhost' queues=…/>`
  (guest `ethtool -l enp1s0` → `Combined: 1`).
- Guest view: `NUMA node(s): 1`, `node0: 0-39` — the guest cannot see the host's 4 nodes.
- Guest RAM 48 GiB but actual RSS ≈ 2.5 GiB; host has `HugePages_Total: 0` (no reserved hugepages).

`★ Insight ─────────────────────────────────────`
`interleave 0-3` + no guest NUMA cells + unpinned vCPUs is the *safe default*, not a tuned config:
every guest page is round-robined across all 4 nodes (75 % of them remote to any given vCPU), and
the guest scheduler has no topology to optimize against. Fine while the guest is idle; it becomes
the binding constraint under real load.
`─────────────────────────────────────────────────`

---

## 2. The libvirt knobs (working principles)

| Knob | XML | Principle |
|---|---|---|
| Guest NUMA cells | `<cpu><numa><cell id='N' cpus='…' memory='…'/></numa></cpu>` | Exposes N NUMA nodes to the guest OS; the guest scheduler then keeps threads near their memory (NUMA balancing). **This is the parameter Cisco's guide tells you to add.** |
| Memory placement | `<numatune><memory mode='…' nodeset='…'/></numatune>` or `<memnode cellid='N' mode='strict' nodeset='…'/>` | `interleave`: pages spread over `nodeset` — elastic, even, but mostly remote. `strict` + `memnode`: guest cell N's memory allocated only from the mapped host node(s) — local, but can fail to start if that node is short of free memory. |
| vCPU pinning | `<cputune><vcpupin vcpu='N' cpuset='…'/></cputune>` (+ `migratable='off'` on `<cpu>`) | Pins each vCPU to host CPUs. Rule: vCPUs of guest cell *i* must sit on the host node(s) that cell *i*'s memory is bound to. Disables live migration. |
| SMT/cores | `<topology sockets='…' cores='…' threads='2'/>` | With 4 nodes × 6 physical cores, 40 vCPUs *must* share 4 cores per node (10 vCPUs on 6 cores). For core isolation use `threads='1'` and ≤ 24 vCPUs (Option F below). |
| NIC multiqueue | `<driver name='vhost' queues='N'/>` right after `<model type='virtio'/>` | Gives the virtio NIC N TX/RX queues (vhost offload) — parallel packet processing. Cisco's example: `queues='8'`. Keep N ≤ vCPU count. |
| Disk iothreads | `<iothreads>N</iothreads>` + `<iothreadpin iothread='N' cpuset='…'/>` + disk `<driver … iothread='N'/>` | Moves virtio-blk I/O off vCPUs onto pinned helper threads. |
| Hugepages | host cmdline `default_hugepagesz=1G hugepagesz=1G hugepages=N` + `<memoryBacking><hugepages/><page size='1048576' unit='KiB'/></memoryBacking>` | 1 GiB pages cut TLB pressure for big in-memory workloads. Costs a permanent reservation; only if benchmarked need. |

---

## 3. Cisco's procedure (from the guide), generalized

1. **Prereq:** host supports more than one NUMA node — check with
   `numactl --hardware | grep available` (install `numactl` if missing; here: 4 nodes) or
   `lscpu` / `virsh capabilities`.
2. Shut the VM down: `virsh -c qemu:///system shutdown <vm>`.
3. Back up the definition: `virsh dumpxml <vm> > ubuntu24-before-numa-$(date +%F).xml`.
4. `virsh -c qemu:///system edit <vm>` — add `<numa>` cells inside `<cpu>`; Cisco's tip:
   **split CPU and memory evenly across the cells**, sized to the VM and host topology.
   Cisco's example (2 cells): `<cell id='0' cpus='0-15' memory='134217728' unit='KiB'/>` +
   `<cell id='1' cpus='16-31' memory='134217728' unit='KiB'/>`, with `migratable='off'`.
5. For each virtio NIC add `<driver name='vhost' queues='8'/>` after `<model type='virtio'/>`.
6. Start the VM: `virsh -c qemu:///system start <vm>`.
7. Verify (this repo's gate, see `docs/verification-matrix.md`): guest shows the new NUMA node
   count (`lscpu`), `virsh domifaddr <vm> --source agent` still returns the DHCP address, and
   `ssh -o BatchMode=yes catc_ubuntu_kvm@<ip> 'ip a && ping -c1 192.168.0.1'` passes.

---

## 4. Options for `ubuntu24` on this host, with rationale

Guest: 40 vCPU / 48 GiB (50331648 KiB). Even split over 4 cells = **10 vCPU / 12582912 KiB per cell**.

### Option A — Status quo (1 guest node, interleave, unpinned) — *current*
Keep as is. **Choose when:** multiple VMs share the host, live migration is needed, or load is
small/variable. **Cost:** worst latency determinism under load.

### Option B — Full pinning ("appliance" model, Cisco-style, recommended for a permanent heavy workload)
```xml
<memory unit='KiB'>50331648</memory>
<vcpu placement='static'>40</vcpu>
<numatune>
  <memnode cellid='0' mode='strict' nodeset='0'/>
  <memnode cellid='1' mode='strict' nodeset='1'/>
  <memnode cellid='2' mode='strict' nodeset='2'/>
  <memnode cellid='3' mode='strict' nodeset='3'/>
</numatune>
<cpu mode='host-passthrough' check='none' migratable='off'>
  <topology sockets='2' dies='1' clusters='1' cores='10' threads='2'/>
  <numa>
    <cell id='0' cpus='0-9'   memory='12582912' unit='KiB'/>
    <cell id='1' cpus='10-19' memory='12582912' unit='KiB'/>
    <cell id='2' cpus='20-29' memory='12582912' unit='KiB'/>
    <cell id='3' cpus='30-39' memory='12582912' unit='KiB'/>
  </numa>
</cpu>
<cputune>
  <!-- cell0 vCPUs 0-9  -> host node0 0-5,24-29  (vcpu i -> cpu i for 0-5, then 24+i-6 for 6-9) -->
  <vcpupin vcpu='0' cpuset='0'/>  <vcpupin vcpu='1' cpuset='1'/>  <vcpupin vcpu='2' cpuset='2'/>
  <vcpupin vcpu='3' cpuset='3'/>  <vcpupin vcpu='4' cpuset='4'/>  <vcpupin vcpu='5' cpuset='5'/>
  <vcpupin vcpu='6' cpuset='24'/> <vcpupin vcpu='7' cpuset='25'/> <vcpupin vcpu='8' cpuset='26'/>
  <vcpupin vcpu='9' cpuset='27'/>
  <!-- cell1 vCPUs 10-19 -> host node1 6-11,30-33 -->
  <vcpupin vcpu='10' cpuset='6'/>  <vcpupin vcpu='11' cpuset='7'/>  <vcpupin vcpu='12' cpuset='8'/>
  <vcpupin vcpu='13' cpuset='9'/>  <vcpupin vcpu='14' cpuset='10'/> <vcpupin vcpu='15' cpuset='11'/>
  <vcpupin vcpu='16' cpuset='30'/> <vcpupin vcpu='17' cpuset='31'/> <vcpupin vcpu='18' cpuset='32'/>
  <vcpupin vcpu='19' cpuset='33'/>
  <!-- cell2 vCPUs 20-29 -> host node2 12-17,36-39 -->
  <vcpupin vcpu='20' cpuset='12'/> <vcpupin vcpu='21' cpuset='13'/> <vcpupin vcpu='22' cpuset='14'/>
  <vcpupin vcpu='23' cpuset='15'/> <vcpupin vcpu='24' cpuset='16'/> <vcpupin vcpu='25' cpuset='17'/>
  <vcpupin vcpu='26' cpuset='36'/> <vcpupin vcpu='27' cpuset='37'/> <vcpupin vcpu='28' cpuset='38'/>
  <vcpupin vcpu='29' cpuset='39'/>
  <!-- cell3 vCPUs 30-39 -> host node3 18-23,42-45 -->
  <vcpupin vcpu='30' cpuset='18'/> <vcpupin vcpu='31' cpuset='19'/> <vcpupin vcpu='32' cpuset='20'/>
  <vcpupin vcpu='33' cpuset='21'/> <vcpupin vcpu='34' cpuset='22'/> <vcpupin vcpu='35' cpuset='23'/>
  <vcpupin vcpu='36' cpuset='42'/> <vcpupin vcpu='37' cpuset='43'/> <vcpupin vcpu='38' cpuset='44'/>
  <vcpupin vcpu='39' cpuset='45'/>
</cputune>
```
**Principle:** guest cell *i* = host node *i* for both CPU and memory → maximal locality; the guest
sees 4 NUMA nodes and schedules within them. **Choose when:** the VM is a fixed-purpose, permanently
loaded appliance (Catalyst Center-style, DB, NFV) with dedicated resources — which matches this
host, since 40/48 vCPUs are already committed. **Risks:** no live migration; startup fails if any
node lacks 12 GiB free (measured 2026-10-30: ~14.5 GiB free per node — OK, re-check before each
start after host reboot); leaves 8 host CPUs (2 SMT siblings per node) for Rocky/QEMU.

### Option C — Cisco's 2-cell shape on this host (locality + headroom)
2 cells × 20 vCPUs × 25165824 KiB (24 GiB), `memnode cellid='0' nodeset='0-1'`, `cellid='1'
nodeset='2-3'`, pin cell 0 to nodes 0-1 CPUs and cell 1 to nodes 2-3 CPUs.
**Choose when:** you want strict locality but each cell should have ~29 GiB of free node memory
for host spikes, or plan to grow the VM later. Middle ground between A and B.

### Option D — Soft NUMA (recommended first step for the current lab guest)
Option B's `<cpu><numa>` cells + strict `<memnode>`s, **no `<cputune>`**, keep `migratable='on'`.
**Principle:** memory is strictly local per cell, but vCPUs float on all 48 host CPUs and the now
NUMA-aware guest kernel migrates threads toward their memory automatically.
**Choose when:** real but variable load, live migration wanted, or more VMs planned later.
Captures most of B's memory-locality with almost none of its rigidity.

### Option E — Dedicated node (multi-VM host)
Shrink per VM to e.g. 12 vCPU / 12 GiB, one cell, `nodeset='0'`, pinned to `0-5,24-29`.
**Choose when:** running several VMs — one node (6 cores, ~15 GiB) per VM gives hard isolation
at the cost of unused inter-node bandwidth.

### Option F — Core isolation (latency over throughput)
24 vCPU, `<topology sockets='4' cores='6' threads='1'/>`, one cell of 6 vCPUs per node, pinned to
that node's 6 physical cores (no SMT sharing).
**Choose when:** p95/p99 latency matters more than throughput (trading, real-time, benchmarking).
Costs 40 % of the vCPUs. Not for a general server.

---

## 5. Companion knobs (apply in every option where relevant)

1. **NIC multiqueue** (Cisco's step 5-6): on the br0 interface add
   `<driver name='vhost' queues='16'/>` after `<model type='virtio'/>`
   (Cisco uses 8; 16 fits since the guest has 40 vCPUs; verify in guest with
   `ethtool -l enp1s0` → `Combined: 16`). Removes today's single-queue bottleneck (`Combined: 1`).
2. **Disk iothreads:** add `<iothreads>2</iothreads>`, `<iothreadpin iothread='1' cpuset='…'/>`
   (and `'2'`), and `iothread='1'` in the disk's `<driver>`. Disk already has
   `cache='none' io='native' discard='unmap'` — keep that.
3. **1 GiB hugepages:** only with a measured TLB-bound, big-memory workload. Host currently has
   none reserved; would need `default_hugepagesz=1G hugepagesz=1G hugepages=48` on the kernel
   cmdline + reboot, plus `<memoryBacking><hugepages/>…` in the XML. See
   `docs/monitoring-and-optimization.md` §3.7 — not worth it for one idle guest.

---

## 6. Decision guide

| Question | Answer → option |
|---|---|
| Fixed appliance, permanent heavy load, dedicated host? | **B** (full pinning, `migratable='off'`) |
| Real but variable load / live migration / future VMs? | **D** first (soft NUMA); promote to B when load stabilizes |
| Need memory headroom per cell + locality? | **C** (2 cells spanning node pairs) |
| Several VMs on the DL360? | **E** (one node per VM) or stay **A** |
| Multiple/migratable VMs, elastic placement? | **A** (status quo) |
| p99 latency beats throughput? | **F** (24 vCPU, `threads='1'`) |
| Network-heavy, any option? | add vhost `queues='8…16'` |
| IO-heavy? | add iothreads + disk `iothread=` |
| Big in-memory DB with measured TLB pressure? | B + 1 GiB hugepages (host cmdline change + reboot) |

**Expected effect, honestly stated:** with the guest at RSS ≈ 2.5 GiB and idle, A-vs-B gains are
negligible *today*; the difference appears under sustained load as lower cross-node traffic
(host node `MemFree` stays even, guest latency variance drops). Benchmark before/after with the
guest's iperf3 (already installed) or `sysbench`/`pgbench` if a DB is involved.

---

## 7. Apply + verify runbook (on `rocky-dl360`, as `catc`, `qemu:///system`)

```sh
# 1. pre-checks
virsh -c qemu:///system capabilities | awk '/<topology>/,/<\/topology>/'   # 4 cells
for n in /sys/devices/system/node/node*/meminfo; do grep -H MemFree $n; done # >= 12 GiB each for B
virsh -c qemu:///system dumpxml ubuntu24 > /root/vm-archive/ubuntu24-before-numa-$(date +%F).xml

# 2. Cisco's procedure
virsh -c qemu:///system shutdown ubuntu24
virsh -c qemu:///system edit ubuntu24          # paste the chosen option's XML
virsh -c qemu:///system start ubuntu24

# 3. verification gate (report PASS/FAIL, see docs/verification-matrix.md)
virsh -c qemu:///system domifaddr ubuntu24 --source agent     # expect 192.168.0.174 on enp1s0
ssh -o BatchMode=yes catc_ubuntu_kvm@192.168.0.174 'lscpu | grep -i numa'   # expect NUMA node(s): 4
ssh -o BatchMode=yes catc_ubuntu_kvm@192.168.0.174 'ethtool -l enp1s0 | grep Combined'  # expect 16 after multiqueue
ssh -o BatchMode=yes catc_ubuntu_kvm@192.168.0.174 'ip a && ping -c1 192.168.0.1'
```

Notes: the fixed MAC `52:54:00:24:00:24` is untouched, so br0 DHCP is unaffected. If the VM fails
to start after adding strict memnodes, a host node was short of memory — check `MemFree` per node
and either free memory or choose Option C/D. Rollback: `virsh define` the backup XML from step 1.

---

## 8. References

- Cisco Catalyst Center 3.2.x on Ubuntu KVM Deployment Guide — *Optimize Catalyst Center VM
  performance* (Configure Guest NUMA): procedure, `<numa>` example, `queues='8'` vhost example,
  "split CPU and memory evenly" tip. URL in header.
- `docs/monitoring-and-optimization.md` — measured host/guest steady state; §4.5 documents the
  current 1-node guest NUMA view as the deliberate default before this guideline.
- `docs/verification-matrix.md` — the PASS/FAIL gate used in §7.
- libvirt domain XML format docs (`numatune`, `cputune`, `cpu/numa`, `memoryBacking`) for the
  exact attribute semantics behind §2.
