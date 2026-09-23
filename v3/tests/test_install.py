"""Offline contract tests for the signed sparse-node installer."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import install  # noqa: E402


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        self.private = self.root / "release-private.pem"
        self.public = self.root / "release-public.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt",
                        "rsa_keygen_bits:2048", "-out", str(self.private)],
                       check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(self.private), "-pubout", "-out",
                        str(self.public)], check=True, capture_output=True)

        self.anchor_hash = "0x" + "a" * 64
        self.child_hash = "0x" + "b" * 64
        self.native_hash = "0x1c91739c" + "c" * 56
        self.native_child = "0x1c91739d" + "d" * 56
        self.native = {
            "block_number": 479294364,
            "block_id": self.native_hash,
            "first_child_block_number": 479294365,
            "first_child_block_id": self.native_child,
            "evm_first_child_block_hash": self.child_hash,
            "chain_id": "0x" + install.NATIVE_CHAIN,
            "starting_gas_price": "0x100",
            "starting_revision": 1,
        }
        self.anchor = {
            "version": 1,
            "chain": {"chain_id": 40, "genesis_hash": self.anchor_hash},
            "parent_block_number": 479294328,
            "parent_block_hash": self.anchor_hash,
            "starting_gas_price": "0x100",
            "starting_revision": 1,
        }
        self.checkpoint = {
            "version": 2,
            "canonical_chain": {"chain_id": 40, "genesis_hash": install.GENESIS},
            "execution_anchor": self.anchor,
            "native_anchor": self.native,
            "actual_state_root": "0x" + "e" * 64,
            "state_dump_sha256": "0x" + digest(b"{}\n"),
            "export_metadata_sha256": "0x" + "1" * 64,
            "native_anchor_attestation_sha256": "0x" + "2" * 64,
            "backup_manifest_sha256": "0x" + "3" * 64,
            "backup_mdbx_sha256": "0x" + "4" * 64,
        }
        (self.bundle / "state.jsonl").write_bytes(b"{}\n")
        write_json(self.bundle / "checkpoint.json", self.checkpoint)
        write_json(self.bundle / "checkpoint.anchor.json", self.anchor)
        audit = {key: self.checkpoint[key] for key in (
            "canonical_chain", "execution_anchor", "native_anchor", "state_dump_sha256",
            "export_metadata_sha256", "native_anchor_attestation_sha256",
            "backup_manifest_sha256", "backup_mdbx_sha256")}
        audit.update(version=2, manifest_sha256="0x" + install.sha256(
            self.bundle / "checkpoint.json"), computed_state_root=self.checkpoint["actual_state_root"])
        write_json(self.bundle / "checkpoint.audit.json", audit)

        env = {
            "CHAIN_ID": "40",
            "CHAIN": "telos-checkpoint:/etc/telos-reth/mainnet/checkpoint.json",
            "CHECKPOINT_MANIFEST": "/etc/telos-reth/mainnet/checkpoint.json",
            "CHECKPOINT_MANIFEST_SHA256": install.sha256(self.bundle / "checkpoint.json"),
            "CHECKPOINT_AUDIT": "/etc/telos-reth/mainnet/checkpoint.audit.json",
            "EXECUTION_ANCHOR": "/etc/telos-reth/mainnet/checkpoint.anchor.json",
            "EXECUTION_ANCHOR_BLOCK_NUMBER": "479294328",
            "EXECUTION_ANCHOR_BLOCK_HASH": self.anchor_hash,
            "TELOS_ENDPOINT": "http://127.0.0.1:8888",
            "NODEOS_URL": "http://127.0.0.1:8888",
            "NODEOS_CHAIN_ID": install.NATIVE_CHAIN,
            "TELOS_SIGNER_ACCOUNT": "",
            "TELOS_SIGNER_PERMISSION": "",
            "HTTP_PORT": "18545",
            "HTTP_API": "eth,net,web3",
            "AUTHRPC_PORT": "18551",
            "METRICS_PORT": "19001",
            "WS_ENABLED": "false",
            "WS_API": "eth,net,web3",
            "RPC_MAX_CONNECTIONS": "500",
            "RPC_MAX_REQUEST_SIZE_MB": "15",
            "RPC_MAX_RESPONSE_SIZE_MB": "64",
            "REFERENCE_RPC_URL": "https://rpc.telos.net/evm",
            "CONSENSUS_UNIT": install.CONSENSUS_UNIT,
            "CONSENSUS_BINARY": "/usr/local/bin/telos-consensus-client",
            "CONSENSUS_CONFIG": "/etc/telos-reth/mainnet/consensus.toml",
            "CONSENSUS_VERSION": "telos-consensus-client test",
            "MAX_HEAD_LAG_BLOCKS": "4",
            "MAX_FINALIZED_STALL_SECONDS": "180",
            "MAX_NODEOS_HEAD_AGE_SECONDS": "30",
            "PARITY_DEPTHS": "0,64,512",
        }
        self.env = env
        self.consensus = {
            "chain_id": 40,
            "data_path": "/var/lib/telos-consensus/mainnet",
            "execution_endpoint": "http://127.0.0.1:18551",
            "chain_endpoint": "http://127.0.0.1:8888",
            "ship_endpoint": "ws://127.0.0.1:8080",
            "execution_anchor_block_number": 479294328,
            "execution_anchor_block_hash": self.anchor_hash,
            "evm_start_block": 479294329,
            "execution_context_anchor_block": 479294329,
            "prev_hash": self.anchor_hash,
            "native_chain_id": self.native["chain_id"],
            "execution_anchor_native_block_number": self.native["block_number"],
            "execution_anchor_native_block_hash": self.native_hash,
            "execution_context_starting_gas_price": "0x100",
            "execution_context_starting_revision": 1,
            "validate_hash": self.child_hash,
            "jwt_secret_path": "/run/credentials/telos-consensus-client@mainnet.service/jwt.hex",
        }
        self.write_configs()
        for name in install.REQUIRED_FILES - {
                "state.jsonl", "checkpoint.json", "checkpoint.anchor.json",
                "checkpoint.audit.json", "node.env", "consensus.toml"}:
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture " + name.encode() + b"\n")
        self.refresh_manifest()

    def write_configs(self):
        (self.bundle / "node.env").write_text("\n".join(
            f"{key}={json.dumps(value)}" if " " in value else f"{key}={value}"
            for key, value in self.env.items()) + "\n")
        (self.bundle / "consensus.toml").write_text("\n".join(
            f"{key}={json.dumps(value)}" for key, value in self.consensus.items()) + "\n")

    def refresh_manifest(self):
        artifacts = {name: install.sha256(self.bundle / name)
                     for name in sorted(install.REQUIRED_FILES)}
        self.env["BINARY_SHA256"] = artifacts["telos-reth"]
        self.env["CONSENSUS_SHA256"] = artifacts["telos-consensus-client"]
        self.write_configs()
        artifacts["node.env"] = install.sha256(self.bundle / "node.env")
        self.manifest = {
            "schema": install.SCHEMA,
            "network": "mainnet",
            "role": "sparse-rpc",
            "archive_history_included": False,
            "release": {"id": "v3.0.0-test", "reth_version": "2.4.1",
                        "reth_commit": "a" * 40,
                        "consensus_commit": "b" * 40},
            "approval": {"status": "approved", **{gate: True for gate in install.GATES}},
            "chain_id": 40,
            "public_genesis_hash": install.GENESIS,
            "native_chain_id": install.NATIVE_CHAIN,
            "history_from_block": 479294328,
            "history_from_hash": self.anchor_hash,
            "required_free_bytes": 100 * 1024**3,
            "artifacts": artifacts,
        }
        self.sign()

    def sign(self):
        write_json(self.bundle / "release.json", self.manifest)
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(self.private), "-out",
                        str(self.bundle / "release.sig"), str(self.bundle / "release.json")],
                       check=True, capture_output=True)

    def check(self):
        return subprocess.run([sys.executable, str(ROOT / "install.py"), "check", "--bundle",
                               str(self.bundle), "--trust-key", str(self.public)],
                              capture_output=True, text=True)

    def test_signed_approved_bundle_passes(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["history_from_block"], 479294328)

    def test_tampered_artifact_fails(self):
        (self.bundle / "telos-reth").write_bytes(b"tampered")
        self.assertIn("SHA-256 mismatch", self.check().stderr)

    def test_tampered_manifest_signature_fails(self):
        with (self.bundle / "release.json").open("a") as output:
            output.write("\n")
        self.assertIn("signature verification failed", self.check().stderr)

    def test_missing_gate_fails_even_when_signed(self):
        self.manifest["approval"]["sparse_backup_restore"] = False
        self.sign()
        self.assertIn("missing a production gate", self.check().stderr)

    def test_legacy_reth_version_fails_even_when_signed(self):
        self.manifest["release"]["reth_version"] = "1.0.8"
        self.sign()
        self.assertIn("Reth 2.4.x", self.check().stderr)

    def test_archive_claim_fails_even_when_signed(self):
        self.manifest["archive_history_included"] = True
        self.sign()
        self.assertIn("must not claim archive history", self.check().stderr)

    def test_extra_artifact_fails_even_when_signed(self):
        (self.bundle / "ops/scripts/extra").write_bytes(b"extra")
        self.manifest["artifacts"]["ops/scripts/extra"] = digest(b"extra")
        self.sign()
        self.assertIn("supported install set exactly", self.check().stderr)

    def test_symlink_artifact_fails(self):
        path = self.bundle / "telos-reth"
        path.unlink()
        path.symlink_to(self.private)
        self.assertIn("symlink in artifact path", self.check().stderr)

    def test_trust_key_inside_bundle_fails(self):
        inside = self.bundle / "release-public.pem"
        inside.write_bytes(self.public.read_bytes())
        result = subprocess.run([sys.executable, str(ROOT / "install.py"), "check", "--bundle",
                                 str(self.bundle), "--trust-key", str(inside)],
                                capture_output=True, text=True)
        self.assertIn("outside the bundle", result.stderr)

    def test_checkpoint_state_pin_fails_even_when_signed(self):
        self.checkpoint["state_dump_sha256"] = "0x" + "f" * 64
        write_json(self.bundle / "checkpoint.json", self.checkpoint)
        self.manifest["artifacts"]["checkpoint.json"] = install.sha256(
            self.bundle / "checkpoint.json")
        self.sign()
        self.assertIn("checkpoint state dump pin differs", self.check().stderr)

    def test_consensus_native_boundary_fails_even_when_signed(self):
        self.consensus["execution_anchor_native_block_number"] += 1
        self.write_configs()
        self.manifest["artifacts"]["consensus.toml"] = install.sha256(
            self.bundle / "consensus.toml")
        self.sign()
        self.assertIn("consensus native anchor differs", self.check().stderr)

    def test_shell_expansion_in_env_fails_even_when_signed(self):
        self.env["REFERENCE_RPC_URL"] = "https://rpc.telos.net/$(id)"
        self.write_configs()
        self.manifest["artifacts"]["node.env"] = install.sha256(self.bundle / "node.env")
        self.sign()
        self.assertIn("shell expansion", self.check().stderr)

    def test_remote_unencrypted_ship_fails_even_when_signed(self):
        self.consensus["ship_endpoint"] = "ws://ship.example.net:8080"
        self.write_configs()
        self.manifest["artifacts"]["consensus.toml"] = install.sha256(
            self.bundle / "consensus.toml")
        self.sign()
        self.assertIn("unencrypted SHIP endpoint", self.check().stderr)

    def test_duplicate_manifest_key_fails_even_when_signed(self):
        manifest = self.bundle / "release.json"
        raw = manifest.read_text().replace('"network": "mainnet",',
                                           '"network": "mainnet", "network": "mainnet",')
        manifest.write_text(raw)
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(self.private), "-out",
                        str(self.bundle / "release.sig"), str(manifest)],
                       check=True, capture_output=True)
        self.assertIn("duplicate JSON key", self.check().stderr)

    def test_group_writable_release_file_is_not_installable(self):
        path = self.bundle / "release.json"
        path.chmod(0o664)
        with self.assertRaisesRegex(install.InstallError, "not group/world writable"):
            install.require_protected_path(path)


if __name__ == "__main__":
    unittest.main()
