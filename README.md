
## Prerequisites

- [containerlab](https://containerlab.dev/install/) (v0.56.0 or later)
- Docker
- KVM support (`/dev/kvm` must exist)

## Usage
### Setup

1. Download `sonic-vs.img.gz` from [sonic.software](https://sonic.software/).

2. Create docker image from VS qcow image.

```bash
./scripts/sonic-build-container-from-qcow2.sh /path/to/sonic-vs.img.gz
```

3. Deploy the simple lab
```
cd simple-lab
containerlab deploy
```

The SONiC VM takes ~60 seconds to boot. Servers start immediately.

### View
Quicky summary of containers
```
containerlab inspect
```

See the topology
```
containerlab graph
```

### Access
Access Linux server: 
```
docker exec -it clab-simple-lab-server1 bash
or
docker exec -it clab-simple-lab-server2 bash
```
Access SONiC switch
```
ssh -4 admin@clab-simple-lab-sonic
```




### Validate

Run tests against the deployed lab (requires `pytest` and `paramiko`):
```
cd simple-lab
pytest simple_test.py -v
```

This runs device health checks (containers, FRR daemons, Redis) and
network tests (interfaces up, correct IPs, end-to-end ping).


## Project Structure

```
.
├── README.md
├── scripts/
│   ├── runlab.sh                          # Generic lifecycle: [build →] deploy → wait → test → cleanup
│   └── sonic-build-container-from-qcow2.sh  # Builds the vrnetlab Docker image
└── simple-lab/
    ├── simple-lab.clab.yml                # Containerlab topology
    ├── config_db.json                     # SONiC startup configuration
    └── simple_test.py                     # Automated validation tests
```

## Issues

### QEMU in docker
I use the SONiC virtual machine image (sonic-vs.img.gz) running under QEMU inside a Docker container (via vrnetlab (https://github.com/srl-labs/vrnetlab)), rather than the SONiC Docker image (docker-sonic-vs.gz). The VM image is closer to a real SONiC deployment: inside the VM, each SONiC service (bgp, swss, syncd, etc.) runs in its own Docker container, just like on physical hardware. The Docker image, by contrast, runs everything under a single supervisord process.

### Building Docker container with warp on
warp must be turned off before running `scripts/sonic-build-container-from-qcow2.sh`.


### Cloudflare WARP and IPv6

If Cloudflare WARP is running, SSH to the SONiC VM will take ~45 seconds
to connect:

```bash
# This will be slow (~45s)
ssh -o PubkeyAuthentication=no admin@clab-simple-lab-sonic
```

**Root cause**: Containerlab assigns each node an IPv6 GUA (Global Unicast
Address) from the `3fff:172:20:20::/64` subnet. WARP's routing policy
intercepts all IPv6 GUA traffic and tunnels it through the
`CloudflareWARP` interface, where it can't reach local Docker containers.
SSH tries IPv6 first, waits for the TCP timeout (~45s), then falls back
to IPv4.

You can verify this with:

```bash
ip -6 route get 3fff:172:20:20::3
# Shows: dev CloudflareWARP table 65743 (should be dev br-xxxx)
```

**Workaround**: Force IPv4 with the `-4` flag:

```bash
ssh -4 -o PubkeyAuthentication=no admin@clab-simple-lab-sonic
```

IPv4 is unaffected because `172.20.20.0/24` is RFC 1918 private space,
which WARP excludes from tunneling.

### config_db.json must match the SONiC image

`config_db.json` is a near-complete dump of the SONiC default configuration,
with only two IP changes (Ethernet0 and Ethernet4) and the dynamic `mac`
field removed. When containerlab applies this config via `config replace`,
it diffs it against the running defaults. If the defaults differ (because
you're using a different SONiC image version), the diff becomes huge and
`config replace` fails verification (some patches can't be applied cleanly),
causing the VM healthcheck to fail.

If you change SONiC image, recapture `config_db.json`:

```bash
# 1. Temporarily comment out startup-config in simple-lab.clab.yml
# 2. Deploy and wait for healthy
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
# 5. Restore startup-config in simple-lab.clab.yml and redeploy
```

## Future Work

- **Automate config_db.json regeneration** -- `runlab.sh` could detect a
  config mismatch (e.g. by booting once without startup-config, dumping the
  defaults, applying the IP changes, and only then redeploying with the
  config). This would remove the manual recapture step when switching images.
- **Tier 2/3 colo lab** -- eBGP topology with an edge router + 2 SONiC ToRs
  + servers, matching Cloudflare's standalone colo design.
- **GitLab CI pipeline** -- run `./scripts/runlab.sh --lab simple-lab --image <path>` in CI to validate on every push.
