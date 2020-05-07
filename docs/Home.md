### Welcome!!

This documentation (rather the repository itself) is created by some of the community members and serves as an easy means to add documentation or scripts that makes more sense to users. The target audience for this document are mainly experienced stake pool operators.

The repository is already open to collaboration from many members within community. We would love community contributions and verification of the instructions, rather than having 100 versions of documentations. If there are any discrepancies/suggestions/contributions for this document, please open a issue and one of the collaborators should be able to add the changes in.

#### Getting started with Haskell Node

Use the sidebar to navigate through the topics. Note that the instructions assume the folder structure as per Next topic, you're expected to update the folder reference as per your environment.
Also, since you cannot run a Praos node yet, the instructions here-in allow you to join a private haskell testnet network (phtn), we will gradually update to Praos version and update the phtn references.

*Note that current version of documentation connects you to cardano-node, which is stable for using permissive oBFT consensus - the shelley (Praos) codebase is not yet in a state where we can run a network from it. While we would like to onboard new features as they're built for Shelley codebase (e.g. hybrid of oBFT nodes run by bootstrap entities and Praos nodes by stakepool operators), it is best to set your expectation accordingly. In the current state, this serves as a useful means to get familiar with modular architecture and usage.*
