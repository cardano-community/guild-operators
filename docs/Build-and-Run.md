### Build and Run

This document is built using instructions from [IOHK repositories](https://github.com/input-output-hk) as a foundation, with additional info/clarification which we can contribute to where appropriate.

**The instructions are intentionally limited to cabal** to avoid wait times/availability of nix/docker/stack.yaml files on, what we expect to be, a rapidly developing codebase - this will also help prevent managing multiple versions of instructions (at least for now).

Note that the instructions are predominantly focused around building Cardano components and OS/3rd-party software (eg: postgres) setup instructions are intended to provide build-level information only.

Of course, we can always add links with specific best practices related to those instructions - for those who would like to contribute, please open a PR directly on the [github repo](https://github.com/cardano-community/guild-operators/tree/master/docs) to do so.

#### Docker Builds:

If you would like to go down the Docker route, the basic instructions to get you set up with Docker itself are below. Additionally, you can follow [IOHK Adrestia documentation](https://input-output-hk.github.io/adrestia/docs/installation/) for the latest release information:
``` bash
# CentOS
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo yum install https://download.docker.com/linux/centos/7/x86_64/stable/Packages/containerd.io-1.2.6-3.3.el7.x86_64.rpm
sudo yum install -y docker-ce docker-ce-cli
sudo systemctl enable docker
sudo chkconfig docker on

## These steps would be automatically performed by the install above
# sudo groupadd docker
# sudo usermod -aG docker $USER
sudo curl -L "https://github.com/docker/compose/releases/download/1.25.5/docker-compose-$(uname -s)-$(uname -m)" -o /usr/bin/docker-compose;chmod 755 /usr/bin/docker-compose
```
