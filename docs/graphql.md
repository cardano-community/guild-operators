### GraphQL

#### Pre-Requisites

Execute the below to set up yarn and dependencies
``` bash
curl --silent --location https://dl.yarnpkg.com/rpm/yarn.repo | sudo tee /etc/yum.repos.d/yarn.repo
sudo rpm --import https://dl.yarnpkg.com/rpm/pubkey.gpg
sudo yum -y install yarn python3 make gcc-c++
```

Going with the spirit of the documentation here, instruction to build the graphql-engine binary :)
``` bash
cd ~/git
git clone https://github.com/hasura/graphql-engine
cd graphql-engine/server
cabal build all
cp dist-newstyle/build/x86_64-linux/ghc-8.6.5/graphql-engine-1.0.0/x/graphql-engine/opt/build/graphql-engine/graphql-engine ~/.local/bin
```

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
# TODO: Improve and script the below
export CNODE_HOME=/opt/cardano/cnode
export PGPASSFILE=$CNODE_HOME/priv/.pgpass
PGPASS=$(cat $PGPASSFILE)
PG_HOST=$(echo $PGPASS | cut -d: -f 1)
PG_PORT=$(echo $PGPASS | cut -d: -f 2)
PG_DB=$(echo $PGPASS | cut -d: -f 3)
PG_USER=$(echo $PGPASS | cut -d: -f 4)
PG_PWD=$(echo $PGPASS | cut -d: -f 5)
export NETWORK=phtn
export EXTENDED=true
export HASURA_GRAPHQL_DATABASE_URL=postgres://$PG_USER:$PG_PWD@PG_HOST:$PG_PORT/$PG_DB)
export HASURA_GRAPHQL_ENABLE_CONSOLE=true
export HASURA_GRAPHQL_ENABLED_LOG_TYPES="startup, http-log, webhook-log, websocket-log, query-log"
export HASURA_GRAPHQL_SERVER_PORT=4080
export HASURA_GRAPHQL_SERVER_HOST=0.0.0.0
export CACHE_ENABLED=true
export HASURA_URI=http://127.0.0.1:4080/v1/graphql
cd -;cd ~/git/cardano-graphql/dist
graphql-engine serve
node index.js
```
