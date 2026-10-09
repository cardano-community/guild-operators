# CNTools common tasks

This guide follows the menus in CNTools. For startup modes, settings and saved
file locations, see the [overview](cntools.md).

Before changing keys or creating transactions, verify the network in the
header and keep an independent backup. Read every confirmation: cancelling a
transaction does not undo separate key generation or operational-certificate
issuance that you already approved.

## Wallets

### Create a CLI wallet

Open **Wallet → New → CLI**, enter a name and confirm the reviewed location.
Names can contain letters, numbers, periods, underscores and hyphens, must
start with a letter or number, and can be at most 64 characters.

CNTools creates payment and stake keys with their addresses. Existing folders
are not replaced. No node connection is needed. Back up the signing-key files:
a randomly generated CLI wallet has no recovery phrase.

### Create or import a mnemonic wallet

Use **Wallet → New → Mnemonic** to create a 24-word recovery phrase.
CNTools displays a copyable line and a numbered table. Record the words in
order, confirm that you have saved them, then answer four randomly selected
word checks after the phrase is cleared from the display.

Use **Wallet → Import → Mnemonic** for an existing software-wallet phrase.
Paste the words separated by spaces or enter them one at a time using the
English word suggestions. Supported lengths are 12, 15, 18, 21 and 24 words.

Account number and address key index default to **0** when you press Enter.
Choose the original values when restoring a wallet. These actions create
standard payment and stake keys; multisig and DRep setup have separate menus.
The recorded derivation path is shown in Wallet Show.

Keep your phrase and derivation choices securely outside the deployment.
Do not use a recorded/shared terminal for secret input. Clearing the display
is not a guarantee that terminal recording or scrollback has been erased.

### Import a hardware wallet

Open **Wallet → Import → HW Wallet** with the supported device connected,
unlocked and ready for its Cardano application. Review the account and key
index, both defaulting to **0**, and follow the device prompts.

CNTools saves public keys, addresses and hardware signing references.
Private keys stay on the device. Hardware signing needs that device connected
to the signing system; use an offline transaction package when your node is
on a remote server. Never enter a hardware recovery phrase into CNTools.

### Inspect wallets, history and UTxOs

**Wallet → List** shows each wallet's type, key protection and primary address.
Choose whether to fetch live balances. Without that lookup, the list opens
quickly and omits balance rows. With it, applicable base/payment balances,
stake rewards, total balance and native-asset counts are shown.

**Wallet → Show** presents addresses, credentials, registration, stake-pool
and DRep delegation, balances and available native assets. Choose **Simple**,
**Detailed** or **Skip** for asset output. Detailed includes available metadata;
the display identifies its source. Koios metadata is optional even when your
balances come from the local node. An unused wallet shows zero balances;
unavailable data is not presented as a confirmed zero.

**Wallet → Transaction List** requires Koios. **Wallet → UTxO List** prefers
Koios and can fall back to a simpler local-node view. After selecting a wallet,
choose payment-credential or stake-address lookup when both are available.
Payment lookup includes base and payment-only addresses sharing that credential.
Stake lookup includes stake-linked addresses, but not payment-only addresses.

Choose 1–10 results per page; Enter uses **5**. Next and Previous appear where
applicable. Open Details using the item number; transaction details also accept
a transaction ID. Press **q** to return from the detail view. Asset metadata
is optional and adds readable names and decimal amounts.

UTxO List shows unspent outputs only. Its summaries include ADA, asset counts
and asset names; details show individual asset information beneath each output.
Koios results warn when the returned count reaches its 1,000-result limit.
Reopen the action to refresh the snapshot. The local fallback covers the
wallet's known funding addresses and cannot discover every stake-linked
address or provide Koios history.

### Protect or unlock wallet keys

**Wallet → Encrypt** protects signing keys with GPG encryption and read-only
file permissions. New passphrases require at least 12 characters and a matching
confirmation. Optional immutable locking follows `ENABLE_CHATTR` in `env`;
when unavailable, read-only protection is retained with a warning.

**Wallet → Decrypt** unlocks keys using their existing passphrase. It accepts
shorter passphrases as well. A wrong passphrase or invalid file does not replace
the protected keys. Inspection never decrypts keys automatically.

Keep the passphrase separately from the backup. Encryption is not a backup.

### Register or de-register a stake address

**Wallet → Register** checks registration status and builds a transaction using
the current stake deposit. Review the deposit, fee and return address, then
choose the shared live, sign-only or offline-signing workflow.

**Wallet → De-Register** requires zero claimable rewards. Withdraw rewards
first if needed. The transaction refunds the deposit recorded for that stake
credential and ends its delegation. Rewards earned but not yet credited are
forfeited, even if the visible reward balance is zero.

### Remove a wallet

