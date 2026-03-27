# Sherman Experiment Runbook
**Last updated: 2026-03-26**
Paste this file at the start of a new conversation to resume.

---

## Project
Reproduce Sherman (SIGMOD 2022) B+Tree RDMA experiments for CS6204 at Virginia Tech.
GitHub: https://github.com/wilsonchang17/Sherman-CS6204
Report: sherman_report.docx (Part 1 complete), Part 2 in progress

---

## Hardware

All node types below use mlx5_2 as the experiment network.
setup.sh auto-detects the correct interface for r650, r6525, c6525-100g, r6615, and d6515.

CRITICAL: mlx5_0 is ALWAYS the control network -- DO NOT USE for RDMA on any node type.
Only mlx5_2 (experiment network, 10.10.1.x) is permitted for RDMA traffic.

### c6525-100g (Utah cluster) -- used for Part 1 benchmark runs
- 2x CloudLab c6525-100g nodes
- node0: 10.10.1.1 (memory server + compute server)
- node1: 10.10.1.2 (compute server)
- On-chip memory: 64KB (confirmed by ibv_exp_alloc_dm probe; paper claims 256KB)
- CPU: single-socket (AMD EPYC 7402P) -- cannot do NUMA emulation, Part 1 only
- Lock table: 64KB / 8B (uint64_t) = 8,192 entries (paper has 256KB / 2B = 131,072, 16x more)

| Component | Specification |
|-----------|---------------|
| CPU       | 24-core AMD EPYC 7402P at 2.80GHz |
| RAM       | 128GB ECC Memory (8x 16GB 3200MT/s RDIMMs) |
| Disk      | Two 1.6TB NVMe SSD (PCIe v4.0) |
| OS        | Ubuntu 20.04, MLNX_OFED 4.9-4.1.7.0 |
| NIC (control) | Dual-port Mellanox ConnectX-5 25GbE (mlx5_0/mlx5_1, eno12399) |
| NIC (experiment) | Dual-port Mellanox ConnectX-5 Ex 100GbE (mlx5_2, ens1f0) |

NIC layout (confirmed via show_gids):

| Device  | Interface | IP          | Speed   | Role                           |
|---------|-----------|-------------|---------|--------------------------------|
| mlx5_0  | eno12399  | 130.127.x.x | 25Gbps  | Control network -- DO NOT USE for RDMA |
| mlx5_2  | ens1f0    | 10.10.1.x   | 100Gbps | Experiment network -- USE THIS |

### r650 -- used for Part 2 (CXL emulation, fallback when r6525 unavailable)
- 2x CloudLab r650 nodes
- node0: 10.10.1.1 (memory server + compute server)
- node1: 10.10.1.2 (compute server)
- On-chip memory: TBD (ibv_exp_alloc_dm probe will detect after OFED install)
- CPU: dual-socket (2x 36-core Intel Xeon Platinum 8360Y) -- supports NUMA emulation
- NUMA distance: 20 (remote) vs 10 (local), ratio 2.0x -- weaker CXL simulation than r6525 (3.2x)
- Lock table: depends on detected on-chip memory size

| Component | Specification |
|-----------|---------------|
| CPU       | 2x 36-core Intel Xeon Platinum 8360Y at 2.4GHz |
| RAM       | 256GB ECC DDR4 (16x 16GB 3200MHz) |
| Disk      | One 480GB SATA SSD + One 1.6TB NVMe SSD (PCIe v4.0) |
| OS        | Ubuntu 20.04, MLNX_OFED 4.9-4.1.7.0 |
| NIC (control) | Dual-port Mellanox ConnectX-5 25GbE (mlx5_0/mlx5_1, eno12399/eno12409) |
| NIC (experiment) | Dual-port Mellanox ConnectX-6 100GbE (mlx5_2/mlx5_3, ens2f0/ens2f1) |

NIC layout (confirmed via ip link + speed probe):

