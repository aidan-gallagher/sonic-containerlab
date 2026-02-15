#!/usr/bin/env python3
"""
BGP-lab validation tests.

Tests eBGP peering between two SONiC switches and end-to-end traffic
forwarding via BGP-learned routes.

Topology (after post-boot configuration):

    server1 <-> sonic1 <-> sonic2 <-> server2

The switches boot with default IPs. A session-scoped fixture SSHes in
and reconfigures interfaces + eBGP before any tests run.

Usage:
    cd labs/bgp-lab
    containerlab deploy
    # wait for both VMs to become healthy
    pytest bgp_test.py -v
"""

import json
import socket
import subprocess
import time

import paramiko
import pytest


# =============================================================================
# CONFIG
# =============================================================================

SONIC1_HOST = "clab-bgp-lab-sonic1"
SONIC2_HOST = "clab-bgp-lab-sonic2"
SONIC_USER = "admin"
SONIC_PASSWORD = "admin"

SERVER1 = "clab-bgp-lab-server1"
SERVER2 = "clab-bgp-lab-server2"

# sonic1: Ethernet0 (10.10.0.0/31) -> server1, Ethernet4 (10.0.0.0/31) -> sonic2
# sonic2: Ethernet0 (10.0.0.1/31) -> sonic1, Ethernet4 (10.20.0.0/31) -> server2
SONIC1_ETH0_IP = "10.10.0.0/31"
SONIC1_ETH4_IP = "10.0.0.0/31"
SONIC2_ETH0_IP = "10.0.0.1/31"
SONIC2_ETH4_IP = "10.20.0.0/31"

SONIC1_ASN = 65001
SONIC2_ASN = 65002

SERVER1_IP = "10.10.0.1"
SERVER2_IP = "10.20.0.1"


# =============================================================================
# TRANSPORT
# =============================================================================


class SonicSSH:
    """Persistent SSH connection to a SONiC device.

    Forces IPv4 to avoid the Cloudflare WARP IPv6 timeout issue.
    Disables key-based auth to avoid exhausting auth attempts with
    too many local SSH keys.
    """

    def __init__(self, host, username, password, port=22):
        # Resolve hostname to IPv4 explicitly
        ipv4_addr = str(socket.getaddrinfo(host, port, socket.AF_INET)[0][4][0])

        # Create an IPv4 TCP socket and connect
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10)
        sock.connect((ipv4_addr, port))

        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.client.connect(
            ipv4_addr,
            port=port,
            username=username,
            password=password,
            look_for_keys=False,
            allow_agent=False,
            sock=sock,
        )

    def run(self, cmd, timeout=30):
        """Run a command, return stdout as string."""
        _, stdout, _ = self.client.exec_command(cmd, timeout=timeout)
        return stdout.read().decode().strip()

    def run_json(self, cmd, timeout=30):
        """Run a command that returns JSON, parse and return it."""
        return json.loads(self.run(cmd, timeout))

    def close(self):
        self.client.close()


