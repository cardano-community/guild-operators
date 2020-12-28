!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

`logMonitor.sh` is a general purpose json log monitoring script for traces created by cardano-node. Currently it will look for traces related to leader slots and block creation but other uses could be added in the future. 

##### Block traces
For the core node (block producer) the `logMonitor.sh` script can be run to monitor the json log file created by cardano-node for traces related to leader slots and block creation.   

For optimal coverage, it's best run together with [CNCLI](Scripts/cncli.md) scripts as they provide different functionality. Together they create a complete picture of blocks assigned, created, validated or invalid due to node issue. 

##### Installation
The script is best run as a background process. This can be accomplished in many ways but the preferred method is to run it as a systemd service. A terminal multiplexer like tmux or screen could also be used but not covered here.

Use the `deploy-as-systemd.sh` script to create a systemd unit file (deployed together with [CNCLI](Scripts/cncli.md)).
Log output is handled by syslog and end up in the systems standard syslog file, normally `/var/log/syslog`. `journalctl -f -u cnode-logmonitor.service` can be used to check service output(follow mode). Other logging configurations are not covered here. 

##### View Blocklog
Best viewed in CNTools or gLiveView. See [CNCLI](Scripts/cncli.md) for example output.

#### Telegram alerts

If known but unwanted errors occur on your node, or if characteristic values indicate an unusual status , cntools can send you Telegram alert messages. 

To do this, you first have to activate your own bot and link it to your own Telegram user. Here is an explanation of how this works:

1. Open Telegram and search for "*botfather*"

2. write him your wish: `/newbot`

3. define a name for your bot, such as `cntools_[POOLNAME]_alerts`

4. Botfather will confirm the creation of your bot by giving you the unique **bot access token**. Keep it save and private.

5. Now send at least one direct message to your new bot.

6. now open this URL in your browser by using your own, just created bot access token

   ```
   https://api.telegram.org/bot<your-access-token>/getUpdates
   ```

7. the result is JSON. Look for the value of `result.message.chat.id`. 
   This **chat id** should be a large integer number.

Congratulations. This is all you need to enable your Telegram alerts in the `scripts/env` file.