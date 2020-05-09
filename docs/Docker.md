# Docker Images 

In there here below section you can find a collection of procedure that will make you able to get you Cardano-* software safely running in docker containers using the Linux flavour of your choice.

## Port mapping

### Cardano node image exposing
- Node port (9000) 
- Prometheus port (12781) 
- EKG port (13788) 

### Cardano node image exposing
- Wallet port (8090)
- Prometheus port (12781) 



## Available Unix Container Flavours
  - Debian    (`Debian_Dockerfile`)
  - CentOS    (`CentOS_Dockerfile`)

The dockerfiles are located in ./files/ptn0/docker/ 

## How to build your own image from Dockerfile

- Requirements: [Docker](https://docs.docker.com/)

Instead of specifying a context, you can pass a single Dockerfile in the URL or pipe the file in via STDIN. 
Pipe the chosen Dockerfile (i.e. Debian_Dockerfile) from STDIN:



### Cardano-Node (passive / active / configuration)

With bash on Linux, you can run (in this example the Debian version):
```
wget https://raw.githubusercontent.com/cardano-community/guild-operators/docker/files/ptn0/docker/debian/Debian_CN_Dockerfile 
docker build -t guild-operators/cardano-node:debian - < Debian_CN_Dockerfile
docker run -itd --name CN --hostname CN -p 9000:9000 -it -e NETWORK=passive guild-operators/cardano-node:debian 
```
This last run command will run the container (Full passive Cardano Node) mapping the internal port of the container to your ip `-p 9000:9000` while you can change the `-e NETWORK=passive` paramiter to `active` or map your configuration directory with the `-v` parameter as follow:

```
docker run -itd --name CN --hostname CN -p 9000:9000 -it -v <PATHTOYOURDIR>:/configuration -e NETWORK=passive guild-operators/cardano-node:debian 
```

Once the container is running, you cat attach to it by running the following command (change `CN` with your container name):
```
docker attach CN
```
To detach the session without stopping the node press `CTRL+P` then `CTRL+Q` and you will be detached from the container
If you hit `CTRL+C` instead the container will be stopped.

While if you have an hook within the continer console use the following command (change `CN` with your container name)
```
docker exec -it CN bash 
```




#### WINZOZZ Users..

With Powershell on Windows, you can run (in this example the Debian version):
```
Get-Content Debian_CN_Dockerfile | docker build -t guild-operators/cardano-node:debian -
docker run -itd --name CN --hostname CN -p 9000:9000 -it -e NETWORK=passive guild-operators/cardano-node:debian 
```



### Cardano-Wallet (testnet / mainnet)

With bash on Linux, you can run:
```
$ docker build -t guild-operators/cardano-wallet:debian - < Debian_CW_Dockerfile
docker run -itd --name CN --hostname CN -p xx:xx -it -e NETWORK=mainnet guild-operators/cardano-wallet:debian 
```
With Powershell on Windows, you can run:
```
Get-Content Debian_CW_Dockerfile | docker build -t guild-operators/cardano-wallet:debian -
```



## How to run your container from DockerHub

... tbd

 - Community DockerHub
 - IOHK DockerHub (Nix Version)

