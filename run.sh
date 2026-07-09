#!/bin/bash

# Set strict error handling
set -euo pipefail

RELEASE_TAG="telos-v1.0.1"

TELOSZERO_CORE_VERSION="1.2.2"
TELOSZERO_CORE_RELEASE_TAG="teloszero-v$TELOSZERO_CORE_VERSION"
TELOSZERO_CORE_DEB="teloszero-core_${TELOSZERO_CORE_VERSION}_amd64.deb"
TELOSZERO_CORE_DEB_URL="https://github.com/telosnetwork/teloszero-core/releases/download/$TELOSZERO_CORE_RELEASE_TAG/$TELOSZERO_CORE_DEB"
TELOSZERO_CORE_DEB_SHA256="285fdfc1abde5104892d94b1f380c6d79aba35eac3413f139119ea88574c5007"
TELOSZERO_CORE_PACKAGE="teloszero-core"
CONFLICTING_NODEOS_PACKAGES=(eosio mandel leap spring antelope-spring)
STORAGE_BASE_URL="${STORAGE_BASE_URL:-https://storage.telos.net/evm_backups/mainnet}"
NODEOS_BACKUP_BASE_URL="${NODEOS_BACKUP_BASE_URL:-$STORAGE_BASE_URL}"
RETH_BACKUP_BASE_URL="${RETH_BACKUP_BASE_URL:-$STORAGE_BASE_URL/telos-evm-2}"
SHIP_ARCHIVE_BASE_URL="${SHIP_ARCHIVE_BASE_URL:-$STORAGE_BASE_URL/mainnet-ship}"
NATIVE_RPC_URL="${NATIVE_RPC_URL:-https://mainnet.telos.net}"
EVM_RPC_URL="${EVM_RPC_URL:-https://rpc.telos.net/evm}"
MAX_BACKUP_STALENESS_BLOCKS="${MAX_BACKUP_STALENESS_BLOCKS:-345600}" # 2 days at 0.5s blocks
ALLOW_STALE_BACKUPS="${ALLOW_STALE_BACKUPS:-false}"
SKIP_BACKUP_FRESHNESS_CHECK="${SKIP_BACKUP_FRESHNESS_CHECK:-false}"
EXPECTED_RETH_VERSION="${EXPECTED_RETH_VERSION:-1.0.8}"
SKIP_RETH_BACKUP_COMPATIBILITY_CHECK="${SKIP_RETH_BACKUP_COMPATIBILITY_CHECK:-false}"
NODEOS_SYNC_TIMEOUT_SECONDS="${NODEOS_SYNC_TIMEOUT_SECONDS:-0}"
RETH_VERIFY_TIMEOUT_SECONDS="${RETH_VERIFY_TIMEOUT_SECONDS:-300}"
FAST_REQUIRED_GIB="${FAST_REQUIRED_GIB:-500}"
ARCHIVE_REQUIRED_GIB="${ARCHIVE_REQUIRED_GIB:-3800}"
if [[ -n "${TELOS_BOOTSTRAP_MODE:-}" ]]; then
    BOOTSTRAP_MODE_EXPLICIT=true
else
    BOOTSTRAP_MODE_EXPLICIT=false
    TELOS_BOOTSTRAP_MODE="fast"
fi
LOCAL_DEBUGGING=true

# Global array to keep track of selected ports
SELECTED_PORTS=()
NODEOS_SNAPSHOT_ARTIFACT=""
NODEOS_SNAPSHOT_URL=""
NODEOS_SNAPSHOT_HEIGHT=""
RETH_BACKUP_ARTIFACT=""
RETH_BACKUP_URL=""
RETH_BACKUP_MANIFEST_URL=""
RETH_BACKUP_SHA_URL=""
RETH_BACKUP_HEIGHT=""
RETH_BACKUP_HASH=""
RETH_BACKUP_SHA256=""
RETH_BACKUP_SOURCE_DATADIR=""
RETH_BACKUP_BINARY=""
RETH_BACKUP_BINARY_VERSION=""
RETH_BACKUP_BINARY_COMMIT=""
RETH_BACKUP_CONSENSUS_BINARY=""
LIVE_NATIVE_HEAD=""

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

usage() {
    cat << EOF
Usage: $0 [--bootstrap-mode fast|archive] [--allow-stale-backups]

Bootstrap modes:
  fast     Use a nodeos state snapshot plus the reth backup. Native nodeos block
           history starts at the snapshot block. This is the default.
  archive  Also restore native block logs and state-history from mainnet-ship.
           This requires multiple TiB of disk and a long transfer.

Environment overrides:
  MAX_BACKUP_STALENESS_BLOCKS=$MAX_BACKUP_STALENESS_BLOCKS
  ALLOW_STALE_BACKUPS=$ALLOW_STALE_BACKUPS
  NODEOS_BACKUP_BASE_URL=$NODEOS_BACKUP_BASE_URL
  RETH_BACKUP_BASE_URL=$RETH_BACKUP_BASE_URL
  SHIP_ARCHIVE_BASE_URL=$SHIP_ARCHIVE_BASE_URL
  EXPECTED_RETH_VERSION=$EXPECTED_RETH_VERSION
  SKIP_RETH_BACKUP_COMPATIBILITY_CHECK=$SKIP_RETH_BACKUP_COMPATIBILITY_CHECK
  NODEOS_SYNC_TIMEOUT_SECONDS=$NODEOS_SYNC_TIMEOUT_SECONDS
  RETH_VERIFY_TIMEOUT_SECONDS=$RETH_VERIFY_TIMEOUT_SECONDS
  FAST_REQUIRED_GIB=$FAST_REQUIRED_GIB
  ARCHIVE_REQUIRED_GIB=$ARCHIVE_REQUIRED_GIB
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bootstrap-mode)
                if [[ $# -lt 2 ]]; then
                    log_error "--bootstrap-mode requires fast or archive"
                    exit 1
                fi
                TELOS_BOOTSTRAP_MODE="$2"
                BOOTSTRAP_MODE_EXPLICIT=true
                shift 2
                ;;
            --allow-stale-backups)
                ALLOW_STALE_BACKUPS=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    case "$TELOS_BOOTSTRAP_MODE" in
        fast|archive) ;;
        *)
            log_error "Invalid bootstrap mode '$TELOS_BOOTSTRAP_MODE'. Use fast or archive."
            exit 1
            ;;
    esac
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

