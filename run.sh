#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_VERSION="3.0.0-beta.2"

RETH_REPO_DEFAULT="https://github.com/TheJudii/telos-reth-v2.git"
RETH_REF_DEFAULT="v3.0.0-beta.2"
CONSENSUS_REPO_DEFAULT="https://github.com/TheJudii/telos-consensus-client.git"
CONSENSUS_REF_DEFAULT="v3.0.0-beta.2"

LEAP_VERSION_DEFAULT="4.0.6"
LEAP_DEB_DEFAULT="leap_4.0.6-ubuntu22.04_amd64.deb"
LEAP_DEB_URL_DEFAULT="https://github.com/AntelopeIO/leap/releases/download/v4.0.6/leap_4.0.6-ubuntu22.04_amd64.deb"

MAINNET_NODEOS_SNAPSHOT_URL_DEFAULT="http://storage.telos.net/evm_backups/mainnet/latest-nodeos.bin.zst"
MAINNET_RETH_BACKUP_URL_DEFAULT="http://storage.telos.net/evm_backups/mainnet/latest-reth.tar.zst"
MAINNET_CANONICAL_RPCS_DEFAULT="https://rpc.telos.net/evm,https://telos.drpc.org/,https://rpc1.us.telos.net/evm"
MAINNET_SIGNER_KEY_DEFAULT="5KjZqM5UTGmmHByRXZaDM1a5JupgGM9925H3NEroTr6CdEZQDvH"
MAINNET_SIGNER_PUBLIC_KEY="EOS5xBSwWxWqsQP93Ps9N5JCSAjxNtwESgU3AAJgi3PEm5hYMRrCL"
TELOS_GENESIS_STATE_ROOT_DEFAULT="0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$*"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
is_interactive() { [ -t 0 ] && [ "${NONINTERACTIVE:-0}" != "1" ]; }

usage() {
  cat <<'EOF'
TelosEVM 3.0 installer

Usage:
  ./run.sh [--help]

Common environment variables:
  INSTALL_DIR=/opt/telos-evm-3
  BOOTSTRAP_MODE=backup|genesis
  RETH_CHAIN_SPEC_URL=https://.../telos-mainnet-quick.json
  NONINTERACTIVE=1
  SKIP_START=1

Backup mode is the production path, but it requires the matching quick
chainspec via RETH_CHAIN_SPEC_URL or RETH_CHAIN_SPEC_PATH.
EOF
}

parse_args() {
  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
    "")
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
}

