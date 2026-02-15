# bgp-lab

Two SONiC virtual switches in an eBGP peering, each with a server behind it.
Tests that BGP sessions establish, routes are learned, and traffic follows
BGP-learned routes end-to-end.

## Topology

```
┌──────────────┐                        ┌──────────────────────┐                        ┌──────────────────────┐                        ┌──────────────┐
│   server1    │    eth1 ◄──► eth1      │       sonic1         │      eth2 ◄──► eth1    │       sonic2         │      eth2 ◄──► eth1    │   server2    │
│              ├────────────────────────┤                      ├────────────────────────┤                      ├────────────────────────┤              │
│  10.10.0.1   │      10.10.0.0/31      │ AS 65001             │       10.0.0.0/31      │ AS 65002             │      10.20.0.0/31      │  10.20.0.1   │
└──────────────┘                        │           10.0.0.0   │              10.0.0.1   │          10.20.0.0   │                        └──────────────┘
                                        └──────────────────────┘                        └──────────────────────┘
```

- **sonic1** -- AS 65001: Ethernet0 (10.10.0.0/31, server-facing), Ethernet4 (10.0.0.0/31, inter-switch)
- **sonic2** -- AS 65002: Ethernet0 (10.0.0.1/31, inter-switch), Ethernet4 (10.20.0.0/31, server-facing)
- **server1** -- Linux: eth1 (10.10.0.1/31), route to 10.20.0.0/31 via 10.10.0.0
- **server2** -- Linux: eth1 (10.20.0.1/31), route to 10.10.0.0/31 via 10.20.0.0

## Post-Boot Configuration

Both switches boot with SONiC's default IPs. A session-scoped pytest fixture
SSHes into each switch and reconfigures interface IPs and eBGP peering before
any tests run. This avoids the `config_db.json` version-coupling problem.

## Tests

Tests in `bgp_test.py` are split into four classes:

**TestHealth** -- device health checks:

- Both switches reporting SONiC version
- Both switches have critical containers running

**TestInterfaces** -- interface state:

- Correct IPs on all four interfaces (two per switch)

**TestBGP** -- eBGP state:

- Both switches have Established eBGP sessions
- sonic1 has a BGP-learned route to server2's subnet (10.20.0.0/31)
- sonic2 has a BGP-learned route to server1's subnet (10.10.0.0/31)

**TestForwarding** -- end-to-end traffic:

- Servers can ping their gateways
- sonic1 can ping sonic2 across the inter-switch link
- server1 can ping server2 end-to-end (via BGP-learned route through both switches)
- server2 can ping server1 end-to-end
- Traceroute from server1 to server2 shows both switch hops
