> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

This is an easy-to-use script to automate setting up of monitoring tools. Tasks automates the following tasks:
- Installs Prometheus, Node Exporter and Grafana Servers for your respective Linux architecture.
- Configure Prometheus to connect to cardano node and node exporter jobs.
- Provisions the installed prometheus server to be automatically available as data source in Grafana.
- Provisions two of the common grafana dashboards used to monitor `cardano-node` by [SkyLight](https://oqulent.com/skylight-pool/) and IOHK to be readily consumed from Grafana.
- Deploy `prometheus`,`node_exporter` and `grafana-server` as systemd service on Linux.
- Start and enable those services.

Note that securing prometheus/grafana servers via TLS encryption and other security best practices are out of scope for this document, and its mainly aimed to help you get started with monitoring without much fuss.

!> Ensure that you've opened the firewall port for grafana server (default used in this script is 5000)

#### Download setup_mon.sh {docsify-ignore}

If you have run `prereqs.sh`, you can skip this step. To download monitoring script, you can execute the commands below:
``` bash
cd $CNODE_HOME/scripts
wget https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/setup_mon.sh
chmod 750 setup_mon.sh
```

#### Customise any Environment Variables

The default selection may not always be usable for everyone. You can customise further environment variable settings by opening in editor (eg: `vi setup_mon.sh` ), and updating variables below to your liking:

``` bash
#!/bin/bash
# shellcheck disable=SC2209,SC2164

######################################################################
#### Environment Variables
######################################################################
CNODE_IP=127.0.0.1
CNODE_PORT=12798
GRAFANA_HOST=0.0.0.0
GRAFANA_PORT=5000
PROJ_PATH=/opt/cardano/monitoring
PROM_HOST=127.0.0.1
PROM_PORT=9090
NEXP_PORT=$(( PROM_PORT + 1 ))
````

#### Set up Monitoring

Execute setup_mon.sh with full path to destination folder you want to setup monitoring in. If you're following guild folder structure, you do not need to specify `-d`. Read the usage comments below before you run the actual script.

Note that to deploy services as systemd, the script expect sudo access is available to the user running the script.

``` bash
cd $CNODE_HOME/scripts
# To check Usage parameters:
# ./setup_mon.sh -h
#Usage: setup_mon.sh [-d directory] [-h hostname] [-p port]
#Setup monitoring using Prometheus and Grafana for Cardano Node
#-d directory      Directory where you'd like to deploy the packages for prometheus , node exporter and grafana
#-i IP/hostname    IPv4 address or a FQDN/DNS name where your cardano-node (relay) is running (check for hasPrometheus in config.json; eg: 127.0.0.1 if same machine as cardano-node)
#-p port           Port at which your cardano-node is exporting stats (check for hasPrometheus in config.json; eg: 12798)
./setup_mon.sh
# 
# Downloading prometheus v2.18.1...
# Downloading grafana v7.0.0...
# Downloading exporter v0.18.1...
# Downloading grafana dashboard(s)...
#   - SKYLight Monitoring Dashboard
#   - IOHK Monitoring Dashboard
# 
# NOTE: Could not create directory as rdlrt, attempting sudo ..
# NOTE: No worries, sudo worked !! Moving on ..
# Configuring components
# Registering Prometheus as datasource in Grafana..
# Creating service files as root..
# 
# =====================================================
# Installation is completed
# =====================================================
# 
# - Prometheus (default): http://127.0.0.1:9090/metrics
#     Node metrics:       http://127.0.0.1:12798
#     Node exp metrics:   http://127.0.0.1:9091
# - Grafana (default):    http://0.0.0.0:5000
# 
# 
# You need to do the following to configure grafana:
# 0. The services should already be started, verify if you can login to grafana, and prometheus. If using 127.0.0.1 as IP, you can check via curl
# 1. Login to grafana as admin/admin (http://0.0.0.0:5000)
# 2. Add "prometheus" (all lowercase) datasource (http://127.0.0.1:9090)
# 3. Create a new dashboard by importing dashboards (left plus sign).
#   - Sometimes, the individual panel's "prometheus" datasource needs to be refreshed.
# 
# Enjoy...
# 
# Cleaning up...

```

#### View Dashboards

You should now be able to Login to grafana dashboard, using the public IP of your server, at port 5000.
The initial credentials to login would be *admin/admin*, and you will be asked to update your password upon first login.
Once logged on, you should be able to go to `Manage > Dashboards` and select the dashboard you'd like to view. Note that if you've just started the server, you might see graphs as empty, as initial interval for dashboards is 12 hours. You can change it to 5 minutes by looking at top right section of the page.

Thanks to [Pal Dorogi](https://github.com/ilap) for the original setup instructions used for modifying.
