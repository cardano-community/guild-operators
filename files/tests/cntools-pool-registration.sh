#!/usr/bin/env bash
# Pool certificate/state/UI contracts; optional node-free cnode CLI integration.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-pool-registration.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'chmod -R u+rwX "${TEST_ROOT}"; rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
for lib in number wallet wallet-material wallet-key wallet-mnemonic wallet-address wallet-id wallet-query utxo transaction transaction-build transaction-sign transaction-files transaction-funding transaction-ui coin-selection change-plan recipient wallet-payment wallet-register pool-id table pool pool-files pool-key pool-inspect pool-ui pool-parameters pool-registration pool-registration-keys pool-registration-ui pool-config pool-metadata pool-stake pool-opcert pool-wizard; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
fail() { printf 'FAIL: %s (%s / %s)\n' "$*" "${CNTOOLS_WALLET_REGISTER_ERROR:-}" "${CNTOOLS_TRANSACTION_ERROR:-}" >&2; tail -12 "${TEST_ROOT}/test.log" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
reject() { if "$@"; then fail "unexpected success: $*"; fi; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/test.log"; }
cntools_log_sanitize_line() { printf '%s' "${1//[[:cntrl:]]/ }"; }
cntools_run_command_timeout() { local mask="$2"; shift 3; (( ${#mask} == $# )) || fail 'audit mask mismatch'; printf '%q ' "$@" >> "${TEST_ROOT}/test.log"; printf '\n' >> "${TEST_ROOT}/test.log"; "$@"; }
cntools_funding_tip_into() { printf -v "$1" '%s' 1000; }
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)" REAL_LN="$(type -P ln)"
  chmod() { local arg=''; local -a args=(); for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done; "${REAL_CHMOD}" "${args[@]}"; }
  ln() { if [[ "${1:-}" == -T ]]; then shift; [[ ! -d "${3}" ]] || return 1; fi; "${REAL_LN}" "$@"; }
fi
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview CNTOOLS_MODE=light
CNTOOLS_LOG="${TEST_ROOT}/test.log" CNTOOLS_TRANSACTION_OPENSSL="${CNTOOLS_TEST_OPENSSL:-openssl}"
CNTOOLS_WALLET_DIR="${TEST_ROOT}/wallets" CNTOOLS_POOL_DIR="${TEST_ROOT}/pools"
CNTOOLS_WALLET_PAY_VKEY_FILENAME=payment.vkey CNTOOLS_WALLET_PAY_SKEY_FILENAME=payment.skey
CNTOOLS_WALLET_PAY_ADDR_FILENAME=payment.addr CNTOOLS_WALLET_PAY_CRED_FILENAME=payment.cred CNTOOLS_WALLET_PAY_SCRIPT_FILENAME=payment.script
CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey CNTOOLS_WALLET_STAKE_SKEY_FILENAME=stake.skey
CNTOOLS_WALLET_STAKE_ADDR_FILENAME=stake.addr CNTOOLS_WALLET_STAKE_CRED_FILENAME=stake.cred CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME=stake.script
CNTOOLS_WALLET_BASE_ADDR_FILENAME=base.addr CNTOOLS_WALLET_DERIVATION_PATH_FILENAME=derivation.path
CNTOOLS_WALLET_PAY_SCRIPT_CRED_FILENAME=payment-script.cred CNTOOLS_WALLET_STAKE_SCRIPT_CRED_FILENAME=stake-script.cred
CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME=payment.hwsfile CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hwsfile
CNTOOLS_TX_SELECTION_STRATEGY=balanced CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_TOKEN_MAX_ASSETS=20
CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N CNTOOLS_TX_UTXO_TARGET_COUNT=4 CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30

margin=''; cntools_pool_margin_into margin '2.500001' || fail 'margin parsing'
eq "${margin}" 2500001/100000000 'exact percentage conversion'
eq "$(cntools_pool_margin_number "${margin}")" 0.02500001
reject cntools_pool_margin_into margin 100.000001
reject cntools_pool_parameter_uint 9007199254740992
reject cntools_pool_relay_valid '{"type":"ip","ipv4":"999.1.2.3","ipv6":"","port":3001}'
reject cntools_pool_relay_valid '{"type":"dns","dns":"relay.example","port":0}'
cntools_pool_relay_valid '{"type":"srv","dns":"_cardano._tcp.example.com"}' || fail 'SRV validation'
ipv6=''; cntools_pool_ipv6_into ipv6 '2001:0DB8:0:0:0:0:0:1'
eq "${ipv6}" '2001:db8::1' 'canonical IPv6'
cntools_pool_ipv6_into ipv6 '::'; eq "${ipv6}" '::' 'all-zero IPv6'
cntools_pool_ipv6_into ipv6 '2001:db8:0:1:1:1:1:1'; eq "${ipv6}" '2001:db8:0:1:1:1:1:1' 'single zero not compressed'
for invalid_ip in '2001::db8::1' '2001:db8::1:' '1:2:3' ':::1' '1:2:3:4:5:6:7:8:9'; do reject cntools_pool_ipv6_into ipv6 "${invalid_ip}"; done
reject cntools_pool_relay_valid '{"type":"dns","dns":".","port":3001}'
reject cntools_pool_relay_valid '{"type":"ip","ipv4":"192.000.002.001","ipv6":"","port":3001}'
reject cntools_pool_metadata_valid '{"url":"https://example.com/pool.json","hash":"bad"}'
hash="$(printf 'ab%.0s' {1..28})" vrf="$(printf 'cd%.0s' {1..32})"
CNTOOLS_POOL_NAMES=(Example); CNTOOLS_POOL_REG_INDEX=0
CNTOOLS_POOL_CHAIN_STATUS=(Registered) CNTOOLS_POOL_CHAIN_SOURCE=('Local node') CNTOOLS_POOL_FUTURE=('{}') CNTOOLS_POOL_RETIREMENT=('')
CNTOOLS_POOL_CURRENT=("$(jq -cn --arg hash "${hash}" --arg vrf "${vrf}" '{spsPledge:100000000,spsCost:170000000,spsMargin:0.025,spsVrf:$vrf,
  spsAccountId:{keyHash:$hash},spsOwners:[$hash],spsRelays:[],spsMetadata:null}')")
state=''; cntools_pool_registration_state_into state || fail 'local state output'
jq -e '.registered and .current.pledgeLovelace == "100000000"' <<< "${state}" >/dev/null || fail 'canonical state'
CNTOOLS_POOL_CHAIN_STATUS=(Unavailable); reject cntools_pool_registration_state_into state
CNTOOLS_POOL_CHAIN_STATUS=('Not registered'); cntools_pool_registration_state_into state
eq "${state}" '{"registered":false}'
# Public-only owners remain in defaults instead of being silently removed.
CNTOOLS_POOL_REG_STATE="$(jq -cn --arg hash "${hash}" --arg vrf "${vrf}" '{registered:true,current:{pledgeLovelace:"1",costLovelace:"170000000",margin:"0.025",reward:$hash,owners:[$hash],relays:[],metadata:null,vrf:$vrf},
  pending:{spsPledge:200000000,spsCost:190000000,spsMargin:0.03,spsAccountId:{keyHash:$hash},spsOwners:[$hash],spsRelays:[],spsMetadata:null}}')"
CNTOOLS_WALLET_NAMES=() CNTOOLS_WALLET_PATHS=()
cntools_pool_registration_defaults || fail 'pending defaults'
eq "${CNTOOLS_POOL_REG_PLEDGE}" 200000000 'pending pledge preserved'
eq "$(jq -r '.[0].hash' <<< "${CNTOOLS_POOL_REG_OWNERS}")" "${hash}" 'missing owner retained'
reject cntools_pool_parameters_json
# UI output must reach its caller, and cancelling a picker changes no settings.
(
  cntools_ui_choose() { printf -v "$1" '%s' 'CNTools wallet'; }
  cntools_wallet_choose() { printf -v "$1" '%s' 0; }
  cntools_pool_wallet_stake_record_into() { printf -v "$1" '%s' '{"hash":"test"}'; }
  record=''; cntools_pool_registration_select_stake_into record Test
  eq "${record}" '{"hash":"test"}' 'UI selected stake output'
  cntools_ui_choose() { printf -v "$1" '%s' Cancel; }
  reject cntools_pool_registration_select_stake_into record Test
)
(
  cntools_transaction_source_kind_into() { printf -v "$1" '%s' hardware; }
  CNTOOLS_POOL_REG_COMBINE_HARDWARE=N
  group=''; cntools_pool_registration_group_into group /test/cold.hwsfile pool-cold
  eq "${group}" pool-cold 'hardware session output'
  CNTOOLS_POOL_REG_COMBINE_HARDWARE=Y
  cntools_pool_registration_group_into group /test/cold.hwsfile pool-cold
  eq "${group}" pool-operator 'combined operator hardware session'
  cntools_pool_registration_group_into group /test/stake.hwsfile owner-test
  eq "${group}" owner-test 'owners never batched with operator'
)
# Live protocol deposit versus modification, and immutable reviewed state.
(
  test_ref="$(printf 'ee%.0s' {1..32})#0"
  fixture_state='{"registered":false}' fixture_backend=local fixture_slot=1000 fixture_spent=N
  fixture_protocol="${TEST_ROOT}/protocol.json"
  cp "${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json" "${fixture_protocol}"
  cntools_funding_collect() {
    CNTOOLS_FUNDING_BACKEND="${fixture_backend}" CNTOOLS_FUNDING_PROTOCOL="${fixture_protocol}" CNTOOLS_FUNDING_SLOT="${fixture_slot}"
    cntools_utxo_reset
    [[ "${fixture_spent}" == Y ]] || cntools_utxo_add "${test_ref}" addr_test1fixture 600000000
  }
  cntools_pool_registration_query_state_into() { printf -v "$1" '%s' "${fixture_state}"; }
  cntools_pool_registration_operation_set pool-register
  CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=addr_test1fixture CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS=addr_test1fixture
  cntools_pool_registration_collect || fail 'registration collection'
  eq "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" 500000000 'live pool deposit'
  fixture_state="$(jq -cn --arg vrf "${vrf}" '{registered:true,current:{vrf:$vrf}}')"
  reject cntools_pool_registration_collect
  cntools_pool_registration_operation_set pool-modify
  CNTOOLS_POOL_REG_VRF_HASH="${vrf}"
  cntools_pool_registration_collect || fail 'modify collection'
  eq "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" 0 'no modification deposit'
  CNTOOLS_WALLET_REGISTER_EXPIRY=2800
  cntools_pool_registration_recheck || fail 'unchanged recheck'
  fixture_state='{"registered":false}'; reject cntools_pool_registration_recheck
  fixture_state="${CNTOOLS_POOL_REG_STATE}"
  fixture_spent=Y; reject cntools_pool_registration_recheck; fixture_spent=N
  fixture_backend=koios; reject cntools_pool_registration_recheck; fixture_backend=local
  fixture_slot=2800; reject cntools_pool_registration_recheck; fixture_slot=1000
  jq '.stakePoolDeposit=600000000' "${fixture_protocol}" > "${TEST_ROOT}/changed.json"
  fixture_protocol="${TEST_ROOT}/changed.json"; reject cntools_pool_registration_recheck
  fixture_protocol="${TEST_ROOT}/protocol.json"
  fixture_state='{"registered":false}'; reject cntools_pool_registration_collect
  fixture_state="$(jq -cn --arg vrf "$(printf 'aa%.0s' {1..32})" '{registered:true,current:{vrf:$vrf}}')"
  reject cntools_pool_registration_collect
)
printf 'CNTools pool registration deterministic tests passed.\n'
# Wizard defaults, status-filtered picker and optional owner/reward checks.
(
  CNTOOLS_POOL_REG_MIN_COST=170000000 CNTOOLS_POOL_REG_STATE='{"registered":false}'
  cntools_pool_registration_defaults
  eq "${CNTOOLS_POOL_REG_PLEDGE}" 50000000000 'legacy 50,000 ADA pledge'
  eq "$(cntools_pool_margin_number "${CNTOOLS_POOL_REG_MARGIN}")" 0.075 'legacy 7.5% margin'
  cntools_ui_spin_function() { shift; "$@"; }
  cntools_pool_inspect_catalog() { :; }
  CNTOOLS_POOL_NAMES=(New Existing Retiring Broken Lagging)
  CNTOOLS_POOL_IDENTITIES=('Verified cold public key' 'Verified cold public key' 'Verified cold public key' 'Verified cold public key' 'Verified cold public key')
  CNTOOLS_POOL_CHAIN_STATUS=('Not registered' Registered Retiring Unavailable 'Not indexed')
  cntools_ui_choose() {
    [[ "$*" != *Broken* ]] || fail 'unavailable pool offered'
    case "${CNTOOLS_WALLET_REGISTER_OPERATION}" in
      pool-register) [[ "$*" != *Existing* && "$*" != *Retiring* ]] || fail 'registered pool in register picker'; printf -v "$1" '%s' 'New · Not registered' ;;
      pool-modify) [[ "$*" != *New* && "$*" != *Lagging* ]] || fail 'unregistered pool in modify picker'; printf -v "$1" '%s' 'Retiring · Retiring' ;;
    esac
  }
  CNTOOLS_WALLET_REGISTER_OPERATION='pool-register'; picked=''; cntools_pool_registration_choose_eligible_into picked; eq "${picked}" 0 'register eligibility'
  CNTOOLS_WALLET_REGISTER_OPERATION='pool-modify'; cntools_pool_registration_choose_eligible_into picked; eq "${picked}" 2 'modify eligibility'
)
(
  CNTOOLS_POOL_REG_OWNERS="$(jq -cn --arg hash "${hash}" '[{label:"Owner",hash:$hash,address:"stake_test1fixture",source:"",vkey:""}]')"
  cntools_pool_reward_record_use "$(jq -c '.[0]' <<< "${CNTOOLS_POOL_REG_OWNERS}")"
  CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_KOIOS_API=https://example.com/api/v1
  calls=0
  cntools_wallet_query_http() {
    calls=$((calls+1)); eq "$(jq '._stake_addresses|length' <<< "$2")" 1 'owner/reward deduplicated request'
    case "${fixture_response}" in
      empty) printf '[]' > "$3" ;;
      valid) printf '[{"stake_address":"stake_test1fixture","status":"registered","delegated_pool":null,"utxo":"9007199254740993","rewards_available":"7"}]' > "$3" ;;
      malformed) printf '[{"stake_address":"wrong"}]' > "$3" ;;
      failure) return 22 ;;
    esac
  }
  fixture_response=valid; cntools_pool_stake_collect
  eq "${calls}" 1 'one bulk call'; eq "${CNTOOLS_POOL_STAKE_BALANCE[${hash}]}" 9007199254741000 'exact pledge sum'
  fixture_response=empty; cntools_pool_stake_collect; eq "${CNTOOLS_POOL_STAKE_STATUS[${hash}]}" no 'empty response is unregistered'
  fixture_response=malformed; cntools_pool_stake_collect; eq "${CNTOOLS_POOL_STAKE_STATUS[${hash}]}" unknown 'malformed response not unregistered'
  fixture_response=failure; cntools_pool_stake_collect; eq "${CNTOOLS_POOL_STAKE_STATUS[${hash}]}" unknown 'HTTP failure not unregistered'
  CNTOOLS_POOL_STAKE_PLAN="$(jq -c 'map(.+{previousRegistered:"no",previousDelegation:""})' <<< "${CNTOOLS_POOL_REG_OWNERS}")"
  fixture_response=empty; cntools_pool_stake_recheck
  fixture_response=valid; reject cntools_pool_stake_recheck
  CNTOOLS_POOL_REG_POOL_DEPOSIT=500000000 CNTOOLS_WALLET_REGISTER_OPERATION='pool-register'
  CNTOOLS_POOL_REG_COLD_SOURCE='' CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE=''
  cntools_ui_render_status() { :; }
  cntools_pool_stake_setup_choose; eq "${CNTOOLS_POOL_STAKE_PLAN}" '[]' 'public-only separate setup'; eq "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" 500000000 'pool-only deposit'
  other_hash="$(printf 'cd%.0s' {1..28})"
  CNTOOLS_POOL_REG_OWNERS="$(jq -cn --arg hash "${hash}" '[{label:"Owner",hash:$hash,address:"stake_test1owner",source:"owner.skey",vkey:"owner.vkey"}]')"
  cntools_pool_reward_record_use "$(jq -cn --arg hash "${other_hash}" '{label:"Reward",hash:$hash,address:"stake_test1reward",source:"reward.skey",vkey:"reward.vkey"}')"
  CNTOOLS_POOL_REG_COLD_SOURCE=cold.skey CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE=payment.skey
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
  CNTOOLS_POOL_STAKE_STATUS["${hash}"]=no CNTOOLS_POOL_STAKE_STATUS["${other_hash}"]=no
  cntools_transaction_source_kind_into() { printf -v "$1" '%s' "${fixture_key_kind}"; }
  cntools_ui_choose() { printf -v "$1" '%s' "$3"; }
  fixture_key_kind=cli; cntools_pool_stake_setup_choose
  eq "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" 504000000 'pool + main owner + reward deposits'
  eq "$(jq length <<< "${CNTOOLS_POOL_STAKE_PLAN}")" 2 'approved setup records'
  cntools_pool_stake_setup_choose; eq "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" 504000000 're-edit does not double charge'
  fixture_key_kind=hardware; cntools_pool_stake_setup_choose
  eq "${CNTOOLS_POOL_STAKE_PLAN}" '[]' 'hardware separate setup'; eq "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" 500000000 'hardware deposit unchanged'
)
printf 'CNTools pool wizard deterministic tests passed.\n'
(( $# > 0 )) || exit 0

CNTOOLS_CLI="$1" PINNED_HWCLI="${2:-}"
version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
eq "${version}" "$(jq -r '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")" 'cnode CLI pin'
mkdir -m 700 "${CNTOOLS_WALLET_DIR}" "${CNTOOLS_POOL_DIR}"
for name in Funding Owner Reward; do
  mkdir -m 700 "${CNTOOLS_WALLET_DIR}/${name}"
  "${CNTOOLS_CLI}" address key-gen --signing-key-file "${CNTOOLS_WALLET_DIR}/${name}/payment.skey" --verification-key-file "${CNTOOLS_WALLET_DIR}/${name}/payment.vkey"
  "${CNTOOLS_CLI}" latest stake-address key-gen --signing-key-file "${CNTOOLS_WALLET_DIR}/${name}/stake.skey" --verification-key-file "${CNTOOLS_WALLET_DIR}/${name}/stake.vkey"
done
pool="${CNTOOLS_POOL_DIR}/Example"; mkdir -m 700 "${pool}"
"${CNTOOLS_CLI}" latest node key-gen --cold-signing-key-file "${pool}/cold.skey" --cold-verification-key-file "${pool}/cold.vkey" --operational-certificate-issue-counter-file "${pool}/cold.counter"
"${CNTOOLS_CLI}" latest node key-gen-VRF --signing-key-file "${pool}/vrf.skey" --verification-key-file "${pool}/vrf.vkey"
"${CNTOOLS_CLI}" latest node key-gen-KES --signing-key-file "${pool}/hot.skey" --verification-key-file "${pool}/hot.vkey"
cntools_pool_catalog_build; cntools_pool_registration_prepare_identity 0 || fail 'pool identity'
cntools_wallet_catalog_build
funding_index="$(printf '%s\n' "${CNTOOLS_WALLET_NAMES[@]}" | awk '/^Funding$/{print NR-1}')"
owner_index="$(printf '%s\n' "${CNTOOLS_WALLET_NAMES[@]}" | awk '/^Owner$/{print NR-1}')"
reward_index="$(printf '%s\n' "${CNTOOLS_WALLET_NAMES[@]}" | awk '/^Reward$/{print NR-1}')"
cntools_pool_registration_prepare_funding "${CNTOOLS_WALLET_PATHS[funding_index]}" || fail 'funding identity'
owner_record='' reward_record='' funding_record=''
cntools_pool_wallet_stake_record_into owner_record "${owner_index}" || fail 'owner identity'
cntools_pool_wallet_stake_record_into reward_record "${reward_index}" || fail 'reward identity'
cntools_pool_wallet_stake_record_into funding_record "${funding_index}" || fail 'funding owner identity'
reward_hash=''; cntools_wallet_reward_credential_into reward_hash "$(jq -r .address <<< "${reward_record}")"
eq "${reward_hash}" "$(jq -r .hash <<< "${reward_record}")" 'Bech32 reward hash decoder'
(
  # Koios publishes Bech32 owner/reward accounts, not ledger credential objects.
  CNTOOLS_POOL_CHAIN_SOURCE[0]='Koios API'; CNTOOLS_POOL_CHAIN_STATUS[0]=Registered
  CNTOOLS_POOL_CURRENT[0]="$(jq -cn --arg reward "$(jq -r .address <<< "${reward_record}")" \
    --arg owner "$(jq -r .address <<< "${owner_record}")" --arg vrf "${CNTOOLS_POOL_REG_VRF_HASH}" \
    '{reward_addr:$reward,owners:[$owner],vrf_key_hash:$vrf,pledge:"100000000",fixed_cost:"170000000",margin:0.025,
      retiring_epoch:null,meta_url:null,meta_hash:null,relays:[{dns:"relay.example.com",srv:null,ipv4:null,ipv6:null,port:3001}],
      block_count:1,live_stake:"100000000"}')"
  koios_state=''; cntools_pool_registration_state_into koios_state || fail 'Koios registration mapping'
  jq -e --arg owner "$(jq -r .hash <<< "${owner_record}")" --arg reward "${reward_hash}" \
    '.current.owners == [$owner] and .current.reward == $reward and .current.metadata == null and
      .current.relays == [{"single host name":{dnsName:"relay.example.com",port:3001}}]' \
    <<< "${koios_state}" >/dev/null || fail 'Koios owner/reward/relay conversion'
  CNTOOLS_POOL_CURRENT[0]="$(jq -c '.block_count=2|.live_stake="200000000"' <<< "${CNTOOLS_POOL_CURRENT[0]}")"
  later_state=''; cntools_pool_registration_state_into later_state || fail 'Koios advancing statistics'
  eq "${later_state}" "${koios_state}" 'statistics do not invalidate review'
)
printf '{"name":"Example","description":"Test pool","ticker":"TEST","homepage":"https://example.com"}\n' > "${TEST_ROOT}/metadata.json"
metadata_hash=''; cntools_pool_metadata_file_hash_into metadata_hash "${TEST_ROOT}/metadata.json" || fail 'metadata hashing'
eq "${metadata_hash}" "$("${CNTOOLS_CLI}" latest stake-pool metadata-hash --pool-metadata-file "${TEST_ROOT}/metadata.json")"
eq "${metadata_hash}" "$("${CNTOOLS_CLI}" hash anchor-data --file-binary "${TEST_ROOT}/metadata.json")" 'raw Blake2b-256 is identical to metadata hash'
# Real metadata author/hash, legacy/new configuration reuse, first opcert issuance.
(
  CNTOOLS_POOL_REG_OWNERS="[${owner_record}]"; cntools_pool_reward_record_use "${reward_record}"
  CNTOOLS_POOL_REG_PLEDGE=50000000000 CNTOOLS_POOL_REG_COST=170000000 CNTOOLS_POOL_REG_MARGIN=7500000/100000000
  CNTOOLS_POOL_REG_METADATA=null CNTOOLS_POOL_REG_RELAYS='[{"type":"dns","dns":"relay.example.com","port":3001}]'
  CNTOOLS_POOL_REG_MIN_COST=170000000
  cntools_pool_config_save || fail 'save wizard draft'
  jq -e '(.owners[0]|has("source") or has("vkey")|not) and .status == "Local draft; not proof of submission"' "${pool}/pool.config" >/dev/null || fail 'no transient/private references in config'
  CNTOOLS_POOL_REG_PLEDGE=0; cntools_pool_config_load || fail 'reload draft'; eq "${CNTOOLS_POOL_REG_PLEDGE}" 50000000000 'draft reuse'
  cntools_pool_config_save; [[ -f "${pool}/pool.config.previous" ]] || fail 'config backup'
  # Legacy migration keeps wallet identities and DNS/IP/SRV selections.
  printf '{"pledgeADA":50000,"costADA":170,"margin":7.5,"owners":[{"wallet_name":"Owner"}],"rewardWallet":"Reward","json_url":"https://example.com/legacy.json","relays":[{"type":"DNS_A","address":"relay.example.com","port":3001}]}' > "${pool}/pool.config"
  cntools_pool_config_load || fail 'legacy config'; eq "${CNTOOLS_POOL_REG_METADATA_URL}" https://example.com/legacy.json 'legacy metadata URL'
  cntools_pool_config_save || fail 'migrated draft'
  config_rows="$(cntools_pool_settings_rows "$(< "${pool}/pool.config")" config)"
  [[ "${config_rows}" == *'50,000.000000 ADA'* ]] || fail 'new config visible in Pool Show'
  (
    CNTOOLS_POOL_COLD_SKEY_FILENAME=pool.config.previous
    reject cntools_pool_filenames_validate
  )
  # Extended metadata is accepted up to 1024 bytes, without relaxing ordinary 512.
  jq -n '{name:("N"*50),ticker:"TEST",description:("D"*255),homepage:("https://example.com/"+("h"*40)),extended:("https://example.com/"+("e"*100)),nonce:"0123456789"}' > "${TEST_ROOT}/extended.json"
  (( $(wc -c < "${TEST_ROOT}/extended.json") > 512 )) || fail 'extended fixture too small'
  extended_hash=''; cntools_pool_metadata_file_hash_into extended_hash "${TEST_ROOT}/extended.json" || fail 'pinned extended metadata hash'
  jq 'del(.extended)|.nonce=("n"*300)' "${TEST_ROOT}/extended.json" > "${TEST_ROOT}/oversized.json"
  reject cntools_pool_metadata_file_hash_into extended_hash "${TEST_ROOT}/oversized.json"
  # Author inputs are public, escaped as JSON, and reach caller despite file-name shadowing.
  cntools_ui_render_status() { :; }; cntools_ui_wait() { :; }
  cntools_ui_input() {
    case "$2" in 'Pool name'*) printf -v "$1" '%s' 'Test "Pool"' ;; Ticker*) printf -v "$1" '%s' test ;;
      Description*) printf -v "$1" '%s' 'Description' ;; Homepage*) printf -v "$1" '%s' https://example.com ;;
      Extended*) printf -v "$1" '%s' https://example.com/extended.json ;;
    esac
  }
  file=''; cntools_pool_metadata_author_into file '{}' || fail 'authoring'; jq -e '.name == "Test \"Pool\"" and .ticker == "TEST"' "${file}" >/dev/null || fail 'author result'
  # Do not pass authorization headers to a metadata host.
  CNTOOLS_KOIOS_TOKEN=secret
  cntools_api_request() { [[ "$*" != *secret* && "$*" != *Authorization* ]] || fail 'metadata credential leak'; cp "${TEST_ROOT}/metadata.json" "$3"; }
  file=''; cntools_pool_metadata_download_into file https://example.com/pool.json; [[ -s "${file}" ]] || fail 'download result'
  reject cntools_pool_metadata_download_into file https://user:secret@example.com/pool.json
  CNTOOLS_SLOTS_PER_KES_PERIOD=129600 CNTOOLS_WALLET_REGISTER_BACKEND=koios
  period=''; cntools_pool_kes_period_into period; eq "${period}" 0 'KES period from tip'
  old_counter="$(jq -r .cborHex "${pool}/cold.counter")"
  cntools_pool_opcert_issue 0 || fail 'first operational certificate'
  [[ -s "${pool}/op.cert" && "$(< "${pool}/kes.start")" == 0 ]] || fail 'opcert/start publication'
  [[ "$(jq -r .cborHex "${pool}/cold.counter")" != "${old_counter}" ]] || fail 'counter not advanced'
  cntools_pool_public_records_prepare "${pool}" || fail 'opcert binding'
  reject cntools_pool_opcert_issue 0
  [[ "$(jq -r .cborHex "${pool}/cold.counter.previous")" == "${old_counter}" ]] || fail 'original counter backup'
  # A publication failure must retain the issued counter/cert and prevent retry.
  failure_pool="${CNTOOLS_POOL_DIR}/Interrupted"; mkdir -m 700 "${failure_pool}"
  cp "${pool}/cold.vkey" "${pool}/hot.vkey" "${pool}/cold.counter" "${failure_pool}/"
  CNTOOLS_POOL_DIRECTORIES[0]="${failure_pool}"
  cntools_pool_public_save() { return 1; }
  reject cntools_pool_opcert_issue 0
  [[ -d "${failure_pool}/.cntools-opcert-lock" && -s "${CNTOOLS_POOL_OPCERT_RECOVERY}/op.cert" &&
     -s "${CNTOOLS_POOL_OPCERT_RECOVERY}/cold.counter" && ! -e "${failure_pool}/op.cert" ]] || fail 'interrupted issuance lost recovery/lock'
  reject cntools_pool_opcert_issue 0
)
reference="$(printf 'ab%.0s' {1..32})#0" policy="$(printf 'cd%.0s' {1..28})"
package='' signed='' view='' fee='' size='' sum=''
read -r -a scenarios <<< "${CNTOOLS_POOL_TEST_SCENARIOS:-ada tokens no-expiry offline two-owners stake-setup}"
for scenario in "${scenarios[@]}"; do
  case "${scenario}" in ada|tokens|no-expiry|offline|two-owners|stake-setup) ;; *) fail 'unknown pool test scenario' ;; esac