| Device  | Interface | IP          | Speed   | Role                           |
|---------|-----------|-------------|---------|--------------------------------|
| mlx5_0  | eno12399  | 130.127.x.x | 25Gbps  | Control network -- DO NOT USE for RDMA |
| mlx5_2  | ens2f0    | 10.10.1.x   | 100Gbps | Experiment network -- USE THIS |

NOTE: NUMA interleaving on r650 is odd/even CPU assignment (node 0: 0,2,4,...; node 1: 1,3,5,...).
This is Intel's topology style vs AMD's contiguous assignment on r6525. numactl behaviour is identical.

### r6525 (Clemson cluster) -- used for Part 2 (CXL emulation)
- 2x CloudLab r6525 nodes
- node0: 10.10.1.1 (memory server + compute server)
- node1: 10.10.1.2 (compute server)
- On-chip memory: 128KB (confirmed by ibv_exp_alloc_dm probe)
- CPU: dual-socket (Two AMD EPYC 7543 Milan) -- required for NUMA-based CXL emulation
- Lock table: 128KB / 8B (uint64_t) = 16,384 entries

| Component | Specification |
|-----------|---------------|
| CPU       | 2x 32-core AMD EPYC 7543 (Milan) at 2.8GHz |
| RAM       | 256GB ECC DDR4 (16x 16GB 3200MHz) |
| Disk      | One 480GB SATA SSD + One 1.6TB NVMe SSD (PCIe v4.0) |
| OS        | Ubuntu 20.04, MLNX_OFED 4.9-4.1.7.0 |
| NIC (control) | Dual-port Mellanox ConnectX-5 25GbE (mlx5_0/mlx5_1, eno12399/eno12409) |
| NIC (experiment) | Dual-port Mellanox ConnectX-6 100GbE (mlx5_2/mlx5_3, ens3f0/ens3f1) |

NIC layout (confirmed via show_gids):

| Device  | Interface | IP          | Speed   | Role                           |
|---------|-----------|-------------|---------|--------------------------------|
| mlx5_0  | eno12399  | 130.127.x.x | 25Gbps  | Control network -- DO NOT USE for RDMA |
| mlx5_2  | ens3f0    | 10.10.1.x   | 100Gbps | Experiment network -- USE THIS |

---

## Current Code State
- gidIndex: 3 (RoCE v2, IPv4-mapped) in include/Rdma.h
- kLockChipMemSize: auto-detected by ibv_exp_alloc_dm probe at setup time (64KB on c6525-100g, 128KB on r6525, r650 TBD)
- NIC selection: must be [5]=='2' in src/rdma/Resource.cpp (setup.sh handles this)
- Lock entry type: uint64_t (8 bytes), NOT 16-bit masked CAS as in the paper -- this is why
  our lock table has 16x fewer entries than the paper even at the same memory size

---

## Part 1 Results (c6525-100g, mlx5_2, ens1f0, 100Gbps)

Traffic verified: mlx5_2 transmitted ~40-70 GB per run; mlx5_0 showed zero traffic.

### Uniform Workloads (zipfan=0, Figure 11)

| Workload | Read Ratio | Our Throughput (Mops) | Paper (Mops) | Our p50 (us) | Paper p50 (us) | Our p99 (us) | Paper p99 (us) |
|----------|------------|----------------------|--------------|--------------|----------------|--------------|----------------|
| Write-only | 0% | 3.06 | 16.04 | 8.0 | 10.7 | 173 | 17.5 |
| Write-intensive | 50% | 5.57 | 21.53 | 6.5 | 8.0 | 45 | 15 |
| Read-intensive | 95% | 9.75 | 32.4 | 4.1 | 5.0 | 12.9 | 12.1 |

### Skewed Workloads (zipfan=0.99, Figure 10)

