#!/bin/bash

sudo apt-get update
sudo apt-get -y install curl build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev libsystemd-dev zlib1g-dev tmux

echo "Install ghcup (The Haskell Toolchain installer)"  
echo "In next step confirm 2x ENTER and type YES at the end to add ghcup to your PATH variable"  
echo "press any key to continue..."  
read just_a_pause_key

curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
source ~/.ghcup/env

ghcup install 8.6.5
ghcup set 8.6.5
ghc --version


