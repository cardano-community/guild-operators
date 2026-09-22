# Funds → Send plan

Status: initial Send plus optional message/custom metadata and Koios-resolved
Handle recipients implemented; live testing remains required.
Recipient choices and ADA Handle support reflect the discussion through
2026-09-06. The design below is retained as a roadmap, with the implemented
boundary and remaining options distinguished here.

## Extended Send implementation boundary

- Send review now offers optional Message / metadata, with plain CIP-20 and
  CIP-83 basic encryption (custom or explicitly public passphrase). Ciphertext
  alone enters the transaction and package. The message is split safely by UTF-8
  byte length; encrypted output uses 64-character base64 chunks.
- Advanced mode enables one Simple/Detailed JSON import, alongside the message
  when label 674 does not conflict. Files are frozen, not reserialized through jq.
  A bounded lexical walk rejects duplicate keys, noncanonical top-level labels,
  exponent/fractional numbers, out-of-range integers, and oversized nesting/node
  counts. A metadata-path table preserves exact numeric literals. The pinned CLI
  performs ledger/schema validation during the build; fees include the same frozen
  metadata on every iteration. Imported encrypted messages remain opaque in the
  custom preview; a separate decrypt-import viewer is not implemented yet.
- Handle is a third explicit recipient choice. Local and light modes query Koios;
  registry and candidate UTxOs plus bulk supply checks establish the reviewed
  destination. Policy windows and sunset slots are enforced. Koios access and a
  valid live registry are required on mainnet/preview/preprod; there is no fallback
  to the Handle API or hardcoded active-policy list. Queries are batched across
  policies per recipient; cross-recipient batching/caching is a later optimization.
- Classic roots, CIP-68 roots, NFT subhandles and virtual subhandles are supported.
  Virtual resolution uses the current label-000 inline datum, not its contract
  holding address. Public/private lease status and expiry are displayed with an
  explicit destination confirmation. Expired leases still resolve but warn about
  revocation/reassignment; private subhandles can be reassigned by the parent owner
  even before expiry. There is never a parent-address fallback. Script
  destinations remain unsupported through Handles. Rechecks run before building,
  signing and live submission; a changed address stops the action rather than
  silently redirecting funds. Virtual identity/lease changes also require renewed
  review. Resolution evidence, including lease state, accompanies the package intent.
- Offline tests cover metadata precision, Unicode, the published CIP-83 vector,
  random salts, secret logging, Handle registry/supply errors, stale tips, mint
  windows and offline rejection. Pinned Linux binary coverage is extended for
  metadata packaging, signing and hardware transformation; physical-device/live
  submission remains a separate acceptance test. No release/changelog increment.

## Initial implementation boundary

### Send presentation and package storage

- Source-wallet, recipient, metadata, transaction-information and result tables
  share the Wallet display theme. The source summary shows spendable ADA and
  distinct native-asset count. Asset selection highlights nonzero available
  quantities in the number color and selected quantities in the success color;
  zeros remain muted. Menus are separated from data by a blank line.
- Recipient add/edit is transactional: Cancel (including input cancellation)
  returns to the recipients menu with the previous addresses, amounts, asset
  choices, Handle evidence and amount mode unchanged. Text inputs use Esc/Ctrl+C;
  selection menus also have an explicit cancel entry. The testnet warning appears
  only for pasted external addresses.
- Metadata editing redraws the current draft. One message is grouped under its
  CIP type and label 674 with numbered lines; custom JSON uses label/path/content
  rows with exact integer lexemes. Encrypted messages show their protection type,
  never a plaintext preview after encryption.
- Live sign-and-submit is the first available workflow. Final review shows
  recipients, metadata and one focused transaction-information table (fee, returned
  change, input selection, active change policies and expiry). Decoded transaction
  and required signers are explicit menu choices; inspection does not rebuild the
  transaction. The Continue choice authorizes signing; submission has a separate
  confirmation, defaulting to Yes, and uses "local node" or "Koios" wording.
- Package validation, authoritative decoding, input/Handle/expiry rechecks and
  signer verification remain mandatory. Intent-summary JSON is logged rather
  than displayed in Send. No decoded transaction is dumped after signing.
