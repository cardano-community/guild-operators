---
hide:
  - toc
---

# GRest Meeting summaries

Thank you all for joining and contributing to the project :smile:

Below you can find a short summary of every GRest meeting held, both for logging purposes and for those who were not able to attend.

### Participants:

| Participant | 12Aug2021        | 29Jul2021        | 22Jul2021        | 15Jul2021        | 09Jul2021        | 02Jul2021        | 25Jun2021        |
| ----------- | ---------------- | ---------------- | ---------------- | ---------------- | ---------------- | ---------------- | ---------------- |
| Damjan      | :material-check: | :material-check: | :material-check: | :material-check: | :material-check: | :material-check: | :material-check: |
| Homer       | :material-check: | :material-check: | :material-check: | :material-check: | :material-check: | :material-check: | :material-check: |
| Markus      | :material-close: | :material-check: | :material-check: | :material-close: | :material-close: | :material-check: | :material-check: |
| Ola         | :material-close: | :material-check: | :material-check: | :material-check: | :material-check: | :material-check: | :material-check: |
| RdLrT       | :material-check: | :material-check: | :material-check: | :material-check: | :material-check: | :material-check: | :material-check: |
| Red         | :material-close: | :material-check: | :material-check: | :material-close: | :material-check: | :material-close: | :material-close: |
| Papacarp    | :material-close: | :material-close: | :material-close: | :material-close: | :material-close: | :material-close: | :material-close: |
| Paddy       | :material-close: | :material-close: | :material-close: | :material-check: | :material-close: | :material-close: | :material-close: |
| GimbaLabs   | :material-check: | :material-check: | :material-close: | :material-close: | :material-close: | :material-close: | :material-close: |

=== "12Aug2021"

    ### PROBLEMS

      - stake distribution query needs to be completed
      - it's hard to use docker to replicate our current setup

    ### ACTIONS

      - additional things to add to stake_distribution query
      - Add logic to record and check tx based on block.id for last but 3rd block in existing query
      - Add a control table in grest schema to record block_hash used for last update, start time, and end time. This will act as a checkpoint for polling of queries that are not live (separate backend in haproxy)
      - create a trigger every 2 minutes (or similar) to run stake_distribution query

    - docker:
      - problems with performance due to nature of IOPs and throughput usage for resources being isolated and can only access each other through sockets.
      - still useful to test whether fully dockerized (each component isolated) can keep up to chain tip
      - consider dockerizing all resources in one container to give new joiners a simple one liner to get up and running - this still doesn't ensure optimal performance, Tuning will still be an additional task for any infrastructure to customise setup to best results achievable

=== "29Jul2021"

    ### PROBLEMS

      - Not everyone reporting to the monitoring dashboard
      - We don't fully understand the execution time deviations of the stake distribution query
      - catalyst rewards are hard to isolate
      - branch 10.1.x has been deleted on the db-sync repo
      - people have a hard time catching up with the project after being away for a while

    ### ACTIONS

      - missing instances start reporting to monitoring
      - run stake_distribution query on multiple instances, report output of `EXPLAIN (ANALYZE, BUFFERS)`
      - catalyst rewards can be ignored until there is a clear path to get them: Fix underway using open PR
      - if someone needs help getting the right db-sync commit, message Priyank for help as the branch is now deleted
      - add project metadata (requirements) to pgrest doc header in a checklist format that folks can use to ensure their setup is up-to-date with the current project state
      - Discussed long-term plans (will be added separately in group)

=== "22Jul2021"

    ### PROBLEMS

    - how to sync live stake between instances (or is there need for it?)

    ### ACTIONS

    1. Team

        - catch live stake distributions in a separate table (in our `grest` schema)
            - these queries can run on a schedule
            - response comes from the instance with the latest data
        - other approaches:
            - possibly distribute pools between instances (complex approach)
            - run full query once and only check for new/leaving delegators (probably impossible because of existing delegator UTXO movements)
        - implement monitoring of execution times for all the queries
        - come up with a timeline for launch (next call)
        - stress test before launch
        - start building queries listed on Trello board

    2. Individual

        - sync db-sync instances to commit `84226d33eed66be8e61d50b7e1dacebdc095cee9` on `release/10.1.x`
        - update setups to reflect recent directory restructuring and [updated instructions](Build/pgrest.md)

