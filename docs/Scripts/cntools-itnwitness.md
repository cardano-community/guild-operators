# Extended Metadata Property

Due to the expected Ticker spoofing attack for pools that were famous during ITN, some of the community members have proposed an interim solution to verify the legitimacy of a pool for delegators.

### Disclaimer:
- We have not yet received a confirmation of whether this will be adopted by CF/IOHK/Emurgo, and as long as Daedalus/Yoroi does not use this information, it is not gonna be fully usable. But this is to be prepared in case the proposal goes through.
- This is not about awarding special recognition to ITN pools, but about preventing scammers from fooling delegators using the performance from ITN to attract wrong delegations. In future this information could be extended further to verify legitimacy of newer pools too - TBD.

### Steps:
The actual implementation is pretty straightforward, we will keep it brisk - as we assume ones participating are fairly familiar with `jcli` usage.
- You need to use your owner keys that was used to register your pool , and it should match the owner _public_ key you presented on [official cardano-foundation github](https://github.com/cardano-foundation/incentivized-testnet-stakepool-registry) while registering metadata.
- Store your pool ID in a file (eg: `mainnet_pool.id`)
- Sign the file using your owner secret key from ITN (eg: `owner_skey`) as per below:
``` bash
jcli key sign --secret-key owner_skey mainnet_pool.id --output mainnet_pool.sig
cat mainnet_pool.sig
# ed25519_sig1sn32v3zdvzhwdwq493nd3l8x7mvsm3anz4jzmhv7aefw32kvn3kgdvrla6s6qx8anyqmvnq2v0d7xeq2fu64549vurvpfuncr4d72rg7rc6gs
```
- Add this signature and owner _public_ key to the extended pool JSON , so that it looks like below:
``` json
{
  "itn": {
    "owner": "ed25519_pk1...",
    "witness": "ed25519_sig1..."
  }
}
```
- Host this signature file online at a URL with raw contents easily accessible on internet (eg: https://my.pool.com/extended-metadata.json)
- When you register/modify a pool using CNTools, use the above mentioned URL to add to your pool metadata.

If the process is approved to appear for wallets, we may consider providing easier alternatives. If any queries about the process, or any additions please create a git issue/PR against guild repository - to capture common queries and update instructions/help text where appropriate.
