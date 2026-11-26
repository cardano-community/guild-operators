# cnode monitoring bootstrap

> Ensure the [prerequisites](../basics.md#pre-requisites) are in place before
> proceeding.

`setup_mon.sh` is a cnode-only convenience script that installs and configures:

- Prometheus
- Node Exporter
- Grafana
- the bundled SKYLight and IOHK/Cardano dashboards
- systemd units for all three services

!!! warning "Legacy bootstrap helper"
    This helper currently pins Prometheus `2.35.0`, Grafana `8.5.1`, and Node
    Exporter `1.3.1`. It does not configure TLS, authentication hardening, or
    lifecycle management. Review the pinned versions and secure the services
    before exposing them outside a trusted network. It is not part of the
    Dingo or Amaru deployment profiles.

The default endpoints are:

| Service | Address |
| --- | --- |
| Prometheus | `http://127.0.0.1:9090` |
| Cardano node metrics | `http://127.0.0.1:12798` |
| Node Exporter | `http://127.0.0.1:9091` |
| Grafana | `http://0.0.0.0:5000` |

Open only the ports that are required for your deployment. In particular,
Grafana listens on all interfaces by default.

## Download

The cnode deployment profile installs `setup_mon.sh` in the selected node's
`scripts` directory. If you need to download it manually:

```bash
cd "${CNODE_HOME}/scripts"
wget https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/setup_mon.sh
chmod 750 setup_mon.sh
```

## Configuration

The editable defaults are at the top of `setup_mon.sh`:

```bash
CNODE_IP=127.0.0.1
CNODE_PORT=12798
GRAFANA_HOST=0.0.0.0
GRAFANA_PORT=5000
PROJ_PATH=/opt/cardano/monitoring
PROM_HOST=127.0.0.1
PROM_PORT=9090
NEXP_PORT=$((PROM_PORT + 1))
```

The command-line interface can override the deployment directory and Cardano
node metrics endpoint:

```text
Usage: setup_mon.sh [-d directory] [-i IP/hostname] [-p port]

-d directory      Monitoring installation directory
-i IP/hostname    Address exporting cardano-node Prometheus metrics
-p port           Port exporting cardano-node Prometheus metrics
```

Confirm the node metrics address and port in the cnode `config.json`. Current
Guild configs declare it in the root `TraceOptions` backend, for example
`PrometheusSimple suffix 127.0.0.1 12798`. The user running the script needs
`sudo` access because the script installs units in `/etc/systemd/system`.

Run it from the deployed scripts directory:

```bash
cd "${CNODE_HOME}/scripts"
./setup_mon.sh
```

For a custom location or metrics endpoint:

```bash
./setup_mon.sh \
  -d /opt/cardano/monitoring \
  -i 127.0.0.1 \
  -p 12798
```

The destination directory must not already exist. On success, the script
installs, starts, and enables `prometheus.service`, `node_exporter.service`, and
`grafana-server.service`.

## View dashboards

Open Grafana using the server address and configured port, which is `5000` by
default. The initial Grafana credentials are `admin` / `admin`; Grafana prompts
you to change the password at first login. The script provisions Prometheus as
a data source and installs the bundled dashboards.

Thanks to [Pal Dorogi](https://github.com/ilap) for the original setup
instructions.
