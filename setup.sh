#!/bin/bash
# Setup script for Sherman on CloudLab r6615 (ConnectX-6, Ubuntu 20.04)
# Usage:
#   Node 0 (memory server + compute server): bash setup.sh 0
#   Node 1 (compute server):                 bash setup.sh 1
#
# Run this on BOTH nodes. Node 0's experiment IP must be 10.10.1.1
# and Node 1's must be 10.10.1.2 (verify with `ip addr show ens1np0`).

set -e

NODE_ID=${1:-0}
REPO_URL="https://github.com/wilsonchang17/Sherman-CS6204.git"
MEMCACHED_SERVER_IP="10.10.1.1"
MEMCACHED_PORT="11211"
GID_INDEX=3  # RoCE v2 on mlx5_0 for r6615 nodes

echo "====== [$(hostname)] Starting setup for node $NODE_ID ======"

# -----------------------------------------------------------------------
# Step 1: Install MLNX_OFED 4.9 (required for ibv_exp_* API used by Sherman)
# -----------------------------------------------------------------------
echo "[1/6] Installing MLNX_OFED 4.9..."

OFED_VERSION="4.9-4.1.7.0"
OFED_DIR="MLNX_OFED_LINUX-${OFED_VERSION}-ubuntu20.04-x86_64"
OFED_TGZ="${OFED_DIR}.tgz"
OFED_URL="https://content.mellanox.com/ofed/MLNX_OFED-${OFED_VERSION}/${OFED_TGZ}"

if ! ofed_info -s 2>/dev/null | grep -q "4.9"; then
    cd /tmp
    if [ ! -f "$OFED_TGZ" ]; then
        wget -q "$OFED_URL"
    fi
    tar -xzf "$OFED_TGZ"
    cd "$OFED_DIR"
    sudo ./mlnxofedinstall --upstream-libs --dpdk --force --without-mft
    # NOTE: After this step, run `sudo /etc/init.d/openibd restart`
    # SSH will disconnect. Reconnect and re-run this script to continue.
    echo ""
    echo "*** OFED installed. Now run: sudo /etc/init.d/openibd restart ***"
    echo "*** SSH will disconnect. Reconnect and re-run setup.sh to continue. ***"
    exit 0
else
    echo "OFED 4.9 already installed, skipping."
fi

# -----------------------------------------------------------------------
# Step 2: Install system dependencies
# -----------------------------------------------------------------------
echo "[2/6] Installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y \
    cmake g++ git \
    libibverbs-dev librdmacm-dev \
    memcached libmemcached-dev \
    libboost-all-dev \
    infiniband-diags \
    pciutils

# -----------------------------------------------------------------------
# Step 3: Install CityHash
# -----------------------------------------------------------------------
echo "[3/6] Installing CityHash..."
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
# Step 4: Clone repo and apply configuration patches
# -----------------------------------------------------------------------
echo "[4/6] Setting up Sherman repo..."
cd ~
if [ ! -d "Sherman-CS6204" ]; then
    git clone "$REPO_URL"
fi
cd Sherman-CS6204

# Patch gidIndex from 1 to 3 (RoCE v2 on r6615)
if grep -q "int gidIndex = 1," include/Rdma.h; then
    sed -i 's/int gidIndex = 1,/int gidIndex = 3,/' include/Rdma.h
    echo "Patched gidIndex to 3 in include/Rdma.h"
fi

# Write memcached config (always points to node 0)
echo "$MEMCACHED_SERVER_IP" > memcached.conf
echo "$MEMCACHED_PORT" >> memcached.conf
echo "Written memcached.conf -> $MEMCACHED_SERVER_IP:$MEMCACHED_PORT"

# -----------------------------------------------------------------------
# Step 5: Configure hugepages and build
# -----------------------------------------------------------------------
echo "[5/6] Configuring hugepages..."
sudo sysctl -w vm.nr_hugepages=5120
# Make hugepages persistent across reboots
echo "vm.nr_hugepages=5120" | sudo tee -a /etc/sysctl.conf > /dev/null

echo "[6/6] Building Sherman..."
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

echo ""
echo "====== Build complete! ======"
echo ""

# -----------------------------------------------------------------------
# Step 6: Node-specific post-setup instructions
# -----------------------------------------------------------------------
if [ "$NODE_ID" -eq 0 ]; then
    echo "=== Node 0 instructions ==="
    echo "Start memcached (if not already running):"
    echo "  memcached -p $MEMCACHED_PORT -u nobody -d"
    echo ""
    echo "Run benchmark (from ~/Sherman-CS6204/build):"
    echo "  ./benchmark 2 50 22"
    echo "  (args: num_servers  read_ratio  num_threads)"
else
    echo "=== Node 1 instructions ==="
    echo "Make sure node 0's memcached is running first, then:"
    echo "Run benchmark (from ~/Sherman-CS6204/build):"
    echo "  ./benchmark 2 50 22"
fi

echo ""
echo "Verify RDMA is working: ibstat | grep -E 'State|Physical'"
echo "Expected: State: Active, Physical state: LinkUp"
