# CNTools common tasks

The step-by-step wallet and pool workflows documented for CNTools 13 do not
apply to the rewritten CNTools 14 framework.

!!! info "Current functional actions"
    Version 14.1.0 provides read-only Wallet List and Wallet Show. All other
    operational entries remain placeholders.

## List wallets

Open **Wallet**, then select **List**. CNTools reads the existing configured
wallet directory and shows each wallet's detected type, whether protected key
files are present, its non-ADA token count, rewards, UTxO balance, and an
inclusive total. CLI wallets and wallets derived from a mnemonic are shown as
separate types.

Live columns follow the selected startup mode. Local cnode and Dingo sessions
use the deployed Cardano CLI and node socket. Light mode deduplicates addresses
across the complete wallet catalog and sends size-bounded bulk Koios requests.
Before either backend is contacted, CNTools asks whether to fetch balances and
rewards. Select **No** for an immediate filesystem-only list with `—` in the
live columns, or **Yes** to run the query with a visible progress spinner.
Offline mode makes no live request or asks an unnecessary question, and local
Amaru leaves the live columns unavailable. CNTools never substitutes a false
zero or incomplete total.

## Show a wallet

Open **Wallet**, select **Show**, then filter and choose a wallet. The action
always shows the validated address files it can read. Additional information
depends on the startup mode:

- local cnode or Dingo queries the deployed Cardano CLI and local socket;
- local Amaru explains that live wallet queries are unavailable and continues
  showing filesystem details;
- light mode batches the wallet's funding addresses through Koios, then queries
  its reward account for registration and delegation;
- offline mode performs no external command or network request.

Missing or malformed addresses are reported but never regenerated. Wallet
List and Show do not create keys, decrypt files, submit transactions, or alter
the existing wallet layout. If only part of a live query succeeds, CNTools can
show the individual value it received but does not label it as the wallet total
or show incomplete UTxO and asset aggregates.

Operational guides will be added as the remaining modular actions are
implemented and tested. Until then, do not treat another visible menu entry as
a supported workflow.

For installation, modes, and the current interface contract, see the
[CNTools guide](cntools.md). Release progress is recorded in the
[CNTools changelog](cntools-changelog.md).
