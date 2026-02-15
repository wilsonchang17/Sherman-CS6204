# Sherman Experiment Runbook

## Hardware
- 2x CloudLab nodes with Mellanox ConnectX-5/6 100Gb NIC
- Preferred node types (in order): r6525 > c6525-100g > c6525-25g > d7615
- Experiment network interface: `ens3f0` (r6525) or `ens1f0` (c6525-100g)
- Node 0 IP: `10.10.1.1`, Node 1 IP: `10.10.1.2`

> **c6525-100g verified compatible (Utah cluster, Feb 2026):**
> Despite different interface name (`ens1f0` vs `ens3f0`), the RDMA device layout is
> identical to r6525: `mlx5_2` maps to the experiment network, `gidIndex=3` is correct.
> **No changes to setup.sh are needed for c6525-100g.**

---

## CRITICAL: Control Network Warning

CloudLab has TWO network interfaces per node:

| Node type | Control NIC | mlx5 device | Experiment NIC | mlx5 device |
|-----------|-------------|-------------|----------------|-------------|
| r6525 | `eno12399` (`130.127.x.x`) | `mlx5_0` | `ens3f0` (`10.10.1.x`) | `mlx5_2` |
| c6525-100g | `eno33` (`128.110.x.x`) | `mlx5_0` | `ens1f0` (`10.10.1.x`) | `mlx5_2` |

On both node types, the original Sherman code selects `mlx5_0` (control network) by default.
`setup.sh` patches `src/rdma/Resource.cpp` to select `mlx5_2` (experiment network).

**Verify before every benchmark run:**
```bash
# Should show mlx5_2 with 10.10.1.x, gidIndex=3
show_gids | grep "mlx5_2.*3"

# Monitor during benchmark -- must show 0 packets
# r6525:
sudo tcpdump -i eno12399 -n port 4791 -q
# c6525-100g:
sudo tcpdump -i eno33 -n port 4791 -q
```
If tcpdump shows ANY packets on port 4791 during benchmark, stop immediately.
CloudLab will send a warning email and may block your account.

---

## First-Time Setup (new nodes)

Run on both nodes (can run in parallel):

```bash
wget https://raw.githubusercontent.com/wilsonchang17/Sherman-CS6204/main/setup.sh
chmod +x setup.sh
sudo bash setup.sh 0   # node0
sudo bash setup.sh 1   # node1
```

Works unchanged on both r6525 and c6525-100g.

### What setup.sh does
1. Install MLNX_OFED 4.9
2. Fix apt conflict: force-remove `ibverbs-providers` + `python3-pyverbs`, hold them
3. Install libibverbs (41mlnx1 from MLNX_LIBS, has `ibv_exp_*` API)
4. Install system deps: cmake, memcached, libboost-all-dev, etc.
5. Install CityHash from source
6. Set experiment network IP on the experiment interface
7. Clone repo + apply patches:
   - `gidIndex=3` (RoCE v2)
   - `kLockChipMemSize=128KB` (actual NIC on-chip memory)
   - **`mlx5_2` NIC selection** (experiment network, NOT control network)
8. Fix file ownership (`chown`) to avoid permission errors
9. Set hugepages=5120, memlock unlimited, build
10. node0: disable systemd memcached, start memcached on `10.10.1.1`, initialize `serverNum`

### After OFED install, script exits and asks you to restart driver
```bash
sudo /etc/init.d/openibd restart
# SSH may disconnect -- reconnect and re-run setup.sh
sudo bash setup.sh 0   # or 1
```

---

## Every Time You Run Benchmark

### Step 1: Verify experiment network is up (both nodes)
```bash
# r6525:
ip addr show ens3f0
# c6525-100g:
ip addr show ens1f0
# Expected: inet 10.10.1.1/24 (node0) or 10.10.1.2/24 (node1)
```

### Step 2: Verify RDMA is on experiment network (both nodes)
```bash
show_gids | grep "mlx5_2.*3"
# r6525 expected:    mlx5_2  1  3  ...10.10.1.x...  v2  ens3f0
# c6525-100g expected: mlx5_2  1  3  ...10.10.1.x...  v2  ens1f0
```

### Step 3: Check memcached is running on experiment network (node0)
```bash
ss -tlnp | grep 11211
# Expected: 10.10.1.1:11211  (NOT 0.0.0.0 or 127.0.0.1 only)

# If not running:
sudo systemctl stop memcached 2>/dev/null || true
memcached -p 11211 -u nobody -l 10.10.1.1 -d
```

