The documentation here uses instructions from
[Intersect MBO repositories](https://github.com/intersectmbo) as a foundation,
with Guild-specific deployment guidance where appropriate. Not every operator
needs every component. Refer to the current
[Cardano architecture](https://docs.cardano.org/about-cardano/explore-more/cardano-architecture)
to decide which services your deployment needs.

#### Components

For most Pool Operators, the default [cnode deployment](Build/cnode.md) is
enough; source-build instructions remain under
[cardano-node and cardano-cli](Build/node-cli.md). Use the below to decide
whether you need other components:

Dingo and Amaru use their own experimental, testnet-only deployment profiles;
see the [node implementation guide](Build/node-implementations.md). Unless a
component description explicitly says otherwise, the surrounding tools on
this page are currently deployed only with `cnode`. gLiveView is the first
common operational dashboard supported across all three profiles.

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
    Guild Operators manages gRest, not GraphQL or Cardano REST. Consult each
    upstream project's current documentation before adding an unmanaged query
    service.

!!! info "Note"
    Each component page uses the build system supported by its upstream
    project. Prefer the verified deployment binaries where Guild Operators
    manages them.

#### Component descriptions

##### Cardano Wallet

An optional HTTP wallet service that connects to a local cardano-node socket.
Guild Operators does not deploy or version-pin it, and the current integration
guide is cnode-specific. See the
[external component guide](Build/wallet.md) and verify node compatibility
against the selected upstream wallet release.

##### CNTools

A swiss army knife for pool operators, primarily built by [Ola](https://github.com/scitz0), to simplify typical operations regarding their wallet keys and pool management. It is currently deployed only with `cnode`. You can read more about it [here](Scripts/cntools.md)

##### gLiveView

A local terminal dashboard, primarily built by
[Ola](https://github.com/scitz0), that complements remote monitoring systems
such as Prometheus/Grafana or Zabbix. It is deployed with cnode, Dingo, and
Amaru. A normalized adapter interface identifies the implementation in the
header and hides fields that its node does not export. Dingo is read through
native Prometheus; Amaru uses a managed, host-safe form of its upstream
OpenTelemetry-to-Prometheus bridge. See the
[gLiveView guide](Scripts/gliveview.md).

##### Topology Updater

A legacy node-to-node discovery solution created before Cardano P2P was
available. It is retained only for operators maintaining an existing non-P2P
cnode deployment and is deprecated for new deployments. You can read more
about it [here](Scripts/topologyupdater.md).

##### Koios/gRest

A full-featured local query layer node to explore blockchain data (via dbsync) using standardised pre-built queries served via API as per standard from [Koios](https://koios.rest) - for which user can opt to participate in elastic query layer. The Guild deployment is currently `cnode`-only. You can read more about build steps [here](Build/grest.md) and reference API endpoints [here](https://api.koios.rest)

##### Ogmios

A lightweight bridge interface for cardano-node. It offers a WebSockets API that enables local clients to speak Ouroboros' mini-protocols via JSON/RPC. Guild Operators currently deploys it only with `cnode`. You can read more about it [here](https://ogmios.dev)

##### CNCLI

A CLI tool written in Rust by [Andrew Westberg](https://github.com/AndrewWestberg) for low-level communication with cardano-node. Guild Operators currently deploys it only with `cnode`. It is commonly used by SPOs to check their leader logs (integrates with CNTools as well as gLiveView) or to send their pool's health information to https://pooltool.io. You can read more about it [here](https://github.com/cardano-community/cncli)

##### Cardano Signer

A tool written by [Martin](https://github.com/gitmachtl/) to sign/verify data (hex, text or binary) using cryptographic keys to generate data as per [CIP-8](https://cips.cardano.org/cips/cip8/) or [CIP-36](https://cips.cardano.org/cips/cip36/) standards. You can read more about it [here](https://github.com/gitmachtl/cardano-signer)

##### Off-chain metadata tools

An optional, independently versioned upstream toolset for creating and
submitting asset metadata. Guild Operators does not deploy or version-pin it;
see the [external component guide](Build/offchain-metadata-tools.md).
