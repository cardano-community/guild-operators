The documentation here uses instructions from [Intersect MBO repositories](https://github.com/intersectmbo) as foundation, with additional info which we can contribute to where appropriate. Note that not everyone needs to build each component. You can refer to [architecture](https://docs.cardano.org/explore-cardano/cardano-architecture) to understand and qualify which of the components built by IO you want to run.

#### Components

For most Pool Operators, simply building [cardano-node](Build/node-cli.md) should be enough. Use the below to decide whether you need other components:

``` mermaid
graph TB
  A([Interact with HD Wallets<br/>locally])
  B([Explore blockchain<br/>locally])
  C([Easy pool-ops and<br/>fund management])
  D([Create Custom Assets])
  E([Monitor node <br/>using Terminal UI])
  F([Sign/verify any data<br/>using crypto keys])
  N(Node)
  O(Ogmios)
  P(gRest/Koios)
  Q(DBSync)
  R(Wallet)
  S(CNTools)
  T(Tx Submit API)
  U(GraphQL)
  V(OfflineMetadataTools)
  X(gLiveView)
  Y(cardano-signer)
  Z[(PostgreSQL)]

N --x C --x S
N --x D --x S & V
N --x E --x X
N --x B
B --x U --x Q
B --x P --x Q
P --x O
P --x T
F ---x Y
N --x A --x R
Q --x Z
```

!!! warning "Important"
    We strongly prefer use of gRest over GraphQL components due to performance, security, simplicity, control and most importantly - consistency benefits. Please refer to [official documentations](https://docs.cardano.org) if you're interested in `GraphQL` or `Cardano-Rest` components instead.

!!! info "Note"
    The instructions are intentionally limited to stack/cabal** to avoid wait times/availability of nix/docker files on a rapidly developing codebase - this also helps us prevent managing multiple versions of instructions.

#### Description for components built by community

##### CNTools

A swiss army knife for pool operators, primarily built by [Ola](https://github.com/scitz0), to simplify typical operations regarding their wallet keys and pool management. You can read more about it [here](Scripts/cntools.md)

##### gLiveView

A local node monitoring tool, primarily built by [Ola](https://github.com/scitz0), to use in addition to remote monitoring tools like Prometheus/Grafana, Zabbix or IOG's RTView. This is especially useful when moving to a systemd deployment - if you haven't done so already - as it offers an intuitive UI to monitor the node status. You can read more about it [here](Scripts/gliveview.md)

##### Topology Updater

A temporary node-to-node discovery solution, run by [Markus](https://github.com/gufmar), that was started initially to bridge the gap created while awaiting completion of P2P on cardano network, but has since become an important lifeline to the network health - to allow everyone to activate their relay nodes without having to postpone and wait for manual topology completion requests. You can read more about it [here](Scripts/topologyupdater.md)

##### Koios/gRest

A full-featured local query layer node to explore blockchain data (via dbsync) using standardised pre-built queries served via API as per standard from [Koios](https://koios.rest) - for which user can opt to participate in elastic query layer. You can read more about build steps [here](Build/grest.md) and reference API endpoints [here](https://api.koios.rest)

##### Ogmios

A lightweight bridge interface for cardano-node. It offers a WebSockets API that enables local clients to speak Ouroboros' mini-protocols via JSON/RPC. You can read more about it [here](https://ogmios.dev)

##### CNCLI

A CLI tool written in Rust by [Andrew Westberg](https://github.com/AndrewWestberg) for low-level communication with cardano-node. It is commonly used by SPOs to check their leader logs (integrates with CNTools as well as gLiveView) or to send their pool's health information to https://pooltool.io. You can read more about it [here](https://github.com/cardano-community/cncli)

##### Cardano Signer

A tool written by [Martin](https://github.com/gitmachtl/) to sign/verify data (hex, text or binary) using cryptographic keys to generate data as per [CIP-8](https://cips.cardano.org/cips/cip8/) or [CIP-36](https://cips.cardano.org/cips/cip36/) standards. You can read more about it [here](https://github.com/gitmachtl/cardano-signer)
