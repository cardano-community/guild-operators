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

Wallet Encrypt and Decrypt load the smaller protection stack instead of the
query or creation libraries:

- `wallet-protection.sh` owns GnuPG discovery, staged encryption/decryption,
  Cardano signing-key validation, no-clobber publication, rollback cleanup,
  owner-only modes, and optional immutable locking; and
- `wallet-protection-ui.sh` owns eligible-wallet filtering, default-No
  confirmations, hidden passphrase entry, progress, and result tables.

New encryption requires 12 characters. Decryption intentionally accepts any
non-empty legacy passphrase without a line break. Passphrases travel only over
an inherited file descriptor and are unset after the operation; neither the
secret nor private key content enters command arguments or logs.
