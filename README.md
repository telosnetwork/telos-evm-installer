# Telos EVM v2.0 Installer

## Description
This repo contains a script to install the Telos EVM automatically from backup as well as detailed manual install instructions.

## Quick Start
To install with 1 line, ensure that `wget` and `sudo` are already installed and then run:
```bash
TEMP_DIR=$(mktemp -d) && curl -o "$TEMP_DIR/run.sh" https://raw.githubusercontent.com/telosnetwork/telos-evm-installer/refs/heads/main/run.sh && bash "$TEMP_DIR/run.sh" && rm -rf "$TEMP_DIR"
```

Alternatively, the automated script for install can be downloaded from `https://raw.githubusercontent.com/telosnetwork/telos-evm-installer/refs/heads/main/run.sh`

# Telos EVM 2.0 Node Installation Script Documentation

This document explains how to use and configure the Telos node installation script. The script automates the process of setting up a complete Telos node environment including nodeos, reth, and the consensus client.

## Prerequisites

Before running the script, ensure your system meets these requirements:

- Ubuntu 22.04 or 24.04 LTS
- Sudo privileges
- Internet connectivity
- Minimum 16GB RAM, 32GB recommended
- Minimum 8 Cores, 16 cores recommended
- At least 500GB of solid-state storage
- Ports available for node operation

## Configuration Options

The script will prompt for several configuration options. Here's what each one means:

### Installation Directory
- Default: `./telos` or `/telos` if run from root
- Purpose: Base directory where all Telos node components will be installed
- Storage requirements: Ensure sufficient disk space in the chosen location

### Version Tag
- Default: `telos-v1.0.0-rc5`
- Purpose: Specifies which version of the Telos software to install
- Format: Must match a valid release tag from the Telos repositories

### Geographic Region
- Options: `east` or `west`
- Default: `west`
- Purpose: Optimizes peer connections based on your location
  - East: Asia/Europe
  - West: North/South America
- Impact: Affects which peer list is used for node connections

### Port Configuration
The script requires several ports for different services. Default ports are:

| Service | Port Type | Default Port | Listen Address | Description |
|---------|-----------|--------------|----------------|-------------|
| Nodeos HTTP | RPC | 8888 | 127.0.0.1 | Main API endpoint |
| Nodeos HTTP | P2P | 9876 | 127.0.0.1 | Peer communication |
| Nodeos SHIP | RPC | 9888 | 127.0.0.1 | State-History endpoint |
| Nodeos SHIP | WebSocket | 18999 | 0.0.0.0 | SHIP WebSocket |
| Nodeos SHIP | P2P | 9877 | 127.0.0.1 | SHIP peer communication |
| Reth | RPC | 8545 | 0.0.0.0 | EVM RPC endpoint |
| Reth | WebSocket | 8546 | 0.0.0.0 | EVM WebSocket endpoint |
| Reth | Auth RPC | 8551 | 127.0.0.1 | JWT-protected endpoint |
| Reth | Discovery | 30303 | 127.0.0.1 | Network discovery |

## Installation Components

The script installs and configures several components:

### System Dependencies
- git
- curl
- build-essential
- clang
- libclang-dev
- gcc
- make
- zstd
- pkg-config
- jq
- libssl-dev

### Core Components
1. **Nodeos (Leap)**: EOSIO blockchain node software
   - Configuration location: `{install_dir}/nodeos-http/config.ini` and `{install_dir}/nodeos-ship/config.ini`
   - Log location: `{install_dir}/nodeos-http/nodeos.log` and `{install_dir}/nodeos-ship/nodeos.log`

2. **Reth**: Telos EVM execution client
   - Configuration location: `{install_dir}/telos-reth/.env`
   - Log location: `{install_dir}/telos-reth/reth.log`

3. **Consensus Client**: Telos consensus layer
   - Configuration location: `{install_dir}/telos-consensus-client/config.toml`
   - Log location: `{install_dir}/telos-consensus-client/consensus.log`

## Log Management

The script configures logrotate for all service logs:
- Rotation frequency: Daily
- Number of backups: 5
- Compression: Enabled
- File permissions: 0644 (root:root)

## Security Considerations

1. **Network Security**
   - Most services listen on localhost (127.0.0.1)
   - Only Reth RPC/WS ports are exposed publicly
   - Recommended to use a reverse proxy with SSL for public endpoints

2. **Configuration Security**
   - JWT authentication between Reth and consensus client
   - Default signer key should be updated for production use
   - Access control headers can be customized in nodeos config

## Post-Installation

After installation completes:

1. Verify all services are running using the provided status scripts
2. Configure your reverse proxy for the public RPC endpoints
3. Monitor the logs for any synchronization issues at the below path. When syncing gets to the head block, you will see a rate of 2 blocks per second.
   - `tail -f {install_dir}/telos-consensus-client/consensus.log | grep sec`

### Service Management

Each component has its own start/stop scripts:

```bash
# Start a service
{install_dir}/{service}/start.sh

# Stop a service
{install_dir}/{service}/stop.sh
```

## Troubleshooting

Common issues and solutions:

1. **Port Conflicts**
   - The script checks for port availability
   - Change ports if conflicts occur
   - Verify no other services are using the required ports

2. **Resource Issues**
   - Monitor system resources during sync
   - Adjust `chain-state-db-size-mb` if needed
   - Check disk space regularly

3. **Network Issues**
   - Verify peer connections in nodeos logs
   - Check firewall settings for required ports
   - Monitor network bandwidth usage

## Additional Resources

- [Telos Documentation](https://docs.telos.net)
- [Telos EVM Documentation](https://docs.telos.net/evm)
- [Telos Network Monitor](https://telosscan.io)

For support, join the [Telos Discord](https://discord.gg/telos) or open an issue on GitHub.
