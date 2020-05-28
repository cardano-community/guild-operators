### Cardano Node Tools

This is a multi-purpose script to operate various activities (like creating keys, transactions, registering stake pool , delegating to a pool or updating binaries) using cardano node.

The script assumes the [Pre-Requisites](../Common.md#dependencies-and-folder-structure-setup) have already been run.

#### Download setup_mon.sh

If you have run `prereqs.sh`, this should already be available in your scripts folder. To download cntools.sh you can execute the commands below:
``` bash
cd $CNODE_HOME/scripts
wget https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/setup_mon.sh
chmod 750 setup_mon.sh
```

#### Set up Monitoring

Execute setup_mon.sh with full path to destination folder you want to setup monitoring in

``` bash
./setup_mon.sh /opt/cardano/cnode/monitoring
#
# Please use hasPrometeus's IP:PORT from node's config file.
# The files will be installed in the "/opt/cardano/cnode/monitoring" directory.
# What port will be used for prometheus web server (Default is 9090)?9003
# What is the ip of the node (default:127.0.0.1)?
# What port is used for prometheus metrics of the node running on 127.0.0.1's (Default is 9001)?
# Is this correct? http://127.0.0.1:9001/metrics
# Do you want to continue? [Y/n/q] Y
# 
# Downloading prometheus v2.18.1...
# Downloading grafana v7.0.0...
# Downloading exporter v0.18.1...
# Downloading grafana dashboard(s)...
#   - Haskel_Node_SKY_Relay1_Dash.json
#   - cardano-application-dashboard-v2.json
# 
# Configuring components
# 
# 
# =====================================================
# Installation is completed
# =====================================================
# 
# - Prometheus (default): http://localhost:9003/metrics
#     Node metrics:       http://127.0.0.1:9001
#     Node exp metrics:   http://127.0.0.1:9002
# - Grafana (default):    http://localhost:3000
# 
# 
# You need to do the following to configure grafana:
# 0. Start the required services in a new terminal by "/opt/cardano/cnode/monitoring/start_all.sh"
#   - check the prometheus and its exporters by opening URLs above after start.
# 1. Login to grafana as admin/admin (http://localhost:3000)
# 2. Add "prometheus" (all lowercase) datasource (http://localhost:9003)
# 3. Create a new dashboard by importing dashboards (left plus sign).
#   - Sometimes, the individual panel's "prometheus" datasource needs to be refreshed.
# 
# Enjoy...
# 
# Cleaning up...
```
