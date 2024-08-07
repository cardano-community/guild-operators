!!! info "Reminder !!"
    Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

`logMonitor.sh` is a general purpose JSON log monitoring script for traces created by `cardano-node`. Currently, it looks for traces related to leader slots and block creation but other uses could be added in the future. 

##### Block traces
For the core node (block producer) the `logMonitor.sh` script can be run to monitor the JSON log file created by `cardano-node` for traces related to leader slots and block creation.   

For optimal coverage, it's best run together with [CNCLI](../Scripts/cncli.md) scripts as they provide different functionalities. Together, they create a complete picture of blocks assigned, created, validated or invalidated due to node issues. 

##### Installation
The script is best run as a background process. This can be accomplished in many ways but the preferred method is to run it as a systemd service. A terminal multiplexer like tmux or screen could also be used but not covered here.

Use the `deploy-as-systemd.sh` script to create a systemd unit file (deployed together with [CNCLI](../Scripts/cncli.md)).
Log output is handled by journald. `journalctl -f -u cnode-logmonitor.service` can be used to check service output (follow mode). Other logging configurations are not covered here.  

##### View Blocklog
Best viewed in CNTools or gLiveView. See [CNCLI](../Scripts/cncli.md) for example output.
