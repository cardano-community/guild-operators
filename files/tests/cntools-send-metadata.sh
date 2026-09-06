#!/usr/bin/env bash
# Offline metadata invariants, including the published CIP-83 known ciphertext.
# shellcheck disable=SC1090,SC2034,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-metadata.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number transaction-metadata message-crypto; do
  . "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/${lib}.sh"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_transaction_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_transaction_temp_file() { local p; p="$(mktemp "${TEST_ROOT}/metadata.XXXXXX")"; printf -v "$1" '%s' "${p}"; }
cntools_transaction_snapshot_into() { local p; p="$(mktemp "${TEST_ROOT}/metadata.XXXXXX")"; cp "$2" "${p}"; printf -v "$1" '%s' "${p}"; }

for valid in '{"1":9007199254740993}' '{"1":{"string":"test"},"2":[1,2,-18446744073709551615]}' '{"674":{"msg":["hello"]}}'; do
  printf '%s' "${valid}" > "${TEST_ROOT}/input"
  cntools_metadata_validate_json "${TEST_ROOT}/input" || fail "valid JSON: ${valid}"
done
for invalid in '{"1":1,"1":2}' '{"1":{"a":1,"\u0061":2}}' '{"01":1}' '{"0x1":1}' '{"1":1.5}' '{"1":1e3}' '{"1":null}' '{"1":true}' '{"1":18446744073709551616}' '{"1":{}} {"2":{}}'; do
  printf '%s' "${invalid}" > "${TEST_ROOT}/input"
  if cntools_metadata_validate_json "${TEST_ROOT}/input"; then fail "accepted ambiguous/unsupported JSON: ${invalid}"; fi
done
printf '%s' '{"1":9007199254740993}' > "${TEST_ROOT}/input"
cntools_metadata_import "${TEST_ROOT}/input" simple
cmp "${TEST_ROOT}/input" "${CNTOOLS_METADATA_CUSTOM}" || fail 'integer literal changed'
printf '%s' '{"1":2}' > "${TEST_ROOT}/input"
[[ "$(< "${CNTOOLS_METADATA_CUSTOM}")" == '{"1":9007199254740993}' ]] || fail 'import was not frozen'

message="$(printf '🙂%.0s' {1..33})"
plain="$(printf '%s\nline two' "${message}" | cntools_metadata_message_json)"
[[ "$(jq 'length' <<< "${plain}")" == 4 ]] || fail 'Unicode chunk count'
jq -e 'all(.[]; utf8bytelength <= 64)' <<< "${plain}" >/dev/null || fail 'UTF-8 limit'
cntools_transaction_temp_file CNTOOLS_METADATA_MESSAGE
printf '%s' "${plain}" | jq '{msg:.}' > "${CNTOOLS_METADATA_MESSAGE}"
printf '%s' '{"674":{}}' > "${TEST_ROOT}/input"
if cntools_metadata_validate_json "${TEST_ROOT}/input"; then fail 'label collision'; fi
args=()
cntools_metadata_arguments_into args
[[ "${args[*]}" == *--metadata-json-file*--metadata-json-file* ]] || fail 'separate metadata inputs'
CNTOOLS_METADATA_SCHEMA=detailed
cntools_metadata_arguments_into args
jq -e '."674".map[0].v.list[0].string' "${args[4]}" >/dev/null || fail 'typed message'

pass='metadata-test-secret-42'
cipher1=""; cipher2=""
cntools_message_encrypt_into cipher1 plain pass || fail 'CIP-83 encryption'
cntools_message_encrypt_into cipher2 plain pass || fail 'CIP-83 encryption repeat'
[[ "${cipher1}" != "${cipher2}" ]] || fail 'salt was reused'
crypto_args=()
cntools_message_crypto_arguments_into crypto_args
vector='U2FsdGVkX1/5Y0A7l8xK686rvLsmPviTlna2n3P/ADNm89Ynr1UPZ/Q6bynbe28Y/zWYOB9PAGt+bq1L0z/W2LNHe92HTN/Fwz16aHa98TOsgM3q8tAR4NSqrLZVu1H7'
decoded="$(printf '%s' "${vector}" | openssl enc -d "${crypto_args[@]}" -pass fd:3 3<<< cardano)" || fail 'published CIP-83 vector'
[[ "${decoded}" == '["Invoice-No: 123456789","Order-No: 7654321","Email: john@doe.com"]' ]] || fail 'vector plaintext'
if grep -Eq 'metadata-test-secret|🙂|line two' "${TEST_ROOT}/log"; then fail 'secret in logs'; fi
cntools_metadata_reset
cntools_metadata_arguments_into args
(( ${#args[@]} == 0 )) || fail 'reset leaked metadata to next transfer'

# Exercise the actual encrypted-message UI callback without a terminal/device.
. "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/send-metadata-ui.sh"
cntools_send_choose() {
  case "$2" in
    'Message protection') printf -v "$1" '%s' 'Encrypted (CIP-83)' ;;
    'Encryption passphrase') printf -v "$1" '%s' 'Custom shared passphrase' ;;
    *) fail 'unexpected metadata prompt' ;;
  esac
}
cntools_ui_render_status() { :; }
cntools_ui_password() { printf -v "$1" '%s' 'not-a-wallet-password'; }
cntools_gum() { printf 'private message from UI'; }
cntools_gum_width() { printf 80; }
cntools_send_begin() { :; }
CNTOOLS_GUM_COLOR_BRAND=green; CNTOOLS_GUM_COLOR_MUTED=gray
cntools_send_metadata_message || fail 'encrypted UI'
[[ "${CNTOOLS_METADATA_MODE}" == basic-custom ]] || fail 'message protection state'
jq -e '.enc == "basic" and all(.msg[]; length <= 64)' "${CNTOOLS_METADATA_MESSAGE}" >/dev/null || fail 'encrypted envelope'
if grep -Eq 'private message from UI|not-a-wallet-password' "${TEST_ROOT}/log" "${CNTOOLS_METADATA_MESSAGE}"; then fail 'UI leaked plaintext or password'; fi
[[ -z "${passphrase+x}" && -z "${plain_json+x}" ]] || fail 'secret scope escaped'

# The shared offline/online CLI review must not round metadata through jq.
(
  . "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/transaction-ui.sh"
  cntools_ui_content_width() { printf 80; }
  cntools_ui_render_detail() { :; }
  cntools_gum() { cat; }
  CNTOOLS_GUM_COLOR_DIVIDER=gray; CNTOOLS_GUM_COLOR_TEXT=white
  rendered="$(cntools_transaction_ui_render_json test '{"metadata":{"123":9007199254740993}}')"
  [[ "${rendered}" == '{"metadata":{"123":9007199254740993}}' ]] || fail 'offline review rounded metadata'
)
printf 'CNTools Send metadata tests passed.\n'
