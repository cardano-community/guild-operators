# CNTools libraries

Catalyst uses `catalyst-key.sh` for separate voting identities and no-overwrite
publication, `catalyst-metadata.sh` for exact CIP-36 payload/signature validation
and CLI/hardware authorization, `catalyst-qr.sh` for secret-safe PIN-encrypted
Toolbox transport, `catalyst-query.sh` for official voter/delegator snapshot status, and
`catalyst-ui.sh` for the shared-table actions. `metadata-transaction-ui.sh`
provides the common fee-only metadata export/sign/submit review. These libraries
are loaded only when their corresponding actions are selected. Public metadata
and commands are logged; private voting material and PINs are never logged.

`private-keys.sh` inventories only explicit configured signing-key roles,
validates public companions, fingerprints the reviewed file identities in
memory, and performs exact confirmed unlinks with partial-failure reporting.
`private-keys-ui.sh` provides scope/encrypted-key choices, the exact-file preview,
backup acknowledgement and typed confirmation. It does not recursively erase a
directory or remove operational KES/VRF keys.

Cross-action parity helpers remain focused and lazy-loaded:
`wallet-selection.sh` supplies advisory role/registration/rewards candidates;
`wallet-utxo-local.sh` supplies the saved-address-only browser fallback;
`wallet-delegation-info.sh` enriches Wallet Show without replacing chain balances;
`pool-health.sh` provides read-only KES/counter diagnostics;
`public-metadata.sh` performs bounded unauthenticated byte-hash anchor checks;
`governance-voting-stats.sh` separates optional indexed voting-power statistics
from authoritative proposal identity. Unknown optional data is never fabricated.

KES rotation uses `pool-opcert-validation.sh` for bounded counter/certificate
parsing and cold-signature verification, `pool-kes.sh` for private durable
staging/offline issuance/counter-safe publication, and `pool-kes-ui.sh` for the
shared Gum review, confirmations and recovery hand-off. Read-only KES health
remains in `pool-health.sh`; the registration wizard's missing-only first
certificate remains separate in `pool-opcert.sh`. They share the issuance lock.

`pool-retirement.sh` validates current retirement bounds/state and the exact
cold-key certificate. `pool-retirement-ui.sh` supplies the guided epoch choice
and compact review. Registration, modification and retirement reuse the same
pool transaction plan/body guards and export/sign/submit/result flow; retirement
never applies an immediate pool deposit refund or requests owner stake witnesses.

Backup uses `backup-files.sh` for private staging, filesystem checks, bounded
archive inspection and no-overwrite publication; `backup.sh` for public/full
snapshots, manifest verification, GPG and conservative legacy restore; and
`backup-ui.sh` for the shared-table wizard, warnings and passphrase capture.
They reuse `filesystem.sh` facts without initializing a CLI or making
chain queries. Restore validates tar paths/types before unpacking only into
empty private staging, retains a complete recovery copy, never merges live
folders, and does not activate pending KES recovery state. The shared
`key-crypto.sh` supplies GPG transport with optional timeout/output bounds;
its existing key-protection callers keep their original defaults.
Passwords/private contents are not logged.

`blocklog.sh` reads and aggregates CNCLI SQLite journals through bounded,
read-only transactions without node/CLI queries or schema changes. It supports
optional schedule statistics, avoids ambiguous multi-pool ideal/luck values,
and owns only temporary query output. `blocklog-ui.sh` supplies the shared-table
summary, paged epoch records/details, status guide and manual refresh. Dates use
the core timezone formatter. Both actions work offline and clean staging on exit.

Libraries are sourced only by actions that declare their relative path.
Native policy creation uses `policy-files.sh` for private staging/no-overwrite
publication, `policy.sh` for single-signer scripts and verified key/hash creation,
and `policy-ui.sh` for the compact review. It shares strict wallet key-envelope
validation and transaction command/filesystem helpers without querying a node.
Expiry is reviewed once and never extended silently during generation.
`policy-catalog.sh` reads legacy/current policies and asset records and freezes
verified single-signer authority. `policy-manage-ui.sh` provides shared-table
inspection and optional cached Koios enrichment. `policy-protection.sh` and
`policy-lock.sh` use the common GPG transport for verified key replacement and
owner-only/optional immutable protection, including short legacy passwords.
`asset-transaction.sh` implements lossless native mint/burn, exact CLI fees,
input/value guards and policy-bound validity on the common funding, selection,
change and portable signing foundation. `asset-transaction-ui.sh` supplies its
common review/export/submit workflow. `asset-registry.sh` isolates and validates
token-metadata-creator exports, while `asset-registry-ui.sh` guides manual
registry submissions without claiming on-chain or registry acceptance.
All menu actions are functional; the former inert-action library is removed.

