#!/usr/bin/env python3
"""Install a signed Telos EVM 3 recent-history RPC bundle on a clean Linux host."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import time
import tomllib
import urllib.parse
import urllib.request


SCHEMA = "telos-evm3-sparse-install/v1"
GENESIS = "0x36fe7024b760365e3970b7b403e161811c1e626edd68460272fcdfa276272563"
NATIVE_CHAIN = "4667b205c6838ef70ff7988f6e8257e8be0e1284a2f59699054a018f743b1d11"
CONFIG_ROOT = Path("/etc/telos-reth/mainnet")
DATA_ROOT = Path("/var/lib/telos-reth/mainnet")
CONSENSUS_PARENT = Path("/var/lib/telos-consensus")
SNAPSHOT_PARENT = Path("/var/lib/telos-reth-snapshots")
BOOTSTRAP_ROOT = Path("/var/lib/telos-reth-bootstrap/mainnet")
RELEASE_HELPER = Path("/usr/local/libexec/telos-reth-release")
EXEC_UNIT = "telos-reth@mainnet.service"
CONSENSUS_UNIT = "telos-consensus-client@mainnet.service"
READINESS_TIMER = "telos-reth-readiness@mainnet.timer"
REQUIRED_FILES = {
    "telos-reth", "telos-consensus-client", "telos-checkpoint-bootstrap",
    "state.jsonl", "checkpoint.json", "checkpoint.audit.json",
    "checkpoint.anchor.json", "node.env", "consensus.toml",
    "ops/config/backup.env.example",
    "ops/sysusers.d/telos-reth.conf", "ops/tmpfiles.d/telos-reth.conf",
    "ops/scripts/telos-reth-release", "ops/scripts/telos-reth-preflight",
    "ops/scripts/telos-reth-run", "ops/scripts/telos-reth-consensus-binding",
    "ops/scripts/telos-reth-engine-ready", "ops/scripts/telos-reth-readiness",
    "ops/scripts/telos-reth-snapshot", "ops/scripts/telos-reth-restore",
    "ops/systemd/telos-reth@.service",
    "ops/systemd/telos-consensus-client@.service",
    "ops/systemd/telos-reth-readiness@.service",
    "ops/systemd/telos-reth-readiness@.timer",
    "ops/systemd/telos-reth-snapshot@.service",
    "ops/systemd/telos-reth-snapshot@.timer",
}
GATES = {
    "release_approved", "companion_compatibility", "checkpoint_import",
    "reorg_and_restart", "testnet_soak", "mainnet_shadow",
    "sparse_backup_restore",
}
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HASH32 = re.compile(r"0x[0-9a-f]{64}\Z")
REQUIRED_ENV = {
    "RPC_MAX_CONNECTIONS", "RPC_MAX_REQUEST_SIZE_MB", "RPC_MAX_RESPONSE_SIZE_MB",
    "METRICS_PORT", "REFERENCE_RPC_URL", "NODEOS_URL", "NODEOS_CHAIN_ID",
    "CONSENSUS_VERSION", "MAX_HEAD_LAG_BLOCKS", "MAX_FINALIZED_STALL_SECONDS",
    "MAX_NODEOS_HEAD_AGE_SECONDS", "PARITY_DEPTHS",
}


class InstallError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise InstallError(message)


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path):
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"duplicate JSON key: {key}")
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique_pairs)


def exact_int(value, minimum=0):
    return type(value) is int and value >= minimum


def hex32(value):
    return isinstance(value, str) and HASH32.fullmatch(value)


def x86_64_elf(path):
    with path.open("rb") as source:
        header = source.read(20)
    return (len(header) == 20 and header[:7] == b"\x7fELF\x02\x01\x01" and
            header[18:20] == b"\x3e\x00")


def endpoint(value, schemes):
    parsed = urllib.parse.urlsplit(value)
    require(parsed.scheme in schemes and parsed.hostname and
            not parsed.username and not parsed.password and not parsed.fragment and
            not parsed.query, f"unsafe endpoint: {value}")
    return parsed


def require_protected_path(path):
    current = path
    while True:
        details = current.lstat()
        require(not stat.S_ISLNK(details.st_mode) and details.st_uid == 0 and
                not details.st_mode & 0o022,
                f"install path must be root-owned and not group/world writable: {current}")
        if current == current.parent:
            break
        current = current.parent


def parse_env(path):
    result = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, raw = line.partition("=")
        require(separator and re.fullmatch(r"[A-Z][A-Z0-9_]*", key), "invalid node.env entry")
        require(not any(char in raw for char in "$`;|&<>\\\r\n"),
                f"shell expansion or control character in node.env: {key}")
        parts = shlex.split(raw, comments=False, posix=True)
        require(len(parts) <= 1, f"invalid node.env value: {key}")
        require(key not in result, f"duplicate node.env key: {key}")
        result[key] = parts[0] if parts else ""
    return result


class Bundle:
    def __init__(self, root, trust_key):
        self.root = root.resolve(strict=True)
        self.trust_key = trust_key.resolve(strict=True)
        require(self.root.is_dir(), "bundle is not a directory")
        require(not self.trust_key.is_relative_to(self.root), "trust key must be outside the bundle")
        require(self.trust_key.is_file(), "trust key does not exist")
        self._path("release.json")
        self._path("release.sig")
        try:
            run("openssl", "dgst", "-sha256", "-verify", str(self.trust_key),
                "-signature", str(self.root / "release.sig"), str(self.root / "release.json"))
        except subprocess.CalledProcessError as error:
            raise InstallError("release signature verification failed") from error
        self.manifest = read_json(self.root / "release.json")
        self.validate()

    def _path(self, name):
        pure = PurePosixPath(name)
        require(not pure.is_absolute() and ".." not in pure.parts and str(pure) == name,
                f"unsafe artifact path: {name}")
        current = self.root
        for part in pure.parts:
            current = current / part
            require(not stat.S_ISLNK(current.lstat().st_mode), f"symlink in artifact path: {name}")
        require(current.is_file() and current.resolve() == self.root / name,
                f"missing or non-regular artifact: {name}")
        return current

    def file(self, name):
        return self._path(name)

    def validate(self):
        manifest = self.manifest
        require(isinstance(manifest, dict), "release manifest must be an object")
        require(manifest.get("schema") == SCHEMA, "unsupported release schema")
        require(manifest.get("network") == "mainnet", "only mainnet is supported")
        require(manifest.get("role") == "sparse-rpc", "bundle must be sparse-rpc")
        require(manifest.get("archive_history_included") is False,
                "sparse installer must not claim archive history")
        release = manifest.get("release", {})
        require(isinstance(release, dict), "release must be an object")
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", release.get("id", "")),
                "invalid release id")
        for key in ("reth_commit", "consensus_commit"):
            require(HEX40.fullmatch(release.get(key, "")), f"missing pinned {key}")
        require(isinstance(release.get("reth_version"), str) and
                re.fullmatch(r"2\.4\.[0-9]+", release["reth_version"]),
                "release must pin a Reth 2.4.x version")
        approval = manifest.get("approval", {})
        require(isinstance(approval, dict), "approval must be an object")
        require(approval.get("status") == "approved", "release is not approved")
        require(all(approval.get(gate) is True for gate in GATES),
                "signed release record is missing a production gate")
        require(manifest.get("chain_id") == 40, "wrong EVM chain ID")
        require(manifest.get("public_genesis_hash") == GENESIS, "wrong public genesis")
        require(manifest.get("native_chain_id") == NATIVE_CHAIN, "wrong native chain ID")
        require(exact_int(manifest.get("history_from_block"), 1) and
                hex32(manifest.get("history_from_hash")), "invalid history boundary")
        required = manifest.get("required_free_bytes")
        require(exact_int(required, 100 * 1024**3) and
                required >= 2 * self.file("state.jsonl").stat().st_size,
                "signed free-space requirement is missing or too small for the state dump")
        artifacts = manifest.get("artifacts", {})
        require(isinstance(artifacts, dict) and set(artifacts) == REQUIRED_FILES,
                "bundle artifacts must match the supported install set exactly")
        for name, expected in artifacts.items():
            require(isinstance(expected, str) and HEX64.fullmatch(expected),
                    f"invalid SHA-256 for {name}")
            require(sha256(self.file(name)) == expected, f"artifact SHA-256 mismatch: {name}")

        checkpoint = read_json(self.file("checkpoint.json"))
        require(isinstance(checkpoint, dict), "checkpoint manifest must be an object")
        chain = checkpoint.get("canonical_chain", {})
        anchor = checkpoint.get("execution_anchor", {})
        native = checkpoint.get("native_anchor", {})
        require(isinstance(chain, dict) and isinstance(anchor, dict) and
                isinstance(native, dict), "checkpoint identity must be an object")
        require(checkpoint.get("version") == 2, "checkpoint manifest v2 required")
        require(chain == {"chain_id": 40, "genesis_hash": GENESIS},
                "checkpoint public chain identity differs")
        require(native.get("chain_id") == "0x" + NATIVE_CHAIN,
                "checkpoint native chain differs")
        require(checkpoint.get("state_dump_sha256") == "0x" + artifacts["state.jsonl"],
                "checkpoint state dump pin differs")
        require(anchor.get("parent_block_number") == manifest.get("history_from_block"),
                "history boundary differs")
        require(anchor.get("parent_block_hash") == manifest.get("history_from_hash"),
                "history boundary hash differs")
        require(anchor.get("version") == 1 and
                anchor.get("chain") == {"chain_id": 40,
                                        "genesis_hash": manifest["history_from_hash"]},
                "checkpoint execution anchor identity differs")
        require(exact_int(native.get("block_number"), 1) and
                native.get("first_child_block_number") == native["block_number"] + 1 and
                hex32(native.get("block_id")) and
                hex32(native.get("first_child_block_id")) and
                hex32(native.get("evm_first_child_block_hash")),
                "checkpoint native child boundary differs")
        require(int(native["block_id"][2:10], 16) == native["block_number"] and
                int(native["first_child_block_id"][2:10], 16) ==
                native["first_child_block_number"],
                "checkpoint native block IDs do not encode their heights")
        require(read_json(self.file("checkpoint.anchor.json")) == anchor,
                "signed execution anchor differs from checkpoint")
        audit = read_json(self.file("checkpoint.audit.json"))
        require(isinstance(audit, dict) and audit.get("version") == 2 and
                audit.get("manifest_sha256") == "0x" + artifacts["checkpoint.json"] and
                audit.get("computed_state_root") == checkpoint.get("actual_state_root") and
                all(audit.get(key) == checkpoint.get(key) for key in (
                    "canonical_chain", "execution_anchor", "native_anchor", "state_dump_sha256",
                    "export_metadata_sha256", "native_anchor_attestation_sha256",
                    "backup_manifest_sha256", "backup_mdbx_sha256")),
                "signed checkpoint audit differs from manifest")

        env = parse_env(self.file("node.env"))
        pinned = {
            "CHAIN_ID": "40",
            "CHAIN": f"telos-checkpoint:{CONFIG_ROOT / 'checkpoint.json'}",
            "CHECKPOINT_MANIFEST": str(CONFIG_ROOT / "checkpoint.json"),
            "CHECKPOINT_MANIFEST_SHA256": artifacts["checkpoint.json"],
            "CHECKPOINT_AUDIT": str(CONFIG_ROOT / "checkpoint.audit.json"),
            "EXECUTION_ANCHOR": str(CONFIG_ROOT / "checkpoint.anchor.json"),
            "EXECUTION_ANCHOR_BLOCK_NUMBER": str(manifest["history_from_block"]),
            "EXECUTION_ANCHOR_BLOCK_HASH": manifest["history_from_hash"],
            "CONSENSUS_UNIT": CONSENSUS_UNIT,
            "CONSENSUS_BINARY": "/usr/local/bin/telos-consensus-client",
            "CONSENSUS_CONFIG": str(CONFIG_ROOT / "consensus.toml"),
            "CONSENSUS_SHA256": artifacts["telos-consensus-client"],
            "BINARY_SHA256": artifacts["telos-reth"],
            "NODEOS_CHAIN_ID": NATIVE_CHAIN,
            "HTTP_API": "eth,net,web3",
            "WS_API": "eth,net,web3",
        }
        for key, value in pinned.items():
            require(env.get(key) == value, f"node.env {key} differs from signed release")
        require(all(env.get(key) for key in REQUIRED_ENV), "node.env is incomplete")
        require(env.get("TELOS_ENDPOINT") == env.get("NODEOS_URL"),
                "forwarder and readiness nodeos URLs differ")
        nodeos_url = endpoint(env["NODEOS_URL"], {"http", "https"})
        require(nodeos_url.scheme == "https" or nodeos_url.hostname in
                {"localhost", "127.0.0.1"},
                "nodeos HTTP endpoint must be loopback")
        endpoint(env["REFERENCE_RPC_URL"], {"https"})
        ports = [env.get(key, "") for key in ("HTTP_PORT", "AUTHRPC_PORT", "METRICS_PORT")]
        require(all(port.isdecimal() and 1024 <= int(port) <= 65535 for port in ports) and
                len(set(ports)) == len(ports), "invalid local RPC ports")
        require(env.get("MAX_HEAD_LAG_BLOCKS") == "4", "head lag gate must be four blocks")
        require(env.get("MAX_FINALIZED_STALL_SECONDS") == "180" and
                env.get("MAX_NODEOS_HEAD_AGE_SECONDS") == "30" and
                env.get("PARITY_DEPTHS") == "0,64,512",
                "readiness thresholds differ from approved policy")
        require(all(env[key].isdecimal() and int(env[key]) > 0 for key in (
                    "RPC_MAX_CONNECTIONS", "RPC_MAX_REQUEST_SIZE_MB",
                    "RPC_MAX_RESPONSE_SIZE_MB")), "invalid RPC resource limits")
        require(env.get("WS_ENABLED") == "false", "WebSocket must start disabled")
        require(env.get("WS_API") == "eth,net,web3", "WebSocket API allowlist differs")
        require(env.get("TELOS_SIGNER_ACCOUNT", "") == "" and
                env.get("TELOS_SIGNER_PERMISSION", "") == "",
                "initial install must be read-only; provision forwarding separately")
        require("REPLACE_WITH" not in self.file("node.env").read_text(),
                "node.env contains placeholders")

        consensus = tomllib.loads(self.file("consensus.toml").read_text())
        require(consensus.get("chain_id") == 40, "consensus chain ID differs")
        require(consensus.get("execution_anchor_block_number") == manifest["history_from_block"],
                "consensus execution anchor differs")
        require(consensus.get("execution_anchor_block_hash") == manifest["history_from_hash"],
                "consensus execution hash differs")
        require(consensus.get("data_path") == "/var/lib/telos-consensus/mainnet",
                "consensus data path differs")
        require(consensus.get("execution_endpoint") ==
                f"http://127.0.0.1:{env['AUTHRPC_PORT']}",
                "consensus Engine endpoint differs")
        require(consensus.get("evm_start_block") == manifest["history_from_block"] + 1,
                "consensus start must be first checkpoint child")
        require(consensus.get("execution_context_anchor_block") ==
                manifest["history_from_block"] + 1 and
                consensus.get("prev_hash") == manifest["history_from_hash"],
                "consensus context anchor differs")
        require(consensus.get("native_chain_id") == native["chain_id"] and
                consensus.get("execution_anchor_native_block_number") == native["block_number"] and
                consensus.get("execution_anchor_native_block_hash") == native["block_id"],
                "consensus native anchor differs")
        require(str(consensus.get("execution_context_starting_gas_price")) ==
                str(anchor.get("starting_gas_price")) ==
                str(native.get("starting_gas_price")) and
                consensus.get("execution_context_starting_revision") ==
                anchor.get("starting_revision") == native.get("starting_revision"),
                "consensus execution context differs")
        require(consensus.get("validate_hash") == native.get("evm_first_child_block_hash"),
                "consensus first-child hash differs")
        require(consensus.get("chain_endpoint") == env["NODEOS_URL"],
                "consensus and Reth nodeos endpoints differ")
        require(consensus.get("jwt_secret_path") ==
                "/run/credentials/telos-consensus-client@mainnet.service/jwt.hex",
                "consensus JWT must use systemd credential")
        ship_url = endpoint(consensus.get("ship_endpoint", ""), {"ws", "wss"})
        require(ship_url.scheme == "wss" or ship_url.hostname in
                {"localhost", "127.0.0.1"},
                "unencrypted SHIP endpoint must be loopback")
        require("REPLACE_WITH" not in self.file("consensus.toml").read_text(),
                "consensus config contains placeholders")
        self.checkpoint = checkpoint
        self.env = env


def host_preflight(bundle):
    require(sys.platform == "linux" and os.geteuid() == 0, "install requires Linux root")
    for path in (bundle.root, bundle.trust_key, *(
            bundle.file(name) for name in REQUIRED_FILES),
            bundle.file("release.json"), bundle.file("release.sig")):
        require_protected_path(path)
    os_release = parse_env(Path("/etc/os-release"))
    require(os_release.get("ID") == "ubuntu" and os.uname().machine == "x86_64",
            "install requires x86_64 Ubuntu")
    require(sys.version_info >= (3, 11), "Python 3.11 or newer is required")
    for tool in ("systemctl", "systemd-sysusers", "systemd-tmpfiles", "getent", "id",
                 "findmnt",
                 "chown", "jq", "curl", "sha256sum", "flock"):
        require(shutil.which(tool), f"missing prerequisite: {tool}")
    version = int(run("systemctl", "--version").splitlines()[0].split()[1])
    require(version >= 252, "systemd 252 or newer is required")
    require(not DATA_ROOT.exists() and not DATA_ROOT.is_symlink() and
            not BOOTSTRAP_ROOT.exists() and not BOOTSTRAP_ROOT.is_symlink(),
            "install requires a clean checkpoint data path")
    require(not CONFIG_ROOT.exists() and not CONFIG_ROOT.is_symlink(),
            "install requires a clean config path")
    targets = [Path("/etc/sysusers.d/telos-reth.conf"),
               Path("/etc/tmpfiles.d/telos-reth.conf"),
               Path("/usr/local/bin/telos-reth"),
               Path("/usr/local/bin/telos-consensus-client")]
    targets.extend(Path("/usr/local/libexec") / Path(name).name
                   for name in REQUIRED_FILES if name.startswith("ops/scripts/"))
    targets.extend(Path("/etc/systemd/system") / Path(name).name
                   for name in REQUIRED_FILES if name.startswith("ops/systemd/"))
    require(all(not target.exists() and not target.is_symlink() for target in targets),
            "install targets already exist; use a clean host")
    for unit in (EXEC_UNIT, CONSENSUS_UNIT):
        require(subprocess.run(["systemctl", "is-active", "--quiet", unit]).returncode != 0,
                f"existing service is active: {unit}")
    for parent in (DATA_ROOT.parent, CONSENSUS_PARENT, SNAPSHOT_PARENT):
        require(parent.is_dir() and not parent.is_symlink(),
                f"create the intended data/snapshot filesystem before installation: {parent}")
    require(len({parent.stat().st_dev for parent in
                 (DATA_ROOT.parent, CONSENSUS_PARENT, SNAPSHOT_PARENT)}) == 1,
            "execution, consensus and snapshot staging must share one filesystem")
    filesystem = run("findmnt", "-no", "FSTYPE", "-T", str(DATA_ROOT.parent))
    require(filesystem in {"xfs", "btrfs"}, "snapshot filesystem must be XFS or Btrfs")
    if filesystem == "xfs":
        require(shutil.which("xfs_info"), "missing prerequisite: xfs_info")
        require("reflink=1" in run("xfs_info", str(DATA_ROOT.parent)),
                "XFS snapshot filesystem must have reflink=1")
    statvfs = os.statvfs(DATA_ROOT.parent)
    free_bytes = statvfs.f_bavail * statvfs.f_frsize
    reserve = statvfs.f_blocks * statvfs.f_frsize // 5
    require(free_bytes >= bundle.manifest["required_free_bytes"] + reserve,
            "insufficient space for checkpoint import plus 20% reserve")
    for name in ("telos-reth", "telos-consensus-client", "telos-checkpoint-bootstrap"):
        artifact = bundle.file(name)
        require(x86_64_elf(artifact) and os.access(artifact, os.X_OK),
                f"{name} must be an executable x86_64 ELF")
    expected_version = bundle.env["CONSENSUS_VERSION"]
    actual_version = run(str(bundle.file("telos-consensus-client")), "--version").splitlines()[0]
    require(actual_version == expected_version, "consensus binary version differs")
    reth_version = bundle.manifest["release"]["reth_version"]
    reth_output = run(str(bundle.file("telos-reth")), "--version").splitlines()[0]
    require(re.search(rf"(?<![0-9.]){re.escape(reth_version)}(?![0-9.])", reth_output),
            "Reth binary version differs from signed release")
    endpoint = bundle.env["NODEOS_URL"].rstrip("/") + "/v1/chain/get_info"
    request = urllib.request.Request(endpoint, data=b"{}",
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        info = json.load(response)
    require(info.get("chain_id") == NATIVE_CHAIN, "nodeos chain ID differs")
    require(info.get("last_irreversible_block_num", 0) >=
            bundle.checkpoint["native_anchor"]["first_child_block_number"],
            "nodeos has not finalized the checkpoint child")


def install_file(source, target, mode, uid=0, gid=0):
    target.parent.mkdir(parents=True, exist_ok=True)
    require(not target.exists() and not target.is_symlink(), f"target already exists: {target}")
    temporary = target.with_name(target.name + ".installing")
    require(not temporary.exists(), f"stale installer temporary file: {temporary}")
    with source.open("rb") as src, temporary.open("xb") as dst:
        shutil.copyfileobj(src, dst, length=4 * 1024 * 1024)
        dst.flush()
        os.fsync(dst.fileno())
    os.chmod(temporary, mode)
    os.chown(temporary, uid, gid)
    os.replace(temporary, target)


def rpc(url, method, params):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                          "params": params}).encode()
    request = urllib.request.Request(url, data=payload,
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=5) as response:
        result = json.load(response)
    require("error" not in result, f"RPC {method} returned an error")
    return result.get("result")


def history_profile(bundle):
    manifest = bundle.manifest
    return {
        "evm_history": "recent",
        "history_from_block": manifest["history_from_block"],
        "history_from_hash": manifest["history_from_hash"],
        "pre_checkpoint_history_included": False,
        "archive_history_included": False,
        "nodeos_history_installed": False,
        "required_free_bytes": manifest["required_free_bytes"],
        "additional_filesystem_reserve_percent": 20,
    }


def install(bundle, start):
    host_preflight(bundle)
    sysusers = Path("/etc/sysusers.d/telos-reth.conf")
    install_file(bundle.file("ops/sysusers.d/telos-reth.conf"), sysusers, 0o644)
    run("systemd-sysusers", str(sysusers))

    BOOTSTRAP_ROOT.mkdir(parents=True, mode=0o700)
    os.chmod(BOOTSTRAP_ROOT, 0o700)
    install_file(bundle.file("checkpoint.json"), BOOTSTRAP_ROOT / "checkpoint.json", 0o600)
    DATA_ROOT.parent.mkdir(parents=True, exist_ok=True)
    bootstrap = bundle.file("telos-checkpoint-bootstrap")
    require(os.access(bootstrap, os.X_OK), "checkpoint importer must be executable")
    subprocess.run([str(bootstrap), "--chain", "telos-mainnet", "--datadir", str(DATA_ROOT),
                    "--storage.v2=true", "--manifest", str(BOOTSTRAP_ROOT / "checkpoint.json"),
                    "--state", str(bundle.file("state.jsonl"))], check=True)
    for name in ("checkpoint.audit.json", "checkpoint.anchor.json"):
        require(sha256(BOOTSTRAP_ROOT / name) == bundle.manifest["artifacts"][name],
                f"checkpoint import {name} differs from signed evidence")

    config_group = run("getent", "group", "telos-reth-config").split(":")[2]
    reth_uid = int(run("id", "-u", "telos-reth"))
    reth_gid = int(run("id", "-g", "telos-reth"))
    run("chown", "-R", f"{reth_uid}:{reth_gid}", str(DATA_ROOT))
    CONFIG_ROOT.mkdir(parents=True, mode=0o750)
    os.chown(CONFIG_ROOT, 0, int(config_group))
    os.chmod(CONFIG_ROOT, 0o750)
    for name in ("checkpoint.json", "checkpoint.audit.json", "checkpoint.anchor.json"):
        install_file(BOOTSTRAP_ROOT / name, CONFIG_ROOT / name, 0o440, gid=int(config_group))
    install_file(bundle.file("node.env"), CONFIG_ROOT / "node.env", 0o440,
                 gid=int(config_group))
    install_file(bundle.file("consensus.toml"), CONFIG_ROOT / "consensus.toml", 0o440,
                 gid=int(config_group))
    install_file(bundle.file("ops/config/backup.env.example"),
                 CONFIG_ROOT / "backup.env.example", 0o400)
    jwt = CONFIG_ROOT / "jwt.hex"
    with os.fdopen(os.open(jwt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400), "w") as output:
        output.write(secrets.token_hex(32) + "\n")
        output.flush()
        os.fsync(output.fileno())

    for name in sorted(bundle.manifest["artifacts"]):
        if name.startswith("ops/scripts/"):
            install_file(bundle.file(name), Path("/usr/local/libexec") / Path(name).name, 0o755)
        elif name.startswith("ops/systemd/"):
            install_file(bundle.file(name), Path("/etc/systemd/system") / Path(name).name, 0o644)
    tmpfiles = Path("/etc/tmpfiles.d/telos-reth.conf")
    install_file(bundle.file("ops/tmpfiles.d/telos-reth.conf"), tmpfiles, 0o644)
    run("systemd-tmpfiles", "--create", str(tmpfiles))

    release_id = bundle.manifest["release"]["id"]
    artifacts = bundle.manifest["artifacts"]
    for component, name in (("execution", "telos-reth"),
                            ("consensus", "telos-consensus-client")):
        run(str(RELEASE_HELPER), "install", component, release_id,
            str(bundle.file(name)), artifacts[name])
        run(str(RELEASE_HELPER), "activate", component, release_id, artifacts[name])
    run("systemctl", "daemon-reload")
    print(f"Staged signed recent-history Telos EVM 3 release {release_id} on loopback only; "
          f"EVM history starts at block {bundle.manifest['history_from_block']}.")
    if start:
        try:
            run("systemctl", "enable", "--now", EXEC_UNIT)
            rpc_url = f"http://127.0.0.1:{bundle.env['HTTP_PORT']}"
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline:
                try:
                    anchor = rpc(rpc_url, "eth_getBlockByNumber",
                                 [hex(bundle.manifest["history_from_block"]), False])
                    if (rpc(rpc_url, "eth_chainId", []) == "0x28" and
                            isinstance(anchor, dict) and
                            anchor.get("hash") == bundle.manifest["history_from_hash"]):
                        break
                except (OSError, ValueError, InstallError):
                    pass
                time.sleep(2)
            else:
                raise InstallError("Reth did not serve the signed checkpoint on loopback")
            run("systemctl", "enable", "--now", CONSENSUS_UNIT)
            run("systemctl", "enable", "--now", READINESS_TIMER)
        except BaseException:
            for unit in (READINESS_TIMER, CONSENSUS_UNIT, EXEC_UNIT):
                subprocess.run(["systemctl", "disable", "--now", unit], check=False)
            raise
        print("Loopback services started; public routing and archive history remain disabled.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "preflight", "install"))
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--trust-key", type=Path, required=True)
    parser.add_argument("--evm-history", choices=("recent", "full"), default="recent",
                        help="recent: signed checkpoint onward (default); full: requires an "
                             "independently qualified archive and router, not yet installed here")
    parser.add_argument("--start", action="store_true",
                        help="start loopback services after a successful install")
    options = parser.parse_args()
    require(not options.start or options.action == "install", "--start requires install")
    require(options.evm_history == "recent",
            "full-history RPC requires a qualified genesis-to-head archive and a history-aware "
            "router; this installer only installs recent-history Reth and configures no routing. "
            "No files changed.")
    bundle = Bundle(options.bundle, options.trust_key)
    if options.action == "check":
        print(json.dumps({"verified": True, "release": bundle.manifest["release"]["id"],
                          "network": "mainnet", "role": "sparse-rpc",
                          **history_profile(bundle)}, sort_keys=True))
    elif options.action == "preflight":
        host_preflight(bundle)
        print("Signed recent-history bundle and clean-host prerequisites verified; "
              f"EVM history starts at block {bundle.manifest['history_from_block']}; "
              "no files changed.")
    else:
        install(bundle, options.start)


if __name__ == "__main__":
    try:
        main()
    except (InstallError, OSError, ValueError, TypeError, KeyError,
            subprocess.CalledProcessError) as error:
        print(f"Telos EVM 3 installer: {error}", file=sys.stderr)
        raise SystemExit(1) from error
