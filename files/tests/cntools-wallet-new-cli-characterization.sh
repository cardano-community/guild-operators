#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet-new-cli characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/new/cli/action.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/new/cli"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f"
COMMON_DIALOG_SOURCE="${LEGACY_ROOT}/010-common-dialog.sh"
GOVERNANCE_QUERY_SOURCE="${LEGACY_ROOT}/030-governance-query.sh"
WALLET_QUERY_SOURCE="${LEGACY_ROOT}/040-address-wallet-query.sh"
WALLET_CREATE_SOURCE="${LEGACY_ROOT}/050-wallet-create-registration.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-new-cli.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
BASE_ADDR='addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
PAY_ADDR='addr_test1pppppppppppppppppppppppppppppppppppppppp'
REWARD_ADDR='stake_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'

cleanup_test() {
  if [[ "${CNTOOLS_WALLET_NEW_CLI_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools wallet-new-cli test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools wallet-new-cli characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk cmp find grep head jq readlink sed sort stat wc; do
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

write_fake_commands() {
  local command_name="" real_mkdir="" real_mv="" real_rmdir=""

  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'printf '\''cardano-cli'\'' >> "${CNTOOLS_WALLET_NEW_CLI_LOG:?}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  if [[ "${normalized}" == "${CNTOOLS_WALLET_NEW_CLI_WALLET_ROOT}/."*.cntools-wallet-new-cli.stage.*/* ]]; then' \
    '    normalized="<stage>/${normalized##*/}"' \
    '  elif [[ "${normalized}" == "${CNTOOLS_WALLET_NEW_CLI_WALLET_ROOT}/"* ]]; then' \
    '    normalized="<wallet>/${normalized#"${CNTOOLS_WALLET_NEW_CLI_WALLET_ROOT}/"}"' \
    '  fi' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${CNTOOLS_WALLET_NEW_CLI_LOG:?}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_NEW_CLI_LOG:?}"' \
    'case "$*" in' \
    '  "address key-gen "*) step=1; vk_flag=--verification-key-file; sk_flag=--signing-key-file ;;' \
    '  "latest stake-address key-gen "*) step=2; vk_flag=--verification-key-file; sk_flag=--signing-key-file ;;' \
    '  "latest governance drep key-gen "*)' \
    '    if [[ "$*" == *"/multisig-drep.vkey"* ]]; then step=8; else step=3; fi' \
    '    vk_flag=--verification-key-file; sk_flag=--signing-key-file' \
    '    ;;' \
    '  "latest governance committee key-gen-cold "*) step=4; vk_flag=--cold-verification-key-file; sk_flag=--cold-signing-key-file ;;' \
    '  "latest governance committee key-gen-hot "*) step=5; vk_flag=--verification-key-file; sk_flag=--signing-key-file ;;' \
    '  "address build "*) derive=payment; [[ "$*" == *" --stake-verification-key-file "* ]] && derive=base ;;' \
    '  "latest stake-address build "*) derive=reward ;;' \
    '  "address key-hash "*|"latest stake-address key-hash "*) derive=credential ;;' \
    '  *) printf '\''unexpected cardano-cli vector: %s\n'\'' "$*" >&2; exit 96 ;;' \
    'esac' \
    'if [[ -n "${derive:-}" ]]; then' \
    '  previous=""; out_file=""' \
    '  for argument in "$@"; do [[ "${previous}" == --out-file ]] && out_file="${argument}"; previous="${argument}"; done' \
    '  [[ -n "${out_file}" ]] || exit 96' \
    '  if [[ "${CNTOOLS_WALLET_NEW_CLI_FAIL_DERIVE:-}" == "${derive}" ]]; then printf '\''unsafe-derive-error\\033[31m\n'\'' >&2; exit 43; fi' \
    '  if [[ "${CNTOOLS_WALLET_NEW_CLI_MALFORMED_DERIVE:-}" == "${derive}" ]]; then printf '\''unsafe\\033[31m\n'\'' > "${out_file}"' \
    '  else' \
    '    case "${derive}" in' \
    '      base)' \
    '        if [[ "${CNTOOLS_WALLET_NEW_CLI_WRONG_NETWORK:-}" == base ]]; then printf '\''addr1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq\n'\'' > "${out_file}"' \
    '        else printf '\''%s\n'\'' "${CNTOOLS_WALLET_NEW_CLI_BASE:?}" > "${out_file}"; fi' \
    '        ;;' \
    '      payment) printf '\''%s\n'\'' "${CNTOOLS_WALLET_NEW_CLI_PAY:?}" > "${out_file}" ;;' \
    '      reward)' \
    '        if [[ "${CNTOOLS_WALLET_NEW_CLI_WRONG_NETWORK:-}" == reward ]]; then printf '\''stake1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq\n'\'' > "${out_file}"' \
    '        else printf '\''%s\n'\'' "${CNTOOLS_WALLET_NEW_CLI_REWARD:?}" > "${out_file}"; fi' \
    '        ;;' \
    '      credential) printf '\''%056d\n'\'' 1 > "${out_file}" ;;' \
    '    esac' \
    '  fi' \
    '  if [[ "${CNTOOLS_WALLET_NEW_CLI_COLLIDE:-N}" == Y && "${out_file##*/}" == multisig-stake.cred ]]; then' \
    '    mkdir -m 0700 -- "${CNTOOLS_WALLET_NEW_CLI_WALLET_ROOT}/${CNTOOLS_WALLET_NEW_CLI_NAME:?}" || exit 96' \
    '    printf '\''collision\n'\'' > "${CNTOOLS_WALLET_NEW_CLI_WALLET_ROOT}/${CNTOOLS_WALLET_NEW_CLI_NAME}/sentinel"' \
    '  fi' \
    '  if [[ "${out_file##*/}" == multisig-stake.cred ]]; then' \
    '    case "${CNTOOLS_WALLET_NEW_CLI_LATE_TAMPER:-}" in' \
    '      signing) printf '\''{"unsafe":"late"}\n'\'' > "${out_file%/*}/payment.skey" ;;' \
    '      base) printf '\''unsafe\\033[31m\n'\'' > "${out_file%/*}/base.addr" ;;' \
    '    esac' \
    '    if [[ "${CNTOOLS_WALLET_NEW_CLI_SWAP_LOCK:-N}" == Y ]]; then' \
    '      lock="${CNTOOLS_WALLET_NEW_CLI_WALLET_ROOT}/.${CNTOOLS_WALLET_NEW_CLI_NAME:?}.cntools-wallet-new-cli.lock"' \
    '      "${CNTOOLS_WALLET_NEW_CLI_REAL_RMDIR:?}" -- "${lock}" || exit 96' \
    '      "${CNTOOLS_WALLET_NEW_CLI_REAL_MKDIR:?}" -m 0700 -- "${lock}" || exit 96' \
    '    fi' \
    '  fi' \
    '  exit 0' \
    'fi' \
    '[[ "${step}" != 1 || "$*" != *"/multisig-payment.vkey"* ]] || step=6' \
    '[[ "${step}" != 2 || "$*" != *"/multisig-stake.vkey"* ]] || step=7' \
    'previous=""; vk_file=""; sk_file=""' \
    'for argument in "$@"; do' \
    '  [[ "${previous}" == "${vk_flag}" ]] && vk_file="${argument}"' \
    '  [[ "${previous}" == "${sk_flag}" ]] && sk_file="${argument}"' \
    '  previous="${argument}"' \
    'done' \
    '[[ -n "${vk_file}" && -n "${sk_file}" ]] || exit 96' \
    'if [[ "${CNTOOLS_WALLET_NEW_CLI_FAIL_STEP:-0}" == "${step}" ]]; then' \
    '  if [[ "${CNTOOLS_WALLET_NEW_CLI_SWAP_STAGE:-N}" == Y ]]; then' \
    '    stage="${vk_file%/*}"; escaped="${CNTOOLS_WALLET_NEW_CLI_EXTERNAL:?}/escaped-stage"' \
    '    "${CNTOOLS_WALLET_NEW_CLI_REAL_MV:?}" -- "${stage}" "${escaped}" || exit 96' \
    '    ln -s "${escaped}" "${stage}" || exit 96' \
    '  fi' \
    '  printf '\''unsafe-cli-error-step-%s\\033[31m\n'\'' "${step}" >&2' \
    '  exit 42' \
    'fi' \
    'case "${step}" in' \
    '  1|6) vk_type=PaymentVerificationKeyShelley_ed25519; sk_type=PaymentSigningKeyShelley_ed25519 ;;' \
    '  2|7) vk_type=StakeVerificationKeyShelley_ed25519; sk_type=StakeSigningKeyShelley_ed25519 ;;' \
    '  3|8) vk_type=DRepVerificationKey_ed25519; sk_type=DRepSigningKey_ed25519 ;;' \
    '  4) vk_type=ConstitutionalCommitteeColdVerificationKey_ed25519; sk_type=ConstitutionalCommitteeColdSigningKey_ed25519 ;;' \
    '  5) vk_type=ConstitutionalCommitteeHotVerificationKey_ed25519; sk_type=ConstitutionalCommitteeHotSigningKey_ed25519 ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    'printf '\''{"type":"%s","description":"fixture-vk-%s","cborHex":"5820aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n'\'' "${vk_type}" "${step}" > "${vk_file}"' \
    'printf '\''{"type":"%s","description":"fixture-sk-%s","cborHex":"5820bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}\n'\'' "${sk_type}" "${step}" > "${sk_file}"' \
    'if [[ "${CNTOOLS_WALLET_NEW_CLI_MALFORMED_STEP:-0}" == "${step}" ]]; then printf '\''{"unsafe":"schema"}\n'\'' > "${vk_file}"; fi' \
    'if [[ "${CNTOOLS_WALLET_NEW_CLI_HARDLINK_STEP:-0}" == "${step}" ]]; then ln "${sk_file}" "${CNTOOLS_WALLET_NEW_CLI_EXTERNAL:?}/hardlink-${step}" || exit 96; fi' \
    > "${FAKE_BIN}/cardano-cli"
  chmod 0755 "${FAKE_BIN}/cardano-cli"

  real_mkdir="$(builtin type -P mkdir)" || fail 'could not resolve real mkdir'
  real_mv="$(builtin type -P mv)" || fail 'could not resolve real mv'
  real_rmdir="$(builtin type -P rmdir)" || fail 'could not resolve real rmdir'
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target="${*: -1}"' \
    '"${CNTOOLS_WALLET_NEW_CLI_REAL_MKDIR:?}" "$@" || exit $?' \
    'if [[ "${CNTOOLS_WALLET_NEW_CLI_SIGNAL_LOCK_ACQUIRE:-N}" == Y && "${target}" == *.cntools-wallet-new-cli.lock ]]; then kill -TERM "${PPID}"; fi' \
    'exit 0' \
    > "${FAKE_BIN}/mkdir"
  chmod 0755 "${FAKE_BIN}/mkdir"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target="${*: -1}"' \
    '"${CNTOOLS_WALLET_NEW_CLI_REAL_MV:?}" "$@" || exit $?' \
    'if [[ "${target}" == "${CNTOOLS_WALLET_NEW_CLI_WALLET_ROOT}/${CNTOOLS_WALLET_NEW_CLI_NAME:-fixture_wallet}" ]]; then' \
    '  [[ "${CNTOOLS_WALLET_NEW_CLI_MV_ERROR_AFTER:-N}" != Y ]] || exit 44' \
    '  [[ "${CNTOOLS_WALLET_NEW_CLI_SIGNAL_AFTER_MOVE:-N}" != Y ]] || kill -TERM "${PPID}"' \
    'fi' \
    'exit 0' \
    > "${FAKE_BIN}/mv"
  chmod 0755 "${FAKE_BIN}/mv"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target="${*: -1}"' \
    'if [[ "${CNTOOLS_WALLET_NEW_CLI_FAIL_STAGE_RELEASE:-N}" == Y && "${target}" == *.cntools-wallet-new-cli.stage.* ]]; then exit 44; fi' \
    'if [[ "${CNTOOLS_WALLET_NEW_CLI_FAIL_LOCK_RELEASE:-N}" == Y && "${target}" == *.cntools-wallet-new-cli.lock ]]; then exit 44; fi' \
    'if [[ "${CNTOOLS_WALLET_NEW_CLI_SIGNAL_LOCK_RELEASE:-N}" == Y && "${target}" == *.cntools-wallet-new-cli.lock && ! -e "${CNTOOLS_WALLET_NEW_CLI_SIGNAL_MARKER:?}" ]]; then' \
    '  : > "${CNTOOLS_WALLET_NEW_CLI_SIGNAL_MARKER}"; kill -TERM "${PPID}"; exit 44' \
    'fi' \
    'if [[ "${CNTOOLS_WALLET_NEW_CLI_MUTATE_DEST:-N}" == Y && "${target}" == *.cntools-wallet-new-cli.lock ]]; then' \
    '  "${CNTOOLS_WALLET_NEW_CLI_REAL_RM:?}" -f -- "${CNTOOLS_WALLET_NEW_CLI_WALLET_ROOT}/${CNTOOLS_WALLET_NEW_CLI_NAME:?}/base.addr"' \
    'fi' \
    'exec "${CNTOOLS_WALLET_NEW_CLI_REAL_RMDIR:?}" "$@"' \
    > "${FAKE_BIN}/rmdir"
  chmod 0755 "${FAKE_BIN}/rmdir"
  CNTOOLS_WALLET_NEW_CLI_REAL_MKDIR="${real_mkdir}"
  CNTOOLS_WALLET_NEW_CLI_REAL_MV="${real_mv}"
  CNTOOLS_WALLET_NEW_CLI_REAL_RMDIR="${real_rmdir}"
  CNTOOLS_WALLET_NEW_CLI_REAL_RM="$(builtin type -P rm)"
  export CNTOOLS_WALLET_NEW_CLI_REAL_MKDIR CNTOOLS_WALLET_NEW_CLI_REAL_MV
  export CNTOOLS_WALLET_NEW_CLI_REAL_RMDIR CNTOOLS_WALLET_NEW_CLI_REAL_RM

  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${FAKE_BIN}/clear"
  chmod 0755 "${FAKE_BIN}/clear"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_WALLET_NEW_CLI_BLOCKED_LOG:?}"' \
      'printf '\''\t%s'\'' "$@" >> "${CNTOOLS_WALLET_NEW_CLI_BLOCKED_LOG:?}"' \
      'printf '\''\n'\'' >> "${CNTOOLS_WALLET_NEW_CLI_BLOCKED_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

write_expected_vectors() {
  local scenario="$1"
  local output_file="$2"

  case "${scenario}" in
    cancel|empty|sanitized|duplicate|hardlink-residue|symlink-destination)
      : > "${output_file}"
      ;;
    fail-[1-8])
      write_direct_vectors "direct-${scenario}" "${output_file}"
      ;;
    success-local|success-light|success-offline)
      write_direct_vectors "direct-${scenario}" "${output_file}"
      ;;
    *) fail "unknown vector scenario: ${scenario}" ;;
  esac
}

