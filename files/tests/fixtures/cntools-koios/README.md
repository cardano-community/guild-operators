# CNTools Koios characterization fixtures

These files are synthetic, public test data. They contain no live addresses,
transactions, credentials, or keys.

The suite exercises three legacy `cntools.library` helpers:

- `getBalanceKoios` and its `address_utxos` CSV parser;
- `getRewardInfoKoios` and its `account_info` CSV parser; and
- `getActiveGovActionCount` and its scalar CSV result.

`empty.response` contains only a newline; command substitution removes it and
therefore presents an empty response to the helper. Timeout and cancellation
are simulated by the fake `curl` process returning statuses 28 and 130. They do
not exercise elapsed wall-clock time, shell signals, traps, or interactive user
input.

Malformed fixtures intentionally record current permissive behavior. They are
not examples of valid Koios responses and are not an endorsement of accepting
invalid data. In particular, the address parser retains the valid outer-row
fields when nested asset JSON is malformed, the account parser accepts an
unexpected row, and the governance-count helper accepts a non-numeric value.

`global-state.json` records variables that are absent immediately before a
representative successful call and present immediately afterward. It separates
documented result globals from incidental scratch/API globals. The inventory is
therefore a fresh-name inventory, not a claim that callers always begin without
colliding names.

`global-collisions.json` complements it with explicitly seeded globals. The
suite verifies the seed value and Bash attribute before each call, then verifies
the exact post-call type and value. The representative cases show indexed header
arrays being overwritten, scalar result names being converted to associative
arrays, associative result maps being cleared and repopulated, scratch scalars
being overwritten, and pre-existing integer attributes surviving assignment.
It also freezes the current empty `rewards_available[0]` entry created because
the CSV field variable has the same name as the result map and the final EOF
read clears that element. The same EOF read clears the `status` scratch scalar
and turns a pre-existing integer `deposit` scratch variable into zero. It does
not attempt every possible incompatible Bash attribute combination.

`curl-argv.json` records the complete fake-curl argument vector for every test
case, including option order, HTTP method, headers, request body, and complete
query URL. The fake logs arguments separated by tabs; fixtures contain no tabs
or newlines inside an individual argument.

Both global inventories are representative rather than exhaustive: they cover
only these safe, read-only helpers and do not quantify source-time initialization
or state created by interactive, key-handling, transaction, or mutation
workflows.
