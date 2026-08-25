#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

if [[ "${1:-}" == "--governance-info-fake" ]]; then
  fake_command="${2:-}"
  shift 2 || exit 98
  fake_input=""
  if [[ "${fake_command}" == bech32 ]]; then
    IFS= read -r fake_input || true
  fi
  printf '%s' "${fake_command}" >> "${CNTOOLS_GOVERNANCE_DIRECT_VECTOR_LOG:?}"
  printf '\t%s' "$@" >> "${CNTOOLS_GOVERNANCE_DIRECT_VECTOR_LOG}"
  if [[ "${fake_command}" == bech32 ]]; then
    printf '\tstdin=%s' "${fake_input}" \
      >> "${CNTOOLS_GOVERNANCE_DIRECT_VECTOR_LOG}"
  fi
  printf '\n' >> "${CNTOOLS_GOVERNANCE_DIRECT_VECTOR_LOG}"
  case "${fake_command}" in
    bech32)
      fake_prefix="${1:-}"
      case "${fake_prefix}:${fake_input}" in
        :drep1ace) printf '%s\n' "${CNTOOLS_GOVERNANCE_OWN_HASH:?}" ;;
        :drep1delegate) printf '%s\n' "${CNTOOLS_GOVERNANCE_DELEGATE_HASH:?}" ;;
        :drep1delegate2z9) printf '22%s\n' "${CNTOOLS_GOVERNANCE_DELEGATE_HASH:?}" ;;
        drep:"${CNTOOLS_GOVERNANCE_OWN_HASH}") printf 'drep1ace\n' ;;
        drep:"22${CNTOOLS_GOVERNANCE_OWN_HASH}") printf 'drep1ace2z9\n' ;;
        drep:"${CNTOOLS_GOVERNANCE_DELEGATE_HASH}") printf 'drep1delegate\n' ;;
        drep:"22${CNTOOLS_GOVERNANCE_DELEGATE_HASH}") printf 'drep1delegate2z9\n' ;;
        cc_cold:"${CNTOOLS_GOVERNANCE_COLD_HASH}") printf 'cc_cold1ace\n' ;;
        :cc_cold1ace) printf '%s\n' "${CNTOOLS_GOVERNANCE_COLD_HASH:?}" ;;
        cc_cold:"12${CNTOOLS_GOVERNANCE_COLD_HASH}") printf 'cc_cold1ace2z9\n' ;;
        cc_hot:"${CNTOOLS_GOVERNANCE_HOT_HASH}") printf 'cc_hot1ace\n' ;;
        :cc_hot1ace) printf '%s\n' "${CNTOOLS_GOVERNANCE_HOT_HASH:?}" ;;
        cc_hot:"02${CNTOOLS_GOVERNANCE_HOT_HASH}") printf 'cc_hot1ace2z9\n' ;;
        *) printf 'unsafe raw bech32 failure: %s:%s\n' \
          "${fake_prefix}" "${fake_input}" >&2; exit 96 ;;
      esac
      ;;
    cardano-cli)
      fake_joined="$*"
      case "${fake_joined}" in
        latest\ governance\ drep\ id\ --drep-verification-key-file\ *)
          printf 'drep1ace\n'
          ;;
        latest\ governance\ committee\ key-hash\ --verification-key-file\ *cc-cold.vkey)
          printf '%s\n' "${CNTOOLS_GOVERNANCE_COLD_HASH:?}"
          ;;
        latest\ governance\ committee\ key-hash\ --verification-key-file\ *cc-hot.vkey)
          printf '%s\n' "${CNTOOLS_GOVERNANCE_HOT_HASH:?}"
          ;;
        query\ stake-address-info\ --mainnet\ --address\ stake1fixture)
          case "${CNTOOLS_GOVERNANCE_DIRECT_SCENARIO:?}" in
            local-full|local-node-error|local-unsafe-anchor)
              printf '[{"address":"stake1fixture","voteDelegation":{"keyHash":"%s"}}]\n' \
                "${CNTOOLS_GOVERNANCE_DELEGATE_HASH:?}"
              ;;
            local-oversized-anchor)
              printf '[{"address":"stake1fixture","voteDelegation":{"keyHash":"%s"}}]\n' \
                "${CNTOOLS_GOVERNANCE_DELEGATE_HASH:?}"
              ;;
            local-delegation-error)
              printf 'unsafe raw local delegation failure\n' >&2
              exit 9
              ;;
            local-delegation-malformed)
              printf '[{"address":"stake1fixture","voteDelegation":{"keyHash":"../../unsafe"}}]\n'
              ;;
            *) printf '[{"address":"stake1fixture","voteDelegation":null}]\n' ;;
          esac
          ;;
        latest\ query\ drep-state\ --drep-key-hash\ *\ --mainnet)
          fake_hash="${5:-}"
          if [[ "${CNTOOLS_GOVERNANCE_DIRECT_SCENARIO:?}" == \
                local-node-error &&
                "${fake_hash}" == "${CNTOOLS_GOVERNANCE_OWN_HASH}" ]]; then
            printf 'unsafe raw node query failure\n' >&2
            exit 9
          fi
          if [[ "${CNTOOLS_GOVERNANCE_DIRECT_SCENARIO}" == \
                local-invalid-status &&
                "${fake_hash}" == "${CNTOOLS_GOVERNANCE_OWN_HASH}" ]]; then
            printf '{ malformed local status\n'
          elif [[ "${fake_hash}" == \
                   "${CNTOOLS_GOVERNANCE_DELEGATE_HASH}" ]]; then
            printf '[[{"keyHash":"%s"},{"anchor":null,"deposit":500000000,"expiry":105}]]\n' \
              "${CNTOOLS_GOVERNANCE_DELEGATE_HASH}"
          elif [[ "${fake_hash}" == "${CNTOOLS_GOVERNANCE_OWN_HASH}" ]]; then
            if [[ "${CNTOOLS_GOVERNANCE_DIRECT_SCENARIO}" == \
                  local-unsafe-anchor ]]; then
              printf '[[{"keyHash":"%s"},{"anchor":{"url":"--config /tmp/governance-info-curlrc","dataHash":"%s"},"deposit":700000000,"expiry":95}]]\n' \
                "${CNTOOLS_GOVERNANCE_OWN_HASH}" \
                "${CNTOOLS_GOVERNANCE_ANCHOR_HASH:?}"
            else
              printf '[[{"keyHash":"%s"},{"anchor":{"url":"%s","dataHash":"%s"},"deposit":700000000,"expiry":95}]]\n' \
                "${CNTOOLS_GOVERNANCE_OWN_HASH}" \
                "${CNTOOLS_GOVERNANCE_ANCHOR_URL:?}" \
                "${CNTOOLS_GOVERNANCE_ANCHOR_HASH:?}"
            fi
          else
            printf '[]\n'
          fi
          ;;
        latest\ query\ drep-stake-distribution\ --all-dreps\ --mainnet)
          if [[ "${CNTOOLS_GOVERNANCE_DIRECT_SCENARIO:?}" == \
                local-overflow-power ]]; then
            printf '{'
            for ((fake_index=0; fake_index<210; fake_index++)); do
              (( fake_index == 0 )) || printf ','
              printf '"drep-keyHash-%056x":45000000000000000' \
                "${fake_index}"
            done
            printf '}\n'
          else
            printf '{"drep-alwaysAbstain":6500000,"drep-keyHash-%s":2500000,"drep-keyHash-%s":1000000}\n' \
              "${CNTOOLS_GOVERNANCE_DELEGATE_HASH}" \
              "${CNTOOLS_GOVERNANCE_OWN_HASH}"
          fi
          ;;
        hash\ anchor-data\ --file-text\ *)
          printf '%s\n' "${CNTOOLS_GOVERNANCE_ANCHOR_HASH:?}"
          ;;
        *) printf 'unsafe raw cardano-cli vector: %s\n' \
          "${fake_joined}" >&2; exit 96 ;;
      esac
      ;;
    curl)
      fake_output="" fake_url="" fake_previous=""
      fake_has_disable=N fake_has_proto=N fake_has_redir_proto=N
      fake_has_max_size=N fake_has_max_time=N
      for fake_argument in "$@"; do
        [[ "${fake_previous}" == --output ]] && fake_output="${fake_argument}"
        [[ "${fake_previous}" == --url ]] && fake_url="${fake_argument}"
        [[ "${fake_argument}" == --disable ]] && fake_has_disable=Y
        [[ "${fake_argument}" == '=https' &&
           "${fake_previous}" == --proto ]] && fake_has_proto=Y
        [[ "${fake_argument}" == '=https' &&
           "${fake_previous}" == --proto-redir ]] && fake_has_redir_proto=Y
        [[ "${fake_previous}" == --max-filesize ]] && fake_has_max_size=Y
        [[ "${fake_previous}" == --max-time ]] && fake_has_max_time=Y
        fake_previous="${fake_argument}"
      done
      [[ "${fake_has_disable}${fake_has_proto}${fake_has_redir_proto}${fake_has_max_size}${fake_has_max_time}" == YYYYY &&
         -n "${fake_output}" && -f "${fake_output}" &&
         ! -L "${fake_output}" &&
         "${fake_output%/*}" == \
           "${CNTOOLS_GOVERNANCE_EXPECTED_PRIVATE_PARENT:?}" ]] || exit 98
      if fake_mode="$("${CNTOOLS_GOVERNANCE_REAL_STAT:?}" -f '%Lp' \
          "${fake_output}" 2>/dev/null)"; then :
      else
        fake_mode="$("${CNTOOLS_GOVERNANCE_REAL_STAT}" -c '%a' -- \
          "${fake_output}" 2>/dev/null)" || exit 98
      fi
      [[ "${fake_mode#0}" == 600 ]] || exit 98
      case "${fake_url}" in
        */account_info?*)
          case "${CNTOOLS_GOVERNANCE_DIRECT_SCENARIO:?}" in
            light-full)
              printf '[{"stake_address":"stake1fixture","status":"registered","delegated_drep":"drep1delegate2z9"}]\n' > "${fake_output}"
              ;;
            light-delegation-error)
              printf 'unsafe raw Koios delegation failure\n' >&2
              exit 28
              ;;
            light-delegation-malformed)
              printf '[{"stake_address":"stake1fixture","status":"registered","delegated_drep":"../../unsafe"}]\n' > "${fake_output}"
              ;;
            *)
              printf '[{"stake_address":"stake1fixture","status":"not registered","delegated_drep":null}]\n' > "${fake_output}"
              ;;
          esac
          ;;
        */drep_info?*)
          case "${CNTOOLS_GOVERNANCE_DIRECT_SCENARIO:?}" in
            light-koios-error)
              printf 'unsafe raw Koios status failure\n' >&2
              exit 28
              ;;
            light-koios-empty) : ;;
            light-invalid-status)
              printf '{ malformed status\n' > "${fake_output}"
              ;;
            light-oversized-status)
              "${CNTOOLS_GOVERNANCE_REAL_HEAD:?}" -c 262145 /dev/zero | \
                "${CNTOOLS_GOVERNANCE_REAL_TR:?}" '\000' x > "${fake_output}"
              ;;
            *)
              if [[ "$*" == *drep1delegate2z9* ]]; then
                printf '[{"drep_status":"registered","deposit":500000000,"active":true,"expires_epoch_no":105,"amount":2500000,"meta_url":null,"meta_hash":null}]\n' > "${fake_output}"
              else
                printf '[{"drep_status":"registered","deposit":700000000,"active":false,"expires_epoch_no":95,"amount":1000000,"meta_url":null,"meta_hash":null}]\n' > "${fake_output}"
              fi
              ;;
          esac
          ;;
        */drep_epoch_summary?*)
          printf '[{"amount":10000000}]\n' > "${fake_output}"
          ;;
        "${CNTOOLS_GOVERNANCE_ANCHOR_URL}")
          if [[ "${CNTOOLS_GOVERNANCE_DIRECT_SCENARIO:?}" == \
                local-oversized-anchor ]]; then
            "${CNTOOLS_GOVERNANCE_REAL_HEAD:?}" -c 262145 /dev/zero | \
              "${CNTOOLS_GOVERNANCE_REAL_TR:?}" '\000' x > "${fake_output}"
          else
            printf '{"name":"fixture anchor"}\n' > "${fake_output}"
          fi
          ;;
        *) printf 'unsafe raw curl URL: %s\n' "${fake_url}" >&2; exit 96 ;;
      esac
      ;;
    *) exit 98 ;;
  esac
  exit 0
