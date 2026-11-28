# Running behind a forward proxy

Some operators let a block producer reach the internet only through an HTTP
forward proxy, such as Squid, that allows a short list of hosts. The Guild
tools have no proxy settings of their own. curl, wget, git and the Rust
binaries they start read the standard proxy environment variables, so the job
is to give every place the tools run from the same variables: your shell, the
systemd services, `sudo`, cron jobs and containers.

This page covers where each of those gets its environment, what `no_proxy`
must contain, which hosts each tool contacts, and how the tools that don't use
curl find the proxy.

!!! note "Node-to-node traffic doesn't use the proxy"
    `cardano-node`, Dingo and Amaru talk to their peers over plain TCP on the
    node port, and so does `cncli sync` when it reads blocks from the node. An
    HTTP proxy doesn't carry that traffic: the block producer still needs a
    direct firewall path to its relays.

## The proxy variables {: #variables}

Set these three, in lower case:

| Variable | Purpose |
| --- | --- |
| `http_proxy` | Proxy for `http://` URLs |
| `https_proxy` | Proxy for `https://` URLs |
| `no_proxy` | Comma-separated hosts to reach directly, see [What no_proxy must contain](#no-proxy) |

The tools read them differently:

| Tool | Variables it reads | When both cases are set | CIDR ranges in `no_proxy` |
| --- | --- | --- | --- |
| curl | `http_proxy` (lower case only), `https_proxy` or `HTTPS_PROXY`, `all_proxy` or `ALL_PROXY`, `no_proxy` or `NO_PROXY` | Lower case wins | From curl 7.86.0 |
| GNU Wget 1.x | `http_proxy`, `https_proxy`, `no_proxy`, lower case only | Upper case is ignored | No, entries are domain suffixes |
| git | `http_proxy`, `https_proxy`, `all_proxy` | Not documented | Not documented |
| Mithril signer and client, CNCLI | `HTTP_PROXY` or `http_proxy`, `HTTPS_PROXY` or `https_proxy`, `ALL_PROXY` or `all_proxy`, `NO_PROXY` or `no_proxy` | Upper case wins | Yes |

Lower-case names are the only ones every tool reads, and there is no need for
`HTTP_PROXY`. If upper-case `HTTPS_PROXY` or `NO_PROXY` are already set on the
host, for example by another program, give them the same values as the
lower-case ones or remove them: curl uses the lower-case value and the Rust
tools the upper-case one.

Keep the values in one file, so the shell and systemd read the same thing:

```bash
sudo tee /etc/guild-proxy.env >/dev/null <<'EOF'
http_proxy=http://proxy.example.lan:3128
https_proxy=http://proxy.example.lan:3128
no_proxy=localhost,127.0.0.1,::1,0.0.0.0,192.168.1.21,192.168.1.22
EOF
```

The file holds plain `NAME=value` lines, without quotes or `export`, so
systemd can read it with `EnvironmentFile=` and a shell can source it. If the
proxy URL contains a user name and password, make the file readable only by
root and the node user's group (`sudo chgrp <group> /etc/guild-proxy.env` and
`sudo chmod 0640 /etc/guild-proxy.env`).

## Your shell and the systemd services {: #shell-and-services}

The cnode units that Guild installs, for the node and its helper scripts,
start their script through a login shell, for example:

```ini
ExecStart=/bin/bash -l -c "exec /opt/cardano/cnode/scripts/cncli.sh sync"
```

A non-interactive login shell reads `/etc/profile` and then the first of
`~/.bash_profile`, `~/.bash_login` and `~/.profile` that exists. It doesn't
read `~/.bashrc` itself, and what happens next depends on the distribution:

