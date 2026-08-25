#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet-import-hardware characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/import/hardware/action.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/import/hardware"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-import-hardware.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
BASE_ADDR='addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
PAY_ADDR='addr_test1pppppppppppppppppppppppppppppppppppppppp'
REWARD_ADDR='stake_test1uuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu'
FAILURE_DIAGNOSTIC='DEVICE-SENSITIVE-DIAGNOSTIC-7f21'

cleanup_test() {
  if [[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools wallet-import-hardware test root preserved: %s\n' \
      "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools wallet-import-hardware characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${CNTOOLS_SCRIPT}" && ! -L "${CNTOOLS_SCRIPT}" ]] ||
  fail 'CNTools controller is missing or unsafe'
[[ -f "${ACTION_SOURCE}" && ! -L "${ACTION_SOURCE}" ]] ||
  fail 'dedicated hardware-wallet action is missing or unsafe'
[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk cmp find grep jq mktemp readlink sed sort stat wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
if command -v sha256sum >/dev/null 2>&1; then
  HASH_COMMAND=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  HASH_COMMAND=shasum
else
  fail 'sha256sum or shasum is required'
fi

# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"

digest_file() {
  file_hash "$1"
}

normalize_file() {
  local source="$1" target="$2" case_root="$3"
  sed -e "s|${case_root}|<CASE>|g" \
    -e "s|${TEST_ROOT}|<TEST_ROOT>|g" \
    "${source}" > "${target}"
}

extract_action_output() {
  local source="$1" target="$2"
  [[ "$(grep -c '^__CNTOOLS_WALLET_IMPORT_HARDWARE_BEGIN__$' "${source}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_WALLET_IMPORT_HARDWARE_END__$' "${source}" || true)" == 1 ]] ||
    fail 'wallet-import-hardware output markers changed'
  awk '
    $0 == "__CNTOOLS_WALLET_IMPORT_HARDWARE_BEGIN__" { capture=1; next }
    $0 == "__CNTOOLS_WALLET_IMPORT_HARDWARE_END__" { exit }
    capture { print }
  ' "${source}" > "${target}"
}

expected_digest() {
  local artifact="$1" scenario="$2"
  case "${artifact}:${scenario}" in
    # Filled from normalized, deterministic fixtures below. Keeping these
    # literals makes stdout, stderr, call ordering, command vectors, and the
    # complete mutation tree part of the frozen legacy contract.
    stdout:missing-cli)
      printf 'e32db1365ee44b926d37eb57a8c56f1dd182d9a20c3cab0c8ba662f7f520e1dc\n' ;;
    stdout:version-failure|stdout:cancel-name|stdout:derivation-failure|\
      stdout:unlock-failure)
      printf 'bae2cc7ba362bf0e2cfb64c9123c8b9250ea5af26cbf709e26274ad8adab1d58\n' ;;
    stdout:command-failure)
      printf 'd6f2b64d90730eb0ea075e5219eefe85c59f201565c7e69be94ce12d9e544bdd\n' ;;
    stdout:no-governance|stdout:success-local|stdout:success-light|\
      stdout:success-offline|stdout:existing-empty|stdout:malformed-json|\
      stdout:unsafe-filename|stdout:symlink-wallet)
      printf 'f0ca3aec99d1a16eb20ccab7effa1c902e57a1d541dd817819085e03b2cb6bd8\n' ;;
    stdout:address-failure)
      printf 'cca0d766304db4f89c694548acb561e80256a9284687a5b9f3054fd84662c766\n' ;;
    stdout:wait-false-missing-cli)
      printf 'a63b443d271fb660e7072e5881f1d4da5cd4b62658341b192bff562f909118d0\n' ;;
    stdout:command-failure-wait-false)
      printf 'c2b3d30cf3f00da4b1770ff8b810d7ac3236b8a8611237f4f21e0c7f1e0a0b9d\n' ;;
    stderr:no-governance)
      printf 'a75c2dd42b42333661574b685e0c6c165856bcd9a4e4525421ee61e593c9dcdb\n' ;;
    stderr:malformed-json)
      printf '57d6731f43ac41d532d1aa7790c5f550d33cec4c63b100341523b67baaf96f36\n' ;;
    stderr:command-failure-wait-false)
      printf '2b2f783007038a7b657e6aae6923cdf92360bc7967af3f04ff258138614656f9\n' ;;
    stderr:*)
      printf 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n' ;;
    events:missing-cli)
      printf '0425304de9d3f54980837c7422da9ca6a4e01899c4aace423a38ae0edfa1d45d\n' ;;
    events:version-failure)
      printf 'fac873c196a4f1b008db7b24492dd8f09f54319a97ea4354225264f335ceca56\n' ;;
    events:cancel-name)
      printf 'fb557c1d59737ee64dd3f7fdbf0e8bc4a5b3b4e98159de0a3b3de3881a1b358a\n' ;;
    events:derivation-failure)
      printf 'eb45e3f3dbc40705959b061f2d312d2e310b475cb7a88f2c14891020272d67d6\n' ;;
    events:unlock-failure)
      printf 'd1fff959c416362b187c7859330aecfb6b11b0bf268bd82df63691c8f3bac3e0\n' ;;
    events:command-failure)
      printf '4f903622a650429508b8d6ead98b837c11f377b3e88ba3518c573d72fbbf4d65\n' ;;
    events:no-governance)
      printf '298fcc5dbb3f75fea27dea58e6d4073fe56d78d67bff53f773e156074f3d6497\n' ;;
    events:success-local)
      printf '0b3f5d5cc2672ab2f6844dd576deddb037ad61f53eb66f10e282a164b9c0dfe9\n' ;;
    events:success-light)
      printf '7e7a38236c369270aa519c4655031f6fd89eef0bf2958aa2a692ad222d7beb8d\n' ;;
    events:success-offline|events:existing-empty|events:malformed-json|\
      events:address-failure|events:symlink-wallet)
      printf 'ce48199e13223cf1e6aaf35e9f949a59dfd55119294e3535750283315fa8093d\n' ;;
    events:unsafe-filename)
      printf 'b5e18475021a3b16bb31422d7b032b18cfbdca8dc59ca5024c5242438c5ded89\n' ;;
    events:wait-false-missing-cli)
      printf 'bde34efb0b680453585a92092151f35fd18e4c8ab4119f6b2e8ef70b473b7c03\n' ;;
    events:command-failure-wait-false)
      printf 'f7907d979ec644b2dac9436bd2ade6f2a2dc9857dd0970d6731603165fc13e24\n' ;;
    commands:missing-cli|commands:version-failure|commands:cancel-name|\
      commands:derivation-failure|commands:unlock-failure)
      printf 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n' ;;
    commands:no-governance)
      printf '946da4ce29eca7caf96f9edf2eb7277aa33b974a2257a93fc62a430ff50cb713\n' ;;
    commands:unsafe-filename)
      printf 'd39436708ec6e1e89aa6847711c805132e5ca6beffff6dadc346234b3f98b1c6\n' ;;
    commands:*)
      printf 'e6353f69fae63d759c226844f3e3a0cb6e378d79d36ec8a4a80368652b26d288\n' ;;
    tree:missing-cli|tree:version-failure|tree:cancel-name|tree:unlock-failure|\
      tree:command-failure)
      printf '7eff0ea8e195ce653cf2266cdd96550b237c9704bac53fb15f0b9ba885d06fe1\n' ;;
    tree:derivation-failure)
      printf 'bc1677f5cd41cd077cb736e19dc011e0b4bc3e7021d21f2f29e242920e41b4d3\n' ;;
    tree:no-governance)
      printf 'e6fc57676e0881b187adbf13bed25cc1210af7b85942c26229f17a1c60f933b5\n' ;;
    tree:success-local|tree:success-light|tree:success-offline|\
      tree:existing-empty|tree:wait-false-missing-cli)
      printf '88659711888e64e82132dbf20efa932a035af1f97edfda798302bc5269d89522\n' ;;
    tree:malformed-json)
      printf 'b1cb69012a472c1bef46d933cac08db272e8fe7296cd99e26f7db22416c64918\n' ;;
    tree:address-failure)
      printf '690900d4c39d13640122da43fea9fb7ebbc5907ab66944b00c401351f1315e79\n' ;;
    tree:unsafe-filename)
      printf '2c3aa2777676d931f96f298788941cbb10242bb8be351ccfffefd3de9cbf7d14\n' ;;
    tree:symlink-wallet)
      printf 'b82e12e9d5e3fa10c22998e8f2aca8a39416db02f16c4fd66324ab8b5ec325e9\n' ;;
    tree:command-failure-wait-false)
      printf '84f17bb6014305fa38bf134ae385e8627253cac6bd44892ffb2f54a5818357e3\n' ;;
    *) fail "missing contract digest: ${artifact}:${scenario}" ;;
  esac
}

