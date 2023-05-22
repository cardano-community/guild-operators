### OS Requirements

- `docker-ce` installed - [Get Docker](https://docs.docker.com/get-docker/).

=== "Private mode"

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

    - Hardware Wallet Management

      ```bash
      docker run -dit
      --name <YourCName>
      --security-opt=no-new-privileges
      -e NETWORK=mainnet
      -v <your_custom_path>:/opt/cardano/cnode/priv
      -v <your_custom_db_path>:/opt/cardano/cnode/db
      --annotation run.oci.keep_original_groups=1
      --privileged=True
      --security-opt no-new-privileges
      --mount type=devpts,destination=/dev/pts
      --volume /dev/:/dev:rslave
      cardanocommunity/cardano-node
      ```

!!! info "Note"
    1) For hardware wallet management start the node temporarily as shown above
    passing through the USB devices of the host, with elevated privileges, for
    the trezor bridge process to access the USB bus.
    2) Start trezord (trezor bridge) as the root and disconnect
    ```docker exec -dit -u root <YourCName> trezord -l /opt/cardano/cnode/logs/trezord.log```
    3) Login to the container ``` docker exec -it < container name or hash >  /bin/bash ```
    4) Execute cntools ``` cntools ``` and follow instructions when told to
    take actions on the hardware wallet.


=== "Public mode"

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

    - Node Relay with custom permanent cfg by passing the env variable CONFIG 
      (Mapping your configuration folder as below will allow you to retain configurations if you update or delete your container)

      ```bash
      docker run -dit
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
    3) CPU and RAM and SHared Memory allocation option for the container can be used when you start the container (i.e. --shm-size or --memory or --cpus [official docker resource docs](https://docs.docker.com/config/containers/resource_constraints/))