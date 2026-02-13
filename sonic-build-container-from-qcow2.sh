#!/bin/bash
#
# Build a vrnetlab Docker image for SONiC VM from a sonic-vs.img.gz file.
#
# Usage: ./sonic-build-container-from-qcow2.sh <path-to-sonic-vs.img.gz>
#
# Produces: vrnetlab/sonic_sonic-vs:latest
#

set -euo pipefail

# Check if Cloudflare WARP is connected -- it breaks DNS in Docker builds.
if command -v warp-cli &>/dev/null; then
    if ! warp-cli status 2>&1 | grep -q "Disconnected"; then
        echo "Error: Cloudflare WARP is connected. Docker builds will fail (DNS broken)."
        echo "Disconnect with: warp-cli disconnect"
        exit 1
    fi
fi

if [ $# -ne 1 ]; then
    echo "Usage: $0 <path-to-sonic-vs.img.gz>"
    echo ""
    echo "  <path-to-sonic-vs.img.gz>  Path to SONiC VS image (QCOW2 compressed with gzip)"
    echo ""
    echo "Produces Docker image: vrnetlab/sonic_sonic-vs:latest"
    exit 1
fi

IMAGE_PATH="$1"

if [ ! -f "$IMAGE_PATH" ]; then
    echo "Error: file not found: $IMAGE_PATH"
    exit 1
fi

TAG="latest"
VRNETLAB_DIR="/tmp/vrnetlab-sonic-build"
SONIC_DIR="$VRNETLAB_DIR/sonic"

echo "==> Cloning vrnetlab into $VRNETLAB_DIR ..."
rm -rf "$VRNETLAB_DIR"
git clone --depth 1 https://github.com/srl-labs/vrnetlab.git "$VRNETLAB_DIR"

echo "==> Decompressing image into $SONIC_DIR/sonic-vs-${TAG}.qcow2 ..."
gunzip -c "$IMAGE_PATH" > "$SONIC_DIR/sonic-vs-${TAG}.qcow2"

echo "==> Building Docker image (this takes a few minutes) ..."
make -C "$SONIC_DIR"

echo "==> Cleaning up ..."
rm -rf "$VRNETLAB_DIR"

echo ""
echo "Done! Image built:"
docker images "vrnetlab/sonic_sonic-vs:${TAG}"
echo ""
echo "Use in containerlab topology:"
echo "  image: vrnetlab/sonic_sonic-vs:${TAG}"
