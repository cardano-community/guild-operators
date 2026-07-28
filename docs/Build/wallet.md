!!! warning "Optional external component"
    An average pool operator does not need `cardano-wallet`; check the
    [component overview](../build.md#components). Guild Operators does not
    select or verify a wallet release in the cnode release manifest and does
    not deploy it for Dingo or Amaru. Review compatibility with the installed
    cardano-node release yourself.

cardano-wallet is maintained by the Cardano Foundation and is currently in
maintenance-only mode. Prefer a binary from the
[upstream releases](https://github.com/cardano-foundation/cardano-wallet/releases)
when one matches your node. The instructions below follow the project's
current Nix build workflow; the Guild `cabal-build-all.sh` helper is not a
supported wallet build path.

## Build

Install and configure the version of
[Nix required upstream](https://cardano-foundation.github.io/cardano-wallet/contributor/what/building.html),
then clone the repository and select a reviewed tag or immutable commit:

```bash
cd "$HOME/git"
git clone https://github.com/cardano-foundation/cardano-wallet
cd cardano-wallet
git fetch --tags --force --prune origin
WALLET_REF='<reviewed tag or commit>'
git checkout --detach "$WALLET_REF"
nix build
mkdir -p "$HOME/.local/bin"
install -m 0755 result/bin/cardano-wallet \
  "$HOME/.local/bin/cardano-wallet"
```

Do not substitute an unreviewed moving branch for `WALLET_REF` on an
operational host.

## Start against a cnode deployment

The wallet requires a running, fully synchronized cardano-node and its
node-to-client socket. For mainnet:

```bash
mkdir -p "$CNODE_HOME/priv/wallet"
cardano-wallet serve --port 8090 \
  --node-socket "$CNODE_HOME/sockets/node.socket" \
  --mainnet \
  --database "$CNODE_HOME/priv/wallet" \
  --token-metadata-server https://tokens.cardano.org
```

For preview or preprod, replace `--mainnet` with
`--testnet "$CNODE_HOME/files/byron-genesis.json"` and use the testnet token
metadata service documented for the selected wallet release.

## Verify

Query the local HTTP API and wait for `sync_progress.status` to become
`ready`:

```bash
curl -fsS http://127.0.0.1:8090/v2/network/information |
  jq '.sync_progress'
```

Wallet creation and recovery handle spendable funds and secret recovery
phrases. Follow the
[official cardano-wallet documentation](https://cardano-foundation.github.io/cardano-wallet/)
for the selected release, never paste a real recovery phrase into shell
history, and never fund a published example phrase.