fi

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools governance info characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
GOVERNANCE_QUERY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f/030-governance-query.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/vote/governance/info/action.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/vote/governance/info"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-governance-info.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
REAL_JQ="$(command -v jq 2>/dev/null || true)"
REAL_HEAD="$(command -v head 2>/dev/null || true)"
REAL_TR="$(command -v tr 2>/dev/null || true)"
REAL_STAT="$(command -v stat 2>/dev/null || true)"

OWN_HASH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DELEGATE_HASH="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
COLD_HASH="cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
HOT_HASH="dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
ANCHOR_HASH="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
KOIOS_FIXTURE="https://koios.example.test/api/v1"
ANCHOR_FIXTURE="https://metadata.example.test/drep.json"

cleanup_test() {
  if [[ "${CNTOOLS_GOVERNANCE_INFO_PRESERVE_TEST_ROOT:-N}" == "Y" ]]; then
    printf 'CNTools governance info test root preserved: %s\n' \
      "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools governance info characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk basename bc cat cmp find grep jq readlink sort stat tail wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
if command -v sha256sum >/dev/null 2>&1; then
  HASH_COMMAND="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_COMMAND="shasum"
else
  fail 'sha256sum or shasum is required'
fi
[[ -n "${REAL_JQ}" && -n "${REAL_HEAD}" && -n "${REAL_TR}" &&
   -n "${REAL_STAT}" ]] ||
  fail 'jq, head, tr, and stat are required for direct parity'

write_direct_fake_commands() {
  local command_name=""

  mkdir -p -- "${FAKE_BIN}"
  for command_name in cardano-cli bech32 curl; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'exec "${CNTOOLS_GOVERNANCE_TEST_SCRIPT:?}" --governance-info-fake "${0##*/}" "$@"' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

normalize_vector_argument() {
  local value="${1:-}"

  value="${value//"${CASE_RUNTIME_ROOT:-/nonexistent}"/<runtime>}"
  printf '%s' "${value}"
}

record_vector() {
  local command_name="$1"
  shift || true
  local argument=""

  printf '%s' "${command_name}" >> "${VECTOR_LOG:?}"
  for argument in "$@"; do
    printf '\t%s' "$(normalize_vector_argument "${argument}")" \
      >> "${VECTOR_LOG:?}"
  done
  printf '\n' >> "${VECTOR_LOG:?}"
}

cardano-cli() {
  local joined="$*" key_hash=""

  record_vector cardano-cli "$@"
  case "${joined}" in
    latest\ governance\ drep\ id\ --drep-verification-key-file\ *)
      printf 'drep1ace\n'
      ;;
    latest\ governance\ committee\ key-hash\ --verification-key-file\ *cc-cold.vkey)
      printf '%s\n' "${COLD_HASH}"
      ;;
    latest\ governance\ committee\ key-hash\ --verification-key-file\ *cc-hot.vkey)
      printf '%s\n' "${HOT_HASH}"
      ;;
    latest\ query\ drep-state\ --drep-key-hash\ *\ --mainnet)
      key_hash="${5:-}"
      if [[ "${CNTOOLS_GOVERNANCE_SCENARIO:?}" == "local-node-error" &&
            "${key_hash}" == "${OWN_HASH}" ]]; then
        printf 'raw node query failure\n' >&2
        return 9
      fi
      if [[ "${key_hash}" == "${DELEGATE_HASH}" ]]; then
        printf '[[{"keyHash":"%s"},{"anchor":null,"deposit":500000000,"expiry":105}]]\n' \
          "${DELEGATE_HASH}"
      elif [[ "${key_hash}" == "${OWN_HASH}" ]]; then
        if [[ "${CNTOOLS_GOVERNANCE_SCENARIO}" == "local-unsafe-anchor" ]]; then
          printf '[[{"keyHash":"%s"},{"anchor":{"url":"--config /tmp/governance-info-curlrc","dataHash":"%s"},"deposit":700000000,"expiry":95}]]\n' \
            "${OWN_HASH}" "${ANCHOR_HASH}"
        else
          printf '[[{"keyHash":"%s"},{"anchor":{"url":"%s","dataHash":"%s"},"deposit":700000000,"expiry":95}]]\n' \
            "${OWN_HASH}" "${ANCHOR_FIXTURE}" "${ANCHOR_HASH}"
        fi
      else
        printf 'null\n'
      fi
      ;;
    latest\ query\ drep-stake-distribution\ --all-dreps\ --mainnet)
      printf '{"drep-alwaysAbstain":6500000,"drep-keyHash-%s":2500000,"drep-keyHash-%s":1000000}\n' \
        "${DELEGATE_HASH}" "${OWN_HASH}"
      ;;
    hash\ anchor-data\ --file-text\ *)
      printf '%s\n' "${ANCHOR_HASH}"
      ;;
    *)
      printf 'unexpected cardano-cli vector: %s\n' "${joined}" >&2
      return 96
      ;;
  esac
}

bech32() {
  local prefix="${1:-}" input=""

  IFS= read -r input || true
  record_vector bech32 "${prefix:-<decode>}" "stdin=${input}"
  case "${prefix}:${input}" in
    :drep1ace) printf '%s\n' "${OWN_HASH}" ;;
    :drep1delegate) printf '%s\n' "${DELEGATE_HASH}" ;;
    drep:"${OWN_HASH}") printf 'drep1ace\n' ;;
    drep:"22${OWN_HASH}") printf 'drep1ace2z9\n' ;;
    drep:"${DELEGATE_HASH}") printf 'drep1delegate\n' ;;
    drep:"22${DELEGATE_HASH}") printf 'drep1delegate2z9\n' ;;
    cc_cold:"${COLD_HASH}") printf 'cc_cold1ace\n' ;;
    :cc_cold1ace) printf '%s\n' "${COLD_HASH}" ;;
    cc_cold:"12${COLD_HASH}") printf 'cc_cold1ace2z9\n' ;;
    cc_hot:"${HOT_HASH}") printf 'cc_hot1ace\n' ;;
    :cc_hot1ace) printf '%s\n' "${HOT_HASH}" ;;
    cc_hot:"02${HOT_HASH}") printf 'cc_hot1ace2z9\n' ;;
    *)
      printf 'unexpected bech32 vector: %s:%s\n' "${prefix}" "${input}" >&2
      return 96
      ;;
  esac
}

curl() {
  local argument="" previous="" output_file="" url="" data=""

  record_vector curl "$@"
  for argument in "$@"; do
    if [[ "${previous}" == "-o" ]]; then output_file="${argument}"; fi
    if [[ "${previous}" == "-d" ]]; then data="${argument}"; fi
    url="${argument}"
    previous="${argument}"
  done
  case "${url}" in
    "${KOIOS_FIXTURE}/drep_info"*)
      case "${CNTOOLS_GOVERNANCE_SCENARIO:?}" in
        light-koios-error)
          printf 'raw Koios transport failure\n' >&2
          return 22
          ;;
        light-koios-empty) return 0 ;;
      esac
      printf 'drep_status,deposit,active,expires_epoch_no,amount,meta_url,meta_hash\n'
      if [[ "${data}" == *drep1delegate2z9* ]]; then
        printf 'registered,500000000,true,105,2500000,,\n'
      else
        printf 'registered,700000000,false,95,1000000,,\n'
      fi
      ;;
    "${KOIOS_FIXTURE}/drep_epoch_summary"*)
      printf 'amount\n10000000\n'
      ;;
    "${ANCHOR_FIXTURE}")
      [[ -n "${output_file}" ]] || return 96
      printf '{"name":"fixture anchor"}\n' > "${output_file}"
      ;;
    /tmp/governance-info-curlrc)
      return 1
      ;;
    *)
      printf 'unexpected curl URL: %s\n' "${url}" >&2
      return 96
      ;;
  esac
}

