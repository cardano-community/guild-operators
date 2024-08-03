### OS Requirements

- `docker-ce` installed - [Get Docker](https://docs.docker.com/get-docker/).

=== "Private mode"

    #### Use Cases
    
    - Pool Management
    - Wallet Management
    - Node testing
    
      ```bash
      docker run --init -dit
      --name <YourCName>
      --security-opt=no-new-privileges
      -e NETWORK=mainnet
      -v <your_custom_path>:/opt/cardano/cnode/priv
      -v <your_custom_db_path>:/opt/cardano/cnode/db
      cardanocommunity/cardano-node
      ```

=== "Public mode"

    #### Use Cases:
    
    - Node Relay
    
      ```bash
      docker run --init -dit
      --name <YourCName>
      --security-opt=no-new-privileges
      -e NETWORK=mainnet
      -p 6000:6000
      -v <your_custom_path>:/opt/cardano/cnode/priv
      -v <your_custom_db_path>:/opt/cardano/cnode/db
      cardanocommunity/cardano-node
      ```

    - Node Relay with custom permanent cfg by passing the env variable CONFIG 
      (Mapping your configuration folder as below will allow you to retain configurations if you update or delete your container)

      ```bash
      docker run --init -dit
      --name <YourCName>
      --security-opt=no-new-privileges
      -e NETWORK=mainnet
      -e CONFIG=/opt/cardano/cnode/priv/<your own configuration files>.yml
      -p 6000:6000
      -v <your_custom_path>:/opt/cardano/cnode/priv
      -v <your_custom_db_path>:/opt/cardano/cnode/db
      cardanocommunity/cardano-node
      ```


!!! info "Note"
    1) `--entrypoint=bash` # This option won't start the node's container but only the OS running (the node software wont actually start, you'll need to manually execute entrypoint.sh ), ready to get in (trough the command ``` docker exec -it < container name or hash >  /bin/bash ```) and play/explore around with it in command line mode.
    2) all guild tools env variable can be used to start a new container using custom values by using the "-e" option.
    3) CPU and RAM and Shared Memory allocation option for the container can be used when you start the container (i.e. --shm-size or --memory or --cpus [official docker resource docs](https://docs.docker.com/config/containers/resource_constraints/))
    4) `--env MITHRIL_DOWNLOAD=Y` # This option will allow Mithril client to download the latest Mithril snapshot of the blockchain when the container starts and does not have a copy of the blockchain yet. This is useful when you want to start a new node from scratch and don't want to wait for the node to sync from the network. This option is not currently available for the guild network.
    5) `--env ENTRYPOINT_PROCESS=mithril-signer.sh` # This option will allow the container to start the Mithril signer process instead of the node process. This is useful when you want to run a Mithril signer node and have the container setup the configuration files based on the NETWORK environment varaible.