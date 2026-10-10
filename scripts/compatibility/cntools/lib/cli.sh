#!/usr/bin/env bash
# Actual candidate commands, with disposable keys. Production version guards
# are reported separately; this runner never changes CNTools' supported pins.
# shellcheck disable=SC2034
ck_cli_version() {
  ck_cli "$CK_WORK/cli-version" version || return
  local actual='' pin=''
  actual="$(sed -n '1p' "$CK_WORK/cli-version")"
  [[ "$actual" == *cardano-cli* ]] || { ck_note 'Unrecognized CLI version output'; return 1; }
  pin="$(jq -r '.companions["cardano-cli"].version' "$CK_REPO/files/node-implementations/cnode/release.json")"
  printf 'Executable: %s\nReported: %s\nDeployment CLI pin: %s\n' "$CK_CLI" "$actual" "$pin"
  [[ "$actual" == *" $pin"* ]] || ck_note 'Candidate differs from deployment pin. Compatibility passes do not authorize a production pin change.'
}
ck_cli_key() {
  local role="$1" derived="$CK_WORK/$1.derived.vkey"
  local -a args=()
  case "$role" in payment) args=(address key-gen) ;; stake) args=(latest stake-address key-gen) ;;
    drep) args=(latest governance drep key-gen) ;; *) return 1 ;; esac
  ck_cli "$CK_WORK/out" "${args[@]}" --verification-key-file "$CK_WORK/$role.vkey" --signing-key-file "$CK_WORK/$role.skey" || return
  ck_envelope "$CK_WORK/$role.skey" && ck_envelope "$CK_WORK/$role.vkey" || return 1
  ck_cli "$CK_WORK/out" key verification-key --signing-key-file "$CK_WORK/$role.skey" --verification-key-file "$derived" || return
  [[ "$(jq -r .cborHex "$derived")" == "$(jq -r .cborHex "$CK_WORK/$role.vkey")" ]] || { ck_note 'Verification key does not match signing key'; return 1; }
}
ck_cli_addresses() {
  ck_require_file "$CK_WORK/payment.vkey" && ck_require_file "$CK_WORK/stake.vkey" || return 78
  ck_cli "$CK_WORK/payment.addr" address build --payment-verification-key-file "$CK_WORK/payment.vkey" "${CK_NET[@]}" || return
  ck_cli "$CK_WORK/base.addr" address build --payment-verification-key-file "$CK_WORK/payment.vkey" --stake-verification-key-file "$CK_WORK/stake.vkey" "${CK_NET[@]}" || return
  ck_cli "$CK_WORK/reward.addr" latest stake-address build --stake-verification-key-file "$CK_WORK/stake.vkey" "${CK_NET[@]}" || return
  ck_cli "$CK_WORK/payment.hash" address key-hash --payment-verification-key-file "$CK_WORK/payment.vkey" || return
  ck_cli "$CK_WORK/stake.hash" latest stake-address key-hash --stake-verification-key-file "$CK_WORK/stake.vkey" || return
  local addr='' hrp='' hex='' expected='' keyhash=''
  for addr in payment base reward; do
    if [[ "$addr" == reward ]]; then hrp=stake; else hrp=addr; fi
    [[ "$CK_NETWORK" == mainnet ]] || hrp+=_test
    cntools_bech32_decode_into hex "$(< "$CK_WORK/$addr.addr")" "$hrp" || { ck_note "Invalid $addr address checksum"; return 1; }
    if [[ "$addr" == reward ]]; then keyhash="$(< "$CK_WORK/stake.hash")"; else keyhash="$(< "$CK_WORK/payment.hash")"; fi
    [[ "${hex:2:56}" == "$keyhash" ]] || { ck_note 'Address credential/key hash mismatch'; return 1; }
    [[ "$addr" != base || "${hex:58:56}" == "$(< "$CK_WORK/stake.hash")" ]] || return 1
    expected=0; [[ "$CK_NETWORK" != mainnet ]] || expected=1
    [[ "${hex:1:1}" == "$expected" ]] || { ck_note 'Address network header mismatch'; return 1; }
  done
  ck_cli "$CK_WORK/out" latest governance drep id --drep-verification-key-file "$CK_WORK/drep.vkey" --output-cip129 --out-file "$CK_WORK/drep.id" || return
  cntools_bech32_decode_into hex "$(< "$CK_WORK/drep.id")" drep || return 1
}
ck_cli_mnemonic() {
  local CK_SECRET=Y phrase='' role='' selector=''
  ck_cli "$CK_WORK/mnemonic" latest key generate-mnemonic --size 24 || return
  phrase="$(< "$CK_WORK/mnemonic")"
  local -a words=(); read -r -a words <<< "$phrase"
  (( ${#words[@]} == 24 )) || { ck_note 'Expected 24 recovery words; secret output suppressed'; return 1; }
  for role in payment stake drep; do
    case "$role" in payment) selector=--payment-key-with-number ;; stake) selector=--stake-key-with-number ;; drep) selector=--drep-key ;; esac
    local -a args=(latest key derive-from-mnemonic --key-output-text-envelope "$selector")
    [[ "$role" == drep ]] || args+=(0)
    ck_cli "$CK_WORK/out" "${args[@]}" --account-number 0 --mnemonic-from-interactive-prompt --signing-key-file "$CK_WORK/mn-$role.skey" <<< "$phrase" || return
    ck_envelope "$CK_WORK/mn-$role.skey" || return
    ck_cli "$CK_WORK/out" key verification-key --signing-key-file "$CK_WORK/mn-$role.skey" --verification-key-file "$CK_WORK/mn-$role.ext.vkey" || return
    ck_cli "$CK_WORK/out" key non-extended-key --extended-verification-key-file "$CK_WORK/mn-$role.ext.vkey" --verification-key-file "$CK_WORK/mn-$role.vkey" || return
    ck_envelope "$CK_WORK/mn-$role.vkey" || return
  done
}
ck_cli_pool_keys() {
  ck_cli "$CK_WORK/out" latest node key-gen --cold-verification-key-file "$CK_WORK/cold.vkey" --cold-signing-key-file "$CK_WORK/cold.skey" --operational-certificate-issue-counter-file "$CK_WORK/cold.counter" || return
  ck_cli "$CK_WORK/out" latest node key-gen-KES --verification-key-file "$CK_WORK/hot.vkey" --signing-key-file "$CK_WORK/hot.skey" || return
  ck_cli "$CK_WORK/out" latest node key-gen-VRF --verification-key-file "$CK_WORK/vrf.vkey" --signing-key-file "$CK_WORK/vrf.skey" || return
  ck_cli "$CK_WORK/vrf.hash" latest node key-hash-VRF --verification-key-file "$CK_WORK/vrf.vkey" || return
  ck_cli "$CK_WORK/pool.id" latest stake-pool id --cold-verification-key-file "$CK_WORK/cold.vkey" || return
  ck_cli "$CK_WORK/pool.hex" latest stake-pool id --cold-verification-key-file "$CK_WORK/cold.vkey" --output-format hex || return
  local hex=''
  cntools_bech32_decode_into hex "$(< "$CK_WORK/pool.id")" pool || return
  [[ "$hex" == "$(< "$CK_WORK/pool.hex")" ]] || return 1
  ck_cli "$CK_WORK/out" latest node new-counter --cold-verification-key-file "$CK_WORK/cold.vkey" --counter-value 0 --operational-certificate-issue-counter-file "$CK_WORK/new.counter" || return
  ck_cli "$CK_WORK/out" latest node issue-op-cert --kes-verification-key-file "$CK_WORK/hot.vkey" --cold-signing-key-file "$CK_WORK/cold.skey" --operational-certificate-issue-counter-file "$CK_WORK/new.counter" --kes-period 0 --out-file "$CK_WORK/op.cert" || return
  ck_envelope "$CK_WORK/op.cert"
}
ck_cli_cert() {
  local kind="$1" file="$CK_WORK/$1.cert"
  ck_require_file "$CK_WORK/stake.vkey" && ck_require_file "$CK_WORK/cold.vkey" && ck_require_file "$CK_WORK/drep.vkey" || return 78
  local -a args=()
  case "$kind" in
    stake-reg) args=(latest stake-address registration-certificate --stake-verification-key-file "$CK_WORK/stake.vkey" --key-reg-deposit-amt 2000000) ;;
    stake-dereg) args=(latest stake-address deregistration-certificate --stake-verification-key-file "$CK_WORK/stake.vkey" --key-reg-deposit-amt 2000000) ;;
    stake-delegate) args=(latest stake-address stake-delegation-certificate --stake-verification-key-file "$CK_WORK/stake.vkey" --cold-verification-key-file "$CK_WORK/cold.vkey") ;;
    vote-delegate) args=(latest stake-address vote-delegation-certificate --stake-verification-key-file "$CK_WORK/stake.vkey" --drep-verification-key-file "$CK_WORK/drep.vkey") ;;
    vote-abstain) args=(latest stake-address vote-delegation-certificate --stake-verification-key-file "$CK_WORK/stake.vkey" --always-abstain) ;;
    vote-no-confidence) args=(latest stake-address vote-delegation-certificate --stake-verification-key-file "$CK_WORK/stake.vkey" --always-no-confidence) ;;
    register-delegate) args=(latest stake-address registration-and-delegation-certificate --stake-verification-key-file "$CK_WORK/stake.vkey" --cold-verification-key-file "$CK_WORK/cold.vkey" --key-reg-deposit-amt 2000000) ;;
    register-vote) args=(latest stake-address registration-and-vote-delegation-certificate --stake-verification-key-file "$CK_WORK/stake.vkey" --always-abstain --key-reg-deposit-amt 2000000) ;;
    drep-reg) args=(latest governance drep registration-certificate --drep-verification-key-file "$CK_WORK/drep.vkey" --key-reg-deposit-amt 500000000) ;;
    drep-update) args=(latest governance drep update-certificate --drep-verification-key-file "$CK_WORK/drep.vkey") ;;
    drep-retire) args=(latest governance drep retirement-certificate --drep-verification-key-file "$CK_WORK/drep.vkey" --deposit-amt 500000000) ;;
    pool-reg) args=(latest stake-pool registration-certificate --cold-verification-key-file "$CK_WORK/cold.vkey" --vrf-verification-key-file "$CK_WORK/vrf.vkey" --pool-pledge 100000000 --pool-cost 170000000 --pool-margin 0.05 --pool-reward-account-verification-key-file "$CK_WORK/stake.vkey" --pool-owner-stake-verification-key-file "$CK_WORK/stake.vkey" --single-host-pool-relay relay.example.invalid --pool-relay-port 3001 "${CK_NET[@]}") ;;
    pool-retire) args=(latest stake-pool deregistration-certificate --cold-verification-key-file "$CK_WORK/cold.vkey" --epoch 100) ;;
    vote-yes|vote-no|vote-abstain-decision) args=(latest governance vote create)
      case "$kind" in vote-yes) args+=(--yes) ;; vote-no) args+=(--no) ;; *) args+=(--abstain) ;; esac
      args+=(--governance-action-tx-id "$(printf 'ab%.0s' {1..32})" --governance-action-index 0 --drep-verification-key-file "$CK_WORK/drep.vkey") ;;
    *) return 1 ;;
  esac
  ck_cli "$CK_WORK/out" "${args[@]}" --out-file "$file" || return
  ck_envelope "$file"
}
ck_cli_metadata() {
  printf '{"name":"Compatibility","ticker":"CHECK","description":"Disposable fixture","homepage":"https://example.invalid"}\n' > "$CK_WORK/poolmeta.json"
  ck_cli "$CK_WORK/hash" latest stake-pool metadata-hash --pool-metadata-file "$CK_WORK/poolmeta.json" || return
  ck_cli "$CK_WORK/anchor.hash" hash anchor-data --file-binary "$CK_WORK/poolmeta.json" || return
  [[ "$(< "$CK_WORK/hash")" =~ ^[0-9a-f]{64}$ && "$(< "$CK_WORK/hash")" == "$(< "$CK_WORK/anchor.hash")" ]] || return 1
  printf '{"body":{"givenName":"Compatibility"}}\n' > "$CK_WORK/drepmeta.json"
  ck_cli "$CK_WORK/hash" latest governance drep metadata-hash --drep-metadata-file "$CK_WORK/drepmeta.json" || return
  [[ "$(< "$CK_WORK/hash")" =~ ^[0-9a-f]{64}$ ]]
}
ck_cli_transaction() {
  local kind="$1" addr='' fee=0 next='' actual=0 i=0 witnesses=1 amount=10000000 change=0
  local input='' policy='' hash='' quantity=9007199254740993 input_coin=2000000000 deposit=0 credit=0
  input="$(printf '00%.0s' {1..32})#0"
  local dir="$CK_WORK/tx-$kind"
  ck_require_file "$CK_WORK/base.addr" || return 78
  mkdir "$dir"; addr="$(< "$CK_WORK/base.addr")"
  local -a extra=() signers=(--signing-key-file "$CK_WORK/payment.skey")
  case "$kind" in
    assets|mint|multisig)
      hash="$(< "$CK_WORK/payment.hash")"
      jq -n --arg hash "$hash" '{type:"sig",keyHash:$hash}' > "$dir/policy.json"
      ck_cli "$dir/policy.id" latest transaction policyid --script-file "$dir/policy.json" || return
      ck_cli "$dir/script.hash" hash script --script-file "$dir/policy.json" || return
      [[ "$(< "$dir/policy.id")" == "$(< "$dir/script.hash")" ]] || return 1
      policy="$(< "$dir/policy.id")"
      [[ "$kind" != mint ]] || extra+=(--mint "$quantity $policy.74657374" --mint-script-file "$dir/policy.json")
      [[ "$kind" != multisig ]] || extra+=(--tx-in-script-file "$dir/policy.json") ;;
    metadata) printf '{"674":{"msg":["Compatibility","CIP-20"]}}\n' > "$dir/metadata.json"; extra+=(--metadata-json-file "$dir/metadata.json") ;;
    detailed-metadata) printf '{"674":{"map":[{"k":{"string":"msg"},"v":{"list":[{"string":"Compatibility"}]}}]}}\n' > "$dir/metadata.json"; extra+=(--metadata-json-file "$dir/metadata.json" --json-metadata-detailed-schema) ;;
    stake-reg|stake-dereg|stake-delegate|vote-delegate|drep-reg|drep-update|drep-retire|pool-reg|pool-retire)
      ck_require_file "$CK_WORK/$kind.cert" || return 78
      extra+=(--certificate-file "$CK_WORK/$kind.cert")
      case "$kind" in drep-*) signers+=(--signing-key-file "$CK_WORK/drep.skey") ;; pool-*) signers+=(--signing-key-file "$CK_WORK/cold.skey"); [[ "$kind" != pool-reg ]] || signers+=(--signing-key-file "$CK_WORK/stake.skey") ;; *) signers+=(--signing-key-file "$CK_WORK/stake.skey") ;; esac ;;
    withdrawal) extra+=(--withdrawal "$(< "$CK_WORK/reward.addr")+1000000"); signers+=(--signing-key-file "$CK_WORK/stake.skey") ;;
    vote) ck_require_file "$CK_WORK/vote-yes.cert" || return 78; extra+=(--vote-file "$CK_WORK/vote-yes.cert"); signers+=(--signing-key-file "$CK_WORK/drep.skey") ;;
  esac
  case "$kind" in
    stake-reg) deposit=2000000 ;; stake-dereg) credit=2000000 ;;
    drep-reg|pool-reg) deposit=500000000 ;; drep-retire) credit=500000000 ;;
    withdrawal) credit=1000000 ;;
  esac
  witnesses=$((${#signers[@]}/2))
  [[ "$kind" == no-expiry ]] || extra+=(--invalid-hereafter 123456789)
  extra+=(--required-signer-hash "$(< "$CK_WORK/payment.hash")")
  for ((i=0;i<12;i++)); do
    change=$((input_coin+credit-deposit-amount-fee))
    local out="$addr+$amount"
    [[ "$kind" != assets && "$kind" != mint ]] || out+=" + $quantity $policy.74657374"
    ck_cli "$dir/out" latest transaction build-raw --tx-in "$input" "${extra[@]}" --tx-out "$out" --tx-out "$addr+$change" --fee "$fee" --out-canonical-cbor --out-file "$dir/body.json" || return
    ck_cli "$dir/fee" latest transaction calculate-min-fee --tx-body-file "$dir/body.json" --tx-in-count 1 --tx-out-count 2 --witness-count "$witnesses" --byron-witness-count 0 --reference-script-size 0 --protocol-params-file "$CK_HOME/lib/data/protocol.json" --output-text || return
    local fee_text=''; fee_text="$(< "$dir/fee")"
    [[ "$fee_text" =~ ^[0-9]+[[:space:]]+Lovelace$ ]] || { ck_note 'Expected calculate-min-fee output: <integer> Lovelace'; return 1; }
    next="${fee_text%% *}"
    [[ "$fee" != "$next" ]] || break
    fee="$next"
  done
  (( i<12 )) || { ck_note 'Exact fee did not converge'; return 1; }
  ck_cli "$dir/out" latest transaction sign --tx-body-file "$dir/body.json" "${signers[@]}" "${CK_NET[@]}" --out-file "$dir/signed.json" || return
  ck_cli "$dir/view.json" debug transaction view --tx-file "$dir/signed.json" --output-json || return
  ck_assert "$dir/view.json" '(.inputs|length)==1 and (.outputs|length)==2 and .era=="Conway"' 'Decoded Conway inputs and outputs' || return
  ck_assert "$dir/view.json" ".fee==\"$fee Lovelace\" and ([.outputs[].amount.lovelace]|add)==$((input_coin+credit-deposit-fee))" 'Exact fee and ADA conservation including deposits/refunds/withdrawals' || return
  if [[ "$kind" == no-expiry ]]; then ck_assert "$dir/view.json" '.["validity range"]["upper bound"]==null' 'No expiry in decoded body' || return
  else ck_assert "$dir/view.json" '.["validity range"]["upper bound"]==123456789' 'Expiry preserved in decoded body' || return; fi
  # The ledger size excludes the one-byte IsValid boolean in the wire envelope.
  # This is an independent assertion, never extra budget added to a fee.
  actual="$(jq -r --slurpfile p "$CK_HOME/lib/data/protocol.json" '(.cborHex|length/2-1)*$p[0].txFeePerByte+$p[0].txFeeFixed' "$dir/signed.json")"
  [[ "$fee" == "$actual" ]] || { printf 'Signed minimum mismatch: built=%s, signed ledger-size minimum=%s\n' "$fee" "$actual"; return 1; }
  if [[ "$kind" == assets || "$kind" == mint ]]; then
    cntools_json_exact_integer_strings < "$dir/view.json" > "$dir/exact.json"
    ck_assert "$dir/exact.json" ".outputs[0].amount[\"policy $policy\"][\"asset 74657374 (test)\"]==\"$quantity\"" 'Exact asset quantity above 2^53' || return
  fi
  ck_cli "$dir/body.id" latest transaction txid --tx-body-file "$dir/body.json" --output-text || return
  ck_cli "$dir/signed.id" latest transaction txid --tx-file "$dir/signed.json" --output-text || return
  [[ "$(< "$dir/body.id")" == "$(< "$dir/signed.id")" && "$(< "$dir/body.id")" =~ ^[0-9a-f]{64}$ ]] || { ck_note 'Transaction ID text format or signed/body identity mismatch'; return 1; }
  local -a witness_args=(); local key='' index=0
  for ((index=0;index<${#signers[@]};index+=2)); do
    key="${signers[index+1]}"
    ck_cli "$dir/out" latest transaction witness --tx-body-file "$dir/body.json" --signing-key-file "$key" "${CK_NET[@]}" --out-file "$dir/witness-$index.json" || return
    ck_envelope "$dir/witness-$index.json" || return
    witness_args+=(--witness-file "$dir/witness-$index.json")
  done
  ck_cli "$dir/out" latest transaction assemble --tx-body-file "$dir/body.json" "${witness_args[@]}" --out-file "$dir/assembled.json" || return
  [[ "$(jq -r .cborHex "$dir/assembled.json")" == "$(jq -r .cborHex "$dir/signed.json")" ]] || { ck_note 'Detached-witness assembly differs from direct signing'; return 1; }
  printf 'Exact fee: %s lovelace · witnesses: %s · transaction ID: %s\n' "$fee" "$witnesses" "$(< "$dir/body.id")"
  cp "$dir/view.json" "$CK_CASE_DIR/decoded.json"
}
ck_cli_minimum_ada() {
  ck_require_file "$CK_WORK/base.addr" || return 78
  local addr='' plain='' assets='' policy='' minimum=''
  addr="$(< "$CK_WORK/base.addr")"
  policy="$(printf 'cd%.0s' {1..28})"
  ck_cli "$CK_WORK/minimum-plain" latest transaction calculate-min-required-utxo --protocol-params-file "$CK_HOME/lib/data/protocol.json" --tx-out "$addr+10000000" || return
  ck_cli "$CK_WORK/minimum-assets" latest transaction calculate-min-required-utxo --protocol-params-file "$CK_HOME/lib/data/protocol.json" --tx-out "$addr+10000000 + 1 $policy.74657374" || return
  plain="$(< "$CK_WORK/minimum-plain")"; assets="$(< "$CK_WORK/minimum-assets")"
  [[ "$plain" =~ ^(Lovelace|Coin)[[:space:]]+([0-9]+)$ ]] || { ck_note 'Unexpected minimum-ADA output'; return 1; }; minimum="${BASH_REMATCH[2]}"
  [[ "$assets" =~ ^(Lovelace|Coin)[[:space:]]+([0-9]+)$ ]] || { ck_note 'Unexpected token minimum-ADA output'; return 1; }
  (( BASH_REMATCH[2] > minimum && minimum > 0 )) || { ck_note 'Token minimum-ADA should exceed an equivalent ADA-only output'; return 1; }
}
ck_cli_estimate() {
  ck_require_file "$CK_WORK/base.addr" || return 78
  local addr='' input=''; addr="$(< "$CK_WORK/base.addr")"; input="$(printf '00%.0s' {1..32})#0"
  ck_cli "$CK_WORK/estimate-out" latest transaction build-estimate --tx-in "$input" --total-utxo-value 50000000 \
    --tx-out "$addr+10000000" --change-address "$addr" --protocol-params-file "$CK_HOME/lib/data/protocol.json" \
    --shelley-key-witnesses 1 --byron-key-witnesses 0 --out-canonical-cbor --out-file "$CK_WORK/estimated.json" || return
  ck_envelope "$CK_WORK/estimated.json" || return
  ck_cli "$CK_CASE_DIR/decoded.json" debug transaction view --tx-body-file "$CK_WORK/estimated.json" --output-json || return
  ck_assert "$CK_CASE_DIR/decoded.json" '(.outputs|length)==2 and (.fee|test("^[0-9]+ Lovelace$")) and ([.outputs[].amount.lovelace]|add)+(.fee|split(" ")[0]|tonumber)==50000000' 'Estimate builder output fee and change conservation'
}
ck_cli_help() { ck_cli "$CK_WORK/help" "$@" --help; }
ck_suite_cli() {
  ck_run cli-version 'Version and candidate/pin distinction' executed ck_cli_version
  local role='' kind=''
  for role in payment stake drep; do ck_run "cli-key-$role" "$role key generation and pair validation" executed ck_cli_key "$role"; done
  ck_run cli-addresses 'Addresses, credentials, network headers and DRep ID' executed ck_cli_addresses
  ck_run cli-mnemonic '24-word generation and payment/stake/DRep derivation' executed ck_cli_mnemonic
  ck_run cli-pool-keys 'Pool, VRF, KES, counter and disposable opcert' executed ck_cli_pool_keys
  ck_run cli-metadata 'Pool metadata, DRep metadata and anchor hashing' executed ck_cli_metadata
  for kind in stake-reg stake-dereg stake-delegate vote-delegate vote-abstain vote-no-confidence register-delegate register-vote drep-reg drep-update drep-retire pool-reg pool-retire vote-yes vote-no vote-abstain-decision; do
    ck_run "cli-cert-$kind" "$kind certificate/vote creation" executed ck_cli_cert "$kind"
  done
  for kind in ada no-expiry assets mint multisig metadata detailed-metadata stake-reg stake-dereg stake-delegate vote-delegate drep-reg drep-update drep-retire pool-reg pool-retire withdrawal vote; do
    ck_run "cli-tx-$kind" "$kind — build, decode, exact fee, sign and assemble" executed ck_cli_transaction "$kind"
  done
  ck_run cli-build 'Online auto-balancer command availability (not node exercised)' syntax ck_cli_help latest transaction build
  ck_run cli-minimum-ada 'Minimum ADA for plain and token outputs' executed ck_cli_minimum_ada
  ck_run cli-estimate 'Estimate-builder with disposable inputs and protocol parameters' executed ck_cli_estimate
  ck_run cli-submit 'Submission command availability (never submitted)' syntax ck_cli_help latest transaction submit
  ck_run cli-submit-acceptance 'Ledger submission acceptance' integration ck_skip 'Requires a separate isolated funded integration environment. This checker never submits.'
}
