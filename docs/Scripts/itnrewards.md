#### Concept

To claim rewards earned during the Incentivized TestNet the private and public keys from ITN must be converted to Shelley stake keys. A script called `itnRewards.sh` has been created to guide you through the process of converting the keys and to create a CNTools compatible wallet from were rewards can be withdrawn. 

<!--details>
<summary>Expand to view</summary-->

```mermaid
graph TB
    A(["<font size=5>itnRewards.sh"])
    A --x B{{"ITN Owner skey (ed25519[e]_sk).."}} --x D(["cardano-cli shelley key <br>convert-itn-key .."])
    A --x C{{"ITN Owner vkey (ed25519_pk).."}} --x D
    D --x E{{"Stake skey/vkey"}} --x L
    A --x F(["cardano-cli shelley .."])
    F --x G{{"Payment skey/vkey/addr"}} --x L
    F --x H{{"Reward addr"}} --x L
    F --x I{{"Base addr"}} --x L
    L[CNTools Wallet]
    ;
```

<!--/details-->

#### Steps

- If secret key used for jcli account in ITN was ed25519_sk (not extended), you can run the `itnRewards.sh` script providing the name for CNTools wallet and ITN owner _public_/_secret_ keys that was used to register your pool as below.
``` bash
cd $CNODE_HOME/scripts
./itnRewards.sh MyITNWallet ~/jormu/account/priv/owner.sk ~/jormu/account/priv/owner.pk
```
- However, if an extended secret key was used(ed25519e_sk), a special version of cardano-cli is needed to convert the key.
  - Follow these instructions to build this version of cardano-cli:
``` bash
cd ~/git # Go to folder where you normally build cardano-node
git checkout -b jordan/cli-handle-extended-itn-keys
git branch --set-upstream-to origin/jordan/cli-handle-extended-itn-keys jordan/cli-handle-extended-itn-keys
git pull
$CNODE_HOME/scripts/cabal-build-all.sh
```
  - Re-run `itnRewards.sh` and provide the path $HOME/.cabal/bin/cardano-cli-itn when asked
- Start CNTools and verify that correct balance is shown in the wallet reward address
- Fund base address of wallet with enough funds to pay for withdraw tx fee
- Use FUNDS >> WITHDRAW to move rewards to base address of wallet
- You can now spend/move funds as you see fit
