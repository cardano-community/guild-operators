#!/usr/bin/env bash
# Asset inventory/UI and registry external-command contracts (not crypto proof).
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-asset-management.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet wallet-material wallet-key wallet-id asset asset-cache wallet-query-transport wallet-query-local asset-metadata wallet-query-koios wallet-list-query asset-view wallet-view wallet-query transaction table policy-files policy policy-ui policy-catalog policy-manage-ui asset-registry asset-registry-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command() { local mask="$1"; shift 2; (( ${#mask} == $# )) || fail 'audit mask'; "$@"; }
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)" REAL_LN="$(type -P ln)"
  chmod() { local arg=''; local -a args=(); for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done; "${REAL_CHMOD}" "${args[@]}"; }
  ln() { [[ "$1" != -T ]] || shift; [[ "$1" != -- ]] || shift; [[ ! -e "$2" && ! -L "$2" ]] || return 1; "${REAL_LN}" "$@"; }
fi
CNTOOLS_MODE=offline CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://invalid.example/api
CNTOOLS_CLI='' CNTOOLS_ASSET_DIR="${TEST_ROOT}/assets" CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}"
CNTOOLS_TIMEZONE=UTC CNTOOLS_NETWORK=preview CNTOOLS_LOG="${TEST_ROOT}/log"
mkdir -m700 "${CNTOOLS_ASSET_DIR}" "${CNTOOLS_ASSET_DIR}/Legacy"
directory="${CNTOOLS_ASSET_DIR}/Legacy" policy="$(printf 'ab%.0s' {1..28})" credential="$(printf 'cd%.0s' {1..28})"
printf '%s\n' "${policy}" > "${directory}/policy.id"
jq -n --arg h "${credential}" '{type:"sig",keyHash:$h}' > "${directory}/policy.script"
jq -n --arg p "${policy}" '{policyID:$p,name:"Token",minted:7}' > "${directory}/Token.asset"
jq -n --arg p "${policy}" '{policyID:$p,assetName:""}' > "${directory}/.asset"
cntools_policy_catalog_build || fail inventory
[[ "${#CNTOOLS_POLICY_NAMES[@]}" == 1 && "${CNTOOLS_POLICY_STATES[0]}" == Watch-only ]] || fail 'policy inventory'
cntools_policy_asset_catalog "${directory}" "${policy}" || fail 'legacy asset inventory'
[[ "${#CNTOOLS_POLICY_ASSET_IDS[@]}" == 2 && "${CNTOOLS_POLICY_ASSET_IDS[*]}" == *"${policy}.546f6b656e"* ]] || fail 'legacy text/empty assets'
cntools_asset_details_for_ids() { fail 'offline metadata request'; }
cntools_policy_asset_enrich "${policy}.546f6b656e"
encoded=''
cntools_policy_asset_name_into encoded text 'Token'; [[ "${encoded}" == 546f6b656e ]] || fail 'output variable shadowed'
cntools_policy_asset_name_into encoded text 'é'; [[ "${encoded}" == c3a9 ]] || fail UTF8
! cntools_policy_asset_name_into encoded text "$(printf 'x%.0s' {1..33})" || fail 'long name accepted'
! cntools_policy_asset_name_into encoded hex a || fail 'odd hex accepted'
cntools_registry_field_valid Decimals 0 || fail 'zero decimals'
! cntools_registry_field_valid Decimals 256 || fail 'overflow decimals'
! cntools_registry_field_valid URL http://example.org || fail 'HTTP URL accepted'
cntools_ui_choose() { printf -v "$1" '%s' Text; }
cntools_ui_input() { printf -v "$1" '%s' Token; }
cntools_policy_asset_input_into encoded; [[ "${encoded}" == 546f6b656e ]] || fail 'UI hex output shadowed'

# An isolated double implements only the documented external file/argv contract.
# Cryptographic attestations remain the real tool's responsibility, not this test.
CNTOOLS_POLICY_ID="${policy}" CNTOOLS_POLICY_SELECTED_SCRIPT="${directory}/policy.script"
CNTOOLS_POLICY_SELECTED_SOURCE="${TEST_ROOT}/policy.skey"; printf '{}\n' > "${CNTOOLS_POLICY_SELECTED_SOURCE}"; chmod 600 "${CNTOOLS_POLICY_SELECTED_SOURCE}"
cntools_registry_require_tool() { CNTOOLS_REGISTRY_TOOL="${BASH}"; }
REGISTRY_FAULT='' REGISTRY_CALLS=0
cntools_run_command_timeout() {
  local mask="$2" subject='' file='' field='' value='' draft='' old='{}' mode='' key='' next=''
  shift 3; (( ${#mask} == $# )) || fail 'timeout audit mask'
  if [[ "$1" != "${CNTOOLS_REGISTRY_TOOL}" ]]; then "$@"; return $?; fi
  shift
  printf '%q ' "$@" >> "${TEST_ROOT}/calls"; printf '\n' >> "${TEST_ROOT}/calls"
  [[ "${REGISTRY_FAULT}" != tool ]] || return 17
  if [[ "$1" == validate ]]; then
    jq -e '.name.signatures|length>0' "${!#}" >/dev/null; return $?
  fi
  subject="$2"; shift 2; file="${subject}.json"; draft="${file}.draft"
  if [[ -f "${draft}" ]]; then old="$(< "${draft}")"; elif [[ -f "${file}" ]]; then old="$(< "${file}")"; fi
  [[ "$*" != *--init* ]] || old='{}'
  printf '%s' "${old}" > "${draft}"
  while (($#)); do
    key="$1"; shift
    case "${key}" in
      --init) ;;
      --finalize) mv "${draft}" "${file}" ;;
      -a) shift; jq 'with_entries(if (.value|type)=="object" then .value.signatures=[{publicKey:"fixture",signature:"fixture"}] else . end)' "${draft}" > "result"; mv result "${draft}" ;;
      --policy) shift ;;
      --name|--description|--ticker|--url|--decimals)
        field="${key#--}"; value="$1"; shift
        [[ "${field}" == decimals ]] || value="$(jq -r '.' <<< "${value}")"
        next="$(jq -c --arg f "${field}" --arg v "${value}" --arg s "${subject}" '.subject=$s|.[$f] as $old|.[$f]={value:$v,sequenceNumber:(if $old==null then 0 elif $old.value==$v then $old.sequenceNumber else $old.sequenceNumber+1 end),signatures:[]}' "${draft}")"
        printf '%s' "${next}" > "${draft}" ;;
      *) fail "unexpected registry option ${key}" ;;
    esac
  done
}
cntools_registry_export "${policy}.546f6b656e" Token 'Test token' TT https://example.org 0 '' || fail "export: ${CNTOOLS_POLICY_ERROR} ${CNTOOLS_TRANSACTION_ERROR}"
first="${CNTOOLS_REGISTRY_SAVED}"
[[ -f "${first}" && "${first##*/}" == "${policy}546f6b656e.json" ]] || fail 'canonical saved file'
cntools_registry_export "${policy}.546f6b656e" 'Token renamed' 'Test token' '' '' '' '' "${first}" || fail 'update export'
second="${CNTOOLS_REGISTRY_SAVED}"
jq -e '.name.sequenceNumber==1 and .description.sequenceNumber==0 and .ticker.value=="TT" and .decimals.value=="0"' "${second}" >/dev/null || fail 'update preservation/sequences'
REGISTRY_FAULT=tool
! cntools_registry_export "${policy}.546f6b656e" Token 'Test token' '' '' '' '' || fail 'tool failure accepted'
cntools_registry_cleanup; cntools_transaction_cleanup
[[ -f "${first}" && -f "${second}" ]] || fail 'cleanup removed completed registry exports'
printf 'Asset inventory, offline UI and registry command contracts passed\n'
