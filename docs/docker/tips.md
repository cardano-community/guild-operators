# Docker operational tips

The cnode image includes the established Guild helper set. Dingo and Amaru
images contain their node-specific launcher, configuration, common runtime,
gLiveView, and healthcheck. Dingo additionally contains CNTools and its
isolated `cardano-cli-dingo` companion; the remaining cnode-only helpers do not
apply. Amaru contains the managed OpenTelemetry Collector required by its
dashboard adapter and a minimal profile derived from Amaru's reference
Prometheus bridge, but not CNTools.

## Open a shell in a running container

Start the container with a name, then open a shell when needed:

```bash
docker exec -it <container-name> bash
```

The image also supports a one-off shell that bypasses the Guild entrypoint:

```bash
docker run --rm -it --entrypoint=bash <image>
```

Every image defines a `gLiveView` alias in its interactive shell. cnode and
Dingo images also define `cntools`. From the host, the explicit script path is
also convenient:

```bash
implementation=dingo
docker exec -it <container-name> \
  "/opt/cardano/${implementation}/scripts/gLiveView.sh"
```

For Amaru, use this against the normal running container. A one-off shell that
bypasses the entrypoint does not start either the node or its collector.

## Common Docker flags

- `--detach` (`-d`): run in the background.
- `--interactive` (`-i`): keep standard input open.
- `--tty` (`-t`): allocate a terminal.
- `--env` (`-e`): set a runtime environment variable.
- `--publish` (`-p`): publish a container port on the host.
- `--volume` (`-v`): mount persistent host or named-volume storage.
- `--name`: assign a stable container name.
- `--hostname`: set the hostname visible inside the container.

For example, run the default cnode/mainnet image as a relay while persisting
its database and private directory:

```bash
docker run --init --detach --interactive --tty \
  --name relay \
  --security-opt=no-new-privileges \
  --publish 9000:6000 \
  --env NETWORK=mainnet \
  --volume cnode-db:/opt/cardano/cnode/db \
  --volume /secure/host/path:/opt/cardano/cnode/priv \
  --volume /host/socket-share:/opt/cardano/cnode/sockets \
  cardanocommunity/cardano-node:latest
```

`NETWORK` is optional and must match the network selected when the image was
built. It cannot convert an image to another network. Mounting a private
directory does not by itself configure a block producer; the cnode pool name
and required operational keys must also be configured correctly.

The container entrypoint deliberately disables CNTools `chattr` and dialog
integration. Do not weaken `no-new-privileges` merely to re-enable those
features; use a reviewed custom image and threat model if they are required.

Useful management commands include:

```bash
docker ps
docker logs --follow <container-name>
docker inspect <container-name>
docker stop <container-name>
docker image ls
docker volume ls
```

## cnode backup and restore

The entrypoint supports a simple cnode database copy before the node starts.
It is disabled by default and does not apply to Dingo or Amaru.

Persist both the live database and backup directory:

```text
--volume cnode-db:/opt/cardano/cnode/db
--volume cnode-backup:/opt/cardano/cnode/backup
```

- `ENABLE_BACKUP=Y` copies the live database to
  `/opt/cardano/cnode/backup/<network>-db` when the live database is larger
  than the existing backup.
- `ENABLE_RESTORE=Y` restores that directory when the backup is larger than the
  live database.

!!! warning
    A backup can require approximately the same space as the database. Stop the
    node and verify the resulting data before treating this simple directory
    copy as a recovery plan. Test restoration before relying on it.

## Runtime update checks

Implementation, network, and deployment root are immutable image properties
recorded in `.deployment.json`. Runtime `NETWORK`, `NODE_IMPLEMENTATION`, and
`NODE_HOME` values must agree with that manifest.

`UPDATE_CHECK=N` is the default:

- cnode restores its selected network configuration from the image's `/conf`
  cache before starting;
- Dingo and Amaru use the native configuration installed when the image was
  built;
- no helper or binary download occurs.

With `UPDATE_CHECK=Y`, the entrypoint runs the installed `guild-deploy.sh`
against the repository and branch recorded in `.deployment.json`. It refreshes
compatible scripts and configuration but does not select a different
implementation, change network, or install a new node binary.

To opt in:

```text
--env UPDATE_CHECK=Y
```

Advanced fork testing may also set `G_ACCOUNT` and `BRANCH`, but the selected
source must contain a complete compatible deployment layout. The refresh
updates the recorded source after it succeeds.

To roll back scripts as well as configuration, recreate the container from a
known image. Switching `UPDATE_CHECK` back to `N` restores cnode's cached
configuration, but it does not undo scripts already changed in that
container's writable layer.

## Workflow builds from forks

The **Docker Image** workflow accepts the Guild branch, implementation,
network, and a testing toggle:

- only cnode/mainnet on `master` with testing disabled is published as the
  production Docker Hub image;
- testing, non-master, alternate-network, Dingo, and Amaru builds are
  published to GitHub Container Registry;
- Dingo and Amaru support only `preprod` and `preview`.

See [Build](build.md) for build arguments, image names, and tag behavior, and
[Security](security.md) before exposing ports or mounting sensitive data.
