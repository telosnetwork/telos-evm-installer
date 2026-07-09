#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/telos-evm-2}
DATA_DIR=${RETH_BACKUP_DATADIR:-$INSTALL_DIR/telos-reth-data}
RETH_BIN=${RETH_BIN:-$INSTALL_DIR/telos-reth/target/release/telos-reth}
STAGE_ROOT=${RETH_TAR_STAGE_ROOT:-$INSTALL_DIR/reth-tar-staging}
STAGE_DIR="$STAGE_ROOT/telos-reth-data"
DOWNLOAD_DIR=${RETH_TAR_DOWNLOAD_DIR:-$INSTALL_DIR/downloads}
LOG_DIR=${LOG_DIR:-$INSTALL_DIR/logs}
LOG="$LOG_DIR/telos-evm2-reth-tar-publish.log"
STATUS="$INSTALL_DIR/RETH-TAR-PUBLISH-STATUS.txt"
LOCK=${LOCK:-/run/lock/telos-evm2-reth-tar-publish.lock}

LOCAL_RPC=${RETH_BACKUP_LOCAL_RPC:-http://127.0.0.1:8545}
PUBLIC_RPC=${RETH_BACKUP_PUBLIC_RPC:-https://rpc.telos.net/evm}
EXPECTED_RETH_VERSION=${EXPECTED_RETH_VERSION:-1.0.8}
MAX_LAG=${RETH_BACKUP_MAX_LAG:-5000}

RETH_SERVICE=${RETH_SERVICE:-}
CONSENSUS_SERVICE=${CONSENSUS_SERVICE:-}
STOP_SERVICES=${RETH_BACKUP_STOP_SERVICES:-0}

KEY=${STORAGEBOX_KEY:-/root/.ssh/storagebox_ed25519}
REMOTE_USER=${STORAGEBOX_USER:-u563713}
REMOTE_HOST=${STORAGEBOX_HOST:-u563713.your-storagebox.de}
REMOTE_PORT=${STORAGEBOX_PORT:-23}
REMOTE_BASE=${STORAGEBOX_BASE:-telos-evm-2}
REMOTE="$REMOTE_USER@$REMOTE_HOST"
RSYNC_SSH="ssh -i $KEY -p $REMOTE_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"

ZSTD_LEVEL=${RETH_TAR_ZSTD_LEVEL:-3}
ZSTD_THREADS=${RETH_TAR_ZSTD_THREADS:-2}

mkdir -p "$LOG_DIR" "$DOWNLOAD_DIR" "$STAGE_ROOT"
exec 9>"$LOCK"
flock -n 9 || { echo "[$(date -Is)] Telos EVM 2 reth tar publish already running"; exit 0; }
exec >>"$LOG" 2>&1

echo "[$(date -Is)] Telos EVM 2 reth tar publish start"

rpc_result() {
  local url="$1" method="$2" params="$3"
  curl -fsS --max-time 15 -H "content-type: application/json" -H "user-agent: curl/8" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" "$url" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result") or "")'
}

block_hash() {
  local url="$1" height_hex="$2"
  curl -fsS --max-time 15 -H "content-type: application/json" -H "user-agent: curl/8" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBlockByNumber\",\"params\":[\"$height_hex\",false]}" "$url" \
    | python3 -c 'import json,sys; r=(json.load(sys.stdin).get("result") or {}); print(r.get("hash", "") if isinstance(r, dict) else "")'
}

version_from_client() {
  sed -nE 's#^reth/v?([0-9]+(\.[0-9]+)*).*#\1#p' <<< "$1"
}

commit_from_client() {
  sed -nE 's#^reth/v?[0-9.]+-([^/]+).*#\1#p' <<< "$1"
}

write_status() {
  local state="$1" note="$2"
  {
    echo "status=$state"
    echo "updated_at=$(date -Is)"
    echo "backup_kind=telos-evm2-reth-tar"
    echo "source_datadir=$DATA_DIR"
    echo "stage_dir=$STAGE_DIR"
    echo "remote_base=$REMOTE_BASE"
    echo "note=$note"
    if [[ -n "${artifact_name:-}" ]]; then echo "artifact=$artifact_name"; fi
    if [[ -n "${height_dec:-}" ]]; then echo "height=$height_dec"; fi
    if [[ -n "${block_hash_value:-}" ]]; then echo "hash=$block_hash_value"; fi
  } > "$STATUS"
  rsync -a --partial --inplace -e "$RSYNC_SSH" "$STATUS" "$REMOTE:$REMOTE_BASE/RETH-TAR-PUBLISH-STATUS.txt" || true
}

if [[ ! -d "$DATA_DIR" ]]; then
  write_status failed "Source datadir is missing."
  exit 1
fi
if [[ ! -f "$KEY" ]]; then
  write_status failed "Storagebox key is missing."
  exit 1
fi

ssh -i "$KEY" -p "$REMOTE_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  "$REMOTE" "mkdir -p $REMOTE_BASE"

client_version="$(rpc_result "$LOCAL_RPC" web3_clientVersion "[]" || true)"
reth_version="$(version_from_client "$client_version")"
reth_commit="$(commit_from_client "$client_version")"
if [[ "$reth_version" != "$EXPECTED_RETH_VERSION" ]]; then
  write_status failed "Local RPC client version '$client_version' does not match expected Reth $EXPECTED_RETH_VERSION."
  exit 1
