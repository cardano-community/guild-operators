# CNTools libraries

Libraries are sourced only by actions that declare their relative path.
`placeholder.sh` provides the shared inert-action notice used by the Phase 4
menu skeleton.

`number.sh` is dependency-free and safe to source from the framework or an
individual action. It provides lossless, string-based handling of signed
integers and fixed-point decimal values of any practical length:

- `cntools_number_normalize_into OUTPUT INPUT` validates INPUT and writes its
  canonical, ungrouped value to OUTPUT;
- `cntools_number_format_into OUTPUT INPUT` validates INPUT and writes its
  US-formatted value with comma thousands separators to OUTPUT;
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
- `wallet-query.sh` adds bounded local and bulk Koios queries for live Wallet
  List and Show values, classifies assets from total supply, selects one
  source-aware metadata document, and builds bounded inline native-asset views.

Generated artifacts are validated before they are cached under the configured
legacy filename. An existing regular file, malformed artifact, or symbolic
link is retained and reported rather than overwritten. Temporary files use
mode `0600` and are removed after success or failure. Artifact derivation may
run in local, light, or offline mode when Cardano CLI is available because it
does not query a node. CIP-14 fingerprints are calculated from the policy ID
and asset-name bytes with the deployed `b2sum` and `bech32` tools.

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
and governance derivation remain separate future actions.

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
Cardano CLI `11.0.0.0`, and hardware signing requires the exact tested
`cardano-hw-cli` release `1.19.1`. Package, signer-source, hardware-change,
output, review, and submission selections are recorded in the normal CNTools
audit log without logging key contents. The Cardano CLI version is validated
lazily on the first transaction operation and then retained for the session.