Shared UI primitives live in `presentation.sh`/`table.sh`, independent of wallet
queries. `filesystem.sh` owns portable stat/path/ancestry facts; callers retain
their role-specific ownership and permission policies. `bech32.sh` implements a
canonical byte-string codec; wallet/pool/governance wrappers enforce their own
network, credential-kind and length rules.

`transaction-balance.sh` owns action-neutral final-body fee convergence. Action
callbacks prepare inputs, outputs and their own certificates; domain validators
verify the final effects. Fees move both up and down to the exact CLI result,
including after hardware normalization. Optional ADA change cannot regrow during
a downward fee adjustment and cause a layout cycle. The cap lasts for one build
only and never changes user settings. Value-size validation counts actual CBOR
policy/name/quantity structure, sharing each policy key once.

`number.sh` is dependency-free and safe to source from the framework or an
individual action. It provides lossless, string-based handling of signed
integers and fixed-point decimal values of any practical length:

- `cntools_number_normalize_into OUTPUT INPUT` validates INPUT and writes its
  canonical, ungrouped value to OUTPUT;
- `cntools_number_format_into OUTPUT INPUT` validates INPUT and writes its
  US-formatted value with comma thousands separators to OUTPUT;
- `cntools_number_units_into OUTPUT INPUT SCALE` converts a non-negative human
  decimal to exact smallest units, rejecting excess precision (ADA uses scale 6);
- `cntools_number_format_units_into OUTPUT QUANTITY SCALE` displays exact
  smallest units with grouped integer digits and bounded metadata decimals;
- `cntools_number_normalize INPUT` and `cntools_number_format INPUT` print the
  corresponding value; and
- `cntools_number_is_valid INPUT` performs validation without producing output.

Ungrouped input may contain leading zeroes, while grouped input must use
canonical groups such as `1,234` or `12,345,678.90`. A leading `+` or `-` and a
decimal such as `.25` are accepted. Exponents, surrounding whitespace, and
malformed grouping are rejected. Fractional digits are preserved exactly;
floating-point arithmetic and the Bash integer range are never involved.
Invalid numeric input returns status 1, while an invalid API argument returns
status 2. The `*_into` functions clear their output before validating input.
Query values remain ungrouped internally; formatting is applied only to a
display copy so separators never enter arithmetic, CLI arguments, API payloads,
or persisted chain state.

Wallet List and Show declare this focused stack in dependency order:

- `number.sh` supplies shared display formatting and future input parsing;
- `wallet.sh` safely discovers wallet directories, validates the configured
  legacy artifacts, classifies wallet types, and builds the in-memory catalog;
- `wallet-material.sh` provides owned temporary files and atomic, missing-only
  publication for generated public artifacts;
- `wallet-key.sh` derives missing public verification keys from supported clear
  signing-key envelopes without logging key contents or decrypting protected
  keys;
- `wallet-address.sh` builds network-appropriate payment, reward, and base
  addresses from public keys or native scripts and selects the wallet's primary
  address;
- `wallet-id.sh` derives missing key and script credential hashes and computes
  local CIP-14 asset fingerprints; and
- `wallet-query-transport.sh` owns logged HTTP/CLI transport and temporary files;
- `wallet-query-local.sh` and `wallet-query-koios.sh` parse backend results;
- `asset-metadata.sh` owns asset inventory and source-aware metadata selection;
- `wallet-query.sh` coordinates the selected backend and query status;
- `wallet-list-query.sh` collects catalog-wide bulk results;
- `asset-view.sh` and `wallet-view.sh` render asset and wallet views.

Only List/Show load the complete catalog/view stack. Other actions declare the
focused helpers they actually use, rather than pulling in a wallet UI library.

Generated artifacts are validated before they are cached under the configured
legacy filename. An existing regular file, malformed artifact, or symbolic
link is retained and reported rather than overwritten. Temporary files use
mode `0600` and are removed after success or failure. Artifact derivation may
run in local, light, or offline mode when Cardano CLI is available because it
does not query a node. CIP-14 fingerprints are calculated from the policy ID
and asset-name bytes with deployed `b2sum` and the shared Bash Bech32 codec.