done
for operation in pool-register pool-modify; do
  for scenario in "${scenarios[@]}"; do
    # Isolate temporary tracking per scenario. Shared key fixtures remain in the
    # initial workspace; the EXIT trap owns and removes every scenario workspace.
    CNTOOLS_TRANSACTION_TEMP_FILES=(); CNTOOLS_TRANSACTION_TEMP_DIR=''; CNTOOLS_TRANSACTION_TEMP_BASE=''
    cntools_pool_registration_operation_set "${operation}"
    cntools_wallet_register_reset_chain_state
    CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_WALLET_REGISTER_SOURCE=Fixture
    CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
    CNTOOLS_POOL_REG_MIN_COST=75000000 CNTOOLS_WALLET_REGISTER_DEPOSIT=0 CNTOOLS_POOL_REG_STATE='{"registered":true}'
    if [[ "${operation}" == pool-register ]]; then CNTOOLS_WALLET_REGISTER_DEPOSIT=500000000; CNTOOLS_POOL_REG_STATE='{"registered":false}'; fi
    CNTOOLS_POOL_REG_PLEDGE=100000000 CNTOOLS_POOL_REG_COST=170000000 CNTOOLS_POOL_REG_MARGIN=2500000/100000000
    CNTOOLS_POOL_REG_RELAYS='[{"type":"dns","dns":"relay.example.com","port":3001},{"type":"srv","dns":"_cardano._tcp.example.com"},{"type":"ip","ipv4":"192.0.2.1","ipv6":"","port":3001}]'
    if [[ "${scenario}" == tokens ]]; then
      CNTOOLS_POOL_REG_RELAYS="$(jq -c '.[2].ipv6="2001:0db8:0:0:0:0:0:1"' <<< "${CNTOOLS_POOL_REG_RELAYS}")"
    fi
    CNTOOLS_POOL_REG_METADATA="$(jq -cn --arg hash "${metadata_hash}" '{url:"https://example.com/pool.json",hash:$hash}')"
    CNTOOLS_POOL_REG_OWNERS='[]'; cntools_pool_owner_add "${owner_record}"; cntools_pool_reward_record_use "${reward_record}"
    [[ "${scenario}" != two-owners ]] || cntools_pool_owner_add "${funding_record}"
    CNTOOLS_POOL_REG_COLD_SOURCE="${pool}/cold.skey" CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE="${CNTOOLS_WALLET_DIR}/Funding/payment.skey"
    if [[ "${scenario}" == stake-setup && "${operation}" == pool-register ]]; then
      CNTOOLS_POOL_STAKE_PLAN="$(jq -cn --argjson owner "${owner_record}" --argjson reward "${reward_record}" \
        '[$owner+{setup:"delegate",previousRegistered:"no",previousDelegation:"",deposit:"2000000"},
         $reward+{setup:"register",previousRegistered:"no",previousDelegation:"",deposit:"2000000"}]')"
      CNTOOLS_WALLET_REGISTER_DEPOSIT=504000000
    fi
    if [[ "${scenario}" == offline ]]; then
      CNTOOLS_POOL_REG_COLD_SOURCE=''
      CNTOOLS_POOL_REG_OWNERS="$(jq -c 'map(.source="")' <<< "${CNTOOLS_POOL_REG_OWNERS}")"
    fi
    can_sign=''; cntools_pool_registration_can_sign_into can_sign
    if [[ "${scenario}" == offline ]]; then eq "${can_sign}" N; else eq "${can_sign}" Y; fi
    CNTOOLS_WALLET_REGISTER_LIFETIME=1800; [[ "${scenario}" != no-expiry ]] || CNTOOLS_WALLET_REGISTER_LIFETIME=0
    cntools_utxo_add "${reference}" "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" 600000000
    [[ "${scenario}" != tokens ]] || cntools_utxo_add_asset 0 "${policy}.01" 9007199254740993
    cntools_wallet_register_inventory_use_all
    cntools_pool_registration_build_into package || fail "build ${operation}/${scenario}"
    cntools_transaction_package_load "${package}" || fail 'package validation'
    cntools_pool_registration_validate_body "${CNTOOLS_TRANSACTION_BODY_FILE}" || fail 'certificate validation'
    expected=3; [[ "${scenario}" != two-owners ]] || expected=4
    [[ "${scenario}" != stake-setup || "${operation}" != pool-register ]] || expected=4
    eq "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" "${expected}" 'funding, cold, owners; no reward witness'
    if [[ -n "${PINNED_HWCLI}" ]]; then
      "${PINNED_HWCLI}" transaction transform --tx-file "${CNTOOLS_TRANSACTION_BODY_FILE}" --out-file "${TEST_ROOT}/hardware.body"
      cntools_pool_registration_validate_body "${TEST_ROOT}/hardware.body" || fail 'hardware normalization changed params'
    fi
    cntools_transaction_view_into view "${CNTOOLS_TRANSACTION_BODY_FILE}"
    sum="$(jq '[.outputs[].amount.lovelace]|add' <<< "${view}")"; fee="$(jq -r '.fee|split(" ")[0]' <<< "${view}")"
    ((sum + fee + CNTOOLS_WALLET_REGISTER_DEPOSIT == 600000000)) || fail 'exact pool deposit conservation'
    [[ "${scenario}" != tokens || "${view}" == *9007199254740993* ]] || fail 'asset precision/conservation'
    if [[ "${scenario}" == no-expiry ]]; then eq "$(jq -r '."validity range"."upper bound"' <<< "${view}")" null; fi
    # Every public certificate parameter is checked, not merely the intent JSON.
    saved_pledge="${CNTOOLS_POOL_REG_PLEDGE}"; CNTOOLS_POOL_REG_PLEDGE=100000001
    reject cntools_pool_registration_validate_body "${CNTOOLS_TRANSACTION_BODY_FILE}"
    CNTOOLS_POOL_REG_PLEDGE="${saved_pledge}"; CNTOOLS_WALLET_REGISTER_ERROR=''
    if [[ "${scenario}" == offline ]]; then
      # Supply missing signing keys later, as Transaction → Sign does.
      cntools_transaction_plan_reset Offline Offline exact
      cntools_transaction_plan_add_signer funding spending "${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}" "${CNTOOLS_WALLET_DIR}/Funding/payment.skey"
      cntools_transaction_plan_add_signer cold certificate "${CNTOOLS_POOL_REG_COLD_VKEY}" "${pool}/cold.skey"
      cntools_transaction_plan_add_signer owner certificate "$(jq -r .vkey <<< "${owner_record}")" "${CNTOOLS_WALLET_DIR}/Owner/stake.skey"
    fi
    signed="${TEST_ROOT}/signed.json"
    cntools_transaction_sign_registered "${package}" "${signed}" || fail 'pool witness/signing'
    cntools_transaction_package_load "${signed}" || fail 'signed validation'
    eq "${CNTOOLS_TRANSACTION_COMPLETE}" Y 'all witnesses complete'
    size="$(jq -r '.cborHex|length/2' "${CNTOOLS_TRANSACTION_SIGNED_FILE}")"
    ((fee == 155381 + 44 * (size - 1))) || fail "non-exact signed fee ${operation}/${scenario}: fee=${fee} bytes=${size}"
    rm "${signed}"
    printf 'Pinned pool transaction passed: %s/%s\n' "${operation}" "${scenario}"
  done
