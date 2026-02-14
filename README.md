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
    ├── config_db.json                     # SONiC startup configuration
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

### config_db.json must match the SONiC image

`config_db.json` is a near-complete dump of the SONiC default configuration.
If you switch to a different SONiC image version, `config_db.json` must be
regenerated. See the procedure below.

<details>
<summary>Regenerate config_db.json</summary>

```bash
# 1. Temporarily comment out startup-config in the .clab.yml
# 2. Deploy and wait for healthy
cd simple-lab
containerlab deploy

# 3. Dump the default config
sshpass -p admin ssh -4 -o StrictHostKeyChecking=no admin@clab-simple-lab-sonic \
  "sonic-cfggen -d --print-data" > config_db.json

# 4. Apply IP changes and remove mac
python3 -c "
import json
with open('config_db.json') as f:
    cfg = json.load(f)
del cfg['INTERFACE']['Ethernet0|10.0.0.0/31']
cfg['INTERFACE']['Ethernet0|192.168.1.1/24'] = {}
del cfg['INTERFACE']['Ethernet4|10.0.0.2/31']
cfg['INTERFACE']['Ethernet4|192.168.2.1/24'] = {}
del cfg['DEVICE_METADATA']['localhost']['mac']
with open('config_db.json', 'w') as f:
    json.dump(cfg, f, indent=4, sort_keys=True)
"

# 5. Restore startup-config in the .clab.yml and redeploy
```

</details>

## Future Work

- **Automate config_db.json regeneration** -- detect config mismatch and
  regenerate automatically during `runlab.sh`.
- **Tier 2/3 colo lab** -- eBGP topology with an edge router + 2 SONiC ToRs
  + servers, matching Cloudflare's standalone colo design.
- **GitLab CI pipeline** -- run `./scripts/runlab.sh --lab simple-lab --image <path>`
  in CI to validate on every push.
