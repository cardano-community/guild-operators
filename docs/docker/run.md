### OS requirements

- `docker-ce` installed — [Get Docker](https://docs.docker.com/get-docker/).

The implementation and network are selected when the image is built. `NETWORK`
may be omitted when running a container; if supplied, it must match the image.
It is no longer supported as a way to switch one image between networks.

The Dingo and Amaru commands below use the local example tags from the
[build guide](build.md). The GitHub workflow instead publishes testing images
as `ghcr.io/<owner>/dingo-node` or `ghcr.io/<owner>/amaru-node`, with the
network included in each non-mainnet tag.

### cnode

The default image remains a cnode mainnet image. To run without publishing the
node port:

```bash
docker run --init --detach --interactive --tty \
  --name <container-name> \
  --security-opt=no-new-privileges \
  --volume <private-path>:/opt/cardano/cnode/priv \
  --volume <database-path>:/opt/cardano/cnode/db \
  cardanocommunity/cardano-node
```

Relay mode:

```bash
docker run --init --detach --interactive --tty \
  --name <container-name> \
  --security-opt=no-new-privileges \
  --publish 6000:6000 \
  --volume <private-path>:/opt/cardano/cnode/priv \
  --volume <database-path>:/opt/cardano/cnode/db \
  cardanocommunity/cardano-node
```

Mounting `priv` only makes an existing operational-key directory available to
the container; it does not configure or register a block-producing pool.

For an image built with another cnode network, passing the same network is
allowed but optional:

```text
--env NETWORK=preprod
```

Passing a different value fails before the node starts.

### Dingo

Dingo images are experimental testnet nodes. With no operational key set they
run as relays. Persist the database and expose the configured relay port:

```bash
docker run --init --detach --interactive --tty \
  --name dingo-preprod \
  --security-opt=no-new-privileges \
  --publish 3001:3001 \
  --volume dingo-preprod-db:/opt/cardano/dingo/db \
  guild-operators/dingo:preprod
```

Importing a Mithril snapshot before the first run is optional:

```bash
docker run --rm --init \
  --security-opt=no-new-privileges \
  --volume dingo-preprod-db:/opt/cardano/dingo/db \
  guild-operators/dingo:preprod bootstrap
```

To test block production, mount only an existing testnet pool's operational
hot-key directory and select the matching folder name:

```bash
docker run --init --detach --interactive --tty \
  --name dingo-preprod-producer \
  --security-opt=no-new-privileges \
  --env POOL_NAME=my-pool \
  --publish 3001:3001 \
  --volume dingo-preprod-db:/opt/cardano/dingo/db \
  --volume <online-pool-path>:/opt/cardano/dingo/priv/pool/my-pool:ro \
  guild-operators/dingo:preprod
```

The mounted directory must contain `hot.skey`, `vrf.skey`, and `op.cert`.
The two signing keys must be owned by the container's `guild` user and have no
group or other permissions. Keep all cold keys and the operational-certificate
counter offline. A partial set fails startup; the bootstrap command always
suppresses block production.

The Dingo image installs gLiveView, CNTools, and the isolated
`cardano-cli-dingo` companion. It does not install Mithril helper scripts,
db-sync, Ogmios, or the remaining cnode-only suite. Its healthcheck verifies
deployment identity, Dingo process liveness, and the native Prometheus endpoint
on loopback port 12798; it does not determine whether chain sync is current.

Open the dashboard in the running container with:

```bash
docker exec -it dingo-preprod \
  /opt/cardano/dingo/scripts/gLiveView.sh
```

Run CNTools against the Dingo socket with:

```bash
docker exec -it dingo-preprod \
  /opt/cardano/dingo/scripts/cntools.sh
```

TCP 12798 is not published by the command above. Dingo binds metrics using its
shared public bind address, so do not publish that port unless remote
Prometheus access is deliberately secured.

### Amaru

Amaru images are experimental relays. Amaru must be bootstrapped before it can
run. Persist the state parent while bootstrapping:

```bash
docker run --rm --init \
  --security-opt=no-new-privileges \
  --volume amaru-preprod-state:/var/lib/amaru \
  guild-operators/amaru:preprod bootstrap
```

Then start the relay with the same volumes:

```bash
docker run --init --detach --interactive --tty \
  --name amaru-preprod \
  --security-opt=no-new-privileges \
  --publish 3000:3000 \
  --volume amaru-preprod-state:/var/lib/amaru \
  guild-operators/amaru:preprod
```

The container sets `AMARU_STATE_ROOT=/var/lib/amaru`, causing Amaru to create
`chain/` and `ledger/` below the mounted parent. Mounting the two child paths
directly would pre-create them and trigger Amaru's bootstrap overwrite guard.

For the default `amaru.sh run` entrypoint, the container starts and supervises
two processes: Amaru and `amaru.sh metrics` running the local OpenTelemetry
Collector with the minimal Amaru reference-bridge profile. Signals are
forwarded to both, and the remaining process is stopped if either exits. The
healthcheck verifies the deployment identity, both processes, and the loopback
Prometheus endpoint on port 8889; it does not determine whether chain sync is
current.

The Amaru image installs gLiveView but does not install CNTools, Mithril helper
scripts, db-sync, or Ogmios. Open the dashboard with:

```bash
docker exec -it amaru-preprod \
  /opt/cardano/amaru/scripts/gLiveView.sh
```

The OTLP/gRPC receiver on 4317 and Prometheus exporter on 8889 bind inside the
container to loopback and do not need host port publishing.

### Entrypoint options

- `--entrypoint=bash` bypasses the Guild entrypoint; combine it with `-it` for
  an interactive shell.
- `ENTRYPOINT_PROCESS` selects an installed script. The default is `cnode.sh`,
  `dingo.sh`, or `amaru.sh`, matching the image implementation. Additional
  helper entrypoints are cnode-only except for the common `gLiveView.sh`.
  Amaru node/collector supervision applies only to the default `amaru.sh run`
  path.
- `UPDATE_CHECK=Y` refreshes compatible scripts and configuration from the
  branch stored in `.deployment.json` without changing implementation or
  network.
- cnode retains `ENABLE_BACKUP`, `ENABLE_RESTORE`, and its supported cnode
  helper entrypoints. The stock image contains Mithril wrapper scripts but not
  the Mithril binaries, so `MITHRIL_DOWNLOAD` requires a derived image that
  also installs the cnode `m` selection. These settings do not apply to Dingo
  or Amaru.
- CPU, memory, and shared-memory limits can be supplied with Docker's standard
  resource flags.

See [Build](build.md) for selecting an implementation and network.
