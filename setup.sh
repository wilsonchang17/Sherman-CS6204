#!/bin/bash
# Setup script for Sherman on CloudLab r6525 / c6525-100g / r6615 (ConnectX-5/6, Ubuntu 20.04)
# Usage:
#   Node 0 (memory server + compute server): bash setup.sh 0
#   Node 1 (compute server):                 bash setup.sh 1
#
# Run this on BOTH nodes.
# Experiment network interface: ens3f0 (r6525) or ens1f0 (c6525-100g) or ens1np0 (r6615)
# Node 0 IP: 10.10.1.1, Node 1 IP: 10.10.1.2
#
# NOTE: c6525-100g (Utah) verified compatible -- RDMA device layout is identical to r6525:
#   mlx5_0/mlx5_1 = control network (eno33/eno34), mlx5_2 = experiment network (ens1f0).
#   No changes needed; IFACE below is the only difference but setup.sh auto-detects it.

set -e

NODE_ID=${1:-0}
REPO_URL="https://github.com/wilsonchang17/Sherman-CS6204.git"
MEMCACHED_SERVER_IP="10.10.1.1"
MEMCACHED_PORT="11211"
GID_INDEX=3  # RoCE v2, confirm with `show_gids` on your node type

OFED_VERSION="4.9-4.1.7.0"
OFED_DIR="MLNX_OFED_LINUX-${OFED_VERSION}-ubuntu20.04-x86_64"
OFED_TGZ="${OFED_DIR}.tgz"
OFED_URL="https://content.mellanox.com/ofed/MLNX_OFED-${OFED_VERSION}/${OFED_TGZ}"

# Experiment network interface name:
#   r6525:      ens3f0
#   c6525-100g: ens1f0   (mlx5_2, same RDMA layout as r6525 -- no other changes needed)
#   r6615:      ens1np0
# Auto-detect: pick whichever interface exists on this node type.
if ip link show ens3f0 2>/dev/null | grep -q "ens3f0"; then
    IFACE="ens3f0"
elif ip link show ens1f0 2>/dev/null | grep -q "ens1f0"; then
    IFACE="ens1f0"
elif ip link show ens1np0 2>/dev/null | grep -q "ens1np0"; then
    IFACE="ens1np0"
else
    echo "ERROR: Cannot detect experiment network interface. Set IFACE manually."
    exit 1
fi
echo "Detected experiment network interface: $IFACE"

echo "====== [$(hostname)] Starting setup for node $NODE_ID ======"

# -----------------------------------------------------------------------
# Step 1: Install MLNX_OFED 4.9
# -----------------------------------------------------------------------
echo "[1/7] Checking MLNX_OFED 4.9..."
if ! ofed_info -s 2>/dev/null | grep -q "4.9"; then
    echo "Installing MLNX_OFED 4.9..."
    cd /tmp
    if [ ! -f "$OFED_TGZ" ]; then
        wget -q "$OFED_URL"
    fi
    tar -xzf "$OFED_TGZ"
    cd "$OFED_DIR"
    sudo ./mlnxofedinstall --upstream-libs --dpdk --force --without-mft
    echo ""
    echo "*** OFED installed. Now run: sudo /etc/init.d/openibd restart ***"
    echo "*** SSH will disconnect. Reconnect and re-run setup.sh to continue. ***"
    exit 0
else
    echo "OFED 4.9 already installed, skipping."
fi

# -----------------------------------------------------------------------
# Step 2: Install libibverbs + mlx5 driver from MLNX_LIBS
# CRITICAL: Must use 41mlnx1 from MLNX_LIBS (has ibv_exp_* API)
#           NOT 50mlnx1 from UPSTREAM_LIBS (missing ibv_exp_*)
# Also install libmlx5-1 from MLNX_LIBS so libibverbs finds libmlx5-rdmav2.so
# -----------------------------------------------------------------------
echo "[2/7] Installing MLNX_LIBS packages..."

MLNX_LIBS="/tmp/${OFED_DIR}/DEBS/MLNX_LIBS"
UPSTREAM_LIBS="/tmp/${OFED_DIR}/DEBS/UPSTREAM_LIBS"

if [ ! -d "$MLNX_LIBS" ]; then
    cd /tmp
    if [ ! -f "$OFED_TGZ" ]; then
        wget -q "$OFED_URL"
    fi
    tar -xzf "$OFED_TGZ"
fi

# Install libibverbs (41mlnx1 has ibv_exp_*)
sudo dpkg -i --force-all \
    ${MLNX_LIBS}/libibverbs1_41mlnx1-OFED.4.9.3.0.0.49417_amd64.deb \
    ${MLNX_LIBS}/libibverbs-dev_41mlnx1-OFED.4.9.3.0.0.49417_amd64.deb