date() {
  record_vector date "$@"
  if [[ "$*" == "+%Y%m%d%H%M%S" ]]; then
    printf '20240102030405\n'
  else
    printf 'unexpected date vector: %s\n' "$*" >&2
    return 96
  fi
}

forbidden_effect() {
  record_vector "blocked:${FUNCNAME[1]}" "${@:1}"
  return 97
}
wget() { forbidden_effect "$@"; }
git() { forbidden_effect "$@"; }
ssh() { forbidden_effect "$@"; }
nc() { forbidden_effect "$@"; }

# Source the public legacy controller and the exact immutable governance query
# fragment used by the inline action. Selection/runtime functions below replace
# only unrelated UI and node initialization behavior.
# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
PRODUCTION_COMPATIBILITY_BRIDGE_DEFINITION="$(
  declare -f cntools_compatibility_dispatch_action
)" || fail 'could not preserve the production compatibility bridge'
# shellcheck source=/dev/null
. "${GOVERNANCE_QUERY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"

println() {
  local log_level="${1:-}"
  shift || true
  case "${log_level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@" ;;
    *) printf '%b\n' "${log_level}" "$@" ;;
  esac
}

clear() {
  if [[ "${CAPTURE_ACTIVE:-N}" == "Y" ]]; then
    if [[ "${ACTION_CLEAR_PENDING:-N}" == "Y" ]]; then
      ACTION_CLEAR_PENDING="N"
    else
      printf 'action:return-without-wait\n' >> "${EVENT_LOG:?}"
      printf '__CNTOOLS_GOVERNANCE_INFO_END__\n'
      CAPTURE_ACTIVE="N"
    fi
  fi
}

getNodeMetrics() {
  printf 'runtime:getNodeMetrics\n' >> "${EVENT_LOG:?}"
  slotnum=100
}
getPriceInfo() {
  printf 'runtime:getPriceInfo\n' >> "${EVENT_LOG:?}"
  price_now=""
}
updateProtocolParams() {
  printf 'runtime:updateProtocolParams\n' >> "${EVENT_LOG:?}"
}
getEpoch() { printf '100\n'; }
timeUntilNextEpoch() { printf '0\n'; }
timeLeft() { printf '00:00:00'; }
getSlotTipRef() { printf '100\n'; }
slotInterval() { printf '20\n'; }

versionCheck() {
  printf 'action:versionCheck:%s:%s\n' "${1:-}" "${2:-}" \
    >> "${EVENT_LOG:?}"
  [[ "${CNTOOLS_GOVERNANCE_SCENARIO:?}" != "pre-conway-local" ]]
}

formatLovelace() {
  case "${1:-}" in
    2500000) printf '2.5' ;;
    1000000) printf '1' ;;
    500000000) printf '500' ;;
    700000000) printf '700' ;;
    0|'') printf '0' ;;
    *) printf 'unexpected:%s' "${1:-}" ;;
  esac
}

isNumber() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
fractionToPCT() {
  case "${1:-}" in
    .25|.250*|0.25|0.250*) printf '25' ;;
    .10|.100*|.1|.10*|0.1|0.10*) printf '10' ;;
    *) printf '0' ;;
  esac
}

isWalletRegistered() {
  printf 'action:isWalletRegistered:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  case "${CNTOOLS_GOVERNANCE_SCENARIO:?}" in
    missing-keys-local|missing-keys-light|light-koios-error|light-koios-empty)
      return 1
      ;;
    *)
      reward_addr="stake_test"
      if [[ "${CNTOOLS_MODE}" == "LOCAL" ]]; then
        vote_delegation="keyHash-${DELEGATE_HASH}"
      fi
      return 0
      ;;
  esac
}

selectWallet() {
  printf 'action:selectWallet:%s:%s\n' "${1:-}" "${SELECT_WALLET_STATUS:?}" \
    >> "${EVENT_LOG:?}"
  if [[ "${CNTOOLS_GOVERNANCE_SCENARIO:?}" == unsafe-wallet-name ]]; then
    wallet_name="../outside"
  else
    wallet_name="registered"
  fi
  if [[ "${SELECT_WALLET_STATUS}" == "2" &&
        "${CAPTURE_ACTIVE:-N}" == "Y" ]]; then
    printf 'action:return-without-wait\n' >> "${EVENT_LOG:?}"
    printf '__CNTOOLS_GOVERNANCE_INFO_END__\n'
    CAPTURE_ACTIVE="N"
  fi
  return "${SELECT_WALLET_STATUS}"
}

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}"
  local menu="" option="" index=0

  case "${1:-}" in
    '[w] Wallet') menu="main" ;;
    '[g] Governance') menu="vote" ;;
    '[i] Info & Status') menu="governance" ;;
    *) fail "unexpected legacy menu: ${1:-<empty>}" ;;
  esac
  [[ -n "${choice}" ]] || fail "legacy menu ${menu} exhausted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  if [[ "${menu}:${choice}" == governance:h &&
        "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    CAPTURE_ACTIVE=N
    ACTION_CLEAR_PENDING=N
  fi
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == "governance:i" ]]; then
        CAPTURE_ACTIVE="Y"
        ACTION_CLEAR_PENDING="Y"
        printf '__CNTOOLS_GOVERNANCE_INFO_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was absent from legacy menu ${menu}"
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == "Y" ]]; then
    printf '__CNTOOLS_GOVERNANCE_INFO_END__\n'
    CAPTURE_ACTIVE="N"
  fi
  return 0
}

myExit() {
  local status="${1:-0}" message="${2:-}"

  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'legacy traversal did not consume every scripted choice'
  exit "${status}"
}

prepare_wallet_fixture() {
  local wallet_root="$1"
  local fixture="$2"
  local wallet="${wallet_root}/registered"
  local delegate_wallet=""

  [[ "${fixture}" != "empty" ]] || return 0
  mkdir -p -- "${wallet}"
  case "${fixture}" in
    selectable|missing-keys) ;;
    cached-keys)
      printf 'drep1ace' > "${wallet}/drep.id"
      printf 'cc_cold1ace' > "${wallet}/cc-cold.id"
      printf 'cc_hot1ace' > "${wallet}/cc-hot.id"
      ;;
    materialize-keys)
      printf '{"description":"Software DRep Verification Key"}\n' \
        > "${wallet}/drep.vkey"
      printf '{"description":"Software Committee Cold Verification Key"}\n' \
        > "${wallet}/cc-cold.vkey"
      printf '{"description":"Software Committee Hot Verification Key"}\n' \
        > "${wallet}/cc-hot.vkey"
      ;;
    *) fail "unknown wallet fixture: ${fixture}" ;;
  esac
  if [[ "${fixture}" == "cached-keys" ||
        "${fixture}" == "materialize-keys" ]]; then
    for delegate_wallet in z-delegate a-delegate; do
      mkdir -p -- "${wallet_root}/${delegate_wallet}"
      printf 'drep1delegate' > \
        "${wallet_root}/${delegate_wallet}/drep.id"
    done
  fi
}

prepare_direct_wallet_fixture() {
  local wallet_root="$1" fixture="$2" cached_file=""

  prepare_wallet_fixture "${wallet_root}" "${fixture}"
  [[ "${fixture}" != empty ]] || return 0
  printf 'stake1fixture' > "${wallet_root}/registered/stake.addr"
  chmod 0644 "${wallet_root}/registered/stake.addr"
  if [[ "${fixture}" == cached-keys ]]; then
    while IFS= read -r -d '' cached_file; do
      chmod 0644 "${cached_file}"
    done < <(find "${wallet_root}" -type f \
      \( -name drep.id -o -name cc-cold.id -o -name cc-hot.id \) \
      -print0)
  fi
}

prepare_direct_security_fixture() {
  local scenario="$1" runtime_root="$2"
  local cache_file="${runtime_root}/wallet/registered/drep.id"
  local peer_file="${runtime_root}/cache-peer"
  local symlink_target="${runtime_root}/cache-symlink-target"

  case "${scenario}" in
    unsafe-cache-mode)
      chmod 0666 "${cache_file}"
      ;;
    unsafe-cache-hardlink)
      ln "${cache_file}" "${peer_file}"
      ;;
    unsafe-cache-symlink)
      printf '%s' drep1ace > "${symlink_target}"
      rm -f -- "${cache_file}"
      ln -s "${symlink_target}" "${cache_file}"
      ;;
    unsafe-cache-content)
      printf '%s' '../../unsafe' > "${cache_file}"
      ;;
  esac
}

write_governance_context() {
  local target="$1" mode="$2" node_home="$3"

  "${REAL_JQ}" -nS --arg mode "${mode,,}" --arg node_home "${node_home}" '
    {
      advanced: true,
      apiVersion: 1,
      capabilities: ["forging", "local-cli", "metrics", "n2c"],
      features: ["advanced"],
      generationVersion: "13.5.7",
      mode: $mode,
      nodeHome: $node_home,
      nodeImplementation: "cnode",
      nodeNetwork: "mainnet",
      schemaVersion: 1
    }
  ' > "${target}"
  chmod 0400 "${target}"
}