### Step 4: Verify memcached reachable from both nodes
```bash
echo "stats" | nc 10.10.1.1 11211 | head -3
# Expected: STAT pid ...
```

### Step 5: Flush memcached and reset serverNum (node0, before EVERY run)
```bash
echo -e "flush_all\r\n" | nc 10.10.1.1 11211
# Expected: OK
echo -e "set serverNum 0 0 1\r\n0\r" | nc 10.10.1.1 11211
# Expected: STORED  (then Ctrl+C)
```
> Why flush_all: After each run, memcached accumulates ~150 stale keys (sum-sum-*, barrier-*,
> QP info). On the next run, Sherman reads these stale QP keys during handshake and builds
> QPs with wrong parameters -- QP never enters RTS state, causing "transport retry counter
> exceeded" on node1. flush_all clears everything so the next run starts clean.
>
> Why serverNum: Sherman uses memcached_increment on `serverNum` to assign node IDs (0 and 1).
> Key must exist with value 0 before each run.
> After a run, value becomes 2 -- must reset or nodes get wrong IDs.

### Step 6: Start control network monitor (node0, second terminal)
```bash
# r6525:
sudo tcpdump -i eno12399 -n port 4791 -q
# c6525-100g:
sudo tcpdump -i eno33 -n port 4791 -q
# Must show 0 packets during benchmark
```

### Step 7: Run benchmark (both nodes at the same time)
```bash
cd ~/Sherman-CS6204/build

# node0 (save result):
sudo bash -c 'ulimit -l unlimited && timeout 180 ./benchmark 2 <read_ratio> 22 2>&1' | tee ~/result_uniform_<read_ratio>.txt

# node1 (same time):
sudo bash -c 'ulimit -l unlimited && timeout 180 ./benchmark 2 <read_ratio> 22 2>&1'
```

node0 prints `I am server 0` first, then node1 connects (within a few seconds is fine).
Warmup takes ~60-120 seconds, then throughput output begins.

---

## Workload Parameters

| Command | Workload | Paper Figure |
|---------|----------|-------------|
| `./benchmark 2 0 22` | Write-only (uniform) | Figure 11(a) |
| `./benchmark 2 50 22` | Write-intensive (uniform) | Figure 11(b) |
| `./benchmark 2 95 22` | Read-intensive (uniform) | Figure 11(c) |

For skewed workloads (Figure 10), change `zipfan = 0.99` in `test/benchmark.cpp` and rebuild.

**Save results (node0):**
```bash
sudo bash -c 'ulimit -l unlimited && timeout 180 ./benchmark 2 0 22 2>&1' | tee ~/result_uniform_writeonly.txt
```

---

## Key Patches Applied by setup.sh

| File | Change | Reason |
|------|--------|--------|
| `include/Rdma.h` | `gidIndex=1` -> `3` | RoCE v2 on CloudLab (r6525 and c6525-100g) |
| `include/Common.h` | `kLockChipMemSize=256*1024` -> `128*1024` | Actual NIC on-chip memory is 128KB |
| `src/rdma/Resource.cpp` | NIC `[5]=='0'` -> `[5]=='2'` | Select mlx5_2 (experiment network) not mlx5_0 (control network) |

---

## Known Issues & Fixes

### apt broken after OFED install
```bash
sudo dpkg --remove --force-depends ibverbs-providers python3-pyverbs
sudo apt-mark hold ibverbs-providers python3-pyverbs
sudo apt --fix-broken install -y
```

### benchmark hangs with "Couldn't incr value and get ID: NOT FOUND"
`serverNum` key not initialized. Run Step 5 above.

### "transport retry counter exceeded" on node1
Root cause: stale memcached keys from a previous run. Sherman exchanges QP connection info
via memcached; if old keys remain, node1 builds a QP using stale parameters and it never
enters RTS state -- RDMA packets are never sent (kernel counters stay at 0).

Fix: always run `flush_all` before every benchmark run (see Step 5).

If it still fails, check node0 actually printed `I am server 0` before node1 started.

### Permission denied on make / sed
```bash
sudo chown -R $USER ~/Sherman-CS6204/
```

### systemd memcached on 127.0.0.1
```bash
sudo systemctl stop memcached && sudo systemctl disable memcached
```

### hugepages gone after reboot
```bash
sudo sysctl -w vm.nr_hugepages=5120
```

### libibverbs warnings about missing drivers (cxgb4, vmw_pvrdma, etc.)
Harmless. Only mlx5 driver matters.

---

## Paper Reference
Sherman: A Write-Optimized Distributed B+Tree Index on Disaggregated Memory
SIGMOD 2022 -- https://github.com/thustorage/Sherman
