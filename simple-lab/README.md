# simple-lab

One SONiC virtual switch routing between two Linux servers. A minimal
topology for validating SONiC health and basic L3 forwarding.

## Topology

```
┌───────────┐  eth1 ◄─► eth1  ┌──────────┐  eth2 ◄─► eth1  ┌───────────┐
│  server1  ├─────────────────┤  sonic   ├─────────────────┤  server2  │
│ .1.2/24   │ 192.168.1.0/24  │ SONiC VM │ 192.168.2.0/24  │ .2.2/24   │
└───────────┘                 └──────────┘                 └───────────┘
```

- **sonic** -- SONiC VM: Ethernet0 (192.168.1.1/24), Ethernet4 (192.168.2.1/24)
- **server1** -- Linux: eth1 (192.168.1.2/24), default route via 192.168.1.1
- **server2** -- Linux: eth1 (192.168.2.2/24), default route via 192.168.2.1

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
