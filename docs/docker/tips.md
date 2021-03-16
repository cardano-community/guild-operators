### How to run a **Cardano Node** with Docker

With this quick guide you will be able to run a cardano node in seconds and also have the powerfull Guild operator's scripts *built-in*.

### How to operate interactively within the container

Once executed the container as a deamon with attached tty by using the flags `-dit` you are then enable to enter within the container

While if you have an hook within the continer console use the following command (change `CN` with your container name)

```bash
docker exec -it CN bash 
```

This command will bring you within the contaner bash env ready to use the Guild tools.

### Docker flags explained

```bash
"docker build" options explained:
 -t : option is to "tag" the image you can name the image as you prefer as long as you maintain the references between dockerfiles.

"docker run" options explained:
 -d : for detach the container
 -i : interactive enabled 
 -t : terminal session enabled
 -e : set an Env Variable
 -p : set exposed ports (by default if not specified the ports will be reachable only internally)
 --hostname : Container's hostname
 --name : Container's name
```

### Custom container with your own cfg

```bash
docker run -itd  
-name Relay                                   #Optional(raccomended for quick access): set a name to your newly created container.
-p 9000:6000                                  #Optional: to expose the internal container's port (6000) to the host <IP> port 9000
-e NETWORK=mainnet                            #Mandatory: mainnet / testnet / staging / launchpad / guild-mainnet / guild
--security-opt=no-new-privileges              #Option to prevent privilege escalations
-v <YourNetPath>:/opt/cardano/cnode/sockets   #Optional: useful to share the node socket wit other containers
-v <YourCfgPath>:/opt/cardano/cnode/priv      #Optional: if used has to contain all the configuration files nedeed to run a node 
-v <YourDBbk>:/opt/cardano/cnode/db           #Optional: if not set a fresh DB will be downloaded from scatch
cardanocommunity/cardano-node:latest          #Mandatory: image to run
```

### Docker CLI managment

#### Official
- docker inspect
- docker ps
- docker ls
- docker stop

### Un-Official Docker managment cli tool
- [Lazydocker](https://github.com/jesseduffield/lazydocker)
