<p align="center"><a href="https://hub.docker.com/u/cardanocommunity" target="_blank"><img src="https://github.com/stakelovelace/cardano-node/blob/master/docker_intro.png"></a></p>

## How to run a __Cardano Node__ with Docker

### Intro

💡 Docker containers are fastest way to run a Cardano node in both "Relay" and "Block-Producing" mode.

[Docker Hub Guild's images](https://hub.docker.com/u/cardanocommunity)

Requirement:  "docker-ce" installed.

## Cardano Operator Guild Docker images (testnet / mainnet)
Modular docker images based on Debian.

Based on the Guild work we decided to build the Cardano Node images in 3 stages:
- 1st stage: it uses `prereq.sh` to prepare the development enviroment before compiling the node source code. [dockerfile_stage2]
- 2nd stage: based on stage1 this stage intent is to compile and produce the binaries of the node. [dockerfile_stage2]
- 3rd stage: based upon a minimal debian image it incorporates the node's binaries as well as all the Guild's tools. [Dockerfile or dockerfile_stage3]



 #### Private node - useful for testing.
```bash 
docker run -dit 
-e NETWORK=mainnet 
--name {YourCName} 
cardanocommunity/cardano-node 
```

* [Other 'docker run' examples](https://github.com/cardano-community/guild-operators/blob/docker/docs/docker/run.md)

If you prefer to build the images your own than you can check: 
* [Docker Build Documentaion](https://github.com/cardano-community/guild-operators/blob/docker/docs/docker/build.md)
* [Docker Wallet Image](https://github.com/cardano-community/guild-operators/blob/docker/docs/docker/wallet.md)
* [Docker Tips](https://github.com/cardano-community/guild-operators/blob/docker/docs/docker/tips.md)
* [Podman Tips](https://github.com/cardano-community/guild-operators/blob/docker/docs/docker/podman.md)

***

## Port mapping
The dockerfiles are located in ./files/docker/ 

 Node Ports        |  Wallet Ports      | Flavors
------------:      | -------------:     | :-------------:
Node  (6000)       | Wallet (8090)      | Debian (`Dockerfile`)
Prometheus (12798) | Prometheus (12798) | 
EKG (12781)        |                    |
***


## 🔔 Features: 
- Full featured Guild Operators tools
	> cntools
	> gLiveView

### Default passive node (relay not exposing any port) use cases:
- Pool Management
- Wallet Management
- Node Overview
- Monitoring ready
 	> EKG, Prometheus