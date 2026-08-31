# CNTools libraries

Libraries are sourced only by actions that declare their relative path.
`placeholder.sh` provides the shared inert-action notice used by the Phase 4
menu skeleton. Wallet List and Show declare this focused stack in dependency
order:

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
  List and Show values.

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