write_expected_stdout() {
  local scenario="$1"
  local output_file="$2"
  local wallet_name=fixture_wallet

  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> WALLET >> NEW >> CLI' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    '' > "${output_file}"
  case "${scenario}" in
    cancel|empty|sanitized|fail-[1-8]) return 0 ;;
    duplicate|hardlink-residue|symlink-destination)
      printf '%s\n%s\n' \
        'WARN: A wallet fixture_wallet already exists' \
        '      Choose another name or delete the existing one' >> "${output_file}"
      ;;
    success-local|success-light|success-offline)
      printf '%s\n' \
        "New Wallet      : ${wallet_name}" \
        "Address         : ${BASE_ADDR}" \
        "Payment Address : ${PAY_ADDR}" \
        '' \
        'You can now send and receive ADA using the above addresses.' \
        'Note that Payment Address will not take part in staking.' \
        'Wallet will be automatically registered on chain if you' \
        'choose to delegate or pledge wallet when registering a stake pool.' \
        >> "${output_file}"
      ;;
    *) fail "unknown stdout scenario: ${scenario}" ;;
  esac
}

write_expected_stderr() {
  local scenario="$1"
  local output_file="$2"

  : > "${output_file}"
  case "${scenario}" in
    empty|sanitized)
      printf '%s\n' 'ERROR: Invalid wallet name, please retry!' > "${output_file}"
      ;;
    fail-[1-8])
      printf '%s\n' 'ERROR: failure during CLI wallet key creation!' > "${output_file}"
      ;;
  esac
}

