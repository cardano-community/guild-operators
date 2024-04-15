### How to run a **Cardano Node** with Docker

With this quick guide you will be able to run a cardano node in seconds and also have the powerfull Koios SPO scripts *built-in*.

### How to operate interactively within the container

Once executed the container as a deamon with attached tty you are then able to enter the container by using the flag `-dit` .

While if you have a hook within the container console, use the following command (change `CN` with your container name):

```bash
docker exec -it CN bash 
```

This command will bring you within the container bash env ready to use the Koios tools.

### Docker flags explained

```bash
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

### Custom container with your own cfg

```bash
docker run --init -itd  
-name Relay                                   # Optional (recommended for quick access): set a name for your newly created container.
-p 9000:6000                                  # Optional: to expose the internal container's port (6000) to the host <IP> port 9000
-e NETWORK=mainnet                            # Mandatory: mainnet / preprod / guild-mainnet / guild
--security-opt=no-new-privileges              # Option to prevent privilege escalations
-v <YourNetPath>:/opt/cardano/cnode/sockets   # Optional: useful to share the node socket with other containers
-v <YourCfgPath>:/opt/cardano/cnode/priv      # Optional: if used has to contain all the sensitive keys needed to run a node as core
-v <YourDBbk>:/opt/cardano/cnode/db           # Optional: if not set a fresh DB will be downloaded from scratch
cardanocommunity/cardano-node:latest          # Mandatory: image to run
```

!!! info "Note"
    To be able to use the CNTools encryption key feature you need to manually change in "cntools.config" ENABLE_CHATTR to "true" and not use the `--security-opt=no-new-privileges` docker run option.

### Docker CLI managment

#### Official
- docker inspect
- docker ps
- docker ls
- docker stop

#### Un-Official Docker managment cli tool
- [Lazydocker](https://github.com/jesseduffield/lazydocker)

### Docker backups and restores

The docker container has an optional backup and restore functionality that can be used to backup the `/opt/cardano/cnode/db` directory. To have the 
backup persist longer than the countainer, the backup directory should be mounted as a volume.

[!NOTE]
The backup and restore functionality is disabled by default.

[!WARNING]
Make sure adequate space exists on the host as the backup will double the space consumed by the database. 

#### Creating a Backup

When the container is started with the **ENABLE_BACKUP** environment variable set to **Y** the container will automatically create a
backup in the `/opt/cardano/cnode/backup/$NETWORK-db` directory. The backup will be created when the container is started and if the
backup directory is smaller than the db directory.

#### Restoring from a Backup

When the container is started with the **ENABLE_RESTORE** environment variable set to **Y** the container will automatically restore
the latest backup from the `/opt/cardano/cnode/backup/$NETWORK-db` directory. The database will be restored when the container is started
and if the backup directory is larger than the db directory.

### Configuration Update Check Functionality

The container now includes a static copy of each network's configuration files (Mainnet, Preprod, Preview, Sanchonet,
and Guild networks). The `NETWORK` environment variable passed into the container determines which configuration files
are copied into `$CNODE_HOME/files`.

The `UPDATE_CHECK` environment variable controls whether the container updates these configuration files from GitHub
before starting. By default, the container has the environment variable set to `UPDATE_CHECK=N`, meaning the container
uses the configuration files it was built with. This can be overriden either persistently or dynamically.

#### Persistently updating configuration files

To always update the configuration files from GitHub, set the `UPDATE_CHECK` environment variable when creating the
container by using the `--env` option, for example `--env UPDATE_CHECK=Y`.

To always update the configuration files from a specific GitHub account, set the `G_ACCOUNT` environment variable when
creating the container by using the `--env` option, for example `--env G_ACCOUNT=gh-fork-user`.

[!NOTE]
There is no way to change the environment variable of an already running container. To rollback the configuration files and scripts stop and remove the container and start it without setting the environment variable.

#### Dynamically updating configuration files

Set an environment file during create/run using `--env-file=file`, for example `--env-file=/opt/cardano/cnode/.env`.

* When `UPDATE_CHECK` is not defined in the environment file, the container will use the built-in configs.
* When `UPDATE_CHECK=Y` is defined in the environment file the container will update configs and scripts from the
  `cardano-community` GitHub repository.
  * When `G_ACCOUNT` is defined in the environment file, the container will update configs and scripts from the GitHub
  repository of the specified account.

To rollback the configuration files to the built-in versions, remove the `UPDATE_CHECK=Y` or set it to `UPDATE_CHECK=N` in the environment file. The static configuration files in the container will be used, however the scripts will remain updated. If you want both the configuration files and scripts to be rolled back, you will need to stop and remove the container and create a new one.

### Building Images from Forked Repositories

Run the **Docker Image** GitHub Action to build and push images to the `ghcr.io` registry.

* The `G_ACCOUNT` will be inherited from the `GITHUB_REPOSITORY_OWNER`.
  * It will be all lowercase so it matches container image name requirements.
* All images not from **master** branch or when **Testing workflow** is checked will be pushed to `ghcr.io`.
* Images from the master branch will also be pushed to the `ghcr.io` registry as long as the **Testing workflow**
remains checked.
