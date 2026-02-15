# Sherman Experiment Runbook

## Hardware
- 2x CloudLab nodes with Mellanox ConnectX-5/6 100Gb NIC
- Preferred node types (in order): r6525 > c6525-100g > c6525-25g > d7615
- Experiment network interface: `ens3f0` (r6525) or `ens1f0` (c6525-100g)
- Node 0 IP: `10.10.1.1`, Node 1 IP: `10.10.1.2`

---

## CRITICAL: Control Network Warning

CloudLab has TWO network interfaces per node:

| Node type | Control NIC | mlx5 device | IP | Experiment NIC | mlx5 device | IP |
|-----------|-------------|-------------|----|----------------|-------------|-----|
| r6525 | `eno12399` | `mlx5_0` | `130.127.x.x` | `ens3f0` | `mlx5_2` | `10.10.1.x` |
| c6525-100g | `eno12399` | `mlx5_0` | `130.127.x.x` | `ens1f0` | `mlx5_2` | `10.10.1.x` |

**The original Sherman code selects `mlx5_0` (control network, 25Gbps) by default.**
This is confirmed by `show_gids`: mlx5_0 maps to `eno12399` with IP `130.127.x.x`.

Using mlx5_0 for RDMA benchmark traffic violates CloudLab's acceptable use policy.
**You MUST patch Resource.cpp to use mlx5_2 before running any benchmark.**

Verify correct NIC is in use:
```bash
# Must show mlx5_2 with 10.10.1.x before every run
show_gids | grep "mlx5_2.*3"

# Monitor control network during benchmark -- must show 0 packets
sudo tcpdump -i eno12399 -n port 4791 -q
```
If tcpdump shows ANY packets on port 4791 during benchmark, stop immediately.

---

## First-Time Setup (new nodes)

Run on both nodes (can run in parallel):

```bash
wget https://raw.githubusercontent.com/wilsonchang17/Sherman-CS6204/main/setup.sh
chmod +x setup.sh
sudo bash setup.sh 0   # node0
sudo bash setup.sh 1   # node1
```

### After OFED install, script exits and asks you to restart driver
```bash
sudo /etc/init.d/openibd restart
# SSH may disconnect -- reconnect and re-run setup.sh
sudo bash setup.sh 0   # or 1
```

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
8. Fix file ownership (`chown`) to avoid permission errors
9. Set hugepages=5120, memlock unlimited, build
10. node0: disable systemd memcached, start memcached on `10.10.1.1`, initialize `serverNum`

---

## MANDATORY: Patch NIC selection after setup (both nodes)

**setup.sh does NOT patch Resource.cpp. You must do this manually.**

```bash
# Apply patch (both nodes)
sed -i "s/deviceList\[i\])\[5\] == '0'/deviceList[i])[5] == '2'/" ~/Sherman-CS6204/src/rdma/Resource.cpp

# Verify patch applied
grep "\[5\] ==" ~/Sherman-CS6204/src/rdma/Resource.cpp
# Expected output: if (ibv_get_device_name(deviceList[i])[5] == '2') {

# Verify mlx5_2 maps to experiment network
show_gids | grep "mlx5_2.*3"
# Expected: mlx5_2  1  3  ...10.10.1.x...  v2  ens1f0

# Rebuild
cd ~/Sherman-CS6204/build && make -j$(nproc)
```

**Do NOT run benchmark until grep shows `'2'` and show_gids shows 10.10.1.x on mlx5_2.**

---

## Every Time You Run Benchmark

### Step 1: Verify experiment network is up (both nodes)
```bash
# c6525-100g:
ip addr show ens1f0
# r6525:
ip addr show ens3f0
# Expected: inet 10.10.1.1/24 (node0) or 10.10.1.2/24 (node1)
```

### Step 2: Verify RDMA is on experiment network (both nodes)
```bash
show_gids | grep "mlx5_2.*3"
# Expected: mlx5_2  1  3  ...10.10.1.x...  v2  ens1f0  (or ens3f0)
```

