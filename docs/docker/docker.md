Running your own Cardano node has never been so fast and easy.

### 🔔 Built-in tools  {docsify-ignore}

- cntools
- gLiveView
- cncli
- Monitoring ready
  - EKG, Prometheus


### Guild Operators Docker startegy (testnet / mainnet / staging / guild)  {docsify-ignore}

Modular docker images based on Debian.

Based on the Guild's work we decided to build the Cardano Node images in 3 stages:

- 1st stage: it uses `prereq.sh` to prepare the development enviroment before compiling the node source code.  -> [Stage1](../files/docker/dockerfile_stage1)
- 2nd stage: based on stage1 this stage intent is to compile and produce the binaries of the node. -> [Stage2](../files/docker/dockerfile_stage2)
- 3rd stage: based upon a minimal debian image it incorporates the node's binaries as well as all the Guild's tools. -> [Stage3](../files/docker/dockerfile_stage3)

### Additional docs  {docsify-ignore}

If you prefer to build the images your own than you can check:

- [Docker Build Documentation](docker/build.md)
- [Docker Wallet Image](docker/wallet.md)
- [Docker Tips](docker/tips.md)
- [Podman Tips](docker/podman.md)

### Port mapping  {docsify-ignore}

 The dockerfiles are located in ./files/docker/

| Node Ports        |  Wallet Ports      | Flavors
|------------:      | -------------:     | :-------------:
|Node  (6000)       | Wallet (8090)      | Debian (`Dockerfile`)
|Prometheus (12798) | Prometheus (12798) |
|EKG (12781)        |                    |

### External resources  {docsify-ignore}

- [DockerHub Guild's images](https://hub.docker.com/u/cardanocommunity)
- [YouTube Guild's Videos](https://www.youtube.com/channel/UC1eg3ljUWjIHeU0Vpqicj6A)

