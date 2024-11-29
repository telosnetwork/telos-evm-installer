#!/bin/bash

# Set strict error handling
set -euo pipefail

RELEASE_TAG="telos-v1.0.0-rc5"

LEAP_DEB="leap_4.0.6-ubuntu22.04_amd64.deb"
LEAP_DEB_URL="https://github.com/AntelopeIO/leap/releases/download/v4.0.6/$LEAP_DEB"
LOCAL_DEBUGGING=true

# Global array to keep track of selected ports
SELECTED_PORTS=()

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

# Function to check and set a port
check_and_set_port() {
  local description="$1"
  local default_port="$2"
  local selected_port

  while true; do
    read -p "$description (default: $default_port): " selected_port
    selected_port="${selected_port:-$default_port}"

    # Check if the port is already selected in this session
    for port in "${SELECTED_PORTS[@]}"; do
      if [[ "$port" == "$selected_port" ]]; then
        log_info "Port $selected_port has already been selected in this process. Please choose another."
        continue 2  # Skip to the next iteration of the outer while loop
      fi
    done

    # Check if the port is in use
    if lsof -iTCP:"$selected_port" -sTCP:LISTEN &>/dev/null; then
      log_info "Port $selected_port is already in use. Please choose another."
    else
      # Add the port to the global array
      SELECTED_PORTS+=("$selected_port")
      echo "$selected_port"
      return
    fi
  done
}

# Initialize inputs
init_inputs() {
  if [ "$(pwd)" == "/" ]; then
      INSTALL_DIR=/telos
  else
      INSTALL_DIR=$(pwd)/telos
  fi
  log_info "Please provided the following values to setup the Telos node"
  log_info "All values will be in configuration files which can be changed later"
  log_info "Press enter to use the default value"
  read -p "Specify the install directory for all services (default: $INSTALL_DIR): " USER_DIR
  if [ -n "$USER_DIR" ]; then
      INSTALL_DIR="$USER_DIR"
  fi

  read -p "Specify the version to use (default: $RELEASE_TAG): " USER_TAG
  if [ -n "$USER_TAG" ]; then
      RELEASE_TAG="$USER_TAG"
  fi

  REGION="west"
  read -p "For peering with other nodes, are you in the East (Asia/Europe) or West(North/South America). Options are east or west (default: west): " USER_REGION
  if [ -n "$USER_REGION" ]; then
    REGION="$USER_REGION"
  fi
  if [ "$REGION" == "west" ]; then
    PEERS_URL="https://raw.githubusercontent.com/telosnetwork/telos-evm-installer/refs/heads/main/nodeos-peers/western-peers.txt"
    log_info "You have selected the west region"
  else
    log_info "You have selected the east region"
    PEERS_URL="https://raw.githubusercontent.com/telosnetwork/telos-evm-installer/refs/heads/main/nodeos-peers/western-peers.txt"
  fi

  NODEOS_HTTP_RPC_PORT=$(check_and_set_port "Enter the RPC port for http nodeos" 8888)
  NODEOS_HTTP_P2P_PORT=$(check_and_set_port "Enter the P2P port for http nodeos" 9876)

  NODEOS_SHIP_RPC_PORT=$(check_and_set_port "Enter the RPC port for ship nodeos" 9888)
  NODEOS_SHIP_WS_SHIP_PORT=$(check_and_set_port "Enter the SHIP WS port for ship nodeos" 18999)
  NODEOS_SHIP_P2P_PORT=$(check_and_set_port "Enter the P2P port for ship nodeos" 9877)

  RETH_RPC_PORT=$(check_and_set_port "Enter the RPC port for reth (will be hosted on 0.0.0.0 for external use)" 8545)
  RETH_WS_PORT=$(check_and_set_port "Enter the WS RPC port for reth (will be hosted on 0.0.0.0 for external use)" 8546)
  RETH_AUTH_RPC_PORT=$(check_and_set_port "Enter the Auth RPC port for reth (this is where the consensus client connects via JWT, will be hosted on 127.0.0.1)" 8551)
  RETH_DISCOVERY_PORT=$(check_and_set_port "Enter the discovery port for reth (not used for discovery but reth wants to open it anyway, will be hosted on 127.0.0.1)" 8551)

  INSTALL_DIR=$(realpath -m "$INSTALL_DIR")
}

# Initialize workspace
init_workspace() {
    log_info "Creating and entering $INSTALL_DIR directory..."
    mkdir -p $INSTALL_DIR
    cd $INSTALL_DIR || exit 1
}

