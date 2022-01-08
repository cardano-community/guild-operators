The documentation here uses instructions from [IOHK repositories](https://github.com/input-output-hk) as a foundation, with additional info which we can contribute to where appropriate. Note that not everyone needs to build each component. You can refer to [architecture](https://docs.cardano.org/explore-cardano/cardano-architecture) to understand and qualify which components you want to run.

#### Components

For most Pool Operators, simply building [cardano-node](Build/node-cli.md) should be enough. Use the below to decide whether you need other components:

``` mermaid
graph TB
  A(Need to interact with <br/>HD Wallets with keys<br/>saved locally?)
  B(Need to explore <br/> blockchain locally?)
  C(Manage pool-ops, <br/> asset operation tasks <br/> easily?)
  D(Create Custom Assets?)
  E(Monitor node <br/> using Terminal UI)
  N(Node)
  F(Manage Pool/Wallet Keys<br/>and tx signing<br/>offline)
  O(Ogmios)
  P(gRest/Koios)
  Q(DBSync)
  R(Wallet)
  S(CNTools)
  T(Tx Submit API)
  U(GraphQL)
  V(OfflineMetadataTools)
  X(gLiveView)

F --x S
N --x C --x S
N --x D
D --x S
D --x V
N --x E --x X
N --x B
B --x U --x Q
B --x P --x Q
P --x O
P --x T
N --x A --x R
```

!!! warning "Important"
    We strongly prefer use of gRest over GraphQL components due to performance, security, simplicity, control and most importantly - consistency benefits. Please refer to [official documentations](https://docs.cardano.org) if you're interested in `GraphQL` or `Cardano-Rest` components instead.

!!! info "Note"
    The instructions are intentionally limited to stack/cabal** to avoid wait times/availability of nix/docker files on a rapidly developing codebase - this also helps us prevent managing multiple versions of instructions.

