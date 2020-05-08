# Docker Images 

In there here below section you can find a collection of procedure that will make you able to get you Cardano-* software safely running in docker containers using the Linux flavour of your choice.

## Available Unix Container Flavours
  - Debian    (Debian_Dockerfile)
  - CentOS    (CentOS_Dockerfile)
  - Nixos     (NixOS_Dockerfile)

The dockerfiles are located in ./files/ptn0/docker/ 

## How to build your own image from Dockerfile

- Requirements: [Docker](https://docs.docker.com/)

Instead of specifying a context, you can pass a single Dockerfile in the URL or pipe the file in via STDIN. 
Pipe the chosen Dockerfile (i.e. Debian_Dockerfile) from STDIN:

With bash on Linux, you can run:
```
$ docker build - < Debian_Dockerfile
```
With Powershell on Windows, you can run:
```
Get-Content Debian_Dockerfile | docker build -
```

## How to run your container from DockerHub

... tbd

 - Community DockerHub
 - IOHK DockerHub