write_expected_events() {
  local scenario="$1"
  local output_file="$2"

  printf '%s\n' \
    'menu:main:w' \
    'menu:wallet:n' \
    'menu:new:c' \
    'action:compatibility-dispatch' \
    'action:begin' > "${output_file}"
  if [[ "${scenario}" == cancel ]]; then
    printf '%s\n' 'prompt:name:cancel' >> "${output_file}"
  else
    printf '%s\n' 'prompt:name:return' >> "${output_file}"
  fi
  case "${scenario}" in
    cancel) ;;
    *) printf '%s\n' 'action:waitToProceed' >> "${output_file}" ;;
  esac
  printf '%s\n' \
    'action:end' \
    'menu:new:h' \
    'menu:main:q' \
    'exit:0:CNTools closed!' >> "${output_file}"
}

extract_action_output() {
  local full_output="$1"
  local action_output="$2"
  [[ "$(grep -c '^__CNTOOLS_WALLET_NEW_CLI_BEGIN__$' "${full_output}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_WALLET_NEW_CLI_END__$' "${full_output}" || true)" == 1 ]] ||
    fail 'wallet-new-cli output markers were missing or duplicated'
  awk '
    $0 == "__CNTOOLS_WALLET_NEW_CLI_BEGIN__" { capture = 1; next }
    $0 == "__CNTOOLS_WALLET_NEW_CLI_END__" { capture = 0; exit }
    capture { print }
  ' "${full_output}" > "${action_output}"
}

# Source the public controller and exact immutable legacy helpers used by this
# inline action. Test seams replace prompts, terminal navigation and derivation
# only; the eight key-generation branches and filesystem behavior stay real.
# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=/dev/null
. "${COMMON_DIALOG_SOURCE}"
# shellcheck source=/dev/null
. "${GOVERNANCE_QUERY_SOURCE}"
# shellcheck source=/dev/null
. "${WALLET_QUERY_SOURCE}"
# shellcheck source=/dev/null
. "${WALLET_CREATE_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"

cntools_compatibility_dispatch_action() {
  local private_root="" context_file="" result_file="" action_status=0
  local tmp_mode=""

  [[ "${1:-}" == wallet.new.cli && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  tmp_mode="$(file_mode "${TMP_DIR}")" || return 70
  chmod 0700 "${TMP_DIR}" || return 70
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/wallet-new-cli-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  write_context "${context_file}" "${CNTOOLS_MODE}" "${NODE_HOME}" || return 70
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    action_status=0
  else
    action_status=$?
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || action_status=70
  rm -f -- "${result_file}" "${context_file}" >/dev/null 2>&1 ||
    action_status=70
  rmdir -- "${private_root}" >/dev/null 2>&1 || action_status=70
  chmod "${tmp_mode}" "${TMP_DIR}" || action_status=70
  CAPTURE_PENDING=N
  CAPTURE_ACTIVE=Y
  return "${action_status}"
}

println() {
  local level="${1:-}"
  shift || true
  case "${level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO) printf '%b\n' "$@" ;;
    ERROR) printf '%b\n' "$@" >&2 ;;
    *) printf '%b\n' "${level}" "$@" ;;
  esac
}

clear() {
  if [[ "${CAPTURE_PENDING:-N}" == Y ]]; then
    CAPTURE_PENDING=N
    CAPTURE_ACTIVE=Y
    printf 'action:begin\n' >> "${EVENT_LOG:?}"
    printf '__CNTOOLS_WALLET_NEW_CLI_BEGIN__\n'
  elif [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    CAPTURE_ACTIVE=N
    printf 'action:end\n' >> "${EVENT_LOG:?}"
    printf '__CNTOOLS_WALLET_NEW_CLI_END__\n'
  fi
}
tput() { :; }
getEpoch() { printf '0\n'; }
timeUntilNextEpoch() { printf '0\n'; }
timeLeft() { printf '00:00:00'; }
getSlotTipRef() { printf '0\n'; }
slotInterval() { printf '20\n'; }
getNodeMetrics() { :; }
updateProtocolParams() { :; }
getPriceInfo() { price_now=""; }

getAnswerAnyCust() {
  local variable_name="${1:-}"
  local answer="${CNTOOLS_WALLET_NEW_CLI_NAME-}"

  if [[ "${CNTOOLS_WALLET_NEW_CLI_CANCEL:-N}" == Y ]]; then
    printf 'prompt:name:cancel\n' >> "${EVENT_LOG:?}"
    return 1
  fi
  printf 'prompt:name:return\n' >> "${EVENT_LOG:?}"
  printf -v "${variable_name}" '%s' "${answer}"
}

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}"
  local menu="" option="" index=0

  case "${1:-}" in
    '[w] Wallet') menu=main ;;
    '[n] New') menu=wallet ;;
    '[m] Mnemonic') menu=new ;;
    *) fail "unexpected wallet-new-cli menu: ${1:-<empty>}" ;;
  esac
  [[ -n "${choice}" ]] || fail "menu ${menu} exhausted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == new:c ]]; then
        CAPTURE_PENDING=Y
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was absent from ${menu} menu"
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  return 0
}