fi

local_hex=$(rpc_result "$LOCAL_RPC" eth_blockNumber "[]" || true)
public_hex=$(rpc_result "$PUBLIC_RPC" eth_blockNumber "[]" || true)
if [[ -z "$local_hex" || -z "$public_hex" ]]; then
  write_status failed "Could not read local/public RPC block heights."
  exit 1
fi
height_dec=$((local_hex))
public_dec=$((public_hex))
lag=$((public_dec - height_dec))
if (( lag < 0 || lag > MAX_LAG )); then
  write_status failed "Reth 1 source is not near public head; lag=$lag."
  exit 1
fi

height_hex=$(printf "0x%x" "$height_dec")
local_hash=$(block_hash "$LOCAL_RPC" "$height_hex" || true)
public_hash=$(block_hash "$PUBLIC_RPC" "$height_hex" || true)
if [[ -z "$local_hash" || -z "$public_hash" || "$local_hash" != "$public_hash" ]]; then
  write_status failed "Hash check failed before final tar pass."
  exit 1
fi
block_hash_value="$local_hash"

artifact_name="reth-data-$(date -u +%Y-%m-%d)-telos-evm-2-${height_dec}.tar.zst"
artifact="$DOWNLOAD_DIR/$artifact_name"
manifest="$STAGE_ROOT/BACKUP-MANIFEST.reth-tar.txt"

rsync_common=(
  -a --delete --partial --inplace --numeric-ids
  --exclude jwt.hex
  --exclude reth.ipc
  --exclude "*.ipc"
  --exclude "*.sock"
  --exclude LOCK
  --exclude "db/LOCK"
)

write_status staging "Low-priority live staging copy is running while reth remains online."
ionice -c3 nice -n 15 rsync "${rsync_common[@]}" "$DATA_DIR/" "$STAGE_DIR/"

restart_reth=0
restart_consensus=0
if [[ "$STOP_SERVICES" == "1" ]]; then
  write_status finalizing "Stopping configured services for final staging rsync."
  if [[ -n "$CONSENSUS_SERVICE" ]] && systemctl is-active --quiet "$CONSENSUS_SERVICE"; then
    restart_consensus=1
    systemctl stop "$CONSENSUS_SERVICE"
  fi
  if [[ -n "$RETH_SERVICE" ]] && systemctl is-active --quiet "$RETH_SERVICE"; then
    restart_reth=1
    systemctl stop "$RETH_SERVICE"
  fi
fi
restart_services() {
  if [[ "$restart_reth" == "1" ]]; then systemctl start "$RETH_SERVICE" || true; fi
  if [[ "$restart_consensus" == "1" ]]; then systemctl start "$CONSENSUS_SERVICE" || true; fi
}
trap restart_services EXIT
ionice -c2 -n7 nice -n 10 rsync "${rsync_common[@]}" "$DATA_DIR/" "$STAGE_DIR/"
restart_services
trap - EXIT

binary_version="$("$RETH_BIN" --version 2>/dev/null | tr '\n' ';' || true)"
if [[ -z "$binary_version" ]]; then
  binary_version="Reth Version: $reth_version;Commit SHA: $reth_commit;Client Version: $client_version;"
fi

{
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "created_at=$(date -Is)"
  echo "backup_kind=telos-evm2-reth-tar"
  echo "source_datadir=$DATA_DIR"
  echo "stage_dir=$STAGE_DIR"
  echo "height=$height_dec"
  echo "hash=$block_hash_value"
  echo "public_height=$public_dec"
  echo "lag=$lag"
  echo "artifact=$artifact_name"
  echo "reth_binary=$binary_version"
  echo "web3_clientVersion=$client_version"
  echo "source_du=$(du -sh "$DATA_DIR" 2>/dev/null | awk '{print $1}')"
  echo "stage_du=$(du -sh "$STAGE_DIR" 2>/dev/null | awk '{print $1}')"
} > "$manifest"

write_status compressing "Final staging copy is complete; compressing tar artifact from staging copy."
rm -f "$artifact.partial" "$artifact"
tar -C "$STAGE_ROOT" -cf - telos-reth-data BACKUP-MANIFEST.reth-tar.txt \
  | ionice -c3 nice -n 15 zstd -T"$ZSTD_THREADS" "-$ZSTD_LEVEL" -o "$artifact.partial"
mv "$artifact.partial" "$artifact"
sha256sum "$artifact" > "$artifact.sha256"

write_status uploading "Compressed tar artifact is ready; uploading to storagebox $REMOTE_BASE."
rsync -a --partial --inplace --info=stats2 -e "$RSYNC_SSH" "$artifact" "$REMOTE:$REMOTE_BASE/$artifact_name"
rsync -a --partial --inplace --info=stats2 -e "$RSYNC_SSH" "$artifact.sha256" "$REMOTE:$REMOTE_BASE/$artifact_name.sha256"
rsync -a --partial --inplace --info=stats2 -e "$RSYNC_SSH" "$manifest" "$REMOTE:$REMOTE_BASE/$artifact_name.manifest.txt"

write_status complete "Fresh Telos EVM 2 Reth $EXPECTED_RETH_VERSION tar artifact uploaded."
echo "[$(date -Is)] Telos EVM 2 reth tar publish complete artifact=$artifact_name height=$height_dec hash=$block_hash_value"