Wallet List deduplicates catalog-wide Koios inputs, splits payloads at a fixed
size bound, asks before fetching live values, shows progress through the shared
Gum spinner, and suppresses complete totals whenever a structurally required
funding or reward result is unknown. Other domain libraries are added only with
their functional action phases.

Wallet New → CLI reuses the focused key, address, credential, and
material helpers above, then adds two focused libraries:

- `wallet-create.sh` owns validation, private staging, exact wallet-shape
  checks, cleanup, and atomic no-clobber publication; and
- `wallet-create-ui.sh` owns the Gum name prompt, default-No confirmation,
  spinner, planned-artifact summary, and result tables.

Creation deliberately does not load `wallet-query.sh`: it is local work in all
runtime modes and neither contacts a node nor calls Koios.

Wallet New → Mnemonic and Import → Mnemonic extend that creation stack with two
focused libraries:

- `wallet-mnemonic.sh` owns phrase normalization, pinned Cardano CLI generation
  and standard CIP-1852 derivation, extended-key validation, derivation markers,
  secret-safe standard-input handling, and the mnemonic wallet inventory; and
- `wallet-mnemonic-ui.sh` owns generation backup presentation, responsive
  numbered word tables, four-word verification, paste import, BIP39
  filter-assisted interactive import, account/key-index prompts, progress, and
  result tables. Its offline selector reads the canonical English list from
  `../data/bip39-english.txt` once per action and keeps it in memory.

The recovery phrase never enters an argument, environment, persistent file, or
log. The generic creation publisher accepts a focused inventory validator so
CLI and mnemonic wallets can share one atomic commit boundary without weakening
their different artifact contracts.

Wallet Import → HW Wallet adds two focused libraries to the same publication
stack:

- `wallet-hardware.sh` discovers and version-checks `cardano-hw-cli` only when
  the action is selected, builds standard CIP-1852 paths, exports payment and
  stake hardware signing files in one device operation, validates their JSON
  envelopes, proves that each embedded public key matches its verification
  key, and enforces the exact hardware-wallet inventory; and
- `wallet-hardware-ui.sh` owns wallet/account/index input, device preparation,
  default-No confirmations, progress, planned paths, and result tables.

The action stores only public verification material and hardware signing
references; ordinary `.skey` files are forbidden by its validator. Account and
key index default to zero. The reusable path builder accepts numeric BIP32
purpose, account, role, and index components, while this action deliberately
permits only CIP-1852 payment role 0 and stake role 2. CIP-1854 multisignature
derivation lives in Advanced → MultiSig; governance derivation remains separate.

Wallet Encrypt and Decrypt load the smaller protection stack instead of the
query or creation libraries:

- `wallet-protection.sh` owns GnuPG discovery, staged encryption/decryption,
  Cardano signing-key validation, no-clobber publication, rollback cleanup,
  legacy directory-mode normalization, owner-only file modes, and optional
  immutable locking; and
- `wallet-protection-ui.sh` owns eligible-wallet filtering, default-No
  confirmations, hidden passphrase entry, progress, and result tables.

New encryption requires 12 characters. Decryption intentionally accepts any
non-empty legacy passphrase without a line break. Passphrases travel only over
an inherited file descriptor and are unset after the operation; neither the
secret nor private key content enters command arguments or logs.

Wallet Remove loads the normal wallet material and query stack, then adds two
focused libraries:

- `wallet-remove.sh` inspects UTxO and reward balances, stake registration,
  and any locally present DRep credential. It prefers the selected local node,
  can fall back to Koios when local state is unavailable, and treats every
  incomplete or offline result as a warning rather than assuming the wallet is
  empty. DRep state is queried separately through `drep-state` or Koios
  `drep_info` because vote delegation is not DRep registration; and
- `wallet-remove-ui.sh` owns the removal review, explicit warnings, default-No
  confirmation, progress, and result table.

Deletion is limited to one owned wallet directory directly below the configured
wallet root. Symbolic links, nested directories, special files, and entries
owned by another user are rejected. Immutable flags created by wallet
protection are removed when possible, files are unlinked without recursive
deletion, and the now-empty wallet directory is removed last.

Funds → Send adds focused lazy helpers to the wallet/transaction stack:

