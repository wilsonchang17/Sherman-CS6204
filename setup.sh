#!/bin/bash
# Setup script for Sherman on CloudLab r6525 / r6615 (ConnectX-5/6, Ubuntu 20.04)
# Usage:
#   Node 0 (memory server + compute server): bash setup.sh 0
#   Node 1 (compute server):                 bash setup.sh 1
#
# Run this on BOTH nodes.
# Experiment network interface: ens3f0 (r6525) or ens1np0 (r6615)
# Node 0 IP: 10.10.1.1, Node 1 IP: 10.10.1.2

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

# Experiment network interface name (r6525 uses ens3f0, r6615 uses ens1np0)
IFACE="ens3f0"

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
# Step 3: Install system dependencies
# -----------------------------------------------------------------------
echo "[3/7] Installing dependencies..."
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

# Patch kLockChipMemSize to 128KB (ConnectX-5/6 on r6525 has 128KB on-chip memory)
# Change from 256KB to 128KB to match actual NIC capability
if grep -q "kLockChipMemSize = 256 \* 1024" include/Common.h; then
    sed -i 's/kLockChipMemSize = 256 \* 1024/kLockChipMemSize = 128 * 1024/' include/Common.h
    echo "Patched kLockChipMemSize to 128KB in include/Common.h"
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

rm -rf build && mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

echo ""
echo "====== Build complete! ======"
echo ""

if [ "$NODE_ID" -eq 0 ]; then
    echo "=== Node 0: next steps ==="
    echo "1. Kill any existing memcached:"
    echo "   sudo pkill memcached"
    echo "2. Start memcached bound to experiment network:"
    echo "   memcached -p $MEMCACHED_PORT -u nobody -l $MEMCACHED_SERVER_IP -d"
    echo "3. Run benchmark (both nodes at the same time):"
    echo "   sudo bash -c 'ulimit -l unlimited && ./benchmark 2 50 22'"
else
    echo "=== Node 1: next steps ==="
    echo "Make sure node 0's memcached is running, then run at the same time as node 0:"
    echo "   sudo bash -c 'ulimit -l unlimited && ./benchmark 2 50 22'"
fi

echo ""
echo "Verify RDMA: ibstat | grep -E 'State|Physical'"
echo "Expected: State: Active, Physical state: LinkUp"
echo ""
echo "Verify on-chip memory: check for 'RNIC has 128KB device memory' when running benchmark"
