# CNTools compatibility checker

Run `cntools-check.sh` separately from CNTools when evaluating a new Cardano CLI,
node, Koios API or companion-tool release. It prints grouped checkmarks and saves
a JSON report with command output and failure details. It does not install tools,
change supported versions or add anything to the CNTools menus.

## Run the CLI checks

From the repository root, with Bash 4.4 or newer and `jq` installed:

```sh
bash scripts/compatibility/cntools/cntools-check.sh --cli /path/to/cardano-cli
```

Run this against the currently deployed version first, then run it against the
candidate executable. Keep both report folders. The version check records the
candidate and the cnode deployment pin; a different candidate version is allowed
for testing, but passing checks do not change CNTools' production version guard.

The CLI group actually creates disposable payment, stake, DRep, pool, VRF and KES
keys; derives mnemonic keys; builds addresses and certificates; hashes metadata;
and builds, decodes, signs and assembles transaction fixtures. Scenarios include
native assets, minting, native scripts, messages, stake registration/de-registration,
delegation, DRep registration/update/retirement, pool registration/retirement,
withdrawals and voting. It checks minimum ADA, estimate-builder change, exact
asset quantities, transaction IDs and minimum fees against the signed transaction
size. No extra fee margin is added.

These are command/output compatibility fixtures, **not transactions accepted by
the ledger**: their inputs and chain state are synthetic. They cannot replace
funded isolated-network integration tests. Online `build` and `submit` are checked
for command availability only, clearly labelled `syntax`.

## Node and Koios checks

Create a copy of `lib/public-identities.example.json` (next to this guide) and fill in public
identities from the network you want to test. Never include signing keys, recovery
words or passwords. Omit fields you do not need, or leave them empty:

- `address`: an existing funded payment or base address.
- `stake_address`: an existing registered stake address.
- `payment_credential`: the 56-character payment credential hex.
- `pool_id`, `drep_id`: registered Bech32 identifiers.
- `tx_hash`: a confirmed 64-character transaction hash.
- `asset`: `policy_id.asset_name_hex`, including the dot for an empty asset name.
- `proposal_id`: a CIP-129 `gov_action1…` identifier. Prior-vote coverage also needs
  a DRep with a vote on that proposal; active proposals are fetched separately.

All fields must be strings. Set `network` to the selected network. Choose fixtures
with non-empty records: a valid empty response is reported as **not exercised**,
not proof that a changed record format still works. UTxOs and active proposals can
disappear over time, so refresh public identities when needed.

The identities are lookup targets, not expected response snapshots. Pass your
completed copy with `--fixtures /path/to/public-identities.json`; the checker uses
these values in its read-only node queries and Koios requests. You can use public
identities from any wallet on that network, not necessarily your own. Leave
unneeded entries empty: checks that require them will be marked not exercised.
The default CLI suite uses disposable generated keys and does not need this file.

```sh
bash scripts/compatibility/cntools/cntools-check.sh \
  --suite node \
  --cli /path/to/cardano-cli --node /path/to/cardano-node \
  --socket /opt/cardano/preview/sockets/node.socket --network preview \
  --metrics http://127.0.0.1:12798/metrics \
  --fixtures /path/to/public-identities.json

bash scripts/compatibility/cntools/cntools-check.sh \
  --suite koios --network preview \
  --koios https://preview.koios.rest/api/v1 \
  --fixtures /path/to/public-identities.json
```

No node or API is contacted by default. Node checks are read-only and require an
explicit socket. The metrics URL is also explicit. API requests are rate-paced,
bounded by time and response size, use the bulk request shapes and filters CNTools
consumes, and include wallet transaction/UTxO inventories, transaction information
and status, pool/DRep data, assets and governance. Production parsers validate
wallet, UTxO, history, asset metadata, pool, DRep and proposal responses where
available. Already captured API responses are fed into these parsers without a
second API request or writing a production cache.

A connected node does **not** enable complete coverage automatically. With public
fixtures and a metrics URL, the node group tests tip, protocol parameters, UTxOs,
stake registration/rewards, pool state, DRep state, governance proposals and health
metrics. Missing fixtures or empty records are reported as not exercised. Live
auto-balancing, ledger acceptance/submission, the KES-period query and all possible
chain-state/output variants are not covered by these read-only tests.

