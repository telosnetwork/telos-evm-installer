# Telos EVM 3 sparse-node installer

`install.py` installs an independently approved, signed Telos Reth 2 / consensus-client bundle on
a clean Ubuntu x86_64 host. It does **not** create an archive, restore pre-checkpoint history,
install Telos Zero, configure transaction signing, publish an RPC port, or replace an incumbent.
The v2 `run.sh` in the repository root remains separate and unchanged.

This path is for an ordinary post-checkpoint RPC node. The first available EVM history is the
signed checkpoint anchor. Requests for earlier blocks, receipts, logs, state, proofs, or traces
need an independently qualified archive and a history router; do not route those requests to this
node and do not advertise full history. Telos Zero still needs its own synchronized nodeos and SHiP
feed. Neither a SHiP log nor a signed checkpoint substitutes for the sparse-node backup/restore
qualification in the release gate.

## Release authority and bundle

No public bundle or approval is assumed by this installer. A release authority must first qualify
the exact Reth and companion commits, publish a signed release record, and distribute its **public
verification key independently of the bundle**. The exact signed `release.json` bytes are verified
with detached `release.sig` using `openssl dgst -sha256 -verify`. A key shipped inside the bundle
is refused. Operators must pin the trusted key fingerprint out of band; using a self-generated key
does not establish Telos release approval.

The release directory contains these files, all individually pinned by SHA-256 in `artifacts`:

```text
release.json              release.sig
telos-reth                telos-consensus-client       telos-checkpoint-bootstrap
state.jsonl               checkpoint.json             checkpoint.audit.json
checkpoint.anchor.json    node.env                    consensus.toml
ops/sysusers.d/telos-reth.conf
ops/tmpfiles.d/telos-reth.conf
ops/config/backup.env.example
ops/scripts/telos-reth-{release,preflight,run,consensus-binding,engine-ready,readiness,snapshot,restore}
ops/systemd/telos-reth@.service
ops/systemd/telos-consensus-client@.service
ops/systemd/telos-reth-{readiness,snapshot}@.{service,timer}
```

The `ops` assets must come from the exact reviewed `telosnetwork/telos-reth-2` commit. The
checkpoint manifest and state dump must be source-bound and finalized; the audit and execution
anchor must be deterministic results of a successful isolated import. `node.env` and
`consensus.toml` must bind the same checkpoint, native chain, first child, Engine port, local
nodeos and SHiP source. The installer validates those relationships again before any mutation.

`release.json` is UTF-8 JSON with these fields:

```json
{
  "schema": "telos-evm3-sparse-install/v1",
  "network": "mainnet",
  "role": "sparse-rpc",
  "archive_history_included": false,
  "release": {
    "id": "<approved immutable release id>",
    "reth_version": "2.4.1",
    "reth_commit": "<40 lowercase hex>",
    "consensus_commit": "<40 lowercase hex>"
  },
  "approval": {
    "status": "approved",
    "release_approved": true,
    "companion_compatibility": true,
    "checkpoint_import": true,
    "reorg_and_restart": true,
    "testnet_soak": true,
    "mainnet_shadow": true,
    "sparse_backup_restore": true
  },
  "chain_id": 40,
  "public_genesis_hash": "0x36fe7024b760365e3970b7b403e161811c1e626edd68460272fcdfa276272563",
  "native_chain_id": "4667b205c6838ef70ff7988f6e8257e8be0e1284a2f59699054a018f743b1d11",
  "history_from_block": 479294328,
  "history_from_hash": "<0x-prefixed checkpoint parent hash>",
  "required_free_bytes": 107374182400,
  "artifacts": {"<each exact required relative path>": "<bare lowercase SHA-256>"}
}
```

The example is a schema guide, **not an approved release**. The actual block/hash and free-space
requirement come from the reviewed checkpoint and capacity test; do not copy sample values blindly.
The authority must retain the evidence behind each approval bit. The installer checks the signed
attestations and internal consistency; it cannot independently prove the soak, reorg, or restore
tests from a boolean. Do not set a gate to `true` before its evidence has been reviewed.

## Host prerequisites

