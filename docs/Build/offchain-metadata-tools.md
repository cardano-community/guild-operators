!!! important

    - An average pool operator may not require off-chain metadata tools. Verify
      whether they are required for your use
      [here](../build.md#components).
    - Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

This upstream project provides tools for creating and submitting off-chain
asset metadata. Guild Operators does not deploy it or pin its version in a
node release manifest; select and review an upstream release independently.

### Download pre-built binaries

Use the
[official releases](https://github.com/input-output-hk/offchain-metadata-tools/releases)
for stable binaries and place the reviewed executable in a directory on
`PATH`, such as `$HOME/.local/bin`.

### Build Instructions

The upstream project uses Nix for reproducible builds. The Guild
`cabal-build-all.sh` helper is not its supported build path.

Clone the repository, select a reviewed tag or immutable commit, and build
`token-metadata-creator` from the repository root:

``` bash
cd "$HOME/git"
git clone https://github.com/input-output-hk/offchain-metadata-tools.git
cd offchain-metadata-tools
git fetch --tags --force --prune origin
METADATA_TOOLS_REF='<reviewed tag or commit>'
git checkout --detach "$METADATA_TOOLS_REF"
nix-build -A token-metadata-creator
mkdir -p "$HOME/.local/bin"
install -m 0755 result/bin/token-metadata-creator \
  "$HOME/.local/bin/token-metadata-creator"
```

See the
[upstream manual](https://input-output-hk.github.io/offchain-metadata-tools/)
for Nix cache setup and other project components.

### Verify

Verify that the tool is executable from anywhere by running:

``` bash
token-metadata-creator -h
```
