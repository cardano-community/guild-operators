`mithril-relay.sh` is a bash script for deployment of Squid Mithril Relays and a Nginx
loadbalancer. It provides functionalities such as:

* Installing and configuring Squid as a relay for a Cardano Block Producer.
* Installing and configuring Nginx as a load balancer for multiple Mithril Relays.

## Usage

```bash
bash [-d] [-l] [-u] [-h]
A script to setup Cardano Mithril relays

-d  Install squid and configure as a relay
-l  Install nginx and configure as a load balancer
-u  Skip update check
-h  Show this help text
```

# Description

The `mithril-relay.sh` script is a bash script for managing the Mithril Relay Server.
It provides functionalities such as installing and configuring Squid as a relay, installing and configuring Nginx as a load balancer.

# Environment Variables

The script uses the following environment variable:

- `RELAY_LISTENING_PORT`: The port on which the relay server listens.

# Execution

The script parses command line options and performs the corresponding actions based on the options provided. If the `-d` option is provided, it installs Squid and configures it as a relay. If the `-l` option is provided, it installs Nginx and configures it as a load balancer. If no options are provided, it displays the usage message.