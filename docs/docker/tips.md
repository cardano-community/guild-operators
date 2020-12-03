## Documentation

- Docker cheatsheet


---------------------------------------------
## How to run a __Cardano Node__ with Docker
With this quick guide you will be able to run a cardano node in seconds and also have the Guild's powerfull operator's scripts.


## How to operate interactively within the container
Once executed the container as a deamon with attached tty by using the flags `-dit` you are then enable to enter within the container 

While if you have an hook within the continer console use the following command (change `CN` with your container name)
```bash
docker exec -it CN bash 
```
This command will bring you within the contaner bash env ready to use the Guild tools.

### Custom container with your own cfg.
```bash
docker run -itd  
-name Relay                                   #Optional(raccomended for quick access): set a name to your newly created container.
-p 9000:6000                                  #Optional: to expose the internal container's port (6000) to the host <IP> port 9000
-e NETWORK=relay                              #Mandatory: relay/master/pool/testnet/guild_relay (*howto chose iss descibed below in the related section)
-v <YourNetPath>:/opt/cardano/cnode/sockets   #Optional: useful to share the node socket wit other containers
-v <YourCfgPath>:/opt/cardano/cnode/priv     #Optional: if used has to contain all the configuration files nedeed to run a node 
-v <YourDBbk>:/opt/cardano/cnode/db          #Optional: if not set a fresh DB will be downloaded from scatch
cardanocommunity/cardano-node:latest          #Mandatory: image to run
```


