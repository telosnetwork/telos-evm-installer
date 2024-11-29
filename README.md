# Telos EVM Installer

## Description
This repo contains a script to install the Telos EVM automatically from backup

## Usage
To install with 1 line, ensure that `wget` and `sudo` are already installed and then run:
```bash
TEMP_DIR=$(mktemp -d) && curl -o "$TEMP_DIR/run.sh" https://raw.githubusercontent.com/telosnetwork/telos-evm-installer/refs/heads/main/run.sh && bash "$TEMP_DIR/run.sh" && rm -rf "$TEMP_DIR"
```

Alternatively, the automated script for install can be downloaded from `https://raw.githubusercontent.com/telosnetwork/telos-evm-installer/refs/heads/main/run.sh`