# Install mlx5 userspace driver from MLNX_LIBS
# This provides libmlx5-rdmav2.so which libibverbs (41mlnx1) expects
sudo dpkg -i --force-all \
    ${MLNX_LIBS}/libmlx5-1_41mlnx1-OFED.4.9.0.1.2.49417_amd64.deb

# Install librdmacm from UPSTREAM_LIBS
sudo dpkg -i --force-all \
    ${UPSTREAM_LIBS}/librdmacm1_50mlnx1-1.49417_amd64.deb \
    ${UPSTREAM_LIBS}/librdmacm-dev_50mlnx1-1.49417_amd64.deb

# libibverbs (41mlnx1) looks for libmlx5-rdmav2.so in /usr/lib/
# but MLNX_LIBS installs it to /usr/lib/libibverbs/ -- add symlinks
sudo ln -sf /usr/lib/libibverbs/libmlx5-rdmav2.so /usr/lib/libmlx5-rdmav2.so 2>/dev/null || true
sudo ln -sf /usr/lib/libibverbs/libmlx4-rdmav2.so /usr/lib/libmlx4-rdmav2.so 2>/dev/null || true

# Make sure /usr/lib/libibverbs is in ldconfig path
echo "/usr/lib/libibverbs" | sudo tee /etc/ld.so.conf.d/libibverbs.conf > /dev/null
sudo ldconfig

# Verify ibv_exp_* is present
IBV_EXP_COUNT=$(grep -c "ibv_exp_" /usr/include/infiniband/verbs_exp.h 2>/dev/null || echo 0)
if [ "$IBV_EXP_COUNT" -eq 0 ]; then
    echo "ERROR: ibv_exp_* not found in verbs_exp.h after install."
    exit 1
fi
echo "ibv_exp_* found ($IBV_EXP_COUNT occurrences). OK."

# -----------------------------------------------------------------------
# Step 3: Fix apt conflicts caused by OFED ibverbs-providers collision,
# then install system dependencies
# -----------------------------------------------------------------------
echo "[3/7] Installing dependencies..."

# OFED installs ibverbs-providers (50mlnx1) which conflicts with Ubuntu's
# ibverbs-providers and causes apt to be completely broken.
# Force-remove both conflicting packages and hold them to prevent apt
# from reinstalling the Ubuntu version.
sudo dpkg --remove --force-depends ibverbs-providers python3-pyverbs 2>/dev/null || true
sudo apt-mark hold ibverbs-providers python3-pyverbs 2>/dev/null || true
sudo apt --fix-broken install -y

sudo apt-get update -qq
sudo apt-get install -y \
    cmake g++ git \
    memcached libmemcached-dev \
    libboost-all-dev \
    infiniband-diags \
    pciutils

# -----------------------------------------------------------------------
# Step 4: Install CityHash
# -----------------------------------------------------------------------
echo "[4/7] Installing CityHash..."
if ! ldconfig -p | grep -q "libcityhash"; then
    cd /tmp
    if [ ! -d "cityhash" ]; then
        git clone https://github.com/google/cityhash.git
    fi
    cd cityhash
    ./configure && make -j$(nproc) && sudo make install && sudo ldconfig
else
    echo "CityHash already installed, skipping."
fi

# -----------------------------------------------------------------------
# Step 5: Configure experiment network interface
# CloudLab does not auto-assign IPs on experiment interfaces.
# Node 0 gets 10.10.1.1, Node 1 gets 10.10.1.2.
# -----------------------------------------------------------------------
echo "[5/7] Configuring experiment network ($IFACE)..."
NODE_IP="10.10.1.$((NODE_ID + 1))"
if ! ip addr show "$IFACE" 2>/dev/null | grep -q "$NODE_IP"; then
    sudo ip link set "$IFACE" up
    sudo ip addr add "${NODE_IP}/24" dev "$IFACE" 2>/dev/null || true
    echo "Set $IFACE to $NODE_IP"
else
    echo "$IFACE already has $NODE_IP, skipping."
fi

# -----------------------------------------------------------------------
# Step 6: Clone repo and apply patches
# -----------------------------------------------------------------------
echo "[6/7] Setting up Sherman repo..."
cd ~
if [ ! -d "Sherman-CS6204" ]; then
    git clone "$REPO_URL"
fi
cd Sherman-CS6204

# Pull latest changes
git pull --ff-only 2>/dev/null || true

# Patch gidIndex to 3 (RoCE v2, confirm with show_gids)
if grep -q "int gidIndex = 1," include/Rdma.h; then
    sed -i 's/int gidIndex = 1,/int gidIndex = 3,/' include/Rdma.h
    echo "Patched gidIndex to 3 in include/Rdma.h"