assert_contract_digest() {
  local artifact="$1" scenario="$2" target="$3"
  local expected="" actual=""
  actual="$(digest_file "${target}")"
  if [[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_DUMP_DIGESTS:-N}" == Y ]]; then
    printf '%s:%s %s\n' "${artifact}" "${scenario}" "${actual}"
    return 0
  fi
  expected="$(expected_digest "${artifact}" "${scenario}")"
  [[ "${expected}" == "${actual}" ]] || {
    printf '%s:%s expected=%s actual=%s\n' \
      "${artifact}" "${scenario}" "${expected}" "${actual}" >&2
    awk '{ printf "%04d %s\\n", NR, $0 }' "${target}" >&2
    fail "${scenario} ${artifact} contract changed"
  }
}

scenario_mode() {
  case "$1" in
    success-local) printf 'LOCAL\n' ;;
    success-light) printf 'LIGHT\n' ;;
    *) printf 'OFFLINE\n' ;;
  esac
}

scenario_governance_choice() {
  case "$1" in
    no-governance) printf 'n\n' ;;
    *) printf 'y\n' ;;
  esac
}

scenario_reaches_governance() {
  case "$1" in
    missing-cli|version-failure|cancel-name|derivation-failure|unlock-failure)
      return 1
      ;;
    *) return 0 ;;
  esac
}

