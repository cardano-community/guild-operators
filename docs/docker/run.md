### OS Requirements

- "docker-ce" installed.

### Private mode

#### Use Cases

- Pool Management
- Wallet Management
- Node testing

```bash
docker run -dit 
--name <YourCName>
--security-opt=no-new-privileges
-e NETWORK=mainnet 
-v <your_custom_path>:/opt/cardano/cnode/priv
-v <your_custom_db_path>:/opt/cardano/cnode/db
cardanocommunity/cardano-node 
```

### Public mode

#### Use Cases:

- Node Relay

```bash
docker run -dit 
--name <YourCName> 
--security-opt=no-new-privileges
-e NETWORK=mainnet
-p 6000:6000 
-v <your_custom_path>:/opt/cardano/cnode/priv
-v <your_custom_db_path>:/opt/cardano/cnode/db
cardanocommunity/cardano-node 
```

* Note: --entrypoint=bash       # This option wont start the node but only the docker os, ready to get in and play with it.

[**Next** Cardano Node - Docker Tips](docker/tips.md)