def docker_exec(container, cmd):
    """Run a command inside a containerlab Linux container."""
    result = subprocess.run(
        ["docker", "exec", container] + cmd.split(),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, f"docker exec {container} failed: {result.stderr}"
    return result.stdout.strip()


# =============================================================================
# POST-BOOT CONFIGURATION
# =============================================================================


def remove_default_config(ssh):
    """Remove the default SONiC interface IPs and BGP config."""
    # Remove default IPs on Ethernet0 and Ethernet4
    ssh.run("sudo config interface ip remove Ethernet0 10.0.0.0/31")
    ssh.run("sudo config interface ip remove Ethernet4 10.0.0.2/31")

    # Find and remove the default BGP instance from FRR.
    # SONiC VS ships with 'router bgp 65100' and 31 pre-configured peers.
    out = ssh.run(
        "docker exec bgp vtysh -c 'show running-config' | grep '^router bgp' || true"
    )
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("router bgp"):
            asn = line.split()[-1]
            ssh.run(
                f"docker exec bgp vtysh -c 'configure terminal' -c 'no router bgp {asn}' -c 'exit'"
            )


def configure_bgp_via_vtysh(ssh, asn, router_id, neighbor_ip, remote_asn, network):
    """Configure eBGP on a SONiC switch via vtysh."""
    commands = [
        "configure terminal",
        f"router bgp {asn}",
        f"bgp router-id {router_id}",
        "no bgp ebgp-requires-policy",
        f"neighbor {neighbor_ip} remote-as {remote_asn}",
        "address-family ipv4 unicast",
        f"network {network}",
        f"neighbor {neighbor_ip} activate",
        "exit-address-family",
        "exit",
        "exit",
    ]
    # Pass each line as a separate -c argument to vtysh
    vtysh_args = " ".join(f"-c '{c}'" for c in commands)
    ssh.run(f"docker exec bgp vtysh {vtysh_args}", timeout=60)


def configure_sonic1(ssh):
    """Configure sonic1: IPs and eBGP toward sonic2."""
    remove_default_config(ssh)

    # Assign new IPs
    ssh.run(f"sudo config interface ip add Ethernet0 {SONIC1_ETH0_IP}")
    ssh.run(f"sudo config interface ip add Ethernet4 {SONIC1_ETH4_IP}")

    # Configure eBGP
    configure_bgp_via_vtysh(
        ssh,
        asn=SONIC1_ASN,
        router_id="10.10.0.0",
        neighbor_ip="10.0.0.1",
        remote_asn=SONIC2_ASN,
        network="10.10.0.0/31",
    )


def configure_sonic2(ssh):
    """Configure sonic2: IPs and eBGP toward sonic1."""
    remove_default_config(ssh)

    # Assign new IPs
    ssh.run(f"sudo config interface ip add Ethernet0 {SONIC2_ETH0_IP}")
    ssh.run(f"sudo config interface ip add Ethernet4 {SONIC2_ETH4_IP}")

    # Configure eBGP
    configure_bgp_via_vtysh(
        ssh,
        asn=SONIC2_ASN,
        router_id="10.20.0.0",
        neighbor_ip="10.0.0.0",
        remote_asn=SONIC1_ASN,
        network="10.20.0.0/31",
    )


def wait_for_bgp(ssh, neighbor_ip, retries=30, interval=2):
    """Poll until a BGP neighbor reaches Established state."""
    for _ in range(retries):
        out = ssh.run("docker exec bgp vtysh -c 'show ip bgp summary json'")
        try:
            bgp = json.loads(out)
            peers = bgp.get("ipv4Unicast", {}).get("peers", {})
            peer = peers.get(neighbor_ip, {})
            if peer.get("state") == "Established":
                return True
        except (json.JSONDecodeError, KeyError):
            pass
        time.sleep(interval)
    return False


# =============================================================================
# FIXTURES
# =============================================================================


@pytest.fixture(scope="session")
def sonic1():
    """SSH connection to sonic1, with post-boot configuration applied."""
    conn = SonicSSH(SONIC1_HOST, SONIC_USER, SONIC_PASSWORD)
    yield conn
    conn.close()


@pytest.fixture(scope="session")
def sonic2():
    """SSH connection to sonic2, with post-boot configuration applied."""
    conn = SonicSSH(SONIC2_HOST, SONIC_USER, SONIC_PASSWORD)
    yield conn
    conn.close()


@pytest.fixture(scope="session", autouse=True)
def configure_lab(sonic1, sonic2):
    """Apply post-boot IP and BGP config to both switches, wait for convergence."""
    configure_sonic1(sonic1)
    configure_sonic2(sonic2)

    # Wait for eBGP sessions to establish
    assert wait_for_bgp(sonic1, "10.0.0.1"), (
        "BGP session sonic1 -> sonic2 did not establish"
    )
    assert wait_for_bgp(sonic2, "10.0.0.0"), (
        "BGP session sonic2 -> sonic1 did not establish"
    )


# =============================================================================
# LAYER 1: DEVICE HEALTH
# =============================================================================


class TestHealth:
    """Are both SONiC devices healthy?"""

    def test_sonic1_version(self, sonic1):
        """sonic1 is reporting a SONiC version."""
        out = sonic1.run("show version")
        assert "SONiC Software Version" in out

    def test_sonic2_version(self, sonic2):
        """sonic2 is reporting a SONiC version."""
        out = sonic2.run("show version")
        assert "SONiC Software Version" in out

    def test_sonic1_containers(self, sonic1):
        """sonic1 has all critical containers running."""
        out = sonic1.run("docker ps --format '{{.Names}}'")
        running = set(out.split())
        required = {"bgp", "swss", "syncd", "teamd", "database"}
        missing = required - running
        assert not missing, f"sonic1 missing containers: {missing}"

    def test_sonic2_containers(self, sonic2):
        """sonic2 has all critical containers running."""
        out = sonic2.run("docker ps --format '{{.Names}}'")
        running = set(out.split())
        required = {"bgp", "swss", "syncd", "teamd", "database"}
        missing = required - running
        assert not missing, f"sonic2 missing containers: {missing}"


# =============================================================================
# LAYER 2: INTERFACE STATE
# =============================================================================


class TestInterfaces:
    """Are the interfaces configured correctly?"""

    def test_sonic1_ethernet0_ip(self, sonic1):
        """sonic1 Ethernet0 has IP 10.10.0.0/31 (server-facing)."""
        out = sonic1.run("show ip interface")
        assert "10.10.0.0/31" in out, f"sonic1 Ethernet0 missing IP:\n{out}"

    def test_sonic1_ethernet4_ip(self, sonic1):
        """sonic1 Ethernet4 has IP 10.0.0.0/31 (inter-switch)."""
        out = sonic1.run("show ip interface")
        assert "10.0.0.0/31" in out, f"sonic1 Ethernet4 missing IP:\n{out}"

    def test_sonic2_ethernet0_ip(self, sonic2):
        """sonic2 Ethernet0 has IP 10.0.0.1/31 (inter-switch)."""
        out = sonic2.run("show ip interface")
        assert "10.0.0.1/31" in out, f"sonic2 Ethernet0 missing IP:\n{out}"

    def test_sonic2_ethernet4_ip(self, sonic2):
        """sonic2 Ethernet4 has IP 10.20.0.0/31 (server-facing)."""
        out = sonic2.run("show ip interface")
        assert "10.20.0.0/31" in out, f"sonic2 Ethernet4 missing IP:\n{out}"


# =============================================================================
# LAYER 3: BGP STATE
# =============================================================================


class TestBGP:
    """Is eBGP working between the two switches?"""

    def test_sonic1_bgp_established(self, sonic1):
        """sonic1 has an Established eBGP session with sonic2."""
        out = sonic1.run("docker exec bgp vtysh -c 'show ip bgp summary json'")
        bgp = json.loads(out)
        peers = bgp.get("ipv4Unicast", {}).get("peers", {})
        peer = peers.get("10.0.0.1", {})
        assert peer.get("state") == "Established", (
            f"sonic1 BGP peer 10.0.0.1 not established: {peer}"
        )

    def test_sonic2_bgp_established(self, sonic2):
        """sonic2 has an Established eBGP session with sonic1."""
        out = sonic2.run("docker exec bgp vtysh -c 'show ip bgp summary json'")
        bgp = json.loads(out)
        peers = bgp.get("ipv4Unicast", {}).get("peers", {})
        peer = peers.get("10.0.0.0", {})
        assert peer.get("state") == "Established", (
            f"sonic2 BGP peer 10.0.0.0 not established: {peer}"
        )

    def test_sonic1_has_remote_route(self, sonic1):
        """sonic1 has a BGP-learned route to server2's subnet (10.20.0.0/31)."""
        out = sonic1.run("docker exec bgp vtysh -c 'show ip bgp 10.20.0.0/31 json'")
        bgp = json.loads(out)
        paths = bgp.get("paths", [])
        assert len(paths) > 0, f"sonic1 has no BGP path to 10.20.0.0/31:\n{out}"

    def test_sonic2_has_remote_route(self, sonic2):
        """sonic2 has a BGP-learned route to server1's subnet (10.10.0.0/31)."""
        out = sonic2.run("docker exec bgp vtysh -c 'show ip bgp 10.10.0.0/31 json'")
        bgp = json.loads(out)
        paths = bgp.get("paths", [])
        assert len(paths) > 0, f"sonic2 has no BGP path to 10.10.0.0/31:\n{out}"


# =============================================================================
# LAYER 4: END-TO-END FORWARDING
# =============================================================================


class TestForwarding:
    """Does traffic follow BGP-learned routes end-to-end?"""

    def test_server1_pings_gateway(self):
        """server1 can reach sonic1 Ethernet0 (10.10.0.0)."""
        out = docker_exec(SERVER1, "ping -c 3 -W 2 10.10.0.0")
        assert "0% packet loss" in out

    def test_server2_pings_gateway(self):
        """server2 can reach sonic2 Ethernet4 (10.20.0.0)."""
        out = docker_exec(SERVER2, "ping -c 3 -W 2 10.20.0.0")
        assert "0% packet loss" in out

    def test_inter_switch_ping(self, sonic1):
        """sonic1 can ping sonic2 across the inter-switch link."""
        out = sonic1.run("ping -c 3 -W 2 10.0.0.1")
        assert "0% packet loss" in out, f"Inter-switch ping failed:\n{out}"

    def test_server1_reaches_server2(self):
        """server1 can ping server2 end-to-end (via BGP-learned route)."""
        out = docker_exec(SERVER1, "ping -c 3 -W 2 10.20.0.1")
        assert "0% packet loss" in out

    def test_server2_reaches_server1(self):
        """server2 can ping server1 end-to-end (via BGP-learned route)."""
        out = docker_exec(SERVER2, "ping -c 3 -W 2 10.10.0.1")
        assert "0% packet loss" in out

    def test_traceroute_shows_path(self):
        """Traceroute from server1 to server2 reaches the destination via sonic1."""
        out = docker_exec(SERVER1, "traceroute -n -m 5 -w 2 10.20.0.1")
        # Hop 1 should be sonic1 (10.10.0.0). Hop 2 may show * (VS kernel
        # doesn't always send TTL-expired ICMP). The destination must appear.
        assert "10.10.0.0" in out, f"sonic1 not in traceroute:\n{out}"
        assert "10.20.0.1" in out, f"Destination not reached in traceroute:\n{out}"