cntools_compatibility_dispatch_action() (
  local action_id="${1:-}" private_root="" context_file=""
  local result_file="" status=0

  [[ "${action_id}" == vote.governance.info && $# -eq 1 ]] || return 70
  printf 'action:compatibility-dispatch:%s\n' "${action_id}" \
    >> "${EVENT_LOG:?}"
  umask 077
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/governance-info-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  write_governance_context "${context_file}" "${CNTOOLS_MODE}" "${NODE_HOME}"
  export CNTOOLS_GOVERNANCE_DIRECT_SCENARIO="${CNTOOLS_GOVERNANCE_SCENARIO}"
  export CNTOOLS_GOVERNANCE_DIRECT_VECTOR_LOG="${VECTOR_LOG}"
  export CNTOOLS_GOVERNANCE_TEST_SCRIPT="${REPO_ROOT}/files/tests/cntools-governance-info-characterization.sh"
  export CNTOOLS_GOVERNANCE_EXPECTED_PRIVATE_PARENT="${private_root}"
  export CNTOOLS_GOVERNANCE_REAL_STAT="${REAL_STAT}"
  export CNTOOLS_GOVERNANCE_REAL_HEAD="${REAL_HEAD}"
  export CNTOOLS_GOVERNANCE_REAL_TR="${REAL_TR}"
  export CNTOOLS_GOVERNANCE_OWN_HASH="${OWN_HASH}"
  export CNTOOLS_GOVERNANCE_DELEGATE_HASH="${DELEGATE_HASH}"
  export CNTOOLS_GOVERNANCE_COLD_HASH="${COLD_HASH}"
  export CNTOOLS_GOVERNANCE_HOT_HASH="${HOT_HASH}"
  export CNTOOLS_GOVERNANCE_ANCHOR_HASH="${ANCHOR_HASH}"
  export CNTOOLS_GOVERNANCE_ANCHOR_URL="${ANCHOR_FIXTURE}"
  unset -f cardano-cli bech32 curl date wget git ssh nc
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    status=0
  else
    status=$?
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || status=70
  rm -f -- "${result_file}" "${context_file}"
  rmdir -- "${private_root}" || status=70
  return "${status}"
)

extract_action_output() {
  local full_output="$1"
  local action_output="$2"
  local begin_count=0 end_count=0

  begin_count="$(grep -c '^__CNTOOLS_GOVERNANCE_INFO_BEGIN__$' \
    "${full_output}" || true)"
  end_count="$(grep -c '^__CNTOOLS_GOVERNANCE_INFO_END__$' \
    "${full_output}" || true)"
  [[ "${begin_count}" == "1" && "${end_count}" == "1" ]] ||
    fail 'action output markers were missing or duplicated'
  awk '
    $0 == "__CNTOOLS_GOVERNANCE_INFO_BEGIN__" { capture = 1; next }
    $0 == "__CNTOOLS_GOVERNANCE_INFO_END__" { capture = 0; exit }
    capture { print }
  ' "${full_output}" > "${action_output}"
}

write_header() {
  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> VOTE >> GOVERNANCE >> INFO & STATUS' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    > "$1"
}

# Expected stdout is filled with literal normalized bytes after the test has
# captured each scenario. Keeping this as a dedicated function makes review of
# the frozen UI contract independent from the helper implementation.
write_expected_stdout() {
  local scenario="$1"
  local output_file="$2"

  write_header "${output_file}"
  case "${scenario}" in
    pre-conway-local)
      printf '%s\n' '' \
        'Not yet in Conway era, please revisit once network has crossed into Cardano governance era!' \
        >> "${output_file}"
      ;;
    empty-local|empty-light|empty-offline)
      printf '%s\n' '' '' 'No wallets available!' >> "${output_file}"
      ;;
    select-failed-local|select-cancel-light)
      printf '%s\n' '' 'Select wallet (derive governance keys if missing)' \
        >> "${output_file}"
      ;;
    missing-keys-local|missing-keys-light)
      printf '%s\n' \
        '' \
        'Select wallet (derive governance keys if missing)' \
        '' \
        '~~ Vote Delegation Status ~~' \
        'Delegation           : undelegated - please note that reward withdrawals will not work until wallet is vote delegated' \
        '' \
        '~~ Own DRep Status ~~' \
        'Status               : Governance keys missing, please derive them if needed' \
        >> "${output_file}"
      ;;
    missing-keys-offline)
      printf '%s\n' \
        '' \
        'Select wallet (derive governance keys if missing)' \
        '' \
        '~~ Own DRep Status ~~' \
        'Status               : Governance keys missing, please derive them if needed' \
        >> "${output_file}"
      ;;
    local-full|light-full|offline-full|light-koios-error|light-koios-empty|\
      local-node-error|local-unsafe-anchor)
      # Filled from reviewed literal fixtures below after the first diagnostic
      # run so alignment and legacy error leakage are frozen byte-for-byte.
      write_expected_status_stdout "${scenario}" "${output_file}"
      ;;
    *) fail "unknown expected stdout scenario: ${scenario}" ;;
  esac
}

write_expected_status_stdout() {
  local scenario="$1"
  local output_file="$2"

  case "${scenario}" in
    local-full)
      printf '%s\n' \
        '' \
        'Select wallet (derive governance keys if missing)' \
        '' \
        '~~ Vote Delegation Status ~~' \
        'Delegation           : CIP-105 => drep1delegate' \
        '                     : CIP-129 => drep1delegate2z9' \
        '                     : Wallet  => a-delegate' \
        'DRep Type            : Key' \
        'DRep expiry          : epoch 105 - active' \
        'Active Vote power    : 2.5 ADA (25.00 %)' \
        '' \
        '~~ Own DRep Status ~~' \
        'DRep ID              : CIP-105 => drep1ace' \
        '                     : CIP-129 => drep1ace2z9' \
        "DRep Hash            : ${OWN_HASH}" \
        'DRep Type            : Key' \
        'DRep expiry          : epoch 95 - inactive (vote power does not count)' \
        "DRep anchor url      : ${ANCHOR_FIXTURE}" \
        'DRep anchor data     :' \
        '{"name":"fixture anchor"}' \
        '' \
        'Active Vote power    : 1 ADA (10.00 %)' \
        '' \
        'Committee Cold ID    : CIP-105 => cc_cold1ace' \
        '                     : CIP-129 => cc_cold1ace2z9' \
        'Committee Hot ID     : CIP-105 => cc_hot1ace' \
        '                     : CIP-129 => cc_hot1ace2z9' \
        >> "${output_file}"
      ;;
    light-full)
      printf '%s\n' \
        '' \
        'Select wallet (derive governance keys if missing)' \
        '' \
        '~~ Vote Delegation Status ~~' \
        'Delegation           : CIP-105 => drep1delegate' \
        '                     : CIP-129 => drep1delegate2z9' \
        '                     : Wallet  => a-delegate' \
        'DRep Type            : Key' \
        'DRep expiry          : epoch 105 - active' \
        'Active Vote power    : 2.5 ADA (25.00 %)' \
        '' \
        '~~ Own DRep Status ~~' \
        'DRep ID              : CIP-105 => drep1ace' \
        '                     : CIP-129 => drep1ace2z9' \
        "DRep Hash            : ${OWN_HASH}" \
        'DRep Type            : Key' \
        'DRep expiry          : epoch 95 - inactive (vote power does not count)' \
        'Active Vote power    : 1 ADA (10.00 %)' \
        '' \
        'Committee Cold ID    : CIP-105 => cc_cold1ace' \
        '                     : CIP-129 => cc_cold1ace2z9' \
        'Committee Hot ID     : CIP-105 => cc_hot1ace' \
        '                     : CIP-129 => cc_hot1ace2z9' \
        >> "${output_file}"
      ;;
    offline-full)
      printf '%s\n' \
        '' \
        'Select wallet (derive governance keys if missing)' \
        '' \
        '~~ Own DRep Status ~~' \
        'DRep ID              : CIP-105 => drep1ace' \
        '                     : CIP-129 => drep1ace2z9' \
        "DRep Hash            : ${OWN_HASH}" \
        'DRep Type            : Key' \
        '' \
        'Committee Cold ID    : CIP-105 => cc_cold1ace' \
        '                     : CIP-129 => cc_cold1ace2z9' \
        'Committee Hot ID     : CIP-105 => cc_hot1ace' \
        '                     : CIP-129 => cc_hot1ace2z9' \
        >> "${output_file}"
      ;;
    light-koios-error)
      printf '%s\n' \
        '' \
        'Select wallet (derive governance keys if missing)' \
        '' \
        '~~ Vote Delegation Status ~~' \
        'Delegation           : undelegated - please note that reward withdrawals will not work until wallet is vote delegated' \
        '' \
        '~~ Own DRep Status ~~' \
        'DRep ID              : CIP-105 => drep1ace' \
        '                     : CIP-129 => drep1ace2z9' \
        "DRep Hash            : ${OWN_HASH}" \
        'DRep Type            : Key' \
        '' \
        'KOIOS_API ERROR: raw Koios transport failure' \
        '' \
        'Status               : DRep key not registered' \
        '' \
        'Committee Cold ID    : CIP-105 => cc_cold1ace' \
        '                     : CIP-129 => cc_cold1ace2z9' \
        'Committee Hot ID     : CIP-105 => cc_hot1ace' \
        '                     : CIP-129 => cc_hot1ace2z9' \
        >> "${output_file}"
      ;;
    light-koios-empty)
      printf '%s\n' \
        '' \
        'Select wallet (derive governance keys if missing)' \
        '' \
        '~~ Vote Delegation Status ~~' \
        'Delegation           : undelegated - please note that reward withdrawals will not work until wallet is vote delegated' \
        '' \
        '~~ Own DRep Status ~~' \
        'DRep ID              : CIP-105 => drep1ace' \
        '                     : CIP-129 => drep1ace2z9' \
        "DRep Hash            : ${OWN_HASH}" \
        'DRep Type            : Key' \
        'Status               : DRep key not registered' \
        '' \
        'Committee Cold ID    : CIP-105 => cc_cold1ace' \
        '                     : CIP-129 => cc_cold1ace2z9' \
        'Committee Hot ID     : CIP-105 => cc_hot1ace' \
        '                     : CIP-129 => cc_hot1ace2z9' \
        >> "${output_file}"
      ;;
    local-node-error)
      printf '%s\n' \
        '' \
        'Select wallet (derive governance keys if missing)' \
        '' \
        '~~ Vote Delegation Status ~~' \
        'Delegation           : CIP-105 => drep1delegate' \
        '                     : CIP-129 => drep1delegate2z9' \
        '                     : Wallet  => a-delegate' \
        'DRep Type            : Key' \
        'DRep expiry          : epoch 105 - active' \
        'Active Vote power    : 2.5 ADA (25.00 %)' \
        '' \
        '~~ Own DRep Status ~~' \
        'DRep ID              : CIP-105 => drep1ace' \
        '                     : CIP-129 => drep1ace2z9' \
        "DRep Hash            : ${OWN_HASH}" \
        'DRep Type            : Key' \
        'DRep expiry          : epoch  - inactive (vote power does not count)' \
        'Active Vote power    : 1 ADA (10.00 %)' \
        '' \
        'Committee Cold ID    : CIP-105 => cc_cold1ace' \
        '                     : CIP-129 => cc_cold1ace2z9' \
        'Committee Hot ID     : CIP-105 => cc_hot1ace' \
        '                     : CIP-129 => cc_hot1ace2z9' \
        >> "${output_file}"
      ;;
    local-unsafe-anchor)
      printf '%s\n' \
        '' \
        'Select wallet (derive governance keys if missing)' \
        '' \
        '~~ Vote Delegation Status ~~' \
        'Delegation           : CIP-105 => drep1delegate' \
        '                     : CIP-129 => drep1delegate2z9' \
        '                     : Wallet  => a-delegate' \
        'DRep Type            : Key' \
        'DRep expiry          : epoch 105 - active' \
        'Active Vote power    : 2.5 ADA (25.00 %)' \
        '' \
        '~~ Own DRep Status ~~' \
        'DRep ID              : CIP-105 => drep1ace' \
        '                     : CIP-129 => drep1ace2z9' \
        "DRep Hash            : ${OWN_HASH}" \
        'DRep Type            : Key' \
        'DRep expiry          : epoch 95 - inactive (vote power does not count)' \
        'DRep anchor url      : --config /tmp/governance-info-curlrc' \
        'DRep anchor data     : Invalid URL or currently not available' \
        'Active Vote power    : 1 ADA (10.00 %)' \
        '' \
        'Committee Cold ID    : CIP-105 => cc_cold1ace' \
        '                     : CIP-129 => cc_cold1ace2z9' \
        'Committee Hot ID     : CIP-105 => cc_hot1ace' \
        '                     : CIP-129 => cc_hot1ace2z9' \
        >> "${output_file}"
      ;;
    *) fail "unknown status stdout fixture: ${scenario}" ;;
  esac
}

