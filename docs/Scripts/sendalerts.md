!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

This section describes the ways in which cntools can send important messages to the operator.

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