**Wallet → Remove** checks available funds, stake registration and DRep
registration, and shows any warnings or unavailable checks before confirmation.
You can explicitly proceed despite warnings, but must have an independent
recovery backup.

Removal deletes local wallet files. It does not send funds, withdraw rewards
or unregister anything on-chain. Do not remove the only copy of keys that
control funds or registered credentials.

## Funds

### Send ADA and native assets

Open **Funds → Send** and choose the source wallet. For each recipient choose:

- **CNTools wallet** — select a known wallet and its available receiving address.
- **External address** — enter and review the address. Testnet addresses do not
  identify a specific testnet; independently confirm the recipient's network.
- **ADA Handle** — enter `$name` or `$child@parent` for resolution through Koios.

Handle resolution supports standard Handles, NFT subhandles and virtual
subhandles on configured supported networks. Review the resolved address,
type and any lease/revocation warning. Virtual subhandles can be reassigned;
CNTools rechecks the destination during the live flow rather than silently
redirecting a transfer.

Choose **Exact amounts**, **Max ADA** or **Send everything** as offered.
Exact mode supports multiple recipients. ADA amounts allow six decimal places;
entering zero requests the required minimum ADA for the output. Native-asset
quantities use the smallest units specified by the prompt.

Add, edit or remove recipients before continuing. Cancel an edit or addition
to return to the recipient list without losing the existing draft. The source
uses eligible funds across its base and payment addresses; rewards and deposits
are not included. Change goes to its primary address unless the optional
change-address choice is enabled in Settings.

Review every address and amount, minimum-ADA adjustments, fee, metadata and
applied change settings. The shared review offers signing/submission,
sign-only or unsigned export.

### Add a message or custom metadata

Use **Message / metadata** in the send flow to add a multi-line CIP-20 message,
optionally encrypted using CIP-83. Start with `-a` to import custom metadata
from a JSON file. Review the metadata type, label and content before signing.

Metadata becomes permanent on-chain. Message encryption hides only the message,
not addresses, amounts or unrelated metadata. Protect the chosen decryption
information. Custom metadata and messages cannot independently own the same
label; the editor explains conflicts.

### Delegate stake

**Funds → Delegate** selects a registered pool as the wallet's delegation
target. If the stake address is not registered, you can explicitly include
registration and its deposit in the same transaction.

Review the pool, any deposit and fee. Delegation does not transfer the wallet's
ADA to the pool or withdraw rewards. Voting/DRep delegation is separate and
must be set where required before reward withdrawal.

### Withdraw rewards

**Funds → Withdraw Rewards** returns claimable rewards to the wallet while
leaving registration and delegations unchanged. Current rewards and at least
one eligible funding UTxO are needed.

Where the protocol requires it, set voting delegation first through
**Vote → Governance → Delegate**, including a predefined abstention option
if appropriate. The withdrawal flow does not add voting delegation implicitly.

Review rewards, fee and net benefit. If rewards or inputs change while a package
is being signed elsewhere, rebuild rather than reuse stale withdrawal data.

### Collect UTxOs

**Funds → Collect UTxOs** returns eligible funds to the same wallet, less the
fee. Choose **ADA-only UTxOs** or **ADA and native assets**. Outputs carrying
datums or reference scripts are left untouched.

Your change settings still apply. Fragmentation or ADA-only management may
create several outputs, so collection can reshape funds rather than reduce the
output count. Review the resulting outputs before signing. Rewards, deposits
and delegation are unchanged.

## Signing and submission

### Sign a transaction offline

1. On an online system, create and review the transaction, then choose
   **Create unsigned package**. Record the saved path.
2. Transfer that package, not private keys, to the signing system.
3. Start `./cntools.sh -o`, open **Transaction → Sign**, and select the package.
4. Review its actual effects and required signers. Supply the matching CLI or
   hardware sources and save the resulting package.
5. Return the completed package to an online system and use
   **Transaction → Submit**.

Multisig participants can sign in separate sessions. Continue with the newest
saved package until every selected signer has contributed. Partial packages
cannot be submitted. Reference-script transactions need the displayed
independent verification because an offline package cannot prove the current
referenced output.

Expiry still applies while transferring and signing packages. **No expiry**
does not remove script time limits or prevent inputs from being spent elsewhere.
Changing a transaction requires rebuilding and collecting new signatures.

### Submit or monitor a transaction

**Transaction → Submit** accepts a completed CNTools package or a supported
external signed Cardano transaction. Review the effects, network and named
submission backend before confirming. External transactions cannot always
prove signer completeness in the interface; the ledger makes the final decision.

The result shows status, transaction ID and any saved recovery path.
If Koios is available, choose whether to monitor block inclusion.
An accepted submission or delayed indexer response is not proof of finality;
check the same transaction ID before attempting a replacement.

