## Build your own Cardano Node

Building your own Cardano node has never been easier.

For easy of use and selective maintenance we adopted a 3 stage building strategy.
    
Each stage derives from a specific phase of the building strategy: 
* stage1 --> is the first stage of the builds and the only thing it does is to prep the compiling enviroment.
* stage2 --> at this stage the Cardano source code is downloaded and compiled on top of the stage1.
* stage3 --> Here is where we copy over a new debian-slim image the results of the copiled software (binaries and libs) including the guild's scripts and tools.

### Let's Build it

You can chose to just start building from the stage3 (or a custom stage3 dockerfile) or build all 3 stages from scratch.

Instead of specifying a context, you can pass a single Dockerfile in the URL or pipe the file in via STDIN. 
Pipe the chosen Dockerfile (i.e. `dockerfile_stage3`) from STDIN:

  - Building the Stage1
  
  ```bash 
  docker build -t cardanocommunity/cardano-node:stage1 - < dockerfile_stage1```
  
  
  - Building the Stage2
  
  ```bash 
  docker build -t cardanocommunity/cardano-node:stage2 - < dockerfile_stage2    ```
  
  
  - Building the Stage3
  
  ```bash 
  docker build -t cardanocommunity/cardano-node:stage3 - < dockerfile_stage3 ```   

  - Building the Stage1 Alpha

  ```bash 
  docker build -t cardanocommunity/cardano-node:alpha1 - < alpha/dockerfile_stage1alpha ```


---
#### Windows Users..
>With Powershell on Windows, you can run (in this example the Debian version):
>```
>Get-Content Debian_CN_Dockerfile | docker build -t guild-operators/cardano-node:latest -
>```
---

- [Docker Docs](https://docs.docker.com/)


Docker tips:
```
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