write_expected_stderr() {
  local scenario="$1"
  local output_file="$2"

  : > "${output_file}"
  if [[ "${scenario}" == "local-node-error" ]]; then
    printf 'raw node query failure\n' > "${output_file}"
  fi
}

append_runtime_events() {
  local mode="$1" output_file="$2"

  case "${mode}" in
    LOCAL)
      printf '%s\n' runtime:getNodeMetrics runtime:getPriceInfo \
        runtime:updateProtocolParams >> "${output_file}"
      ;;
    LIGHT)
      printf '%s\n' runtime:getPriceInfo runtime:updateProtocolParams \
        >> "${output_file}"
      ;;
    OFFLINE) ;;
    *) fail "unknown runtime mode: ${mode}" ;;
  esac
}

write_expected_events() {
  local scenario="$1" mode="$2" select_status="$3" output_file="$4"

  : > "${output_file}"
  append_runtime_events "${mode}" "${output_file}"
  printf '%s\n' menu:main:v menu:vote:g menu:governance:i \
    'action:compatibility-dispatch:vote.governance.info' \
    "action:versionCheck:9.0:10.1" >> "${output_file}"
  case "${scenario}" in
    pre-conway-local|empty-local|empty-light|empty-offline) ;;
    *)
      printf 'action:selectWallet:none:%s\n' "${select_status}" \
        >> "${output_file}"
      ;;
  esac
  case "${scenario}" in
    missing-keys-local|missing-keys-light|light-koios-error|light-koios-empty)
      printf 'action:versionCheck:10.0:10.1\n' >> "${output_file}"
      ;;
  esac
  if [[ "${scenario}" == "select-cancel-light" ]]; then
    printf 'action:return-without-wait\n' >> "${output_file}"
  else
    printf 'action:waitToProceed\n' >> "${output_file}"
  fi
  printf 'menu:governance:h\n' >> "${output_file}"
  append_runtime_events "${mode}" "${output_file}"
  printf '%s\n' menu:main:q 'exit:0:CNTools closed!' >> "${output_file}"
}

write_expected_vectors() {
  local scenario="$1" output_file="$2"

  : > "${output_file}"
  case "${scenario}" in
    pre-conway-local|empty-local|empty-light|empty-offline|\
      select-failed-local|select-cancel-light|missing-keys-local|\
      missing-keys-light|missing-keys-offline) ;;
    *)
      # Filled from reviewed literal command fixtures after the first
      # diagnostic run.
      write_expected_status_vectors "${scenario}" "${output_file}"
      ;;
  esac
}

write_expected_status_vectors() {
  local scenario="$1"
  local output_file="$2"

  case "${scenario}" in
    local-full)
      write_delegation_identity_vectors "${output_file}"
      write_local_status_vectors "${DELEGATE_HASH}" "${output_file}"
      write_local_vote_power_vectors "${output_file}"
      write_materialized_own_identity_vectors "${output_file}"
      write_local_status_vectors "${OWN_HASH}" "${output_file}"
      printf '%s\n' \
        $'date\t+%Y%m%d%H%M%S' \
        $'curl\t-sL\t-m\t20\t-o\t<runtime>/tmp/metadata_20240102030405.json\thttps://metadata.example.test/drep.json' \
        $'cardano-cli\thash\tanchor-data\t--file-text\t<runtime>/tmp/metadata_20240102030405.json' \
        >> "${output_file}"
      write_local_vote_power_vectors "${output_file}"
      ;;
    light-full)
      write_delegation_identity_vectors "${output_file}"
      write_light_status_vectors "${DELEGATE_HASH}" drep1delegate2z9 \
        "${output_file}"
      write_light_vote_power_vectors "${output_file}"
      write_cached_own_identity_vectors "${output_file}"
      write_light_status_vectors "${OWN_HASH}" drep1ace2z9 "${output_file}"
      write_light_vote_power_vectors "${output_file}"
      ;;
    offline-full)
      write_cached_own_identity_vectors "${output_file}"
      ;;
    light-koios-error|light-koios-empty)
      write_cached_own_identity_vectors "${output_file}"
      write_light_status_vectors "${OWN_HASH}" drep1ace2z9 "${output_file}"
      ;;
    local-node-error)
      write_delegation_identity_vectors "${output_file}"
      write_local_status_vectors "${DELEGATE_HASH}" "${output_file}"
      write_local_vote_power_vectors "${output_file}"
      write_cached_own_identity_vectors "${output_file}"
      write_local_status_vectors "${OWN_HASH}" "${output_file}"
      write_local_vote_power_vectors "${output_file}"
      ;;
    local-unsafe-anchor)
      write_delegation_identity_vectors "${output_file}"
      write_local_status_vectors "${DELEGATE_HASH}" "${output_file}"
      write_local_vote_power_vectors "${output_file}"
      write_cached_own_identity_vectors "${output_file}"
      write_local_status_vectors "${OWN_HASH}" "${output_file}"
      printf '%s\n' \
        $'date\t+%Y%m%d%H%M%S' \
        $'curl\t-sL\t-m\t20\t-o\t<runtime>/tmp/metadata_20240102030405.json\t--config\t/tmp/governance-info-curlrc' \
        >> "${output_file}"
      write_local_vote_power_vectors "${output_file}"
      ;;
    *) fail "unknown status vector fixture: ${scenario}" ;;
  esac
}

write_delegation_identity_vectors() {
  local output_file="$1"

  printf '%s\n' \
    $'bech32\t<decode>\tstdin=drep1delegate' \
    "bech32"$'\tdrep\tstdin=22'"${DELEGATE_HASH}" \
    "bech32"$'\tdrep\tstdin='"${DELEGATE_HASH}" \
    "bech32"$'\tdrep\tstdin=22'"${DELEGATE_HASH}" \
    >> "${output_file}"
}

write_cached_own_identity_vectors() {
  local output_file="$1"

  printf '%s\n' \
    $'bech32\t<decode>\tstdin=drep1ace' \
    "bech32"$'\tdrep\tstdin=22'"${OWN_HASH}" \
    $'bech32\t<decode>\tstdin=cc_cold1ace' \
    "bech32"$'\tcc_cold\tstdin=12'"${COLD_HASH}" \
    $'bech32\t<decode>\tstdin=cc_hot1ace' \
    "bech32"$'\tcc_hot\tstdin=02'"${HOT_HASH}" \
    >> "${output_file}"
}

write_materialized_own_identity_vectors() {
  local output_file="$1"

  printf '%s\n' \
    $'cardano-cli\tlatest\tgovernance\tdrep\tid\t--drep-verification-key-file\t<runtime>/wallet/registered/drep.vkey' \
    $'cardano-cli\tlatest\tgovernance\tcommittee\tkey-hash\t--verification-key-file\t<runtime>/wallet/registered/cc-cold.vkey' \
    "bech32"$'\tcc_cold\tstdin='"${COLD_HASH}" \
    $'cardano-cli\tlatest\tgovernance\tcommittee\tkey-hash\t--verification-key-file\t<runtime>/wallet/registered/cc-hot.vkey' \
    "bech32"$'\tcc_hot\tstdin='"${HOT_HASH}" \
    >> "${output_file}"
  write_cached_own_identity_vectors "${output_file}"
}

write_local_status_vectors() {
  local drep_hash="$1"
  local output_file="$2"

  printf 'cardano-cli\tlatest\tquery\tdrep-state\t--drep-key-hash\t%s\t--mainnet\n' \
    "${drep_hash}" >> "${output_file}"
}

