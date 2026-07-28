# Docker security

Containers share the host kernel and are not a substitute for host hardening.
Treat a node container, its image inputs, mounted keys, and the Docker daemon as
one security boundary.

## Guild image defaults

The Guild node image builds as root but runs the node as the unprivileged
`guild` user. The examples in this guide use
`--security-opt=no-new-privileges`. The image also records implementation,
network, and deployment root in `.deployment.json`; the entrypoint rejects
runtime identity overrides that conflict with it.

Those controls prevent common configuration mistakes, but they do not make an
untrusted image, script branch, or host safe.

## Protect the Docker daemon

- Never expose an unauthenticated Docker API or mount the Docker socket inside
  the node container. Control of the daemon or socket is effectively
  root-equivalent access to the host.
- Limit membership of the host's `docker` group and audit it regularly.
- Consider Docker's
  [rootless mode](https://docs.docker.com/engine/security/rootless/) where it
  fits the deployment.
- Keep the host kernel, Docker Engine, and runtime packages supported and
  patched.

## Use least privilege

- Do not use `--privileged`.
- Retain `--security-opt=no-new-privileges`.
- Publish only the relay or monitoring ports that are intentionally reachable,
  and enforce host and network firewalls.
- Amaru's OTLP receivers and Prometheus bridge are loopback-only inside the
  container and do not need publishing for gLiveView. Dingo's native metrics
  listener shares its public bind address; leave TCP 12798 unpublished unless
  remote monitoring is deliberate and separately protected.
- Mount only required paths. Use read-only mounts for inputs that never need to
  change, and separate node state from operational keys.
- Additional capability drops, a read-only root filesystem, seccomp, or
  AppArmor/SELinux policies can reduce exposure, but test them against the
  launcher's required writable paths before production use.
- Apply CPU, memory, process, and storage limits appropriate for the node. See
  Docker's [resource constraints](https://docs.docker.com/engine/containers/resource_constraints/).

## Protect keys and secrets

- Never bake pool keys, wallet keys, API credentials, or database passwords
  into an image.
- Keep cold keys offline. Mount only the operational files required by that
  specific online node.
- Restrict ownership and permissions on host bind mounts.
- Prefer a managed secret mechanism over plain environment variables for
  sensitive values. See
  [Docker secrets](https://docs.docker.com/engine/swarm/secrets/) when using a
  compatible deployment mode.
- Back up state and configuration separately from secrets, encrypt sensitive
  backups, and test restoration.

## Verify image and build inputs

- Prefer immutable image digests for production deployments rather than a
  moving `latest` tag.
- Review the selected `G_ACCOUNT` and `GUILD_DEPLOY_BRANCH`; the Dockerfile
  downloads deployment scripts, manifests, configuration, and container assets
  from that source.
- Guild release manifests checksum node and tool artifacts, but this does not
  replace review of the Dockerfile, source branch, base image, or workflow.
- Scan images and their dependencies before deployment and after material
  updates.
- Docker Content Trust/Notary v1 is being retired. For environments requiring
  supply-chain enforcement, use current digest, signature, and provenance
  controls such as
  [Build attestations](https://docs.docker.com/build/metadata/attestations/)
  and an organizational signature policy rather than starting a new DCT
  deployment.

## Operate and monitor

- Send container and daemon logs to monitored storage with retention limits.
- Alert on repeated restarts, unexpected image changes, resource exhaustion,
  and published-port changes.
- Recreate containers from reviewed images instead of making undocumented
  changes inside a running container.
- Test cnode upgrades on a relay or test network first. Dingo and Amaru images
  are experimental, relay-only, and restricted to `preprod` and `preview`.

See [Run](run.md) for implementation-specific volumes and ports and
[Docker operational tips](tips.md) for update, backup, and restore behavior.