| Workload | Read Ratio | Our Throughput (Mops) | Paper (Mops) | Our p50 (us) | Paper p50 (us) | Our p99 (us) | Paper p99 (us) |
|----------|------------|----------------------|--------------|--------------|----------------|--------------|----------------|
| Write-only | 0% | 3.06 | 4.14 | 8.4 | 9.6 | 174 | 1136 |
| Write-intensive | 50% | 5.57 | 8.02 | 6.5 | 6.9 | 44 | 209 |
| Read-intensive | 95% | 9.77 | 33.8 | 4.0 | 4.8 | 12.9 | 47 |

Key findings from Part 1:

1. Lock table saturation: uniform and skewed results are nearly identical. The 64KB NIC
   on-chip memory yields only 8,192 lock entries (vs paper's 131,072). Two compounding
   factors: smaller on-chip memory (64KB vs 256KB) AND larger entry size (8B uint64_t vs
   2B masked CAS). Combined effect is 16x fewer entries, causing hash collision rate to
   converge under both workload distributions and eliminating the skewed-workload HOCL
   advantage the paper demonstrates (paper p99: 1136us skewed vs 17.5us uniform; ours:
   174us vs 173us).

2. p99 latency for write-heavy workloads is elevated (~173us vs paper's 17.5us). Likely
   cause: CloudLab experiment network switches do not have PFC (Priority Flow Control)
   configured for RoCE v2, causing occasional packet drops and retransmissions under
   write-heavy lock contention.

3. Lower absolute throughput (e.g. 3.06 vs 16.04 Mops write-only) is expected: we use
   2 nodes / 44 threads vs the paper's 16 nodes / 176 threads (4x fewer threads).

---

## First-Time Setup (new nodes)

```bash
wget https://raw.githubusercontent.com/wilsonchang17/Sherman-CS6204/main/setup.sh
chmod +x setup.sh
sudo bash setup.sh 0   # node0
sudo bash setup.sh 1   # node1
```

After OFED installs, script exits -- restart driver then re-run:
```bash
sudo /etc/init.d/openibd restart
sudo bash setup.sh 0   # or 1
```

Setup does: MLNX_OFED 4.9, libibverbs (41mlnx1), deps, CityHash, network IP,
patches (gidIndex=3, kLockChipMemSize auto-detected, mlx5_2 NIC selection), hugepages, build.

At the end, setup prints verification -- confirm:
- NIC selection shows [5] == '2'  (NOT '0')
- show_gids shows mlx5_2 with 10.10.1.x on gidIndex 3

---

## Every Time You Run Benchmark

### Step 1: Verify experiment network is up (both nodes)
```bash
ip addr show ens1f0   # c6525-100g; use ens3f0 on r6525
# Expected: inet 10.10.1.1/24 (node0) or 10.10.1.2/24 (node1)
# If missing: sudo ip link set ens1f0 up && sudo ip addr add 10.10.1.<N>/24 dev ens1f0
```

### Step 2: Verify RDMA on experiment network (both nodes)
```bash
show_gids | grep "mlx5_2.*3"
# Expected: mlx5_2  1  3  ...10.10.1.x...  v2  ens1f0 (or ens3f0 on r6525)

grep "\[5\] ==" ~/Sherman-CS6204/src/rdma/Resource.cpp
# Expected: [5] == '2'   (NOT '0')
# If this shows '0', STOP IMMEDIATELY -- RDMA will route over the control network
```

### Step 3: Check memcached on experiment network (node0)
```bash
ss -tlnp | grep 11211
# Expected: 10.10.1.1:11211
# MUST be bound to 10.10.1.1, NOT 127.0.0.1

# If not running:
sudo systemctl stop memcached 2>/dev/null || true
memcached -p 11211 -u nobody -l 10.10.1.1 -d
```

### Step 4: Flush memcached and reset serverNum (node0, before EVERY run)
```bash
echo -e "flush_all\r\n" | nc 10.10.1.1 11211             # Expected: OK
echo -e "set serverNum 0 0 1\r\n0\r" | nc 10.10.1.1 11211  # Expected: STORED
```
flush_all is mandatory: stale QP keys from previous runs cause "transport retry counter
exceeded" on the next run. serverNum must start at 0 before each run.

### Step 5: Verify traffic is on experiment network after benchmark starts

Note: tcpdump CANNOT detect RDMA traffic -- RDMA (libibverbs) uses kernel bypass,
so tcpdump always shows 0 packets regardless of which NIC is used. This was confirmed
by CloudLab support via switch traffic counters. Use mlx5 port counters instead.

Before starting benchmark, snapshot the counters on both NICs:
```bash
# Snapshot BEFORE benchmark (both nodes)
cat /sys/class/infiniband/mlx5_0/ports/1/counters/port_xmit_data > /tmp/mlx5_0_before.txt
cat /sys/class/infiniband/mlx5_2/ports/1/counters/port_xmit_data > /tmp/mlx5_2_before.txt
```

After benchmark completes, check which NIC transmitted data:
```bash
# Check AFTER benchmark (both nodes)
echo "mlx5_0 (control, should be ~0):"
echo "before: $(cat /tmp/mlx5_0_before.txt)  after: $(cat /sys/class/infiniband/mlx5_0/ports/1/counters/port_xmit_data)"
echo "mlx5_2 (experiment, should be large):"
echo "before: $(cat /tmp/mlx5_2_before.txt)  after: $(cat /sys/class/infiniband/mlx5_2/ports/1/counters/port_xmit_data)"
```
mlx5_2 counter should increase by billions of bytes. mlx5_0 should be near zero.
If mlx5_0 increased significantly, the NIC patch was not applied correctly -- stop and fix.

### Step 6: Run benchmark (both nodes at the same time)
```bash
cd ~/Sherman-CS6204/build

# node0 (save result):
sudo bash -c 'ulimit -l unlimited && timeout 150 ./benchmark 2 <read_ratio> 22 2>&1' | tee ~/result_<workload>.txt

# node1 (same time):
sudo bash -c 'ulimit -l unlimited && timeout 150 ./benchmark 2 <read_ratio> 22 2>&1'
```
Warmup ~13-14s on c6525-100g (2 nodes), then throughput output begins. 150s total is sufficient.

---

## Workloads (all 6)

| read_ratio | zipfan | Workload                  | Result file                       | Paper Fig    |
|------------|--------|---------------------------|-----------------------------------|--------------| 
| 0          | 0      | Write-only (uniform)      | result_uniform_writeonly.txt      | Figure 11(a) |
| 50         | 0      | Write-intensive (uniform) | result_uniform_writeintensive.txt | Figure 11(b) |
| 95         | 0      | Read-intensive (uniform)  | result_uniform_readintensive.txt  | Figure 11(c) |
| 0          | 0.99   | Write-only (skewed)       | result_skewed_writeonly.txt       | Figure 10(a) |
| 50         | 0.99   | Write-intensive (skewed)  | result_skewed_writeintensive.txt  | Figure 10(b) |
| 95         | 0.99   | Read-intensive (skewed)   | result_skewed_readintensive.txt   | Figure 10(c) |

For skewed: edit test/benchmark.cpp, change zipfan = 0 to zipfan = 0.99, rebuild.
For uniform: change back to zipfan = 0, rebuild.

```bash
cd ~/Sherman-CS6204/build && make -j$(nproc)
```

---

## Key Patches (applied by setup.sh)

| File | Change | Reason |
|------|--------|--------|
| include/Rdma.h | gidIndex=1 -> 3 | RoCE v2, IPv4-mapped GID |
| include/Common.h | kLockChipMemSize=256*1024 -> auto-detected | Probe actual allocatable NIC on-chip memory (64KB on c6525-100g, 128KB on r6525) |
| src/rdma/Resource.cpp | [5]=='0' -> [5]=='2' | Select mlx5_2 (100Gbps experiment) not mlx5_0 (25Gbps control) |

The kLockChipMemSize probe compiles a small C program that calls ibv_exp_alloc_dm() with
decreasing sizes (128KB, 64KB, 32KB, 16KB) on mlx5_2 to find the actual allocatable limit.
On c6525-100g this returns 64KB; on r6525 this returns 128KB.

---

## Part 2: CXL-Emulated Platform (r6525 nodes)

### Concept

CXL memory adds latency because the CPU must access memory across an external link.
NUMA emulation replicates this by forcing the Memory Server's allocations onto NUMA node 1
while its CPU runs on node 0. Every DSM access crosses the AMD Infinity Fabric interconnect,
producing extra latency analogous to CXL.

Sherman requires NO code changes -- numactl operates at the OS level and is transparent
to Sherman. The benchmark binary, RDMA setup, and NIC selection are all unchanged.

```
CXL:  CPU --> PCIe/CXL link  --> CXL memory pool
NUMA: CPU (socket 0) --> Infinity Fabric --> DRAM (socket 1)
```

Why r6525 is required: c6525-100g has a single-socket CPU (AMD 7402P), so all DRAM is
local and NUMA emulation is impossible. r6525 has two sockets (Two AMD EPYC 7543), giving
two NUMA nodes with a measurable remote-access penalty.

### Step 0: Confirm NUMA topology (node0, before running anything)

```bash
numactl --hardware
```

Expected output:
```
available: 2 nodes (0-1)
node 0 cpus: 0-31
node 1 cpus: 32-63
node distances:
node   0   1
  0:  10  32
  1:  32  10
```

If only one node appears, you have a single-socket node -- do not proceed, re-provision.
The distance ratio (32/10 = 3.2x) quantifies the simulated CXL memory access overhead.

### Running Part 2 experiments

Run the same six workloads twice: once as baseline, once with CXL emulation.
All pre-run steps (Steps 1-5 above) apply identically to both groups.
The NIC verification in Step 5 is especially important -- mlx5_0 must show zero traffic.

**Group 1: r6525 Baseline (native DRAM, no numactl)**

node0 command:
```bash
cd ~/Sherman-CS6204/build
sudo bash -c 'ulimit -l unlimited && timeout 150 ./benchmark 2 <read_ratio> 22 2>&1' | tee ~/result_r6525_baseline_<workload>.txt
```

node1 command (same time):
```bash
cd ~/Sherman-CS6204/build
sudo bash -c 'ulimit -l unlimited && timeout 150 ./benchmark 2 <read_ratio> 22 2>&1'
```

Result files: result_r6525_baseline_uniform_writeonly.txt, etc.

**Group 2: r6525 CXL-Emulated (numactl on node0 Memory Server only)**

IMPORTANT: numactl must be inside the sudo call, not outside it. Correct form:

```bash
cd ~/Sherman-CS6204/build
sudo numactl --cpunodebind=0 --membind=1 \
  bash -c 'ulimit -l unlimited && timeout 150 ./benchmark 2 <read_ratio> 22 2>&1' \
  | tee ~/result_r6525_cxl_<workload>.txt
```

node1 command -- unchanged, no numactl needed:
```bash
cd ~/Sherman-CS6204/build
sudo bash -c 'ulimit -l unlimited && timeout 150 ./benchmark 2 <read_ratio> 22 2>&1'
```

Result files: result_r6525_cxl_uniform_writeonly.txt, etc.

### Verify numactl is working

While the CXL-emulated benchmark is running, confirm memory is allocated on node 1:
```bash
# On node0, in a separate terminal
numastat -p benchmark
# node1 column should show large and increasing memory usage
# If node0 column is large instead, numactl was not applied correctly -- stop and fix
```

### Part 2 Result Tables (fill in after running)

#### Uniform Workloads

| Workload | Part 1 c6525-100g | r6525 Baseline | r6525 CXL-Emulated |
|----------|-------------------|----------------|---------------------|
| Write-only Throughput (Mops) | 3.06 | ? | ? |
| Write-only p50 (us) | 8.0 | ? | ? |
| Write-only p99 (us) | 173 | ? | ? |
| Write-intensive Throughput (Mops) | 5.57 | ? | ? |
| Write-intensive p50 (us) | 6.5 | ? | ? |
| Write-intensive p99 (us) | 45 | ? | ? |
| Read-intensive Throughput (Mops) | 9.75 | ? | ? |
| Read-intensive p50 (us) | 4.1 | ? | ? |
| Read-intensive p99 (us) | 12.9 | ? | ? |

#### Skewed Workloads

| Workload | Part 1 c6525-100g | r6525 Baseline | r6525 CXL-Emulated |
|----------|-------------------|----------------|---------------------|
| Write-only Throughput (Mops) | 3.06 | ? | ? |
| Write-only p50 (us) | 8.4 | ? | ? |
| Write-only p99 (us) | 174 | ? | ? |
| Write-intensive Throughput (Mops) | 5.57 | ? | ? |
| Write-intensive p50 (us) | 6.5 | ? | ? |
| Write-intensive p99 (us) | 44 | ? | ? |
| Read-intensive Throughput (Mops) | 9.77 | ? | ? |
| Read-intensive p50 (us) | 4.0 | ? | ? |
| Read-intensive p99 (us) | 12.9 | ? | ? |

### Analysis checklist (for Part 2 report writing)

- CXL overhead: compare r6525 baseline vs CXL-emulated p50 and p99 -- how much did latency increase?
- Write vs read sensitivity: write-heavy workloads expected to be more affected because
  lock acquisition hits remote DRAM on every write; read-heavy workloads benefit from the
  index cache and avoid remote memory access more often
- On-chip memory improvement: r6525 has 128KB (16,384 lock entries) vs c6525-100g 64KB
  (8,192 entries); r6525 baseline skewed p99 should show improvement over Part 1
- NUMA distance ratio is 3.2x (32/10); check whether measured p50 latency increase is
  roughly proportional
- RDMA traffic: verify mlx5_2 transmitted data and mlx5_0 showed zero for both groups

---

## Troubleshooting

**apt broken after OFED install**
```bash
sudo dpkg --remove --force-depends ibverbs-providers python3-pyverbs
sudo apt-mark hold ibverbs-providers python3-pyverbs
sudo apt --fix-broken install -y
```

**benchmark hangs: "Couldn't incr value and get ID: NOT FOUND"**
serverNum not initialized. Run Step 4.

**"transport retry counter exceeded" on node1**
Stale memcached keys. Run flush_all in Step 4.

**hugepages gone after reboot**
```bash
sudo sysctl -w vm.nr_hugepages=5120
```

**Permission denied on make or sed -i**
```bash
sudo chown -R $USER ~/Sherman-CS6204/
```
This fixes both `make` and `sed -i` failures. `sed -i` needs to create a temp file in the same
directory, which fails if the directory is owned by root (from a previous sudo run of setup.sh).

**libibverbs warnings (cxgb4, vmw_pvrdma, etc.)**
Harmless. Only mlx5 driver matters.

**numactl: memory allocation on wrong node**
Verify with `numastat -p benchmark` while benchmark is running.
node1 column must show large memory usage. If node0 is large, numactl was not applied correctly.
Make sure you are using `sudo numactl ... bash -c '...'` not `numactl ... sudo bash -c '...'`.

**RDMA traffic on control network (mlx5_0 counter increasing)**
This must never happen. Stop the benchmark immediately.
Check patch: grep "\[5\] ==" ~/Sherman-CS6204/src/rdma/Resource.cpp
Must show '2', not '0'. Re-run setup.sh if needed.

---

## Paper Reference
Sherman: A Write-Optimized Distributed B+Tree Index on Disaggregated Memory
SIGMOD 2022 -- https://github.com/thustorage/Sherman
