#!/usr/bin/env bash
#
# Generic lab lifecycle script.
#
# Deploys a containerlab topology, waits for the SONiC VM to become
# healthy (if one exists), runs pytest validation tests, and cleans up.
# Optionally builds the Docker image first if an image path is provided.
#
# When --lab is omitted, discovers and runs all labs under the labs/ directory.
#
# Usage: ./runlab.sh [--lab <lab-dir>] [--image <path>] [--no-cleanup]
#
set -euo pipefail

# =============================================================================
# USAGE
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [--lab <lab-dir>] [--image <path>] [--no-cleanup]

Run the full lab lifecycle: deploy, wait for health, test, and clean up.

Optional:
  --lab <dir>       Path to a lab directory containing a .clab.yml topology
                    If omitted, runs all labs under the labs/ directory
  --image <path>    Path to SONiC VS image (.img.gz) to build before deploying
                    If omitted, assumes the Docker image already exists
  --no-cleanup      Leave the lab running after tests complete
  -h, --help        Show this help message

Examples:
  $(basename "$0")                                                    # run all labs
  $(basename "$0") --lab labs/simple-lab
  $(basename "$0") --lab labs/simple-lab --image /path/to/sonic-vs.img.gz
  $(basename "$0") --lab labs/simple-lab --no-cleanup
EOF
    exit "${1:-0}"
}

# =============================================================================
# PARSE ARGUMENTS
# =============================================================================

LAB_ARG=""
IMAGE_FILE=""
DO_CLEANUP=true

while [ $# -gt 0 ]; do
    case "$1" in
        --lab)
            [ $# -lt 2 ] && { echo "Error: --lab requires a directory argument"; usage 1; }
            LAB_ARG="$2"
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
# RESOLVE LAB DIRECTORIES
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WAIT_TIMEOUT=3600  # 1 hour

if [ -n "$LAB_ARG" ]; then
    LAB_ARG="$(realpath "$LAB_ARG")"
    if [ ! -d "$LAB_ARG" ]; then
        echo "Error: lab directory not found: $LAB_ARG"
        exit 1
    fi
    LAB_DIRS=("$LAB_ARG")
else
    LAB_DIRS=()
    for d in "$REPO_ROOT"/labs/*/; do
        [ -d "$d" ] && LAB_DIRS+=("$(realpath "$d")")
    done
    if [ ${#LAB_DIRS[@]} -eq 0 ]; then
        echo "Error: no lab directories found in $REPO_ROOT/labs/"
        exit 1
    fi
    echo "==> Discovered ${#LAB_DIRS[@]} lab(s): ${LAB_DIRS[*]}"
fi

if [ -n "$IMAGE_FILE" ]; then
    IMAGE_FILE="$(realpath "$IMAGE_FILE")"
    if [ ! -f "$IMAGE_FILE" ]; then
        echo "Error: image file not found: $IMAGE_FILE"
        exit 1
    fi
fi

"$SCRIPT_DIR/install-dependencies.sh" --check

# =============================================================================
# BUILD: create vrnetlab Docker image (skip if no image path provided)
# =============================================================================

if [ -n "$IMAGE_FILE" ]; then
    echo "==> Building Docker image ..."
    "$SCRIPT_DIR/sonic-build-container-from-qcow2.sh" "$IMAGE_FILE"
else
    echo "==> Skipping image build (no image path provided)"
fi

# =============================================================================
# RUN EACH LAB: discover, deploy, wait, test, cleanup
# =============================================================================

for LAB_DIR in "${LAB_DIRS[@]}"; do

    # =========================================================================
    # DISCOVER: find topology file and SONiC node
    # =========================================================================

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

    # Find all sonic-vm nodes (if any) for the health-wait step
    mapfile -t SONIC_NODES < <(yq -r '.topology.nodes | to_entries[] | select(.value.kind == "sonic-vm") | .key' "$TOPO_FILE")

    echo "==> Lab: ${LAB_NAME} (topology: $(basename "$TOPO_FILE"))"
    if [ ${#SONIC_NODES[@]} -gt 0 ]; then
        SONIC_CONTAINERS=()
        for node in "${SONIC_NODES[@]}"; do
            container="clab-${LAB_NAME}-${node}"
            SONIC_CONTAINERS+=("$container")
            echo "    SONiC VM node: ${node} (container: ${container})"
        done
    else
        echo "    No sonic-vm nodes found, will skip health-wait step"
    fi

    # =========================================================================
    # CLEANUP (runs on exit unless --no-cleanup was passed)
    # =========================================================================

    cleanup() {
        if [ "$DO_CLEANUP" = true ]; then
            echo ""
            echo "==> Cleaning up ${LAB_NAME} ..."
            cd "$LAB_DIR"
            containerlab destroy -t "$TOPO_FILE" 2>/dev/null || true
        else
            echo ""
            echo "==> Skipping cleanup (--no-cleanup). Destroy manually with:"
            echo "    cd $LAB_DIR && containerlab destroy"
        fi
    }
    trap cleanup EXIT

    # =========================================================================
    # PRE-CLEAN: destroy any existing lab
    # =========================================================================

    echo "==> Destroying any existing ${LAB_NAME} lab ..."
    cd "$LAB_DIR"
    containerlab destroy -t "$TOPO_FILE" 2>/dev/null || true

    # =========================================================================
    # DEPLOY: start the lab
    # =========================================================================

    echo "==> Deploying ${LAB_NAME} ..."
    cd "$LAB_DIR"
    containerlab deploy -t "$TOPO_FILE"

    # =========================================================================
    # WAIT: poll until SONiC VM is healthy (skip if no sonic-vm node)
    # =========================================================================

    if [ ${#SONIC_NODES[@]} -gt 0 ]; then
        echo "==> Waiting for SONiC VMs to become healthy (timeout: ${WAIT_TIMEOUT}s) ..."
        SECONDS=0

        # Track which containers are still pending
        declare -A PENDING
        for container in "${SONIC_CONTAINERS[@]}"; do
            PENDING["$container"]=1
        done

        while [ ${#PENDING[@]} -gt 0 ]; do
            for container in "${!PENDING[@]}"; do
                STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
                if [ "$STATUS" = "healthy" ]; then
                    echo "    ${container} is healthy (took ${SECONDS}s)"
                    unset "PENDING[$container]"
                fi
            done
            if [ ${#PENDING[@]} -eq 0 ]; then
                break
            fi
            if [ "$SECONDS" -ge "$WAIT_TIMEOUT" ]; then
                echo "    Error: timed out after ${WAIT_TIMEOUT}s"
                echo "    Still waiting on: ${!PENDING[*]}"
                exit 1
            fi
            sleep 10
        done

        # Allow extra time for SONiC services (FRR, syncd, ASIC programming)
        # to fully converge after the container health check passes.
        echo "    Waiting 30s for services to converge ..."
        sleep 30
    else
        echo "==> Skipping health-wait (no sonic-vm nodes)"
    fi

    # =========================================================================
    # TEST: run validation
    # =========================================================================

    echo "==> Running tests for ${LAB_NAME} ..."
    cd "$LAB_DIR"
    pytest -v

    echo ""
    echo "==> ${LAB_NAME}: all tests passed."

    # Clean up before moving to the next lab
    cleanup
    trap - EXIT

done

echo ""
echo "Done! All tests in all labs passed."