write_local_vote_power_vectors() {
  local output_file="$1"

  printf '%s\n' \
    $'cardano-cli\tlatest\tquery\tdrep-stake-distribution\t--all-dreps\t--mainnet' \
    >> "${output_file}"
}

write_light_status_vectors() {
  local drep_hash="$1"
  local drep_id="$2"
  local output_file="$3"

  printf 'bech32\tdrep\tstdin=22%s\n' "${drep_hash}" >> "${output_file}"
  printf 'curl\t-sSL\t-f\t-X\tPOST\t-H\tAuthorization: fixture\t-H\tContent-Type: application/json\t-H\taccept: text/csv\t-d\t{"_drep_ids":["%s"]}\t%s/drep_info?select=drep_status,deposit,active,expires_epoch_no,amount,meta_url,meta_hash\n' \
    "${drep_id}" "${KOIOS_FIXTURE}" >> "${output_file}"
}

write_light_vote_power_vectors() {
  local output_file="$1"

  printf 'curl\t-sSL\t-f\t-X\tGET\t-H\tAuthorization: fixture\t-H\taccept: text/csv\t%s/drep_epoch_summary?_epoch_no=100&select=amount\n' \
    "${KOIOS_FIXTURE}" >> "${output_file}"
}

assert_mutations() {
  local scenario="$1" runtime_root="$2" before_snapshot="$3"
  local after_snapshot="$4"
  local filtered_after="${after_snapshot}.filtered"
  local expected_cache_file=""

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot ${scenario} after traversal"
  if [[ "${scenario}" != "local-full" ]]; then
    assert_files_equal "${after_snapshot}" "${before_snapshot}" \
      "${scenario} persistent tree"
    return 0
  fi

  for expected_cache_file in \
      "${runtime_root}/wallet/registered/drep.id" \
      "${runtime_root}/wallet/registered/cc-cold.id" \
      "${runtime_root}/wallet/registered/cc-hot.id" \
      "${runtime_root}/tmp/metadata_20240102030405.json"; do
    [[ -f "${expected_cache_file}" && ! -L "${expected_cache_file}" ]] ||
      fail "${scenario} allowed cache was not materialized: ${expected_cache_file}"
  done
  [[ "$(< "${runtime_root}/wallet/registered/drep.id")" == "drep1ace" &&
     "$(< "${runtime_root}/wallet/registered/cc-cold.id")" == "cc_cold1ace" &&
     "$(< "${runtime_root}/wallet/registered/cc-hot.id")" == "cc_hot1ace" &&
     "$(< "${runtime_root}/tmp/metadata_20240102030405.json")" == \
       '{"name":"fixture anchor"}' ]] ||
    fail "${scenario} materialized cache content changed"
  grep -Ev $'^f\t(wallet/registered/(drep|cc-cold|cc-hot)\.id|tmp/metadata_20240102030405\.json)\t' \
    "${after_snapshot}" > "${filtered_after}"
  assert_files_equal "${filtered_after}" "${before_snapshot}" \
    "${scenario} mutation allowlist"
}

run_case() {
  local scenario="$1" mode="$2" fixture="$3" select_status="$4"
  local case_root="${TEST_ROOT}/cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local vector_log="${capture_root}/vectors"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local status=0

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/wallet" \
    "${runtime_root}/pool" "${runtime_root}/home" "${capture_root}"
  prepare_direct_wallet_fixture "${runtime_root}/wallet" "${fixture}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot ${scenario} before traversal"
  : > "${event_log}"
  : > "${vector_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C
    export TZ=UTC
    PATH="${FAKE_BIN}:${BASE_PATH}"
    export PATH
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION="characterized"
    NETWORK_NAME="Mainnet"
    NETWORK_IDENTIFIER="--mainnet"
    NWMAGIC="764824073"
    PROT_VERSION="10.1"
    ADVANCED_MODE="false"
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    CCLI="cardano-cli"
    CURL_TIMEOUT=20
    KOIOS_API=""
    KOIOS_API_HEADERS=(-H 'Authorization: fixture')
    [[ "${mode}" == "LIGHT" ]] && KOIOS_API="${KOIOS_FIXTURE}"
    WALLET_SELECTION_FILTER_LIMIT=10
    WALLET_GOV_DREP_VK_FILENAME="drep.vkey"
    WALLET_GOV_DREP_SK_FILENAME="drep.skey"
    WALLET_GOV_DREP_SCRIPT_FILENAME="drep.script"
    WALLET_GOV_DREP_ID_FILENAME="drep.id"
    WALLET_GOV_HW_DREP_SK_FILENAME="drep.hwsfile"
    WALLET_GOV_CC_COLD_VK_FILENAME="cc-cold.vkey"
    WALLET_GOV_CC_COLD_SK_FILENAME="cc-cold.skey"
    WALLET_GOV_CC_COLD_ID_FILENAME="cc-cold.id"
    WALLET_GOV_HW_CC_COLD_SK_FILENAME="cc-cold.hwsfile"
    WALLET_GOV_CC_HOT_VK_FILENAME="cc-hot.vkey"
    WALLET_GOV_CC_HOT_SK_FILENAME="cc-hot.skey"
    WALLET_GOV_CC_HOT_ID_FILENAME="cc-hot.id"
    WALLET_GOV_HW_CC_HOT_SK_FILENAME="cc-hot.hwsfile"
    WALLET_STAKE_ADDR_FILENAME="stake.addr"
    WALLET_STAKE_VK_FILENAME="stake.vkey"
    WALLET_STAKE_SCRIPT_FILENAME="stake.script"
    WALLET_MULTISIG_PREFIX="ms-"
    price_now=""
    slotnum=100
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC="" BOLD=""
    EVENT_LOG="${event_log}"
    VECTOR_LOG="${vector_log}"
    CASE_RUNTIME_ROOT="${runtime_root}"
    CAPTURE_ACTIVE="N"
    ACTION_CLEAR_PENDING="N"
    SELECT_WALLET_STATUS="${select_status}"
    CNTOOLS_GOVERNANCE_SCENARIO="${scenario}"
    declare -A vote_delegations=()
    vote_delegations[stake_test]="keyHash-${DELEGATE_HASH}"
    CHOICES=(v g i h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "0" ]] || fail "${scenario} traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_stdout}"
  write_expected_direct_stdout "${scenario}" "${expected_stdout}"
  write_expected_direct_stderr "${scenario}" "${expected_stderr}"
  write_expected_events "${scenario}" "${mode}" "${select_status}" \
    "${expected_events}"
  assert_files_equal "${action_stdout}" "${expected_stdout}" \
    "${scenario} action stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "${scenario} action stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "${scenario} navigation/wait events"
  assert_direct_vectors "${scenario}" "${mode}" "${vector_log}"
  if grep -q '^blocked:' "${vector_log}"; then
    fail "${scenario} attempted a forbidden external effect"
  fi
  assert_direct_mutations "${scenario}" "${runtime_root}" "${before_snapshot}" \
    "${after_snapshot}"
}

write_expected_direct_stdout() {
  local scenario="$1" output_file="$2" direct_diagnostic=""

  case "${scenario}" in
    unsafe-api-config|unsafe-header-flag|unsafe-header-control)
      : > "${output_file}"
      ;;
    unsafe-cache-mode|unsafe-cache-hardlink|unsafe-cache-symlink|\
      unsafe-cache-content|unsafe-wallet-name)
      write_header "${output_file}"
      printf '%s\n' '' 'Select wallet (derive governance keys if missing)' \
        >> "${output_file}"
      ;;
    local-node-error|local-unsafe-anchor)
      write_header "${output_file}"
      write_expected_direct_delegated_status "${output_file}"
      write_expected_direct_own_identity "${output_file}"
      if [[ "${scenario}" == local-node-error ]]; then
        printf '%s\n' \
          'ERROR: failure during local governance status query!' \
          'Status               : DRep key not registered' \
          >> "${output_file}"
      else
        printf '%s\n' \
          'ERROR: local governance query returned an invalid response!' \
          'Status               : DRep key not registered' \
          >> "${output_file}"
      fi
      write_expected_direct_committee "${output_file}"
      ;;
    local-invalid-status|light-koios-error|light-invalid-status|\
      light-oversized-status)
      write_header "${output_file}"
      write_expected_direct_undelegated_status "" "${output_file}"
      write_expected_direct_own_identity "${output_file}"
      case "${scenario}" in
        local-invalid-status)
          printf '%s\n' \
            'ERROR: local governance query returned an invalid response!'
          ;;
        light-koios-error)
          printf '%s\n' \
            'ERROR: failure during governance status query!'
          ;;
        light-invalid-status)
          printf '%s\n' \
            'ERROR: governance status service returned an invalid response!'
          ;;
        light-oversized-status)
          printf '%s\n' \
            'ERROR: governance status response exceeded the 262144-byte safety limit!'
          ;;
      esac >> "${output_file}"
      printf '%s\n' 'Status               : DRep key not registered' \
        >> "${output_file}"
      write_expected_direct_committee "${output_file}"
      ;;
    light-delegation-error|light-delegation-malformed|\
      local-delegation-error|local-delegation-malformed)
      write_header "${output_file}"
      case "${scenario}" in
        light-delegation-error)
          direct_diagnostic='ERROR: failure during governance delegation query!'
          ;;
        light-delegation-malformed)
          direct_diagnostic='ERROR: governance delegation service returned an invalid response!'
          ;;
        local-delegation-error)
          direct_diagnostic='ERROR: failure during local governance delegation query!'
          ;;
        local-delegation-malformed)
          direct_diagnostic='ERROR: local governance delegation query returned an invalid response!'
          ;;
      esac
      write_expected_direct_undelegated_status "${direct_diagnostic}" \
        "${output_file}"
      write_expected_direct_own_identity "${output_file}"
      printf '%s\n' \
        'DRep expiry          : epoch 95 - inactive (vote power does not count)' \
        >> "${output_file}"
      if [[ "${scenario}" == local-* ]]; then
        printf '%s\n' \
          "DRep anchor url      : ${ANCHOR_FIXTURE}" \
          'DRep anchor data     :' \
          '{"name":"fixture anchor"}' \
          '' \
          >> "${output_file}"
      fi
      printf '%s\n' 'Active Vote power    : 1 ADA (10.00 %)' \
        >> "${output_file}"
      write_expected_direct_committee "${output_file}"
      ;;
    local-oversized-anchor)
      write_header "${output_file}"
      write_expected_direct_delegated_status "${output_file}"
      write_expected_direct_own_identity "${output_file}"
      printf '%s\n' \
        'DRep expiry          : epoch 95 - inactive (vote power does not count)' \
        "DRep anchor url      : ${ANCHOR_FIXTURE}" \
        'DRep anchor data     : Invalid URL or currently not available' \
        'Active Vote power    : 1 ADA (10.00 %)' \
        >> "${output_file}"
      write_expected_direct_committee "${output_file}"
      ;;
    local-overflow-power)
      write_header "${output_file}"
      write_expected_direct_undelegated_status "" "${output_file}"
      write_expected_direct_own_identity "${output_file}"
      printf '%s\n' \
        'DRep expiry          : epoch 95 - inactive (vote power does not count)' \
        "DRep anchor url      : ${ANCHOR_FIXTURE}" \
        'DRep anchor data     :' \
        '{"name":"fixture anchor"}' \
        '' \
        'ERROR: local governance vote-power query returned an invalid response!' \
        'Active Vote power    : 0 ADA (0 %)' \
        >> "${output_file}"
      write_expected_direct_committee "${output_file}"
      ;;
    *) write_expected_stdout "${scenario}" "${output_file}" ;;
  esac
}

