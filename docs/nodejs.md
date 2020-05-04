### Updating Node.js Instructions

We will follow the instructions provided by the nodesource/distributions GitHub repository.

#### Supported Linux Distributions

#### *Ubuntu:*
14.04 LTS, 16.04 LTS, 18.04 LTS, 18.10, 19.04, 19.10, 20.04 LTS

### Installation instructions

```bash
# Using Ubuntu
curl -sL https://deb.nodesource.com/setup_14.x | sudo -E bash -
sudo apt install -y nodejs
# This will install Node.js v14.x and npm but you can replace 14 with 10, 12, or 13 for earlier versions
# You may also need development tools to build native addons:
sudo apt install gcc g++ make
# To install the Yarn package manager, run:
curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
sudo apt-get update && sudo apt-get install yarn
```

### Check the Installation

```bash
node -v
# Check to make sure Node.js version is at least 10.0.0
# If you want to check which yarn version is installed, run:
yarn version
```