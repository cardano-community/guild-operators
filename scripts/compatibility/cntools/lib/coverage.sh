#!/usr/bin/env bash
# Inventory is deliberately broader than the exercised checks. Do not equate
# discovery, help success, or empty replies with end-to-end feature coverage.
ck_coverage_inventory() {
  type -P rg >/dev/null || { ck_block 'Install ripgrep (rg) to run the source coverage inventory'; return 78; }
  rg -n 'cntools_wallet_query_http|cntools_funding_get|cntools_api_request|curl |run_cli|run_command|openssl |gpg |key_crypto_run|_CLI\}"|_TOOL\}"|_SIGNER\}"' \
    "$CK_SOURCE/core" "$CK_SOURCE/lib" > "$CK_CASE_DIR/source-calls.txt" || return
  local -a known=(account_info address_info address_utxos asset_history asset_info asset_utxos cli_protocol_params committee_info drep_info pool_calidus_keys pool_info proposal_list proposal_votes proposal_voting_summary submittx tip tx_info tx_status)
  local route='' found=N missing=0
  # Discover literal API routes independently of the suite catalog.
  rg --no-filename -o 'CNTOOLS_KOIOS_API[^}]*\}/[a-z_]+' "$CK_SOURCE" |
    sed 's@.*/@@' | sort -u > "$CK_CASE_DIR/discovered-koios-routes.txt"
  while IFS= read -r route; do
    found=N
    local expected=''
    for expected in "${known[@]}"; do [[ "$route" != "$expected" ]] || found=Y; done
    if [[ "$found" == N ]]; then printf 'New unmapped Koios route: %s\n' "$route"; missing=$((missing+1)); fi
  done < "$CK_CASE_DIR/discovered-koios-routes.txt"
  # The dynamically chosen inventory routes are explicitly documented too.
  printf '%s\n' credential_txs credential_utxos account_txs account_utxos >> "$CK_CASE_DIR/discovered-koios-routes.txt"
  printf '%s\n' \
    'CLI: key/address/identity, certificates/votes, build-raw, exact fee, decode, sign, witness, assemble: executed with disposable data.' \
    'CLI: build-estimate executes with disposable data. Online build is syntax-only; connected-node auto-balancing is not integration tested.' \
    'Node: query tip/protocol/UTxO/stake/pool/DRep/governance and health metrics: executed only with explicit socket/public fixtures.' \
    'Koios: literal and dynamic wallet/governance/asset routes: executed only with explicit endpoint/public fixtures.' \
    'Koios: wallet and metadata production parsers are exercised with captured responses; curated voting/Calidus fixtures are needed.' \
    'Companions: GPG/OpenSSL/Cardano Address/Cardano Signer: disposable executed scenarios when installed.' \
    'Hardware CLI: source-derived argument names checked against subcommand help, plus device-free ADA/token validation and transform. Help does not prove value/repeat semantics or device output.' \
    'Not exercised: live CLI/Koios submission, hardware approval, KES query with real opcert, full Handle/metadata display semantics.' \
    'Companions: Token Registry lifecycle and tar/gzip/SQLite checks execute when their prerequisites are installed.' \
    'Other external interfaces: GitHub updates, Catalyst REST, arbitrary off-chain metadata URLs, chattr and UI tool behavior are listed in source-calls.txt but are not yet contract-tested.' \
    'Source inventory is a review aid, not proof of exhaustive coverage of dynamically constructed commands. Review it whenever an external call is added.' \
    > "$CK_CASE_DIR/coverage.txt"
  cat "$CK_CASE_DIR/coverage.txt"
  (( missing == 0 ))
}
ck_suite_coverage() {
  ck_run coverage-inventory 'Source call inventory and newly unmapped Koios routes' discovery ck_coverage_inventory
}
