!> Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

This section describes the ways in which CNTools can send important messages to the operator.

#### Telegram alerts

If known but unwanted errors occur on your node, or if characteristic values indicate an unusual status , CNTools can send you Telegram alert messages. 

To do this, you first have to activate your own bot and link it to your own Telegram user. Here is an explanation of how this works:

1. Open Telegram and search for "*botfather*".

2. Write him your wish: `/newbot`.

3. Define a name for your bot, such as `cntools_[POOLNAME]_alerts`.

4. Botfather will confirm the creation of your bot by giving you the unique **bot access token**. Keep it safe and private.

5. Now send at least one direct message to your new bot.

6. Open this URL in your browser by using your own, just created bot access token:

   ```
   https://api.telegram.org/bot<your-access-token>/getUpdates
   ```

7. the result is a JSON. Look for the value of `result.message.chat.id`. 
   This **chat id** should be a large integer number.

This is all you need to enable your Telegram alerts in the `scripts/env` file - uncomment and add the chat ID to the `TG_CHAT_ID` user variable in the `env` file:
```
...
TG_CHAT_ID="<YOUR_TG_CHAT_ID>"
...  
```