- `recipient.sh` validates receiving addresses and proves that a local native-script
  recipient matches its script. Handle resolution and external script destinations
  needing datum support are not implicitly accepted;
- `transaction-funding.sh` collects current protocol parameters, tip and exact
  inventories from a local node or bulk extended Koios queries;
- `funds-send.sh` prepares payment signers, native-asset demands, residual change,
  minimum ADA, bounded fee convergence and portable packages; and
- `funds-send-ui.sh` provides recipient editing, exact/max/sweep choices, review,
  output publication, signing and submission confirmations with stale-input checks;
- `funds-send-view.sh` keeps source/asset/review/result tables consistent with the
  shared theme, while `funds-send-files.sh` separates tracked intermediate files
  from uniquely named persistent transaction exports. Recipient drafts roll back
  on cancellation; signer details are opt-in, while raw decoded JSON is logged only;
- `transaction-metadata.sh` freezes custom JSON without rewriting integer literals,
  rejects duplicate keys, builds UTF-8-safe CIP-20 messages and attaches metadata;
- `message-crypto.sh` uses OpenSSL for compatible CIP-83 basic encryption and a
  local decryption check, with passphrases on private descriptors;
- `send-metadata-ui.sh` supplies optional message protection/import controls and
  lossless, escaped metadata-path table previews; and
- `handle.sh` resolves classic/CIP-68 root, NFT and virtual subhandles through Koios using
  the authenticated on-chain policy registry. It checks tip freshness, policy
  windows, supply and current UTxOs. `handle-virtual.sh` decodes the label-000
  inline datum, validates its ADA destination and records its public/private lease
  and millisecond expiry. It never falls back to a parent or contract address.
  `recipient.sh` converts address bytes to Bech32 in Bash and validates the result
  without adding a binary dependency. Virtual lease changes require renewed review.

Send's Message / metadata entry is optional. Custom imports require advanced mode
and accept one Simple or Detailed JSON file (64 KiB maximum, canonical decimal
labels, integer literals, 32 nesting levels/4096 values). Ledger/schema validation
is performed by the pinned CLI when building. Label 674 conflicts are rejected.
Encryption affects only the message; the public `cardano` passphrase provides no
confidentiality. Custom passphrases are not wallet passwords and must be shared
separately. CBC has no authentication tag. Only ciphertext is packaged; no message
password is needed for offline signing. OpenSSL must support PBKDF2 and the CIP-83
8-byte salt format. Logs never contain custom message passwords or encrypted-mode
plaintext. The JSON schema and final metadata are included in fee/size handling.

Handle resolution is an explicit recipient choice, never an interpretation of
arbitrary external-address text. Local and light modes both use the configured
Koios service; offline lookup is rejected. Mainnet/preview/preprod have reviewed
bootstrap identities, but lookup still requires a valid live registry on that
network. Candidate and supply lookups are bulk calls per recipient. Evidence is
stored in the package intent, while the transaction itself pins the actual address.
Live rechecks stop on changed destinations; existing packages are never redirected.

`cntools_coin_select_value LOVELACE DEMAND_ARRAY STRATEGY` extends the shared
selector with an associative policy/name-to-quantity demand. Change planning sees
only the unsent asset quantities. ADA arithmetic and asset quantities stay exact
integer strings throughout. Send never implicitly withdraws rewards or deposits.

Transaction actions use five lazy libraries:

- `transaction.sh` owns the signer plan, native-script requirements, public
  package schema, body/package binding, and exact validation;
- `transaction-build.sh` provides guarded Cardano CLI builders and fee
  calculation without allowing callers to override foundation-owned signer,
  network, validity, or output arguments;
- `transaction-sign.sh` adds verified CLI and hardware witnesses incrementally,
  prepares hardware-compatible bodies, and assembles the signed envelope;
- `transaction-submit.sh` validates complete packages or signed envelopes and
  submits through a ready local node or Koios; and
- `transaction-ui.sh` owns package selection, decoded review, confirmations,
  signer-source prompts, progress, and result presentation.

A finalized plan deduplicates required witnesses by distinct public key while
retaining merged labels and roles. The portable CNTools package contains only
public material and can move between signing systems. The intent summary is
descriptive; Cardano CLI's decoded transaction body or signed envelope is the
authoritative review. Sign therefore accepts a package, not an arbitrary
unsigned body whose signer plan cannot be proved. Future transaction-producing
actions must follow the shared plan → build → package APIs.

