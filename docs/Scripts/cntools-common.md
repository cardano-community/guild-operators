# CNTools common tasks

The step-by-step wallet and pool workflows documented for CNTools 13 do not
apply to the rewritten CNTools 14 framework.

!!! info "Current functional actions"
    Version 14.0.0 provides Wallet New → CLI, Wallet List, and Wallet Show.
    List and Show may cache missing public wallet artifacts; all other
    operational entries remain placeholders.

## Create a CLI wallet

Open **Wallet → New → CLI**, enter a wallet name, review the planned location
and contents, and confirm creation. A wallet name must begin with a letter or
number, may contain letters, numbers, periods, underscores, and hyphens, and
may be at most 64 characters long. An existing file, directory, or symbolic
link with the same name is never replaced. The confirmation defaults to
**No** because the new signing keys must be backed up securely.

CNTools generates one standard payment key pair and one stake key pair, then
derives the payment, reward, and combined base addresses and their raw
hexadecimal credential hashes. It intentionally does not generate governance,
committee, or multisignature keys; those belong to separate future actions.
Because a CLI wallet has no `derivation.path`, Wallet List and Show identify it
as **CLI**.

The action works in local, light, and offline modes when Cardano CLI and the
selected Cardano network are configured. It performs no node or Koios query.
All artifacts are first generated and validated inside a private hidden
staging directory. CNTools publishes the whole wallet in one no-overwrite
operation only after every expected artifact is valid and each verification
key has independently been proven to match its signing key. A handled failure
or interruption cannot leave a partially created wallet in the catalog.
An uncatchable process kill or power loss may leave a hidden
`.cntools-wallet-new.*` staging directory containing private key material;
CNTools excludes and logs it rather than treating it as a wallet.

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

Tables expand with the terminal up to a readable maximum. Addresses and hashes
therefore remain unbroken when sufficient width is available and wrap only on
narrower terminals. Balances, counts, token quantities, and other numeric
values use comma thousands separators and a period decimal separator.

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

- local cnode or Dingo queries the deployed Cardano CLI and local socket, then,
  when `ENABLE_KOIOS=Y`, enriches native-asset metadata through Koios without
  replacing local wallet data;
- local Amaru explains that live wallet queries are unavailable and continues
  showing filesystem details;
- light mode batches the wallet's funding addresses through Koios, queries its
  reward account for registration and delegation, and retrieves available
  token metadata for all held native assets in bounded bulk requests;
- offline mode performs no blockchain query or network request.

Native-asset quantities are aggregated exactly across the wallet's funding
addresses, and the Balances table includes the number of distinct assets. The
rest of Wallet Show is rendered before the user chooses `Simple`, `Detailed`,
or `Skip` for native-asset output. An asset is classified as `NFT` when its
current total supply is exactly one and as `FT` otherwise. NFT rows omit wallet
amount, total supply, ticker, and decimals. Simple shows the remaining relevant
identity and holding fields; Detailed appends the selected metadata document's
retained fields as an inline compact tree. Missing fields are omitted, while
safety limits use explicit omission markers instead of silently dropping
content.

Metadata precedence remains driven by the applicable standard label. CIP-67
label `222` prefers CIP-68 and then exact CIP-25 label `721`; label `333`
prefers CIP-68, transaction metadata label `20`, and then the Token Registry;
and label `444` prefers CIP-68 and then the Token Registry. Unlabelled assets
retain label `20`, Token Registry, and exact label `721` fallback coverage. The
table identifies both the selected standard and Koios API as its source. A
metadata failure leaves validated holdings visible.

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