# The production bridge authenticates an installed generation. Public-route
# parity substitutes only that authority setup, then runs the real dispatcher
# and the exact extracted action selected by the public menu.
cntools_compatibility_dispatch_action() {
  local action_id="${1:-}" private_root="" context_file=""
  local result_file="" status=0

  [[ "${action_id}" == wallet.import.hardware && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/wallet-import-hardware-test-dispatch.XXXXXXXX")" ||
    return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  write_context "${context_file}" "${CNTOOLS_MODE}" "${NODE_HOME}" || return 70
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    status=0
  else
    status=$?
  fi
  ACTION_ARMED=N
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || status=70
  rm -f -- "${result_file}" "${context_file}" >/dev/null 2>&1 || status=70
  rmdir -- "${private_root}" >/dev/null 2>&1 || status=70
  printf '__CNTOOLS_WALLET_IMPORT_HARDWARE_END__\n'
  return "${status}"
}

run_case() (
  local scenario="$1" mode="" governance_choice="" case_root=""
  local runtime_root="" wallet_root="" full_stdout="" action_stdout=""
  local stderr_file="" event_log="" command_log="" blocked_log=""
  local before="" after="" normalized_stdout="" normalized_stderr=""
  local normalized_events="" normalized_commands="" normalized_tree=""
  local status=0

  case_root="${TEST_ROOT}/cases/${scenario}"
  runtime_root="${case_root}/runtime"
  wallet_root="${runtime_root}/wallet"
  full_stdout="${case_root}/full.stdout"
  action_stdout="${case_root}/action.stdout"
  stderr_file="${case_root}/stderr"
  event_log="${case_root}/events"
  command_log="${case_root}/commands"
  blocked_log="${case_root}/blocked"
  before="${case_root}/before.tree"
  after="${case_root}/after.tree"
  normalized_stdout="${case_root}/contract.stdout"
  normalized_stderr="${case_root}/contract.stderr"
  normalized_events="${case_root}/contract.events"
  normalized_commands="${case_root}/contract.commands"
  normalized_tree="${case_root}/contract.tree"
  mode="$(scenario_mode "${scenario}")"
  governance_choice="$(scenario_governance_choice "${scenario}")"

  mkdir -p -- "${wallet_root}" "${runtime_root}/pool" \
    "${runtime_root}/asset" "${runtime_root}/tmp" \
    "${runtime_root}/home/files"
  chmod 0700 "${wallet_root}" "${runtime_root}/tmp"
  jq -nS '{
    schemaVersion: 1,
    implementation: "cnode",
    tools: {"cardano-hw-cli": {minimumVersion: "1.17.0"}}
  }' > "${runtime_root}/home/files/cnode-release.json"
  chmod 0600 "${runtime_root}/home/files/cnode-release.json"
  case "${scenario}" in
    symlink-wallet)
      mkdir -p -- "${runtime_root}/outside-wallet"
      ln -s -- "${runtime_root}/outside-wallet" \
        "${wallet_root}/fixture_wallet"
      ;;
    existing-empty)
      mkdir -p -- "${wallet_root}/fixture_wallet"
      ;;
  esac
  tree_snapshot "${runtime_root}" "${before}" ||
    fail "${scenario} pre-snapshot failed"
  : > "${event_log}"
  : > "${command_log}"
  : > "${blocked_log}"

  if (
    set +e; set +u; set +o pipefail
    export LC_ALL=C TZ=UTC PATH="${FAKE_BIN}:${BASE_PATH}"
    HOME="${runtime_root}/home"; NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"; WALLET_FOLDER="${wallet_root}"
    POOL_FOLDER="${runtime_root}/pool"; ASSET_FOLDER="${runtime_root}/asset"
    BLOCKLOG_DB="${runtime_root}/absent.db"; NETWORK_NAME=Preview
    ADVANCED_MODE=true; CNTOOLS_MODE="${mode}"; CNTOOLS_MODE_COLOR=""
    price_now=""; slotnum=1000
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    NETWORK_IDENTIFIER='--testnet-magic 42'
    CCLI="${FAKE_BIN}/cardano-cli"
    EVENT_LOG="${event_log}"; COMMAND_LOG="${command_log}"
    BLOCKED_LOG="${blocked_log}"; SCENARIO="${scenario}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_LOG="${command_log}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_WALLET_ROOT="${wallet_root}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_EXTERNAL="${runtime_root}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_HW_MODE=success
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_CLI_MODE=success
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_SECRET="${FAILURE_DIAGNOSTIC}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_BASE="${BASE_ADDR}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_PAY="${PAY_ADDR}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REWARD="${REWARD_ADDR}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REAL_MKDIR="${DIRECT_REAL_MKDIR}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REAL_MV="${DIRECT_REAL_MV}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REAL_RMDIR="${DIRECT_REAL_RMDIR}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_MV_ERROR_AFTER=N
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_FAIL_LOCK_RELEASE=N
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_SIGNAL_AFTER_MOVE=N
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_SIGNAL_LOCK_ACQUIRE=N
    ACTION_ARMED=N; CAPTURE_ACTIVE=N; WAIT_COUNT=0
    WALLET_DERIVATION_PATH_FILENAME=derivation.path
    WALLET_HW_PAY_SK_FILENAME=payment.hwsfile
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_HW_STAKE_SK_FILENAME=stake.hwsfile
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_GOV_HW_DREP_SK_FILENAME=drep.hwsfile
    WALLET_GOV_DREP_VK_FILENAME=drep.vkey
    WALLET_GOV_HW_CC_COLD_SK_FILENAME=cc-cold.hwsfile
    WALLET_GOV_CC_COLD_VK_FILENAME=cc-cold.vkey
    WALLET_GOV_HW_CC_HOT_SK_FILENAME=cc-hot.hwsfile
    WALLET_GOV_CC_HOT_VK_FILENAME=cc-hot.vkey
    WALLET_MULTISIG_PREFIX=ms_
    WALLET_BASE_ADDR_FILENAME=base.addr
    WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_STAKE_ADDR_FILENAME=stake.addr
    WALLET_PAY_CRED_FILENAME=payment.cred
    WALLET_STAKE_CRED_FILENAME=stake.cred
    if [[ "${scenario}" == unsafe-filename ]]; then
      WALLET_HW_PAY_SK_FILENAME='../../escaped-payment.hwsfile'
    fi

    record_event() {
      [[ "${CAPTURE_ACTIVE:-N}" == Y ]] || return 0
      printf '%s\n' "$*" >> "${EVENT_LOG}"
    }

    println() {
      local level="${1:-}"
      shift || true
      case "${level}" in
        ACTION)
          record_event "action-vector:$*"
          ;;
        LOG) ;;
        OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@" ;;
        *) printf '%b\n' "${level}" "$@" ;;
      esac
    }

    clear() {
      if [[ "${ACTION_ARMED:-N}" == Y ]]; then
        ACTION_ARMED=N
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_WALLET_IMPORT_HARDWARE_BEGIN__\n'
        record_event "action:begin:${CNTOOLS_MODE}"
      elif [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
        printf '__CNTOOLS_WALLET_IMPORT_HARDWARE_END__\n'
        CAPTURE_ACTIVE=N
      fi
      record_event 'terminal:clear'
    }

    getEpoch() { printf '5\n'; }
    timeUntilNextEpoch() { printf '0\n'; }
    timeLeft() { printf 'delta-%s' "${1:-}"; }
    slotInterval() { printf '20\n'; }
    getSlotTipRef() { printf '1000\n'; }
    getNodeMetrics() { slotnum=1000; }
    getPriceInfo() { price_now=""; }
    updateProtocolParams() { :; }

    getAnswerAnyCust() {
      local output_variable="${1:-}"
      shift || true
      record_event "prompt:${output_variable}"
      case "${output_variable}" in
        prompted)
          case "${PROMPT_COUNT:-0}" in
            0)
              if [[ "${SCENARIO}" == cancel-name ]]; then
                PROMPT_COUNT=$((PROMPT_COUNT + 1))
                return 1
              fi
              printf -v "${output_variable}" '%s' fixture_wallet
              ;;
            1) printf -v "${output_variable}" '%s' 7 ;;
            2) printf -v "${output_variable}" '%s' 11 ;;
            *) return 70 ;;
          esac
          PROMPT_COUNT=$((PROMPT_COUNT + 1))
          ;;
        *) return 70 ;;
      esac
    }

    select_opt() {
      local choice="" menu="" option="" index=0 completed=N
      grep -Fqx 'public-action-complete' "${EVENT_LOG}" 2>/dev/null && completed=Y
      if [[ "${completed}" == Y && "${1:-}" == '[m] Mnemonic' ]]; then
        choice=b
      elif [[ "${completed}" == Y && "${1:-}" == '[n] New' ]]; then
        choice=h
      elif [[ "${completed}" == Y && "${1:-}" == '[w] Wallet' ]]; then
        choice=q
      else
        choice="${CHOICES[CHOICE_CURSOR]:-}"
      fi
      case "${1:-}" in
        '[w] Wallet') menu=main ;;
        '[n] New') menu=wallet ;;
        '[m] Mnemonic') menu=import ;;
        '[n] No') menu=governance ;;
        *) fail "unexpected public menu: ${1:-<empty>}" ;;
      esac
      [[ -n "${choice}" ]] || fail "${menu} menu exhausted choices"
      [[ "${completed}:${menu}" == Y:import ||
         "${completed}:${menu}" == Y:wallet ||
         "${completed}:${menu}" == Y:main ]] ||
        CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
      printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG}"
      for option in "$@"; do
        if [[ "${option}" == "[${choice}]"* ]]; then
          selected_value="${option}"
          if [[ "${menu}:${choice}" == import:w ]]; then
            ACTION_ARMED=Y
          fi
          return "${index}"
        fi
        index=$((index + 1))
      done
      fail "choice ${choice} was unavailable in ${menu} menu"
    }

    waitToProceed() {
      WAIT_COUNT=$((WAIT_COUNT + 1))
      record_event "helper:waitToProceed:${WAIT_COUNT}"
      case "${SCENARIO}:${WAIT_COUNT}" in
        success-local:2|success-light:2|success-offline:2|no-governance:2)
          printf 'public-action-complete\n' >> "${EVENT_LOG}"
          ;;
      esac
      case "${SCENARIO}:${WAIT_COUNT}" in
        wait-false-missing-cli:1|command-failure-wait-false:1) return 1 ;;
        *) return 0 ;;
      esac
    }

    printWalletInfo() {
      printf 'Hardware wallet fixture summary\n'
      record_event 'helper:printWalletInfo'
    }

    curl() { printf 'curl\n' >> "${BLOCKED_LOG}"; return 97; }
    wget() { printf 'wget\n' >> "${BLOCKED_LOG}"; return 97; }
    git() { printf 'git\n' >> "${BLOCKED_LOG}"; return 97; }
    ssh() { printf 'ssh\n' >> "${BLOCKED_LOG}"; return 97; }
    nc() { printf 'nc\n' >> "${BLOCKED_LOG}"; return 97; }
    cardano-cli() {
      {
        printf 'cardano-cli'
        printf '\t%q' "$@"
        printf '\n'
      } >> "${BLOCKED_LOG}"
      return 97
    }

    myExit() {
      local exit_status="${1:-0}" message="${2:-}"
      [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
        fail 'public menu did not consume every scripted choice'
      [[ "${CAPTURE_ACTIVE}" == N ]] ||
        fail 'action output capture remained active at exit'
      printf 'exit:%s:%s\n' "${exit_status}" "${message}" >> "${EVENT_LOG}"
      exit "${exit_status}"
    }

    if scenario_reaches_governance "${scenario}"; then
      CHOICES=(w i w "${governance_choice}" b h q)
    else
      CHOICES=(w i w h q)
    fi
    CHOICE_CURSOR=0
    PROMPT_COUNT=0
    base_addr='stale-base-address'
    pay_addr='stale-payment-address'
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi

  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"
  extract_action_output "${full_stdout}" "${action_stdout}"
  [[ ! -s "${blocked_log}" ]] ||
    fail "${scenario} invoked network, VCS, SSH, or cardano-cli"

  normalize_file "${action_stdout}" "${normalized_stdout}" "${case_root}"
  normalize_file "${stderr_file}" "${normalized_stderr}" "${case_root}"
  normalize_file "${event_log}" "${normalized_events}" "${case_root}"
  normalize_file "${command_log}" "${normalized_commands}" "${case_root}"
  tree_snapshot "${runtime_root}" "${after}" ||
    fail "${scenario} post-snapshot failed"
  normalize_file "${after}" "${normalized_tree}" "${case_root}"

  grep -Fq ' >> WALLET >> IMPORT >> HARDWARE WALLET' "${action_stdout}" ||
    fail "${scenario} action header changed"
  grep -Fq 'cardano-hw-cli' "${action_stdout}" ||
    fail "${scenario} hardware note changed"
  [[ ! -s "${stderr_file}" ]] || fail "${scenario} emitted stderr"
  ! grep -Fq "${FAILURE_DIAGNOSTIC}" "${action_stdout}" "${stderr_file}" ||
    fail "${scenario} reflected a hardware/tool secret"
  grep -Fq 'action:compatibility-dispatch' "${event_log}" ||
    fail "${scenario} bypassed the compatibility dispatcher"
  [[ "$(grep -Fc 'action:compatibility-dispatch' "${event_log}")" == 1 ]] ||
    fail "${scenario} dispatched more than once"
  if [[ "${scenario}" == cancel-name ]]; then
    ! grep -Fq 'HW Wallet Imported :' "${action_stdout}" ||
      fail 'cancel-name reported success'
    [[ ! -e "${wallet_root}/fixture_wallet" ]] ||
      fail 'cancel-name mutated the wallet root'
  else
    grep -Fq 'HW Wallet Imported : fixture_wallet' "${action_stdout}" ||
      fail "${scenario} public success output changed"
    grep -Fq "Address            : ${BASE_ADDR}" "${action_stdout}" ||
      fail "${scenario} public base address changed"
    grep -Fq "Payment Address    : ${PAY_ADDR}" "${action_stdout}" ||
      fail "${scenario} public payment address changed"
    [[ -d "${wallet_root}/fixture_wallet" &&
       "$(file_mode "${wallet_root}/fixture_wallet")" == 700 ]] ||
      fail "${scenario} did not publish an owner-private wallet"
    if [[ "${scenario}" == no-governance ]]; then
      [[ "$(find "${wallet_root}/fixture_wallet" -type f -print | wc -l | tr -d '[:space:]')" == 16 ]] ||
        fail 'no-governance public artifact count changed'
    else
      [[ "$(find "${wallet_root}/fixture_wallet" -type f -print | wc -l | tr -d '[:space:]')" == 24 ]] ||
        fail "${scenario} public artifact count changed"
    fi
  fi
  grep -Fq 'menu:import:w' "${event_log}" ||
    fail "${scenario} public import route changed"
  grep -Fq 'exit:0:CNTools closed!' "${event_log}" ||
    fail "${scenario} public navigation did not return home"
  [[ -z "$(find "${runtime_root}/tmp" -mindepth 1 -print -quit)" ]] ||
    fail "${scenario} left private bridge artifacts"
)