getBaseAddress() {
  local name="${1:-}"
  printf 'derive:base\n' >> "${EVENT_LOG:?}"
  base_addr="${BASE_ADDR}"
  printf '%s\n' "${base_addr}" > "${WALLET_FOLDER}/${name}/${WALLET_BASE_ADDR_FILENAME}"
}

getPayAddress() {
  local name="${1:-}"
  printf 'derive:payment\n' >> "${EVENT_LOG:?}"
  pay_addr="${PAY_ADDR}"
  printf '%s\n' "${pay_addr}" > "${WALLET_FOLDER}/${name}/${WALLET_PAY_ADDR_FILENAME}"
}

getRewardAddress() {
  local name="${1:-}"
  printf 'derive:reward\n' >> "${EVENT_LOG:?}"
  reward_addr="${REWARD_ADDR}"
  printf '%s\n' "${reward_addr}" > "${WALLET_FOLDER}/${name}/${WALLET_STAKE_ADDR_FILENAME}"
}

getCredentials() {
  local name="${1:-}"
  printf 'derive:credentials\n' >> "${EVENT_LOG:?}"
  printf '%s\n' pay-credential > "${WALLET_FOLDER}/${name}/${WALLET_PAY_CRED_FILENAME}"
  printf '%s\n' stake-credential > "${WALLET_FOLDER}/${name}/${WALLET_STAKE_CRED_FILENAME}"
  printf '%s\n' multisig-pay-credential > "${WALLET_FOLDER}/${name}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}"
  printf '%s\n' multisig-stake-credential > "${WALLET_FOLDER}/${name}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_CRED_FILENAME}"
}

safeDel() {
  local target="${1:-}"
  rm -rf -- "${target}"
  printf 'Deleted: %s\n' "${target}"
}

myExit() {
  local status="${1:-0}"
  local message="${2:-}"

  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'wallet-new-cli traversal did not consume all choices'
  exit "${status}"
}

run_case() {
  local scenario="$1"
  local mode="$2"
  local case_root="${TEST_ROOT}/cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local wallet_root="${runtime_root}/wallet"
  local capture_root="${case_root}/capture"
  local before_tree="${capture_root}/before.tree"
  local after_tree="${capture_root}/after.tree"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local cli_log="${capture_root}/cli"
  local expected_cli="${capture_root}/expected.cli"
  local blocked_log="${capture_root}/blocked"
  local expected_wallet_name=fixture_wallet name_input=fixture_wallet fail_step=0
  local status=0

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${wallet_root}" "${capture_root}"
  case "${scenario}" in
    cancel) name_input=ignored ;;
    empty) name_input='' ;;
    sanitized) name_input='Alpha/Beta'; expected_wallet_name=Alpha_Beta ;;
    duplicate)
      mkdir -p -- "${wallet_root}/${expected_wallet_name}"
      printf 'existing\n' > "${wallet_root}/${expected_wallet_name}/existing.skey"
      ;;
    symlink-destination)
      mkdir -p -- "${runtime_root}/outside"
      printf 'outside\n' > "${runtime_root}/outside/sentinel"
      ln -s ../outside "${wallet_root}/${expected_wallet_name}"
      ;;
    hardlink-residue)
      mkdir -p -- "${wallet_root}/${expected_wallet_name}"
      printf 'outside\n' > "${runtime_root}/outside.skey"
      ln "${runtime_root}/outside.skey" "${wallet_root}/${expected_wallet_name}/existing.skey"
      ;;
    fail-[1-8]) fail_step="${scenario#fail-}" ;;
    success-local|success-light|success-offline) ;;
    *) fail "unknown wallet-new-cli scenario: ${scenario}" ;;
  esac
  tree_snapshot "${runtime_root}" "${before_tree}" ||
    fail "could not snapshot ${scenario} before traversal"
  : > "${event_log}"
  : > "${cli_log}"
  : > "${blocked_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C TZ=UTC
    export PATH="${FAKE_BIN}:${BASE_PATH}"
    export CNTOOLS_WALLET_NEW_CLI_LOG="${cli_log}"
    export CNTOOLS_WALLET_NEW_CLI_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_WALLET_NEW_CLI_WALLET_ROOT="${wallet_root}"
    export CNTOOLS_WALLET_NEW_CLI_FAIL_STEP="${fail_step}"
    export CNTOOLS_WALLET_NEW_CLI_NAME="${name_input}"
    export CNTOOLS_WALLET_NEW_CLI_EXTERNAL="${runtime_root}"
    export CNTOOLS_WALLET_NEW_CLI_BASE="${BASE_ADDR}"
    export CNTOOLS_WALLET_NEW_CLI_PAY="${PAY_ADDR}"
    export CNTOOLS_WALLET_NEW_CLI_REWARD="${REWARD_ADDR}"
    if [[ "${scenario}" == cancel ]]; then
      CNTOOLS_WALLET_NEW_CLI_CANCEL=Y
    else
      CNTOOLS_WALLET_NEW_CLI_CANCEL=N
    fi
    export CNTOOLS_WALLET_NEW_CLI_CANCEL
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${wallet_root}"
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=characterized
    NETWORK_NAME=Preview
    NETWORK_IDENTIFIER='--testnet-magic 42'
    ADVANCED_MODE=false
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    CCLI=cardano-cli
    WALLET_PAY_SK_FILENAME=payment.skey
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_STAKE_SK_FILENAME=stake.skey
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_GOV_DREP_SK_FILENAME=drep.skey
    WALLET_GOV_DREP_VK_FILENAME=drep.vkey
    WALLET_GOV_CC_COLD_SK_FILENAME=cc-cold.skey
    WALLET_GOV_CC_COLD_VK_FILENAME=cc-cold.vkey
    WALLET_GOV_CC_HOT_SK_FILENAME=cc-hot.skey
    WALLET_GOV_CC_HOT_VK_FILENAME=cc-hot.vkey
    WALLET_MULTISIG_PREFIX=multisig-
    WALLET_PAY_SCRIPT_FILENAME=payment.script
    WALLET_STAKE_SCRIPT_FILENAME=stake.script
    WALLET_BASE_ADDR_FILENAME=base.addr
    WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_STAKE_ADDR_FILENAME=stake.addr
    WALLET_PAY_CRED_FILENAME=payment.cred
    WALLET_STAKE_CRED_FILENAME=stake.cred
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_PENDING=N
    CAPTURE_ACTIVE=N
    CHOICES=(w n c h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"
  extract_action_output "${full_stdout}" "${action_stdout}"

  write_expected_stdout "${scenario}" "${expected_stdout}"
  write_expected_stderr "${scenario}" "${expected_stderr}"
  write_expected_events "${scenario}" "${expected_events}"
  write_expected_vectors "${scenario}" "${expected_cli}"
  sed "s#${wallet_root}#<wallet>#g" "${action_stdout}" > "${capture_root}/normalized.stdout"
  sed "s#${wallet_root}#<wallet>#g" "${stderr_file}" > "${capture_root}/normalized.stderr"
  assert_files_equal "${capture_root}/normalized.stdout" "${expected_stdout}" \
    "${scenario} stdout"
  assert_files_equal "${capture_root}/normalized.stderr" "${expected_stderr}" \
    "${scenario} stderr"
  assert_files_equal "${event_log}" "${expected_events}" "${scenario} events"
  assert_files_equal "${cli_log}" "${expected_cli}" "${scenario} CLI vector"
  [[ ! -s "${blocked_log}" ]] || fail "${scenario} attempted network access"

  tree_snapshot "${runtime_root}" "${after_tree}" ||
    fail "could not snapshot ${scenario} after traversal"
  case "${scenario}" in
    empty|cancel|sanitized|duplicate|hardlink-residue|symlink-destination|fail-[1-8])
      assert_files_equal "${after_tree}" "${before_tree}" "${scenario} tree"
      ;;
    success-local|success-light|success-offline)
      [[ -f "${wallet_root}/${expected_wallet_name}/base.addr" &&
         -f "${wallet_root}/${expected_wallet_name}/payment.addr" &&
         -f "${wallet_root}/${expected_wallet_name}/stake.addr" ]] ||
        fail "${scenario} did not derive address files"
      [[ "$(file_mode "${wallet_root}/${expected_wallet_name}")" == 700 &&
         "$(find "${wallet_root}/${expected_wallet_name}" -type f -print | wc -l | tr -d '[:space:]')" == 23 ]] ||
        fail "${scenario} published wallet inventory changed"
      while IFS= read -r leaf; do
        [[ "$(file_mode "${leaf}")" == 600 ]] ||
          fail "${scenario} published a non-0600 leaf: ${leaf##*/}"
      done < <(find "${wallet_root}/${expected_wallet_name}" -type f -print | LC_ALL=C sort)
      ;;
  esac
}

