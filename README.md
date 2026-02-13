
## Prerequisites

- [containerlab](https://containerlab.dev/install/) (v0.56.0 or later)
- Docker
- KVM support (`/dev/kvm` must exist)

## Quick Start

### 1. Build the SONiC container image

Download `sonic-vs.img.gz` from [sonic.software](https://sonic.software/).

Then run the build script:

```bash
./sonic-build-container-from-qcow2.sh /path/to/sonic-vs.img.gz 202405
```

This clones vrnetlab, wraps the QCOW2 image in a Docker container with
QEMU, and produces `vrnetlab/sonic_sonic-vs:202405`.

### 2. Deploy the lab

```bash
cd lab
containerlab deploy
```

The SONiC VM takes ~60 seconds to boot. Servers start immediately.

### 3. Test connectivity

```bash
docker exec clab-sonic-lab-server1 ping -c 3 192.168.2.2
```

## Project Structure

```
.
├── README.md
├── sonic-build-container-from-qcow2.sh   # Builds the vrnetlab Docker image
└── lab/
    ├── sonic-lab.clab.yml                 # Containerlab topology
    └── config_db.json                     # SONiC startup configuration
```