bool_is_true() {
    case "${1:-}" in
        true|TRUE|yes|YES|1) return 0 ;;
        *) return 1 ;;
    esac
}

download_url() {
    local url="$1"
    local output="$2"
    local remote_size=""
    local local_size=""

    remote_size=$(curl -fsSIL "$url" | awk 'tolower($1) == "content-length:" {value=$2} END {gsub(/\r/, "", value); print value}' || true)
    if [[ -f "$output" && "$remote_size" =~ ^[0-9]+$ ]]; then
        local_size=$(wc -c < "$output" | tr -d ' ')
        if (( local_size == remote_size )); then
            log_info "$output already exists and matches remote size; skipping download"
            return
        fi

        if (( local_size > remote_size )); then
            log_warning "$output is larger than the remote artifact; removing local file and downloading again"
            rm "$output"
        fi
    fi

    curl -L --fail --retry 3 --retry-delay 2 --continue-at - "$url" --output "$output"
}

download_fresh_url() {
    local url="$1"
    local output="$2"
    curl -L --fail --retry 3 --retry-delay 2 "$url" --output "$output"
}

file_sha256() {
    sha256sum "$1" | awk '{print $1}'
}

read_manifest_value() {
    local key="$1"
    local file="$2"
    awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' "$file"
}

parse_reth_binary_version() {
    local binary="$1"
    local version
    version="$(echo "$binary" | sed -nE 's/.*[Rr]eth Version: *([^;[:space:]]+).*/\1/p')"
    if [[ -z "$version" ]]; then
        version="$(echo "$binary" | sed -nE 's#.*[Rr]eth/v([^/[:space:]]+).*#\1#p')"
    fi
    echo "$version"
}

parse_reth_binary_commit() {
    local binary="$1"
    echo "$binary" | sed -nE 's/.*Commit SHA: *([^;]+).*/\1/p'
}

normalize_version() {
    local version="$1"
    version="${version#v}"
    version="${version%%-*}"
    echo "$version"
}

fetch_native_head() {
    curl -fsS "$NATIVE_RPC_URL/v1/chain/get_info" | jq -r '.head_block_num'
}

discover_latest_artifact() {
    local base_url="$1"
    local pattern="$2"
    local listing

    if ! listing="$(curl -fsSL "$base_url/" 2>/dev/null)"; then
        return 0
    fi

    echo "$listing" | grep -oE "href=\"$pattern\"" | sed -E 's/^href="([^"]+)"/\1/' | sort | tail -1
}

artifact_url() {
    local base_url="$1"
    local artifact="$2"
    echo "$base_url/$artifact"
}