write_direct_fake_commands() {
  local real_mkdir="" real_mv="" real_rmdir=""

  mkdir -p -- "${FAKE_BIN}"
  chmod 0700 "${FAKE_BIN}"
  real_mkdir="$(builtin type -P mkdir)" || fail 'could not resolve mkdir'
  real_mv="$(builtin type -P mv)" || fail 'could not resolve mv'
  real_rmdir="$(builtin type -P rmdir)" || fail 'could not resolve rmdir'
  DIRECT_REAL_MKDIR="${real_mkdir}"
  DIRECT_REAL_MV="${real_mv}"
  DIRECT_REAL_RMDIR="${real_rmdir}"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'printf '\''cardano-hw-cli'\'' >> "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_LOG:?}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  if [[ "${normalized}" == "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_WALLET_ROOT}/."*.cntools-wallet-import-hardware.stage.*/* ]]; then normalized="<stage>/${normalized##*/}"; fi' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_LOG:?}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_LOG:?}"' \
    'case "$*" in' \
    '  version)' \
    '    case "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_HW_MODE:-success}" in' \
    '      version-fail) printf '\''%s\n'\'' "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_SECRET:?}" >&2; exit 18 ;;' \
    '      version-malformed) printf '\''unsafe-version\\033[31m\n'\''; exit 0 ;;' \
    '      old-version) printf '\''Cardano HW CLI Tool version 1.16.9\n'\''; exit 0 ;;' \
    '      *) printf '\''Cardano HW CLI Tool version 1.20.0\n'\''; exit 0 ;;' \
    '    esac' \
    '    ;;' \
    '  "device version")' \
    '    case "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_HW_MODE:-success}" in' \
    '      device-fail) printf '\''%s\\033[31m\n'\'' "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_SECRET:?}" >&2; exit 17 ;;' \
    '      device-malformed) printf '\''unsafe-device\\033[31m\n'\''; exit 0 ;;' \
    '      *) printf '\''Ledger app version 7.1.2\n'\''; exit 0 ;;' \
    '    esac' \
    '    ;;' \
    '  "address key-gen "*) ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    'paths=(); vkeys=(); hwsfiles=(); previous=""' \
    'for argument in "$@"; do' \
    '  case "${previous}" in --path) paths+=("${argument}") ;; --verification-key-file) vkeys+=("${argument}") ;; --hw-signing-file) hwsfiles+=("${argument}") ;; esac' \
    '  previous="${argument}"' \
    'done' \
    '[[ "${#paths[@]}" == "${#vkeys[@]}" && "${#paths[@]}" == "${#hwsfiles[@]}" ]] || exit 96' \
    'for ((index=0; index<${#paths[@]}; index++)); do' \
    '  path="${paths[index]}"; vkey="${vkeys[index]}"; hws="${hwsfiles[index]}"' \
    '  case "${path}" in' \
    '    1852H/*/0/*|1854H/*/0/*) vtype=PaymentVerificationKeyShelley_ed25519; htype=PaymentHWSigningFileShelley_ed25519 ;;' \
    '    1852H/*/2/*|1854H/*/2/*) vtype=StakeVerificationKeyShelley_ed25519; htype=StakeHWSigningFileShelley_ed25519 ;;' \
    '    1852H/*/3/*) vtype=DRepVerificationKey_ed25519; htype=DRepHWSigningFile_ed25519 ;;' \
    '    1852H/*/4/*) vtype=CommitteeColdVerificationKey_ed25519; htype=CommitteeColdHWSigningFile_ed25519 ;;' \
    '    1852H/*/5/*) vtype=CommitteeHotVerificationKey_ed25519; htype=CommitteeHotHWSigningFile_ed25519 ;;' \
    '    *) exit 96 ;;' \
    '  esac' \
    '  printf -v public '\''%064x'\'' "$((index + 1))"' \
    '  chain=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    '  vpublic="${public}"; output_path="${path}"; output_vtype="${vtype}"; output_htype="${htype}"' \
    '  [[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_HW_MODE:-success}" != pair-mismatch || "${index}" != 0 ]] || vpublic=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' \
    '  [[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_HW_MODE:-success}" != wrong-path || "${index}" != 0 ]] || output_path=1852H/1815H/999H/0/0' \
    '  [[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_HW_MODE:-success}" != wrong-type || "${index}" != 0 ]] || output_vtype=StakeVerificationKeyShelley_ed25519' \
    '  printf '\''{"type":"%s","description":"device-vkey","cborHex":"5820%s"}\n'\'' "${output_vtype}" "${vpublic}" > "${vkey}"' \
    '  printf '\''{"type":"%s","description":"device-hws","path":"%s","cborXPubKeyHex":"5840%s%s"}\n'\'' "${output_htype}" "${output_path}" "${public}" "${chain}" > "${hws}"' \
    '  if [[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_HW_MODE:-success}" == export-fail && "${index}" == 0 ]]; then printf '\''%s\\033[31m\n'\'' "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_SECRET:?}" >&2; exit 19; fi' \
    'done' \
    'case "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_HW_MODE:-success}" in' \
    '  malformed-json) printf '\''not-json\n'\'' > "${vkeys[0]}" ;;' \
    '  hardlink) ln "${vkeys[0]}" "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_EXTERNAL:?}/hardware-hardlink" ;;' \
    '  symlink-output) printf '\''outside\n'\'' > "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_EXTERNAL:?}/outside-vkey"; rm -f -- "${vkeys[0]}"; ln -s "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_EXTERNAL:?}/outside-vkey" "${vkeys[0]}" ;;' \
    '  special-output) rm -f -- "${vkeys[0]}"; mkfifo "${vkeys[0]}" ;;' \
    '  extra-output) printf '\''unexpected\n'\'' > "${vkeys[0]%/*}/unexpected.artifact" ;;' \
    'esac' \
    'exit 0' \
    > "${FAKE_BIN}/cardano-hw-cli"
  chmod 0755 "${FAKE_BIN}/cardano-hw-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'printf '\''cardano-cli'\'' >> "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_LOG:?}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  if [[ "${normalized}" == "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_WALLET_ROOT}/."*.cntools-wallet-import-hardware.stage.*/* ]]; then normalized="<stage>/${normalized##*/}"; fi' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_LOG:?}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_LOG:?}"' \
    'previous=""; output=""' \
    'for argument in "$@"; do [[ "${previous}" == --out-file ]] && output="${argument}"; previous="${argument}"; done' \
    '[[ -n "${output}" ]] || exit 96' \
    'case "$*" in' \
    '  "address build "*) if [[ "$*" == *" --stake-verification-key-file "* ]]; then kind=base; else kind=payment; fi ;;' \
    '  "latest stake-address build "*) kind=reward ;;' \
    '  "address key-hash "*|"latest stake-address key-hash "*) kind=credential ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    'if [[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_CLI_MODE:-success}" == "fail-${kind}" ]]; then printf '\''%s\\033[31m\n'\'' "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_SECRET:?}" >&2; exit 23; fi' \
    'case "${kind}" in' \
    '  base) value="${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_BASE:?}" ;;' \
    '  payment) value="${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_PAY:?}" ;;' \
    '  reward) value="${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REWARD:?}" ;;' \
    '  credential) value=00000000000000000000000000000000000000000000000000000001 ;;' \
    'esac' \
    '[[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_CLI_MODE:-success}" != "malformed-${kind}" ]] || value='\''unsafe\\033[31m'\''' \
    '[[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_CLI_MODE:-success}" != "wrong-network-${kind}" ]] || { case "${kind}" in base|payment) value=addr1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq ;; reward) value=stake1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq ;; esac; }' \
    'printf '\''%b\n'\'' "${value}" > "${output}"' \
    'if [[ "${output##*/}" == ms_stake.cred ]]; then' \
    '  case "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_CLI_MODE:-success}" in' \
    '    late-tamper) printf '\''tampered\n'\'' > "${output%/*}/payment.hwsfile" ;;' \
    '    collision) mkdir -m 0700 -- "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_WALLET_ROOT}/fixture_wallet"; printf '\''collision\n'\'' > "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_WALLET_ROOT}/fixture_wallet/sentinel" ;;' \
    '    stage-swap) stage="${output%/*}"; "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REAL_MV:?}" -- "${stage}" "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_EXTERNAL:?}/swapped-stage"; ln -s "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_EXTERNAL:?}/swapped-stage" "${stage}" ;;' \
    '    lock-swap) lock="${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_WALLET_ROOT}/.fixture_wallet.cntools-wallet-import-hardware.lock"; "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REAL_RMDIR:?}" -- "${lock}"; "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REAL_MKDIR:?}" -m 0700 -- "${lock}" ;;' \
    '  esac' \
    'fi' \
    'exit 0' \
    > "${FAKE_BIN}/cardano-cli"
  chmod 0755 "${FAKE_BIN}/cardano-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target="${*: -1}"' \
    '"${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REAL_MKDIR:?}" "$@" || exit $?' \
    'if [[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_SIGNAL_LOCK_ACQUIRE:-N}" == Y && "${target}" == *.cntools-wallet-import-hardware.lock ]]; then kill -TERM "${PPID}"; fi' \
    'exit 0' \
    > "${FAKE_BIN}/mkdir"
  chmod 0755 "${FAKE_BIN}/mkdir"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target="${*: -1}"' \
    'if [[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_FAIL_LOCK_RELEASE:-N}" == Y && "${target}" == *.cntools-wallet-import-hardware.lock ]]; then exit 41; fi' \
    'exec "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REAL_RMDIR:?}" "$@"' \
    > "${FAKE_BIN}/rmdir"
  chmod 0755 "${FAKE_BIN}/rmdir"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'publish=N' \
    'for argument in "$@"; do [[ "${argument}" != -n ]] || publish=Y; done' \
    '"${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REAL_MV:?}" "$@" || exit $?' \
    'if [[ "${publish}" == Y ]]; then' \
    '  [[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_SIGNAL_AFTER_MOVE:-N}" != Y ]] || kill -TERM "${PPID}"' \
    '  [[ "${CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_MV_ERROR_AFTER:-N}" != Y ]] || exit 44' \
    'fi' \
    'exit 0' \
    > "${FAKE_BIN}/mv"
  chmod 0755 "${FAKE_BIN}/mv"
}

