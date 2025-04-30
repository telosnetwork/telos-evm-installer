#!/usr/bin/env bash

# manage-services.sh: stop or start Telos services in order
# Usage: manage-services.sh <stop|start> [<main_dir>]
#   stop:  stops telos-consensus-client then telos-reth
#   start: starts telos-reth then telos-consensus-client
#   main_dir: root of services (default: /data/telos-evm-installer/telos)

set -euo pipefail

# Default main directory
MAIN_DIR=${2:-/data/telos-evm-installer/telos}
ACTION=${1:-}

log_info() {
  echo "[INFO] $1"
}

usage() {
  echo "Usage: $0 <stop|start> [<main_dir>]"
  exit 1
}

# Verify action
if [[ "$ACTION" != "stop" && "$ACTION" != "start" ]]; then
  log_info "Invalid action: '$ACTION'"
  usage
fi

# Paths to service scripts
CONSENSUS_DIR="$MAIN_DIR/telos-consensus-client"
RETH_DIR="$MAIN_DIR/telos-reth"

log_info "Using main directory: $MAIN_DIR"

case "$ACTION" in
  stop)
    log_info "Stopping Telos Consensus Client..."
    bash "$CONSENSUS_DIR/stop.sh"
    log_info "Stopping Telos Reth..."
    bash "$RETH_DIR/stop.sh"
    log_info "All services stopped."
    ;;

  start)
    log_info "Starting Telos Reth..."
    bash "$RETH_DIR/start.sh"
    log_info "Starting Telos Consensus Client..."
    bash "$CONSENSUS_DIR/start.sh"
    log_info "All services started."
    ;;

  *)
    usage
    ;;
 esac
