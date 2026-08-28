# CNTools common tasks

The step-by-step wallet and pool workflows documented for CNTools 13 do not
apply to the rewritten CNTools 14 framework.

!!! info "Current functional actions"
    Version 14.1.0 provides read-only Wallet List and Wallet Show. All other
    operational entries remain placeholders.

## List wallets

Open **Wallet**, then select **List**. CNTools reads the existing configured
wallet directory and shows each wallet's detected type, whether protected key
files are present, and how many standard address files are available. This
does not query the blockchain or change any wallet file.

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
