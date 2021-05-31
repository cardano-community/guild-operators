### Intro

💡 Docker containers are fastest way to run a Cardano node in both "Relay" and "Block-Producing" mode.

For easy of use and maintenance we adopted a 3 stage building strategy.

Each stage derives from a specific phase of the building strategy:

* stage1 --> is the first stage of the builds and the only thing it does is to prep the compiling enviroment.
* stage2 --> at this stage the Cardano source code is downloaded and compiled on top of the stage1.
* stage3 --> Here is where we copy over a new debian-slim image the results of the copiled software (binaries and libs) including the guild's scripts and tools.

#### How to build {docsify-ignore}

You can chose to just start building from the stage3 (or a custom stage3 dockerfile) or build all 3 stages from scratch.

Instead of specifying a context, you can pass a single Dockerfile in the URL or pipe the file in via STDIN.
Pipe the chosen Dockerfile (i.e. `dockerfile_stage3`) from STDIN:

* Building the Stage1
  
  ```bash
  docker build -t cardanocommunity/cardano-node:stage1 - < dockerfile_stage1
  ```
  
  * Building the Stage2
  
  ```bash
  docker build -t cardanocommunity/cardano-node:stage2 - < dockerfile_stage2    
  ```
  
  * Building the Stage3
  
  ```bash
  docker build -t cardanocommunity/cardano-node:stage3 - < dockerfile_stage3 
  ```

#### For Windows Users {docsify-ignore}

With Powershell on Windows, you can run docker by typing the following command:

```
Get-Content dockerfile_stage3  | docker build -t guild-operators/cardano-node:latest -
```

#### See also {docsify-ignore}

[Docker Tips](docker/tips.md)

[Docker Official Docs](https://docs.docker.com/)