done
# Public hardware-reference contract double. No physical device is contacted;
# cold/payment operator witnesses share a session, each owner gets its own.
for spec in Funding:payment Funding:stake Owner:stake; do
  hw_wallet="${spec%%:*}" hw_role="${spec#*:}"
  hw_path='1852H/1815H/0H/0/0' hw_type=PaymentHWSigningFileShelley_ed25519
  if [[ "${hw_role}" == stake ]]; then hw_path='1852H/1815H/0H/2/0'; hw_type=StakeHWSigningFileShelley_ed25519; fi
  jq --arg type "${hw_type}" --arg path "${hw_path}" --arg chain "$(printf '00%.0s' {1..32})" \
    '{type:$type,path:$path,cborXPubKeyHex:("5840"+.cborHex[4:]+$chain)}' \
    "${CNTOOLS_WALLET_DIR}/${hw_wallet}/${hw_role}.vkey" > "${CNTOOLS_WALLET_DIR}/${hw_wallet}/${hw_role}.hwsfile"
done
jq --arg chain "$(printf '00%.0s' {1..32})" '{type:"StakePoolHWSigningFile_ed25519",path:"1853H/1815H/0H/0H",cborXPubKeyHex:("5840"+.cborHex[4:]+$chain)}' \
  "${pool}/cold.vkey" > "${pool}/cold.hwsfile"
