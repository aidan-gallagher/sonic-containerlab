# simple-lab

One SONiC virtual switch routing between two Linux servers. A minimal
topology for validating SONiC health and basic L3 forwarding.

## Topology

```
┌──────────────┐                        ┌──────────────────────┐                        ┌──────────────┐
│   server1    │    eth1 ◄──► eth1      │        sonic         │      eth2 ◄──► eth1    │   server2    │
│              ├────────────────────────┤                      ├────────────────────────┤              │
│  10.0.0.1    │      10.0.0.0/31       │ 10.0.0.0             │       10.0.0.2/31      │  10.0.0.3    │
└──────────────┘                        │            10.0.0.2  │                        └──────────────┘
                                        └──────────────────────┘
```

- **sonic** -- SONiC VM: Ethernet0 (10.0.0.0/31), Ethernet4 (10.0.0.2/31) -- default IPs, no config needed
- **server1** -- Linux: eth1 (10.0.0.1/31), route to 10.0.0.2/31 via 10.0.0.0
- **server2** -- Linux: eth1 (10.0.0.3/31), route to 10.0.0.0/31 via 10.0.0.2

## Tests

Tests in `simple_test.py` are split into two classes:

**TestHealth** -- device health checks:

- SONiC version reported
- Required containers running (bgp, swss, syncd, teamd, database)
- No crashed or restarting containers
- Redis responding, CONFIG_DB/APPL_DB/ASIC_DB populated
- Config parseable by sonic-cfggen, valid JSON on disk
- FRR daemons running (zebra, bgpd, staticd)
- No core dumps, OOM kills, kernel panics, or zombie processes

**TestNetwork** -- network state validation:

- Ethernet0 and Ethernet4 operationally up with correct IPs
- server1 and server2 can ping their gateways
- End-to-end ping between servers through SONiC

**TestMTU** -- frame size forwarding:

- 1400-byte payload passes through (well under default MTU)
- 8000-byte jumbo payload passes through (under 9100 default MTU)
- 9100-byte payload blocked (headers push it over MTU limit)

**TestARP** -- ARP / neighbor resolution:

- Switch has ARP entry for server1 after traffic flows
- Kernel neighbor entries for both servers are REACHABLE or STALE
- server1 gets ARP replies from its gateway (L2 arping)