write_direct_stdout() {
  local scenario="$1" output_file="$2" wallet_name=fixture_wallet

  : > "${output_file}"
  case "${scenario}" in
    direct-unsafe-root-mode|direct-unsafe-ccli-symlink|direct-ccli-shadow)
      return 0
      ;;
  esac
  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> WALLET >> NEW >> CLI' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    '' >> "${output_file}"
  case "${scenario}" in
    direct-duplicate|direct-destination-symlink)
      printf '%s\n' \
        'WARN: A wallet fixture_wallet already exists' \
        '      Choose another name or delete the existing one' >> "${output_file}"
      ;;
    direct-success-local|direct-success-light|direct-success-offline|\
      direct-postcommit-lock-failure|direct-mv-error-after|\
      direct-postcommit-display-capture|direct-root-0755-success|\
      direct-absolute-ccli|direct-production-clear)
      printf '%s\n' \
        "New Wallet      : ${wallet_name}" \
        "Address         : ${BASE_ADDR}" \
        "Payment Address : ${PAY_ADDR}" \
        '' \
        'You can now send and receive ADA using the above addresses.' \
        'Note that Payment Address will not take part in staking.' \
        'Wallet will be automatically registered on chain if you' \
        'choose to delegate or pledge wallet when registering a stake pool.' \
        >> "${output_file}"
      ;;
  esac
}

write_direct_stderr() {
  local scenario="$1" output_file="$2"

  : > "${output_file}"
  case "${scenario}" in
    direct-invalid-name)
      printf '%s\n' 'ERROR: Invalid wallet name, please retry!' > "${output_file}"
      ;;
    direct-lock-contention)
      printf '%s\n' 'ERROR: wallet creation is already in progress, please retry!' > "${output_file}"
      ;;
    direct-fail-[1-8])
      printf '%s\n' 'ERROR: failure during CLI wallet key creation!' > "${output_file}"
      ;;
    direct-malformed-key|direct-hardlink-key|direct-unsafe-root-mode|\
      direct-unsafe-ccli-symlink|direct-ccli-shadow|direct-derive-failure|\
      direct-malformed-address|direct-wrong-network-base|\
      direct-wrong-network-reward|direct-late-signing-tamper|\
      direct-late-base-tamper|direct-stage-swap|direct-cleanup-failure|\
      direct-lock-swap|direct-publish-collision)
      printf '%s\n' 'CNTools CLI wallet creation action failed validation.' > "${output_file}"
      ;;
    direct-postcommit-lock-failure|direct-signal-after-move|\
      direct-signal-lock-release)
      printf '%s\n' \
        'WARNING: the wallet was created, but administrative cleanup needs attention.' \
        > "${output_file}"
      ;;
  esac
}

write_direct_events() {
  local scenario="$1" output_file="$2"

  : > "${output_file}"
  if [[ "${scenario}" == direct-unsafe-root-mode ||
        "${scenario}" == direct-unsafe-ccli-symlink ||
        "${scenario}" == direct-ccli-shadow ]]; then
    return 0
  elif [[ "${scenario}" == direct-cancel ]]; then
    printf '%s\n' 'prompt:name:cancel' > "${output_file}"
    return 0
  fi
  printf '%s\n' 'prompt:name:return' > "${output_file}"
  case "${scenario}" in
    direct-malformed-key|direct-hardlink-key|direct-unsafe-root-mode|\
      direct-derive-failure|direct-malformed-address|\
      direct-wrong-network-base|direct-wrong-network-reward|\
      direct-late-signing-tamper|direct-late-base-tamper|\
      direct-stage-swap|direct-cleanup-failure|direct-lock-swap|\
      direct-publish-collision|direct-signal-after-move|\
      direct-signal-lock-release|direct-signal-lock-acquire) ;;
    *) printf '%s\n' 'action:waitToProceed' >> "${output_file}" ;;
  esac
}