- Intermediate packages use the existing private, cleanup-tracked action
  workspace. Exported packages are automatically saved under
  `<node home>/transactions/send-<timestamp>.<unique>/unsigned.json` or
  `signed.json` without overwriting existing files. Final paths are shown for
  offline/sign-only workflows. Live flows also retain the final signed package
  before submission for recovery, showing its path if submission is declined or
  fails. Submission results use a table with the transaction ID/status; acceptance
  is explicitly distinguished from confirmed inclusion.

### Transfer behavior

- CNTools-wallet or external-address recipients, with add/edit/remove review
  and a maximum of 20 recipients. Local native-script wallets can receive;
  external script destinations, script spending, and Byron addresses are deferred.
  Testnet addresses cannot distinguish preview from preprod/guild by themselves;
  the UI explicitly asks users to verify the selected network.
- Exact ADA and native-asset quantities, single-recipient Max ADA and Send
  everything. Asset entry uses explicitly labelled integer smallest units and
  policy/name identity; metadata-assisted names/decimal entry are follow-ups.
  ADA accepts six decimal places; comma grouping is supported for both inputs.
- Fees are added on top, with minimum ADA adjustments explicitly shown in the
  final review. Deduct-fee-from-entered-amount is deferred. Exact transfers keep
  a protocol-valid residual ADA output; use Max/sweep to empty available ADA.
- Native-asset-aware selection and residual token change reuse configured
  fragmentation and percentage-based ADA management. Max/sweep selects all
  spendable inputs (up to 100) and skips optional ADA housekeeping. Conservative
  value/transaction-size bounds can require smaller transfers near protocol limits.
- The shared raw builder iterates exact fee/change amounts using current protocol
  parameters, with identical local/Koios behavior. This replaces the proposed
  backend-specific auto-balancing approach for Send. Only the payment key witnesses
  ordinary transfers; hardware base change includes both public derivation paths.
- Unsigned export for offline signing, sign-only, and live sign/submit paths use
  the existing public package contract. Locked/public-only wallets can export
  when their verification material is available. Online chain data is required to
  compose the transaction; importing a chain snapshot on an offline builder is not
  part of this slice. Expiry choices are 30 minutes, 2 hours, or 24 hours.
- Funds refresh before building; selected inputs and expiry are checked again
  before live signing/submission. Saved packages are retained on later cancellation
  or failure. Offline signing/submission remains available through Transaction.
- Unit and workflow tests are in `files/tests/cntools-funds-send.sh`. The Linux
  pinned-binary smoke test also builds/signs Send bodies and checks fee coverage
  using the deployment-pinned CLI. Its synthetic Conway protocol fixture omits
  Plutus cost models deliberately and must never be used for real transfers.

## First slice: direct-address transfers

Use the shared transaction, signing, submission, coin-selection, change-planning,
number-formatting, and themed Gum UI libraries. Keep the action itself small.

### User flow

1. **Source wallet.** Select a CNTools wallet and fetch spendable base/payment
   UTxOs with progress feedback. Show rewards separately: Send does not implicitly
   withdraw rewards or reclaim deposits. Support CLI, mnemonic, hardware, and
   payment-only sources. Watch-only or locked wallets can prepare unsigned packages
   when the required public artifacts are available. Script/multisig spending is
   a later slice, not an ordinary key-wallet signing path.
2. **Recipient type.** Explicitly choose **CNTools wallet** or **External address**.
   - CNTools wallet: select an existing wallet, then show its actual destination.
     Prefer the combined base address, otherwise its payment address. Use a
     native-script wallet's appropriate receiving address where available; this
     does not imply support for spending from that script wallet. Stake-only
     wallets cannot receive a normal transaction output and must be explained or
     excluded. If more than one useful receiving address is offered, default to
     the primary address and clearly label alternatives.
   - External address: paste a payment-capable receiving address. Trim surrounding
     whitespace, validate the address and active network, and reject reward
     addresses. Do not silently accept contract destinations needing unsupported
     datum handling. No handle lookup in this first slice.
   - Both paths feed the same validated recipient representation and show the
     full address for review. Warn about sending back to the source wallet.
3. **What to send.** Enter ADA, select native assets and quantities, or choose
   Send everything. Accept grouped or ungrouped numeric input using the shared
   number library. Use exact integer quantities internally. Asset identity is
   policy ID plus asset-name bytes, never a ticker. Explain unknown decimals and
   distinguish whole-token quantities from display amounts.
