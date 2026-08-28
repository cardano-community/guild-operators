# CNTools libraries

Libraries are sourced only by actions that declare their relative path.
`placeholder.sh` provides the shared inert-action notice used by the Phase 4
menu skeleton. `wallet.sh` provides read-only wallet discovery and inventory
presentation, including Bech32 and selected-path validation. `wallet-query.sh`
adds bounded local and bulk Koios queries for Wallet List and Show. List
deduplicates catalog-wide Koios inputs, splits payloads at a fixed size bound,
asks before fetching live values, shows progress through the shared Gum
spinner, and suppresses totals whenever either funding or reward data is
unknown. Other domain libraries are added only with their functional action
phases.
