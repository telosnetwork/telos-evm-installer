#!/bin/bash

# Set strict error handling
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Initialize workspace
init_workspace() {
    log_info "Creating and entering Telos directory..."
    mkdir -p telos
    cd telos || exit 1
}

# Install dependencies
install_dependencies() {
    log_info "Installing system dependencies..."
    if ! sudo apt update; then
        log_error "Failed to update package lists"
        exit 1
    }
    
    if ! sudo apt install -y \
        curl \
        build-essential \
        clang \
        libclang-dev \
        gcc \
        make \
        pkg-config \
        jq \
        libssl-dev; then
        log_error "Failed to install dependencies"
        exit 1
    }
}

# Install Rust
install_rust() {
    if ! command_exists rustc; then
        log_info "Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    else
        log_info "Rust is already installed"
    fi
}

# Clone repositories
clone_repos() {
    log_info "Cloning Telos repositories..."
    git clone --branch telos-v1.0.0-rc5 https://github.com/telosnetwork/telos-consensus-client
    git clone --branch telos-v1.0.0-rc5 https://github.com/telosnetwork/telos-reth
}

# Build clients
build_clients() {
    log_info "Building Telos consensus client..."
    if ! ./telos-consensus-client/build.sh; then
        log_error "Failed to build consensus client"
        exit 1
    fi

    log_info "Building Telos reth..."
    if ! ./telos-reth/build.sh; then
        log_error "Failed to build reth"
        exit 1
    fi
}

# Get JWT secret
get_jwt_secret() {
    log_info "Reading JWT secret..."
    local jwt_path="./telos-reth-data/jwt.hex"
    
    if [[ ! -f "$jwt_path" ]]; then
        log_error "JWT file not found at $jwt_path"
        exit 1
    }
    
    JWT_SECRET=$(cat "$jwt_path")
    if [[ -z "$JWT_SECRET" ]]; then
        log_error "JWT secret is empty"
        exit 1
    }
    
    log_info "JWT secret successfully read"
}

# Generate consensus client config
generate_consensus_config() {
    log_info "Generating consensus client config..."
    local config_path="./telos-consensus-client/config.toml"
    
    cat > "$config_path" << EOF
# EVM Chain id, Telos mainnet is 40 and testnet is 41
chain_id = 40

# Execution API http endpoint (JWT protected endpoint on reth)
execution_endpoint = "http://127.0.0.1:8554"

# The JWT secret used to sign the JWT token
jwt_secret = "${JWT_SECRET}"

# Nodeos ship ws endpoint
ship_endpoint = "ws://127.0.0.1:19000"

# Nodeos http endpoint
chain_endpoint = "http://127.0.0.1:8888"

# Block count in between finalize block calls while syncing
batch_size = 500

# The parent hash of the start_block
prev_hash = "0000000000000000000000000000000000000000000000000000000000000000"

# Start block to start with, should be at or before the first block of the execution node
evm_start_block = 0

# (Optional) Expected block hash of the start block
# validate_hash: Option<String>

# (Optional) Block number to stop on, default is U32::MAX
#evm_stop_block = 354408792

log_level = "info"
data_path = "temp/db"
block_checkpoint_interval = 1000
maximum_sync_range = 100000
latest_blocks_in_db_num = 500
EOF

    if [[ ! -f "$config_path" ]]; then
        log_error "Failed to create consensus client config"
        exit 1
    }
    
    log_info "Consensus client config generated successfully"
}

# Main execution
main() {
    log_info "Starting Telos node setup..."
    
    init_workspace
    install_dependencies
    install_rust
    clone_repos
    build_clients
    get_jwt_secret
    generate_consensus_config
    
    log_info "Setup completed successfully"
}

# Run the script
main