- Clean x86_64 Ubuntu, Python 3.11+, systemd 252+, OpenSSL, `jq`, `curl`, `flock`, `sha256sum`,
  and the standard systemd sysusers/tmpfiles tools.
- Stage the approved bundle and out-of-bundle trust key under root-owned, non-group/world-writable
  paths. Every file and ancestor directory is checked before a root install; a developer-owned
  directory is allowed for `check` only.
- One reflink-capable XFS (`reflink=1`) or Btrfs filesystem is already mounted and accessible at
  `/var/lib/telos-reth`, `/var/lib/telos-consensus`, and `/var/lib/telos-reth-snapshots`. These
  directories must exist on the same filesystem so coordinated snapshots can clone both stores.
  Free bytes must cover the signed import estimate **plus 20% filesystem reserve**; the estimate
  must be at least 100 GiB and at least twice the state-dump file size.
- A synchronized Savannah-compatible Telos Zero nodeos is reachable at the signed `NODEOS_URL`,
  reports the mainnet chain ID, and has finalized past the checkpoint's native first child.
- The signed consensus config uses a local `ws://` SHiP endpoint or authenticated external
  `wss://` endpoint. Nodeos/SHiP provisioning and TLS are separate operator tasks.
- No existing `/var/lib/telos-reth/mainnet`, `/var/lib/telos-reth-bootstrap/mainnet`, or
  `/etc/telos-reth/mainnet` installation. Do not run this over a live v1 or v2 node.

## Check, install, and start

```bash
python3.11 v3/install.py check --bundle /srv/telos-release-approved \
  --trust-key /etc/telos-release/authority-public.pem

sudo python3.11 v3/install.py install --bundle /srv/telos-release-approved \
  --trust-key /etc/telos-release/authority-public.pem

sudo python3.11 v3/install.py install --bundle /srv/telos-release-approved \
  --trust-key /etc/telos-release/authority-public.pem --start
```

Run `check` first on any platform; it does not change files or start services. On the target host,
`sudo python3.11 v3/install.py preflight --bundle ... --trust-key ...` checks the OS, root-owned
bundle, filesystem, binaries, and live nodeos without mutation. `install` is for a
**clean host only** and is not idempotent. It imports state with storage v2, recomputes and checks
the completed audit/anchor against the signed bundle, installs root-owned configuration and
systemd units, generates a local Engine JWT, and activates immutable binary digests. Without
`--start` it stages only. With `--start` it starts Reth, checks its loopback chain ID and signed
checkpoint anchor, then starts
the consensus companion and readiness timer. All listeners remain loopback-only; signer fields
are empty and no signing key is installed. The readiness timer may fail while the node catches up;
that is not permission to expose the RPC. Promotion needs a clean readiness result and an
independent public routing decision.

The signed snapshot/restore tools and units are staged but the snapshot timer is **not enabled**.
Review the installed root-only `backup.env.example`, replace the instance placeholder, and install
the resulting file as `backup.env` mode `0600`. Provision `restic.repository` and
`restic.password` as root-only systemd credential sources, run an authenticated remote snapshot and a cold-host
restore, then enable the timer under an approved backup policy. Its upstream schedule is every
six hours; the archival servers' three-day schedule is a separate policy. Never claim backup
coverage merely because the unit file exists.

If checkpoint import fails or is interrupted, the new data directory is invalid and cannot be
resumed. Preserve the error and audit evidence, then use a **new clean target**; the installer
does not delete partial data automatically. If service start fails, it disables the units it
enabled, but it retains installed files for inspection. No production routing changes are made.

For the authoritative checkpoint and operating procedure, see the upstream
[checkpoint bootstrap](https://github.com/telosnetwork/telos-reth-2/blob/main/docs/telos/checkpoint-bootstrap.md)
and [operations](https://github.com/telosnetwork/telos-reth-2/blob/main/docs/telos/operations.md)
documentation. Release sign-off is separate from this installer code.

## Offline tests

```bash
python3.11 -m unittest discover -s v3/tests -v
```

These tests cover signed-bundle acceptance and fail-closed paths. A real Ubuntu clean-host
rehearsal with an actual approved binary, state dump, nodeos/SHiP source, catch-up, snapshot,
restore, and shadow traffic is still required before production use.
