#!/usr/bin/env bash
#
# Generic lab lifecycle script.
#
# Deploys a containerlab topology, waits for the SONiC VM to become
# healthy (if one exists), runs pytest validation tests, and cleans up.
# Optionally builds the Docker image first if an image path is provided.
#
# Usage: ./runlab.sh --lab <lab-dir> [--image <path>] [--no-cleanup]
#
set -euo pipefail

# =============================================================================
# USAGE
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") --lab <lab-dir> [--image <path>] [--no-cleanup]

Run the full lab lifecycle: deploy, wait for health, test, and clean up.

Required:
  --lab <dir>       Path to a lab directory containing a .clab.yml topology

Optional:
  --image <path>    Path to SONiC VS image (.img.gz) to build before deploying
                    If omitted, assumes the Docker image already exists
  --no-cleanup      Leave the lab running after tests complete
  -h, --help        Show this help message

Examples:
  $(basename "$0") --lab simple-lab
  $(basename "$0") --lab simple-lab --image /path/to/sonic-vs.img.gz
  $(basename "$0") --lab simple-lab --no-cleanup
EOF
    exit "${1:-0}"
}

# =============================================================================
# PARSE ARGUMENTS
# =============================================================================

LAB_DIR=""
IMAGE_FILE=""
DO_CLEANUP=true

[ $# -eq 0 ] && usage 0

while [ $# -gt 0 ]; do
    case "$1" in
        --lab)
            [ $# -lt 2 ] && { echo "Error: --lab requires a directory argument"; usage 1; }
            LAB_DIR="$2"
            shift 2
            ;;
        --image)
            [ $# -lt 2 ] && { echo "Error: --image requires a file path argument"; usage 1; }
            IMAGE_FILE="$2"
            shift 2
            ;;
        --no-cleanup)
            DO_CLEANUP=false
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            echo "Error: unknown option: $1"
            echo ""
            usage 1
            ;;
    esac
done

# =============================================================================
# VALIDATE ARGUMENTS
# =============================================================================

if [ -z "$LAB_DIR" ]; then
    echo "Error: --lab is required"
    echo ""
    usage 1
fi

LAB_DIR="$(realpath "$LAB_DIR")"
if [ ! -d "$LAB_DIR" ]; then
    echo "Error: lab directory not found: $LAB_DIR"
    exit 1
fi

if [ -n "$IMAGE_FILE" ]; then
    IMAGE_FILE="$(realpath "$IMAGE_FILE")"
    if [ ! -f "$IMAGE_FILE" ]; then
        echo "Error: image file not found: $IMAGE_FILE"
        exit 1
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAIT_TIMEOUT=3600  # 1 hour

"$SCRIPT_DIR/install-dependencies.sh" --check

# =============================================================================
# DISCOVER: find topology file and SONiC node
# =============================================================================

# Find the single .clab.yml in the lab directory
TOPO_FILES=("$LAB_DIR"/*.clab.yml)
if [ ${#TOPO_FILES[@]} -eq 0 ] || [ ! -f "${TOPO_FILES[0]}" ]; then
    echo "Error: no .clab.yml file found in $LAB_DIR"
    exit 1
fi
if [ ${#TOPO_FILES[@]} -gt 1 ]; then
    echo "Error: multiple .clab.yml files found in $LAB_DIR"
    exit 1
fi
TOPO_FILE="${TOPO_FILES[0]}"

# Parse the lab name from the topology
LAB_NAME="$(yq -r '.name' "$TOPO_FILE")"
if [ -z "$LAB_NAME" ] || [ "$LAB_NAME" = "null" ]; then
    echo "Error: could not parse lab name from $TOPO_FILE"
    exit 1
fi

# Find a sonic-vm node (if any) for the health-wait step
SONIC_NODE="$(yq -r '.topology.nodes | to_entries[] | select(.value.kind == "sonic-vm") | .key' "$TOPO_FILE")"
if [ -n "$SONIC_NODE" ]; then
    SONIC_CONTAINER="clab-${LAB_NAME}-${SONIC_NODE}"
    echo "==> Lab: ${LAB_NAME} (topology: $(basename "$TOPO_FILE"))"
    echo "    SONiC VM node: ${SONIC_NODE} (container: ${SONIC_CONTAINER})"
else
    echo "==> Lab: ${LAB_NAME} (topology: $(basename "$TOPO_FILE"))"
    echo "    No sonic-vm node found, will skip health-wait step"
fi

# =============================================================================
# CLEANUP (runs on exit unless --no-cleanup was passed)
# =============================================================================

cleanup() {
    if [ "$DO_CLEANUP" = true ]; then
        echo ""
        echo "==> Cleaning up ..."
        cd "$LAB_DIR"
        containerlab destroy -t "$TOPO_FILE" 2>/dev/null || true
    else
        echo ""
        echo "==> Skipping cleanup (--no-cleanup). Destroy manually with:"
        echo "    cd $LAB_DIR && containerlab destroy"
    fi
}
trap cleanup EXIT

# =============================================================================
# 0. PRE-CLEAN: destroy any existing lab
# =============================================================================

echo "==> Destroying any existing lab ..."
cd "$LAB_DIR"
containerlab destroy -t "$TOPO_FILE" 2>/dev/null || true

# =============================================================================
# 1. BUILD: create vrnetlab Docker image (skip if no image path provided)
# =============================================================================

if [ -n "$IMAGE_FILE" ]; then
    echo "==> Building Docker image ..."
    "$SCRIPT_DIR/sonic-build-container-from-qcow2.sh" "$IMAGE_FILE"
else
    echo "==> Skipping image build (no image path provided)"
fi

# =============================================================================
# 2. DEPLOY: start the lab
# =============================================================================

echo "==> Deploying lab ..."
cd "$LAB_DIR"
containerlab deploy -t "$TOPO_FILE"

# =============================================================================
# 3. WAIT: poll until SONiC VM is healthy (skip if no sonic-vm node)
# =============================================================================

if [ -n "$SONIC_NODE" ]; then
    echo "==> Waiting for SONiC VM to become healthy (timeout: ${WAIT_TIMEOUT}s) ..."
    SECONDS=0
    while true; do
        STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$SONIC_CONTAINER" 2>/dev/null || echo "unknown")
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
else
    echo "==> Skipping health-wait (no sonic-vm node)"
fi

# =============================================================================
# 4. TEST: run validation
# =============================================================================

echo "==> Running tests ..."
cd "$LAB_DIR"
pytest -v

echo ""
echo "Done! All tests passed."
