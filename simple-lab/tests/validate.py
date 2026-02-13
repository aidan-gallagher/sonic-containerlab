#!/usr/bin/env python3
"""
Simple-lab validation tests.

Runs health checks and network tests against a deployed simple-lab topology.

Usage:
    cd simple-lab
    containerlab deploy          # deploy first
    pytest tests/validate.py -v  # run tests
"""

import json
import socket
import subprocess

import paramiko
import pytest


# =============================================================================
# CONFIG
# =============================================================================

SONIC_HOST = "clab-simple-lab-sonic"
SONIC_USER = "admin"
SONIC_PASSWORD = "admin"

SERVER1 = "clab-simple-lab-server1"
SERVER2 = "clab-simple-lab-server2"


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
# FIXTURES
# =============================================================================


@pytest.fixture(scope="session")
def sonic():
    """Single SSH connection to the SONiC switch, reused across all tests."""
    conn = SonicSSH(SONIC_HOST, SONIC_USER, SONIC_PASSWORD)
    yield conn
    conn.close()


# =============================================================================
# LAYER 1: DEVICE HEALTH
# =============================================================================


class TestHealth:
    """Is the SONiC device healthy?"""

    def test_show_version(self, sonic):
        """SONiC image is installed and reporting a version."""
        out = sonic.run("show version")
        assert "SONiC Software Version" in out

    def test_required_containers_running(self, sonic):
        """All critical SONiC containers are running."""
        out = sonic.run("docker ps --format '{{.Names}}'")
        running = set(out.split())
        required = {"bgp", "swss", "syncd", "teamd", "database"}
        missing = required - running
        assert not missing, f"Containers not running: {missing}"

    def test_no_crashed_containers(self, sonic):
        """No containers have exited with a non-zero exit code."""
        out = sonic.run(
            "docker ps -a --filter 'status=exited' --format '{{.Names}} {{.Status}}'"
        )
        crashed = [
            line for line in out.splitlines() if line and "Exited (0)" not in line
        ]
        assert not crashed, f"Crashed containers: {crashed}"

    def test_redis_ping(self, sonic):
        """Redis is responding."""
        out = sonic.run("redis-cli PING")
        assert out == "PONG"

    def test_config_db_populated(self, sonic):
        """CONFIG_DB has a reasonable number of keys."""
        out = sonic.run("redis-cli -n 4 DBSIZE")
        count = int(out.split()[-1])
        assert count > 100, f"CONFIG_DB has only {count} keys"

    def test_frr_daemons(self, sonic):
        """FRR routing daemons (zebra, bgpd, staticd) are running."""
        out = sonic.run("docker exec bgp vtysh -c 'show daemons' 2>/dev/null")
        for daemon in ["zebra", "bgpd", "staticd"]:
            assert daemon in out, f"{daemon} not running"

    def test_no_core_dumps(self, sonic):
        """No core dumps exist on the device."""
        out = sonic.run("find /var/core -type f 2>/dev/null | wc -l")
        assert out == "0", f"Found {out} core dump(s) in /var/core"


# =============================================================================
# LAYER 2: NETWORK STATE
# =============================================================================


class TestNetwork:
    """Is the network working as expected?"""

    def test_ethernet0_up(self, sonic):
        """Ethernet0 is operationally up."""
        out = sonic.run("show interfaces status Ethernet0")
        assert "up" in out.lower(), f"Ethernet0 not up:\n{out}"

    def test_ethernet4_up(self, sonic):
        """Ethernet4 is operationally up."""
        out = sonic.run("show interfaces status Ethernet4")
        assert "up" in out.lower(), f"Ethernet4 not up:\n{out}"

    def test_ethernet0_ip(self, sonic):
        """Ethernet0 has the expected IP address (192.168.1.1/24)."""
        out = sonic.run("show ip interface")
        assert "192.168.1.1/24" in out, f"Ethernet0 missing IP 192.168.1.1/24:\n{out}"

    def test_ethernet4_ip(self, sonic):
        """Ethernet4 has the expected IP address (192.168.2.1/24)."""
        out = sonic.run("show ip interface")
        assert "192.168.2.1/24" in out, f"Ethernet4 missing IP 192.168.2.1/24:\n{out}"

    def test_server1_pings_gateway(self):
        """server1 can reach its gateway (192.168.1.1)."""
        out = docker_exec(SERVER1, "ping -c 3 -W 2 192.168.1.1")
        assert "0% packet loss" in out

    def test_server2_pings_gateway(self):
        """server2 can reach its gateway (192.168.2.1)."""
        out = docker_exec(SERVER2, "ping -c 3 -W 2 192.168.2.1")
        assert "0% packet loss" in out

    def test_server1_reaches_server2(self):
        """server1 can ping server2 (end-to-end through SONiC)."""
        out = docker_exec(SERVER1, "ping -c 3 -W 2 192.168.2.2")
        assert "0% packet loss" in out

    def test_server2_reaches_server1(self):
        """server2 can ping server1 (end-to-end through SONiC)."""
        out = docker_exec(SERVER2, "ping -c 3 -W 2 192.168.1.2")
        assert "0% packet loss" in out
