#!/bin/bash
#
# Build a vrnetlab Docker image for SONiC VM from a sonic-vs.img.gz file.
#
# Usage: ./sonic-build-container-from-qcow2.sh <path-to-sonic-vs.img.gz> <version>
#
# Example: ./sonic-build-container-from-qcow2.sh ~/sonic-vs.img.gz 202405
#
# Produces: vrnetlab/sonic_sonic-vs:<version>
#

set -euo pipefail

read -p "Make sure WARP (Cloudflare) is turned off before continuing. Press Enter to proceed..."

if [ $# -ne 2 ]; then
    echo "Usage: $0 <path-to-sonic-vs.img.gz> <version>"
    echo ""
    echo "  <path-to-sonic-vs.img.gz>  Path to SONiC VS image (QCOW2 compressed with gzip)"
    echo "  <version>                  Version tag, e.g. 202405"
    echo ""
    echo "Produces Docker image: vrnetlab/sonic_sonic-vs:<version>"
    exit 1
fi

IMAGE_PATH="$1"
VERSION="$2"

if [ ! -f "$IMAGE_PATH" ]; then
    echo "Error: file not found: $IMAGE_PATH"
    exit 1
fi

VRNETLAB_DIR="/tmp/vrnetlab-sonic-build"
SONIC_DIR="$VRNETLAB_DIR/sonic"

echo "==> Cloning vrnetlab into $VRNETLAB_DIR ..."
rm -rf "$VRNETLAB_DIR"
git clone --depth 1 https://github.com/srl-labs/vrnetlab.git "$VRNETLAB_DIR"

echo "==> Decompressing image into $SONIC_DIR/sonic-vs-${VERSION}.qcow2 ..."
gunzip -c "$IMAGE_PATH" > "$SONIC_DIR/sonic-vs-${VERSION}.qcow2"

echo "==> Building Docker image (this takes a few minutes) ..."
make -C "$SONIC_DIR"

echo "==> Cleaning up ..."
rm -rf "$VRNETLAB_DIR"

echo ""
echo "Done! Image built:"
docker images "vrnetlab/sonic_sonic-vs:${VERSION}"
echo ""
echo "Use in containerlab topology:"
echo "  image: vrnetlab/sonic_sonic-vs:${VERSION}"
