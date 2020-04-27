### Setup Cardano-Rest

This guide assumes you are using the common directory structure.

#### Install Instructions

Clone the cardano-rest repository from github

```bash
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
```text
Running full server on http://localhost:8100/

```
#### Verify the REST server is functioning
```bash
curl http://localhost:8100/api/blocks/pages
```

Expected output should be similar to the following
```json

{"Right":[261,[{"cbeEpoch":4,"cbeSlot":9345,"cbeBlkHeight":2605,"cbeBlkHash":"9026612cfa53b7f8a84ff62c4e897830db9ab6ce24b19e0059f4b4db7a14c0f9","cbeTimeIssued":1587974365,"cbeTxNum":0,"cbeTotalSent":{"getCoin":"0"},"cbeSize":631,"cbeBlockLead":"464835a0904109be93d7996b9b4acc486f6c8f75a595b2c4392f9521","cbeFees":{"getCoin":"0"}},{"cbeEpoch":4,"cbeSlot":9341,"cbeBlkHeight":2604,"cbeBlkHash":"24000e2986bbfbfd610cb105d3697cce7582b8570469c4ff944b91d7dd0dc58f","cbeTimeIssued":1587974325,"cbeTxNum":0,"cbeTotalSent":{"getCoin":"0"},"cbeSize":631,"cbeBlockLead":"1ce88674d08d7813c5281e38e8a43b51550292f0bd8907b17a62eef2","cbeFees":{"getCoin":"0"}},{"cbeEpoch":4,"cbeSlot":9338,"cbeBlkHeight":2603,"cbeBlkHash":"5c2737421b223d1ab67f1046f8841d57d7f8456b77a841702fbb18bccf71a216","cbeTimeIssued":1587974295,"cbeTxNum":0,"cbeTotalSent":{"getCoin":"0"},"cbeSize":631,"cbeBlockLead":"f6a4cfa43cef5ebed8fbd0527153f9896d1f9dd83bd1d55e609d622b","cbeFees":{"getCoin":"0"}},{"cbeEpoch":4,"cbeSlot":9333,"cbeBlkHeight":2602,"cbeBlkHash":"496db1bc19d609687185e394cfcb8fa15e8df652c7dc40a58a347e30b9e4a25f","cbeTimeIssued":1587974245,"cbeTxNum":0,"cbeTotalSent":{"getCoin":"0"},"cbeSize":631,"cbeBlockLead":"a7cad2c48edecff1627bac50aab5fcc6831f6ab91131721269850805","cbeFees":{"getCoin":"0"}},{"cbeEpoch":4,"cbeSlot":9332,"cbeBlkHeight":2601,"cbeBlkHash":"8a837d43685dd350c6f1773b1ede7843d56d093a425ff4ccd799f7ff1b76204d","cbeTimeIssued":1587974235,"cbeTxNum":0,"cbeTotalSent":{"getCoin":"0"},"cbeSize":631,"cbeBlockLead":"a18aa0130f67053ed1cb346813054e160687a8ee7602a549f8ae165b","cbeFees":{"getCoin":"0"}}]]}
```