Use `KOIOS_API_TOKEN` in the environment if authentication is required. It is passed
through a private temporary header file, removed from child environments and
redacted from saved output. Copyable API requests are saved as `request.txt`, with
the token replaced by a placeholder. Do not use secrets in lookup identities or
endpoint URLs. Reports can reveal public wallet activity; treat them accordingly.

Network names supported: `mainnet`, `preview`, `preprod`, `guild`. Use
`--testnet-magic N` to override the testnet magic. The checker does not silently
fall back to another node or API.

## Companion tools and coverage

```sh
bash scripts/compatibility/cntools/cntools-check.sh \
  --suite cli,tools,coverage --cli /path/to/cardano-cli
```

Put candidate companion executables on `PATH`. GPG uses an isolated temporary
home and tests AES-256 round-trips, including legacy short-password decryption.
OpenSSL checks CIP-83 encryption and valid/invalid Ed25519 signatures. Cardano
Address checks custom CIP-1854 derivation and CLI conversion. Cardano Signer checks
Catalyst key generation and Calidus authorization/verification.

Hardware CLI checks run without a device. Supply `--hw-cli /path/to/cardano-hw-cli`
or put the candidate on `PATH`. They check its version output and compare the
actual CNTools argument names, extracted from source, against help for device
version, wallet/multisig key export, transaction validation/transformation/witnessing,
pool key export/operational certificates and Catalyst registration metadata.
Removed arguments fail even if `--help` itself succeeds. These are labelled
`syntax`: help cannot prove argument value types, repeat semantics or device
output compatibility. Disposable ADA and native-asset transaction validation and
transformation are also executed, checking canonical transaction ID preservation.
Hardware signing, key export and real device approval are not automated; no
device is contacted. Catalyst Toolbox checks command availability only. Token
Metadata Creator checks disposable entry creation, attestation, finalization and
validation. Tar/gzip archive round-trips and read-only SQLite JSON queries are
also tested. Missing companions are reported, never installed automatically.

`coverage` requires `rg` and saves a source-call inventory, API route inventory and
coverage notes. A new unmapped literal Koios route fails this check. The inventory
is a review aid: dynamically built commands still need explicit tests when added.
Full Handle resolution, all token metadata display standards,
off-chain metadata, GitHub updates, Catalyst REST, immutable attributes and UI
interfaces are not yet fully contract-tested. They are explicitly recorded as
coverage gaps, not represented as passing features.

Use `--suite all` to request every group, supplying the node/API/fixture options
above. Run `--help` for all options.

## Read results

- `✓ … [executed]`: real command/request succeeded and its stated contract passed.
- `✓ … [syntax]`: command/help contract only; no workflow or ledger acceptance claim.
- `✓ … [discovery]`: source inventory matched the known catalog.
- `✗`: command or expected output mismatch. The failure shows the assertion or
  diagnostic and points to saved output.
- `!`: blocked by a prerequisite, node connection, timeout, authentication, rate
  limit or service availability problem.
- `–`: not exercised, for example missing optional public fixtures or hardware.

Exit status is `1` for a failure, `2` for blocked checks or invalid invocation, and
`0` otherwise. **Exit 0 is not exhaustive coverage**: always review the counts and
coverage levels. Optional skips do not fail the whole run. JSON reports contain
individual levels, results, diagnostics and artifact paths for automation.

Each run creates a private report directory and prints its location. Use
`--report-dir /absolute/new/path` to choose a new directory; existing paths are
never overwritten. Each check has `details.log`, command/request logs and captured
responses as applicable. `report.json` combines the results. Secret-bearing
mnemonic/derivation output is never retained. Disposable keys and working files
are removed on exit; reports remain until you remove them.

The checker never sources `env`, loads real wallet/pool keys, contacts hardware,
submits a transaction, or modifies a deployment. Run it with normal user
permissions, not as root. CLI fixtures use the included synthetic Conway protocol
parameters in `lib/data/protocol.json` for deterministic offline checks. This file
is not fetched or replaced when a node is available. The node and Koios suites
fetch live protocol parameters and check their response contracts separately;
those responses are saved with the reports, not substituted into the CLI fixtures.

## Add a compatibility check

Keep new checks in the appropriate small library under `lib/`. Register each
with a stable report ID, a useful label and its real coverage level. Execute the
same arguments and response shape used by CNTools, reuse its parsers where
possible, and assert identities, types and exact integer values rather than
hashing whole outputs that legitimately change between runs. Never mark an empty
response or a successful `--help` as full integration coverage. Add new endpoints
to the coverage catalog and document any test prerequisites.