=== "15Jul2021"

    ### Introduction for new joiner - Paddy

    - from Shamrock stake pool / [poolpeek](https://poolpeek.com/)
    - gRest project could be helpful for pool peek
    - Paddy will probably run an individual instance

    ### Problems

    - there is a problem with extremely high CPU usage haproxy, tuning underway.
    - live stake query has multiple variations, and we need to figure out what is the correct one.

    ### Action Items

    - Everyone should add monitoring to their instances
    - restructure RPC query files (separate metadata in `<query>.json` and sql in `<query>.sql`), also remove `get_` prefix
    - Add new queries from the list
    - fix haproxy CPU usage (use `nbthreads` in config, tune maxconn, switch to http mode)
    - gather multiple variations of the live stake query and ask Erik for clarification on which one is correct
    - Start working on other queries listed on trello

=== "09Jul2021"

    ### Deployment scripts

    Ola added automatic deployment of services to the scripts last week. We added new tasks on [Trello ticket](https://trello.com/c/euQDYUce/20-enhancements-to-setup-script), including flags for multiple networks (guild, testnet, mainnet), haproxy service dynamically creating hosts and doc updates. Overall, the script works well with some manual interaction still required at the moment.

    ### Supported Networks

    Just for the record here, a 16GB (or even 8GB) instance is enough to support both testnet and guild networks.

    ### db-sync versioning

    We agreed to use the `release/10.1.x` branch which is not yet released but built to include Alonzo migrations to avoid rework later. This version does require Alonzo config and hash to be in the node's `config.json`. This has to be done manually and the files are available [here](https://hydra.iohk.io/job/Cardano/cardano-node/cardano-deployment/latest-finished/download/1/index.html). Once fully released, all members should rebuild the released version to ensure each instance is running the same code.

    ### DNS naming

    For the [DNS setup ticket](https://trello.com/c/imnlrIaz/1-create-agent-config-file-for-haproxy-come-to-an-agreement-regarding-how-to-handle-dns-and-set-it-up), we started to think about the instance names for the 2 DNS instances (orange in the graph). Submissions for names will be made in the Telegram group, and will probably make a poll once we have the entries finalised.

    ### Monitoring System

    Priyank started setting up the monitoring on his instance which can then easily be switched to a separate monitoring instance. We agreed to use Prometheus / Grafana combo for data source / visualisation. We'll probably need to create some custom archiving of data to keep it long term as Prometheus stores only the last 30 days of data.

    ### Next meeting

    We would like to make Friday @ 07:00 UTC the standard time and keep meetings at weekly frequency. A poll will still be created for next weeks, but if there are no objections / requests for switching the time around (which we have not had so far) we can go ahead with the making Friday the standard with polls no longer required and only reminders / Google invites sent every week.

=== "02Jul2021"

    After the initial stand-up updates from participants, we went through the entire Trello board, updating/deleting existing tickets and creating some new ones.

    ### Deployment scripts

    During the last week, work has been done on deployment scripts for all services (db-sync, pgREST and haproxy) -> this is now in testing with updated instructions on [trello](https://trello.com/c/1GS8VpNP/2-add-haproxy-config-to-setup). Everybody can put their name down on the ticket to signify when the setup is complete and note down any comments for bugs/improvements. This is the main priority at the moment as it would allow us to start transferring our setups to mainnet.

    ### Switch to Mainnet

    Following on from that, we created a ticket for starting to set up mainnet instances -> we can use 32GB RAM to start and increase later. While making sure everything works against the guild network is priority, people are free to start on this as well as we anticipate we are almost ready for the switch.

    ### Supported Networks
    This brings me to another discussion point which is on which networks are to be supported. After some discussion, it was agreed to keep beefy servers for mainnet, and have small independent instances for testnet maintained by those interested, while guild instance is pretty lightweight and useful to keep.

    ### Monitoring System

    The ticket for creating a centralised monitoring system was discussed and updated. I would say it would be good to have at least a basic version of the system in place around the time we switch to mainnet. The system could eventually serve for:
     - analysis of instance
     - performances and subsequent tuning
     - endpoints usage
     - anticipation of system requirements increases
     - etc.

    I would say that this should be an important topic of the next meeting to come up with an approach on how we will structure this system so that we can start building it in time for mainnet switch.

    ### Handling SSL

    Enabling SSL was agreed to not be required by each instance, but is optional and documentation should be created for how to automate the process of renewing SSL certificates for those wishing to add it to their instance. The end user facing endpoints "Instance Checker" will of course be SSL-enabled.

    ### Next meeting

    We somewhat agreed to another meeting next week again at the same time, but some participants aren't 100% for availability. Friday at 07:00 UTC might be a good standard time we hold on to, but I will make a poll like last time so that we can get more info before confirming the meeting.

=== "25Jun2021"

    ### Meeting Structure
    As this was the first meeting, at the start we discussed about the meeting structure. In general, we agreed to something like listed below, but this can definitely change in the future:

    1) 2-liner (60s) round the table stand-ups by everyone to sync up on what they were doing / are planning to do / mention struggles etc. This itself often sparks discussions.
    2) going through the Trello board tasks with the intention of discussing and possbily assigning them to individuals / smaller groups (maybe 1-2-3 people choose to work together on a single task)

    ### Stand-ups
    We then proceeded to give a status of where we are individually in terms of what's been done, a summary below:

    - Homer, Ola, Markus, Priyank and Damjan have all set up their dbsync + pgrest endpoints against guild network and added to topology.
    - Ola laid down the groundwork for CNTools to integrate with API endpoints created so far.
    - Markus has created the systemd scripts and will add them soon to repo
    - Damjan is tracking live stake query that includes payment + stake address, but is awaiting fix on dbsync for pool refund (contextual reserves -> account) , also need to validate reserve -> MIR certs
    - Priyank created initial haproxy settings for polls done, need to complete agent based on design finalisation

    ### Main discussion points

    1. Directory structure on the repo -> General agreement is to have anything related to db-sync/postgREST separated from the current cnode-helper-scripts directory. We can finalise the end locations of files a bit later, for now intent should be to simply add them all to /files/dbsync folder. `prereqs.sh` addendum can be done once artifacts are finalised (added a Trello ticket for tracking).
    2. DNS/haproxy configurations:
      We have two options:
      a. controlled approach for endpoints - wherein there is a layer of haproxy that will load balance and ensure tip being in sync for individual providers (individuals can provide haproxy OR pgrest instances).
      b. completely decentralised - each client to maintain haproxy endpoint, and fails over to other node if its not up to recent tip.
      I think that in general, it was agreed to use a hybrid approach. Details are captured in diagram [here](https://t.me/c/1499031483/335). DNS endpoint can be reserved post initial testing of haproxy-agent against mainnet nodes.
    3. Internal monitoring system
      This would be important and useful and has not been mentioned before this meeting (as far as I know). Basically, a system for monitoring all of our instances together and also handling alerts. Not only for ensuring good quality of service, but also for logging and inspection of short- and long-term trends to better understand what's happening. A ticket is added to trello board

    ### Next meeting

    All in all, I think we saw that there is need for these meetings as there are a lot of things to discuss and new ideas come up (like the monitoring system). We went for over an hour (~1h15min) and still didn't have enough time to go through the board, we basically only touched the DNS/haproxy part of the board. This tells me that we are in a stage where more frequent meetings are required, weekly instead of biweekly, as we are in the initial stage and it's important to build things right from the start rather than having to refactor later on. With that, the participants in general agreed to another meeting next week, but this will be confirmed in the TG chat and the times can be discussed then.