4. **Recipients.** Present an editable list with Add, Edit, Remove, Continue, and
   Cancel. Recalculate totals when it changes. Start with one recipient; do not
   require a separate batch workflow for ordinary multiple recipients.
5. **Execution.** Offer an unsigned package for offline signing, signing without
   submission, or live signing/submission through the shared flow. Offline signing
   does not mean live UTxO/protocol data can be invented on an offline machine.
6. **Build and review.** Show recipients, amounts, required ADA for asset outputs,
   fees, change, inputs, required witnesses, expiry, and active selection/change
   policies. Allow going back to edit before confirmation. Reveal private keys or
   request hardware signing only through the established signing flow.
7. **Result.** Show the package location or submission result and transaction ID.
   Distinguish successful submission from confirmed inclusion.

### Amount, fee, and change semantics

- Fees are added on top by default. A proposed single-recipient ADA option can
  deduct the fee from the entered amount, but must explicitly show the recipient's
  net amount and still enforce the output minimum.
- Asset outputs require protocol-calculated minimum ADA, not a fixed constant.
  Show and confirm any ADA added automatically.
- Max ADA retains ADA needed for assets left behind. Send everything explicitly
  sweeps spendable ADA and assets, less fees, without including rewards/deposits.
  Initially limit these modes to one recipient to avoid ambiguous allocation.
- Persistent token-fragmentation and ADA-management settings apply to change,
  not silently to recipient amounts. Max/sweep should not reserve optional
  housekeeping change; explain applicable policy exceptions in the review.
- Reuse the selected wallet's change address. Do not prompt for housekeeping
  settings on every transfer. Collection/consolidation stays a separate feature.
- Reuse transaction validity controls. Exact live/offline expiry defaults remain
  an implementation decision; explain expiry before exporting an offline package.

### Shared foundation work and acceptance checks

- Extend selection to cover requested asset quantities as well as ADA. Compute
  residual assets by subtracting recipient outputs before planning change.
- Converge selection, minimum ADA, change outputs, and fee together; enforce value
  size and transaction size limits. Do not consume extra inputs merely to create
  optional housekeeping outputs.
- Preserve exact value conservation and required-witness accounting across base
  and payment inputs. Recheck spent inputs and expiry before submission. Any
  changed transaction body requires review and new signatures.
- Test ADA-only, mixed assets, unknown decimals, dust/minimum ADA, insufficient
  assets/ADA, multiple recipients, max/sweep, wrong-network addresses, source-self
  transfers, hardware/CLI signing, and offline export/import. Use deployment-pinned
  tool versions and local plus Koios query fixtures. Never log secrets.

## ADA Handle design reference (ownership paths now implemented)

Use **ADA Handle** as a third explicit recipient choice. Do not make users
guess which formats the External address field accepts. Keep a focused resolver
separate from the Send action; its output is an ordinary validated address plus
resolution evidence for review and logging.

### Handle forms to cover