write_direct_vectors() {
  local scenario="$1" output_file="$2" limit=0 line=""
  local -a vectors=()

  vectors=(
    'address key-gen --verification-key-file <stage>/payment.vkey --signing-key-file <stage>/payment.skey'
    'latest stake-address key-gen --verification-key-file <stage>/stake.vkey --signing-key-file <stage>/stake.skey'
    'latest governance drep key-gen --verification-key-file <stage>/drep.vkey --signing-key-file <stage>/drep.skey'
    'latest governance committee key-gen-cold --cold-verification-key-file <stage>/cc-cold.vkey --cold-signing-key-file <stage>/cc-cold.skey'
    'latest governance committee key-gen-hot --verification-key-file <stage>/cc-hot.vkey --signing-key-file <stage>/cc-hot.skey'
    'address key-gen --verification-key-file <stage>/multisig-payment.vkey --signing-key-file <stage>/multisig-payment.skey'
    'latest stake-address key-gen --verification-key-file <stage>/multisig-stake.vkey --signing-key-file <stage>/multisig-stake.skey'
    'latest governance drep key-gen --verification-key-file <stage>/multisig-drep.vkey --signing-key-file <stage>/multisig-drep.skey'
    'address build --payment-verification-key-file <stage>/payment.vkey --stake-verification-key-file <stage>/stake.vkey --testnet-magic 42 --out-file <stage>/base.addr'
    'address build --payment-verification-key-file <stage>/payment.vkey --testnet-magic 42 --out-file <stage>/payment.addr'
    'latest stake-address build --stake-verification-key-file <stage>/stake.vkey --testnet-magic 42 --out-file <stage>/stake.addr'
    'address key-hash --payment-verification-key-file <stage>/payment.vkey --out-file <stage>/payment.cred'
    'latest stake-address key-hash --stake-verification-key-file <stage>/stake.vkey --out-file <stage>/stake.cred'
    'address key-hash --payment-verification-key-file <stage>/multisig-payment.vkey --out-file <stage>/multisig-payment.cred'
    'latest stake-address key-hash --stake-verification-key-file <stage>/multisig-stake.vkey --out-file <stage>/multisig-stake.cred'
  )
  case "${scenario}" in
    direct-fail-[1-8]) limit="${scenario#direct-fail-}" ;;
    direct-malformed-key) limit=3 ;;
    direct-hardlink-key) limit=4 ;;
    direct-derive-failure|direct-malformed-address|direct-wrong-network-base)
      limit=9
      ;;
    direct-wrong-network-reward) limit=11 ;;
    direct-stage-swap|direct-cleanup-failure) limit=2 ;;
    direct-success-local|direct-success-light|direct-success-offline|\
      direct-publish-collision|direct-postcommit-lock-failure|\
      direct-late-signing-tamper|direct-late-base-tamper|\
      direct-lock-swap|direct-mv-error-after|direct-signal-after-move|\
      direct-signal-lock-release|direct-postcommit-display-capture|\
      direct-root-0755-success|direct-absolute-ccli|\
      direct-production-clear) limit=15 ;;
    *) limit=0 ;;
  esac
  : > "${output_file}"
  for ((line=0; line<limit; line++)); do
    printf 'cardano-cli\t%s\n' "${vectors[line]// /$'\t'}" >> "${output_file}"
  done
}

