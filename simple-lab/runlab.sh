#!/usr/bin/env bash
#
# Full lifecycle script for simple-lab.
#
# Builds the Docker image, deploys the lab, waits for the SONiC VM to
# become healthy, runs validation tests, and cleans up.
#
# Usage: ./runlab.sh <path-to-sonic-vs.img.gz>
#
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <path-to-sonic-vs.img.gz>"
    echo ""
    echo "Download the image from https://sonic.software"
    exit 1
fi

IMAGE_FILE="$(realpath "$1")"
if [ ! -f "$IMAGE_FILE" ]; then
    echo "Error: file not found: $1"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE="vrnetlab/sonic_sonic-vs:latest"
SONIC_NODE="clab-simple-lab-sonic"
WAIT_TIMEOUT=300

# =============================================================================
# CLEANUP (runs on exit, always)
# =============================================================================

cleanup() {
    echo ""
    echo "==> Cleaning up ..."
    cd "$SCRIPT_DIR"
    containerlab destroy -t simple-lab.clab.yml 2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
# 0. PRE-CLEAN: destroy any existing lab
# =============================================================================

echo "==> Destroying any existing lab ..."
cd "$SCRIPT_DIR"
containerlab destroy -t simple-lab.clab.yml 2>/dev/null || true

# =============================================================================
# 1. BUILD: create vrnetlab Docker image
# =============================================================================

echo "==> Building Docker image ${IMAGE} ..."
"$REPO_DIR/sonic-build-container-from-qcow2.sh" "$IMAGE_FILE"

# =============================================================================
# 2. DEPLOY: start the lab
# =============================================================================

echo "==> Deploying lab ..."
cd "$SCRIPT_DIR"
containerlab deploy -t simple-lab.clab.yml

# =============================================================================
# 3. WAIT: poll until SONiC VM is healthy
# =============================================================================

echo "==> Waiting for SONiC VM to become healthy (timeout: ${WAIT_TIMEOUT}s) ..."
SECONDS=0
while true; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$SONIC_NODE" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "healthy" ]; then
        echo "    SONiC VM is healthy (took ${SECONDS}s)"
        break
    fi
    if [ "$SECONDS" -ge "$WAIT_TIMEOUT" ]; then
        echo "    Error: timed out after ${WAIT_TIMEOUT}s (status: $STATUS)"
        exit 1
    fi
    sleep 10
done

# =============================================================================
# 4. TEST: run validation
# =============================================================================

echo "==> Running tests ..."
cd "$SCRIPT_DIR"
pytest simple_test.py -v

echo ""
echo "Done! All tests passed."
