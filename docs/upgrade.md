### One Time major upgrade for Guild Scripts from 15-Oct-2020

We would like to start by thanking entire community for the love, adoption and contribution to the repositories. We look forward to more contributions and working together.

#### Preface for Upgrade

Given the increase in usage and adoptability of the scripts, we have seen some repititive requests as well as learnt that if we are to keep adding features, we need to rewrite the scripts to accomodate:

- Update components in place
- Handle Multiple Networks using flags - reducing manual download of file/configs.
- Retain User customisations, while trying to reduce number of files (topology, custom ports, paths, etc)
- Re-use code as much as possible, instead of re-writing across scripts
- Have better workflow for troubleshooting using alternate git branches
- Standardise the method of accessing information and use EKG as much as possible
- This was merged nicely with the addition of CNTools Offline transaction signing and online creation/submission process (details [here](Scripts/cntools-common.md#offline-workflow) )
- We also use this opportunity to make some changes to topologyUpdater script to not require a seperate fetch call, and let variables be defined using consistent manner, including custom peers for own relays. @Gufmar has modified the backend service, to atleast provide a minimal viable topology file (includes IOG peers alongwith custom ones) in case you're not allowed to fetch yet.

Some or all of the above required us to rewrite some artifacts in a way that is more future proof, but is not too much of a hassle to existing users of guild scripts. We have tried to come up with what we think is a good balance, but would like to apologize in advance if this does not seem very convinient to a few.

#### Steps for Upgrade

!> Remember that same as before, you're running these as non root user with sudo access for the session.

- Download the latest prereqs.sh (tip: do checkout new features in `prereqs.sh -h`) to update all the scripts and files from the guild template. Most of the files modified with user content (env, gLiveView.sh, topologyUpdater.sh, cnode.sh, etc) will be backed up before overwriting. The backed up files will be in the same folder as the original files, and will be named as *${filename}_bkp<timestamp>*. More static files (genesis files or some of the scripts themselves) will not be backed up, as they're not expected to be modified.

``` bash
mkdir "$HOME/tmp";cd "$HOME/tmp"
curl -sS -o prereqs.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/prereqs.sh
chmod 700 prereqs.sh
./prereqs.sh -f
```

- Check and add back your customisations.
Below is a list of files that you will typically customise against each script. `env` file is usually the common place for most user variables, while there may be a few scripts which may have variables within themselves:  

|User-Defined customisations :arrow_down: \ Applies to :arrow_right: | gLiveView.sh |   cntools.sh   | topologyUpdater.sh | cnode.sh | topology.json | config.json |
|:-------------------------------------------------------------------|:------------:|:--------------:|:------------------:|:--------:|:-------------:|:-----------:|
|env                                                                 |:heavy_check_mark:|:heavy_check_mark:|:heavy_check_mark:|:heavy_check_mark:|:x:|:x:          |
|Script/File itself                                                  |:eyes:        |:x:             |:heavy_check_mark:  |:heavy_check_mark:    |:heavy_check_mark:|:heavy_check_mark:|
|Others                                                              |:x:           |*cntools.config*|:x:                 |:x:       |:x:            |:x:          |

:heavy_check_mark: - It is likely that you'd want to visit/update customisations.  
:eyes: - Usually users dont need to touch, but it is supported for scenarios when they're applying non-standard customisations.  
:x: - No customisations required.

Typical section that you may want to modify (if defaults dont work for you):

``` bash
######################################
# User Variables - Change as desired #
# Leave as is if unsure              #
######################################

#CCLI="${HOME}/.cabal/bin/cardano-cli"                  # Override automatic detection of path to cardano-cli executable
#CNCLI="${HOME}/.cargo/bin/cncli"                       # Override automatic detection of path to cncli executable (https://github.com/AndrewWestberg/cncli)
#CNODE_HOME="/opt/cardano/cnode"                        # Override default CNODE_HOME path (defaults to /opt/cardano/cnode)
CNODE_PORT=6000                                         # Set node port
#CONFIG="${CNODE_HOME}/files/config.json"               # Override automatic detection of node config path
#SOCKET="${CNODE_HOME}/sockets/node0.socket"            # Override automatic detection of path to socket
#EKG_HOST=127.0.0.1                                     # Set node EKG host
#EKG_PORT=12788                                         # Override automatic detection of node EKG port
#EKG_TIMEOUT=3                                          # Maximum time in seconds that you allow EKG request to take before aborting (node metrics)
#CURL_TIMEOUT=10                                        # Maximum time in seconds that you allow curl file download to take before aborting (GitHub update process)
#BLOCKLOG_DIR="${CNODE_HOME}/guild-db/blocklog"         # Override default directory used to store block data for core node
#BLOCKLOG_TZ="UTC"                                      # TimeZone to use when displaying blocklog - https://en.wikipedia.org/wiki/List_of_tz_database_time_zones

######################################
# Do NOT modify code below           #
######################################
```


!> The way user content is retained during future upgrades is all the user customisations are to be retained above the line stating `DO NOT MODIFY`, anything after that line will be overwritten with the latest code from github.


#### Advanced Users/Testers only

For folks who would like to try out an unreleased feature by using a specific branch (`alpha` for example), you can now do so. While setting up your repository, use `prereqs.sh -b alpha -f` where alpha is the name of the branch.
The `-b branch` argument is also extended to cntools, gLiveView and topologyUpdater scripts.

Just beware, that using this option may mean you test against a branch that may have breaking changes. Always take extra care when using this option.