- **Debian and Ubuntu:** `~/.profile` sources `~/.bashrc`, but the default
  `~/.bashrc` returns at its first lines when the shell isn't interactive.
  Variables exported further down `~/.bashrc` reach your terminal but not the
  services. That explains
  [issue #1862](https://github.com/cardano-community/guild-operators/issues/1862),
  where the CNCLI sync and validate services failed while the same commands
  worked by hand. Put the line below in `~/.profile`. If you created a
  `~/.bash_profile`, bash reads that instead of `~/.profile`, so put it there.
- **RHEL and its rebuilds:** `~/.bash_profile` sources `~/.bashrc`, which
  has no such check, so either file works. `~/.bash_profile` is the clearer
  place.

Add this line to that file of the user who runs the node:

```bash
set -a; . /etc/guild-proxy.env; set +a
```

Your SSH logins read the same file, so the commands you type see the variables
too. Log in again, then restart the services.

### systemd drop-ins {: #systemd-dropin}

A drop-in gives a unit the variables however it starts, without relying on
shell files. Use one for:

- units that don't start through a login shell: Amaru's
  `<name>-leaderlog.service` and `<name>-validate.service` run their script
  directly and query Koios;
- any unit, if you would rather not depend on the shell files above.

`<name>` is the deployment's service name, for example `cnode` for
`/opt/cardano/cnode`. `systemctl list-unit-files 'cnode*'` lists the units of
that deployment. To add the drop-in to one unit:

```bash
sudo systemctl edit cnode-cncli-sync.service
```

and enter:

```ini
[Service]
EnvironmentFile=/etc/guild-proxy.env
```

To add it to several units at once:

```bash
for unit in cnode-cncli-sync cnode-cncli-leaderlog cnode-cncli-validate \
            cnode-cncli-ptsendtip cnode-cncli-ptsendslots; do
  sudo mkdir -p "/etc/systemd/system/${unit}.service.d"
  printf '[Service]\nEnvironmentFile=/etc/guild-proxy.env\n' |
    sudo tee "/etc/systemd/system/${unit}.service.d/proxy.conf" >/dev/null
done
sudo systemctl daemon-reload
```

Then restart the units that are running. `systemctl cat <unit>` shows a unit
together with its drop-ins. The Guild installers replace only the unit file in
`/etc/systemd/system`, never the `.d` folder next to it, so a drop-in survives
reinstalls and deployments.

These units contact the internet:

| Unit | Contacts | Starts through |
| --- | --- | --- |
| `<name>.service` (cnode) | The Mithril aggregator and its snapshot storage when `MITHRIL_DOWNLOAD=Y` is set in `cnode.sh` | Login shell |
| `<name>-cncli-sync`, `-leaderlog`, `-validate` | Koios, plus the node's metrics on `PROM_HOST`, which must be in `no_proxy` | Login shell |
| `<name>-cncli-ptsendtip`, `-ptsendslots` | PoolTool (`api.pooltool.io`), from the `cncli` binary | Login shell |
| `<name>-mithril-signer` | The Mithril aggregator, directly or through a Mithril relay, see [Mithril](#mithril) | Login shell |
| Amaru `<name>-leaderlog`, `<name>-validate` | Koios | The script directly: needs a drop-in or [`~/.curlrc`](#curlrc) |
| `<name>-haproxy` (gRest) | `api.koios.rest`, from `grest-poll.sh`, which HAProxy runs as its health check | HAProxy itself: whether the variables reach the check is [not verified](#not-verified) |

### sudo and the package managers {: #sudo}

`guild-deploy.sh` installs OS packages with `sudo apt-get` or `sudo dnf`.
`sudo` resets the environment by default, and the default sudoers on Ubuntu
keeps none of the proxy variables, so the package manager doesn't see them.
Configure the package manager itself:

- Debian and Ubuntu, in `/etc/apt/apt.conf.d/95proxy`:

    ```
    Acquire::http::Proxy "http://proxy.example.lan:3128";
    Acquire::https::Proxy "http://proxy.example.lan:3128";
    ```

- RHEL and its rebuilds, under `[main]` in `/etc/dnf/dnf.conf`:

    ```ini
    proxy=http://proxy.example.lan:3128
    ```

Alternatively, keep the variables across `sudo` with
`Defaults env_keep += "http_proxy https_proxy no_proxy"` in a file under
`/etc/sudoers.d`, edited with `sudo visudo -f`; apt and dnf both read the
variables when they have no proxy setting of their own. The rest of
`guild-deploy.sh`, its curl, git and wget downloads, runs as your user and
uses your shell's variables.

### cron jobs of gRest {: #cron}

`setup-grest.sh` installs its jobs in `/etc/cron.d`, each run as
`/bin/bash <script>`. Cron reads no profile files, and the installer rewrites
those files on every run, so set the proxy for the gRest user instead. Two
jobs contact the internet: `asset-registry-update` clones and pulls the Token
Registry from GitHub with git, and `pool-groups-update` downloads its list
from `raw.githubusercontent.com` with curl. Give git its own setting and curl a
[`~/.curlrc`](#curlrc):

```bash
git config --global http.proxy http://proxy.example.lan:3128
```

## ~/.curlrc {: #curlrc}

curl reads `~/.curlrc` of the user it runs as, however it was started, and its
settings take precedence over the environment variables. The reporter of
issue #1862 used one to get the services working:

```
proxy = "http://proxy.example.lan:3128"
noproxy = "localhost,127.0.0.1,::1,0.0.0.0,192.168.1.21,192.168.1.22"
```

It is a curl-only setting:

- Only the `curl` command reads it. wget, git, `cncli` and the Mithril binaries
  don't, so PoolTool, the Mithril signer and client, and the git and wget
  downloads of the deployment still need the variables.
- It applies to every curl that user runs, including the ones you type.
- A command that passes `-q` or `--disable` as its first option skips the
  file. The CNTools compatibility checker,
  `scripts/compatibility/cntools/cntools-check.sh`, does that.
- `noproxy` follows the same CIDR rule as `no_proxy`: ranges work only from
  curl 7.86.0.

## What no_proxy must contain {: #no-proxy}

Requests to a host that isn't in `no_proxy` go to the proxy, which can't reach
this host's loopback addresses and usually doesn't allow LAN ones. Include:

- `localhost`, `127.0.0.1` and `::1`: the node's metrics (`PROM_HOST` defaults
  to `127.0.0.1`), and local services such as PostgREST for gRest's
  `grest-poll.sh` on `127.0.0.1:8050`.
- `0.0.0.0`: the scripts read `PROM_HOST` from the `PrometheusSimple` backend
  in the node's `config.json`. When the node listens on `0.0.0.0` there, the
  scripts query `http://0.0.0.0:<port>`. The Mithril signer's metrics server
  also listens on `0.0.0.0` by default (`METRICS_SERVER_IP`), so keep it if
  you read those metrics at that address.
- Any address you set in `PROM_HOST`, `EKG_HOST` or `NODE_METRICS_HOST`.
- LAN hosts the tools reach directly: other nodes whose metrics you read, a
  Koios instance of your own named in `KOIOS_API`, and your Prometheus or
  Grafana.

List each address on its own unless every tool on the host accepts CIDR
ranges. GNU Wget never does, and curl does only from 7.86.0. These releases
ship the following curl versions (from their package pages, November 2026):

| Release | curl | CIDR in `no_proxy` |
| --- | --- | --- |
| Ubuntu 22.04 | 7.81.0 | No |
| Ubuntu 24.04 | 8.5.0 | Yes |
| Ubuntu 26.04 | 8.18.0 | Yes |
| Debian 11 | 7.74.0 | No |
| Debian 12 | 7.88.1 | Yes |
| Debian 13 | 8.14.1 | Yes |
| RHEL 8 and rebuilds | 7.61.1 | No |
| RHEL 9 and rebuilds | 7.76.1 | No |
| RHEL 10 and rebuilds | 8.12.1 | Yes |

Distributions backport fixes, so the version number alone doesn't prove the
behaviour. To see where curl sends a request, run it with `-v`:

```bash
curl -sv -o /dev/null http://127.0.0.1:12798/metrics 2>&1 | grep -iE 'proxy|trying|connected'
```

## Hosts each tool contacts {: #hosts}

Your proxy's allowlist needs the hosts of the tools you use. This list comes
from the scripts; a new release can add hosts, so check the proxy's access log
(for Squid, `TCP_DENIED` lines in `/var/log/squid/access.log`) after an
upgrade.

| Tool or step | Hosts |
| --- | --- |
| `guild-deploy.sh` | `raw.githubusercontent.com` (the first download of the script, raw files), `github.com` (the git clone of guild-operators on every run, release downloads), `api.github.com` (release lookups), `release-assets.githubusercontent.com` (where GitHub redirects release downloads), and your OS package mirrors |
| `guild-deploy.sh -s d` | GitHub releases of the node and `cardano-cli` (cnode, Dingo, Amaru) and of the OpenTelemetry collector (Amaru); `share.koios.rest` (cnode: `cardano-address`, db-sync); `ci.iog.io` (db-sync on Dijkstra) |
| `guild-deploy.sh -s m`, `-s c`, `-s o`, `-s x` | GitHub releases of Mithril, CNCLI, Ogmios and Cardano Signer |
| `guild-deploy.sh -s w` | GitHub releases of `cardano-hw-cli`, `data.trezor.io` and `raw.githubusercontent.com` (device rules) |
| `guild-deploy.sh -s r` | `raw.githubusercontent.com` (the openBlockPerf installer) |
| `guild-deploy.sh -s b`, `-s l` | `github.com` (GHCup, libsodium, secp256k1, blst) |
| `guild-deploy.sh -s p` on RHEL and its rebuilds | `dl.fedoraproject.org` (EPEL) |
| Update checks (`UPDATE_CHECK=Y`, the default) | `raw.githubusercontent.com`, `api.github.com` |
| Koios queries: `env`, CNTools, gLiveView, `cncli.sh`, `amaru-leaderlog.sh` | `api.koios.rest` (mainnet), `preprod.koios.rest`, `preview.koios.rest`, `guild.koios.rest`, or the host in `KOIOS_API` |
| `cncli.sh ptsendtip`, `ptsendslots` | `api.pooltool.io` |
| Mithril client: `mithril-client.sh`, `cnode.sh` with `MITHRIL_DOWNLOAD=Y` | `aggregator.<release>-<network>.api.mithril.network`; the snapshot storage the aggregator lists (`storage.googleapis.com` for mainnet in November 2026); `raw.githubusercontent.com` (verification keys, when `mithril.env` is created) |
| Mithril signer | `aggregator.<release>-<network>.api.mithril.network`; `raw.githubusercontent.com` (era and protocol settings, verification keys, when `mithril-signer.sh -e` creates `mithril.env`) |
| CNTools | Koios; the pool's metadata URL, any host, when you register or modify a pool; governance metadata URLs, and `ipfs.io` for `ipfs://` links; `api.projectcatalyst.io` (Catalyst); GitHub releases of fzf and gum, when CNTools installs them; `raw.githubusercontent.com` (updates, CIP-0094 polls) |
| gLiveView | Koios; `ip-api.com` over plain HTTP (peer locations), so it needs `http_proxy`; `api.github.com` (update check) |
| Telegram alerts (`TG_BOT_TOKEN` set) | `api.telegram.org` |
| `setup-grest.sh` | `raw.githubusercontent.com`, `api.github.com`, `github.com` (PostgREST), `www.haproxy.org` over plain HTTP (HAProxy source), `share.koios.rest` (pg_cardano), `api.koios.rest` (API specification) |
| gRest cron jobs and `grest-poll.sh` | `github.com` (Token Registry), `raw.githubusercontent.com` (pool groups), `api.koios.rest` (API specification) |
| `setup_mon.sh` (legacy monitoring) | `github.com` (Prometheus, node_exporter), `dl.grafana.com`, `raw.githubusercontent.com` (dashboards) |
| Docker image build | Debian package mirrors, plus the `guild-deploy.sh` hosts above |

## Tools that don't use curl {: #non-curl}

### wget

`mithril.library` fetches the Mithril verification keys and era settings with
wget when it creates `mithril.env`, `setup_mon.sh` falls back to wget when
curl is missing, and the Docker image build downloads `guild-deploy.sh` with
it. GNU Wget reads `http_proxy`, `https_proxy` and `no_proxy` in lower case
only. Its `no_proxy` entries are domain suffixes: the manual describes no
address ranges. The same settings can go in `~/.wgetrc` as
`https_proxy = <URL>` and `no_proxy = <list>`.

### git

`guild-deploy.sh` clones guild-operators from `github.com` with git, the source
toolchain flags `-s b` and `-s l` clone libraries, and gRest's Token Registry
job clones and pulls with git. git reads `http_proxy`, `https_proxy` and
`all_proxy`; `git config --global http.proxy <URL>` overrides them for that
user. git doesn't read `~/.curlrc`, which is a setting of the `curl` command.

### Mithril client and signer {: #mithril}

Both binaries use the Rust HTTP library reqwest with its default proxy
handling (checked in the source of Mithril 2642.0): they read the variables in
the table above, prefer the upper-case names, and accept CIDR ranges in
`NO_PROXY`.

The signer's `RELAY_ENDPOINT` changes that. When `mithril.env` sets it, the
signer sends all of its aggregator traffic to that Mithril relay and ignores
the proxy variables. The Squid that `mithril-relay.sh` installs on a relay
node is itself a forward proxy, but only for this traffic: it allows the
block producer's addresses to reach `.mithril.network` on port 443 and
nothing else, so don't point `https_proxy` at it. Without a relay, your proxy
must allow the aggregator host. `mithril-signer.sh -r` and `-s` check the
registration and signatures with curl, which goes through `https_proxy`, not
the relay.

The client doesn't use `RELAY_ENDPOINT`. It downloads from the aggregator and
from the snapshot storage the aggregator lists, through `https_proxy`.

### CNCLI

`cncli sync` reads blocks from the node over its node-to-node port, which
doesn't use the proxy, and `leaderlog` and `validate` work from CNCLI's own
database. `cncli.sh` makes its Koios queries with curl. `ptsendtip` and
`ptsendslots` call `api.pooltool.io` from the `cncli` binary itself, which
uses reqwest with its default proxy handling (checked in the source of CNCLI
6.8.3), so it needs the variables in its environment: `~/.curlrc` doesn't help
there.

### Dingo and Amaru bootstrap

`dingo.sh bootstrap` runs Dingo's built-in Mithril import and
`amaru.sh bootstrap` downloads Amaru's snapshots. Both run from your shell, so
they get its variables, but how those binaries handle proxies hasn't been
checked.

### Docker and Kubernetes {: #containers}

The image doesn't set any proxy itself. Pass the variables when you build and
run it:

- **Build:** the proxy variables, in either case, are predefined build
  arguments: pass them with `--build-arg`, for example
  `docker build --build-arg https_proxy=...`, and the Dockerfile needs no
  `ARG` for them. They stay out of the image's history. The build uses apt,
  wget, curl and git.
- **Run:** pass them with `--env`, for example
  `--env https_proxy=http://proxy.example.lan:3128 --env no_proxy=localhost,127.0.0.1,::1`.
  Keep `127.0.0.1` in `no_proxy`: the container health check reads the node's
  metrics on `127.0.0.1`. The image sets `UPDATE_CHECK=N`, so it makes no
  GitHub update checks.
- **Both:** a `proxies` block in the Docker client's `~/.docker/config.json`
  sets the variables in every new build and container. Don't set them with
  `ENV` in a Dockerfile, which stores them in the image.
- **Pulling images** goes through the Docker daemon, which has its own
  proxy setting in `daemon.json` or a `docker.service` drop-in.

See Docker's [CLI proxy](https://docs.docker.com/engine/cli/proxy/) and
[daemon proxy](https://docs.docker.com/engine/daemon/proxy/) guides.

In Kubernetes, set the same variables in the container's `env` of the pod
spec, and add the cluster addresses the container calls, such as a Koios
instance or another node's metrics, to `no_proxy`.

## Not verified {: #not-verified}

These are not covered by the checks behind this page:

- Proxy handling of the Dingo and Amaru binaries during `bootstrap`.
- Which hosts GHCup and Cabal contact while building from source (`-s b`).
- Which hosts openBlockPerf reports to after its installer has run.
- How db-sync fetches off-chain pool and governance metadata; those come from
  any host that pools and proposals name.
- Whether HAProxy passes proxy variables to `grest-poll.sh` when it runs it
  as a health check.
- Wget2, which some distributions ship as `wget`.