The action-facing sequence is intentionally small:

1. Call `cntools_transaction_plan_reset INTENT DESCRIPTION ASSURANCE`, then
   optionally set a JSON summary and validity bounds.
2. Register each distinct signer with `cntools_transaction_plan_add_signer`, or
   its public-only equivalent. Reusing a public key merges its labels and roles
   instead of increasing the witness count. Roles retain action/UI context;
   every planned credential is also written into the body's explicit required
   signer set so the portable plan cannot silently lose a signer.
3. Register any embedded/reference native scripts and hardware change keys.
   An action—not a key directory—defines each hardware group that must share
   one device invocation. Reference scripts use
   `cntools_transaction_plan_add_native_reference_script LABEL PURPOSE
   SCRIPT_FILE REFERENCE_INPUT KEY_ID...`, where `REFERENCE_INPUT` is the
   exact lower-case `transaction-id#output-index` consumed by the body.
4. Call `cntools_transaction_build_body` with `build`, `build-estimate`, or
   `build-raw`. The foundation injects network, validity, canonical-CBOR,
   output, and exact witness-count arguments; callers cannot override them.
5. Call `cntools_transaction_package_create BODY NEW_PACKAGE`. When hardware
   signers are planned, the action must also load `transaction-sign.sh` so the
   body is hardware-validated or transformed before any witness exists.

An action that registered runtime key sources may then use
`cntools_transaction_sign_registered INPUT_PACKAGE NEW_PACKAGE`; the generic
Sign screen uses `cntools_transaction_sign_package` after matching operator
selected sources to public key IDs. Every output path must be new. Inputs are
snapshotted into the private action session, and publication never overwrites
an existing file. Witness public keys and signatures are parsed from the pinned
Cardano CLI review format, and each detached Ed25519 signature is verified over
the raw 32-byte transaction-body ID with OpenSSL 3 or newer before a package is
accepted. `xxd` performs the strictly validated hex decoding; these tools are
resolved only for witness-bearing packages.

Native-script plans bind the selected `all`, `any`, or `atLeast` branch and its
validity requirements. Embedded scripts receive exact assurance only when the
body has no reference inputs. Every transaction containing a reference input
retains manual assurance because the referenced on-chain output cannot be
proved from the portable body alone. Declared native reference scripts are
bound to their exact input; the signing review displays the purpose, script
hash, selected signer keys, reference input, and declared script before
confirmation.
CLI and hardware witnesses may be added over
multiple runs, including offline. An originating action defines atomic hardware
session groups: all still-missing group signers and all group change references
must be selected for one device call. Change HWS files are separate inputs, do
not create witnesses, and accept only standard CIP-1852 payment roles `0`/`1`
or stake role `2`. General signing accepts supported non-Byron Cardano HWS
sources. CNTools leaves `--derivation-type` unset, which currently selects the
Trezor-only `cardano-hw-cli` default, `ICARUS_TREZOR`.

Submit accepts a complete validated package or an external Cardano transaction
envelope. Package completeness is proven by the signer plan. For an external
envelope, CNTools authenticates every supported Shelley VKey witness present,
but cannot infer the complete witness requirement; the review marks it
unverified and leaves final ledger validation to the local node or Koios.
External Byron/bootstrap witness sets are rejected. Submission prefers a ready
local node and falls back to enabled Koios access; offline submission is
prohibited. The transaction contracts use the pinned
Cardano CLI `11.2.3.1` from the cnode deployment pin, and hardware signing requires the exact tested
`cardano-hw-cli` release `1.19.1`. Package, signer-source, hardware-change,
output, review, and submission selections are recorded in the normal CNTools
audit log without logging key contents. The Cardano CLI version is validated
lazily on the first transaction operation and then retained for the session.

### Multisig adapters

`multisig-key.sh` adds separate participant key pairs without replacing wallet
keys; custom software recovery paths use the pinned `cardano-address` companion
over stdin, and hardware paths use the existing device/export validation.
`multisig-wallet.sh` creates deterministic threshold payment/stake scripts and
publishes only the validated public wallet shape. `multisig-ui.sh` owns the
guided participant/threshold/path/timelock review, not transaction construction.