canonical_path() {
  local path="$1"
  if realpath -m "$path" >/dev/null 2>&1; then
    realpath -m "$path"
  elif command_exists python3; then
    python3 - "$path" <<'PY'
import os
import sys
print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
  else
    case "$path" in
      /*) echo "$path" ;;
      *) echo "$(pwd)/$path" ;;
    esac
  fi
}

prompt_value() {
  local var_name="$1"
  local prompt="$2"
  local default="$3"
  local current="${!var_name:-$default}"
  local answer

  if is_interactive; then
    read -r -p "$prompt (default: $current): " answer
    printf -v "$var_name" "%s" "${answer:-$current}"
  else
    printf -v "$var_name" "%s" "$current"
  fi
}

prompt_port() {
  local var_name="$1"
  local prompt="$2"
  local default="$3"
  local selected

  if [ -n "${!var_name:-}" ]; then
    return
  fi

  while true; do
    if is_interactive; then
      read -r -p "$prompt (default: $default): " selected
      selected="${selected:-$default}"
    else
      selected="$default"
    fi

    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${selected}$"; then
      if is_interactive; then
        log_warn "Port $selected is already listening; choose another."
        continue
      fi
      die "Port $selected is already listening. Set $var_name to another port."
    fi

    printf -v "$var_name" "%s" "$selected"
    return
  done
}

set_defaults() {
  : "${NETWORK:=mainnet}"
  if [ "$NETWORK" != "mainnet" ]; then
    die "This first TelosEVM 3.0 installer supports mainnet only. Set NETWORK=mainnet."
  fi

  : "${INSTALL_DIR:=/opt/telos-evm-3}"
  : "${BOOTSTRAP_MODE:=backup}"
  : "${RETH_REPO:=$RETH_REPO_DEFAULT}"
  : "${RETH_REF:=$RETH_REF_DEFAULT}"
  : "${CONSENSUS_REPO:=$CONSENSUS_REPO_DEFAULT}"
  : "${CONSENSUS_REF:=$CONSENSUS_REF_DEFAULT}"
  : "${LEAP_VERSION:=$LEAP_VERSION_DEFAULT}"
  : "${LEAP_DEB:=$LEAP_DEB_DEFAULT}"
  : "${LEAP_DEB_URL:=$LEAP_DEB_URL_DEFAULT}"
  : "${NODEOS_SNAPSHOT_URL:=$MAINNET_NODEOS_SNAPSHOT_URL_DEFAULT}"
  : "${RETH_BACKUP_URL:=$MAINNET_RETH_BACKUP_URL_DEFAULT}"
  : "${CANONICAL_RPCS:=$MAINNET_CANONICAL_RPCS_DEFAULT}"
  : "${RPC_FALLBACK_QUORUM:=2}"
  : "${RPC_FALLBACK_RETRY_INTERVAL_SECS:=5}"
  : "${RPC_FALLBACK_SAMPLE_EVERY_N:=1}"
  : "${SIGNER_ACCOUNT:=rpc.evm}"
  : "${SIGNER_PERMISSION:=rpc}"
  : "${SIGNER_KEY:=$MAINNET_SIGNER_KEY_DEFAULT}"
  : "${TELOS_GENESIS_STATE_ROOT:=$TELOS_GENESIS_STATE_ROOT_DEFAULT}"
  : "${CHAIN_ID:=40}"
  : "${EVM_DEPLOY_BLOCK:=180698896}"
  : "${BATCH_SIZE:=250}"
  : "${MAXIMUM_SYNC_RANGE:=500000000}"
  : "${LATEST_BLOCKS_IN_DB_NUM:=10000}"
  : "${BLOCK_CHECKPOINT_INTERVAL:=5000}"
  : "${RETH_HTTP_ADDR:=127.0.0.1}"
  : "${RETH_WS_ADDR:=127.0.0.1}"
  : "${RETH_AUTH_ADDR:=127.0.0.1}"
  : "${RETH_METRICS_ADDR:=127.0.0.1}"
  : "${NODEOS_HTTP_ADDR:=127.0.0.1}"
  : "${NODEOS_SHIP_HTTP_ADDR:=127.0.0.1}"
  : "${NODEOS_SHIP_WS_ADDR:=127.0.0.1}"
  : "${RETH_PERSISTENCE_THRESHOLD:=20}"
  : "${RETH_PERSISTENCE_BACKPRESSURE_THRESHOLD:=30}"
  : "${RETH_MEMORY_BLOCK_BUFFER_TARGET:=30}"
  : "${REGION:=west}"
  : "${SKIP_START:=0}"

  INSTALL_DIR="$(canonical_path "$INSTALL_DIR")"
  CONFIG_DIR="$INSTALL_DIR/etc"
  BIN_DIR="$INSTALL_DIR/bin"
  LOG_DIR="$INSTALL_DIR/logs"
  DOWNLOAD_DIR="$INSTALL_DIR/downloads"
  SNAPSHOT_DIR="$INSTALL_DIR/snapshots"
  RETH_SRC_DIR="$INSTALL_DIR/telos-reth-v2"
  CONSENSUS_SRC_DIR="$INSTALL_DIR/telos-consensus-client"
  RETH_DATADIR="$INSTALL_DIR/telos-reth-data"
  CONSENSUS_DATA_DIR="$INSTALL_DIR/telos-consensus-client-data"
  RETH_ENV="$CONFIG_DIR/reth.env"
  CONSENSUS_CONFIG="$CONFIG_DIR/consensus.toml"
  JWT_PATH="$RETH_DATADIR/jwt.hex"
  CHAIN_SPEC_PATH="${RETH_CHAIN_SPEC_PATH:-$INSTALL_DIR/telos-mainnet-quick.json}"

  if [ "$REGION" = "east" ]; then
    PEERS_URL="${PEERS_URL:-https://raw.githubusercontent.com/telosnetwork/telos-evm-installer/refs/heads/main/nodeos-peers/eastern-peers.txt}"
  else
    PEERS_URL="${PEERS_URL:-https://raw.githubusercontent.com/telosnetwork/telos-evm-installer/refs/heads/main/nodeos-peers/western-peers.txt}"
  fi
}

collect_inputs() {
  log_info "TelosEVM $INSTALLER_VERSION installer"
  prompt_value INSTALL_DIR "Install directory" "$INSTALL_DIR"
  INSTALL_DIR="$(canonical_path "$INSTALL_DIR")"
  set_defaults

  prompt_value BOOTSTRAP_MODE "Bootstrap mode: backup or genesis" "$BOOTSTRAP_MODE"
  prompt_value REGION "Peer region: west or east" "$REGION"
  prompt_value CANONICAL_RPCS "Canonical EVM RPCs, comma-separated" "$CANONICAL_RPCS"
  prompt_value RPC_FALLBACK_QUORUM "Canonical RPC quorum" "$RPC_FALLBACK_QUORUM"

  prompt_port NODEOS_HTTP_RPC_PORT "Nodeos HTTP RPC port" 8888
  prompt_port NODEOS_HTTP_P2P_PORT "Nodeos HTTP P2P port" 9876
  prompt_port NODEOS_SHIP_RPC_PORT "Nodeos SHIP HTTP RPC port" 9888
  prompt_port NODEOS_SHIP_WS_PORT "Nodeos SHIP websocket port" 18999
  prompt_port NODEOS_SHIP_P2P_PORT "Nodeos SHIP P2P port" 9877
  prompt_port RETH_RPC_PORT "Reth HTTP RPC port" 8545
  prompt_port RETH_WS_PORT "Reth WS RPC port" 8546
  prompt_port RETH_AUTH_RPC_PORT "Reth Auth RPC port" 8551
  prompt_port RETH_DISCOVERY_PORT "Reth discovery port" 30303
  prompt_port RETH_METRICS_PORT "Reth metrics port" 9002
}

sudo_cmd() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

prepare_dirs() {
  log_info "Creating $INSTALL_DIR"
  sudo_cmd mkdir -p "$CONFIG_DIR" "$BIN_DIR" "$LOG_DIR" "$DOWNLOAD_DIR" "$SNAPSHOT_DIR" \
    "$RETH_DATADIR" "$CONSENSUS_DATA_DIR"
  sudo_cmd chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"
}

install_dependencies() {
  log_info "Installing system dependencies"
  sudo_cmd apt-get update
  DEBIAN_FRONTEND=noninteractive sudo_cmd apt-get install -y \
    git curl wget build-essential clang libclang-dev gcc make zstd pkg-config jq \
    libssl-dev lsof ca-certificates openssl rsync tar
}

install_rust() {
  if command_exists cargo && command_exists rustc; then
    log_info "Rust is already installed"
    return
  fi

  log_info "Installing Rust"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck source=/dev/null
  . "$HOME/.cargo/env"
}

install_nodeos() {
  if command_exists nodeos; then
    log_info "nodeos is already installed"
    return
  fi

  log_info "Installing Leap $LEAP_VERSION"
  curl -fsSL "$LEAP_DEB_URL" -o "$DOWNLOAD_DIR/$LEAP_DEB"
  sudo_cmd dpkg -i "$DOWNLOAD_DIR/$LEAP_DEB"
}

download_nodeos_snapshot() {
  local zst="$SNAPSHOT_DIR/latest-nodeos.bin.zst"
  local bin="$SNAPSHOT_DIR/latest-nodeos.bin"

  if [ -f "$bin" ]; then
    log_info "Nodeos snapshot already exists: $bin"
    return
  fi

  log_info "Downloading nodeos snapshot"
  curl -fL "$NODEOS_SNAPSHOT_URL" -o "$zst"
  unzstd -f "$zst" -o "$bin"
}

write_nodeos_config() {
  log_info "Writing nodeos configuration"
  local peers
  peers="$(curl -fsSL "$PEERS_URL")"

  mkdir -p "$INSTALL_DIR/nodeos-http" "$INSTALL_DIR/nodeos-ship"

  cat > "$INSTALL_DIR/nodeos-http/config.ini" << EOF
http-server-address = $NODEOS_HTTP_ADDR:$NODEOS_HTTP_RPC_PORT
p2p-listen-endpoint = 127.0.0.1:$NODEOS_HTTP_P2P_PORT
agent-name = "TelosEVM-3.0-http"
wasm-runtime = eos-vm-jit
eos-vm-oc-compile-threads = 4
eos-vm-oc-enable = 1
chain-state-db-size-mb = 65536
contracts-console = true
access-control-allow-origin = *
access-control-allow-headers = *
verbose-http-errors = true
http-validate-host = false
abi-serializer-max-time-ms = 5000
http-max-response-time-ms = 10000
p2p-max-nodes-per-host = 100
plugin = eosio::http_plugin
plugin = eosio::chain_plugin
plugin = eosio::chain_api_plugin
plugin = eosio::net_plugin
plugin = eosio::producer_plugin
$peers
EOF

  cat > "$INSTALL_DIR/nodeos-ship/config.ini" << EOF
http-server-address = $NODEOS_SHIP_HTTP_ADDR:$NODEOS_SHIP_RPC_PORT
p2p-listen-endpoint = 127.0.0.1:$NODEOS_SHIP_P2P_PORT
agent-name = "TelosEVM-3.0-ship"
wasm-runtime = eos-vm-jit
eos-vm-oc-compile-threads = 4
eos-vm-oc-enable = 1
chain-state-db-size-mb = 65536
contracts-console = true
access-control-allow-origin = *
access-control-allow-headers = *
verbose-http-errors = true
http-validate-host = false
abi-serializer-max-time-ms = 5000
http-max-response-time-ms = 10000
p2p-max-nodes-per-host = 100
plugin = eosio::http_plugin
plugin = eosio::chain_plugin
plugin = eosio::chain_api_plugin
plugin = eosio::net_plugin
plugin = eosio::producer_plugin
plugin = eosio::state_history_plugin
state-history-endpoint = $NODEOS_SHIP_WS_ADDR:$NODEOS_SHIP_WS_PORT
trace-history = true
chain-state-history = true
trace-history-debug-mode = true
$peers
EOF
}

write_nodeos_launchers() {
  cat > "$BIN_DIR/nodeos-http.sh" << EOF
#!/usr/bin/env bash
set -euo pipefail
SNAPSHOT="$SNAPSHOT_DIR/latest-nodeos.bin"
DATA_DIR="$INSTALL_DIR/nodeos-http/data"
CONFIG_DIR="$INSTALL_DIR/nodeos-http"
mkdir -p "\$DATA_DIR"
ARGS=()
if [ ! -d "\$DATA_DIR/blocks" ] && [ -f "\$SNAPSHOT" ]; then
  ARGS+=(--snapshot "\$SNAPSHOT")
fi
exec nodeos --disable-replay-opts --data-dir "\$DATA_DIR" --blocks-log-stride 10000000 \
  --max-retained-block-files 1 --state-history-stride 10000000 \
  --max-retained-history-files 1 --config-dir "\$CONFIG_DIR" "\${ARGS[@]}"
EOF

  cat > "$BIN_DIR/nodeos-ship.sh" << EOF
#!/usr/bin/env bash
set -euo pipefail
SNAPSHOT="$SNAPSHOT_DIR/latest-nodeos.bin"
DATA_DIR="$INSTALL_DIR/nodeos-ship/data"
CONFIG_DIR="$INSTALL_DIR/nodeos-ship"
mkdir -p "\$DATA_DIR"
ARGS=()
if [ ! -d "\$DATA_DIR/blocks" ] && [ -f "\$SNAPSHOT" ]; then
  ARGS+=(--snapshot "\$SNAPSHOT")
fi
exec nodeos --disable-replay-opts --data-dir "\$DATA_DIR" --blocks-log-stride 10000000 \
  --max-retained-block-files 1 --state-history-stride 10000000 \
  --max-retained-history-files 1 --config-dir "\$CONFIG_DIR" "\${ARGS[@]}"
EOF

  chmod +x "$BIN_DIR/nodeos-http.sh" "$BIN_DIR/nodeos-ship.sh"
}

clone_or_update_repo() {
  local repo="$1"
  local ref="$2"
  local dir="$3"
  local name="$4"

  if [ -d "$dir/.git" ]; then
    log_info "Updating $name"
    git -C "$dir" fetch --all --tags --prune
  else
    log_info "Cloning $name"
    git clone "$repo" "$dir"
  fi

  git -C "$dir" checkout "$ref"
  if git -C "$dir" show-ref --verify --quiet "refs/heads/$ref"; then
    git -C "$dir" pull --ff-only origin "$ref"
  fi
}

build_clients() {
  # shellcheck source=/dev/null
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

  clone_or_update_repo "$RETH_REPO" "$RETH_REF" "$RETH_SRC_DIR" "telos-reth-v2"
  clone_or_update_repo "$CONSENSUS_REPO" "$CONSENSUS_REF" "$CONSENSUS_SRC_DIR" "telos-consensus-client"

  log_info "Building telos-reth-v2"
  cargo build --manifest-path "$RETH_SRC_DIR/Cargo.toml" --release -p telos-reth --bin telos-reth

  log_info "Building telos-consensus-client"
  (cd "$CONSENSUS_SRC_DIR" && bash build.sh)
}

bootstrap_reth_data() {
  local archive="$DOWNLOAD_DIR/latest-reth.tar.zst"
  local extract_dir
  local found

  case "$BOOTSTRAP_MODE" in
    backup)
      if [ ! -d "$RETH_DATADIR/db" ]; then
        log_info "Downloading reth backup"
        curl -fL "$RETH_BACKUP_URL" -o "$archive"
        extract_dir="$(mktemp -d "$INSTALL_DIR/reth-extract.XXXXXX")"
        log_info "Extracting reth backup"
        tar --zstd -xf "$archive" -C "$extract_dir"
        found="$(find "$extract_dir" -maxdepth 4 -type d -name telos-reth-data | head -1)"
        [ -n "$found" ] || die "Could not find telos-reth-data inside $archive"
        rsync -a "$found/" "$RETH_DATADIR/"
        rm -rf "$extract_dir"
      else
        log_info "Reth datadir already bootstrapped: $RETH_DATADIR"
      fi

      if [ -n "${RETH_CHAIN_SPEC_URL:-}" ] && [ ! -f "$CHAIN_SPEC_PATH" ]; then
        log_info "Downloading reth quick chainspec"
        curl -fL "$RETH_CHAIN_SPEC_URL" -o "$CHAIN_SPEC_PATH"
      fi

      if [ ! -f "$CHAIN_SPEC_PATH" ]; then
        die "Backup mode requires the matching quick chainspec. Set RETH_CHAIN_SPEC_URL or RETH_CHAIN_SPEC_PATH. The current mainnet quick chainspec is not bundled because it is large."
      fi
      RETH_CHAIN="$CHAIN_SPEC_PATH"
      ;;
    genesis)
      log_warn "Genesis mode does not use the fast reth backup and may take a long time to become useful."
      RETH_CHAIN="${RETH_CHAIN:-telos-mainnet}"
      ;;
    *)
      die "Unsupported BOOTSTRAP_MODE=$BOOTSTRAP_MODE. Use backup or genesis."
      ;;
  esac
}

generate_jwt() {
  if [ -f "$JWT_PATH" ]; then
    log_info "JWT already exists"
    return
  fi

  log_info "Generating Engine API JWT"
  openssl rand -hex 32 > "$JWT_PATH"
  chmod 600 "$JWT_PATH"
}

write_reth_env_and_launcher() {
  cat > "$RETH_ENV" << EOF
TELOS_GENESIS_STATE_ROOT=$TELOS_GENESIS_STATE_ROOT
RETH_BIN=$RETH_SRC_DIR/target/release/telos-reth
RETH_CHAIN=$RETH_CHAIN
RETH_DATADIR=$RETH_DATADIR
RETH_HTTP_ADDR=$RETH_HTTP_ADDR
RETH_RPC_PORT=$RETH_RPC_PORT
RETH_WS_ADDR=$RETH_WS_ADDR
RETH_WS_PORT=$RETH_WS_PORT
RETH_AUTH_ADDR=$RETH_AUTH_ADDR
RETH_AUTH_RPC_PORT=$RETH_AUTH_RPC_PORT
RETH_DISCOVERY_PORT=$RETH_DISCOVERY_PORT
RETH_METRICS_ADDR=$RETH_METRICS_ADDR
RETH_METRICS_PORT=$RETH_METRICS_PORT
RETH_PERSISTENCE_THRESHOLD=$RETH_PERSISTENCE_THRESHOLD
RETH_PERSISTENCE_BACKPRESSURE_THRESHOLD=$RETH_PERSISTENCE_BACKPRESSURE_THRESHOLD
RETH_MEMORY_BLOCK_BUFFER_TARGET=$RETH_MEMORY_BLOCK_BUFFER_TARGET
TELOS_ENDPOINT=http://127.0.0.1:$NODEOS_HTTP_RPC_PORT
SIGNER_ACCOUNT=$SIGNER_ACCOUNT
SIGNER_PERMISSION=$SIGNER_PERMISSION
SIGNER_KEY=$SIGNER_KEY
EOF
  chmod 600 "$RETH_ENV"

  cat > "$BIN_DIR/telos-reth-v2.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${RETH_BIN:?missing RETH_BIN}"
: "${RETH_CHAIN:?missing RETH_CHAIN}"
: "${RETH_DATADIR:?missing RETH_DATADIR}"
: "${SIGNER_KEY:?missing SIGNER_KEY}"

JWT="$RETH_DATADIR/jwt.hex"
[ -f "$JWT" ] || { echo "missing JWT at $JWT" >&2; exit 2; }

exec "$RETH_BIN" node \
  --chain "$RETH_CHAIN" \
  --datadir "$RETH_DATADIR" \
  --http --http.addr "$RETH_HTTP_ADDR" --http.port "$RETH_RPC_PORT" --http.api all \
  --ws --ws.addr "$RETH_WS_ADDR" --ws.port "$RETH_WS_PORT" --ws.api all \
  --authrpc.addr "$RETH_AUTH_ADDR" --authrpc.port "$RETH_AUTH_RPC_PORT" \
  --authrpc.jwtsecret "$JWT" \
  --ipcpath "$RETH_DATADIR/reth.ipc" \
  --port "$RETH_DISCOVERY_PORT" --discovery.port "$RETH_DISCOVERY_PORT" \
  --metrics "$RETH_METRICS_ADDR:$RETH_METRICS_PORT" \
  --engine.persistence-threshold "$RETH_PERSISTENCE_THRESHOLD" \
  --engine.persistence-backpressure-threshold "$RETH_PERSISTENCE_BACKPRESSURE_THRESHOLD" \
  --engine.memory-block-buffer-target "$RETH_MEMORY_BLOCK_BUFFER_TARGET" \
  --telos.telos_endpoint "$TELOS_ENDPOINT" \
  --telos.signer_account "$SIGNER_ACCOUNT" \
  --telos.signer_permission "$SIGNER_PERMISSION" \
  --telos.signer_key "$SIGNER_KEY" \
  --telos.trust_consensus true \
  --telos.build_state
EOF
  chmod +x "$BIN_DIR/telos-reth-v2.sh"
}

write_systemd_units() {
  log_info "Writing systemd units"

  sudo_cmd tee /etc/systemd/system/telos-evm3-nodeos-http.service >/dev/null << EOF
[Unit]
Description=TelosEVM 3.0 nodeos HTTP
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR/nodeos-http
ExecStart=$BIN_DIR/nodeos-http.sh
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=append:$LOG_DIR/nodeos-http.log
StandardError=append:$LOG_DIR/nodeos-http.log

[Install]
WantedBy=multi-user.target
EOF

  sudo_cmd tee /etc/systemd/system/telos-evm3-nodeos-ship.service >/dev/null << EOF
[Unit]
Description=TelosEVM 3.0 nodeos SHIP
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR/nodeos-ship
ExecStart=$BIN_DIR/nodeos-ship.sh
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=append:$LOG_DIR/nodeos-ship.log
StandardError=append:$LOG_DIR/nodeos-ship.log

[Install]
WantedBy=multi-user.target
EOF

  sudo_cmd tee /etc/systemd/system/telos-evm3-reth.service >/dev/null << EOF
[Unit]
Description=TelosEVM 3.0 reth v2
After=network-online.target telos-evm3-nodeos-http.service
Wants=network-online.target telos-evm3-nodeos-http.service

[Service]
Type=simple
EnvironmentFile=$RETH_ENV
WorkingDirectory=$RETH_SRC_DIR
ExecStart=$BIN_DIR/telos-reth-v2.sh
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=append:$LOG_DIR/reth.log
StandardError=append:$LOG_DIR/reth.log

[Install]
WantedBy=multi-user.target
EOF

  sudo_cmd tee /etc/systemd/system/telos-evm3-consensus.service >/dev/null << EOF
[Unit]
Description=TelosEVM 3.0 consensus client
After=network-online.target telos-evm3-nodeos-ship.service telos-evm3-reth.service
Wants=network-online.target telos-evm3-nodeos-ship.service telos-evm3-reth.service

[Service]
Type=simple
WorkingDirectory=$CONSENSUS_SRC_DIR
ExecStart=$CONSENSUS_SRC_DIR/target/release/telos-consensus-client --config $CONSENSUS_CONFIG
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=append:$LOG_DIR/consensus.log
StandardError=append:$LOG_DIR/consensus.log

[Install]
WantedBy=multi-user.target
EOF

  sudo_cmd systemctl daemon-reload
}

setup_logrotate() {
  sudo_cmd tee /etc/logrotate.d/telos-evm3 >/dev/null << EOF
$LOG_DIR/*.log {
  daily
  rotate 7
  compress
  missingok
  notifempty
  copytruncate
  create 0644 root root
}
EOF
}

json_rpc() {
  local url="$1"
  local method="$2"
  local params="${3:-[]}"
  curl -fsS --max-time 5 -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" "$url"
}

wait_for_nodeos() {
  local url="http://127.0.0.1:$NODEOS_HTTP_RPC_PORT/v1/chain/get_info"
  local i
  for i in $(seq 1 120); do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      log_info "nodeos HTTP is responding"
      return
    fi
    sleep 2
  done
  die "nodeos HTTP did not become ready at $url"
}

wait_for_reth() {
  local url="http://127.0.0.1:$RETH_RPC_PORT"
  local i
  for i in $(seq 1 120); do
    if json_rpc "$url" eth_chainId >/dev/null 2>&1; then
      log_info "reth RPC is responding"
      return
    fi
    sleep 2
  done
  die "reth RPC did not become ready at $url"
}

fetch_reth_start_point() {
  local url="http://127.0.0.1:$RETH_RPC_PORT"
  local block
  block="$(json_rpc "$url" eth_getBlockByNumber '["finalized",false]' || true)"
  if ! echo "$block" | jq -e '.result.number and .result.parentHash' >/dev/null 2>&1; then
    block="$(json_rpc "$url" eth_getBlockByNumber '["latest",false]')"
  fi

  RETH_START_BLOCK_HEX="$(echo "$block" | jq -r '.result.number')"
  RETH_START_BLOCK=$((RETH_START_BLOCK_HEX))
  RETH_START_PARENT_HASH="$(echo "$block" | jq -r '.result.parentHash')"
  [ -n "$RETH_START_PARENT_HASH" ] && [ "$RETH_START_PARENT_HASH" != "null" ] || die "Could not fetch reth parent hash"
  log_info "Consensus start point: EVM block $RETH_START_BLOCK parent $RETH_START_PARENT_HASH"
}

toml_array_from_csv() {
  local csv="$1"
  local out="["
  local first=1
  local item
  IFS=',' read -ra items <<< "$csv"
  for item in "${items[@]}"; do
    item="$(echo "$item" | xargs)"
    [ -n "$item" ] || continue
    if [ "$first" -eq 0 ]; then
      out+=", "
    fi
    out+="\"$item\""
    first=0
  done
  out+="]"
  echo "$out"
}

write_consensus_config() {
  local jwt
  local rpc_array
  jwt="$(cat "$JWT_PATH")"
  rpc_array="$(toml_array_from_csv "$CANONICAL_RPCS")"

  cat > "$CONSENSUS_CONFIG" << EOF
log_level = "info"
chain_id = $CHAIN_ID

execution_endpoint = "http://127.0.0.1:$RETH_AUTH_RPC_PORT"
jwt_secret = "$jwt"

ship_endpoint = "ws://127.0.0.1:$NODEOS_SHIP_WS_PORT"
chain_endpoint = "http://127.0.0.1:$NODEOS_HTTP_RPC_PORT"

evm_start_block = $RETH_START_BLOCK
evm_deploy_block = $EVM_DEPLOY_BLOCK
prev_hash = "$RETH_START_PARENT_HASH"

batch_size = $BATCH_SIZE
data_path = "$CONSENSUS_DATA_DIR/db"
block_checkpoint_interval = $BLOCK_CHECKPOINT_INTERVAL
maximum_sync_range = $MAXIMUM_SYNC_RANGE
latest_blocks_in_db_num = $LATEST_BLOCKS_IN_DB_NUM

rpc_fallback_endpoints = $rpc_array
rpc_fallback_quorum = $RPC_FALLBACK_QUORUM
rpc_fallback_retry_interval_secs = $RPC_FALLBACK_RETRY_INTERVAL_SECS
rpc_fallback_sample_every_n = $RPC_FALLBACK_SAMPLE_EVERY_N

raw_message_channel_size = 5000
block_message_channel_size = 5000
final_message_channel_size = 5000
EOF
  chmod 600 "$CONSENSUS_CONFIG"
}

write_healthcheck() {
  cat > "$BIN_DIR/healthcheck.sh" << EOF
#!/usr/bin/env bash
set -euo pipefail
LOCAL_RPC="http://127.0.0.1:$RETH_RPC_PORT"
PUBLIC_RPC="\${PUBLIC_RPC:-$(echo "$CANONICAL_RPCS" | cut -d, -f1)}"

rpc_block() {
  curl -fsS --max-time 5 -H 'content-type: application/json' \\
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "\$1" \\
    | jq -r '.result' | xargs printf "%d\\n"
}

local_block="\$(rpc_block "\$LOCAL_RPC")"
public_block="\$(rpc_block "\$PUBLIC_RPC")"
lag=\$((public_block - local_block))
echo "local_block=\$local_block public_block=\$public_block lag=\$lag"
systemctl --no-pager --plain is-active telos-evm3-reth telos-evm3-consensus telos-evm3-nodeos-http telos-evm3-nodeos-ship
ps -C telos-reth -o pid,pcpu,rss,etime,cmd || true
ps -C telos-consensus-client -o pid,pcpu,rss,etime,cmd || true
EOF
  chmod +x "$BIN_DIR/healthcheck.sh"
}

verify_signer_key() {
  log_info "Verifying configured rpc.evm@rpc signer key"
  if [ "$SIGNER_KEY" != "$MAINNET_SIGNER_KEY_DEFAULT" ]; then
    log_warn "Custom SIGNER_KEY configured. Reth will perform its own on-chain authority preflight."
    return
  fi
  log_info "Default signer key derives to $MAINNET_SIGNER_PUBLIC_KEY, the current mainnet rpc.evm@rpc key."
}

start_services() {
  if [ "$SKIP_START" = "1" ]; then
    log_warn "SKIP_START=1 set; services were installed but not started."
    return
  fi

  log_info "Starting nodeos services"
  sudo_cmd systemctl enable --now telos-evm3-nodeos-http telos-evm3-nodeos-ship
  wait_for_nodeos

  log_info "Starting reth"
  sudo_cmd systemctl enable --now telos-evm3-reth
  wait_for_reth

  fetch_reth_start_point
  write_consensus_config

  log_info "Starting consensus client"
  sudo_cmd systemctl enable --now telos-evm3-consensus
}

print_summary() {
  cat << EOF

TelosEVM 3.0 installer finished.

Install dir:        $INSTALL_DIR
Reth repo/ref:      $RETH_REPO @ $RETH_REF
Consensus repo/ref: $CONSENSUS_REPO @ $CONSENSUS_REF
Reth RPC:           http://$RETH_HTTP_ADDR:$RETH_RPC_PORT
Reth WS:            ws://$RETH_WS_ADDR:$RETH_WS_PORT
Reth Auth RPC:      http://127.0.0.1:$RETH_AUTH_RPC_PORT
Nodeos HTTP:        http://127.0.0.1:$NODEOS_HTTP_RPC_PORT
Nodeos SHIP:        ws://127.0.0.1:$NODEOS_SHIP_WS_PORT
Canonical RPCs:     $CANONICAL_RPCS
Canonical quorum:   $RPC_FALLBACK_QUORUM

Useful commands:
  systemctl status telos-evm3-reth telos-evm3-consensus
  journalctl -u telos-evm3-reth -f
  journalctl -u telos-evm3-consensus -f
  $BIN_DIR/healthcheck.sh

EOF
}

main() {
  parse_args "${1:-}"
  set_defaults
  collect_inputs
  prepare_dirs
  install_dependencies
  install_rust
  install_nodeos
  download_nodeos_snapshot
  write_nodeos_config
  write_nodeos_launchers
  build_clients
  bootstrap_reth_data
  generate_jwt
  verify_signer_key
  write_reth_env_and_launcher
  write_systemd_units
  setup_logrotate
  write_healthcheck
  start_services
  print_summary
}

main "$@"
