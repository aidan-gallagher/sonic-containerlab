# sonic-containerlab

SONiC network labs built on [containerlab](https://containerlab.dev), using
vrnetlab to run SONiC virtual switches (QEMU inside Docker) alongside Linux
server containers. Each lab includes pytest-based validation tests.

## Prerequisites

Install all dependencies:

```bash
sudo ./scripts/install-dependencies.sh
```

Or manually ensure you have:
- [containerlab](https://containerlab.dev/install/) (v0.56.0+)
- Docker with KVM support (`/dev/kvm` must exist)
- Python 3 with `pytest` and `paramiko`
- `yq` (YAML processor)

## Quick Start

1. Download `sonic-vs.img.gz` from [sonic.software](https://sonic.software/).

2. Run the full lifecycle (build, deploy, test, cleanup):

```bash
./scripts/runlab.sh --lab simple-lab --image /path/to/sonic-vs.img.gz
```

If the Docker image is already built, skip the build step:

```bash
./scripts/runlab.sh --lab simple-lab
```

To leave the lab running after tests (for debugging or manual inspection):

```bash
./scripts/runlab.sh --lab simple-lab --no-cleanup
```

See all options with `./scripts/runlab.sh --help`.

## Manual Usage

The steps below show what `runlab.sh` does under the hood. These are useful
when developing tests or debugging a lab interactively.

### Build the Docker image

```bash
./scripts/sonic-build-container-from-qcow2.sh /path/to/sonic-vs.img.gz
```

Cloudflare WARP must be disconnected first (`warp-cli disconnect`).

### Deploy a lab

```bash
cd simple-lab
containerlab deploy
```

The SONiC VM takes ~60 seconds to boot. Servers start immediately.

### Inspect the lab

```bash
containerlab inspect     # container summary
containerlab graph       # topology diagram
```

### Access nodes

```bash
# Linux servers
docker exec -it clab-simple-lab-server1 bash
docker exec -it clab-simple-lab-server2 bash

# SONiC switch (use -4 to avoid WARP IPv6 issues)
ssh -4 admin@clab-simple-lab-sonic
```

Node names follow the pattern `clab-<lab-name>-<node-name>`.

### Run tests

```bash
cd simple-lab
pytest -v                 # all tests
pytest -v -k "TestHealth" # one test class
pytest -v -k "test_ethernet0_up"  # one test
```

### Destroy the lab

```bash
cd simple-lab
containerlab destroy
```

## Project Structure

```
.
├── scripts/
│   ├── install-dependencies.sh            # Installs all apt dependencies
│   ├── runlab.sh                          # Generic lifecycle: [build →] deploy → wait → test → cleanup
│   └── sonic-build-container-from-qcow2.sh  # Builds vrnetlab Docker image from SONiC qcow2
└── simple-lab/
    ├── simple-lab.clab.yml                # Containerlab topology
    └── simple_test.py                     # Automated validation tests
```

## Known Issues

### QEMU in Docker

This project uses the SONiC virtual machine image (`sonic-vs.img.gz`) running
under QEMU inside a Docker container (via
[vrnetlab](https://github.com/srl-labs/vrnetlab)), rather than the SONiC Docker
image (`docker-sonic-vs.gz`). The VM image is closer to a real SONiC deployment:
inside the VM, each SONiC service (bgp, swss, syncd, etc.) runs in its own
Docker container, just like on physical hardware.

### Cloudflare WARP and IPv6

If Cloudflare WARP is running, SSH to SONiC nodes will be slow (~45s) because
WARP intercepts IPv6 GUA traffic from the containerlab subnet
(`3fff:172:20:20::/64`). SSH tries IPv6 first, times out, then falls back to
IPv4.

**Workaround**: Force IPv4 with `-4`:

```bash
ssh -4 admin@clab-simple-lab-sonic
```

WARP must also be disconnected before building Docker images
(`warp-cli disconnect`).

## Future Work

- **Custom SONiC configuration** -- the simple-lab currently uses SONiC's
  default interface IPs (`10.0.0.0/31`, `10.0.0.2/31`) to avoid needing any
  switch configuration. Future labs with custom IP schemes or non-default
  settings will need a way to configure the SONiC VM. There are two approaches,
  each with tradeoffs:

  1. **`startup-config` (config_db.json)** -- containerlab's native mechanism.
     A full `config_db.json` is injected into the VM at boot via vrnetlab's
     `/backup.sh restore`. The problem: `config_db.json` is tightly coupled to
     the SONiC image version. It contains a `VERSIONS.DATABASE.VERSION` field
     and schema that must match the image exactly, or the restore fails and the
     VM goes unhealthy. Switching images requires a manual regeneration
     procedure (boot with defaults, dump config, apply customizations). This
     version coupling previously caused CI failures.

  2. **Post-boot SSH commands** -- after the VM is healthy, SSH in and run
     SONiC `config` CLI commands (e.g., `sudo config interface ip add ...`).
     This is version-independent and simple for small changes, but cannot be
     done via the `.clab.yml` `exec` block. For `sonic-vm` nodes, `exec` runs
     on the outer vrnetlab container (the QEMU wrapper), not inside the SONiC
     VM. Reaching the VM requires SSH, and the VM takes ~60s to boot, so the
     commands must run after the health-wait step in `runlab.sh`, not in the
     topology file.

- **Tier 2/3 colo lab** -- eBGP topology with an edge router + 2 SONiC ToRs
  + servers, matching Cloudflare's standalone colo design.
- **GitLab CI pipeline** -- run `./scripts/runlab.sh --lab simple-lab --image <path>`
  in CI to validate on every push.