`multisig-spend.sh` adapts Send/Collect to frozen native scripts and an explicitly
chosen signer subset. It verifies script/address binding, checks mandatory time
bounds, registers public identities/runtime sources with the shared signer plan,
and attaches the script to each selected input. The ordinary transaction
foundation remains responsible for exact fees, witness verification, hardware
preparation, offline collection and package completeness.

`multisig-stake.sh` adapts registration, de-registration, pool/voting delegation
and withdrawal without duplicating balancing or state checks. It verifies
frozen payment/stake scripts against all wallet addresses, selects the two
participant subsets independently, intersects their mandatory time bounds with
the requested TTL, and registers each script's spend/certificate/withdrawal
purpose. The shared signer plan merges a key used by both scripts into one
witness with both roles. Builders attach the payment script per input and the
stake script to its certificate or withdrawal; deposits/refunds, reward gates,
rechecks and portable offline packages retain the ordinary action contract.
Distinct-signature `atLeast` branches with optional mandatory time bounds are
supported; arbitrary alternative branches and committee identities remain
deferred. Pool operator identities retain their existing key-wallet guards;
DRep transactions use the separate script authorization adapter below.

`drep-script.sh` owns public-participant validation, deterministic threshold
DRep creation, no-overwrite/inode-tracked publication and native-script identity
inspection. It shares the native script writer, CLI script-hash verification
and CIP-129 encoder rather than introducing a second signing implementation.
`drep-script-ui.sh` owns cancellable participant/threshold review. No private
participant keys are copied and no transaction is created. The key inspector
routes script identities to this focused helper; Info & Status and local voting
delegation targets reuse it. Cached-only offline inspection is explicitly
unverified against the script.

`multisig-drep.sh` adapts the existing DRep registration/update/retirement and
vote builders to script credentials. Payment and DRep subsets have isolated
selection state and independent thresholds; their mandatory time bounds are
intersected with the requested expiry. Shared signer IDs merge into one witness
with both purposes. The shared transaction plan binds each embedded script,
selected signer set and interval to the body, while existing operation-specific
validators still check exact certificates/votes, deposits, anchors and change.
Key DReps may also use multisig funding. Source paths stay in runtime memory;
portable public packages support independent offline participants. No parallel
fee, signing or submission implementation is introduced.

### Calidus identity setup

`calidus-id.sh` combines the CLI's role-neutral Blake2b-224 public-key hashing
with the existing checksum-tested Bech32 encoder (`a1`, HRP `calidus`).
`pool-calidus.sh` validates normal/extended payment envelopes, stages imports
and generation, verifies pairs/IDs and publishes only new files. Repair never
replaces cached public artifacts. Inode-tracked cleanup precedes pool staging
cleanup on interruption. No cold/node signing keys are read or modified and
no network or transaction API is used by key setup. `pool-calidus-ui.sh` owns the
pool chooser, cancellation, plaintext-key warning and compact local status.
`pool-protection.sh` uses the shared GPG transport for cold and Calidus keys.
It prepares/validates every key before publishing, publishes every counterpart
before retirement, and tracks snapshots/inodes for partial-retirement recovery.
`cntools_calidus_signing_matches` verifies staged normal/extended keys against
optional public keys and cached IDs without publishing plaintext for inspection.
KES/VRF keys and public identities are never encrypted. Hardware/watch-only
cold identities may coexist with a protected Calidus key; lock-only needs no
password when there are no local signing keys to transform.
`calidus-registration.sh` freezes the public identities, verifies the complete
CIP-151/CIP-88-v2 cold-key authorization using Cardano Signer, and queries the
latest indexed Koios nonce (including revocation). `metadata-transaction.sh`
adapts Send's existing selection/change/exact-fee engine with no recipients;
it excludes datum/reference-script funding and compares the complete decoded
metadata against the frozen authorization. Only funding witnesses enter the
transaction plan. `pool-calidus-registration-ui.sh` provides public metadata
export, compact shared review/expiry/workflow controls and live state rechecks.
Registration and revocation share this pipeline with an explicitly bound
operation. Revocation targets CIP-151's zero public key, requires only the pool
cold identity, never inspects local Calidus files, and cannot import registration
metadata. The UI confirms revocation with default No and skips transactions for
already revoked/unindexed records. Both operations recheck the full reviewed
indexed state before build/sign/submit and retain signed recovery packages.
Offline authorization does not need chain access; online construction requires
Koios for nonce lookup, while funding keeps the configured local/Koios preference.
