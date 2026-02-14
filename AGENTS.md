# AGENTS.md

Guidelines for AI coding agents working in this repository.

## Project Overview

This is a SONiC network lab built on [containerlab](https://containerlab.dev).
It uses vrnetlab to run a SONiC virtual switch (QEMU inside Docker) alongside
Linux server containers, with pytest-based validation tests.

**Languages**: Bash (scripts), Python (tests), YAML (topology), JSON (config)

## Project Structure

```
scripts/
├── install-dependencies.sh            # Installs all apt dependencies
├── runlab.sh                          # Generic lifecycle: [build →] deploy → wait → test → cleanup
└── sonic-build-container-from-qcow2.sh  # Builds vrnetlab Docker image from SONiC qcow2
simple-lab/
├── simple-lab.clab.yml                # Containerlab topology definition
└── simple_test.py                     # Pytest validation suite
```

## Build / Deploy / Test Commands

There is no traditional build system. The workflow is:

### Build the Docker image

```bash
./scripts/sonic-build-container-from-qcow2.sh /path/to/sonic-vs.img.gz   # requires WARP disconnected
```

### Deploy the lab

```bash
cd simple-lab
containerlab deploy          # SONiC VM takes ~60s to boot
```

### Run all tests

```bash
cd simple-lab
pytest simple_test.py -v
```

### Run a single test

```bash
pytest simple_test.py -v -k "test_ethernet0_up"                          # substring match
pytest simple_test.py -v -k "TestHealth"                                  # by class
pytest simple_test.py -v "simple_test.py::TestHealth::test_redis_ping"    # fully qualified
```

### Full lifecycle (build + deploy + test + cleanup)

```bash
./scripts/runlab.sh --lab simple-lab --image /path/to/sonic-vs.img.gz   # build, deploy, test, cleanup
./scripts/runlab.sh --lab simple-lab                                     # skip build, deploy + test only
./scripts/runlab.sh --lab simple-lab --no-cleanup                        # deploy + test, leave lab running
```

### Destroy the lab

```bash
cd simple-lab
containerlab destroy
```

## Dependencies

- [containerlab](https://containerlab.dev/install/) v0.56.0+
- Docker with KVM support (`/dev/kvm` must exist)
- Python 3 with `pytest` and `paramiko`

Install everything with: `sudo ./scripts/install-dependencies.sh`

## Code Style Guidelines

### Python (tests)

- **Formatter/linter**: None configured. Follow PEP 8 conventions.
- **Line length**: Keep lines under 100 characters.
- **Quotes**: Use double quotes for strings.
- **Imports**: Group in order (stdlib, third-party, local), separated by blank
  lines. Alphabetical within each group.
- **Type annotations**: Not used in this codebase. Don't add them.
- **Docstrings**: Every test method gets a one-line docstring explaining what
  it validates. Use `"""Triple double quotes."""` on a single line.
- **Test classes**: Group related tests into classes (`TestHealth`, `TestNetwork`).
  Class names use `PascalCase` with a `Test` prefix. Each class gets a docstring.
- **Test methods**: Use `snake_case` with a `test_` prefix. Name should describe
  the condition being verified (e.g., `test_no_core_dumps`, `test_ethernet0_up`).
- **Assertions**: Use plain `assert` with descriptive failure messages via
  f-strings: `assert condition, f"Explanation: {details}"`.
- **Fixtures**: Use `pytest.fixture` with `scope="session"` for expensive
  connections (SSH). Yield the resource and clean up after.
- **Constants**: Module-level, `UPPER_SNAKE_CASE`, grouped under a
  `# CONFIG` section header.
- **Section headers**: Use `# ===...===` comment blocks to separate major
  sections (CONFIG, TRANSPORT, FIXTURES, test layers).

### Bash (scripts)

- **Shebang**: `#!/bin/bash` for scripts, `#!/usr/bin/env bash` for portable ones.
- **Strict mode**: Always start with `set -euo pipefail`.
- **Variables**: `UPPER_SNAKE_CASE` for constants and configuration.
- **Quoting**: Always quote variables: `"$VAR"`, not `$VAR`.
- **Error messages**: Guard checks with clear error messages and `exit 1`.
- **Cleanup**: Use `trap cleanup EXIT` for resource cleanup.
- **Structure**: Use `# ===...===` comment blocks with step numbers to separate
  phases (e.g., `# 0. PRE-CLEAN`, `# 1. BUILD`, `# 2. DEPLOY`).
- **Script header**: Include a comment block describing purpose and usage.

### YAML (containerlab topology)

- **Indentation**: 2 spaces.
- **Style**: Follow containerlab conventions. Nodes define `kind` and `image`;
  links use `endpoints` arrays.

## Error Handling Patterns

- **Python tests**: Assertions include f-string messages with the actual output
  for debugging: `assert "up" in out.lower(), f"Ethernet0 not up:\n{out}"`.
- **SSH helper** (`SonicSSH`): Forces IPv4 to avoid Cloudflare WARP IPv6 timeouts.
  Disables key-based auth (`look_for_keys=False`, `allow_agent=False`).
- **Docker exec helper**: Asserts `returncode == 0` and includes stderr in the
  failure message.
- **Bash scripts**: `set -euo pipefail` ensures immediate failure on errors.
  Pre-flight checks (e.g., WARP status, file existence) run before any work.

## Known Environment Issues

- **Cloudflare WARP + IPv6**: WARP intercepts IPv6 GUA traffic to containerlab
  nodes. Always use `-4` flag for SSH or force `socket.AF_INET` in Python.
- **WARP + Docker builds**: Disconnect WARP before building Docker images
  (`warp-cli disconnect`).

## Adding New Tests

1. Add test methods to the appropriate class in `simple-lab/simple_test.py`:
   - `TestHealth` — device health checks (containers, daemons, databases)
   - `TestNetwork` — network state validation (interfaces, IPs, connectivity)
2. Tests needing SSH to the switch take `sonic` as a parameter (pytest fixture).
   Tests against Linux containers use `docker_exec()`.
3. Follow the existing pattern: one-line docstring, single assertion with a
   descriptive failure message.
4. If adding a new test category, create a new `class Test*` with a section
   header comment block.