# Install dependencies
install_dependencies() {
    log_info "Installing system dependencies..."
    if ! sudo apt update; then
        log_error "Failed to update package lists"
        exit 1
    fi

    # TODO: Avoid the prompt for timezone
    if ! DEBIAN_FRONTEND=noninteractive sudo apt install -y \
        git \
        curl \
        build-essential \
        clang \
        libclang-dev \
        gcc \
        make \
        zstd \
        pkg-config \
        jq \
        libssl-dev;
    then
        log_error "Failed to install dependencies"
        exit 1
    fi
}

# Install Rust
install_rust() {
    if ! command_exists rustc; then
        log_info "Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
        . "$HOME/.cargo/env"
    else
        log_info "Rust is already installed"
    fi
}

# Install Nodeos
install_nodeos() {
    if ! command_exists nodeos; then
        log_info "Installing Nodeos..."
        curl -L $LEAP_DEB_URL --output $LEAP_DEB
        sudo dpkg -i $LEAP_DEB
    else
        log_info "Nodeos is already installed"
    fi
}

setup_nodeos_base() {
    local NODEOS_DIR=$INSTALL_DIR/$1
    log_info "Setting up nodeos base for $1"
    mkdir -p $NODEOS_DIR
    cat > $NODEOS_DIR/start.sh << 'EOF'
#!/bin/bash

INSTALL_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_PATH="$INSTALL_ROOT/nodeos.log"
DATA_DIR_PATH=$INSTALL_ROOT/data

nohup nodeos --disable-replay-opts --data-dir $DATA_DIR_PATH --config-dir $INSTALL_ROOT "$@" >> "$LOG_PATH" 2>&1 &
PID="$!"
echo "nodeos started with pid $PID"
echo $PID > $INSTALL_ROOT/nodeos.pid

EOF

    cat > $NODEOS_DIR/stop.sh << 'EOF'
#!/bin/bash

INSTALL_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PID_FILE="$INSTALL_ROOT/nodeos.pid"
PID="$( cat $PID_FILE )"

if [ -n "$PID" ]; then
  echo "Killing pid " $PID
  kill $PID

  for i in $(seq 1 20); do
  IS_RUNNING=`ps $PID | wc -l`

  if [ $IS_RUNNING = "1" ]; then
    echo "$INSTALL_ROOT node has been shutdown"
    break;
  fi

  echo "Waiting..."

  sleep 2
  done

  if [ $IS_RUNNING = "2" ]; then
  echo "ERROR: Unable to shutdown $INSTALL_ROOT node successfully, check log"
  fi

else
  echo "No pid found at $PID_FILE"
fi

EOF
    chmod +x $NODEOS_DIR/*.sh

    cat > $NODEOS_DIR/logging.json << "EOF"
{
  "includes": [],
  "appenders": [{
      "name": "stderr",
      "type": "console",
      "args": {
        "format": "${timestamp} ${thread_name} ${context} ${file}:${line} ${method} ${level}]  ${message}",
        "stream": "std_error",
        "level_colors": [{
            "level": "debug",
            "color": "green"
          },{
            "level": "warn",
            "color": "brown"
          },{
            "level": "error",
            "color": "red"
          }
        ],
        "flush": true
      },
      "enabled": true
    },{
      "name": "stdout",
      "type": "console",
      "args": {
        "stream": "std_out",
        "level_colors": [{
            "level": "debug",
            "color": "green"
          },{
            "level": "warn",
            "color": "brown"
          },{
            "level": "error",
            "color": "red"
          }
        ],
        "flush": true
      },
      "enabled": true
    },{
      "name": "net",
      "type": "gelf",
      "args": {
        "endpoint": "10.10.10.10:12201",
        "host": "host_name",
        "_network": "mainnet"
      },
      "enabled": false
    }
  ],
  "loggers": [{
      "name": "default",
      "level": "debug",
      "enabled": true,
      "additivity": false,
      "appenders": [
        "stderr"
      ]
    },{
      "name": "net_plugin_impl",
      "level": "info",
      "enabled": true,
      "additivity": false,
      "appenders": [
        "stderr"
      ]
    },{
      "name": "http_plugin",
      "level": "info",
      "enabled": true,
      "additivity": false,
      "appenders": [
        "stderr"
      ]
    },{
      "name": "producer_plugin",
      "level": "info",
      "enabled": true,
      "additivity": false,
      "appenders": [
        "stderr"
      ]
    },{
      "name": "transaction_success_tracing",
      "level": "info",
      "enabled": true,
      "additivity": false,
      "appenders": [
        "stderr"
      ]
    },{
      "name": "transaction_failure_tracing",
      "level": "info",
      "enabled": true,
      "additivity": false,
      "appenders": [
        "stderr"
      ]
    },{
      "name": "trace_api",
      "level": "info",
      "enabled": true,
      "additivity": false,
      "appenders": [
        "stderr"
      ]
    },{
      "name": "transaction_trace_success",
      "level": "info",
      "enabled": true,
      "additivity": false,
      "appenders": [
        "stderr",
      ]
    },{
      "name": "transaction_trace_failure",
      "level": "info",
      "enabled": true,
      "additivity": false,
      "appenders": [
        "stderr",
      ]
    },{
    "name": "state_history",
    "level": "info",
    "enabled": true,
    "additivity": false,
    "appenders": [
      "stderr",
      ]
    },{
      "name": "transaction",
      "level": "info",
      "enabled": true,
      "additivity": false,
      "appenders": [
        "stderr",
      ]
    }
  ]
}

EOF
}

setup_nodeos() {
  setup_nodeos_base "nodeos-http"
  setup_nodeos_base "nodeos-ship"
  PEERS=$(curl -s $PEERS_URL)
  # Setup http nodeos config
  cat > $INSTALL_DIR/nodeos-http/config.ini << EOF
# THIS IS YOUR API SERVER HTTP PORT, PUT IT BEHIND NGINX OR HAPROXY WITH SSL
http-server-address = 127.0.0.1:$NODEOS_HTTP_RPC_PORT

# THIS IS YOUR P2P PORT AND IS ONLY TCP, DO NOT TRY TO PUT SSL IN FRONT OR USE AN HTTP PROXY WITH IT
p2p-listen-endpoint = 127.0.0.1:$NODEOS_HTTP_P2P_PORT

# SET A LOGICAL NAME FOR THIS NODE
agent-name = "Name that peers will see this node as"

# Directory configuration if you are splitting state/blocks/ship/trace...
#    note that state currently is not configurable and will be relative to the data-dir
#blocks-dir=
#state-history-dir=
#trace-dir=

wasm-runtime = eos-vm-jit

# DO NOT ENABLE THESE ON A PRODUCER, they may be handy for making replays faster though!
eos-vm-oc-compile-threads = 4
eos-vm-oc-enable = 1

# This can be set as low as the configured RAM on the network,
#   but should not be higher than the configured RAM on your server
chain-state-db-size-mb = 65536
contracts-console = true
access-control-allow-origin = *
access-control-allow-headers = *
verbose-http-errors = true
http-validate-host = false
abi-serializer-max-time-ms = 5000
http-max-response-time-ms = 10000

#this must be a high number behind a proxy, as all connections appear to come from the proxy host
p2p-max-nodes-per-host = 100

# PLUGINS
plugin = eosio::http_plugin
plugin = eosio::chain_plugin
plugin = eosio::chain_api_plugin
plugin = eosio::net_plugin
plugin = eosio::producer_plugin

# Peers
$PEERS
EOF

  cat > $INSTALL_DIR/nodeos-ship/config.ini << EOF
# THIS IS YOUR API SERVER HTTP PORT, PUT IT BEHIND NGINX OR HAPROXY WITH SSL
http-server-address = 127.0.0.1:$NODEOS_SHIP_RPC_PORT

# THIS IS YOUR P2P PORT AND IS ONLY TCP, DO NOT TRY TO PUT SSL IN FRONT OR USE AN HTTP PROXY WITH IT
p2p-listen-endpoint = 127.0.0.1:$NODEOS_SHIP_P2P_PORT

# SET A LOGICAL NAME FOR THIS NODE
agent-name = "Name that peers will see this node as"

# Directory configuration if you are splitting state/blocks/ship/trace...
#    note that state currently is not configurable and will be relative to the data-dir
#blocks-dir=
#state-history-dir=
#trace-dir=

wasm-runtime = eos-vm-jit

# DO NOT ENABLE THESE ON A PRODUCER, they may be handy for making replays faster though!
eos-vm-oc-compile-threads = 4
eos-vm-oc-enable = 1

# This can be set as low as the configured RAM on the network,
#   but should not be higher than the configured RAM on your server
chain-state-db-size-mb = 65536
contracts-console = true
access-control-allow-origin = *
access-control-allow-headers = *
verbose-http-errors = true
http-validate-host = false
abi-serializer-max-time-ms = 5000
http-max-response-time-ms = 10000

#this must be a high number behind a proxy, as all connections appear to come from the proxy host
p2p-max-nodes-per-host = 100

# PLUGINS
plugin = eosio::http_plugin
plugin = eosio::chain_plugin
plugin = eosio::chain_api_plugin
plugin = eosio::net_plugin
plugin = eosio::producer_plugin

#IF YOU ARE RUNNING STATE HISTORY FOR HYPERION, ENABLE AND CONFIGURE THE BELOW
plugin = eosio::state_history_plugin
state-history-endpoint = 0.0.0.0:$NODEOS_SHIP_WS_SHIP_PORT
trace-history = true
chain-state-history = true
trace-history-debug-mode = true

# Peers
$PEERS
EOF

}

# Download nodeos snapshot
download_snapshot() {
    cd $INSTALL_DIR
    log_info "Downloading nodeos snapshot..."
    if [ ! -d ./snapshots ]; then
        mkdir snapshots
    fi
    cd snapshots || exit 1
    curl http://storage.telos.net/evm_backups/mainnet/latest-nodeos.bin.zst --output latest-nodeos.bin.zst
    unzstd latest-nodeos.bin.zst
    cd $INSTALL_DIR
}

# Start nodeos
start_nodeos() {
    log_info "Starting nodeos..."
    cd $INSTALL_DIR/nodeos-http || exit 1
    bash start.sh --snapshot ../snapshots/latest-nodeos.bin
    log_info "HTTP nodeos started successfully"
    cd $INSTALL_DIR/nodeos-ship || exit 1
    bash start.sh --snapshot ../snapshots/latest-nodeos.bin
    log_info "SHIP nodeos started successfully"
    cd $INSTALL_DIR
}

# Clone repositories
clone_repos() {
    cd $INSTALL_DIR
    log_info "Cloning Telos repositories..."
    if [ ! -d ./telos-consensus-client ]; then
      git clone --branch $RELEASE_TAG https://github.com/telosnetwork/telos-consensus-client
    fi
    if [ ! -d ./telos-reth ]; then
      git clone --branch $RELEASE_TAG https://github.com/telosnetwork/telos-reth
    fi
    cd $INSTALL_DIR
}

# Build clients
build_clients() {
    log_info "Building Telos consensus client..."
    cd $INSTALL_DIR/telos-consensus-client || exit 1
    if ! bash build.sh; then
        log_error "Failed to build consensus client"
        exit 1
    fi

    cd $INSTALL_DIR/telos-reth || exit 1

    log_info "Building Telos reth..."
    if ! bash build.sh; then
        log_error "Failed to build reth"
        exit 1
    fi

    cd $INSTALL_DIR
}

# Download backup
download_backup() {
    cd $INSTALL_DIR
    log_info "Downloading reth backup..."
    if [ ! -d ./telos-reth-data ]; then
      curl http://storage.telos.net/evm_backups/mainnet/latest-reth.tar.zst --output latest-reth.tar.zst
    fi
}

# Extract backup
extract_backup() {
    cd $INSTALL_DIR
    log_info "Extracting reth backup..."
    tar --zstd -xvf latest-reth.tar
    cd $INSTALL_DIR
}

# Get JWT secret
get_jwt_secret() {
    log_info "Reading JWT secret..."
    local jwt_path="./telos-reth-data/jwt.hex"
    
    if [[ ! -f "$jwt_path" ]]; then
        log_error "JWT file not found at $jwt_path"
        exit 1
    fi
    
    JWT_SECRET=$(cat "$jwt_path")
    if [[ -z "$JWT_SECRET" ]]; then
        log_error "JWT secret is empty"
        exit 1
    fi
    
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
    fi
    
    log_info "Consensus client config generated successfully"
}

# Main execution
main() {
    log_info "Starting Telos node setup..."
    
    install_dependencies
    init_inputs
    init_workspace
    install_rust
    install_nodeos
    download_snapshot
    setup_nodeos
    start_nodeos
    clone_repos
    build_clients
    download_backup
#    extract_backup
#    get_jwt_secret
#    generate_consensus_config
    
    log_info "Setup completed successfully"
}

# Run the script
main
