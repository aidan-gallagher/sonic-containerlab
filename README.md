
## Prerequisites

- [containerlab](https://containerlab.dev/install/) (v0.56.0 or later)
- Docker
- KVM support (`/dev/kvm` must exist)

## Usage
### Setup

1. Download `sonic-vs.img.gz` from [sonic.software](https://sonic.software/).

2. Create docker image from VS qcow image.

```bash
./sonic-build-container-from-qcow2.sh /path/to/sonic-vs.img.gz 202405
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




## Project Structure

```
.
├── README.md
├── sonic-build-container-from-qcow2.sh   # Builds the vrnetlab Docker image
└── simple-lab/
    ├── simple-lab.clab.yml                # Containerlab topology
    └── config_db.json                     # SONiC startup configuration
```

## Issues

### Building Docker container with warp on
warp must be turned off before running `sonic-build-container-from-qcow2.sh`.


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