write_direct_expected_stdout() {
  local scenario="$1" target="$2"

  : > "${target}"
  case "${scenario}" in
    direct-unsafe-root|direct-unsafe-filename|direct-ccli-shadow|\
      direct-ccli-symlink) return 0 ;;
  esac
  printf '%s\n\n\n' ' >> WALLET >> IMPORT >> HARDWARE WALLET' >> "${target}"
  case "${scenario}" in
    direct-missing-hwcli)
      printf '%s\n' \
        'ERROR: cardano-hw-cli not found or not executable.' \
        'Install hardware-wallet support with guild-deploy.sh -s w.' \
        >> "${target}"
      ;;
    direct-version-fail|direct-old-version)
      printf '%s\n' \
        'ERROR: cardano-hw-cli is unavailable, incompatible, or below the required version.' \
        >> "${target}"
      ;;
    direct-invalid-name)
      printf '%s\n' 'ERROR: Invalid wallet name, please retry!' >> "${target}"
      ;;
    direct-invalid-account|direct-invalid-key)
      printf '%s\n' 'ERROR: Invalid derivation index, please retry!' >> "${target}"
      ;;
    direct-duplicate|direct-destination-symlink)
      printf '%s\n' \
        'WARN: A wallet fixture_wallet already exists' \
        '      Choose another name or delete the existing one' \
        >> "${target}"
      ;;
    direct-lock-contention)
      printf '%s\n' \
        'ERROR: hardware wallet import is already in progress, please retry!' \
        >> "${target}"
      ;;
    direct-device-fail)
      printf '%s\n' \
        'Include governance (drep & committee) keys (only Ledger supported)?' \
        'ERROR: unable to access an unlocked supported hardware device.' \
        >> "${target}"
      ;;
    direct-export-fail)
      printf '%s\n' \
        'Include governance (drep & committee) keys (only Ledger supported)?' \
        'ERROR: failure during hardware wallet key extraction!' \
        >> "${target}"
      ;;
    direct-derive-fail)
      printf '%s\n' \
        'Include governance (drep & committee) keys (only Ledger supported)?' \
        'ERROR: failure while deriving hardware wallet addresses.' \
        >> "${target}"
      ;;
    direct-success-local|direct-success-light|direct-success-offline|\
      direct-success-no-governance|direct-wait-false|direct-mv-error-after|\
      direct-postcommit-lock-failure)
      printf '%s\n' \
        'Include governance (drep & committee) keys (only Ledger supported)?' \
        'HW Wallet Imported : fixture_wallet' \
        "Address            : ${BASE_ADDR}" \
        "Payment Address    : ${PAY_ADDR}" \
        '' \
        'Hardware wallet fixture summary' \
        >> "${target}"
      ;;
    direct-cancel-name|direct-version-malformed|direct-release-malformed|\
      direct-release-unsafe|direct-hwcli-shadow|direct-hwcli-symlink|\
      direct-signal-lock-acquire) ;;
    *)
      printf '%s\n' \
        'Include governance (drep & committee) keys (only Ledger supported)?' \
        >> "${target}"
      ;;
  esac
}

direct_scenario_is_invariant() {
  case "$1" in
    direct-unsafe-root|direct-unsafe-filename|direct-ccli-shadow|\
      direct-ccli-symlink|direct-version-malformed|direct-release-malformed|\
      direct-release-unsafe|direct-hwcli-shadow|direct-hwcli-symlink|\
      direct-device-malformed|direct-malformed-json|direct-pair-mismatch|\
      direct-wrong-path|direct-wrong-type|direct-hardlink|\
      direct-symlink-output|direct-special-output|direct-extra-output|\
      direct-malformed-address|direct-wrong-network|direct-late-tamper|\
      direct-publish-collision|direct-stage-swap|direct-lock-swap|\
      direct-signal-lock-acquire)
      return 0
      ;;
    *) return 1 ;;
  esac
}

