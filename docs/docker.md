# Cardano Operator Guild Docker images (testnet / mainnet)
Modular docker images using stages based on Debian (dockerfiles and dockerhub images)

Based on the Guild work we decided to build the Cardano Node image in 3 stages:
- 1st stage: it uses `prereq.sh` to prepare the development enviroment before compiling the node source code. [dockerfile_stage2]
- 2nd stage: based on stage1 this stage intent is to compile and produce the binaries of the node. [dockerfile_stage2]
- 3rd stage: based upon a minimal debian image it incorporates the node's binaries as well as all the Guild's tools. [Dockerfile or dockerfile_stage3]

## Features:
- Full featured Guild Operators tools
	> cntools
	> gLiveView
    
- Monitoring ready
 	> EKG, Prometheus

## Documentation
- Intro and Scope
	> We like to offer a choice for the more 

- How to run a Cardano docker image
	> Network: relays setup
	> Ports setup (Relays, Pool, Prometheus)

- Docker cheatsheet


---------------------------------------------
## How to run a __Cardano Node__ with Docker
With this quick guide you will be able to run a cardano node in seconds and also have the Guild's powerfull operator's scripts.

### Default passive node (relay not exposing any port) - run cmd:
Useful to run locally for test purpose
```bash
docker run -dit -e NETWORK=relay cardanocommunity/cardano-node:latest
```


### Default passive node (relay not exposing any port) for Wallet/Pool Managment - run cmd:
Useful to run temporary locally to deal with node operator sensitive tasks like:
- Pool Management
- Wallet Management
- Node Overview

The option: `-v <YourCfgPath>:/opt/cardano/cnode/priv/` will enable the use of custom cfg as well as your own Wallet and Pool's file using `cntools`.

```bash
docker run -dit -name CN -v <YourCfgPath>:/opt/cardano/cnode/priv/ -e NETWORK=relay cardanocommunity/cardano-node:latest
```

## How to operate within the container
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
-v <YourNetPath>:/ipc                         #Optional: useful to share the node socket wit other containers
-v <YourCfgPath>:/opt/cardano/cnode/priv/     #Optional: if used has to contain all the configuration files nedeed to run a node 
-v <YourDBbk>:/tmp/mainnet-combo-db           #Optional: if not set a fresh DB will be downloaded from scatch
cardanocommunity/cardano-node:latest          #Mandatory: image to run
```
* __\<YourNetPath\>__   - is where your node.socket resides (needs to be shared if you want to run a wallet too)
* __\<YourCfgPath\>__   - Your cfg files (configuration.yaml, topology.json, genesis.yaml)
* __\<YourDBbk\>__      - Location of the node database backup



-----------
## How to build your own image from Dockerfile

- **Requirements:** [Docker](https://docs.docker.com/)

Instead of specifying a context, you can pass a single Dockerfile in the URL or pipe the file in via STDIN. 
Pipe the chosen Dockerfile (i.e. `dockerfile_stage3`) from STDIN:

by running the following command you will build your own docker image:
```
docker build --compress -t cardanocommunity/cardano-node:latest - < ./files/docker/node/dockerfile_stage3
```

With `-t` you can label the image as you prefer.


---
#### Windows Users using Powershell
You can run the following command:
```
Get-Content Debian_CN_Dockerfile | docker build -t guild-operators/cardano-node:latest -
```
---


***

## Port mapping
The dockerfiles are located in ./files/docker/ 

 Node Ports        |  Wallet Ports      | Flavors
------------:      | -------------:     | :-------------:
Node  (6000)       | Wallet (8090)      | Debian (`Dockerfile`)
Prometheus (12798) | Prometheus (12798) | 
EKG (12781)        |                    |


***