fi

# Patch kLockChipMemSize to 128KB (ConnectX-5/6 on r6525 and c6525-100g has 128KB on-chip memory)
# Change from 256KB to 128KB to match actual NIC capability
if grep -q "kLockChipMemSize = 256 \* 1024" include/Common.h; then
    sed -i 's/kLockChipMemSize = 256 \* 1024/kLockChipMemSize = 128 * 1024/' include/Common.h
    echo "Patched kLockChipMemSize to 128KB in include/Common.h"
fi

# CRITICAL: Patch NIC selection to use mlx5_2 (experiment network 10.10.1.x)
# NOT mlx5_0 (control network).
# On both r6525 and c6525-100g, mlx5_0/mlx5_1 are control network NICs -- using them
# sends all RDMA traffic over CloudLab's shared control network, violating policy.
# mlx5_2 is the experiment network NIC on both node types (ens3f0 or ens1f0).
# Original code selects device whose name has '0' at position 5 (mlx5_0).
# We change it to '2' to select mlx5_2 (experiment network).
if grep -q "deviceList\[i\])\[5\] == '0'" src/rdma/Resource.cpp; then
    cp src/rdma/Resource.cpp /tmp/Resource.cpp.bak
    sed "s/deviceList\[i\])\[5\] == '0'/deviceList[i])[5] == '2'/" /tmp/Resource.cpp.bak > /tmp/Resource.cpp
    cp /tmp/Resource.cpp src/rdma/Resource.cpp
    echo "Patched NIC selection to mlx5_2 (ens3f0) in src/rdma/Resource.cpp"
fi

# Write memcached config pointing to node 0
echo "$MEMCACHED_SERVER_IP" > memcached.conf
echo "$MEMCACHED_PORT" >> memcached.conf
echo "Written memcached.conf -> $MEMCACHED_SERVER_IP:$MEMCACHED_PORT"

# -----------------------------------------------------------------------
# Step 7: Configure hugepages and build
# -----------------------------------------------------------------------
echo "[7/7] Configuring hugepages and building..."
sudo sysctl -w vm.nr_hugepages=5120
grep -q "vm.nr_hugepages" /etc/sysctl.conf || \
    echo "vm.nr_hugepages=5120" | sudo tee -a /etc/sysctl.conf > /dev/null

# Set memlock unlimited so Sherman can register 8GB memory region
grep -q "memlock unlimited" /etc/security/limits.conf || \
    echo "* soft memlock unlimited" | sudo tee -a /etc/security/limits.conf > /dev/null
grep -q "hard memlock unlimited" /etc/security/limits.conf || \
    echo "* hard memlock unlimited" | sudo tee -a /etc/security/limits.conf > /dev/null

# Fix ownership in case previous sudo run left root-owned files
 sudo chown -R $USER ~/Sherman-CS6204/

rm -rf build && mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

echo ""
echo "====== Build complete! ======"
echo ""

if [ "$NODE_ID" -eq 0 ]; then
    # Start memcached bound to experiment network IP
    # Stop systemd memcached (binds to 127.0.0.1 by default, causes confusion)
    sudo systemctl stop memcached 2>/dev/null || true
    sudo systemctl disable memcached 2>/dev/null || true
    sudo pkill memcached 2>/dev/null || true
    sleep 1
    memcached -p $MEMCACHED_PORT -u nobody -l $MEMCACHED_SERVER_IP -d
    sleep 1
    # Initialize serverNum key to 0 so Sherman's memcached_increment works.
    # Sherman uses incr on this key to assign node IDs; incr fails if key doesn't exist.
    echo -e "set serverNum 0 0 1\r\n0\r" | nc $MEMCACHED_SERVER_IP $MEMCACHED_PORT
    echo "memcached started on $MEMCACHED_SERVER_IP:$MEMCACHED_PORT (serverNum initialized)"
    echo ""
    echo "=== Node 0: next steps ==="
    echo "Run benchmark (both nodes at the same time):"
    echo "   sudo bash -c 'ulimit -l unlimited && ./benchmark 2 50 22'"
else
    echo "=== Node 1: next steps ==="
    echo "Make sure node 0's setup.sh has finished, then run at the same time as node 0:"
    echo "   sudo bash -c 'ulimit -l unlimited && ./benchmark 2 50 22'"
fi

echo ""
echo "Verify RDMA: ibstat | grep -E 'State|Physical'"
echo "Expected: State: Active, Physical state: LinkUp"
echo ""
echo "Verify on-chip memory: check for 'RNIC has 128KB device memory' when running benchmark"
