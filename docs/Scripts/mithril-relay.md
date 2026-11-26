`mithril-relay.sh` deploys Squid Mithril relays and an Nginx load balancer. It
can:

- Install and configure Squid as a relay for a Cardano block producer.
- Install and configure Nginx as a load balancer for multiple Mithril relays.

!!! warning "cnode-only deployment"
    This helper is currently installed only by the cnode profile. Dingo and
    Amaru deployments do not install it.

## Usage

```bash
mithril-relay.sh [-d] [-l] [-s] [-u] [-h]
A script to setup Cardano Mithril relays

-d  Install squid and configure as a relay
-l  Install nginx and configure as a load balancer
-u  Skip update check
-s  Stop relays
-h  Show this help text
```

## Description

The `mithril-relay.sh` script is a bash script for managing the Mithril Relay Server.
It provides functionalities such as installing and configuring Squid as a relay, installing and configuring Nginx as a load balancer.

## Environment Variables

The script uses the following environment variable:

- `RELAY_LISTENING_PORT`: The port on which the relay server listens.

## Execution

If `-d` is provided, the script installs Squid and configures it as a relay.
If `-l` is provided, it installs Nginx and configures it as a load balancer.
`-s` stops the configured Squid and Nginx services. This helper manages those
distribution services directly and does not expose the Guild component
`systemd install|remove|status` interface. With no option it prints usage and
exits.
