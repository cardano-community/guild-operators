### GraphQL

Ensure the [Pre-Requisites](Common.md#dependencies-and-folder-structure-setup) are in place before you proceed.

#### Build Hasura graphql-engine

Going with the spirit of the documentation here, instruction to build the graphql-engine binary :)
``` bash
cd ~/git
git clone https://github.com/hasura/graphql-engine
cd graphql-engine/server
$CNODE_HOME/scripts/cabal-build-all.sh
```
This should make `graphql-engine` available at ~/.cabal/bin.

#### Build cardano-graphql

The command below will help you compile the cardano-graphql node:
``` bash
git clone https://github.com/input-output-hk/cardano-graphql
cd cardano-graphql
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

#### Set up environment for cardano-graphql

cardano-graphql requires cardano-node, cardano-db-sync-extended, postgresql and graphql-engine to be set up and running.
The below will help you map the components:
``` bash
export PGPASSFILE=$CNODE_HOME/priv/.pgpass
IFS=':' read -r -a PGPASS <<< $(cat $PGPASSFILE)
PG_HOST="${PGPASS[0]}"
PG_PORT="${PGPASS[1]}"
PG_DB="${PGPASS[2]}"
PG_USER="${PGPASS[3]}"
PG_PWD="${PGPASS[4]}"
export HASURA_GRAPHQL_DATABASE_URL=postgres://$PG_USER:$PG_PWD@$PG_HOST:$PG_PORT/$PG_DB
export HASURA_GRAPHQL_ENABLE_CONSOLE=true
export HASURA_GRAPHQL_ENABLED_LOG_TYPES="startup, http-log, webhook-log, websocket-log, query-log"
export HASURA_GRAPHQL_SERVER_PORT=4080
export HASURA_GRAPHQL_SERVER_HOST=0.0.0.0
export CACHE_ENABLED=true
export HASURA_URI=http://127.0.0.1:4080/v1/graphql
cd ~/git/cardano-graphql/dist
graphql-engine serve &
node index.js
```
