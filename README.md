# SONiC Lab

A containerlab topology with 1 SONiC virtual switch and 2 Linux servers connected via L3 routing.

## Topology

```
                   +------------------+
                   |      sonic       |
                   |   (sonic-vs)     |
                   |                  |
                   | Ethernet0  Ethernet4 |
                   +---eth1------eth2-+
                       |          |
                       |          |
                   +---eth1-+ +---eth1-+
                   |server1 | |server2 |
                   | .1.2   | | .2.2   |
                   +--------+ +--------+

    subnet: 192.168.1.0/24    subnet: 192.168.2.0/24
```

| Node    | Interface  | SONiC Port | IP Address      | Subnet           |
|---------|------------|------------|-----------------|------------------|
| sonic   | eth1       | Ethernet0  | 192.168.1.1/24  | 192.168.1.0/24   |
| sonic   | eth2       | Ethernet4  | 192.168.2.1/24  | 192.168.2.0/24   |
| server1 | eth1       | -          | 192.168.1.2/24  | 192.168.1.0/24   |
| server2 | eth1       | -          | 192.168.2.2/24  | 192.168.2.0/24   |

The SONiC switch routes between the two subnets. Each server has a static
route pointing to the SONiC interface on its subnet as the gateway.

## Prerequisites

- [containerlab](https://containerlab.dev/install/) installed
- Docker running
- The `docker-sonic-vs` container image loaded (see next section)

## Acquiring the SONiC Image

The `docker-sonic-vs` image is not available on Docker Hub. You need to
download it from one of two sources.

### Option A: sonic.software (easiest)

Visit [sonic.software](https://sonic.software/) and download the
`docker-sonic-vs.gz` file for your desired branch (e.g. `202511`, `202405`).
This site is an unofficial mirror and may occasionally be down.

### Option B: Azure Pipeline (official)

If sonic.software is unavailable, download from the official Azure pipeline:

1. Go to the [pipelines list](https://sonic-build.azurewebsites.net/ui/sonic/pipelines).
2. Scroll to the bottom where the **vs** platform is listed.
3. Find the row for your desired branch (e.g. **202511**) and click **Build History**.
4. Pick the latest build with a **Succeeded** result and click the **Artifacts** link.
5. Click the single artifact listed in the new window.
6. Scroll down (or Ctrl+F) to find `target/docker-sonic-vs.gz` and click to download.

### Load the image into Docker

Once downloaded, load and tag the image:

```bash
docker load -i docker-sonic-vs.gz
```

Verify the image is available:

```bash
docker images | grep sonic
```

You should see an image named `docker-sonic-vs`. If the tag doesn't match
`latest`, re-tag it:

```bash
docker tag docker-sonic-vs:<existing-tag> docker-sonic-vs:latest
```

## Deploy the Lab

From the `sonic-lab/` directory (containerlab auto-detects the `.clab.yml` file):

```bash
sudo containerlab deploy
```

Containerlab will:
1. Create the containers for `sonic`, `server1`, and `server2`.
2. Wire up the links (`sonic:eth1 <-> server1:eth1`, `sonic:eth2 <-> server2:eth1`).
3. Run the `exec` commands defined in the topology to configure IP addresses
   and routes on all three nodes.

Deployment output will show the management IP addresses assigned to each node.

## Verify Connectivity

### Ping between servers

From server1, ping server2 through the SONiC switch:

```bash
docker exec -it clab-sonic-lab-server1 ping -c 3 192.168.2.2
```

From server2, ping server1:

```bash
docker exec -it clab-sonic-lab-server2 ping -c 3 192.168.1.2
```

### Check SONiC interface status

```bash
docker exec -it clab-sonic-lab-sonic bash
show interfaces status
show ip interfaces
```

### Check SONiC routing table

```bash
docker exec -it clab-sonic-lab-sonic vtysh -c "show ip route"
```

## Accessing Nodes

### SONiC switch

```bash
# Bash shell
docker exec -it clab-sonic-lab-sonic bash

# FRR CLI (vtysh)
docker exec -it clab-sonic-lab-sonic vtysh
```

### Servers

```bash
# server1
docker exec -it clab-sonic-lab-server1 bash

# server2
docker exec -it clab-sonic-lab-server2 bash
```

## Destroy the Lab

```bash
sudo containerlab destroy
```

Add `--cleanup` to also remove the lab directory created by containerlab:

```bash
sudo containerlab destroy --cleanup
```

You can also destroy by lab name from anywhere:

```bash
sudo containerlab destroy -n sonic-lab
```

## Interface Mapping Reference

The `sonic-vs` kind uses the following interface mapping:

| Linux interface | SONiC port |
|-----------------|------------|
| eth0            | Management |
| eth1            | Ethernet0  |
| eth2            | Ethernet4  |
| eth3            | Ethernet8  |
| eth(N)          | Ethernet((N-1)*4) |

`eth0` is always the management interface connected to the containerlab
management network. Data interfaces start at `eth1`.

## Troubleshooting

### SONiC takes a long time to deploy

The topology includes a `sonic-db-cli PING` retry loop that waits for
SONiC's Redis database to become ready before applying interface
configuration. This is necessary because containerlab starts SONiC's
`supervisord` asynchronously — Redis and the config database take 30-90
seconds to come up after deploy. The `containerlab deploy` command will
appear to hang during this time; this is normal.

If the exec commands still fail, shell into the container and run them
manually:

```bash
docker exec -it clab-sonic-lab-sonic bash
# Wait for services to be ready
sonic-db-cli PING
# Bring interfaces up and configure IPs
config interface startup Ethernet0
config interface startup Ethernet4
config interface ip add Ethernet0 192.168.1.1/24
config interface ip add Ethernet4 192.168.2.1/24
```

### Servers can't reach each other

1. Check that interfaces are up on both servers:
   ```bash
   docker exec clab-sonic-lab-server1 ip addr show eth1
   docker exec clab-sonic-lab-server2 ip addr show eth1
   ```

2. Check that routes exist:
   ```bash
   docker exec clab-sonic-lab-server1 ip route
   docker exec clab-sonic-lab-server2 ip route
   ```

3. Check SONiC has both interfaces configured:
   ```bash
   docker exec clab-sonic-lab-sonic show ip interfaces
   ```

4. Verify SONiC can reach both servers:
   ```bash
   docker exec clab-sonic-lab-sonic ping -c 1 192.168.1.2
   docker exec clab-sonic-lab-sonic ping -c 1 192.168.2.2
   ```
