# Sherman Experiment Runbook
**Last updated: 2026-02-15**
Paste this file at the start of a new conversation to resume.

---

## Project
Reproduce Sherman (SIGMOD 2022) B+Tree RDMA experiments for CS6204 at Virginia Tech.
GitHub: https://github.com/wilsonchang17/Sherman-CS6204

---

## Hardware (c6525-100g, Clemson cluster)
- 2x CloudLab c6525-100g nodes
- node0: 10.10.1.1 (memory server + compute server)
- node1: 10.10.1.2 (compute server)
- On-chip memory: 128KB (paper claims 256KB)

NIC layout (confirmed via show_gids):

| Device  | Interface | IP          | Speed   | Role                           |
|---------|-----------|-------------|---------|--------------------------------|
| mlx5_0  | eno12399  | 130.127.x.x | 25Gbps  | Control network -- DO NOT USE for RDMA |
| mlx5_2  | ens1f0    | 10.10.1.x   | 100Gbps | Experiment network -- USE THIS |

---

## Current Code State
- gidIndex: 3 (RoCE v2, IPv4-mapped) in include/Rdma.h
- kLockChipMemSize: 128*1024 in include/Common.h
- NIC selection: must be [5]=='2' in src/rdma/Resource.cpp (setup.sh handles this)

## IMPORTANT: Previous results collected on mlx5_0 (control network) -- need re-run
All result_*.txt files so far used mlx5_0 (eno12399, 130.127.x.x, control network).
This was confirmed by CloudLab support via switch traffic counters.
Note: tcpdump cannot detect RDMA traffic (kernel bypass), so tcpdump showing 0 packets
does NOT mean the control network was idle. Must re-run with mlx5_2 patch applied.

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
patches (gidIndex=3, kLockChipMemSize=128KB, mlx5_2 NIC selection), hugepages, build.

At the end, setup prints verification -- confirm:
- NIC selection shows [5] == '2'  (NOT '0')
- show_gids shows mlx5_2 with 10.10.1.x on gidIndex 3

---

## Every Time You Run Benchmark

### Step 1: Verify experiment network is up (both nodes)
```bash
ip addr show ens1f0
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
sudo bash -c 'ulimit -l unlimited && timeout 180 ./benchmark 2 <read_ratio> 22 2>&1' | tee ~/result_<workload>.txt

# node1 (same time):
sudo bash -c 'ulimit -l unlimited && timeout 180 ./benchmark 2 <read_ratio> 22 2>&1'
```
Warmup ~60-120s, then throughput output begins.

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
| include/Common.h | kLockChipMemSize=256*1024 -> 128*1024 | Actual NIC on-chip memory is 128KB |
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

**Permission denied on make**
```bash
sudo chown -R $USER ~/Sherman-CS6204/
```

**libibverbs warnings (cxgb4, vmw_pvrdma, etc.)**
Harmless. Only mlx5 driver matters.

---

## Paper Reference
Sherman: A Write-Optimized Distributed B+Tree Index on Disaggregated Memory
SIGMOD 2022 -- https://github.com/thustorage/Sherman
