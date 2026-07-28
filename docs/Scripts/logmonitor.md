!!! info "Reminder !!"
    Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

!!! warning "Currently disabled and cnode-only"
    `logMonitor.sh` has not been updated for the current `cardano-node`
    tracing format. It exits without monitoring logs, and
    `logMonitor.sh systemd install` deliberately refuses to install a service
    that cannot run. Dingo and Amaru deployments do not install this helper.

`logMonitor.sh` is a legacy JSON log monitor for traces produced by
`cardano-node`. Its disabled parser looked for leader-slot and block-creation
events.

##### Block traces
Historically, a core node (block producer) could run `logMonitor.sh` against
the JSON log produced by `cardano-node` to find leader-slot and block-creation
traces. That parser is not usable with current tracing.

When supported, Log Monitor complemented [CNCLI](cncli.md); CNCLI blocklog does
not require Log Monitor and remains usable while this helper is disabled.

##### Installation

New installation is disabled until the tracing parser is updated. The script still owns the old unit name so stale installations can be inspected and safely removed:

``` bash
$CNODE_HOME/scripts/logMonitor.sh systemd status
$CNODE_HOME/scripts/logMonitor.sh systemd remove
```

The owned unit is `${CNODE_VNAME}-logmonitor.service` (`cnode-logmonitor.service` with the default prefix). No central systemd deployment script is required.

##### View Blocklog
Best viewed in CNTools or gLiveView. See [CNCLI](../Scripts/cncli.md) for example output.
