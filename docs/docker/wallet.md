### Cardano-Wallet (testnet / mainnet)

> At the moment the best way to run the Wallet container is trough the related docker compose file (`Wallet-docker-compose.yaml`) 

With bash on Linux, you can run _just_ for the wallet image:
```bash
$ docker build -t guild-operators/cardano-wallet:debian - < Debian_CW_Dockerfile
docker run -itd --name CW --hostname CW -p 8090:8090 -e NETWORK=mainnet guild-operators/cardano-wallet:latest 
```

## docker-compose
While to run a node + wallet trough the docker-compose cmd:
```bash
wget https://raw.githubusercontent.com/cardano-community/guild-operators/files/docker/Wallet-docker-compose.yaml
NETWORK=mainnet; docker-compose -f Wallet-docker-compose.yaml up    # add -d for detach mode

```

***
