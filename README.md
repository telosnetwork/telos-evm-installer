# TelosEVM 3.0 Installer

This installer provisions the TelosEVM 3.0 pre-Savannah stack:

- `telos-reth-v2`
- `telos-consensus-client`
- TelosZero Core/nodeos HTTP and SHIP nodes
- systemd units for all four services
- log files and logrotate
- a local healthcheck script
- pre-Savannah head tracking with canonical RPC validation
- the current public `rpc.evm@rpc` signer key for Telos transaction forwarding

The default client refs are the hardened pre-Savannah beta tags:

```bash
https://github.com/TheJudii/telos-reth-v2.git v3.0.0-beta.3
https://github.com/TheJudii/telos-consensus-client.git v3.0.0-beta.4
```

## Current Status

This is ready for controlled mainnet beta installs. Before publishing as the public one-line production installer, upload the matching Telos mainnet quick chainspec to stable storage and set `RETH_CHAIN_SPEC_URL` as the default in `run.sh`.

The quick reth backup is not enough by itself. Reth v2 must be started with the chainspec that matches the backup DB genesis. The current quick chainspec is large, so it is intentionally not committed to this repo.

## Quick Start

Interactive install:

```bash
git clone https://github.com/telosnetwork/telos-evm-installer telos-evm-3-installer
cd telos-evm-3-installer
git checkout v3.0.0-beta.5
RETH_CHAIN_SPEC_URL="https://YOUR-STABLE-STORAGE/telos-mainnet-quick.json" ./run.sh
```

Non-interactive install:

```bash
NONINTERACTIVE=1 \
INSTALL_DIR=/opt/telos-evm-3 \
BOOTSTRAP_MODE=backup \
RETH_CHAIN_SPEC_URL="https://YOUR-STABLE-STORAGE/telos-mainnet-quick.json" \
RETH_HTTP_ADDR=127.0.0.1 \
RETH_WS_ADDR=127.0.0.1 \
./run.sh
```

For a slow from-genesis install without the quick backup:

```bash
NONINTERACTIVE=1 \
BOOTSTRAP_MODE=genesis \
INSTALL_DIR=/opt/telos-evm-3 \
./run.sh
```

Genesis mode is mainly useful for validation and development. It is not the recommended path for bringing up production capacity quickly.

## Installed Services

The installer writes these systemd units:

```bash
telos-evm3-nodeos-http.service
telos-evm3-nodeos-ship.service
telos-evm3-reth.service
telos-evm3-consensus.service
```

Useful commands:

```bash
systemctl status telos-evm3-reth telos-evm3-consensus
journalctl -u telos-evm3-reth -f
journalctl -u telos-evm3-consensus -f
/opt/telos-evm-3/bin/healthcheck.sh
```

Log files are written under:

```bash
/opt/telos-evm-3/logs/
```

## Default Ports

| Service | Default | Bind |
| --- | ---: | --- |
| nodeos HTTP RPC | `8888` | `127.0.0.1` |
| nodeos HTTP P2P | `9876` | `127.0.0.1` |
| nodeos SHIP HTTP RPC | `9888` | `127.0.0.1` |
| nodeos SHIP WS | `18999` | `127.0.0.1` |
| nodeos SHIP P2P | `9877` | `127.0.0.1` |
| reth HTTP RPC | `8545` | `127.0.0.1` |
| reth WS RPC | `8546` | `127.0.0.1` |
| reth Auth RPC | `8551` | `127.0.0.1` |
| reth discovery | `30303` | local host networking |
| reth metrics | `9002` | `127.0.0.1` |

The installer intentionally binds reth HTTP/WS to localhost by default. Put nginx, HAProxy, or another controlled edge in front of it for public RPC.

## Production Safety Defaults

The generated consensus config uses:

```toml
rpc_fallback_endpoints = [
  "https://rpc.telos.net/evm",
  "https://telos.drpc.org/",
  "https://rpc1.us.telos.net/evm",
]
rpc_fallback_quorum = 2
rpc_fallback_sample_every_n = 1
```

That means every pre-Savannah head block must match canonical RPC quorum before it is forwarded to reth.

The generated reth launcher uses:

```bash
--engine.persistence-threshold 20
--engine.persistence-backpressure-threshold 30
--engine.memory-block-buffer-target 30
--telos.trust_consensus true
--telos.build_state
```

The public mainnet signer key is:

```bash
TELOS_SIGNER_KEY=5KjZqM5UTGmmHByRXZaDM1a5JupgGM9925H3NEroTr6CdEZQDvH
```

It derives to the current on-chain `rpc.evm@rpc` public key:

```bash
EOS5xBSwWxWqsQP93Ps9N5JCSAjxNtwESgU3AAJgi3PEm5hYMRrCL
```

The Engine API JWT is generated per install and stored at:

```bash
/opt/telos-evm-3/telos-reth-data/jwt.hex
```

## Important Environment Variables

| Variable | Default |
| --- | --- |
| `INSTALL_DIR` | `/opt/telos-evm-3` |
| `BOOTSTRAP_MODE` | `backup` |
| `RETH_CHAIN_SPEC_URL` | empty, must be set for backup mode |
| `RETH_CHAIN_SPEC_PATH` | `$INSTALL_DIR/telos-mainnet-quick.json` |
| `RETH_REPO` | `https://github.com/TheJudii/telos-reth-v2.git` |
| `RETH_REF` | `v3.0.0-beta.3` |
| `CONSENSUS_REPO` | `https://github.com/TheJudii/telos-consensus-client.git` |
| `CONSENSUS_REF` | `v3.0.0-beta.4` |
| `TELOS_ZERO_CORE_VERSION` | `1.2.2` |
| `TELOS_ZERO_CORE_DEB_URL` | `https://github.com/telosnetwork/teloszero-core/releases/download/teloszero-v1.2.2/teloszero-core_1.2.2_amd64.deb` |
| `CANONICAL_RPCS` | `https://rpc.telos.net/evm,https://telos.drpc.org/,https://rpc1.us.telos.net/evm` |
| `RPC_FALLBACK_QUORUM` | `2` |
| `SIGNER_KEY` | current public mainnet `rpc.evm@rpc` WIF |
| `SKIP_START` | `0` |

Set `SKIP_START=1` to build and write configs/units without starting services.

## Remaining Release Work

Before this should become the official public installer:

1. Upload the current mainnet quick chainspec to stable Telos-controlled storage.
2. Set `RETH_CHAIN_SPEC_URL` in `run.sh` to that stable URL.
3. Run a clean install on a fresh Ubuntu 22.04/24.04 host.
4. Run funded tx forwarding smoke tests against the installed node.
5. Soak for 48-72 hours with 2-of-3 canonical RPC quorum.
6. Promote from beta tags to final release tags after the soak and smoke-test gates pass.