## Stake pools

### Create, import and inspect a pool

**Pool → New** creates a local pool identity and operational keys.
**Pool → Import** imports existing pool material without replacing a named
pool already present. Back up cold signing keys securely and keep them off
the online block producer when possible.

**Pool → List / Show** displays local identity, registration and available
chain information, including reward/owner settings and operational-key health
where supported. Unavailable data is identified rather than treated as zero.

**Pool → Encrypt / Decrypt** protects or unlocks cold and applicable Calidus
signing keys. Operational KES/VRF files needed by the running node are not a
substitute for cold-key recovery backups.

### Register or modify a pool

**Pool → Register / Modify** guides pool and funding-wallet selection, pledge,
cost, margin, reward account, owners, relays and optional metadata.

Metadata can be created/edited locally, selected from a file, downloaded for
review, or supplied as a published URL and hash. Publish it yourself and ensure
the published bytes match the reviewed file. Saved local settings are drafts,
not evidence of an on-chain update.

Review owner/reward registration and delegation guidance and any pledge
shortfall. Pledge is a commitment to maintain, not an amount paid to register
the pool. Initial registration charges the current pool deposit; modification
does not charge another pool deposit. Updating a retiring pool can cancel its
scheduled retirement.

The funding payment key, pool cold key and all owner stake keys are required.
Missing local signing sources use the offline package route. Hardware approval
depends on the companion/device's pool-signing rules; follow the displayed
session and funding-source requirements.

Where offered, initial registration can include explicitly approved owner or
reward-account setup and prepare a missing operational certificate. Certificate
issuance is a separate side effect: it advances the issue counter even if you
later cancel the transaction. Follow the final guidance for `POOL_NAME`,
operational files and pledge maintenance; CNTools does not edit `env` for you.

### Rotate KES keys

**Pool → Rotate** prepares replacement KES keys and an operational certificate.
It does not restart the node. Verify the pool, issue counter and start period;
if chain data is unavailable, independently confirm the requested values.

Stop the block producer before approving installation. Keep it stopped if
installation is interrupted, and continue the recorded recovery operation
rather than issuing another certificate. Restart the node yourself afterwards
and verify its health.

For offline cold-key signing:

1. Prepare replacement keys and choose **Prepare offline hand-off** on the node.
2. Copy only the reported public request directory to the signing system.
   Never transfer the new KES private key or the parent recovery directory.
3. Use **Pool → Rotate → Sign an offline request** there with the independently
   held cold key and current issue counter.
4. Return only the reported certificate and advanced counter, import the
   response on the node, then approve installation while the producer is stopped.

A used issue counter is never rolled back. Keep recovery copies securely;
never restore an older counter to make an old certificate usable.

### Retire a pool

**Pool → Retire** selects a registered pool, funding wallet and permitted future
epoch. Enter defaults to the next epoch. The review identifies any existing
scheduled retirement that will be replaced.

Only the fee is spent by this transaction. The pool deposit is returned to its
registered reward account when retirement takes effect, not when the retirement
transaction is submitted. Keep that reward stake account registered.

### Manage Calidus credentials

**Pool → Calidus** creates/imports a Calidus identity, repairs missing public
files and shows local or Koios-indexed status. Use its separate authorization
and registration options to register, replace or revoke the on-chain key.

Registration needs pool cold-key authorization and current Koios information,
even in local mode. Public authorization metadata can be prepared on an offline
cold-key system and transferred without private keys. Hardware transaction
signatures do not replace the required cold-key metadata authorization.

An empty indexed result is not proof that a recent submission never occurred.
Check previous transaction IDs before creating another authorization.

## Governance and Catalyst

### Manage a DRep or voting delegation

**Vote → Governance → Derive Keys** creates random CLI DRep keys or derives
them from a software recovery phrase. Back up their own keys or phrase/account:
they need not use the same recovery information as the payment wallet.

**Info & Status** shows identity, key availability and available registration
information. **DRep Registration / Update** registers a new identity or updates
an existing one, with optional published metadata. CNTools can hash a local
document but does not upload it. Registration charges the current DRep deposit;
updates charge the fee, and **DRep Retire** refunds the recorded deposit.

**Delegate** assigns voting power to a DRep, **Always Abstain** or
**Always No Confidence**. It can include explicitly approved first stake
registration. Registering your own DRep does not automatically delegate your
stake to it. Pool delegation remains separate.

### Browse proposals and vote

**Vote → Governance → List Proposals** browses active proposals with pagination,
details and vote information. Recorded vote counts are not a prediction of
ratification. Metadata from an indexer is not independently verified by CNTools.

