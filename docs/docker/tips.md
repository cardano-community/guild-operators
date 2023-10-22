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