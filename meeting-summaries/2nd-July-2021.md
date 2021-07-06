# 2nd Meeting

Thank you all for joining and working on the project :)

I will try to provide a short summary of the 2nd guild pgREST meeting (held on 02/07/2021 - 07:00 UTC), both for logging purposes and for those who were not able to attend.

### Participants:

- Homer
- Ola
- Markus
- Priyank
- Damjan

After the initial stand-up updates from participants, we went through the entire Trello board, updating/deleting existing tickets and creating some new ones.

## Deployment scripts

During the last week, work has been done on deployment scripts for all services (db-sync, pgREST and haproxy) -> this is now in testing with updated instructions on https://trello.com/c/1GS8VpNP/2-add-haproxy-config-to-setup. Everybody can put their name down on the ticket to signify when the setup is complete and note down any comments for bugs/improvements. This is the main priority at the moment as it would allow us to start transferring our setups to mainnet.

## Switch to Mainnet

Following on from that, we created a ticket for starting to set up mainnet instances -> we can use 32GB RAM to start and increase later. While making sure everything works against the guild network is priority, people are free to start on this as well as we anticipate we are almost ready for the switch.

## Supported Networks
This brings me to another discussion point which is on which networks are to be supported. After some discussion, it was agreed to keep beefy servers for mainnet, and have small independent instances for testnet maintained by those interested, while guild instance is pretty lightweight and useful to keep.

## Monitoring System

The ticket for creating a centralised monitoring system was discussed and the ticket description updated. I would say it would be good to have at least a basic version of the system in place around the time we switch to mainnet. The system could eventually serve for:
 - analysis of instance
- performances and subsequent tuning
 - endpoints usage
 - anticipation of system requirements increases
 - etc.

I would say that this should be an important topic of the next meeting to come up with an approach on how we will structure this system so that we can start building it in time for mainnet switch.

## Handling SSL

Enabling SSL was agreed to not be required by each instance, but is optional and documentation should be created for how to automate the process of renewing SSL certificates for those wishing to add it to their instance. The end user facing endpoints "Instance Checker" will of course be SSL-enabled.

## Next meeting

We somewhat agreed to another meeting next week again at the same time, but some participants aren't 100% for availability. Friday at 07:00 UTC might be a good standard time we hold on to, but I will make a poll like last time so that we can get more info before confirming the meeting.