The official [Handle resolution guide](https://public.koralabs.io/documentation/HandleResolution.pdf)
distinguishes these resolution paths:

| Form | Resolution basis |
| --- | --- |
| Classic root handle (`$name`) | Holding address of the unprefixed handle token. |
| CIP-68 root handle | Holding address of the label-222 user token, not its reference token. |
| NFT subhandle (`$child@parent`) | Label-222 user token, as for a CIP-68 root handle. |
| Virtual subhandle (`$child@parent`) | Label-000 token's datum, specifically the ADA destination; not the token's contract holding address. |

The guide checks active policies first, then CIP-68/NFT ownership, virtual
subhandles when applicable, and classic ownership. Policies include mint windows
and sunset information. Do not resolve arbitrary same-named tokens or hardcode
the original policy as the only valid policy forever.

Personalization is a separate concern, not another token-ownership model. Do not
treat arbitrary profile metadata as authority to redirect funds. The official
[API specification](https://github.com/koralabs/api.handle.me/blob/preview/docs/spec/spec.md)
and [index model](https://github.com/koralabs/api.handle.me/blob/preview/docs/spec/index-model.md)
provide additional implementation references beyond the overview diagram.

### Koios approach and remaining validation

Koios exposes bulk `asset_utxos`, asset information/history, and address lookup
endpoints in its [asset API definitions](https://github.com/cardano-community/koios-artifacts/blob/main/specs/fragments/paths/asset.yaml).
The official Handle API specification also describes using Koios `asset_utxos`
and `tx_info` to recover indexed state. These are good evidence that a focused
Koios-backed resolver is feasible, not proof that a complete resolver is simply
one NFT-address query.

Proposed implementation:

1. Establish authenticated, network-specific policy-registry bootstrap data and
   read current policy rules from chain. Verify registry identity rather than
   trusting any asset named `handle_policies`.
2. Validate handle syntax and encode the exact asset names/labels. Batch candidate
   lookups across applicable policies and recipients through the shared logged
   Koios client. Cache within the operation, not indefinitely.
3. Validate ownership and relevant datum state using UTxO/transaction queries.
   Implement official precedence and mint/sunset rules. Reject ambiguity, burned
   or invalid state, missing destination data, and malformed responses.
4. Decode virtual destinations and lease state under the reviewed rules below.
   Reject malformed/missing datum; never guess a parent address as fallback.
5. Validate the resulting receiving address/network exactly as for pasted input.
   Unsupported datum-requiring destinations remain unsupported after resolution.

Use Koios in both local and light modes when available, clearly identifying it
as the source. There must be no network lookup in offline mode and no silent
fallback to the Handle API. Missing/unavailable resolution must not block normal
direct-address sending. A lookup error must not be reported as “handle not found.”

Review must show the exact handle, type, network, full resolved address, and query
source. Record policy/asset identity, relevant UTxO references and query time in
the package and normal API logs. Re-resolve before final online review; a changed
destination requires explicit renewed approval. An offline package pins the
reviewed address: later handle movement must never rewrite a signed transaction.
Explain that handles can change destination after resolution.

Acceptance coverage includes fixtures for each form,
transfers, migration/overlap, burns, virtual state changes, unsupported networks,
ambiguous candidates, stale/unavailable indexers, and wrong-network destinations.
Pin resolver rules and test data to reviewed upstream revisions. The virtual
on-chain captures currently cover preview; full mainnet/preprod live acceptance
and physical hardware transaction submission remain separate acceptance checks.

## Extended Send design reference

Design review: 2026-09-05. The implemented subset and remaining limitations are
listed above; retain the following as the fuller acceptance roadmap. Keep the
existing Send flow and small shared helpers, with no new transaction framework.

### User interaction

- Add **ADA Handle** alongside CNTools wallet and External address. Show the full
  resolved address before proceeding; the handle is an alias, not the destination
  stored in the transaction. Do not require advanced mode to use a handle.
- Add **Message / metadata** to the editable transfer review. Default to None,
  without an extra compulsory question for every transfer. Show a compact summary
  when configured and offer Edit / Remove. Draft content belongs to this transfer,
  not persistent settings or the next Send invocation.
- Offer **Add message** normally and **Import custom metadata** behind the existing
  advanced flag. A multiline Gum editor fits messages; custom metadata uses a file
  picker/path input and explicit Simple JSON / Detailed JSON format choice.
- Offer Plain (CIP-20) or Encrypted (CIP-83) when adding a message. Encryption
  offers an explicit public-default-passphrase or custom-passphrase choice; never
  silently use the public default when a custom password is left empty.
- Show the message and an expandable/tree-style metadata review before
  confirmation. Plaintext is public; encrypted content is still permanently
  published as ciphertext, and other metadata, addresses and amounts remain public.
  Messages are transaction-wide, not recipient-specific. For encrypted messages,
  keep plaintext review local and transient, not in the exported review summary.
  Never render imported terminal escape sequences.
- Changing message, metadata, recipient, or resolution invalidates the built
  transaction and its fee review. Rebuild and review before signing, including
  Max ADA and Send everything, whose recipient amounts change with the fee.

### CIP-20 message handling

Use [CIP-20](https://cips.cardano.org/cip/CIP-0020): label `674` contains a map
with a nonempty `msg` array. Each string is limited to **64 UTF-8 bytes**, not
64 characters. Accept multiline input, split long lines at valid UTF-8 boundaries
(prefer word boundaries), and show the resulting lines for approval. Preserve
intentional line breaks; do not silently truncate or strip meaningful text.
Empty input means no message. Apply a reasonable editor/import size bound before
processing, then enforce actual transaction size through the builder.

Generate a small standalone metadata file. When custom metadata is present,
generate the message using that file's selected JSON schema. Detailed schema
explicitly represents the message as text; Simple JSON follows the CLI's normal
mapping. Verify edge cases such as text beginning with `0x` against the pinned
CLI; if a message would be interpreted as bytes, require Detailed JSON for the
combined import rather than silently changing the message's on-chain type.

### CIP-83 encrypted messages

Include [CIP-83](https://cips.cardano.org/cip/CIP-0083) in the first metadata slice,
not a later optional extension. Support `enc: "basic"` under label 674. Serialize
the entire plaintext `msg` array as UTF-8 JSON and encrypt it once, not each line
individually. Base64-encode the salted result and split it into `msg` strings of
at most 64 ASCII bytes. Preserve unrelated metadata outside that message.

The interoperable format uses AES-256-CBC, PKCS#7 padding, PBKDF2-HMAC-SHA256 with
10,000 iterations, a fresh random 8-byte salt, and the OpenSSL `Salted__` envelope.
Do not change those parameters under the same method name. Explicitly select
SHA-256 and iterations; use `-saltlen 8` where supported and verify the older
8-byte behavior otherwise. Newer OpenSSL releases changed the PBKDF2 salt default;
see the [OpenSSL enc documentation](https://docs.openssl.org/master/man1/openssl-enc/).
Capability-check the installed tool and fail clearly rather than producing an
incompatible message. Reuse the existing OpenSSL dependency through a focused
`message-crypto.sh` helper, not custom cryptographic primitives in Bash.

The standard's default passphrase is `cardano`. Label this choice **Public
passphrase — anyone can decrypt**, never private encryption. Custom mode uses
masked entry and confirmation, recommends a strong unique shared passphrase,
and explains that it must be communicated separately to the recipient. Neither
mode uses wallet signing keys. Do not silently reuse the wallet encryption password.

Pass secrets through a private file descriptor, not command arguments, environment
variables, history, or normal command-capture logging. Disable tracing around secret
handling. Do not persist plaintext, passphrases, derived keys, or their hashes in
packages/logs. Log operation, non-secret parameters, status and ciphertext digest;
the copyable command must redact secret inputs. Clear transient UI/state on cancel
and completion, without promising secure memory erasure or removal from terminal
scrollback. Only frozen ciphertext enters build/fee iterations and offline packages;
signing/submission must not require the message passphrase or re-encrypt on rebuild.

Provide local decryption/round-trip validation for generated messages and optional
local review of imported basic messages. Never send ciphertext/passphrases to an
API for decryption. Require decoded plaintext to be the expected string array and
handle bad passwords/malformed data safely. Missing `enc` and `enc: "plain"` mean
ordinary messages; unknown encryption methods remain opaque and are never guessed.
Additional label-674 fields are allowed. Existing label-conflict handling applies
equally to encrypted and plaintext imports.

CBC basic mode has no authentication tag: successful decryption is not proof of
authenticity, and weak passphrases remain vulnerable to offline guessing. Explain
these limits without inventing a nonstandard authenticated variant. Transaction
signatures bind the submitted ciphertext, not a claimed plaintext sender identity.

### Custom metadata and exact preservation

- Initially support one JSON import in either CLI schema, plus the optional
  generated message. Defer raw CBOR input and multiple custom files until useful.
  Simple JSON is the familiar label-to-content object; Detailed JSON supports
  explicit integer, byte, string, list, and map types. Explain that arbitrary JSON
  is not automatically valid Cardano metadata: booleans, null, fractional values,
  oversized strings/bytes, and out-of-range integers are rejected by the CLI.
- Copy the selected regular file into the protected transaction staging directory
  before validation and preview. Build only from that frozen copy, never from a
  file the user can inadvertently change between review and signing.
- Preserve imported bytes and numeric literals. Do not serialize custom metadata
  back through jq: deployed jq versions can lose precision for large integers.
  Use the pinned CLI as the ledger/schema validator and use a lossless review
  path for large numbers. Reject ambiguous duplicate JSON keys/metadata labels,
  including equivalent numeric label spellings, rather than accepting a parser's
  silent last/first-value behavior. Cover this explicitly in validation tests.
- The pinned CLI's `readTxMetadata` accepts multiple metadata files and combines
  their decoded content. Pass the custom file and generated message separately
  with repeated `--metadata-json-file` flags and one shared schema selection;
  CNTools does not need to rewrite/merge the custom document.
- If the custom file owns label 674, ask the user to keep the imported label or
  remove it from their file before adding a CNTools message. Never silently
  overwrite, merge, or discard either value. Match the numeric label, not just
  the literal string `"674"`.
- Include the identical frozen files in every fee/build iteration. Check minimum
  fee and total size again after hardware preparation, using the existing path.
  Report CLI validation details in the UI/log without exposing unrelated secrets.
- Keep metadata in the transaction envelope carried by the public offline package;
  do not introduce a required external metadata file for offline signing. A summary
  can record schema, labels, file digest, and message presence, but is not the
  authority for what gets signed. Log exact CLI calls and staged paths/digests;
  do not automatically duplicate the complete draft message into logs.

Suggested shared boundary: `transaction-metadata.sh` owns staging, validation,
message encoding, label conflicts, and builder arguments. Send owns the prompts.
The helper can then serve other transaction actions without copying its logic.

### ADA Handle implementation boundary

Keep network access in `handle.sh` and virtual datum decoding in `handle-virtual.sh`, using existing Koios,
address, logging, and number helpers. No Handle API dependency or arbitrary
profile/IPFS fetch is needed for ordinary ownership-based ADA resolution.

The reviewed official resolver
([revision c74262f](https://github.com/koralabs/api.handle.me/blob/c74262fc69e24131e668bf72e88580b8c95b3dba/repositories/handlesRepository.ts))
confirms that ordinary/label-222 handles use the owner address and that label-100
personalization preserves that ADA destination. Virtual subhandles instead decode
the datum's `resolved_addresses.ada` from address bytes and expose an `expires_time`
field. Lifecycle rules were separately checked against the contract, not inferred
from the field name (see below).

Use the authenticated policy-registry bootstrap for classic,
CIP-68 root, NFT and virtual subhandle paths. Batch policy/asset queries where
possible. Support only networks with reviewed bootstrap identities and fixtures;
do not assume a testnet address proves which test network supplied the answer.
Policy normalization is documented in the upstream
[policy decoder](https://github.com/koralabs/api.handle.me/blob/c74262fc69e24131e668bf72e88580b8c95b3dba/utils/policies.ts).
Apply the mint/sunset checks described above, including registry freshness.

Virtual subhandles use constructor-0/version-1 inline datum with exact, unique
bytes-map keys. `resolved_addresses.ada` contains ledger address bytes; the
`virtual` map contains integer `expires_time` and integer `public_mint` (0/1).
Missing, duplicated, wrong-type or unsupported data fails closed. No JSON display
metadata, IPFS profiles or parent addresses are used as destinations. Existing
direct-address entry stays available independently.

#### Verified virtual lifecycle and CNTools policy

Sources pinned for this implementation:

- [Official API destination extraction](https://github.com/koralabs/api.handle.me/blob/c74262fc69e24131e668bf72e88580b8c95b3dba/repositories/handlesRepository.ts),
  using `@koralabs/kora-labs-common` 6.9.2's Handle datum schema.
- [Personalization contract: REVOKE and UPDATE branches](https://github.com/koralabs/handles-personalization/blob/d54bc81417dc0643bb609c1c857fedc7554e1723/pers.helios)
  and its [specification](https://github.com/koralabs/handles-personalization/blob/d54bc81417dc0643bb609c1c857fedc7554e1723/docs/spec/spec.md).
- [Preview settings](https://github.com/koralabs/handles-subhandle-settings/blob/9bc5ad5cd2fee21045e162080dff7bfd10931b79/deploy/preview/subhandle-settings.yaml):
  expiry duration is 31,536,000,000 milliseconds (one year).

The contract compares expiry as a millisecond POSIX time. Expiry is not an
automatic invalidation or redirect: the current unspent datum continues to carry
the destination until a transaction updates or burns the virtual token. Private
virtuals can be revoked or reassigned by the root holder without waiting for
expiry. Public virtuals may be revoked after expiry, or reclaimed by the root
holder under the contract's renewal/payment rules. Parent transfer or disabling
public minting does not itself replace the current resolved address. Root/settings
references govern mutation authorization; they are not additional destination
sources for read-only resolution.

CNTools therefore shows public/private and expired/unexpired state, UTC expiry,
and an explicit confirmation for **every** virtual recipient. Expired leases are
not silently treated as missing, but carry a clear revocation/reassignment warning.
Zero expiry is an expired timestamp, never a "permanent" sentinel. Before build
and live signing/submission, any destination, token identity/type, expiry timestamp,
public/private flag or lease-status change stops the flow for editing and renewed
review. A profile-only datum/UTxO change does not force approval again when these
reviewed fields remain identical. The newest datum hash and UTxO are still logged.
These checks cannot lock the alias or guarantee its state at transaction inclusion.
Offline packages pin the reviewed address and record the lease/resolution evidence;
they do not need Koios while signing and are never redirected by later alias changes.

The fixture `files/tests/fixtures/handle-virtual-preview.json` contains unmodified
Koios UTxO responses captured 2026-09-06 for `00n@hal`, `00f@hal`, `vsh6@ai` and
`vsh8@ai`, with independently captured official-API expected destinations/leases.
These cover private/public and expired/unexpired examples at capture time. Runtime
uses Koios only; the official API was used for research/cross-checking, not fallback.
Deterministic tests also cover renewal, expiry transitions, revocation, map ordering,
duplicate keys, unsupported versions, unsafe timestamps, absent destinations and
wrong-network/script addresses. No transaction is submitted by these tests.

Resolve through Koios in local or light mode, with progress feedback and copyable
API logs. Query failure, stale/incomplete data, ambiguity, unsupported type/network,
and not found are different outcomes. Do not turn a partial failed lookup into a
successful lower-priority candidate. Koios supplies the chain view; this is not a
trustless proof of current ownership.

Carry the reviewed resolution evidence with each recipient in the package. Check
again before live signing/submission; a changed destination stops the flow and
requires an explicit return to editing, rebuilding, and review. Never substitute
an address in an existing signed package. Offline users review the pinned address
and resolution time without requiring an API call. Handle resolution cannot
guarantee ownership remains unchanged between the last query and inclusion.

### Implementation order and acceptance gates

1. Shared metadata helper, CIP-20 editor and CIP-83 encryption, followed by custom
   JSON import and the common preview. No message/metadata must preserve today's
   behavior.
2. Koios Handle resolver for ownership-based forms after policy/network bootstrap
   fixtures are verified. Reuse the same recipient validation and review.
3. Virtual subhandle datum/lifecycle support follows the verified rules and fixtures
   above. Additional network/device live acceptance remains a release check.

Test with deployment-pinned CLI and hardware-tool versions, not current upstream
defaults. Required metadata coverage includes Unicode/emoji at 64-byte boundaries,
multiline/empty/cancelled messages, schema types, duplicate/conflicting labels,
integers beyond jq's exact range, input-file changes, insufficient fee/size,
Max/sweep, and metadata-only tampering. Prove auxiliary data and its body hash stay
bound through build → package → hardware preparation → offline import → witness
assembly, and that alteration is rejected even if witness/body comparisons alone
would not detect it. Add mocked workflow tests plus real pinned-binary round trips;
a physical hardware signing check remains a separate live acceptance test.

For CIP-83, add official interoperability vectors, default/custom passphrases,
Unicode and JSON escaping, ciphertext chunk boundaries, randomized salt, malformed
envelopes, wrong-password handling, unknown methods, cancellation/secret-log checks,
and encrypted size/fee limits. Verify encrypted offline packages contain neither
plaintext nor secrets. Exercise supported deployment OpenSSL versions (both salt
default behaviors), plus deployment-pinned CLI/hardware tools; round-trip tests
alone cannot prove interoperability if both directions share the same mistake.

## Other deferred additions

- **Multisig source spending, contract-specific outputs, and bulk file import:**
  separate extensions of the same reviewed-recipient and transaction foundation.
