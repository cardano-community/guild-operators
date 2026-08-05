### Building a node image

`dockerfile_bin` uses the same implementation dispatcher as a host deployment.
The implementation and network are image build properties because they are
recorded as authoritative values in `.deployment.json`.

The defaults remain `cnode` and `mainnet`:

```bash
docker build \
  --file files/docker/node/dockerfile_bin \
  --tag cardanocommunity/cardano-node:latest \
  .
```

Select a different cnode network at build time:

```bash
docker build \
  --file files/docker/node/dockerfile_bin \
  --build-arg NODE_NETWORK=preprod \
  --tag guild-operators/cnode:preprod \
  .
```

Dingo and Amaru images are experimental and currently support only `preprod`
and `preview`. Dingo can run as a relay or testnet block producer; Amaru is
relay-only:

```bash
docker build \
  --file files/docker/node/dockerfile_bin \
  --build-arg NODE_IMPLEMENTATION=dingo \
  --build-arg NODE_NETWORK=preprod \
  --tag guild-operators/dingo:preprod \
  .

docker build \
  --file files/docker/node/dockerfile_bin \
  --build-arg NODE_IMPLEMENTATION=amaru \
  --build-arg NODE_NETWORK=preview \
  --tag guild-operators/amaru:preview \
  .
```

The accepted build combinations are:

| Implementation | Networks |
| --- | --- |
| `cnode` (default) | `mainnet` (default), `preprod`, `preview`, `guild` |
| `dingo` | `preprod`, `preview` |
| `amaru` | `preprod`, `preview` |

An unsupported combination fails during the build. A container also rejects
runtime `NETWORK`, `NODE_IMPLEMENTATION`, or `NODE_HOME` values that contradict
its deployment manifest. Rebuild the image to change implementation or network.
The Dockerfile uses Docker's target platform for its base image rather than
forcing the builder platform, so a Buildx target cannot silently receive
binaries for the build host's architecture.

All supported images install the common gLiveView dashboard and an
implementation-aware healthcheck. The Dingo image reads its native Prometheus
listener. The Amaru image additionally installs the checksummed
`otelcol-contrib` artifact from the Amaru release manifest; its entrypoint
supervises the node and collector as two processes, using the minimal
host-safe form of Amaru's reference bridge. The alternate images do not
install the other cnode-only helper suite. Dingo does install CNTools and its
independently pinned `cardano-cli-dingo`; Amaru does not.

To build from a fork or non-default Guild Operators branch, add:

```text
--build-arg G_ACCOUNT=<github-account>
--build-arg GUILD_DEPLOY_BRANCH=<branch>
```

For cnode images, node, companion, optional-tool, and source-build version
choices come from the same compact
`files/node-implementations/cnode/release.json` manifest used by host
deployments. Pinned binaries record a `version` and architecture-keyed HTTPS
`url`/`sha256` artifacts. A direct-binary tool with `version: "latest"`
resolves its declared `github` repository, architecture `assets`, and optional
`channel` only when that tool is selected, and accepts an asset only when
GitHub supplies a SHA-256 digest. To pin such a tool, replace its latest
selector fields with a concrete `version` and checksummed `artifacts`.

An upstream release does not itself create a Guild Operators repository event.
Run the Docker workflow manually when an image should pick up a newer
latest-tracking tool. Changes to deployment scripts, release manifests,
implementation configs, or Docker assets trigger the default cnode/mainnet
push workflow; Dingo, Amaru, and other networks remain manual workflow
selections.

The image workflow defaults to cnode/mainnet and continues to publish only that
combination as the production `cardanocommunity/cardano-node` image. A manual
workflow dispatch can select another supported combination. Testing images are
published to GitHub Container Registry as `cardano-node`, `dingo-node`, or
`amaru-node`, with the network included in non-mainnet tags.

#### See also

- [Run the images](run.md)
- [Docker tips](tips.md)
- [Docker documentation](https://docs.docker.com/)
