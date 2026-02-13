#!/usr/bin/env bash
#
# Install all dependencies needed to run containerlab SONiC labs.
#
# Usage: sudo ./scripts/install-dependencies.sh
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root (use sudo)"
    exit 1
fi

echo "==> Installing dependencies ..."
apt-get update -qy
apt-get install -y --no-install-recommends \
    containerlab \
    docker.io \
    python3 \
    python3-paramiko \
    python3-pytest \
    yq

echo ""
echo "Done! All dependencies installed."
echo ""
echo "Note: /dev/kvm must exist for QEMU support. If missing, run:"
echo "  sudo modprobe kvm_intel   (Intel CPUs)"
echo "  sudo modprobe kvm_amd     (AMD CPUs)"
