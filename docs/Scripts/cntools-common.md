# CNTools common tasks

The step-by-step wallet and pool workflows documented for CNTools 13 do not
apply to the rewritten CNTools 14 framework.

!!! info "Current functional actions"
    Version 14.1.0 provides Wallet List and Wallet Show. These inspection
    actions may cache missing public wallet artifacts; all other operational
    entries remain placeholders.

## List wallets

Open **Wallet**, then select **List**. CNTools reads the existing configured
wallet directory and renders a multi-line entry for each wallet. The entry
shows its detected type, whether protected keys are present, and its primary
address. CNTools uses a combined base address when payment and stake
credentials are both present, an enterprise address for a payment-only wallet,
a reward address plus a missing-payment note for a stake-only wallet, and the
script address for a multisignature wallet. CLI and mnemonic wallets are shown
as separate types.

When live values are requested, base UTxO, payment UTxO, stake rewards, and the
inclusive total are separate rows. CNTools omits rows that do not apply to the
wallet rather than printing misleading zero or unavailable values. The native
asset row is also omitted for an ADA-only wallet; otherwise it shows the number
of distinct non-ADA assets.

Live data follows the selected startup mode. Local cnode and Dingo sessions
use the deployed Cardano CLI and node socket. Light mode deduplicates addresses
across the complete wallet catalog and sends size-bounded bulk Koios requests.
Before either backend is contacted, CNTools asks whether to fetch balances and
rewards. Select **No** for an immediate filesystem-only list without balance
rows, or **Yes** to run the query with a visible progress spinner.
Offline mode makes no live request or asks an unnecessary question, and local
Amaru explains that live values are unavailable. CNTools never substitutes a
false zero or incomplete total.

## Show a wallet

Open **Wallet**, select **Show**, then filter and choose a wallet. The action
always presents wallet identity and its relevant addresses and credentials in
Gum tables. Stake registration is part of the identity table. Mnemonic wallets
also show the exact value recorded in `derivation.path`; CLI wallets omit that
row. The credential table contains the applicable payment, stake,
multisignature-payment, multisignature-stake, and script hashes as lowercase
hexadecimal values without address header bits. Stake pool delegation and DRep
delegation remain clearly labeled in their own table. Additional information
depends on the startup mode:

- local cnode or Dingo queries the deployed Cardano CLI and local socket;
- local Amaru explains that live wallet queries are unavailable and continues
  showing filesystem details;
- light mode batches the wallet's funding addresses through Koios, queries its
  reward account for registration and delegation, and retrieves available
  Token Registry metadata for all held native assets in bounded bulk requests;
- offline mode performs no blockchain query or network request.

Native-asset quantities are aggregated exactly across the wallet's funding
addresses. One native-asset details table shows each asset's raw quantity,
policy ID, asset-name hex, and deterministic CIP-14 fingerprint. Light mode
adds the registered name, ticker, decimals, total supply, description, and URL
when Koios provides them. A metadata failure leaves the validated on-chain
properties visible. If the details are taller than the terminal, CNTools opens
the table in a Gum scroll view and returns to Wallet Show when it closes.

Before rendering, CNTools can fill a missing public artifact cache from an
available clear signing key or multisignature script. It creates only the
public verification keys, addresses, credentials, and applicable identifiers,
stores them under the configured legacy
filenames, and reuses them on later runs. Existing files are never overwritten,
and encrypted signing keys are never decrypted automatically. The derivation
is local and may run in offline or light mode when Cardano CLI is installed; it
does not contact a node. A malformed or symbolic-link artifact is reported
instead of replaced.

Wallet List and Show do not change private keys or submit transactions. If
only part of a live balance query succeeds, CNTools can show the individual
value it received but does not label it as the wallet total or show incomplete
UTxO and asset aggregates.

Operational guides will be added as the remaining modular actions are
implemented and tested. Until then, do not treat another visible menu entry as
a supported workflow.

For installation, modes, and the current interface contract, see the
[CNTools guide](cntools.md). Release progress is recorded in the
[CNTools changelog](cntools-changelog.md).
