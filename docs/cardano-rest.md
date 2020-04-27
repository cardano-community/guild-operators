### Setup Cardano-Rest

This guide assumes you are using the common directory structure.

#### Install Instructions

```bash
# Clone the cardano-rest repository from github

cd; cd git
git clone https://github.com/input-output-hk/cardano-rest.git
cd cardano-rest
cabal update
cabal build all
```

Now you can copy the binary builds (using location below) into ~/.local/bin folder (when part of the PATH variable).

```bash
/cardano-rest/dist-newstyle/build/x86_64-linux/ghc-8.6.5/cardano-explorer-api-2.0.0/x/cardano-explorer-api/build/cardano-explorer-api
/cardano-rest/dist-newstyle/build/x86_64-linux/ghc-8.6.5/cardano-explorer-api-2.0.0/x/cardano-explorer-api-compare/build/cardano-explorer-api-compare
/cardano-rest/dist-newstyle/build/x86_64-linux/ghc-8.6.5/cardano-explorer-api-2.0.0/x/cardano-explorer-api-validate/build/cardano-explorer-api-validate
```


#### Start the REST server
```bash
export PGPASSFILE=opt/cardano/cnode/priv/.pgpass
cardano-explorer-api
```

Expected output should be similar to the following

```text
Running full server on http://localhost:8100/
```
