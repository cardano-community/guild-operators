
Running your own Cardano node has never been so fast and easy.

!!! info ""
    But first, a kind reminder to the [security aspects of running docker containers](../docker/security.md).

### External resources

- [DockerHub Guild's images](https://hub.docker.com/u/cardanocommunity)
- [YouTube Guild's Videos](https://www.youtube.com/channel/UC1eg3ljUWjIHeU0Vpqicj6A)

### 🔔 Built-in Cardano software

- cardano-address
- cardano-cli
- cardano-hw-cli
- cardano-node
- cardano-submit-api
- mithril-client
- mithril-signer

#### Mithril

### 🔔 Built-in tools

- CNTools
- gLiveView
- CNCLI
- Ogmios
- Cardano Hardware CLI
- Cardano Signer
- Monitoring ready (with EKG and Prometheus)

#### Docker Splash screen

![Docker Splash screen](./imgs/container_splashscreen.png)

#### Cntools 

![CNTools](./imgs/cntools.png)

#### gLiveView

![gLiveView](./imgs/gLiveView.png)

#### gLiveView Peers analyzer 

![gLiveView](./imgs/gLiveView_peers.png)

#### CNCLI

![CNCLI](./imgs/cncli.png)

#### Guild Operators Docker strategy ( mainnet/ preview / preprod / guild)  {: id="strategy"}

Modular docker images based on Debian.

Based on the Guild's work the Cardano Node image is built in a single stage: -> [dockerfile_bin](https://github.com/cardano-community/guild-operators/blob/master/files/docker/node/dockerfile_bin)

- Uses `guild-deploy.sh` to:
  - Install the os prerequisites
  - Add the cardano software from release binaries
  - Add the guild's SPO tools and the node's configuration files.


### Additional docs

If you prefer to build the images your own than you can check:

- [Docker Build Documentation](../docker/build.md)
- [Docker Tips](../docker/tips.md)

### Port mapping

 The dockerfiles are located in ./files/docker/

| Node Ports        |  Wallet Ports      | Flavor        |
| ------------:     | -------------:     |:-------------:|
| Node  (6000)      | Wallet (8090)      | Debian        |
| Prometheus (12798)| Prometheus (12798) |               |
| EKG (12781)       |                    |               |