CNTOOLS_POOL_REG_COLD_SOURCE="${pool}/cold.hwsfile"
CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE="${CNTOOLS_WALLET_DIR}/Funding/payment.hwsfile"
CNTOOLS_WALLET_REGISTER_WALLET_TYPE=Hardware CNTOOLS_POOL_REG_COMBINE_HARDWARE=Y
CNTOOLS_POOL_REG_OWNERS="$(jq -cn --argjson a "${owner_record}" --argjson b "${funding_record}" \
  --arg asource "${CNTOOLS_WALLET_DIR}/Owner/stake.hwsfile" --arg bsource "${CNTOOLS_WALLET_DIR}/Funding/stake.hwsfile" \
  '[$a + {source:$asource},$b + {source:$bsource}]')"
cntools_pool_registration_plan_create || fail 'hardware pool plan'
jq -e '([.[]|select(.hardwareGroup=="pool-operator")]|length)==2 and
  ([.[]|select(.hardwareGroup|startswith("owner-"))]|length)==2 and
  ([.[].hardwareGroup]|unique|length)==3' <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}" >/dev/null || fail 'pool signing modes mixed'
jq -e 'length==2 and all(.[];.hardwareGroup=="pool-operator")' <<< "${CNTOOLS_TRANSACTION_PLAN_CHANGE_KEYS}" >/dev/null || fail 'operator change references'
(
  cntools_payment_prepare_wallet() {
    CNTOOLS_PAYMENT_TYPE=Hardware CNTOOLS_PAYMENT_WALLET=Funding CNTOOLS_PAYMENT_ADDRESS=addr_test1base CNTOOLS_PAYMENT_PAYMENT=addr_test1payment
    CNTOOLS_PAYMENT_SOURCE="${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" CNTOOLS_PAYMENT_VKEY="${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}" CNTOOLS_PAYMENT_CREDENTIAL="${CNTOOLS_WALLET_REGISTER_PAYMENT_CREDENTIAL}"
  }
  CNTOOLS_POOL_REG_COLD_SOURCE="${pool}/cold.skey"; reject cntools_pool_registration_prepare_funding /wallet
  CNTOOLS_POOL_REG_COLD_SOURCE="${pool}/cold.hwsfile"; cntools_pool_registration_prepare_funding /wallet || fail 'hardware operator sources'
  cntools_ui_choose() { printf -v "$1" '%s' 'Yes, same Ledger device'; }
  cntools_ui_render_status() { :; }
  cntools_pool_registration_hardware_choice || fail 'same-device confirmation'
  eq "${CNTOOLS_POOL_REG_COMBINE_HARDWARE}" Y
  cntools_ui_choose() { printf -v "$1" '%s' 'No, use another funding wallet'; }
  reject cntools_pool_registration_hardware_choice
)
cntools_wallet_cleanup_material
cntools_transaction_cleanup
printf 'CNTools pool registration pinned tests passed (cnode CLI %s).\n' "${version}"
