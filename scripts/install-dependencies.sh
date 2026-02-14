#!/usr/bin/env bash
#
# Install all dependencies needed to run containerlab SONiC labs.
# Requires a Debian-based system (Debian, Ubuntu) with apt.
#
# Usage: sudo ./scripts/install-dependencies.sh          # install
#        ./scripts/install-dependencies.sh --check        # check only
#
set -euo pipefail

# =============================================================================
# CHECK MODE
# =============================================================================

check_prerequisites() {
    echo "==> Checking prerequisites ..."
    local fail=false

    for cmd in docker containerlab yq python3 pytest; do
        if command -v "$cmd" &>/dev/null; then
            echo "    [OK]      $cmd"
        else
            echo "    [MISSING] $cmd"
            fail=true
        fi
    done

    # Non-root users need docker group and clab_admins group access
    if [ "$(id -u)" -ne 0 ]; then
        if command -v docker &>/dev/null && ! docker info &>/dev/null; then
            echo "    [ERROR]   docker daemon not accessible (run with sudo, or: sudo usermod -aG docker \$USER && newgrp docker)"
            fail=true
        fi

        if getent group clab_admins &>/dev/null && ! id -nG 2>/dev/null | grep -qw clab_admins; then
            echo "    [ERROR]   user not in clab_admins group (run with sudo, or: sudo usermod -aG clab_admins \$USER && newgrp clab_admins)"
            fail=true
        fi
    fi

    if [ -e /dev/kvm ]; then
        echo "    [OK]      /dev/kvm"
    else
        echo "    [MISSING] /dev/kvm -- run: sudo modprobe kvm_intel (or kvm_amd)"
        fail=true
    fi

    if [ "$fail" = true ]; then
        echo ""
        echo "Error: missing prerequisites. Install with: sudo ./scripts/install-dependencies.sh"
        exit 1
    fi
}

if [ "${1:-}" = "--check" ]; then
    check_prerequisites
    exit 0
fi

# =============================================================================
# INSTALL MODE
# =============================================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root (use sudo)"
    exit 1
fi

if ! command -v apt-get &>/dev/null; then
    echo "Error: apt-get not found. This script requires a Debian-based system."
    exit 1
fi

echo "==> Installing apt dependencies ..."
apt-get update -qy
apt-get install -y --no-install-recommends \
    curl \
    docker.io \
    python3 \
    python3-paramiko \
    python3-pytest \
    yq

# On Debian Trixie+, the docker CLI is a separate package from docker.io
if apt-cache show docker-cli &>/dev/null; then
    apt-get install -y --no-install-recommends docker-cli
fi

echo "==> Installing containerlab ..."
bash -c "$(curl -sL https://get.containerlab.dev)"

# Add the calling user to required groups
if [ -n "${SUDO_USER:-}" ]; then
    usermod -aG docker "$SUDO_USER"
    echo "==> Added $SUDO_USER to the docker group"

    # containerlab requires membership in clab_admins (created by containerlab install)
    if getent group clab_admins &>/dev/null; then
        usermod -aG clab_admins "$SUDO_USER"
        echo "==> Added $SUDO_USER to the clab_admins group"
    fi
fi

echo ""
echo "==> Verifying installation ..."
check_prerequisites

echo ""
echo "Done! All dependencies installed."