run_direct_case() {
  local scenario="$1" mode="$2"
  local case_root="${TEST_ROOT}/direct/${scenario}"
  local runtime_root="${case_root}/runtime"
  local wallet_root="${runtime_root}/wallet"
  local outside_root="${runtime_root}/outside"
  local private_root="${runtime_root}/private"
  local capture_root="${case_root}/capture"
  local stdout_file="${capture_root}/stdout" stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local cli_log="${capture_root}/cli" expected_cli="${capture_root}/expected.cli"
  local blocked_log="${capture_root}/blocked"
  local before_tree="${capture_root}/before.tree" after_tree="${capture_root}/after.tree"
  local name_input=fixture_wallet cancel=N fail_step=0 malformed_step=0
  local hardlink_step=0 fail_derive="" malformed_derive="" collide=N
  local fail_lock_release=N fail_stage_release=N late_tamper=""
  local wrong_network="" swap_lock=N swap_stage=N mv_error_after=N
  local signal_after_move=N signal_lock_release=N signal_lock_acquire=N
  local mutate_dest=N ccli_value=cardano-cli ccli_shadow=N unset_clear=N
  local expected_status=0 direct_status=0

  mkdir -p -- "${wallet_root}" "${outside_root}" "${private_root}" \
    "${runtime_root}/home" "${capture_root}"
  chmod 0700 "${wallet_root}" "${outside_root}" "${private_root}"
  case "${scenario}" in
    direct-cancel) cancel=Y ;;
    direct-invalid-name) name_input='bad/name' ;;
    direct-duplicate)
      mkdir -m 0700 -- "${wallet_root}/fixture_wallet"
      printf 'existing\n' > "${wallet_root}/fixture_wallet/sentinel"
      ;;
    direct-destination-symlink)
      printf 'outside\n' > "${outside_root}/sentinel"
      ln -s ../outside "${wallet_root}/fixture_wallet"
      ;;
    direct-lock-contention)
      mkdir -m 0700 -- "${wallet_root}/.fixture_wallet.cntools-wallet-new-cli.lock"
      ;;
    direct-fail-[1-8]) fail_step="${scenario#direct-fail-}" ;;
    direct-malformed-key) malformed_step=3; expected_status=70 ;;
    direct-hardlink-key) hardlink_step=4; expected_status=70 ;;
    direct-derive-failure) fail_derive=base; expected_status=70 ;;
    direct-malformed-address) malformed_derive=base; expected_status=70 ;;
    direct-wrong-network-base) wrong_network=base; expected_status=70 ;;
    direct-wrong-network-reward) wrong_network=reward; expected_status=70 ;;
    direct-late-signing-tamper) late_tamper=signing; expected_status=70 ;;
    direct-late-base-tamper) late_tamper=base; expected_status=70 ;;
    direct-stage-swap) fail_step=2; swap_stage=Y; expected_status=70 ;;
    direct-cleanup-failure) fail_step=2; fail_stage_release=Y; expected_status=70 ;;
    direct-lock-swap) swap_lock=Y; expected_status=70 ;;
    direct-publish-collision) collide=Y; expected_status=70 ;;
    direct-postcommit-lock-failure) fail_lock_release=Y ;;
    direct-mv-error-after) mv_error_after=Y ;;
    direct-signal-after-move) signal_after_move=Y ;;
    direct-signal-lock-release) signal_lock_release=Y ;;
    direct-signal-lock-acquire) signal_lock_acquire=Y; expected_status=70 ;;
    direct-postcommit-display-capture) mutate_dest=Y ;;
    direct-root-0755-success) chmod 0755 "${wallet_root}" ;;
    direct-unsafe-root-mode) chmod 0777 "${wallet_root}"; expected_status=70 ;;
    direct-absolute-ccli) ccli_value="${FAKE_BIN}/cardano-cli" ;;
    direct-unsafe-ccli-symlink)
      ln -s "${FAKE_BIN}/cardano-cli" "${runtime_root}/unsafe-ccli"
      ccli_value="${runtime_root}/unsafe-ccli"
      expected_status=70
      ;;
    direct-ccli-shadow) ccli_shadow=Y; expected_status=70 ;;
    direct-production-clear) unset_clear=Y ;;
    direct-success-local|direct-success-light|direct-success-offline) ;;
    *) fail "unknown direct wallet-new-cli scenario: ${scenario}" ;;
  esac
  write_context "${private_root}/context.json" "${mode}" "${runtime_root}/home"
  tree_snapshot "${wallet_root}" "${before_tree}" ||
    fail "could not snapshot ${scenario} before dispatch"
  : > "${event_log}"; : > "${cli_log}"; : > "${blocked_log}"
  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C TZ=UTC PATH="${FAKE_BIN}:${BASE_PATH}"
    export CNTOOLS_WALLET_NEW_CLI_ROUTE=direct
    export CNTOOLS_WALLET_NEW_CLI_LOG="${cli_log}"
    export CNTOOLS_WALLET_NEW_CLI_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_WALLET_NEW_CLI_WALLET_ROOT="${wallet_root}"
    export CNTOOLS_WALLET_NEW_CLI_EXTERNAL="${outside_root}"
    export CNTOOLS_WALLET_NEW_CLI_FAIL_STEP="${fail_step}"
    export CNTOOLS_WALLET_NEW_CLI_MALFORMED_STEP="${malformed_step}"
    export CNTOOLS_WALLET_NEW_CLI_HARDLINK_STEP="${hardlink_step}"
    export CNTOOLS_WALLET_NEW_CLI_FAIL_DERIVE="${fail_derive}"
    export CNTOOLS_WALLET_NEW_CLI_MALFORMED_DERIVE="${malformed_derive}"
    export CNTOOLS_WALLET_NEW_CLI_COLLIDE="${collide}"
    export CNTOOLS_WALLET_NEW_CLI_FAIL_LOCK_RELEASE="${fail_lock_release}"
    export CNTOOLS_WALLET_NEW_CLI_FAIL_STAGE_RELEASE="${fail_stage_release}"
    export CNTOOLS_WALLET_NEW_CLI_LATE_TAMPER="${late_tamper}"
    export CNTOOLS_WALLET_NEW_CLI_WRONG_NETWORK="${wrong_network}"
    export CNTOOLS_WALLET_NEW_CLI_SWAP_LOCK="${swap_lock}"
    export CNTOOLS_WALLET_NEW_CLI_SWAP_STAGE="${swap_stage}"
    export CNTOOLS_WALLET_NEW_CLI_MV_ERROR_AFTER="${mv_error_after}"
    export CNTOOLS_WALLET_NEW_CLI_SIGNAL_AFTER_MOVE="${signal_after_move}"
    export CNTOOLS_WALLET_NEW_CLI_SIGNAL_LOCK_RELEASE="${signal_lock_release}"
    export CNTOOLS_WALLET_NEW_CLI_SIGNAL_LOCK_ACQUIRE="${signal_lock_acquire}"
    export CNTOOLS_WALLET_NEW_CLI_MUTATE_DEST="${mutate_dest}"
    export CNTOOLS_WALLET_NEW_CLI_SIGNAL_MARKER="${capture_root}/signal.marker"
    export CNTOOLS_WALLET_NEW_CLI_NAME="${name_input}"
    export CNTOOLS_WALLET_NEW_CLI_CANCEL="${cancel}"
    export CNTOOLS_WALLET_NEW_CLI_BASE="${BASE_ADDR}"
    export CNTOOLS_WALLET_NEW_CLI_PAY="${PAY_ADDR}"
    export CNTOOLS_WALLET_NEW_CLI_REWARD="${REWARD_ADDR}"
    export CNTOOLS_WALLET_NEW_CLI_REAL_RMDIR
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    WALLET_FOLDER="${wallet_root}"
    CNTOOLS_MODE="${mode}"
    NETWORK_IDENTIFIER='--testnet-magic 42'
    CCLI="${ccli_value}"
    WALLET_PAY_SK_FILENAME=payment.skey
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_STAKE_SK_FILENAME=stake.skey
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_GOV_DREP_SK_FILENAME=drep.skey
    WALLET_GOV_DREP_VK_FILENAME=drep.vkey
    WALLET_GOV_CC_COLD_SK_FILENAME=cc-cold.skey
    WALLET_GOV_CC_COLD_VK_FILENAME=cc-cold.vkey
    WALLET_GOV_CC_HOT_SK_FILENAME=cc-hot.skey
    WALLET_GOV_CC_HOT_VK_FILENAME=cc-hot.vkey
    WALLET_MULTISIG_PREFIX=multisig-
    WALLET_BASE_ADDR_FILENAME=base.addr
    WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_STAKE_ADDR_FILENAME=stake.addr
    WALLET_PAY_CRED_FILENAME=payment.cred
    WALLET_STAKE_CRED_FILENAME=stake.cred
    FG_RED="" FG_GREEN="" FG_YELLOW="" FG_LGRAY="" NC=""
    EVENT_LOG="${event_log}"
    if [[ "${ccli_shadow}" == Y ]]; then
      function cardano-cli { : > "${capture_root}/shadow-invoked"; }
    fi
    [[ "${unset_clear}" != Y ]] || unset -f clear
    direct_status=0
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${private_root}/context.json" "${private_root}/result.json" ||
      direct_status=$?
    printf '%s\n' "${direct_status}" > "${capture_root}/status"
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    direct_status=0
  else
    direct_status=$?
  fi
  [[ "${direct_status}" == 0 ]] || fail "${scenario} harness returned ${direct_status}"
  direct_status="$(< "${capture_root}/status")"
  [[ "${direct_status}" == "${expected_status}" ]] ||
    fail "${scenario} returned ${direct_status}, expected ${expected_status}"
  write_direct_stdout "${scenario}" "${expected_stdout}"
  write_direct_stderr "${scenario}" "${expected_stderr}"
  write_direct_events "${scenario}" "${expected_events}"
  write_direct_vectors "${scenario}" "${expected_cli}"
  assert_files_equal "${stdout_file}" "${expected_stdout}" "${scenario} stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" "${scenario} stderr"
  assert_files_equal "${event_log}" "${expected_events}" "${scenario} events"
  assert_files_equal "${cli_log}" "${expected_cli}" "${scenario} CLI vector"
  [[ ! -s "${blocked_log}" ]] || fail "${scenario} attempted network access"
  [[ ! -e "${private_root}/result.json" &&
     -z "$(find "${private_root}" -mindepth 1 ! -name context.json -print -quit)" ]] ||
    fail "${scenario} left a result or private temporary file"
  tree_snapshot "${wallet_root}" "${after_tree}" ||
    fail "could not snapshot ${scenario} after dispatch"
  case "${scenario}" in
    direct-success-local|direct-success-light|direct-success-offline|\
      direct-mv-error-after|direct-root-0755-success|direct-absolute-ccli|\
      direct-production-clear)
      [[ -d "${wallet_root}/fixture_wallet" &&
         "$(file_mode "${wallet_root}/fixture_wallet")" == 700 ]] ||
        fail "${scenario} did not publish an owner-private wallet"
      [[ "$(find "${wallet_root}/fixture_wallet" -type f -print | wc -l | tr -d '[:space:]')" == 23 ]] ||
        fail "${scenario} final inventory changed"
      while IFS= read -r leaf; do
        [[ "$(file_mode "${leaf}")" == 600 ]] ||
          fail "${scenario} published a non-0600 leaf: ${leaf##*/}"
      done < <(find "${wallet_root}/fixture_wallet" -type f -print | LC_ALL=C sort)
      [[ -z "$(find "${wallet_root}" -mindepth 1 -maxdepth 1 -name '.*cntools-wallet-new-cli*' -print -quit)" ]] ||
        fail "${scenario} left a staging or lock directory"
      if [[ "${scenario}" == direct-root-0755-success ]]; then
        [[ "$(file_mode "${wallet_root}")" == 755 ]] ||
          fail 'safe established wallet-root mode was mutated'
      fi
      ;;
    direct-postcommit-lock-failure)
      [[ -d "${wallet_root}/fixture_wallet" &&
         -d "${wallet_root}/.fixture_wallet.cntools-wallet-new-cli.lock" ]] ||
        fail 'postcommit cleanup oracle changed'
      ;;
    direct-publish-collision)
      [[ "$(< "${wallet_root}/fixture_wallet/sentinel")" == collision ]] ||
        fail 'publish collision overwrote the competing destination'
      [[ -z "$(find "${wallet_root}" -mindepth 1 -maxdepth 1 -name '*.stage.*' -print -quit)" ]] ||
        fail 'publish collision left staging residue'
      ;;
    direct-signal-after-move|direct-signal-lock-release)
      [[ -d "${wallet_root}/fixture_wallet" &&
         "$(find "${wallet_root}/fixture_wallet" -type f -print | wc -l | tr -d '[:space:]')" == 23 &&
         -z "$(find "${wallet_root}" -mindepth 1 -maxdepth 1 -name '.*cntools-wallet-new-cli*' -print -quit)" ]] ||
        fail "${scenario} did not preserve the committed wallet cleanly"
      ;;
    direct-postcommit-display-capture)
      [[ -d "${wallet_root}/fixture_wallet" &&
         ! -e "${wallet_root}/fixture_wallet/base.addr" &&
         "$(find "${wallet_root}/fixture_wallet" -type f -print | wc -l | tr -d '[:space:]')" == 22 ]] ||
        fail 'postcommit display-capture oracle changed'
      ;;
    direct-stage-swap)
      [[ -L "$(find "${wallet_root}" -mindepth 1 -maxdepth 1 -name '*.stage.*' -print -quit)" &&
         -f "${outside_root}/escaped-stage/payment.skey" &&
         ! -e "${wallet_root}/fixture_wallet" ]] ||
        fail 'stage-swap containment oracle changed'
      ;;
    direct-cleanup-failure)
      [[ -d "$(find "${wallet_root}" -mindepth 1 -maxdepth 1 -name '*.stage.*' -print -quit)" &&
         -z "$(find "${wallet_root}" -mindepth 2 -type f -print -quit)" &&
         ! -e "${wallet_root}/fixture_wallet" ]] ||
        fail 'precommit cleanup-failure oracle changed'
      ;;
    direct-lock-swap)
      [[ -d "${wallet_root}/.fixture_wallet.cntools-wallet-new-cli.lock" &&
         ! -e "${wallet_root}/fixture_wallet" &&
         -z "$(find "${wallet_root}" -mindepth 1 -maxdepth 1 -name '*.stage.*' -print -quit)" ]] ||
        fail 'lock replacement authority oracle changed'
      ;;
    direct-hardlink-key)
      [[ ! -e "${wallet_root}/fixture_wallet" &&
         -f "${outside_root}/hardlink-4" ]] ||
        fail 'hardlink rejection behavior changed'
      ;;
    direct-duplicate|direct-destination-symlink|direct-lock-contention|\
      direct-signal-lock-acquire)
      assert_files_equal "${after_tree}" "${before_tree}" "${scenario} tree"
      ;;
    *)
      assert_files_equal "${after_tree}" "${before_tree}" "${scenario} tree"
      ;;
  esac
  if [[ "${scenario}" == direct-fail-[1-8] ||
        "${scenario}" == direct-derive-failure ||
        "${scenario}" == direct-late-base-tamper ]]; then
    ! grep -q $'\033' "${stderr_file}" ||
      fail "${scenario} reflected raw control bytes"
  fi
  [[ ! -e "${capture_root}/shadow-invoked" ]] ||
    fail "${scenario} executed a shadowed cardano-cli function"
}

