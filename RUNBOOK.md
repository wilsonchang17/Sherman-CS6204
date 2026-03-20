# Sherman Experiment Runbook
**Last updated: 2026-03-20**
Paste this file at the start of a new conversation to resume.

---

## Project
Reproduce Sherman (SIGMOD 2022) B+Tree RDMA experiments for CS6204 at Virginia Tech.
GitHub: https://github.com/wilsonchang17/Sherman-CS6204
Report: sherman_report.docx

---

## Hardware

Both node types below have identical RDMA device layout (mlx5_2 = experiment network).
setup.sh auto-detects the correct interface and works on both without modification.

### c6525-100g (Utah cluster) -- used for final benchmark runs
- 2x CloudLab c6525-100g nodes
- node0: 10.10.1.1 (memory server + compute server)
- node1: 10.10.1.2 (compute server)
- On-chip memory: 64KB (confirmed by ibv_exp_alloc_dm probe; paper claims 256KB)

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

### r6525 (Clemson cluster) -- also compatible
- 2x CloudLab r6525 nodes
- Same IP assignment, same RDMA layout as c6525-100g
- Only difference: experiment interface is ens3f0 instead of ens1f0
- On-chip memory: 128KB (confirmed by ibv_exp_alloc_dm probe)

| Component | Specification |
|-----------|---------------|
| CPU       | 2x AMD EPYC 7xx2 (Rome), 24 cores total |
| RAM       | 128GB ECC DDR4 |
| OS        | Ubuntu 20.04, MLNX_OFED 4.9-4.1.7.0 |
| NIC (control) | Dual-port Mellanox ConnectX-5 25GbE (mlx5_0/mlx5_1, eno12399/eno12409) |
| NIC (experiment) | Dual-port Mellanox ConnectX-5 Ex 100GbE (mlx5_2/mlx5_3, ens3f0/ens3f1) |

NIC layout (confirmed via show_gids):

| Device  | Interface | IP          | Speed   | Role                           |
|---------|-----------|-------------|---------|--------------------------------|
| mlx5_0  | eno12399  | 130.127.x.x | 25Gbps  | Control network -- DO NOT USE for RDMA |
| mlx5_2  | ens3f0    | 10.10.1.x   | 100Gbps | Experiment network -- USE THIS |

---

## Current Code State
- gidIndex: 3 (RoCE v2, IPv4-mapped) in include/Rdma.h
- kLockChipMemSize: auto-detected by ibv_exp_alloc_dm probe at setup time (64KB on c6525-100g, 128KB on r6525)
- NIC selection: must be [5]=='2' in src/rdma/Resource.cpp (setup.sh handles this)

---

## Final Benchmark Results (c6525-100g, mlx5_2, ens1f0, 100Gbps)

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

Key finding: Uniform and skewed results are nearly identical because the 64KB NIC on-chip
memory yields only 8,192 lock entries (vs. paper's 131,072), causing lock table saturation
under both workload distributions. This eliminates the skewed-workload advantage HOCL
would otherwise provide.

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
# Expected: mlx5_2  1  3  ...10.10.1.x...  v2  ens1f0

grep "\[5\] ==" ~/Sherman-CS6204/src/rdma/Resource.cpp
# Expected: [5] == '2'   (NOT '0')
```

### Step 3: Check memcached on experiment network (node0)
```bash
ss -tlnp | grep 11211
# Expected: 10.10.1.1:11211

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
This fixes both `make` and `sed -i` failures. `sed -i` needs to create a temp file in the same directory, which fails if the directory is owned by root (from a previous sudo run of setup.sh).

**libibverbs warnings (cxgb4, vmw_pvrdma, etc.)**
Harmless. Only mlx5 driver matters.

---

## Paper Reference
Sherman: A Write-Optimized Distributed B+Tree Index on Disaggregated Memory
SIGMOD 2022 -- https://github.com/thustorage/Sherman
