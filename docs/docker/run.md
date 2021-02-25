## Run you own __Cardano Node__ 

## OS Requirements

- "docker-ce" installed.

## Private mode

### use cases

- Pool Management
- Wallet Management
- Node testing

```bash
docker run -dit 
-e NETWORK=mainnet 
--name <YourCName>
-p <your_custom_path>:/opt/cardano/cnode/priv
-p <your_custom_db_path>:/opt/cardano/cnode/db
cardanocommunity/cardano-node 
```

## Public mode

### use cases:

- Node Relay

```bash
docker run -dit 
--name <YourCName> 
-e NETWORK=mainnet
-p 6000:6000
-e NETWORK=mainnet  
-p <your_custom_path>:/opt/cardano/cnode/priv
-p <your_custom_db_path>:/opt/cardano/cnode/db
cardanocommunity/cardano-node 
```

* Note: --entrypoint=bash       # This option wont start the node but only the docker os, ready to get in and play with it.