#!/bin/bash

# Determine OS platform
UNAME=$(uname | tr "[:upper:]" "[:lower:]")
# If Linux, try to determine specific distribution
if [ "$UNAME" == "linux" ]; then
    # If available, use LSB to identify distribution
    if [ -f /etc/lsb-release -o -d /etc/lsb-release.d ]; then
        export DISTRO=$(lsb_release -i | cut -d: -f2 | sed s/'^\t'//)
    # Otherwise, use release info file
    else
        export DISTRO=$(ls -d /etc/[A-Za-z]*[_-][rv]e[lr]* | grep -v "lsb" | cut -d'/' -f3 | cut -d'-' -f1 | cut -d'_' -f1)
    fi
fi
# For everything else (or if above failed), just use generic identifier
[ "$DISTRO" == "" ] && export DISTRO=$UNAME
unset UNAME

if [[ "Debian;Ubuntu;" == *"$DISTRO"* ]]; then
	echo "use apt to prepare packages for this ${DISTRO} system"
	sleep 3
	sudo apt-get update
	sudo apt-get -y install curl build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev libsystemd-dev zlib1g-dev tmux
elif [[ "CentOS"  == *"$DISTRO"* ]]; then
	echo "use yum to prepare packages for ${DISTRO} system"
	sudo apt-get update
	sudo yum -y install curl pkgconfig libffi-devel gmp-devel openssl-devel ncurses-libs systemd-devel zlib-devel tmux
	echo "You might need to create a symlink to /usr/lib64/libtinfo.so as per below if one does not already exist"
	echo " sudo ln -s $(ls -1 /usr/lib64/libtinfo.so* | tail -1) /usr/lib64/libtinfo.so"
	echo " sudo ln -s $(ls -1 /usr/lib64/libtinfo.so* | tail -1) /usr/lib64/libtinfo.so.5"
else
	echo "We have no automated procedures for this ${DISTRO} system"
	echo "please manually install required packages."
	echo "Their relative names are:"
	echo "Debian: curl build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev libsystemd-dev zlib1g-dev tmux"
	echo "CentOS: curl pkgconfig libffi-devel gmp-devel openssl-devel ncurses-libs systemd-devel zlib-devel tmux"
	exit;
fi

echo "Install ghcup (The Haskell Toolchain installer)"  
echo "In next step confirm 2x ENTER and type YES at the end to add ghcup to your PATH variable"  
echo "press any key to continue..."  
read just_a_pause_key

curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
source ~/.ghcup/env

ghcup install 8.6.5
ghcup set 8.6.5
ghc --version


