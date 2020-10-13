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

!> Remember that same as before, you're running these as non root user with passwordless sudo access for the session.

- Download the latest prereqs.sh (tip: do checkout new features in `prereqs.sh -h`) to update all the scripts and files from the guild template. Most of the files modified with user content (env, gLiveView.sh, topologyUpdater.sh, cnode.sh, etc) will be backed up before overwriting. More static files (genesis files or some of the scripts themselves) will not be backed up, as they're not expected to be modified.

``` bash
mkdir "$HOME/tmp";cd "$HOME/tmp"
curl -sS -o prereqs.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/prereqs.sh
chmod 700 prereqs.sh
./prereqs.sh -f
```

- Check and add back your customisations.
Below is a list of files that you will typically customise - depending on scripts that you use:  
|Script|env |Self|Others|
|:-----|:--:|:--:|-----:|
|gLiveView.sh|:heavy_check_mark:|:eyes:|:x:|
|CNTools|:heavy_check_mark:|:x:|*cntools.config*|
|topologyUpdater.sh|:heavy_check_mark:|:heavy_check_mark:|:x:|
|cnode.sh|:heavy_check_mark:|:heavy_check_mark:|:x:|
|topology.json|:x:|:heavy_check_mark:|:x:|

!> The way user content is retained during future upgrades is all the user customisations are to be retained above the line stating `DO NOT MODIFY`, anything after that line will be overwritten with the latest code from github.


#### Advanced Users/Testers only

For folks who would like to try out an unreleased feature by using a specific branch (`alpha` for example), you can now do so. While setting up your repository, use `prereqs.sh -b alpha` where alpha is the name of the branch.
The `-b branch` argument is also extended to cntools, gLiveView and topologyUpdater scripts.

Just beware, that using this option may mean you test against a branch that may have breaking changes. Always take extra care when using this option.