write_fake_commands
run_case cancel OFFLINE
run_case empty OFFLINE
run_case sanitized OFFLINE
run_case duplicate LOCAL
for fail_step in 1 2 3 4 5 6 7 8; do
  run_case "fail-${fail_step}" LOCAL
done
run_case success-local LOCAL
run_case success-light LIGHT
run_case success-offline OFFLINE
run_case symlink-destination OFFLINE
run_case hardlink-residue OFFLINE

run_direct_case direct-cancel OFFLINE
run_direct_case direct-invalid-name OFFLINE
run_direct_case direct-duplicate LOCAL
for fail_step in 1 2 3 4 5 6 7 8; do
  run_direct_case "direct-fail-${fail_step}" LOCAL
done
run_direct_case direct-malformed-key LOCAL
run_direct_case direct-hardlink-key LOCAL
run_direct_case direct-derive-failure LOCAL
run_direct_case direct-malformed-address LOCAL
run_direct_case direct-wrong-network-base LOCAL
run_direct_case direct-wrong-network-reward LOCAL
run_direct_case direct-late-signing-tamper LOCAL
run_direct_case direct-late-base-tamper LOCAL
run_direct_case direct-stage-swap LOCAL
run_direct_case direct-cleanup-failure LOCAL
run_direct_case direct-lock-swap LOCAL
run_direct_case direct-success-local LOCAL
run_direct_case direct-success-light LIGHT
run_direct_case direct-success-offline OFFLINE
run_direct_case direct-root-0755-success OFFLINE
run_direct_case direct-absolute-ccli OFFLINE
run_direct_case direct-unsafe-ccli-symlink OFFLINE
run_direct_case direct-ccli-shadow OFFLINE
run_direct_case direct-production-clear OFFLINE
run_direct_case direct-unsafe-root-mode OFFLINE
run_direct_case direct-destination-symlink OFFLINE
run_direct_case direct-lock-contention OFFLINE
run_direct_case direct-publish-collision OFFLINE
run_direct_case direct-postcommit-lock-failure OFFLINE
run_direct_case direct-mv-error-after OFFLINE
run_direct_case direct-signal-after-move OFFLINE
run_direct_case direct-signal-lock-release OFFLINE
run_direct_case direct-signal-lock-acquire OFFLINE
run_direct_case direct-postcommit-display-capture OFFLINE

[[ "$(grep -Fc 'cntools_compatibility_dispatch_action wallet.new.cli' \
  "${CNTOOLS_SCRIPT}")" == 1 ]] ||
  fail 'public wallet-new-cli route is not exactly one generic dispatch call'
legacy_cli_arm="$(awk '
  /^[[:space:]]+cli\)$/ { capture = 1 }
  capture { print }
  capture && /;; ###################################################################/ { exit }
' "${CNTOOLS_SCRIPT}")"
[[ "${legacy_cli_arm}" == *'cntools_compatibility_dispatch_action wallet.new.cli'* &&
   "${legacy_cli_arm}" != *'latest governance drep key-gen'* &&
   "${legacy_cli_arm}" != *'safeDel '* ]] ||
  fail 'public wallet-new-cli arm contains stale inline production logic'
grep -Fq 'cntools_action_main() {' "${ACTION_SOURCE}" ||
  fail 'dedicated wallet-new-cli action entrypoint is missing'
[[ "$(grep -Ec '^_cntools_action_wallet_new_cli_[A-Za-z0-9_]+\(\)' "${ACTION_SOURCE}")" -ge 1 ]] ||
  fail 'dedicated wallet-new-cli helper namespace is missing'
if direct_guard_stderr="$("${BASH}" "${ACTION_SOURCE}" 2>&1)"; then
  fail 'dedicated wallet-new-cli action executed directly'
else
  direct_guard_status=$?
fi
[[ "${direct_guard_status}" == 64 &&
   "${direct_guard_stderr}" == 'CNTools actions are launched by the dispatcher, not directly.' ]] ||
  fail 'dedicated wallet-new-cli direct-execution guard changed'

printf 'CNTools wallet-new-cli characterization/parity passed (17 public + 40 direct cases)\n'
