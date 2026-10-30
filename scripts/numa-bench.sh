#!/usr/bin/env bash
# numa-bench.sh — identical benchmark suite for Option A vs Option B on ubuntu24.
# Usage (run INSIDE the guest as root):  bash numa-bench.sh <label> <outdir>
#   label: optionA | optionB      outdir: where to write <label>-*.txt
# Fixed parameters so A and B runs are directly comparable.
set -uo pipefail

LABEL="${1:?label (optionA|optionB)}"
OUTDIR="${2:?outdir}"
mkdir -p "$OUTDIR"
cd "$OUTDIR"

NCPU=$(nproc)                                    # 40
MEM_KIB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_G=$(( MEM_KIB / 1024 / 1024 ))
HOST=192.168.0.188

dump_baseline() {
  {
    echo "===== baseline: $(date -u +%FT%TZ) label=$LABEL ncpu=$NCPU mem=${MEM_G}GiB ====="
    lscpu | grep -Ei 'numa|socket|core\(s\)|thread|model name'
    for n in /sys/devices/system/node/node*; do
      echo "$n cpus=$(cat "$n/cpulist") $(grep MemTotal "$n/meminfo")"
    done 2>/dev/null || true
    grep -E 'HugePages_Total|Hugepagesize' /proc/meminfo
    ethtool -l enp1s0 2>/dev/null | grep -E 'Combined' || true
  } | tee "$LABEL-baseline.txt"
}

run_cpu() {
  echo "===== sysbench cpu: prime=100000 threads=$NCPU time=60 =====" | tee "$LABEL-cpu.txt"
  sysbench cpu --cpu-max-prime=100000 --threads="$NCPU" --time=60 run 2>&1 \
    | tee -a "$LABEL-cpu.txt" | grep -E 'events per second|total number|avg:|min:|max:|95th' || true
}

run_mem_bw() {
  echo "===== sysbench memory: 64G re-write, threads=$NCPU, time=60 =====" | tee "$LABEL-mem.txt"
  sysbench memory --memory-block-size=1K --memory-total-size=64G --memory-oper=write \
    --threads="$NCPU" --time=60 run 2>&1 \
    | tee -a "$LABEL-mem.txt" | grep -E 'MiB transferred|Total operations|per second|avg:|95th' || true
}

run_mem_lat() {
  echo "===== sysbench memory single-thread read latency per pinned vCPU (subset) =====" | tee "$LABEL-mem-lat.txt"
  for v in 0 5 10 20 30 39; do
    line=$(numactl --physcpubind="$v" --membind=0 sysbench memory --memory-block-size=1K \
      --memory-total-size=1G --memory-oper=read --threads=1 --time=10 run 2>&1 \
      | grep -E 'MiB transferred' || echo "n/a")
    echo "vcpu$v $line" | tee -a "$LABEL-mem-lat.txt"
  done
}

run_fio() {
  echo "===== fio prep 2G =====" | tee "$LABEL-fio-prep.txt"
  fio --name=prep --rw=write --bs=4k --size=2G --filename=/var/tmp/fio-test.bin \
      --direct=1 --ioengine=libaio --iodepth=32 --numjobs=8 --group_reporting 2>&1 \
    | tee -a "$LABEL-fio-prep.txt" | grep -E 'WRITE: bw|err=' || true
  echo "===== fio 4k randread 30s qd32 jobs8 =====" | tee "$LABEL-fio-randread.txt"
  fio --name=randread --directory=/var/tmp --rw=randread --bs=4k --size=2G --direct=1 \
      --ioengine=libaio --iodepth=32 --numjobs=8 --runtime=30 --time_based --group_reporting \
      --filename=/var/tmp/fio-test.bin 2>&1 \
    | tee -a "$LABEL-fio-randread.txt" | grep -E 'read:|IOPS|lat \(' || true
  echo "===== fio 4k randwrite 30s qd32 jobs8 =====" | tee "$LABEL-fio-randwrite.txt"
  fio --name=randwrite --directory=/var/tmp --rw=randwrite --bs=4k --size=2G --direct=1 \
      --ioengine=libaio --iodepth=32 --numjobs=8 --runtime=30 --time_based --group_reporting \
      --filename=/var/tmp/fio-test.bin 2>&1 \
    | tee -a "$LABEL-fio-randwrite.txt" | grep -E 'write:|IOPS|lat \(' || true
  rm -f /var/tmp/fio-test.bin
}

run_iperf() {
  echo "===== iperf3 TCP 30s 8 streams to $HOST:5201 =====" | tee "$LABEL-iperf.txt"
  iperf3 -c "$HOST" -P 8 -t 30 -i 10 2>&1 | tee -a "$LABEL-iperf.txt" | grep -E 'SUM|sender|receiver' || true
  echo "===== iperf3 UDP 30s 8 streams (jitter/loss) =====" | tee -a "$LABEL-iperf.txt"
  iperf3 -c "$HOST" -P 8 -t 30 -u -b 10G -l 64K 2>&1 | tee -a "$LABEL-iperf.txt" | grep -E 'SUM|sender|receiver|jitter|lost' || true
}

run_numa_probe() {
  echo "===== NUMA probe: interleave-all vs single-node local write bandwidth =====" | tee "$LABEL-numa.txt"
  l1=$(numactl --interleave=all sysbench memory --memory-block-size=1K --memory-total-size=8G \
        --memory-oper=write --threads="$NCPU" --time=20 run 2>&1 | grep -E 'MiB transferred' || echo n/a)
  node=$(ls /sys/devices/system/node/ | head -1)
  l2=$(numactl --cpunodebind="$node" --membind="$node" sysbench memory --memory-block-size=1K \
        --memory-total-size=8G --memory-oper=write --threads=6 --time=20 run 2>&1 | grep -E 'MiB transferred' || echo n/a)
  echo "interleave-all : $l1" | tee -a "$LABEL-numa.txt"
  echo "local $node (6 thr) : $l2" | tee -a "$LABEL-numa.txt"
}

dump_baseline
run_cpu        # ~60s
run_mem_bw     # ~60s
run_mem_lat    # 6 x 10s
run_fio        # prep + 30 + 30s
run_iperf      # 30 + 30s
run_numa_probe # 20 + 20s
echo "===== DONE $(date -u +%FT%TZ) =====" | tee "$LABEL-done.txt"