run_direct_case() {
  local scenario="$1" mode="$2"
  local case_root="${TEST_ROOT}/direct/${scenario}"
  local runtime_root="${case_root}/runtime"
  local wallet_root="${runtime_root}/wallet"
  local outside_root="${runtime_root}/outside"
  local private_root="${runtime_root}/private"
  local node_home="${runtime_root}/home"
  local capture_root="${case_root}/capture"
  local stdout_file="${capture_root}/stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local event_log="${capture_root}/events"
  local command_log="${capture_root}/commands"
  local before_tree="${capture_root}/before.tree"
  local after_tree="${capture_root}/after.tree"
  local direct_name=fixture_wallet direct_account=7 direct_key=11
  local governance=Y cancel_name=N hw_mode=success cli_mode=success
  local direct_path="${FAKE_BIN}:${BASE_PATH}" ccli_value=cardano-cli
  local mv_error_after=N fail_lock_release=N signal_after_move=N
  local signal_lock_acquire=N
  local expected_status=0 direct_status=0 context_hash="" manifest_hash=""
  local wallet_count=0 expected_count=24 case_bin=""

  mkdir -p -- "${wallet_root}" "${outside_root}" "${private_root}" \
    "${node_home}/files" "${capture_root}"
  chmod 0700 "${wallet_root}" "${outside_root}" "${private_root}"
  jq -nS '{
    schemaVersion: 1,
    implementation: "cnode",
    tools: {"cardano-hw-cli": {minimumVersion: "1.17.0"}}
  }' > "${node_home}/files/cnode-release.json"
  chmod 0600 "${node_home}/files/cnode-release.json"
  case "${scenario}" in
    direct-success-local|direct-success-light|direct-success-offline) ;;
    direct-success-no-governance) governance=N; expected_count=16 ;;
    direct-wait-false) ;;
    direct-cancel-name) cancel_name=Y ;;
    direct-invalid-name) direct_name='../escape' ;;
    direct-invalid-account) direct_account=0007 ;;
    direct-invalid-key) direct_key=2147483648 ;;
    direct-duplicate)
      mkdir -m 0700 -- "${wallet_root}/fixture_wallet"
      printf 'existing\n' > "${wallet_root}/fixture_wallet/sentinel"
      ;;
    direct-destination-symlink)
      printf 'outside\n' > "${outside_root}/sentinel"
      ln -s ../outside "${wallet_root}/fixture_wallet"
      ;;
    direct-lock-contention)
      mkdir -m 0700 -- \
        "${wallet_root}/.fixture_wallet.cntools-wallet-import-hardware.lock"
      ;;
    direct-missing-hwcli)
      direct_path="${BASE_PATH}"
      ccli_value="${FAKE_BIN}/cardano-cli"
      ;;
    direct-version-fail) hw_mode=version-fail ;;
    direct-version-malformed) hw_mode=version-malformed; expected_status=70 ;;
    direct-old-version) hw_mode=old-version ;;
    direct-release-malformed)
      printf 'not-json\n' > "${node_home}/files/cnode-release.json"
      expected_status=70
      ;;
    direct-release-unsafe)
      chmod 0666 "${node_home}/files/cnode-release.json"
      expected_status=70
      ;;
    direct-device-fail) hw_mode=device-fail ;;
    direct-device-malformed) hw_mode=device-malformed; expected_status=70 ;;
    direct-export-fail) hw_mode=export-fail ;;
    direct-malformed-json) hw_mode=malformed-json; expected_status=70 ;;
    direct-pair-mismatch) hw_mode=pair-mismatch; expected_status=70 ;;
    direct-wrong-path) hw_mode=wrong-path; expected_status=70 ;;
    direct-wrong-type) hw_mode=wrong-type; expected_status=70 ;;
    direct-hardlink) hw_mode=hardlink; expected_status=70 ;;
    direct-symlink-output) hw_mode=symlink-output; expected_status=70 ;;
    direct-special-output) hw_mode=special-output; expected_status=70 ;;
    direct-extra-output) hw_mode=extra-output; expected_status=70 ;;
    direct-derive-fail) cli_mode=fail-base ;;
    direct-malformed-address) cli_mode=malformed-base; expected_status=70 ;;
    direct-wrong-network) cli_mode=wrong-network-base; expected_status=70 ;;
    direct-late-tamper) cli_mode=late-tamper; expected_status=70 ;;
    direct-publish-collision) cli_mode=collision; expected_status=70 ;;
    direct-stage-swap) cli_mode=stage-swap; expected_status=70 ;;
    direct-lock-swap) cli_mode=lock-swap; expected_status=70 ;;
    direct-mv-error-after) mv_error_after=Y ;;
    direct-postcommit-lock-failure) fail_lock_release=Y ;;
    direct-signal-after-move) signal_after_move=Y ;;
    direct-signal-lock-acquire) signal_lock_acquire=Y; expected_status=70 ;;
    direct-unsafe-root) chmod 0777 "${wallet_root}"; expected_status=70 ;;
    direct-unsafe-filename) expected_status=70 ;;
    direct-ccli-shadow) expected_status=70 ;;
    direct-ccli-symlink)
      ln -s "${FAKE_BIN}/cardano-cli" "${runtime_root}/cardano-cli-link"
      ccli_value="${runtime_root}/cardano-cli-link"
      expected_status=70
      ;;
    direct-hwcli-shadow) expected_status=70 ;;
    direct-hwcli-symlink)
      case_bin="${runtime_root}/case-bin"
      mkdir -m 0700 -- "${case_bin}"
      ln -s "${FAKE_BIN}/cardano-hw-cli" "${case_bin}/cardano-hw-cli"
      direct_path="${case_bin}:${BASE_PATH}"
      ccli_value="${FAKE_BIN}/cardano-cli"
      expected_status=70
      ;;
    *) fail "unknown direct scenario: ${scenario}" ;;
  esac

  write_context "${private_root}/context.json" "${mode}" "${node_home}"
  context_hash="$(file_hash "${private_root}/context.json")"
  manifest_hash="$(file_hash "${node_home}/files/cnode-release.json")"
  tree_snapshot "${wallet_root}" "${before_tree}" ||
    fail "${scenario} pre-dispatch wallet snapshot failed"
  : > "${event_log}"
  : > "${command_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C TZ=UTC PATH="${direct_path}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_LOG="${command_log}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_WALLET_ROOT="${wallet_root}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_EXTERNAL="${outside_root}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_HW_MODE="${hw_mode}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_CLI_MODE="${cli_mode}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_SECRET="${FAILURE_DIAGNOSTIC}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_BASE="${BASE_ADDR}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_PAY="${PAY_ADDR}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REWARD="${REWARD_ADDR}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REAL_MKDIR="${DIRECT_REAL_MKDIR}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REAL_MV="${DIRECT_REAL_MV}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_REAL_RMDIR="${DIRECT_REAL_RMDIR}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_MV_ERROR_AFTER="${mv_error_after}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_FAIL_LOCK_RELEASE="${fail_lock_release}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_SIGNAL_AFTER_MOVE="${signal_after_move}"
    export CNTOOLS_WALLET_IMPORT_HARDWARE_DIRECT_SIGNAL_LOCK_ACQUIRE="${signal_lock_acquire}"
    HOME="${node_home}"
    NODE_HOME="${node_home}"
    WALLET_FOLDER="${wallet_root}"
    CNTOOLS_MODE="${mode}"
    NETWORK_IDENTIFIER='--testnet-magic 42'
    CCLI="${ccli_value}"
    WALLET_DERIVATION_PATH_FILENAME=derivation.path
    WALLET_HW_PAY_SK_FILENAME=payment.hwsfile
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_HW_STAKE_SK_FILENAME=stake.hwsfile
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_GOV_HW_DREP_SK_FILENAME=drep.hwsfile
    WALLET_GOV_DREP_VK_FILENAME=drep.vkey
    WALLET_GOV_HW_CC_COLD_SK_FILENAME=cc-cold.hwsfile
    WALLET_GOV_CC_COLD_VK_FILENAME=cc-cold.vkey
    WALLET_GOV_HW_CC_HOT_SK_FILENAME=cc-hot.hwsfile
    WALLET_GOV_CC_HOT_VK_FILENAME=cc-hot.vkey
    WALLET_MULTISIG_PREFIX=ms_
    WALLET_BASE_ADDR_FILENAME=base.addr
    WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_STAKE_ADDR_FILENAME=stake.addr
    WALLET_PAY_CRED_FILENAME=payment.cred
    WALLET_STAKE_CRED_FILENAME=stake.cred
    [[ "${scenario}" != direct-unsafe-filename ]] ||
      WALLET_HW_PAY_SK_FILENAME='../escaped.hwsfile'
    FG_RED="" FG_GREEN="" FG_YELLOW="" FG_LGRAY="" NC=""
    DIRECT_PROMPT_COUNT=0
    DIRECT_WAIT_COUNT=0
    DIRECT_EVENT_LOG="${event_log}"

    clear() { printf 'clear\n' >> "${DIRECT_EVENT_LOG}"; }
    println() {
      local level="${1:-}"
      shift || true
      case "${level}" in
        ACTION) printf 'action:%s\n' "$*" >> "${DIRECT_EVENT_LOG}" ;;
        DEBUG|LOG) ;;
        OFF|INFO|ERROR) printf '%b\n' "$@" ;;
        *) printf '%b\n' "${level}" "$@" ;;
      esac
    }
    waitToProceed() {
      DIRECT_WAIT_COUNT=$((DIRECT_WAIT_COUNT + 1))
      printf 'wait:%s\n' "${DIRECT_WAIT_COUNT}" >> "${DIRECT_EVENT_LOG}"
      [[ "${scenario}" != direct-wait-false ]]
    }
    getAnswerAnyCust() {
      local output_variable="${1:-}"
      DIRECT_PROMPT_COUNT=$((DIRECT_PROMPT_COUNT + 1))
      printf 'prompt:%s\n' "${DIRECT_PROMPT_COUNT}" >> "${DIRECT_EVENT_LOG}"
      case "${DIRECT_PROMPT_COUNT}" in
        1)
          [[ "${cancel_name}" != Y ]] || return 1
          printf -v "${output_variable}" '%s' "${direct_name}"
          ;;
        2) printf -v "${output_variable}" '%s' "${direct_account}" ;;
        3) printf -v "${output_variable}" '%s' "${direct_key}" ;;
        *) return 70 ;;
      esac
    }
    select_opt() {
      printf 'governance:%s\n' "${governance}" >> "${DIRECT_EVENT_LOG}"
      [[ "${governance}" == N ]]
    }
    printWalletInfo() {
      printf 'Hardware wallet fixture summary\n'
      printf 'display\n' >> "${DIRECT_EVENT_LOG}"
    }
    if [[ "${scenario}" == direct-ccli-shadow ]]; then
      function cardano-cli { printf 'shadow-ccli\n' >> "${DIRECT_EVENT_LOG}"; }
    fi
    if [[ "${scenario}" == direct-hwcli-shadow ]]; then
      function cardano-hw-cli { printf 'shadow-hwcli\n' >> "${DIRECT_EVENT_LOG}"; }
    fi
    direct_status=0
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${private_root}/context.json" "${private_root}/result.json" ||
      direct_status=$?
    printf '%s\n' "${direct_status}" > "${capture_root}/status"
    printf '%s\n' "${DIRECT_WAIT_COUNT}" > "${capture_root}/wait-count"
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    direct_status=0
  else
    direct_status=$?
  fi
  [[ "${direct_status}" == 0 ]] || fail "${scenario} harness returned ${direct_status}"
  direct_status="$(< "${capture_root}/status")"
  [[ "${direct_status}" == "${expected_status}" ]] ||
    fail "${scenario} returned ${direct_status}, expected ${expected_status}"

  write_direct_expected_stdout "${scenario}" "${expected_stdout}"
  assert_files_equal "${stdout_file}" "${expected_stdout}" "${scenario} stdout"
  if [[ "${scenario}" == direct-postcommit-lock-failure ||
        "${scenario}" == direct-signal-after-move ]]; then
    [[ "$(< "${stderr_file}")" == \
       'WARNING: the hardware wallet was imported, but administrative cleanup needs attention.' ]] ||
      fail "${scenario} postcommit warning changed"
  elif direct_scenario_is_invariant "${scenario}"; then
    [[ "$(< "${stderr_file}")" == \
       'CNTools hardware wallet import action failed validation.' ]] ||
      fail "${scenario} validation stderr changed"
  else
    [[ ! -s "${stderr_file}" ]] || fail "${scenario} emitted stderr"
  fi
  ! grep -Fq "${FAILURE_DIAGNOSTIC}" "${stdout_file}" "${stderr_file}" ||
    fail "${scenario} reflected a hardware/tool secret"
  ! grep -q $'\033' "${stdout_file}" "${stderr_file}" ||
    fail "${scenario} reflected terminal control bytes"
  [[ ! -e "${private_root}/result.json" &&
     -z "$(find "${private_root}" -mindepth 1 ! -name context.json -print -quit)" ]] ||
    fail "${scenario} left a result or private temporary artifact"
  [[ "$(file_hash "${private_root}/context.json")" == "${context_hash}" &&
     "$(file_hash "${node_home}/files/cnode-release.json")" == "${manifest_hash}" ]] ||
    fail "${scenario} mutated authenticated input or release metadata"

  tree_snapshot "${wallet_root}" "${after_tree}" ||
    fail "${scenario} post-dispatch wallet snapshot failed"
  case "${scenario}" in
    direct-success-local|direct-success-light|direct-success-offline|\
      direct-success-no-governance|direct-wait-false|direct-mv-error-after)
      [[ -d "${wallet_root}/fixture_wallet" &&
         "$(file_mode "${wallet_root}/fixture_wallet")" == 700 ]] ||
        fail "${scenario} did not publish an owner-private wallet"
      wallet_count="$(find "${wallet_root}/fixture_wallet" -type f -print | wc -l | tr -d '[:space:]')"
      [[ "${wallet_count}" == "${expected_count}" ]] ||
        fail "${scenario} published ${wallet_count} artifacts, expected ${expected_count}"
      while IFS= read -r filename; do
        [[ "$(file_mode "${filename}")" == 600 ]] ||
          fail "${scenario} published a non-0600 artifact: ${filename##*/}"
      done < <(find "${wallet_root}/fixture_wallet" -type f -print | LC_ALL=C sort)
      [[ "$(< "${wallet_root}/fixture_wallet/derivation.path")" == \
         '1852H/1815H/7H/x/11' ]] ||
        fail "${scenario} derivation-path metadata changed"
      [[ -z "$(find "${wallet_root}" -mindepth 1 -maxdepth 1 \
        -name '.*cntools-wallet-import-hardware*' -print -quit)" ]] ||
        fail "${scenario} left a lock or staging directory"
      ;;
    direct-postcommit-lock-failure)
      [[ -d "${wallet_root}/fixture_wallet" &&
         -d "${wallet_root}/.fixture_wallet.cntools-wallet-import-hardware.lock" ]] ||
        fail 'postcommit lock-release failure oracle changed'
      ;;
    direct-signal-after-move)
      [[ -d "${wallet_root}/fixture_wallet" &&
         -z "$(find "${wallet_root}" -mindepth 1 -maxdepth 1 \
           -name '.*cntools-wallet-import-hardware*' -print -quit)" ]] ||
        fail 'postcommit signal reconciliation changed'
      ;;
    direct-publish-collision)
      [[ "$(< "${wallet_root}/fixture_wallet/sentinel")" == collision ]] ||
        fail 'publish collision overwrote the competing wallet'
      [[ -z "$(find "${wallet_root}" -mindepth 1 -maxdepth 1 \
        -name '*.stage.*' -print -quit)" ]] ||
        fail 'publish collision left staging residue'
      ;;
    direct-extra-output)
      [[ ! -e "${wallet_root}/fixture_wallet" &&
         -f "$(find "${wallet_root}" -mindepth 2 -name unexpected.artifact -print -quit)" ]] ||
        fail 'unknown-output containment residue changed'
      ;;
    direct-hardlink)
      [[ -f "${outside_root}/hardware-hardlink" &&
         ! -e "${wallet_root}/fixture_wallet" ]] ||
        fail 'hard-linked hardware output containment changed'
      ;;
    direct-symlink-output)
      [[ -f "${outside_root}/outside-vkey" &&
         ! -e "${wallet_root}/fixture_wallet" ]] ||
        fail 'symlinked hardware output containment changed'
      ;;
    direct-stage-swap)
      [[ -L "$(find "${wallet_root}" -mindepth 1 -maxdepth 1 \
           -name '*.stage.*' -print -quit)" &&
         -d "${outside_root}/swapped-stage" &&
         ! -e "${wallet_root}/fixture_wallet" ]] ||
        fail 'stage replacement containment changed'
      ;;
    direct-lock-swap)
      [[ -d "${wallet_root}/.fixture_wallet.cntools-wallet-import-hardware.lock" &&
         ! -e "${wallet_root}/fixture_wallet" &&
         -z "$(find "${wallet_root}" -mindepth 1 -maxdepth 1 \
           -name '*.stage.*' -print -quit)" ]] ||
        fail 'lock replacement authority changed'
      ;;
    direct-duplicate|direct-destination-symlink|direct-lock-contention)
      assert_files_equal "${after_tree}" "${before_tree}" "${scenario} wallet tree"
      ;;
    *)
      assert_files_equal "${after_tree}" "${before_tree}" "${scenario} wallet tree"
      ;;
  esac

  case "${scenario}" in
    direct-success-local|direct-success-light|direct-success-offline|\
      direct-success-no-governance|direct-wait-false|direct-mv-error-after|\
      direct-postcommit-lock-failure)
      [[ "$(grep -c '^cardano-hw-cli' "${command_log}")" == 3 &&
         "$(grep -c '^cardano-cli' "${command_log}")" == 7 ]] ||
        fail "${scenario} command count changed"
      grep -Fq -- $'--verification-key-file\t<stage>/cc-hot.vkey' \
        "${command_log}" || {
          [[ "${scenario}" == direct-success-no-governance ]] ||
            fail "${scenario} committee-hot verification destination regressed"
        }
      ! grep -Fq -- $'--verification-key-file\t<stage>/cc-hot.hwsfile' \
        "${command_log}" ||
        fail "${scenario} reused the signing destination for committee-hot verification"
      if [[ "${scenario}" == direct-success-no-governance ]]; then
        [[ "$(grep -o -- '--path' "${command_log}" | wc -l | tr -d '[:space:]')" == 4 ]] ||
          fail 'no-governance hardware path count changed'
        ! grep -Fq 'H/3/' "${command_log}" ||
          fail 'no-governance import requested a DRep derivation path'
      else
        [[ "$(grep -o -- '--path' "${command_log}" | wc -l | tr -d '[:space:]')" == 7 ]] ||
          fail "${scenario} governance hardware path count changed"
      fi
      [[ "$(grep -c '^wait:' "${event_log}" || true)" == 2 ]] ||
        fail "${scenario} wait ownership changed"
      ;;
    direct-cancel-name)
      [[ "$(grep -c '^wait:' "${event_log}" || true)" == 0 ]] ||
        fail 'name cancellation unexpectedly waited'
      ;;
  esac
  [[ ! -e "${capture_root}/shadow-ccli" &&
     ! -e "${capture_root}/shadow-hwcli" ]] ||
    fail "${scenario} executed a shadowed tool function"
}