normalize_path() {
    local path="$1"

    if realpath -m "$path" >/dev/null 2>&1; then
        realpath -m "$path"
    elif [[ "$path" == /* ]]; then
        echo "$path"
    else
        echo "$(pwd)/$path"
    fi
}

extract_snapshot_height() {
    local artifact="$1"
    local height
    height=$(echo "$artifact" | sed -nE 's/.*-([0-9]{10})\.bin\.zst$/\1/p')
    if [[ -n "$height" ]]; then
        echo "$((10#$height))"
    fi
}

dpkg_installed_version() {
    local package="$1"
    local query_output
    query_output=$(dpkg-query -W -f='${Status} ${Version}' "$package" 2>/dev/null || true)

    if [[ "$query_output" == install\ ok\ installed* ]]; then
        echo "${query_output##* }"
    fi
}

download_teloszero_core_package() {
    log_info "Downloading TelosZero Core $TELOSZERO_CORE_VERSION..."
    curl -L --fail --retry 3 --retry-delay 2 "$TELOSZERO_CORE_DEB_URL" --output "$TELOSZERO_CORE_DEB"
}

verify_teloszero_core_package() {
    log_info "Verifying TelosZero Core package checksum..."
    if ! echo "$TELOSZERO_CORE_DEB_SHA256  $TELOSZERO_CORE_DEB" | sha256sum -c - >/dev/null; then
        log_error "Checksum verification failed for $TELOSZERO_CORE_DEB"
        exit 1
    fi
}

remove_conflicting_nodeos_packages() {
    local installed_conflicts=()
    local package

    for package in "${CONFLICTING_NODEOS_PACKAGES[@]}"; do
        if [[ -n "$(dpkg_installed_version "$package")" ]]; then
            installed_conflicts+=("$package")
        fi
    done

    if (( ${#installed_conflicts[@]} > 0 )); then
        log_info "Removing conflicting nodeos packages: ${installed_conflicts[*]}"
        DEBIAN_FRONTEND=noninteractive sudo apt-get remove -y "${installed_conflicts[@]}"
    fi
}

load_backup_metadata() {
    log_info "Discovering latest Telos EVM backup metadata..."

    NODEOS_SNAPSHOT_ARTIFACT="$(discover_latest_artifact "$NODEOS_BACKUP_BASE_URL" 'snapshot-[^"]+\.bin\.zst')"
    if [[ -z "$NODEOS_SNAPSHOT_ARTIFACT" ]]; then
        log_error "Could not discover a nodeos snapshot artifact from $NODEOS_BACKUP_BASE_URL"
        exit 1
    fi
    NODEOS_SNAPSHOT_URL="$(artifact_url "$NODEOS_BACKUP_BASE_URL" "$NODEOS_SNAPSHOT_ARTIFACT")"
    NODEOS_SNAPSHOT_HEIGHT="$(extract_snapshot_height "$NODEOS_SNAPSHOT_ARTIFACT")"

    local reth_manifest_artifact
    reth_manifest_artifact="$(discover_latest_artifact "$RETH_BACKUP_BASE_URL" 'reth-data-[^"]+\.tar\.zst\.manifest\.txt')"
    if [[ -z "$reth_manifest_artifact" ]]; then
        log_error "Could not discover a Telos EVM 2 reth backup manifest from $RETH_BACKUP_BASE_URL"
        log_error "Publish a Reth $EXPECTED_RETH_VERSION-compatible reth-data-*.tar.zst plus .manifest.txt and .sha256 into that folder."
        exit 1
    fi

    RETH_BACKUP_MANIFEST_URL="$(artifact_url "$RETH_BACKUP_BASE_URL" "$reth_manifest_artifact")"
    RETH_BACKUP_ARTIFACT="${reth_manifest_artifact%.manifest.txt}"
    RETH_BACKUP_URL="$(artifact_url "$RETH_BACKUP_BASE_URL" "$RETH_BACKUP_ARTIFACT")"
    RETH_BACKUP_SHA_URL="$(artifact_url "$RETH_BACKUP_BASE_URL" "$RETH_BACKUP_ARTIFACT.sha256")"

    mkdir -p "$INSTALL_DIR/manifests"
    download_fresh_url "$RETH_BACKUP_MANIFEST_URL" "$INSTALL_DIR/manifests/$reth_manifest_artifact"
    if download_fresh_url "$RETH_BACKUP_SHA_URL" "$INSTALL_DIR/manifests/$RETH_BACKUP_ARTIFACT.sha256"; then
        RETH_BACKUP_SHA256="$(awk '{print $1; exit}' "$INSTALL_DIR/manifests/$RETH_BACKUP_ARTIFACT.sha256")"
    else
        log_warning "No checksum file found for $RETH_BACKUP_ARTIFACT"
    fi

    RETH_BACKUP_HEIGHT="$(read_manifest_value height "$INSTALL_DIR/manifests/$reth_manifest_artifact")"
    RETH_BACKUP_HASH="$(read_manifest_value hash "$INSTALL_DIR/manifests/$reth_manifest_artifact")"
    RETH_BACKUP_SOURCE_DATADIR="$(read_manifest_value source_datadir "$INSTALL_DIR/manifests/$reth_manifest_artifact")"
    RETH_BACKUP_BINARY="$(read_manifest_value reth_binary "$INSTALL_DIR/manifests/$reth_manifest_artifact")"
    RETH_BACKUP_BINARY_VERSION="$(parse_reth_binary_version "$RETH_BACKUP_BINARY")"
    RETH_BACKUP_BINARY_COMMIT="$(parse_reth_binary_commit "$RETH_BACKUP_BINARY")"
    RETH_BACKUP_CONSENSUS_BINARY="$(read_manifest_value consensus_binary "$INSTALL_DIR/manifests/$reth_manifest_artifact")"

    if [[ -z "$RETH_BACKUP_HEIGHT" ]]; then
        log_error "Reth backup manifest does not include a height"
        exit 1
    fi

    log_info "Nodeos snapshot: $NODEOS_SNAPSHOT_ARTIFACT${NODEOS_SNAPSHOT_HEIGHT:+ at block $NODEOS_SNAPSHOT_HEIGHT}"
    log_info "Reth backup: $RETH_BACKUP_ARTIFACT at block $RETH_BACKUP_HEIGHT"
    log_info "Reth backup binary: ${RETH_BACKUP_BINARY_VERSION:-unknown}${RETH_BACKUP_BINARY_COMMIT:+, commit $RETH_BACKUP_BINARY_COMMIT}"
}

validate_reth_backup_compatibility() {
    if bool_is_true "$SKIP_RETH_BACKUP_COMPATIBILITY_CHECK"; then
        log_warning "Skipping reth backup binary compatibility check"
        return
    fi

    case "$EXPECTED_RETH_VERSION" in
        any|ANY)
            log_warning "EXPECTED_RETH_VERSION=$EXPECTED_RETH_VERSION disables exact reth backup binary compatibility checks"
            return
            ;;
    esac

    if [[ -z "$RETH_BACKUP_BINARY" ]]; then
        log_error "Reth backup manifest does not include reth_binary, so compatibility cannot be verified."
        log_error "Use a manifest that records the producer binary, or set SKIP_RETH_BACKUP_COMPATIBILITY_CHECK=true only after verifying datadir compatibility."
        exit 1
    fi

    if [[ -z "$RETH_BACKUP_BINARY_VERSION" ]]; then
        log_error "Could not parse Reth version from manifest reth_binary: $RETH_BACKUP_BINARY"
        log_error "Set SKIP_RETH_BACKUP_COMPATIBILITY_CHECK=true only after verifying datadir compatibility."
        exit 1
    fi

    local actual_version
    local expected_version
    local actual_major
    local expected_major
    actual_version="$(normalize_version "$RETH_BACKUP_BINARY_VERSION")"
    expected_version="$(normalize_version "$EXPECTED_RETH_VERSION")"

    if [[ "$actual_version" == "$expected_version" ]]; then
        log_info "Reth backup compatibility validated: manifest Reth $actual_version matches expected Reth $expected_version"
        return
    fi

    actual_major="${actual_version%%.*}"
    expected_major="${expected_version%%.*}"

    log_error "Reth backup binary mismatch."
    log_error "Backup manifest reports Reth $actual_version${RETH_BACKUP_BINARY_COMMIT:+, commit $RETH_BACKUP_BINARY_COMMIT}."
    log_error "Installer expects Reth $expected_version for telos-reth RELEASE_TAG=$RELEASE_TAG."
    if [[ -n "$RETH_BACKUP_SOURCE_DATADIR" ]]; then
        log_error "Backup source datadir: $RETH_BACKUP_SOURCE_DATADIR"
    fi
    if [[ "$actual_major" != "$expected_major" ]]; then
        log_error "Reth datadirs are not safe to restore across major versions; do not restore a Reth $actual_major.x backup into Reth $expected_major.x."
    fi
    log_error "Use a backup generated by the matching telos-reth release, or set EXPECTED_RETH_VERSION to the version built by your selected RELEASE_TAG."
    log_error "Set SKIP_RETH_BACKUP_COMPATIBILITY_CHECK=true only after independently verifying datadir compatibility."
    exit 1
}

validate_backup_freshness() {
    if bool_is_true "$SKIP_BACKUP_FRESHNESS_CHECK"; then
        log_warning "Skipping backup freshness check"
        return
    fi

    LIVE_NATIVE_HEAD="$(fetch_native_head)"
    if [[ -z "$LIVE_NATIVE_HEAD" || "$LIVE_NATIVE_HEAD" == "null" ]]; then
        log_error "Could not fetch live Telos mainnet head from $NATIVE_RPC_URL"
        log_error "Set SKIP_BACKUP_FRESHNESS_CHECK=true only if you intentionally want to bypass this check."
        exit 1
    fi

    local lag=$((LIVE_NATIVE_HEAD - RETH_BACKUP_HEIGHT))
    if (( lag < 0 )); then
        log_warning "Reth backup height $RETH_BACKUP_HEIGHT is ahead of live head $LIVE_NATIVE_HEAD; continuing."
        return
    fi

    log_info "Live native head: $LIVE_NATIVE_HEAD; reth backup lag: $lag blocks"
    if (( lag > MAX_BACKUP_STALENESS_BLOCKS )); then
        local approx_days
        approx_days=$(awk "BEGIN { printf \"%.1f\", $lag / 172800 }")
        if bool_is_true "$ALLOW_STALE_BACKUPS"; then
            log_warning "Backup is stale by $lag blocks (~$approx_days days), continuing because ALLOW_STALE_BACKUPS=true"
        else
            log_error "Backup is stale by $lag blocks (~$approx_days days), exceeding MAX_BACKUP_STALENESS_BLOCKS=$MAX_BACKUP_STALENESS_BLOCKS"
            log_error "Refresh the backup or rerun with --allow-stale-backups / ALLOW_STALE_BACKUPS=true."
            exit 1
        fi
    fi
}

verify_reth_backup_checksum() {
    local backup_path="$INSTALL_DIR/$RETH_BACKUP_ARTIFACT"

    if [[ -z "$RETH_BACKUP_SHA256" ]]; then
        log_warning "No reth backup checksum available; skipping checksum verification"
        return
    fi

    log_info "Verifying reth backup checksum..."
    local actual_sha
    actual_sha="$(file_sha256 "$backup_path")"
    if [[ "$actual_sha" != "$RETH_BACKUP_SHA256" ]]; then
        log_error "Checksum verification failed for $RETH_BACKUP_ARTIFACT"
        log_error "Expected $RETH_BACKUP_SHA256 but got $actual_sha"
        exit 1
    fi
}

validate_ship_archive_metadata() {
    if [[ "$TELOS_BOOTSTRAP_MODE" != "archive" ]]; then
        return
    fi

    log_info "Validating native SHiP archive metadata..."
    local status
    local chain_info
    local earliest_block
    local archive_head
    local updated_at

    status="$(curl -fsSL "$SHIP_ARCHIVE_BASE_URL/BACKUP-STATUS.txt")"
    chain_info="$(echo "$status" | sed -n 's/^chain_info=//p')"
    updated_at="$(echo "$status" | awk -F= '$1 == "updated_at" {print $2; exit}')"
    earliest_block="$(echo "$chain_info" | jq -r '.earliest_available_block_num')"
    archive_head="$(echo "$chain_info" | jq -r '.head_block_num')"

    if [[ "$earliest_block" != "1" ]]; then
        log_error "Native SHiP archive does not advertise block history from block 1. earliest_available_block_num=$earliest_block"
        exit 1
    fi

    log_info "Native SHiP archive validated: earliest block $earliest_block, head $archive_head, updated $updated_at"
}

check_disk_space() {
    local required_gib="$FAST_REQUIRED_GIB"
    local override_name="FAST_REQUIRED_GIB"
    local available_kib
    local available_gib

    if [[ "$TELOS_BOOTSTRAP_MODE" == "archive" ]]; then
        required_gib="$ARCHIVE_REQUIRED_GIB"
        override_name="ARCHIVE_REQUIRED_GIB"
    fi

    available_kib=$(df -Pk "$INSTALL_DIR" | awk 'NR == 2 {print $4}')
    available_gib=$((available_kib / 1024 / 1024))

    log_info "Available disk at $INSTALL_DIR: ${available_gib} GiB; required for $TELOS_BOOTSTRAP_MODE mode: ${required_gib} GiB"
    if (( available_gib < required_gib )); then
        log_error "Not enough free disk space for $TELOS_BOOTSTRAP_MODE mode."
        log_error "Use a larger install directory or override $override_name only if you have verified the sizing."
        exit 1
    fi
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
    if (( ${#SELECTED_PORTS[@]} > 0 )); then
      for port in "${SELECTED_PORTS[@]}"; do
        if [[ "$port" == "$selected_port" ]]; then
          log_info "Port $selected_port has already been selected in this process. Please choose another."
          continue 2  # Skip to the next iteration of the outer while loop
        fi
      done
    fi

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
  log_info "Please provide the following values to setup the Telos node"
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

  if ! bool_is_true "$BOOTSTRAP_MODE_EXPLICIT"; then
      read -p "Bootstrap mode: fast or archive (default: $TELOS_BOOTSTRAP_MODE): " USER_BOOTSTRAP_MODE
      if [ -n "$USER_BOOTSTRAP_MODE" ]; then
          TELOS_BOOTSTRAP_MODE="$USER_BOOTSTRAP_MODE"
      fi
  fi
  case "$TELOS_BOOTSTRAP_MODE" in
    fast)
      log_info "Fast mode selected: nodeos will start from a state snapshot, so native nodeos block history starts at the snapshot block."
      ;;
    archive)
      log_warning "Archive mode selected: this restores native block logs and SHiP state-history and can require more than 3 TiB."
      read -p "Type yes to continue with archive mode: " ARCHIVE_CONFIRM
      if [[ "$ARCHIVE_CONFIRM" != "yes" ]]; then
          log_error "Archive mode was not confirmed"
          exit 1
      fi
      ;;
    *)
      log_error "Invalid bootstrap mode '$TELOS_BOOTSTRAP_MODE'. Use fast or archive."
      exit 1
      ;;
  esac

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
    PEERS_URL="https://raw.githubusercontent.com/telosnetwork/telos-evm-installer/refs/heads/main/nodeos-peers/eastern-peers.txt"
  fi

  NODEOS_HTTP_RPC_PORT=$(check_and_set_port "Enter the RPC port for http nodeos" 8888)
  NODEOS_HTTP_P2P_PORT=$(check_and_set_port "Enter the P2P port for http nodeos" 9876)

  NODEOS_SHIP_RPC_PORT=$(check_and_set_port "Enter the RPC port for ship nodeos" 9888)
  NODEOS_SHIP_WS_SHIP_PORT=$(check_and_set_port "Enter the SHIP WS port for ship nodeos" 18999)
  NODEOS_SHIP_P2P_PORT=$(check_and_set_port "Enter the P2P port for ship nodeos" 9877)

  RETH_RPC_PORT=$(check_and_set_port "Enter the RPC port for reth (will be hosted on 0.0.0.0 for external use)" 8545)
  RETH_WS_PORT=$(check_and_set_port "Enter the WS RPC port for reth (will be hosted on 0.0.0.0 for external use)" 8546)
  RETH_AUTH_RPC_PORT=$(check_and_set_port "Enter the Auth RPC port for reth (this is where the consensus client connects via JWT, will be hosted on 127.0.0.1)" 8551)
  RETH_DISCOVERY_PORT=$(check_and_set_port "Enter the discovery port for reth (not used for discovery but reth wants to open it anyway, will be hosted on 127.0.0.1)" 30303)

  INSTALL_DIR=$(normalize_path "$INSTALL_DIR")
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
    if ! sudo apt-get update; then
        log_error "Failed to update package lists"
        exit 1
    fi

    # TODO: Avoid the prompt for timezone
    if ! DEBIAN_FRONTEND=noninteractive sudo apt-get install -y \
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
        libatomic1 \
        libcurl4 \
        libgmp10 \
        zlib1g \
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
    local installed_version
    installed_version="$(dpkg_installed_version "$TELOSZERO_CORE_PACKAGE")"

    if [[ "$installed_version" == "$TELOSZERO_CORE_VERSION" ]]; then
        log_info "TelosZero Core $TELOSZERO_CORE_VERSION is already installed"
    else
        if [[ -n "$installed_version" ]]; then
            log_info "Upgrading TelosZero Core from $installed_version to $TELOSZERO_CORE_VERSION..."
        elif command_exists nodeos; then
            log_warning "nodeos is installed, but $TELOSZERO_CORE_PACKAGE $TELOSZERO_CORE_VERSION is not. Replacing old nodeos packages with TelosZero Core."
        else
            log_info "Installing TelosZero Core $TELOSZERO_CORE_VERSION..."
        fi

        download_teloszero_core_package
        verify_teloszero_core_package
        remove_conflicting_nodeos_packages
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "./$TELOSZERO_CORE_DEB"
    fi

    installed_version="$(dpkg_installed_version "$TELOSZERO_CORE_PACKAGE")"
    if [[ "$installed_version" != "$TELOSZERO_CORE_VERSION" ]]; then
        log_error "Expected $TELOSZERO_CORE_PACKAGE $TELOSZERO_CORE_VERSION, found '${installed_version:-not installed}'"
        exit 1
    fi

    if ! command_exists nodeos; then
        log_error "TelosZero Core installation completed, but nodeos was not found on PATH"
        exit 1
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

nohup nodeos --disable-replay-opts --data-dir $DATA_DIR_PATH --blocks-log-stride 10000000 --max-retained-block-files 1 --state-history-stride 10000000 --max-retained-history-files 1 --config-dir $INSTALL_ROOT "$@" >> "$LOG_PATH" 2>&1 &
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
    if [[ ! -f "${NODEOS_SNAPSHOT_ARTIFACT%.zst}" ]]; then
        if [[ ! -f "$NODEOS_SNAPSHOT_ARTIFACT" ]]; then
            download_url "$NODEOS_SNAPSHOT_URL" "$NODEOS_SNAPSHOT_ARTIFACT"
        fi
        unzstd -f "$NODEOS_SNAPSHOT_ARTIFACT"
    else
        log_info "Nodeos snapshot already decompressed"
    fi
    cd $INSTALL_DIR
}

download_http_directory_files() {
    local source_url="$1"
    local dest_dir="$2"
    local listing
    local files
    local file

    mkdir -p "$dest_dir"
    listing="$(curl -fsSL "$source_url/")"
    files=$(echo "$listing" | grep -oE 'href="[^"]+"' | sed -E 's/^href="([^"]+)"/\1/' | grep -Ev '/$|^\.\.$|^/$' || true)

    while IFS= read -r file; do
        if [[ -z "$file" ]]; then
            continue
        fi

        log_info "Downloading $source_url/$file"
        download_url "$source_url/$file" "$dest_dir/$file"
    done <<< "$files"
}

restore_ship_archive() {
    if [[ "$TELOS_BOOTSTRAP_MODE" != "archive" ]]; then
        log_info "Fast mode selected; skipping native block/state-history archive restore"
        return
    fi

    log_info "Restoring native block logs and SHiP state-history into nodeos-ship..."
    log_info "nodeos-http remains snapshot-backed; use nodeos-ship for native historical blocks/SHiP history."
    log_warning "This may download more than 3 TiB and can take a long time."

    local ship_data_dir="$INSTALL_DIR/nodeos-ship/data"
    mkdir -p "$ship_data_dir/blocks" "$ship_data_dir/state-history/retained"

    download_http_directory_files "$SHIP_ARCHIVE_BASE_URL/backup_blocks" "$ship_data_dir/blocks"
    download_http_directory_files "$SHIP_ARCHIVE_BASE_URL/backup_state-history" "$ship_data_dir/state-history"
    download_http_directory_files "$SHIP_ARCHIVE_BASE_URL/backup_state-history/retained" "$ship_data_dir/state-history/retained"
}

# Start nodeos
start_nodeos() {
    local snapshot_path="../snapshots/${NODEOS_SNAPSHOT_ARTIFACT%.zst}"

    log_info "Starting nodeos..."
    cd $INSTALL_DIR/nodeos-http || exit 1
    bash start.sh --snapshot "$snapshot_path"
    log_info "HTTP nodeos started successfully"
    cd $INSTALL_DIR/nodeos-ship || exit 1
    bash start.sh --snapshot "$snapshot_path"
    log_info "SHIP nodeos started successfully"
    cd $INSTALL_DIR
}

fetch_local_nodeos_head() {
    curl -fsS "http://127.0.0.1:$NODEOS_HTTP_RPC_PORT/v1/chain/get_info" | jq -r '.head_block_num'
}

wait_for_nodeos_height() {
    local target_height="$1"
    local start_time=$SECONDS
    local head=""

    if [[ -z "$target_height" ]]; then
        log_warning "No target nodeos height was supplied; skipping nodeos catch-up wait"
        return
    fi

    log_info "Waiting for nodeos to reach reth backup height $target_height..."
    while true; do
        head="$(fetch_local_nodeos_head 2>/dev/null || true)"
        if [[ "$head" =~ ^[0-9]+$ ]] && (( head >= target_height )); then
            log_info "Nodeos reached block $head"
            return
        fi

        if (( NODEOS_SYNC_TIMEOUT_SECONDS > 0 && SECONDS - start_time > NODEOS_SYNC_TIMEOUT_SECONDS )); then
            log_error "Timed out waiting for nodeos to reach $target_height; latest observed head was '${head:-unavailable}'"
            exit 1
        fi

        log_info "Nodeos head is '${head:-unavailable}', waiting..."
        sleep 10
    done
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
      if [[ ! -f "$RETH_BACKUP_ARTIFACT" ]]; then
        download_url "$RETH_BACKUP_URL" "$RETH_BACKUP_ARTIFACT"
      fi
      verify_reth_backup_checksum
    else
      log_info "Existing telos-reth-data directory found; skipping reth backup download"
    fi
}

# Extract backup
extract_backup() {
    cd $INSTALL_DIR
    if [ ! -d ./telos-reth-data ]; then
        log_info "Extracting reth backup..."
        tar --zstd -xvf "$RETH_BACKUP_ARTIFACT"
    else
        log_info "Existing telos-reth-data directory found; skipping reth backup extraction"
    fi
    cd $INSTALL_DIR
}

# Get JWT secret
get_jwt_secret() {
    cd $INSTALL_DIR
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
    cd $INSTALL_DIR
}

# Generate reth config
generate_reth_config() {
    cd $INSTALL_DIR
    log_info "Generating reth config..."
    local config_path="./telos-reth/.env"

    cat > "$config_path" << EOF
DATA_DIR=$INSTALL_DIR/telos-reth-data
LOG_PATH=$INSTALL_DIR/telos-reth/reth.log
LOG_LEVEL=info
CHAIN=tevmmainnet
RETH_RPC_ADDRESS=0.0.0.0
RETH_RPC_PORT=$RETH_RPC_PORT
RETH_WS_ADDRESS=0.0.0.0
RETH_WS_PORT=$RETH_WS_PORT
RETH_AUTH_RPC_ADDRESS=127.0.0.1
RETH_AUTH_RPC_PORT=$RETH_AUTH_RPC_PORT
RETH_DISCOVERY_PORT=$RETH_DISCOVERY_PORT
TELOS_ENDPOINT=http://127.0.0.1:$NODEOS_HTTP_RPC_PORT
TELOS_SIGNER_ACCOUNT=rpc.evm
TELOS_SIGNER_PERMISSION=rpc
# Below is the Telos Mainnet Signer Key. Only uncomment one.
TELOS_SIGNER_KEY=5KjZqM5UTGmmHByRXZaDM1a5JupgGM9925H3NEroTr6CdEZQDvH
# Below is the Telos Testnet Signer Key. Only uncomment one.
# TELOS_SIGNER_KEY=5Hq1FmDPfbyfUr5WpgbsYPtxyAkYynBtJ6oS5C7LfZE5MMyZeRJ
EOF
    cd $INSTALL_DIR
}

# Start reth
start_reth() {
    log_info "Starting reth..."
    cd $INSTALL_DIR/telos-reth || exit 1
    bash start.sh
    log_info "Reth started successfully"
    cd $INSTALL_DIR
}

eth_rpc() {
    local payload="$1"
    curl -fsS -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://127.0.0.1:$RETH_RPC_PORT"
}

verify_reth_history() {
    local start_time=$SECONDS
    local block_zero=""
    local finalized_block=""

    log_info "Verifying reth RPC and restored EVM history..."
    while true; do
        block_zero="$(eth_rpc '{"method": "eth_getBlockByNumber", "params": ["0x0", false], "id": 1, "jsonrpc": "2.0"}' 2>/dev/null || true)"
        finalized_block="$(eth_rpc '{"method": "eth_getBlockByNumber", "params": ["finalized", false], "id": 1, "jsonrpc": "2.0"}' 2>/dev/null || true)"

        if [[ -n "$block_zero" && -n "$finalized_block" ]] \
            && echo "$block_zero" | jq -e '.result.number == "0x0"' >/dev/null 2>&1 \
            && echo "$finalized_block" | jq -e '.result.number' >/dev/null 2>&1; then
            log_info "Reth restored EVM block 0 and finalized block history successfully"
            return
        fi

        if (( RETH_VERIFY_TIMEOUT_SECONDS > 0 && SECONDS - start_time > RETH_VERIFY_TIMEOUT_SECONDS )); then
            log_error "Timed out verifying reth history. Check $INSTALL_DIR/telos-reth/reth.log"
            exit 1
        fi

        log_info "Reth RPC is not ready or history is not available yet, retrying..."
        sleep 5
    done
}

# Fetch block info from reth
fetch_block_info() {
    log_info "Fetching block info from reth..."

    while true; do
        # Make the curl request
        local latest_block=$(curl -s -X POST \
                              -H "Content-Type: application/json" \
                              -d '{"method": "eth_getBlockByNumber", "params": ["finalized", false], "id": 1, "jsonrpc": "2.0"}' \
                              http://127.0.0.1:$RETH_RPC_PORT)

        # Check if the request was successful and contains the expected data
        if [[ -n "$latest_block" && $(echo "$latest_block" | jq -e '.result.number' > /dev/null 2>&1; echo $?) -eq 0 ]]; then
            local block_number_hex=$(echo $latest_block | jq -r '.result.number')
            RETH_FINAL_BLOCK=$((block_number_hex))  # Convert hex to decimal
            RETH_PARENT_HASH=$(echo $latest_block | jq -r '.result.parentHash')
            log_info "Successfully fetched block info. Block number: $RETH_FINAL_BLOCK"
            break
        else
            log_info "Reth not started so cannot fetch block info, retrying in 1 second..."
            sleep 1
        fi
    done
}

# Generate consensus client config
generate_consensus_config() {
    log_info "Generating consensus client config..."
    local config_path="./telos-consensus-client/config.toml"
    
    cat > "$config_path" << EOF
# EVM Chain id, Telos mainnet is 40 and testnet is 41
chain_id = 40

# Execution API http endpoint (JWT protected endpoint on reth)
execution_endpoint = "http://127.0.0.1:$RETH_AUTH_RPC_PORT"

# The JWT secret used to sign the JWT token
jwt_secret = "${JWT_SECRET}"

# Nodeos ship ws endpoint
ship_endpoint = "ws://127.0.0.1:$NODEOS_SHIP_WS_SHIP_PORT"

# Nodeos http endpoint
chain_endpoint = "http://127.0.0.1:$NODEOS_HTTP_RPC_PORT"

# Block count in between finalize block calls while syncing
batch_size = 500

# The parent hash of the start_block
prev_hash = "$RETH_PARENT_HASH"

# Start block to start with, should be at or before the first block of the execution node
evm_start_block = $RETH_FINAL_BLOCK

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
    
    log_info "Consensus client config generated successfully."
}

# Start consensus client
start_consensus_client() {
    log_info "Starting consensus client..."
    cd $INSTALL_DIR/telos-consensus-client || exit 1
    bash start.sh
    log_info "Consensus client started successfully"
    cd $INSTALL_DIR
}

#Define logs to be rotated via logrotate
setup_logrotate() {
    log_info "Setting up logrotate configuration..."
    local logrotate_config="/etc/logrotate.d/telos"
    sudo tee "$logrotate_config" > /dev/null << EOF
$INSTALL_DIR/telos-consensus-client/consensus.log $INSTALL_DIR/telos-reth/reth.log $INSTALL_DIR/nodeos-ship/nodeos.log $INSTALL_DIR/nodeos-http/nodeos.log {
   daily
   rotate 5
   compress
   missingok
   notifempty
   create 0644 root root
   dateext
   copytruncate
}
EOF

    # Set proper permissions for logrotate config file
    sudo chmod 644 "$logrotate_config"
    
    log_info "Logrotate configuration created at $logrotate_config"
}

cleanup_downloads() {
    log_info "Cleaning up downloaded installation files..."
    
    # Clean up the reth backup file
    local reth_backup="$INSTALL_DIR/$RETH_BACKUP_ARTIFACT"
    if [[ -n "$RETH_BACKUP_ARTIFACT" && -f "$reth_backup" ]]; then
        # We only delete the backup if the extracted directory exists, ensuring data safety
        if [[ -d "$INSTALL_DIR/telos-reth-data" ]]; then
            if rm "$reth_backup"; then
                log_info "Successfully removed reth backup file: $reth_backup"
            else
                log_warning "Failed to remove reth backup file: $reth_backup. You may want to remove it manually."
            fi
        else
            log_warning "Extracted reth directory not found. Keeping backup file for safety."
        fi
    fi
    
    # Clean up the TelosZero Core DEB package
    local teloszero_core_deb="$INSTALL_DIR/$TELOSZERO_CORE_DEB"
    if [[ -f "$teloszero_core_deb" ]]; then
        # We only delete the DEB if nodeos is successfully installed
        if command_exists nodeos; then
            if rm "$teloszero_core_deb"; then
                log_info "Successfully removed TelosZero Core DEB package: $teloszero_core_deb"
            else
                log_warning "Failed to remove TelosZero Core DEB package: $teloszero_core_deb. You may want to remove it manually."
            fi
        else
            log_warning "Nodeos installation not verified. Keeping DEB package for safety."
        fi
    fi
}

# Log installation details
log_install_details() {
    log_info "Installation details:"
    log_info "Install directory: $INSTALL_DIR"
    log_info "Release tag: $RELEASE_TAG"
    log_info "TelosZero Core version: $TELOSZERO_CORE_VERSION"
    log_info "Bootstrap mode: $TELOS_BOOTSTRAP_MODE"
    log_info "Nodeos snapshot artifact: ${NODEOS_SNAPSHOT_ARTIFACT:-unknown}"
    log_info "Nodeos native history starts at snapshot block: ${NODEOS_SNAPSHOT_HEIGHT:-unknown}"
    log_info "Reth backup artifact: ${RETH_BACKUP_ARTIFACT:-unknown}"
    log_info "Reth backup height: ${RETH_BACKUP_HEIGHT:-unknown}"
    log_info "Reth backup binary version: ${RETH_BACKUP_BINARY_VERSION:-unknown}"
    log_info "Expected reth binary version: $EXPECTED_RETH_VERSION"
    log_info "Region: $REGION"
    log_info "Nodeos HTTP RPC port: http://127.0.0.1:$NODEOS_HTTP_RPC_PORT"
    log_info "Nodeos HTTP P2P port: 127.0.0.1:$NODEOS_HTTP_P2P_PORT"
    log_info "Nodeos SHIP RPC port: http://127.0.0.1:$NODEOS_SHIP_RPC_PORT"
    log_info "Nodeos SHIP WS SHIP port: ws://127.0.0.1:$NODEOS_SHIP_WS_SHIP_PORT"
    log_info "Nodeos SHIP P2P port: 127.0.0.1:$NODEOS_SHIP_P2P_PORT"
    log_info "Reth RPC port: http://0.0.0.0:$RETH_RPC_PORT"
    log_info "Reth WS port: ws://0.0.0.0:$RETH_WS_PORT"
    log_info "Reth Auth RPC port: http://127.0.0.1:$RETH_AUTH_RPC_PORT"
    log_info "Reth Discovery port: 127.0.0.1:$RETH_DISCOVERY_PORT"
    log_info "Within $INSTALL_DIR there are 4 services running, each has a start.sh and stop.sh script"
    log_info "1. nodeos-http configuration is managed in config.ini"
    log_info "2. nodeos-ship configuration is managed in config.ini"
    log_info "3. telos-reth configuration is managed in .env"
    log_info "4. telos-consensus-client configuration is managed in config.toml"
    log_info "Only the http and ws reth RPC ports of are listening publicly, it is advised to put a reverse proxy in front of these services where you terminate SSL"
    echo "\
████████╗███████╗██╗      ██████╗ ███████╗███████╗██╗   ██╗███╗   ███╗
╚══██╔══╝██╔════╝██║     ██╔═══██╗██╔════╝██╔════╝██║   ██║████╗ ████║
   ██║   █████╗  ██║     ██║   ██║███████╗█████╗  ██║   ██║██╔████╔██║
   ██║   ██╔══╝  ██║     ██║   ██║╚════██║██╔══╝  ╚██╗ ██╔╝██║╚██╔╝██║
   ██║   ███████╗███████╗╚██████╔╝███████║███████╗ ╚████╔╝ ██║ ╚═╝ ██║
   ╚═╝   ╚══════╝╚══════╝ ╚═════╝ ╚══════╝╚══════╝  ╚═══╝  ╚═╝     ╚═╝"

}

# Main execution
main() {
    parse_args "$@"
    log_info "Starting Telos node setup..."
    init_inputs
    init_workspace
    load_backup_metadata
    validate_reth_backup_compatibility
    check_disk_space
    install_dependencies
    validate_backup_freshness
    validate_ship_archive_metadata
    install_rust
    install_nodeos
    download_snapshot
    setup_logrotate
    setup_nodeos
    restore_ship_archive
    start_nodeos
    clone_repos
    build_clients
    download_backup
    extract_backup
    wait_for_nodeos_height "$RETH_BACKUP_HEIGHT"
    get_jwt_secret
    generate_reth_config
    start_reth
    verify_reth_history
    fetch_block_info
    generate_consensus_config
    start_consensus_client
    cleanup_downloads
    
    log_info "Setup completed successfully"

    log_install_details
}

# Run the script
main "$@"
