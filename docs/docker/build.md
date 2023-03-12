### Intro

💡 Docker containers are the fastest way to run a Cardano node in both "Relay" and "Block-Producing" (Pool) mode.

#### How to build

  ```bash
  docker build -t cardanocommunity/cardano-node:latest - < dockerfile_bin
  ```
  

#### For Windows Users

With Powershell on Windows, you can run docker by typing the following command:

```
Get-Content dockerfile_bin  | docker build -t guild-operators/cardano-node:latest -
```

#### See also

[Docker Tips](../docker/tips.md)

[Docker Official Docs](https://docs.docker.com/)