**Cast vote** uses a registered key or script DRep identity. Select the proposal,
choose **Yes**, **No** or **Abstain**, and optionally attach a published rationale
URL/hash. Replacing an existing vote needs explicit confirmation.

This action casts DRep votes, not committee or pool votes. Review the exact
proposal and decision before using the shared transaction flow.

### Register and use Catalyst voting

**Vote → Catalyst → Registration** creates or reuses a separate voting identity
and prepares registration with stake-key authorization. Keep the voting key:
it is not recovered from the payment-wallet mnemonic. Offline authorization
can be transferred for an online registration transaction.

**Display QR** creates a private voting QR with a four-digit PIN for the voting
app. Keep both private. The voting key must be unlocked for QR creation.
Catalyst Toolbox is required; its PIN can briefly be visible to processes
running as the same user.

**Verify** checks mainnet fund-snapshot registration and voting power using the
Catalyst API. Optional delegator details include known local wallets, reward
addresses and individual power. Snapshot eligibility differs from recent
transaction inclusion. Check the current fund's dates and voting requirements
separately; testnet registration does not grant mainnet voting eligibility.

## Advanced actions

Start CNTools with `-a` to show these menus.

### Multisig wallets and DReps

**Advanced → MultiSig → Derive Keys** adds separate participant keys using a
software recovery phrase, fresh CLI keys or a supported hardware device.
Custom derivation paths are available. Existing wallet keys are not replaced.

**Create** selects local or external participants, the signing threshold and
optional payment time bounds to create a script wallet. Back up the scripts
and participant recovery information. Participants, threshold and time bounds
determine the address and cannot be changed for that address.
An expiry can permanently lock remaining funds.

Use **Vote → Governance → MultiSig DRep** for a separate threshold DRep
identity. Transaction actions choose payment, stake and DRep signing subsets
as applicable. Public-only participants can sign packages elsewhere.

### Native assets

**Advanced → Asset → Create Policy** creates a single-signer native minting
policy. Choose an optional expiry and back up its signing key. Expiry prevents
both minting and burning after that time; no expiry leaves the key authorized.

**List Assets / Show Asset** inspect local policies and asset records, with
optional Koios supply/metadata. Local records do not prove inclusion or
current supply. **Encrypt / Lock Policy** and **Decrypt / Unlock Policy**
protect or unlock policy signing keys.

**Mint Asset / Burn Asset** select the policy, asset name and funding wallet.
Text, hex and empty asset names are supported. Quantities are exact smallest
units; Burn can select all available units. Unrelated assets are preserved.
Review the fee, quantity and policy/transaction expiry through the shared flow.

**Register Asset** prepares a signed Token Registry metadata file using
`token-metadata-creator`. It does not submit a blockchain transaction or
publish the file. Follow the reported mainnet/testnet registry instructions
for manual submission. Registry metadata is separate from minting metadata.

### Clear metadata cache or remove private keys

**Clear asset cache** refreshes names and metadata on their next Koios lookup.

**Delete Private Keys** previews known keys from selected wallets, pools or
policies. You must acknowledge a verified independent backup and type the
required deletion phrase. Public artifacts and node operational keys remain.

This action does not move funds or unregister credentials. Deleted keys are
recoverable only from your separate backup, and file deletion does not guarantee
secure erasure from SSDs, snapshots or other backups.

## Backups and restoration

**Backup & Restore → Backup** offers full or public-only archives, with GPG
encryption recommended. Full backups include present wallet, pool and policy
files; public-only archives are not signing-key recovery backups.

New encrypted archives require a confirmed passphrase of at least 12 characters.
Restoring an encrypted archive accepts its existing passphrase, including
shorter ones.

Review the key-coverage warnings. An archive cannot recover missing keys,
hardware recovery seeds, or mnemonic words not stored in its source folders.
Keep recovery phrases and passphrases independently. Archive integrity checks
do not prove that every key you need is recoverable.

The default destination is `${NODE_HOME}/backups/`. Pause other wallet/pool
operations while creating a backup. Scripts, `env`, node configuration/database,
settings, logs, caches and transaction packages are not included; save those
separately as needed.

**Restore** previews the archive and conflicts before importing. Existing
folders are never merged or overwritten. CNTools retains a reported private
recovery copy; protect it because it can contain decrypted private keys.
Restore only trusted archives.

Restored files do not regain immutable locking automatically. Reapply
encryption/locking where appropriate. Do not start a pool with old operational
files or an older issue counter: verify current state and rotate KES safely.
Pending KES recovery material remains for manual recovery rather than being
activated automatically.

## Block production history

**Blocks → Summary / Epoch** reads the configured CNCLI blocklog database.
It shows available production results and epoch details without altering the
database or controlling the node. Set up the blocklog collector separately
using the [CNCLI guide](cncli.md).