write_expected_direct_delegated_status() {
  local output_file="$1"

  printf '%s\n' \
    '' \
    'Select wallet (derive governance keys if missing)' \
    '' \
    '~~ Vote Delegation Status ~~' \
    'Delegation           : CIP-105 => drep1delegate' \
    '                     : CIP-129 => drep1delegate2z9' \
    '                     : Wallet  => a-delegate' \
    'DRep Type            : Key' \
    'DRep expiry          : epoch 105 - active' \
    'Active Vote power    : 2.5 ADA (25.00 %)' \
    '' \
    >> "${output_file}"
}

write_expected_direct_undelegated_status() {
  local diagnostic="${1:-}" output_file="$2"

  printf '%s\n' \
    '' \
    'Select wallet (derive governance keys if missing)' \
    '' \
    '~~ Vote Delegation Status ~~' \
    >> "${output_file}"
  [[ -z "${diagnostic}" ]] || printf '%s\n' "${diagnostic}" >> "${output_file}"
  printf '%s\n' \
    'Delegation           : undelegated - please note that reward withdrawals will not work until wallet is vote delegated' \
    '' \
    >> "${output_file}"
}

write_expected_direct_own_identity() {
  local output_file="$1"

  printf '%s\n' \
    '~~ Own DRep Status ~~' \
    'DRep ID              : CIP-105 => drep1ace' \
    '                     : CIP-129 => drep1ace2z9' \
    "DRep Hash            : ${OWN_HASH}" \
    'DRep Type            : Key' \
    >> "${output_file}"
}

write_expected_direct_committee() {
  local output_file="$1"

  printf '%s\n' \
    '' \
    'Committee Cold ID    : CIP-105 => cc_cold1ace' \
    '                     : CIP-129 => cc_cold1ace2z9' \
    'Committee Hot ID     : CIP-105 => cc_hot1ace' \
    '                     : CIP-129 => cc_hot1ace2z9' \
    >> "${output_file}"
}

write_expected_direct_stderr() {
  local scenario="$1" output_file="$2"

  : > "${output_file}"
  case "${scenario}" in
    unsafe-api-config|unsafe-header-flag|unsafe-header-control|\
      unsafe-cache-mode|unsafe-cache-hardlink|unsafe-cache-symlink|\
      unsafe-cache-content|unsafe-wallet-name)
      printf 'CNTools governance-info action failed validation.\n' \
        > "${output_file}"
      ;;
  esac
}

write_expected_direct_events() {
  local scenario="$1" select_status="$2" output_file="$3"

  : > "${output_file}"
  case "${scenario}" in
    unsafe-api-config|unsafe-header-flag|unsafe-header-control) return 0 ;;
  esac
  printf 'action:versionCheck:9.0:10.1\n' >> "${output_file}"
  case "${scenario}" in
    pre-conway-local|empty-local|empty-light|empty-offline) ;;
    *)
      printf 'action:selectWallet:none:%s\n' "${select_status}" \
        >> "${output_file}"
      ;;
  esac
  case "${scenario}" in
    unsafe-cache-mode|unsafe-cache-hardlink|unsafe-cache-symlink|\
      unsafe-cache-content|unsafe-wallet-name) return 0 ;;
  esac
  case "${scenario}" in
    missing-keys-local|missing-keys-light|light-koios-error|\
      light-koios-empty|light-invalid-status|light-oversized-status|\
      light-delegation-error|light-delegation-malformed|\
      local-delegation-error|local-delegation-malformed|\
      local-invalid-status|local-overflow-power)
      printf 'action:versionCheck:10.0:10.1\n' >> "${output_file}"
      ;;
  esac
  if [[ "${scenario}" != select-cancel-light ]]; then
    printf 'action:waitToProceed\n' >> "${output_file}"
  fi
}

assert_direct_mutations() {
  local scenario="$1" runtime_root="$2" before_snapshot="$3"
  local after_snapshot="$4"
  local filtered_after="${after_snapshot}.filtered"
  local cache_file="" cache_mode=""

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot direct ${scenario} after dispatch"
  if [[ "${scenario}" != local-full ]]; then
    assert_files_equal "${after_snapshot}" "${before_snapshot}" \
      "direct ${scenario} persistent tree"
  else
    for cache_file in \
        "${runtime_root}/wallet/registered/drep.id" \
        "${runtime_root}/wallet/registered/cc-cold.id" \
        "${runtime_root}/wallet/registered/cc-hot.id"; do
      [[ -f "${cache_file}" && ! -L "${cache_file}" ]] ||
        fail "direct ${scenario} cache was not materialized: ${cache_file}"
      cache_mode="$(file_mode "${cache_file}")" ||
        fail "direct ${scenario} cache mode could not be read"
      [[ "${cache_mode}" == 600 ]] ||
        fail "direct ${scenario} cache mode changed: ${cache_mode}"
    done
    grep -Ev $'^f\t(wallet/registered/(drep|cc-cold|cc-hot)\.id)\t' \
      "${after_snapshot}" > "${filtered_after}"
    assert_files_equal "${filtered_after}" "${before_snapshot}" \
      "direct ${scenario} mutation allowlist"
  fi
  [[ -z "$(find "${runtime_root}" -name \
    '.cntools-governance-info.*' -print -quit)" ]] ||
    fail "direct ${scenario} retained a cache temporary"
}

assert_direct_vectors() {
  local scenario="$1" mode="$2" vector_log="$3"
  local vector_line="" curl_count=0

  while IFS= read -r vector_line; do
    case "${vector_line}" in
      curl$'\t'*)
        curl_count=$((curl_count + 1))
        [[ "${vector_line}" == \
          curl$'\t--disable\t--silent\t--location\t--max-redirs\t3\t--proto\t=https\t--proto-redir\t=https\t--max-time\t20\t--fail\t--max-filesize\t'* &&
           "${vector_line}" == *$'\t--output\t'* &&
           "${vector_line}" == *$'\t--url\thttps://'* ]] ||
          fail "direct ${scenario} curl array contract changed"
        ;;
      bech32$'\t'*)
        [[ "${vector_line}" == *$'\tstdin='?* ]] ||
          fail "direct ${scenario} bech32 stdin contract changed"
        ;;
    esac
  done < "${vector_log}"
  if [[ "${mode}" == LIGHT && "${curl_count}" -gt 0 ]]; then
    grep -Fq $'\t-H\tAuthorization: fixture\t' "${vector_log}" ||
      fail "direct ${scenario} rejected a valid -H header vector"
  fi
  if grep -Eq $'(^|\t)(-sSL|-X|--config)(\t|$)' "${vector_log}"; then
    fail "direct ${scenario} used an unsafe or legacy curl vector"
  fi
}

run_wrong_arity_case() {
  local case_root="${TEST_ROOT}/direct-cases/wrong-arity"
  local stdout_file="${case_root}/stdout" stderr_file="${case_root}/stderr"
  local status=0

  mkdir -p -- "${case_root}"
  if (
    # shellcheck source=/dev/null
    . "${ACTION_SOURCE}"
    cntools_action_main only-one-argument
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == 64 && ! -s "${stdout_file}" && ! -s "${stderr_file}" ]] ||
    fail 'direct wrong-arity contract changed'
}

