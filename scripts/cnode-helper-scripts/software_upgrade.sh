#!/bin/bash


###################################
# sudo password for sudo commands #
###################################

if [[ "$(/usr/bin/whoami)" != "root" ]]; then
sudo -p "The script needs the admin/sudo password to continue, please enter: " date 2>/dev/null 1>&2
        if [ ! $? = 0 ]; then
            echo "You entered an invalid password. Script aborted."
            exit 1
        fi
fi



####################################
# Operating System (Linux) upgrade #
####################################
{
while true; do
                read -p "Update Operating System (Linux)? (yes or no): " INPUT
                if [ "$INPUT" = "no" ]; then
                        echo "Skipped! The software upgrade will continue without updating the Operating System... please wait"
                        sleep 3
                elif [ "$INPUT" = "yes" ]; then
                        echo "Updating Operating System (Linux)... please wait"
                        sleep 3
                        sudo apt-get update        # command is used to download package information from all configured sources.
                        sudo apt-get upgrade       # You run sudo apt-get upgrade to install available upgrades of all packages currently installed on the system from the sources configured via sources. list file. New packages will be installed if required to satisfy dependencies, but existing packages will never be removed
                else
                        echo  "yes or no"
                        continue
                fi
break
done
}

#################################
# Node software upgrade section #
#################################

cd ~/git/cardano-node
{
while true; do

        TAGS=$(git tag)
        read -p "Enter version: " version
                if [[ $TAGS == *"$version"* ]]; then            # checking if the version entered is available on github
                        echo "Version valid"
                        sleep 3
                else
                        echo "Version invalid, enter a valid version: "
                        continue
                fi
        break
        done
}

echo "Checking for current version, please wait... "
sleep 3
current_version=$(cardano-node --version | grep node | cut -c13-20)     # checking for the version running on server
echo "Current version running:" $current_version

if [ $current_version = $version ]; then
        {
        while true; do
        read -p "Version already installed, do you want to continue anyway? (yes or no) "  INPUT
                if [ "$INPUT" = "no" ]; then
                        echo "Upgrade skipped, software" $current_version "already installed!"
                        sleep 3
                        exit 1
                elif [ "$INPUT" = "yes" ]; then
                        echo "Upgrading cardano-node to" $current_version...
                        sleep 3
                else
                        echo  "yes or no"
                        continue
                fi
        break
        done
        }
fi

        echo "Stopping cardano-node..."
#               sudo systemctl stop cnode
                sleep 10
        echo "Updating cabal, please wait..."
#               cabal update
#               cd ~/git
#               sudo rm -R cardano-node
#               git clone https://github.com/input-output-hk/cardano-node
#               cd cardano-node

#               git fetch --tags --all
#               git checkout $version


#               echo -e "package cardano-crypto-praos\n  flags: -external-libsodium-vrf" > cabal.project.local

         echo "Starting cardano-node software upgrade, it will take a while, meantime you can enjoy some coffee :)"
#               $CNODE_HOME/scripts/cabal-build-all.sh

        echo "The software upgrade is succesfully, starting the node"
#                sudo systemctl start cnode
                sleep 10
        cd $CNODE_HOME/scripts

{
while true; do

        read -p "The node has been started, do you want to open gLiveView? (yes or no): " INPUT
                if [ "$INPUT" = "no" ]; then
                        echo "Good-bye!"
                        exit 1
                elif [ "$INPUT" = "yes" ]; then
                        echo "Opening gLiveView, please wait..."
                        sleep 3
                        ./gLiveView.sh
                else
                        echo  "yes or no"
                        continue
                fi
        break
        done
}
