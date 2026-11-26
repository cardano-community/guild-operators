# CNTools

CNTools is a terminal application for Cardano wallets, stake pools, transactions,
governance and native assets. Its Bash-based application uses Charm Gum for
searchable menus, guided prompts and responsive tables.

Start it from your deployment's scripts directory:

```bash
./cntools.sh
```

Choose local node mode (default), Koios light mode (`-l`), or offline mode
(`-o`). Add `-a` to show advanced actions and theme selection.

## User guides

- [Overview, installation, modes and settings](../../../docs/Scripts/cntools.md)
- [Wallets, funds, pools and other common tasks](../../../docs/Scripts/cntools-common.md)
- [Release changelog](../../../docs/Scripts/cntools-changelog.md)

## Before using CNTools

Check the network in the header before creating or signing a transaction.
Keep secure, independent backups of private keys, recovery phrases and hardware
wallet recovery information. Never enter a hardware wallet's recovery phrase
into CNTools.

Transaction actions share a review showing the important effects, fee,
expiry and applied input/change settings. Choose live signing and submission,
signing without submission, or an unsigned package for offline signing.
Saved packages contain public transaction material, not private keys.

CNTools uses the deployment's `env` settings for paths, network, node access,
Koios and displayed dates. It stores user preferences separately, so changing a
theme or transaction default does not require editing the scripts.
