#!/usr/bin/env bash
#
# Install all dependencies needed to run containerlab SONiC labs.
#
# Usage: sudo ./scripts/install-dependencies.sh          # install
#        ./scripts/install-dependencies.sh --check        # check only
#
set -euo pipefail

COMMANDS=(docker containerlab yq python3 pytest)

# --check mode: verify prerequisites and exit
if [ "${1:-}" = "--check" ]; then
    echo "==> Checking prerequisites ..."
    FAIL=false
    for cmd in "${COMMANDS[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            echo "    [OK]      $cmd"
        else
            echo "    [MISSING] $cmd"
            FAIL=true
        fi
    done
    if [ -e /dev/kvm ]; then
        echo "    [OK]      /dev/kvm"
    else
        echo "    [MISSING] /dev/kvm"
        FAIL=true
    fi
    if [ "$FAIL" = true ]; then
        echo ""
        echo "Error: missing prerequisites. Install them with:"
        echo "    sudo ./scripts/install-dependencies.sh"
        exit 1
    fi
    exit 0
fi

# Install mode: must be root
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