write_direct_fake_commands
run_case cancel-name
run_direct_case direct-success-local LOCAL
run_direct_case direct-success-light LIGHT
run_direct_case direct-success-offline OFFLINE
run_direct_case direct-success-no-governance OFFLINE
run_direct_case direct-wait-false OFFLINE
run_direct_case direct-cancel-name OFFLINE
run_direct_case direct-invalid-name OFFLINE
run_direct_case direct-invalid-account OFFLINE
run_direct_case direct-invalid-key OFFLINE
run_direct_case direct-duplicate LOCAL
run_direct_case direct-destination-symlink OFFLINE
run_direct_case direct-lock-contention OFFLINE
run_direct_case direct-missing-hwcli OFFLINE
run_direct_case direct-version-fail OFFLINE
run_direct_case direct-version-malformed OFFLINE
run_direct_case direct-old-version OFFLINE
run_direct_case direct-release-malformed OFFLINE
run_direct_case direct-release-unsafe OFFLINE
run_direct_case direct-device-fail OFFLINE
run_direct_case direct-device-malformed OFFLINE
run_direct_case direct-export-fail LOCAL
run_direct_case direct-malformed-json LOCAL
run_direct_case direct-pair-mismatch LOCAL
run_direct_case direct-wrong-path LOCAL
run_direct_case direct-wrong-type LOCAL
run_direct_case direct-hardlink LOCAL
run_direct_case direct-symlink-output LOCAL
run_direct_case direct-special-output LOCAL
run_direct_case direct-extra-output LOCAL
run_direct_case direct-derive-fail LOCAL
run_direct_case direct-malformed-address LOCAL
run_direct_case direct-wrong-network LOCAL
run_direct_case direct-late-tamper LOCAL
run_direct_case direct-publish-collision LOCAL
run_direct_case direct-stage-swap LOCAL
run_direct_case direct-lock-swap LOCAL
run_direct_case direct-mv-error-after OFFLINE
run_direct_case direct-postcommit-lock-failure OFFLINE
run_direct_case direct-signal-after-move OFFLINE
run_direct_case direct-signal-lock-acquire OFFLINE
run_direct_case direct-unsafe-root OFFLINE
run_direct_case direct-unsafe-filename OFFLINE
run_direct_case direct-ccli-shadow OFFLINE
run_direct_case direct-ccli-symlink OFFLINE
run_direct_case direct-hwcli-shadow OFFLINE
run_direct_case direct-hwcli-symlink OFFLINE