run_direct_case() {
  local scenario="$1" mode="$2" fixture="$3" select_status="$4"
  local expected_status="${5:-0}"
  local case_root="${TEST_ROOT}/direct-cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local capture_root="${case_root}/capture"
  local private_root="${runtime_root}/tmp/private"
  local context_file="${private_root}/context.json"
  local result_file="${private_root}/result.json"
  local stdout_file="${capture_root}/stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local vector_log="${capture_root}/vectors"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local status=0

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/wallet" \
    "${runtime_root}/pool" "${runtime_root}/home" "${capture_root}"
  prepare_direct_wallet_fixture "${runtime_root}/wallet" "${fixture}"
  prepare_direct_security_fixture "${scenario}" "${runtime_root}"
  if [[ "${fixture}" == cached-keys &&
        "${scenario}" != unsafe-cache-* ]]; then
    [[ "$(file_mode "${runtime_root}/wallet/registered/drep.id")" == 644 ]] ||
      fail "direct ${scenario} did not exercise a safe 0644 cache"
  fi
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot direct ${scenario} before dispatch"
  mkdir -p -- "${private_root}"
  chmod 0700 "${private_root}"
  write_governance_context "${context_file}" "${mode}" \
    "${runtime_root}/home"
  : > "${event_log}"
  : > "${vector_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C TZ=UTC
    unset -f cardano-cli bech32 curl date wget git ssh nc
    PATH="${FAKE_BIN}:${BASE_PATH}"
    export PATH
    export CNTOOLS_GOVERNANCE_TEST_SCRIPT="${REPO_ROOT}/files/tests/cntools-governance-info-characterization.sh"
    export CNTOOLS_GOVERNANCE_DIRECT_SCENARIO="${scenario}"
    export CNTOOLS_GOVERNANCE_DIRECT_VECTOR_LOG="${vector_log}"
    export CNTOOLS_GOVERNANCE_EXPECTED_PRIVATE_PARENT="${private_root}"
    export CNTOOLS_GOVERNANCE_REAL_STAT="${REAL_STAT}"
    export CNTOOLS_GOVERNANCE_REAL_HEAD="${REAL_HEAD}"
    export CNTOOLS_GOVERNANCE_REAL_TR="${REAL_TR}"
    export CNTOOLS_GOVERNANCE_OWN_HASH="${OWN_HASH}"
    export CNTOOLS_GOVERNANCE_DELEGATE_HASH="${DELEGATE_HASH}"
    export CNTOOLS_GOVERNANCE_COLD_HASH="${COLD_HASH}"
    export CNTOOLS_GOVERNANCE_HOT_HASH="${HOT_HASH}"
    export CNTOOLS_GOVERNANCE_ANCHOR_HASH="${ANCHOR_HASH}"
    export CNTOOLS_GOVERNANCE_ANCHOR_URL="${ANCHOR_FIXTURE}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    CNTOOLS_MODE="${mode}"
    PROT_VERSION=10.1
    NWMAGIC=764824073
    CCLI=cardano-cli
    CURL_TIMEOUT=20
    KOIOS_API="${KOIOS_FIXTURE}"
    case "${scenario}" in
      unsafe-api-config)
        KOIOS_API='https://koios.example.test/api?unsafe=1'
        ;;
    esac
    case "${scenario}" in
      unsafe-header-flag)
        KOIOS_API_HEADERS=(--config /tmp/governance-info-curlrc)
        ;;
      unsafe-header-control)
        KOIOS_API_HEADERS=(-H $'X-Test: okay\nInjected: unsafe')
        ;;
      *) KOIOS_API_HEADERS=(-H 'Authorization: fixture') ;;
    esac
    WALLET_GOV_DREP_VK_FILENAME=drep.vkey
    WALLET_GOV_DREP_SCRIPT_FILENAME=drep.script
    WALLET_GOV_DREP_ID_FILENAME=drep.id
    WALLET_GOV_CC_COLD_VK_FILENAME=cc-cold.vkey
    WALLET_GOV_CC_COLD_ID_FILENAME=cc-cold.id
    WALLET_GOV_CC_HOT_VK_FILENAME=cc-hot.vkey
    WALLET_GOV_CC_HOT_ID_FILENAME=cc-hot.id
    WALLET_STAKE_ADDR_FILENAME=stake.addr
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_STAKE_SCRIPT_FILENAME=stake.script
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC="" BOLD=""
    EVENT_LOG="${event_log}"
    CAPTURE_ACTIVE=N
    ACTION_CLEAR_PENDING=N
    SELECT_WALLET_STATUS="${select_status}"
    CNTOOLS_GOVERNANCE_SCENARIO="${scenario}"
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "direct ${scenario} returned ${status}, expected ${expected_status}"
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] ||
    fail "direct ${scenario} unexpectedly produced a result"

  if [[ "${CNTOOLS_GOVERNANCE_INFO_CAPTURE_DIRECT:-N}" != Y ]]; then
    write_expected_direct_stdout "${scenario}" "${expected_stdout}"
    write_expected_direct_stderr "${scenario}" "${expected_stderr}"
    write_expected_direct_events "${scenario}" "${select_status}" \
      "${expected_events}"
    assert_files_equal "${stdout_file}" "${expected_stdout}" \
      "direct ${scenario} stdout"
    assert_files_equal "${stderr_file}" "${expected_stderr}" \
      "direct ${scenario} stderr"
    assert_files_equal "${event_log}" "${expected_events}" \
      "direct ${scenario} wait events"
  fi
  if grep -Eq 'unsafe raw|--config|governance-info-curlrc' \
      "${stdout_file}" "${stderr_file}"; then
    fail "direct ${scenario} reflected unsafe external text"
  fi
  if grep -Eq -- '--config|governance-info-curlrc' "${vector_log}"; then
    fail "direct ${scenario} transported an unsafe anchor option"
  fi
  assert_direct_vectors "${scenario}" "${mode}" "${vector_log}"
  rm -f -- "${context_file}"
  rmdir -- "${private_root}" ||
    fail "direct ${scenario} retained private response state"
  assert_direct_mutations "${scenario}" "${runtime_root}" \
    "${before_snapshot}" "${after_snapshot}"
}

write_direct_fake_commands
run_case pre-conway-local LOCAL selectable 0
run_case empty-local LOCAL empty 0
run_case empty-light LIGHT empty 0
run_case empty-offline OFFLINE empty 0
run_case select-failed-local LOCAL selectable 1
run_case select-cancel-light LIGHT selectable 2
run_case missing-keys-local LOCAL missing-keys 0
run_case missing-keys-light LIGHT missing-keys 0
run_case missing-keys-offline OFFLINE missing-keys 0
run_case local-full LOCAL materialize-keys 0
run_case light-full LIGHT cached-keys 0
run_case offline-full OFFLINE cached-keys 0
run_case light-koios-error LIGHT cached-keys 0
run_case light-koios-empty LIGHT cached-keys 0
run_case local-node-error LOCAL cached-keys 0
run_case local-unsafe-anchor LOCAL cached-keys 0

run_direct_case pre-conway-local LOCAL selectable 0
run_direct_case empty-local LOCAL empty 0
run_direct_case empty-light LIGHT empty 0
run_direct_case empty-offline OFFLINE empty 0
run_direct_case select-failed-local LOCAL selectable 1
run_direct_case select-cancel-light LIGHT selectable 2
run_direct_case missing-keys-local LOCAL missing-keys 0
run_direct_case missing-keys-light LIGHT missing-keys 0
run_direct_case missing-keys-offline OFFLINE missing-keys 0
run_direct_case local-full LOCAL materialize-keys 0
run_direct_case light-full LIGHT cached-keys 0
run_direct_case offline-full OFFLINE cached-keys 0
run_direct_case light-koios-error LIGHT cached-keys 0
run_direct_case light-koios-empty LIGHT cached-keys 0
run_direct_case local-node-error LOCAL cached-keys 0
run_direct_case local-unsafe-anchor LOCAL cached-keys 0
run_direct_case local-invalid-status LOCAL cached-keys 0
run_direct_case light-invalid-status LIGHT cached-keys 0
run_direct_case light-oversized-status LIGHT cached-keys 0
run_direct_case light-delegation-error LIGHT cached-keys 0
run_direct_case light-delegation-malformed LIGHT cached-keys 0
run_direct_case local-delegation-error LOCAL cached-keys 0
run_direct_case local-delegation-malformed LOCAL cached-keys 0
run_direct_case unsafe-api-config LIGHT cached-keys 0 70
run_direct_case unsafe-header-flag LIGHT cached-keys 0 70
run_direct_case unsafe-header-control LIGHT cached-keys 0 70
run_direct_case unsafe-cache-mode OFFLINE cached-keys 0 70
run_direct_case unsafe-cache-hardlink OFFLINE cached-keys 0 70
run_direct_case unsafe-cache-symlink OFFLINE cached-keys 0 70
run_direct_case unsafe-cache-content OFFLINE cached-keys 0 70
run_direct_case unsafe-wallet-name OFFLINE cached-keys 0 70
run_direct_case local-oversized-anchor LOCAL cached-keys 0
run_direct_case local-overflow-power LOCAL cached-keys 0
run_wrong_arity_case

# Freeze the hardened extraction boundary: one generic public call remains and
# the complete implementation lives in the authenticated action.
[[ "$(grep -c '^[[:space:]]*info-status)' "${CNTOOLS_SCRIPT}" || true)" == "1" ]] ||
  fail 'legacy governance info arm is missing or duplicated'
legacy_arm="${TEST_ROOT}/legacy-governance-info.arm"
awk '
  /^[[:space:]]*info-status\)/ { capture = 1 }
  capture { print }
  capture && /^[[:space:]]*;;[[:space:]]*#+/ { exit }
' "${CNTOOLS_SCRIPT}" > "${legacy_arm}"
[[ "$(grep -Fc \
      'cntools_compatibility_dispatch_action vote.governance.info' \
      "${legacy_arm}" || true)" == 1 ]] ||
  fail 'legacy governance info arm does not contain exactly one generic call'
if grep -Eq 'getDRepStatus|getDRepVotePower|getDRepAnchor|selectWallet|curl|cardano-cli' \
    "${legacy_arm}"; then
  fail 'legacy governance info arm retains extracted implementation bytes'
fi
for required_mapping in \
    '0) continue ;;' \
    '20|21) break 2 ;;' \
    '22) myExit ;;' \
    '*) waitToProceed; continue ;;'; do
  grep -Fq "${required_mapping}" "${legacy_arm}" ||
    fail "legacy governance info outcome mapping is missing: ${required_mapping}"
done
if grep -Fq 'CNTools action execution is inactive in Stage 3 shadow mode.' \
    "${ACTION_SOURCE}"; then
  fail 'governance info action remains inert'
fi
grep -Fq 'vote.governance.info)' \
  <(printf '%s\n' "${PRODUCTION_COMPATIBILITY_BRIDGE_DEFINITION}") ||
  fail 'production compatibility bridge no longer admits governance info'

printf 'CNTools governance info characterization/parity passed (16 public + 33 direct + 1 arity cases)\n'
