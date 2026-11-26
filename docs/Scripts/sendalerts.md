!!! info "Reminder"
    Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place
    before you proceed.

This page configures the shared `telegramSend` function used by CNTools; there
is no separate `sendAlerts.sh` executable. CNTools is installed by cnode and
by the experimental Dingo testnet profile. Alert delivery is a shared CNTools
feature; it does not add support for Dingo features that remain cnode-only.

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

7. The result is JSON. Look for the value of `result[].message.chat.id`.
   This **chat id** should be a large integer number.

Enable alerts by setting both values in `${NODE_HOME}/scripts/env`:

```bash
TG_BOT_TOKEN="<YOUR_BOT_TOKEN>"
TG_CHAT_ID="<YOUR_TG_CHAT_ID>"
```

Keep the bot token secret. If either value is empty, `telegramSend` warns and
does not send a message.
