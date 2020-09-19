!> We have temporarily disabled updating build documentation for Cardano-GraphQL. The specific component does not follow the process/technology/language (requires npm, yarn) used by other components (cabal/stack), and the value provided by `cardano-graphql` over the (haskell-based) hasura instance has been negligible. Also, an average pool operator may not require cardano-graphql at all, please verify if it is required for your use as mentioned [here](build.md#components). The instructions below are `out of date`.

> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

#### Build Hasura graphql-engine {docsify-ignore}

Going with the spirit of the documentation here, instruction to build the graphql-engine binary :)
``` bash
cd ~/git
git clone https://github.com/hasura/graphql-engine
cd graphql-engine/server
$CNODE_HOME/scripts/cabal-build-all.sh
```
This should make `graphql-engine` available at ~/.cabal/bin.

##### Build cardano-graphql

The build will fail if you are running a version of node.js earlier than 10.0.0 (which could happen if you have a conflicting version in your $PATH). You can verify your node version by executing the below:

```bash
#check your version of node.js
node -v
#if response is 10.0.0 or higher build can proceed. 
```

The commands below will help you compile the cardano-graphql node:
``` bash
cd ~/git
git clone https://github.com/input-output-hk/cardano-graphql
cd cardano-graphql
git checkout v1.1.1
yarn
#yarn install v1.22.4
# [1/4] Resolving packages...
# [2/4] Fetching packages...
# info fsevents@2.1.2: The platform "linux" is incompatible with this module.
# info "fsevents@2.1.2" is an optional dependency and failed compatibility check. Excluding it from installation.
# info fsevents@1.2.12: The platform "linux" is incompatible with this module.
# info "fsevents@1.2.12" is an optional dependency and failed compatibility check. Excluding it from installation.
# [3/4] Linking dependencies...
# warning " > graphql-type-datetime@0.2.4" has incorrect peer dependency "graphql@^0.13.2".
# warning " > @typescript-eslint/eslint-plugin@1.13.0" has incorrect peer dependency "eslint@^5.0.0".
# warning " > @typescript-eslint/parser@1.13.0" has incorrect peer dependency "eslint@^5.0.0".
# [4/4] Building fresh packages...
# Done in 20.70s.
yarn build
# yarn run v1.22.4
# $ yarn codegen:internal && yarn codegen:external && tsc -p . && shx cp src/schema.graphql dist/
# $ graphql-codegen
#   ✔ Parse configuration
#   ✔ Generate outputs
# $ graphql-codegen --config ./codegen.external.yml
#   ✔ Parse configuration
#   ✔ Generate outputs
# Done in 38.11s.
cd dist
rsync -arvh ../node_modules ./
```

##### Set up environment for cardano-graphql

cardano-graphql requires cardano-node, cardano-db-sync-extended, postgresql and graphql-engine to be set up and running.
The below will help you map the components:
``` bash
export PGPASSFILE=$CNODE_HOME/priv/.pgpass
IFS=':' read -r -a PGPASS <<< $(cat $PGPASSFILE)
export HASURA_GRAPHQL_ENABLE_TELEMETRY=false  # Optional.  To send usage data to Hasura, set to true.
export HASURA_GRAPHQL_DATABASE_URL=postgres://${PGPASS[3]}:${PGPASS[4]}@${PGPASS[0]}:${PGPASS[1]}/${PGPASS[2]}
export HASURA_GRAPHQL_ENABLE_CONSOLE=true
export HASURA_GRAPHQL_ENABLED_LOG_TYPES="startup, http-log, webhook-log, websocket-log, query-log"
export HASURA_GRAPHQL_SERVER_PORT=4080
export HASURA_GRAPHQL_SERVER_HOST=0.0.0.0
export CACHE_ENABLED=true
export HASURA_URI=http://127.0.0.1:4080
cd ~/git/cardano-graphql/dist
graphql-engine serve &
node index.js
```
