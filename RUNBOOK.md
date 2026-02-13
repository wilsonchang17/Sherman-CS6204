# Sherman Experiment Runbook

## Hardware
- 2x CloudLab nodes with Mellanox ConnectX-5/6 100Gb NIC
- Preferred node types (in order): r6525 > c6525-25g > d7615
- Experiment network interface: `ens3f0` (r6525) or `ens1np0` (r6615)
- Node 0 IP: `10.10.1.1`, Node 1 IP: `10.10.1.2`

---

## First-Time Setup (new nodes)

Run on both nodes (node0 first, node1 can run in parallel):

```bash
wget https://raw.githubusercontent.com/wilsonchang17/Sherman-CS6204/main/setup.sh
chmod +x setup.sh
sudo bash setup.sh 0   # node0
sudo bash setup.sh 1   # node1
```

### What setup.sh does
1. Install MLNX_OFED 4.9
2. Fix apt conflict: force-remove `ibverbs-providers` + `python3-pyverbs`, hold them
3. Install libibverbs (41mlnx1 from MLNX_LIBS, has `ibv_exp_*` API)
4. Install system deps: cmake, memcached, libboost-all-dev, etc.
5. Install CityHash from source
6. Set experiment network IP on `ens3f0`
7. Clone repo + apply patches (gidIndex=3, kLockChipMemSize=128KB)
8. Set hugepages=5120, memlock unlimited, build
9. node0: start memcached + initialize `serverNum` key

### After OFED install, script exits and asks you to restart driver
```bash
sudo /etc/init.d/openibd restart
# SSH may disconnect -- reconnect and re-run setup.sh
sudo bash setup.sh 0   # or 1
```

---

## Every Time You Run Benchmark

### Step 1: Check memcached is running (node0)
```bash
pgrep memcached
# If not running:
memcached -p 11211 -u nobody -l 10.10.1.1 -d
```

### Step 2: Verify memcached reachable from both nodes
```bash
echo "stats" | nc 10.10.1.1 11211 | head -3
# Expected: STAT pid ...
```

### Step 3: Reset serverNum key (node0, before EVERY run)
```bash
echo -e "set serverNum 0 0 1\r\n0\r" | nc 10.10.1.1 11211
# Expected: STORED
# Ctrl+C to exit nc
```
> Why: Sherman uses memcached_increment on `serverNum` to assign node IDs.
> The key must exist with value 0 before each run, or all nodes get NOT FOUND.
> After a run, the value becomes 2 (incremented by both nodes), so reset is needed.

### Step 4: Run benchmark (both nodes at the same time)
```bash
cd ~/Sherman-CS6204/build
sudo bash -c 'ulimit -l unlimited && ./benchmark 2 50 22'
```
- `2` = number of nodes
- `50` = read ratio (50% reads, 50% writes)
- `22` = CPU cores per CS (matches paper setup)

Expected output includes:
```
The RNIC has 128KB device memory
I am server 0   (or 1)
...throughput / latency results
```

---

## Key Patches Applied to Repo

| File | Change | Reason |
|------|--------|--------|
| `include/Rdma.h` | `gidIndex = 1` -> `3` | RoCE v2 on CloudLab r6525 |
| `include/Common.h` | `kLockChipMemSize = 256*1024` -> `128*1024` | Actual NIC on-chip memory is 128KB |

---

## Known Issues & Fixes

### apt broken after OFED install
OFED installs `ibverbs-providers` (50mlnx1) which conflicts with Ubuntu's version.
```bash
sudo dpkg --remove --force-depends ibverbs-providers python3-pyverbs
sudo apt-mark hold ibverbs-providers python3-pyverbs
sudo apt --fix-broken install -y
```

### benchmark hangs with "Couldn't incr value and get ID: NOT FOUND"
`serverNum` key not initialized in memcached. Run Step 3 above.

### libibverbs warnings about missing drivers (cxgb4, vmw_pvrdma, etc.)
Harmless. These are other RDMA vendors' drivers that aren't installed.
Only `mlx5` matters and it loads correctly.

### hugepages gone after reboot
```bash
sudo sysctl -w vm.nr_hugepages=5120
```

---

## Paper Reference
Sherman: A Write-Optimized Distributed B+Tree Index on Disaggregated Memory  
SIGMOD 2022 -- https://github.com/thustorage/Sherman