### Step 3: Verify NIC patch is still in place (both nodes)
```bash
grep "\[5\] ==" ~/Sherman-CS6204/src/rdma/Resource.cpp
# Expected: [5] == '2'   (NOT '0')
```

### Step 4: Check memcached is running on experiment network (node0)
```bash
ss -tlnp | grep 11211
# Expected: 10.10.1.1:11211  (NOT 0.0.0.0 or 127.0.0.1 only)

# If not running:
sudo systemctl stop memcached 2>/dev/null || true
memcached -p 11211 -u nobody -l 10.10.1.1 -d
```

### Step 5: Verify memcached reachable from both nodes
```bash
echo "stats" | nc 10.10.1.1 11211 | head -3
# Expected: STAT pid ...
```

### Step 6: Flush memcached and reset serverNum (node0, before EVERY run)
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

### Step 7: Start control network monitor (node0, second terminal)
```bash
sudo tcpdump -i eno12399 -n port 4791 -q
# Must show 0 packets during entire benchmark run
# If you see packets, STOP immediately -- you are using the wrong NIC
```

### Step 8: Run benchmark (both nodes at the same time)
```bash
cd ~/Sherman-CS6204/build

# node0 (save result):
sudo bash -c 'ulimit -l unlimited && timeout 180 ./benchmark 2 <read_ratio> 22 2>&1' | tee ~/result_<workload>.txt

# node1 (same time):
sudo bash -c 'ulimit -l unlimited && timeout 180 ./benchmark 2 <read_ratio> 22 2>&1'
```

node0 prints `I am server 0` first, then node1 connects (within a few seconds is fine).
Warmup takes ~60-120 seconds, then throughput output begins.

---

## Workload Parameters

| Command | zipfan in benchmark.cpp | Workload | Result file | Paper Figure |
|---------|--------------------------|----------|-------------|--------------|
| `./benchmark 2 0 22`  | 0    | Write-only (uniform)      | result_uniform_writeonly.txt      | Figure 11(a) |
| `./benchmark 2 50 22` | 0    | Write-intensive (uniform) | result_uniform_writeintensive.txt | Figure 11(b) |
| `./benchmark 2 95 22` | 0    | Read-intensive (uniform)  | result_uniform_readintensive.txt  | Figure 11(c) |
| `./benchmark 2 0 22`  | 0.99 | Write-only (skewed)       | result_skewed_writeonly.txt       | Figure 10(a) |
| `./benchmark 2 50 22` | 0.99 | Write-intensive (skewed)  | result_skewed_writeintensive.txt  | Figure 10(b) |
| `./benchmark 2 95 22` | 0.99 | Read-intensive (skewed)   | result_skewed_readintensive.txt   | Figure 10(c) |

For skewed workloads: edit `test/benchmark.cpp`, change `zipfan = 0` to `zipfan = 0.99`, rebuild.
For uniform: change back to `zipfan = 0`, rebuild.

---

## Key Patches

| File | Change | Reason |
|------|--------|--------|
| `include/Rdma.h` | `gidIndex=1` -> `3` | RoCE v2, IPv4-mapped GID on CloudLab |
| `include/Common.h` | `kLockChipMemSize=256*1024` -> `128*1024` | Actual NIC on-chip memory is 128KB |
| `src/rdma/Resource.cpp` | NIC `[5]=='0'` -> `[5]=='2'` | **MANUAL PATCH REQUIRED** -- select mlx5_2 (experiment network, 100Gbps) not mlx5_0 (control network, 25Gbps) |

---

## Known Issues & Fixes

### apt broken after OFED install
```bash
sudo dpkg --remove --force-depends ibverbs-providers python3-pyverbs
sudo apt-mark hold ibverbs-providers python3-pyverbs
sudo apt --fix-broken install -y
```

### benchmark hangs with "Couldn't incr value and get ID: NOT FOUND"
`serverNum` key not initialized. Run Step 6 above.

### "transport retry counter exceeded" on node1
Root cause: stale memcached keys from a previous run. Always run `flush_all` before every run (Step 6).

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