hardware_arm="${TEST_ROOT}/wallet-import-hardware-arm"
awk '
  /^[[:space:]]+hardware\)/ { capture=1 }
  capture { print }
  capture && /esac # wallet >> import sub OPERATION/ { exit }
' "${CNTOOLS_SCRIPT}" > "${hardware_arm}"
[[ "$(grep -Fc 'cntools_compatibility_dispatch_action wallet.import.hardware' \
  "${hardware_arm}")" == 1 ]] || fail 'wallet.import.hardware generic call count changed'
grep -Fq '0|21) continue ;;' "${hardware_arm}" ||
  fail 'wallet.import.hardware continue mapping changed'
grep -Fq '20) break 2 ;;' "${hardware_arm}" ||
  fail 'wallet.import.hardware parent mapping changed'
grep -Fq '22) myExit 0 "CNTools closed!" ;;' "${hardware_arm}" ||
  fail 'wallet.import.hardware exit mapping changed'
grep -Fq '*) waitToProceed; continue ;;' "${hardware_arm}" ||
  fail 'wallet.import.hardware failure mapping changed'
if grep -Eq 'cardano-hw-cli address key-gen|HW_DERIVATION_CMD|cc_hot_sk_file|ms_drep_sk_file' \
    "${hardware_arm}"; then
  fail 'wallet.import.hardware inline implementation remains after binding'
fi

legacy_fingerprint_count=0
for legacy_scenario in \
  missing-cli version-failure cancel-name derivation-failure unlock-failure \
  command-failure no-governance success-local success-light success-offline \
  existing-empty malformed-json address-failure unsafe-filename symlink-wallet \
  wait-false-missing-cli command-failure-wait-false; do
  for legacy_artifact in stdout stderr events commands tree; do
    legacy_fingerprint="$(expected_digest \
      "${legacy_artifact}" "${legacy_scenario}")"
    [[ "${legacy_fingerprint}" =~ ^[0-9a-f]{64}$ ]] ||
      fail "invalid frozen legacy fingerprint: ${legacy_artifact}:${legacy_scenario}"
    legacy_fingerprint_count=$((legacy_fingerprint_count + 1))
  done
done
[[ "${legacy_fingerprint_count}" == 85 ]] ||
  fail 'frozen legacy fingerprint coverage changed'

direct_guard_status=0
direct_guard_stderr=""
if direct_guard_stderr="$("${BASH}" "${ACTION_SOURCE}" 2>&1)"; then
  fail 'dedicated hardware-wallet action executed directly'
else
  direct_guard_status=$?
fi
[[ "${direct_guard_status}" == 64 &&
   "${direct_guard_stderr}" == \
     'CNTools actions are launched by the dispatcher, not directly.' ]] ||
  fail 'dedicated hardware-wallet direct-execution guard changed'

printf 'CNTools wallet-import-hardware characterization/parity passed (17 frozen legacy records + 1 public + 46 direct cases)\n'
