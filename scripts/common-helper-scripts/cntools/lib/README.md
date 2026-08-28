# CNTools libraries

Libraries are sourced only by actions that declare their relative path.
`placeholder.sh` provides the shared inert-action notice used by the Phase 4
menu skeleton. `wallet.sh` provides read-only wallet discovery and inventory
presentation, including Bech32 and selected-path validation. `wallet-query.sh`
adds bounded local and bulk Koios queries only for Wallet Show, suppressing
complete aggregates when any funding query is missing. Other domain libraries
are added only with their functional action phases.
