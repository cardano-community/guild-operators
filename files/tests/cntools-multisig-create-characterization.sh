#!/usr/bin/env bash
# Focused public-route characterization for the legacy advanced.multisig.create arm.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2178,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools multisig-create characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/advanced/multisig/create/action.sh"
ACTION_DIRECTORY="${ACTION_SOURCE%/action.sh}"
MODULE_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/advanced/multisig/create/module.json"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-multisig-create.XXXXXX")"
TEST_ROOT="$(cd -P -- "${TEST_ROOT}" && pwd -P)"
BASE_PATH="${PATH}"
DIRECT_FAKE_BIN="${TEST_ROOT}/direct-fake-bin"
REAL_CHMOD="$(command -v chmod)"
REAL_JQ="$(command -v jq)"
REAL_LN="$(command -v ln)"
REAL_MKFIFO="$(command -v mkfifo)"
REAL_MKTEMP="$(command -v mktemp)"
REAL_MV="$(command -v mv)"
REAL_MKDIR="$(command -v mkdir)"
REAL_RM="$(command -v rm)"
REAL_RMDIR="$(command -v rmdir)"

PAY_A='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PAY_B='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
STAKE_A='11111111111111111111111111111111111111111111111111111111'
STAKE_B='22222222222222222222222222222222222222222222222222222222'
STAKE_C='33333333333333333333333333333333333333333333333333333333'
NONHEX_PAY='zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
NONHEX_STAKE='yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy'

cleanup_test() {
  if [[ "${CNTOOLS_MULTISIG_CREATE_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools multisig-create test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  "${REAL_CHMOD}" -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools multisig-create characterization failed: %s\n' "$1" >&2
  exit 1
}

for required_file in "${CNTOOLS_SCRIPT}" "${ACTION_SOURCE}" \
    "${MODULE_SOURCE}" "${REGISTRY_SOURCE}" "${CONTEXT_SOURCE}" \
    "${RESULT_SOURCE}" "${DISPATCHER_SOURCE}" "${STAGE4_TEST_LIBRARY}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" ]] ||
    fail "required source is missing or unsafe: ${required_file}"
done

# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

if command -v sha256sum >/dev/null 2>&1; then
  HASH_COMMAND=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  HASH_COMMAND=shasum
else
  fail 'sha256sum or shasum is required'
fi

stream_hash() {
  if [[ "${HASH_COMMAND}" == sha256sum ]]; then
    sha256sum | awk '{ print $1 }'
  else
    shasum -a 256 | awk '{ print $1 }'
  fi
}

file_identity() {
  local target="$1" identity=""
  if identity="$(stat -f '%d:%i' "${target}" 2>/dev/null)"; then
    :
  else
    identity="$(stat -c '%d:%i' -- "${target}")" || return 1
  fi
  printf '%s\n' "${identity}"
}

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

# Public parity traverses the real controller arm. This focused adapter replaces
# only installed-generation authority setup, then invokes the shipped action
# through the production dispatcher and its private context/result channel.
cntools_compatibility_dispatch_action() {
  local action_id="${1:-}" private_root="" context_file="" result_file=""
  local action_status=0 tmp_mode=""

  [[ "${action_id}" == advanced.multisig.create && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch:%s\n' "${action_id}" >> "${EVENT_LOG:?}"
  tmp_mode="$(file_mode "${TMP_DIR}")" || return 70
  private_root="$("${REAL_MKTEMP}" -d \
    "${TMP_DIR%/}/multisig-create-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  "${REAL_CHMOD}" 0700 "${TMP_DIR}" "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  "${REAL_JQ}" -nS --arg mode "${CNTOOLS_MODE,,}" \
    --arg node_home "${NODE_HOME}" '
      {
        advanced: true,
        apiVersion: 1,
        capabilities: ["forging", "local-cli", "metrics", "n2c"],
        features: ["advanced"],
        generationVersion: "13.5.7",
        mode: $mode,
        nodeHome: $node_home,
        nodeImplementation: "cnode",
        nodeNetwork: "preview",
        schemaVersion: 1
      }
    ' > "${context_file}" || return 70
  "${REAL_CHMOD}" 0400 "${context_file}" || return 70
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    action_status=0
  else
    action_status=$?
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || action_status=70
  "${REAL_RM}" -f -- "${result_file}" "${context_file}" || action_status=70
  "${REAL_RMDIR}" -- "${private_root}" || action_status=70
  "${REAL_CHMOD}" "${tmp_mode}" "${TMP_DIR}" || action_status=70
  [[ "${CAPTURE_ACTIVE:-N}" != Y ]] || END_ON_CLEAR=Y
  return "${action_status}"
}

# Fixed legacy filename ABI used both inside the public traversal and by the
# post-run mutation oracle.
WALLET_MULTISIG_PREFIX=multisig-
WALLET_PAY_VK_FILENAME=payment.vkey
WALLET_STAKE_VK_FILENAME=stake.vkey
WALLET_PAY_SCRIPT_FILENAME=payment.script
WALLET_STAKE_SCRIPT_FILENAME=stake.script
WALLET_BASE_ADDR_FILENAME=base.addr
WALLET_PAY_ADDR_FILENAME=payment.addr
WALLET_STAKE_ADDR_FILENAME=reward.addr
WALLET_PAY_SCRIPT_CRED_FILENAME=payment-script.cred
WALLET_STAKE_SCRIPT_CRED_FILENAME=stake-script.cred

println() {
  local level="${1:-}"
  shift || true
  case "${level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@" ;;
    *) printf '%b\n' "${level}" "$@" ;;
  esac
}

clear() {
  if [[ "${CAPTURE_ACTIVE:-N}" == Y && "${END_ON_CLEAR:-N}" == Y ]]; then
    printf '__CNTOOLS_MULTISIG_CREATE_END__\n'
    printf 'action:end:clear\n' >> "${EVENT_LOG:?}"
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
  fi
  printf 'terminal:clear\n' >> "${EVENT_LOG:?}"
}

tput() { return 0; }
getEpoch() { printf 5; }
timeUntilNextEpoch() { printf 0; }
timeLeft() { printf 0; }
slotInterval() { printf 20; }
getSlotTipRef() { printf 1000; }
getNodeMetrics() { printf 'runtime:getNodeMetrics\n' >> "${EVENT_LOG:?}"; slotnum=1000; }
getPriceInfo() { printf 'runtime:getPriceInfo\n' >> "${EVENT_LOG:?}"; price_now=""; }
updateProtocolParams() { printf 'runtime:updateProtocolParams\n' >> "${EVENT_LOG:?}"; }

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}" menu="" option="" index=0
  if [[ "${1:-}" == '[w] Wallet' ]]; then
    [[ "${CAPTURE_ACTIVE:-N}" == Y ]] && menu=participant || menu=main
  else
    case "${1:-}" in
      '[m] Metadata') menu=advanced ;;
      '[c] Create') menu=multisig ;;
      '[n] No') menu=confirm ;;
      *) fail "unexpected selection menu: ${1:-<empty>}" ;;
    esac
  fi
  [[ -n "${choice}" ]] || fail "menu ${menu} exhausted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    if [[ ( "${choice}" == e && "${option}" == '[Esc]'* ) ||
          "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == multisig:c ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_MULTISIG_CREATE_BEGIN__\n'
        printf 'action:begin\n' >> "${EVENT_LOG}"
      elif [[ "${CAPTURE_ACTIVE:-N}" == Y && "${choice}" == e ]]; then
        END_ON_CLEAR=Y
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice unavailable: ${menu}:${choice}"
}

createNewWallet() {
  printf 'action:createNewWallet\n' >> "${EVENT_LOG:?}"
  wallet_name=alpha
  if [[ "${SCENARIO:?}" == create-failure ]]; then
    END_ON_CLEAR=Y
    return 1
  fi
  if [[ "${SCENARIO}" != symlink-destination ]]; then
    mkdir -p -- "${WALLET_FOLDER}/${wallet_name}"
  fi
  if [[ "${SCENARIO}" == inline-existing ]]; then
    printf 'existing wallet material\n' > "${WALLET_FOLDER}/${wallet_name}/existing.skey"
  fi
  return 0
}

selectWallet() {
  printf 'action:selectWallet' >> "${EVENT_LOG:?}"
  printf '\t%s' "$@" >> "${EVENT_LOG}"
  printf '\n' >> "${EVENT_LOG}"
  case "${SCENARIO:?}" in
    wallet-select-failure) return 1 ;;
    wallet-select-cancel) return 2 ;;
    *) wallet_name=signer; return 0 ;;
  esac
}

getCredentials() {
  local name="${1:-}"
  printf 'action:getCredentials:%s\n' "${name}" >> "${EVENT_LOG:?}"
  if [[ "${name}" == signer ]]; then
    case "${SCENARIO:?}" in
      wallet-pay-missing) ms_pay_cred=; ms_stake_cred="${STAKE_A}" ;;
      wallet-stake-missing) ms_pay_cred="${PAY_A}"; ms_stake_cred= ;;
      *) ms_pay_cred="${PAY_A}"; ms_stake_cred="${STAKE_A}" ;;
    esac
    return 0
  fi
  unset script_pay_cred script_stake_cred
  if [[ "${SCENARIO:?}" == address-helper-failure ]]; then
    return 1
  fi
  script_pay_cred='script-payment-credential'
  script_stake_cred='script-stake-credential'
  printf '%s\n' "${script_pay_cred}" > \
    "${WALLET_FOLDER}/${name}/${WALLET_PAY_SCRIPT_CRED_FILENAME}"
  printf '%s\n' "${script_stake_cred}" > \
    "${WALLET_FOLDER}/${name}/${WALLET_STAKE_SCRIPT_CRED_FILENAME}"
}

getAnswerAnyCust() {
  local variable="${1:?}" value="" count=0
  printf 'action:prompt:%s:%s\n' "${variable}" "${2:-}" >> "${EVENT_LOG:?}"
  case "${variable}" in
    ms_pay_cred)
      PAY_PROMPT_COUNT=$((PAY_PROMPT_COUNT + 1))
      case "${SCENARIO:?}" in
        invalid-pay-length) value=short ;;
        nonhex-credentials) value="${NONHEX_PAY}" ;;
        two-signers)
          (( PAY_PROMPT_COUNT == 1 )) && value="${PAY_A}" || value="${PAY_B}"
          ;;
        duplicate-payment) value="${PAY_A}" ;;
        *) value="${PAY_A}" ;;
      esac
      ;;
    ms_stake_cred)
      STAKE_PROMPT_COUNT=$((STAKE_PROMPT_COUNT + 1))
      case "${SCENARIO:?}" in
        invalid-stake-length) value=short ;;
        nonhex-credentials) value="${NONHEX_STAKE}" ;;
        two-signers)
          (( STAKE_PROMPT_COUNT == 1 )) && value="${STAKE_A}" || value="${STAKE_B}"
          ;;
        duplicate-payment)
          (( STAKE_PROMPT_COUNT == 1 )) && value="${STAKE_A}" || value="${STAKE_C}"
          ;;
        *) value="${STAKE_A}" ;;
      esac
      ;;
    required_sig_cnt)
      case "${SCENARIO:?}" in
        invalid-required) value=0 ;;
        two-signers) value=2 ;;
        *) value=1 ;;
      esac
      if [[ "${SCENARIO}" == hardlink-script ]]; then
        ln -- "${OUTSIDE_ROOT}/external.script" \
          "${WALLET_FOLDER}/alpha/${WALLET_PAY_SCRIPT_FILENAME}"
        printf 'fault:hardlink-payment-script\n' >> "${EVENT_LOG}"
      fi
      ;;
    epoch_no)
      [[ "${SCENARIO:?}" == invalid-epoch ]] && value=bad || value=123
      ;;
    *) fail "unexpected prompt variable: ${variable}" ;;
  esac
  printf -v "${variable}" '%s' "${value}"
  count=${#value}
  printf 'action:prompt-result:%s:length=%s\n' "${variable}" "${count}" \
    >> "${EVENT_LOG}"
}

isNumber() { [[ "$#" == 1 && "${1:-}" =~ ^[0-9]+$ ]]; }

getEpochStart() {
  printf 'action:getEpochStart:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  printf 424242
}

getBaseAddress() {
  local name="${1:-}"
  printf 'action:getBaseAddress:%s\n' "${name}" >> "${EVENT_LOG:?}"
  unset base_addr
  [[ "${SCENARIO:?}" != address-helper-failure ]] || return 1
  base_addr='addr_test1basefixture'
  printf '%s\n' "${base_addr}" > "${WALLET_FOLDER}/${name}/${WALLET_BASE_ADDR_FILENAME}"
}

getPayAddress() {
  local name="${1:-}"
  printf 'action:getPayAddress:%s\n' "${name}" >> "${EVENT_LOG:?}"
  unset pay_addr
  [[ "${SCENARIO:?}" != address-helper-failure ]] || return 1
  pay_addr='addr_test1paymentfixture'
  printf '%s\n' "${pay_addr}" > "${WALLET_FOLDER}/${name}/${WALLET_PAY_ADDR_FILENAME}"
}

getRewardAddress() {
  local name="${1:-}"
  printf 'action:getRewardAddress:%s\n' "${name}" >> "${EVENT_LOG:?}"
  unset reward_addr
  [[ "${SCENARIO:?}" != address-helper-failure ]] || return 1
  reward_addr='stake_test1rewardfixture'
  printf '%s\n' "${reward_addr}" > "${WALLET_FOLDER}/${name}/${WALLET_STAKE_ADDR_FILENAME}"
}

safeDel() {
  local target="${1:-}" normalized="${1:-}"
  [[ "${target}" == "${WALLET_FOLDER}/"* ]] || fail "unsafe test deletion target: ${target}"
  normalized="<wallet>/${target#"${WALLET_FOLDER}/"}"
  printf 'action:safeDel:%s\n' "${normalized}" >> "${EVENT_LOG:?}"
  rm -rf -- "${target}"
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  END_ON_CLEAR=Y
  if [[ "${DIRECT_SCENARIO:-}" == direct-signal-wait &&
        "${DIRECT_SIGNAL_WAIT_SENT:-N}" != Y ]]; then
    DIRECT_SIGNAL_WAIT_SENT=Y
    kill -TERM "${BASHPID}"
  fi
  return 0
}

chmod() {
  if [[ "${SCENARIO:-}" == chmod-ignored && "${1:-}" == 600 &&
        "${2:-}" == "${WALLET_FOLDER}/alpha/${WALLET_PAY_SCRIPT_FILENAME}" ]]; then
    printf 'fault:chmod:ignored\n' >> "${EVENT_LOG:?}"
    return 55
  fi
  "${REAL_CHMOD}" "$@"
}

jq() {
  local argument="" count=0 fail_now=N saw_sig_script=N previous=""
  printf 'jq' >> "${VECTOR_LOG:?}"
  for argument in "$@"; do
    printf '\t%s' "${argument//$'\n'/<newline>}" >> "${VECTOR_LOG}"
    [[ "${previous}" == --argjson && "${argument}" == sig_script ]] &&
      saw_sig_script=Y
    previous="${argument}"
  done
  printf '\n' >> "${VECTOR_LOG}"
  if [[ "${SCENARIO:?}" == timelock-bug && "${saw_sig_script}" == Y ]]; then
    printf '%s\n' 'jq: invalid JSON text passed to --argjson' >&2
    return 2
  fi
  if [[ "${1:-}" == -e ]]; then
    count="$(< "${JQ_STATE}")"
    count=$((count + 1))
    printf '%s\n' "${count}" > "${JQ_STATE}"
    [[ "${SCENARIO}" == jq-pay-failure && "${count}" == 1 ]] && fail_now=Y
    [[ "${SCENARIO}" == jq-stake-failure && "${count}" == 2 ]] && fail_now=Y
    if [[ "${fail_now}" == Y ]]; then
      printf '%s\n' 'RAW\033[31mJQ-VALIDATION-FAIL' >&2
      return 41
    fi
  fi
  "${REAL_JQ}" "$@"
}

for blocked_command in curl wget git ssh nc; do
  eval "${blocked_command}() { printf '%s\\n' '${blocked_command}' >> \"\${NETWORK_LOG:?}\"; return 97; }"
done
unset blocked_command

myExit() {
  printf 'exit:%s:%s\n' "${1:-0}" "${2:-}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'public traversal did not consume every scripted choice'
  exit "${1:-0}"
}

extract_between_markers() {
  local source="$1" target="$2" begin="$3" end="$4"
  [[ "$(grep -cF "${begin}" "${source}" || true)" == 1 &&
     "$(grep -cF "${end}" "${source}" || true)" == 1 ]] ||
    fail "capture markers changed in ${source}"
  awk -v begin="${begin}" -v end="${end}" \
    '$0 == begin { active=1; next } $0 == end { exit } active' \
    "${source}" > "${target}"
}

normalize_file() {
  local source="$1" target="$2" runtime="$3"
  sed "s#${runtime}#<runtime>#g" "${source}" > "${target}"
}

setup_case() {
  local scenario="$1" wallet_root="$2" outside="$3"
  case "${scenario}" in
    symlink-destination)
      mkdir -p -- "${outside}/symlink-wallet"
      ln -s ../outside/symlink-wallet "${wallet_root}/alpha"
      ;;
    hardlink-script)
      printf 'outside sentinel\n' > "${outside}/external.script"
      "${REAL_CHMOD}" 0600 "${outside}/external.script"
      ;;
  esac
}

set_case_choices() {
  local scenario="$1"
  case "${scenario}" in
    create-failure|inline-existing) CASE_CHOICES=(a s c h q) ;;
    cancel-initial) CASE_CHOICES=(a s c e h q) ;;
    done-zero) CASE_CHOICES=(a s c d h q) ;;
    wallet-select-failure|wallet-pay-missing|wallet-stake-missing)
      CASE_CHOICES=(a s c w e h q)
      ;;
    wallet-select-cancel) CASE_CHOICES=(a s c w e h q) ;;
    invalid-pay-length|invalid-stake-length)
      CASE_CHOICES=(a s c c e h q)
      ;;
    invalid-required) CASE_CHOICES=(a s c c n h q) ;;
    time-cancel) CASE_CHOICES=(a s c c n e h q) ;;
    invalid-epoch|timelock-bug) CASE_CHOICES=(a s c c n y h q) ;;
    two-signers|duplicate-payment) CASE_CHOICES=(a s c c y c n n h q) ;;
    wallet-success) CASE_CHOICES=(a s c w n n h q) ;;
    *) CASE_CHOICES=(a s c c n n h q) ;;
  esac
}

assert_mutation_contract() {
  local scenario="$1" wallet_root="$2" outside="$3" before="$4" after="$5"
  local destination="${wallet_root}/alpha" expected_count=0
  local outside_identity="" payment_identity=""
  case "${scenario}" in
    create-failure|cancel-initial|done-zero|wallet-select-failure|wallet-select-cancel|\
      wallet-pay-missing|wallet-stake-missing|invalid-pay-length|invalid-stake-length|\
      invalid-required|time-cancel|invalid-epoch|timelock-bug|jq-pay-failure|\
      jq-stake-failure)
      assert_files_equal "${after}" "${before}" "${scenario} zero mutation"
      return 0
      ;;
    inline-existing)
      [[ -f "${destination}/existing.skey" ]] ||
        fail 'inline duplicate warning residue changed'
      return 0
      ;;
    symlink-destination)
      [[ -L "${destination}" ]] || fail 'symlink destination was no longer followed'
      destination="${outside}/symlink-wallet"
      ;;
  esac
  [[ -f "${destination}/${WALLET_PAY_SCRIPT_FILENAME}" &&
     -f "${destination}/${WALLET_STAKE_SCRIPT_FILENAME}" ]] ||
    fail "${scenario} script publication changed"
  if [[ "${scenario}" == address-helper-failure ]]; then
    expected_count=2
  else
    expected_count=7
  fi
  [[ "$(find "${destination}" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" == "${expected_count}" ]] ||
    fail "${scenario} exact file inventory changed"
  if [[ "${scenario}" == chmod-ignored ]]; then
    [[ "$(file_mode "${destination}/${WALLET_PAY_SCRIPT_FILENAME}")" == 644 ]] ||
      fail 'ignored chmod failure no longer leaves permissive scripts'
  else
    [[ "$(file_mode "${destination}/${WALLET_PAY_SCRIPT_FILENAME}")" == 600 &&
       "$(file_mode "${destination}/${WALLET_STAKE_SCRIPT_FILENAME}")" == 600 ]] ||
      fail "${scenario} script modes changed"
  fi
  if [[ "${scenario}" == hardlink-script ]]; then
    outside_identity="$(file_identity "${outside}/external.script")"
    payment_identity="$(file_identity "${destination}/${WALLET_PAY_SCRIPT_FILENAME}")"
    [[ "${outside_identity}" == "${payment_identity}" &&
       "$(< "${outside}/external.script")" == *'"type": "atLeast"'* ]] ||
      fail 'hard-linked outside script overwrite changed'
  fi
  if [[ "${scenario}" == duplicate-payment ]]; then
    "${REAL_JQ}" -e --arg pay "${PAY_A}" --arg stake "${STAKE_C}" '
      .required == 1 and (.scripts | length) == 1 and
      .scripts[0].keyHash == $stake
    ' "${destination}/${WALLET_STAKE_SCRIPT_FILENAME}" >/dev/null ||
      fail 'duplicate payment credential overwrite semantics changed'
  fi
  if [[ "${scenario}" == nonhex-credentials ]]; then
    "${REAL_JQ}" -e --arg pay "${NONHEX_PAY}" '
      .scripts[0].keyHash == $pay
    ' "${destination}/${WALLET_PAY_SCRIPT_FILENAME}" >/dev/null ||
      fail 'length-only credential acceptance changed'
  fi
  if [[ "${scenario}" == two-signers ]]; then
    "${REAL_JQ}" -e '.required == 2 and (.scripts | length) == 2' \
      "${destination}/${WALLET_PAY_SCRIPT_FILENAME}" >/dev/null ||
      fail 'two-signer threshold/order contract changed'
  fi
}

expected_signature() {
  case "$1" in
    create-failure) printf '%s\n' 972ece35cef7b303767f2438a558a17a672014425fedd71bd168fbc7d701dbd6 ;;
    inline-existing) printf '%s\n' 7db7dc06c8a208f7f17807e356849de5bbc6fe2f9bfcace6194a98fb237c31a1 ;;
    cancel-initial) printf '%s\n' 3a52cf561c2c325281fa225e2f7bc52e3248074204a5f9fbf8f7d264b66a80ca ;;
    done-zero) printf '%s\n' ccc2367f450b293635f1aac18fd746eb32ebb36fc5aa3b829ac2c8029e373fae ;;
    wallet-select-failure) printf '%s\n' 54137c4ce0f38ad3c82e9edb40630ccc64fb691135a7bdd010ab1d742750fe82 ;;
    wallet-select-cancel) printf '%s\n' 3e903c72c411f00538ccd4b385f9b12c31a002eef950c5d402e59ad1a1e7e217 ;;
    wallet-pay-missing) printf '%s\n' de1035f0db9802ba4ec754281ad33d87e5150cee9d7fb953d4ffd48f208f14d0 ;;
    wallet-stake-missing) printf '%s\n' 09611023f023dcda165e12b108216ee4c0dd052966538121f5bd0cc98532ab3a ;;
    invalid-pay-length) printf '%s\n' 4c18599d390eb74f6e0d0551860eae2a6e450c1152bc2cf2c6f1f9f1b5862b54 ;;
    invalid-stake-length) printf '%s\n' 7694afc40ce65d8355a019af39b9844a6dd51b26258a0472031d92d5d174067d ;;
    invalid-required) printf '%s\n' 14c4cd50bff21aac00cf518d33b07884523fdc86965ba61579b83a81b95ceb20 ;;
    time-cancel) printf '%s\n' 27cbc8d8415b9c0ef73da1c531181731914a8ad0fb2619922f8b704c27f188e6 ;;
    invalid-epoch) printf '%s\n' 637b89c5ea2af73f7628e4de89d50487bd39abcb61e06a7bf64229386149944d ;;
    timelock-bug) printf '%s\n' 13ae7441d7531673f82562f287d7775d02d8b38f3c0dfb07d74d2755af843465 ;;
    jq-pay-failure) printf '%s\n' bea71f51d9a2f8e89be2d352ba9d6c6f7be9f38cb898f4b894e532903ea15c5b ;;
    jq-stake-failure) printf '%s\n' 21f8649bad62245b2a786e7c86363287fecff17aa3f406fac4eae669f9b09da9 ;;
    success-local|success-light|success-offline)
      printf '%s\n' 560fed83afac061a0edece6c74b0936e0561fbbd7f91cae34c705970fa249127
      ;;
    wallet-success) printf '%s\n' b3190a14cc7b648ccfc5f6dfdab8659a48afae5b6c6243bf1b66598a068abc62 ;;
    two-signers)
      if (( BASH_VERSINFO[0] == 4 )); then
        printf '%s\n' 9604804fca929e82d1e05fda33732dabfd6bff77fbb7c3e8dbbae7247796723d
      else
        printf '%s\n' 8d4ab2abfb49d5194ff9216b2910913a6db7e8ad659f405248701c80b63ddea3
      fi
      ;;
    duplicate-payment) printf '%s\n' a638d911223ee4eb655514ecc8681a6d123394b018e10772c45fd0bfbba4ce45 ;;
    nonhex-credentials) printf '%s\n' e5c38aea3105d2c702656eca045647367049c01275a28e87bf642bb958ef5099 ;;
    address-helper-failure) printf '%s\n' f36ae39601d57fdfb6e306c8e1247d243752d04f0a8eb42613ba2adec44e700a ;;
    chmod-ignored) printf '%s\n' 0290fcd29c7f9dcd22d07d21c59f386e1a18d3d6a582496b0d9b4513c40c418d ;;
    symlink-destination) printf '%s\n' 01142f123044b95795070f82f2790999874adce6b96e02003bd43c4643b41050 ;;
    hardlink-script) printf '%s\n' 01239aca4a26837a6e239b611bd3593e977b8a7bea4f572aff12e041f249ae4a ;;
    *) return 1 ;;
  esac
}

run_case() (
  local scenario="$1" mode="$2" case_root="${TEST_ROOT}/cases/$1"
  local runtime="${case_root}/runtime" wallet_root="" outside="" capture=""
  local full_stdout="" action_stdout="" stderr_file="" events="" action_events=""
  local vectors="" network="" before="" after="" normalized_events=""
  local normalized_vectors="" signature="" expected="" status=0 waits=0
  local -a CASE_CHOICES=()
  wallet_root="${runtime}/wallet"
  outside="${runtime}/outside"
  capture="${case_root}/capture"
  full_stdout="${capture}/full.stdout"
  action_stdout="${capture}/action.stdout"
  stderr_file="${capture}/stderr"
  events="${capture}/events"
  action_events="${capture}/action.events"
  vectors="${capture}/vectors"
  network="${capture}/network"
  before="${capture}/before.tree"
  after="${capture}/after.tree"
  normalized_events="${capture}/events.normalized"
  normalized_vectors="${capture}/vectors.normalized"
  mkdir -p -- "${wallet_root}" "${outside}" "${runtime}/tmp" \
    "${runtime}/home" "${runtime}/pool" "${runtime}/asset" "${capture}"
  setup_case "${scenario}" "${wallet_root}" "${outside}"
  tree_snapshot "${runtime}" "${before}" || fail "${scenario} pre-snapshot failed"
  : > "${events}"; : > "${vectors}"; : > "${network}"
  printf '0\n' > "${capture}/jq-state"
  set_case_choices "${scenario}"
  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC PATH="${BASE_PATH}"
    HOME="${runtime}/home"
    NODE_HOME="${runtime}/home"
    TMP_DIR="${runtime}/tmp"
    WALLET_FOLDER="${wallet_root}"
    POOL_FOLDER="${runtime}/pool"
    ASSET_FOLDER="${runtime}/asset"
    BLOCKLOG_DB="${runtime}/absent.db"
    ADVANCED_MODE=true
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=10.1.0
    NETWORK_NAME=Preview
    CURRENCY=off
    CCLI=cardano-cli
    WALLET_MULTISIG_PREFIX=multisig-
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_PAY_SCRIPT_FILENAME=payment.script
    WALLET_STAKE_SCRIPT_FILENAME=stake.script
    WALLET_BASE_ADDR_FILENAME=base.addr
    WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_STAKE_ADDR_FILENAME=reward.addr
    WALLET_PAY_SCRIPT_CRED_FILENAME=payment-script.cred
    WALLET_STAKE_SCRIPT_CRED_FILENAME=stake-script.cred
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE="" FG_MAGENTA=""
    FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE="" FG_WHITE="" NC=""
    EVENT_LOG="${events}"
    VECTOR_LOG="${vectors}"
    NETWORK_LOG="${network}"
    OUTSIDE_ROOT="${outside}"
    JQ_STATE="${capture}/jq-state"
    SCENARIO="${scenario}"
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
    CHOICES=("${CASE_CHOICES[@]}")
    CHOICE_CURSOR=0
    PAY_PROMPT_COUNT=0
    STAKE_PROMPT_COUNT=0
    unset wallet_name ms_wallet_name ms_pay_cred ms_stake_cred required_sig_cnt
    unset epoch_no timelock_after pay_script stake_script base_addr pay_addr reward_addr
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == 0 ]] || fail "${scenario} public traversal returned ${status}"
  extract_between_markers "${full_stdout}" "${action_stdout}" \
    '__CNTOOLS_MULTISIG_CREATE_BEGIN__' '__CNTOOLS_MULTISIG_CREATE_END__'
  awk '$0=="action:begin"{p=1;next}$0 ~ /^action:end:/{exit}p' \
    "${events}" > "${action_events}"
  normalize_file "${action_events}" "${normalized_events}" "${runtime}"
  normalize_file "${vectors}" "${normalized_vectors}" "${runtime}"
  [[ ! -s "${network}" ]] || fail "${scenario} attempted network access"
  grep -Fq ' >> ADVANCED >> MULTISIG >> CREATE WALLET' "${action_stdout}" ||
    fail "${scenario} action header changed"
  [[ "$(grep -c '^menu:main:a$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:advanced:s$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:multisig:c$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:multisig:h$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:main:q$' "${events}" || true)" == 1 ]] ||
    fail "${scenario} public navigation changed"
  waits="$(grep -c '^action:waitToProceed$' "${action_events}" || true)"
  case "${scenario}" in
    create-failure|cancel-initial|wallet-select-cancel|time-cancel)
      [[ "${waits}" == 0 ]] || fail "${scenario} wait behavior changed" ;;
    *) [[ "${waits}" == 1 ]] || fail "${scenario} wait behavior changed" ;;
  esac
  if [[ "${scenario}" == timelock-bug ]]; then
    grep -Fqx 'jq: invalid JSON text passed to --argjson' "${stderr_file}" ||
      fail 'timelock undefined-jsonscript diagnostic changed'
  elif [[ -s "${stderr_file}" ]]; then
    fail "${scenario} unexpected stderr"
  fi
  if [[ "${scenario}" == jq-pay-failure || "${scenario}" == jq-stake-failure ]]; then
    ! grep -Fq 'JQ-VALIDATION-FAIL' "${action_stdout}" "${stderr_file}" ||
      fail "${scenario} no longer loses the redirected jq diagnostic"
  fi
  tree_snapshot "${runtime}" "${after}" || fail "${scenario} post-snapshot failed"
  assert_mutation_contract "${scenario}" "${wallet_root}" "${outside}" \
    "${before}" "${after}"
  signature="$(
    printf '%s\t%s\t%s\t%s\t%s\t%s' \
      "$(file_hash "${action_stdout}")" \
      "$(file_hash "${stderr_file}")" \
      "$(file_hash "${normalized_events}")" \
      "$(file_hash "${normalized_vectors}")" \
      "$(file_hash "${before}")" \
      "$(file_hash "${after}")" | stream_hash
  )"
  expected="$(expected_signature "${scenario}")" ||
    fail "${scenario} has no frozen signature"
  [[ "${signature}" == "${expected}" ]] ||
    fail "${scenario} exact stream/event/vector/tree signature changed (${signature})"
)

# The exact pre-bind records remain reviewable even though the public arm now
# owns only transport. Hardened behavior is covered below by one real public
# traversal and the complete direct matrix.
legacy_fingerprint_count=0
for legacy_scenario in \
  create-failure inline-existing cancel-initial done-zero \
  wallet-select-failure wallet-select-cancel wallet-pay-missing \
  wallet-stake-missing invalid-pay-length invalid-stake-length \
  invalid-required time-cancel invalid-epoch timelock-bug jq-pay-failure \
  jq-stake-failure success-local success-light success-offline \
  wallet-success two-signers duplicate-payment nonhex-credentials \
  address-helper-failure chmod-ignored symlink-destination hardlink-script; do
  legacy_fingerprint="$(expected_signature "${legacy_scenario}")"
  [[ "${legacy_fingerprint}" =~ ^[0-9a-f]{64}$ ]] ||
    fail "invalid frozen legacy fingerprint: ${legacy_scenario}"
  legacy_fingerprint_count=$((legacy_fingerprint_count + 1))
done
[[ "${legacy_fingerprint_count}" == 27 ]] ||
  fail 'frozen legacy fingerprint coverage changed'

# The frozen records above characterize the legacy public route. The direct
# matrix below exercises only the unbound hardened action boundary.
unset -f jq chmod

write_direct_fake_commands() {
  local command_name=""

  mkdir -p -- "${DIRECT_FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MULTISIG_CREATE_DIRECT_SCENARIO:?}"' \
    'log="${CNTOOLS_MULTISIG_CREATE_DIRECT_VECTORS:?}"' \
    'outside="${CNTOOLS_MULTISIG_CREATE_DIRECT_OUTSIDE:?}"' \
    'printf '\''cardano-cli'\'' >> "${log}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  [[ "${normalized}" == "${CNTOOLS_MULTISIG_CREATE_DIRECT_ROOT}/"* ]] && normalized="<wallet>/${normalized#"${CNTOOLS_MULTISIG_CREATE_DIRECT_ROOT}/"}"' \
    '  [[ "${normalized}" == "${CNTOOLS_MULTISIG_CREATE_DIRECT_PRIVATE}/"* ]] && normalized="<private>/${normalized#"${CNTOOLS_MULTISIG_CREATE_DIRECT_PRIVATE}/"}"' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${log}"' \
    'done' \
    'printf '\''\n'\'' >> "${log}"' \
    '[[ "${1:-}" != --version ]] || { printf '\''cardano-cli 10.1.1.0\n'\''; exit 0; }' \
    'previous="" outfile="" script="" payment_vkey="" stake_vkey=""' \
    'for argument in "$@"; do' \
    '  case "${previous}" in' \
    '    --out-file) outfile="${argument}" ;;' \
    '    --script-file) script="${argument}" ;;' \
    '    --payment-verification-key-file) payment_vkey="${argument}" ;;' \
    '    --stake-verification-key-file) stake_vkey="${argument}" ;;' \
    '  esac' \
    '  previous="${argument}"' \
    'done' \
    'operation=unknown' \
    'case "$*" in' \
    '  "address key-hash "*) operation=payment-key-hash ;;' \
    '  "latest stake-address key-hash "*) operation=stake-key-hash ;;' \
    '  "address build "*) [[ "$*" == *"--stake-script-file"* ]] && operation=base || operation=payment ;;' \
    '  "latest stake-address build "*) operation=reward ;;' \
    '  "hash script "*) [[ "${script##*/}" == payment.script ]] && operation=payment-credential || operation=stake-credential ;;' \
    'esac' \
    'case "${operation}" in' \
    '  payment-key-hash) printf '\''aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'\'' > "${outfile}" ;;' \
    '  stake-key-hash) printf '\''11111111111111111111111111111111111111111111111111111111\n'\'' > "${outfile}" ;;' \
    '  base)' \
    '    printf '\''addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq\n'\'' > "${outfile}"' \
    '    [[ "${scenario}" != direct-wrong-network ]] || printf '\''addr1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq\n'\'' > "${outfile}"' \
    '    [[ "${scenario}" != direct-signal-derive ]] || kill -TERM "${CNTOOLS_MULTISIG_CREATE_ACTION_PID:?}"' \
    '    if [[ "${scenario}" == direct-symlink-output ]]; then rm -f -- "${outfile}"; ln -s -- "${outside}/escaped.addr" "${outfile}"; fi' \
    '    if [[ "${scenario}" == direct-hardlink-output ]]; then rm -f -- "${outfile}"; "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_LN:?}" -- "${outside}/escaped.addr" "${outfile}"; fi' \
    '    if [[ "${scenario}" == direct-fifo-output ]]; then rm -f -- "${outfile}"; "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKFIFO:?}" -- "${outfile}"; chmod 0640 "${outfile}"; fi' \
    '    ;;' \
    '  payment)' \
    '    [[ "${scenario}" != direct-bad-address ]] && printf '\''addr_test1pppppppppppppppppppppppppppppppp\n'\'' > "${outfile}" || printf '\''addr_test1bad\n'\'' > "${outfile}" ;;' \
    '  reward) printf '\''stake_test1rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr\n'\'' > "${outfile}" ;;' \
    '  payment-credential) printf '\''cccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n'\'' > "${outfile}" ;;' \
    '  stake-credential)' \
    '    [[ "${scenario}" != direct-bad-credential ]] && printf '\''dddddddddddddddddddddddddddddddddddddddddddddddddddddddd\n'\'' > "${outfile}" || printf '\''not-a-credential\n'\'' > "${outfile}" ;;' \
    '  *) exit 62 ;;' \
    'esac' \
    'case "${scenario}:${operation}" in' \
    '  direct-cli-failure:base|direct-cli-base-rm-persistent:base|direct-cli-payment-private-persistent:payment|direct-cli-reward-lock-persistent:reward|direct-cli-payment-credential-rm-retry:payment-credential|direct-cli-stake-credential-private-retry:stake-credential|direct-cli-stake-credential-lock-retry:stake-credential)' \
    '    printf '\''RAW TOOL ERROR \033[31m\n'\'' >&2' \
    '    exit 41' \
    '    ;;' \
    'esac' \
    > "${DIRECT_FAKE_BIN}/cardano-cli"
  chmod 0755 "${DIRECT_FAKE_BIN}/cardano-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'if [[ "${CNTOOLS_MULTISIG_CREATE_DIRECT_SCENARIO:?}" == direct-json-schema && "$*" == *"required:\$required"* ]]; then' \
    '  printf '\''{"required":1,"scripts":[{"keyHash":"bad","type":"sig"}],"type":"atLeast"}\n'\''' \
    '  exit 0' \
    'fi' \
    'exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_JQ:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/jq"
  chmod 0755 "${DIRECT_FAKE_BIN}/jq"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MULTISIG_CREATE_DIRECT_SCENARIO:?}"' \
    'source_path="${2:-}" destination="${3:-}"' \
    'case "${scenario}" in' \
    '  direct-mv-created-nonzero) "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MV:?}" "$@" || exit $?; exit 71 ;;' \
    '  direct-mv-failure|direct-rm-created-nonzero|direct-rm-retry|direct-rm-persistent|direct-rmdir-created-nonzero|direct-rmdir-retry|direct-rmdir-persistent) exit 72 ;;' \
    '  direct-signal-publish) "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MV:?}" "$@" || exit $?; kill -TERM "${PPID}"; exit 0 ;;' \
    '  direct-publish-collision) "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKDIR:?}" -m 0700 -- "${destination}"; printf '\''competitor\n'\'' > "${destination}/collision"; chmod 0600 "${destination}/collision"; exit 73 ;;' \
    'esac' \
    'exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MV:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/mv"
  chmod 0755 "${DIRECT_FAKE_BIN}/mv"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'target="${*: -1}"' \
    'if [[ "${CNTOOLS_MULTISIG_CREATE_DIRECT_SCENARIO:?}" == direct-signal-lock && "${target}" == *.cntools-multisig-create.lock ]]; then' \
    '  "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKDIR:?}" "$@" || exit $?' \
    '  kill -TERM "${PPID}"' \
    '  exit 0' \
    'fi' \
    'exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKDIR:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/mkdir"
  chmod 0755 "${DIRECT_FAKE_BIN}/mkdir"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MULTISIG_CREATE_DIRECT_SCENARIO:?}"' \
    'target="${*: -1}"' \
    'if [[ "${target}" == *.cntools-multisig-create.stage.*/payment.script ]]; then' \
    '  case "${scenario}" in' \
    '    direct-rm-created-nonzero) "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_RM:?}" "$@" || exit $?; exit 75 ;;' \
    '    direct-rm-retry|direct-cli-payment-credential-rm-retry)' \
    '      if [[ ! -e "${CNTOOLS_MULTISIG_CREATE_DIRECT_FAULT_MARKER:?}" ]]; then printf '\''retry\n'\'' > "${CNTOOLS_MULTISIG_CREATE_DIRECT_FAULT_MARKER}"; exit 75; fi' \
    '      ;;' \
    '    direct-rm-persistent|direct-cli-base-rm-persistent) exit 75 ;;' \
    '  esac' \
    'elif [[ "${target}" == "${CNTOOLS_MULTISIG_CREATE_DIRECT_PRIVATE}"/multisig-create-stage-leaf-* ]]; then' \
    '  :' \
    'elif [[ "${target}" == "${CNTOOLS_MULTISIG_CREATE_DIRECT_PRIVATE}"/multisig-create-* ]]; then' \
    '  case "${scenario}" in' \
    '    direct-private-rm-created-nonzero) "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_RM:?}" "$@" || exit $?; exit 75 ;;' \
    '    direct-private-rm-retry|direct-cli-stake-credential-private-retry)' \
    '      if [[ ! -e "${CNTOOLS_MULTISIG_CREATE_DIRECT_FAULT_MARKER:?}" ]]; then printf '\''retry\n'\'' > "${CNTOOLS_MULTISIG_CREATE_DIRECT_FAULT_MARKER}"; exit 75; fi' \
    '      ;;' \
    '    direct-private-rm-persistent|direct-cli-payment-private-persistent) exit 75 ;;' \
    '  esac' \
    'fi' \
    'exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_RM:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/rm"
  chmod 0755 "${DIRECT_FAKE_BIN}/rm"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MULTISIG_CREATE_DIRECT_SCENARIO:?}"' \
    'target="${*: -1}"' \
    'if [[ "${target}" == *.cntools-multisig-create.stage.* ]]; then' \
    '  case "${scenario}" in' \
    '    direct-rmdir-created-nonzero) "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_RMDIR:?}" "$@" || exit $?; exit 76 ;;' \
    '    direct-rmdir-retry)' \
    '      if [[ ! -e "${CNTOOLS_MULTISIG_CREATE_DIRECT_FAULT_MARKER:?}" ]]; then printf '\''retry\n'\'' > "${CNTOOLS_MULTISIG_CREATE_DIRECT_FAULT_MARKER}"; exit 76; fi' \
    '      ;;' \
    '    direct-rmdir-persistent) exit 76 ;;' \
    '  esac' \
    'elif [[ "${target}" == *.cntools-multisig-create.lock ]]; then' \
    '  case "${scenario}" in' \
    '    direct-lock-rmdir-created-nonzero) "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_RMDIR:?}" "$@" || exit $?; exit 76 ;;' \
    '    direct-lock-rmdir-retry|direct-cli-stake-credential-lock-retry)' \
    '      if [[ ! -e "${CNTOOLS_MULTISIG_CREATE_DIRECT_FAULT_MARKER:?}" ]]; then printf '\''retry\n'\'' > "${CNTOOLS_MULTISIG_CREATE_DIRECT_FAULT_MARKER}"; exit 76; fi' \
    '      ;;' \
    '    direct-postcommit-lock-release|direct-cli-reward-lock-persistent) exit 74 ;;' \
    '  esac' \
    'fi' \
    'exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_RMDIR:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/rmdir"
  chmod 0755 "${DIRECT_FAKE_BIN}/rmdir"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MULTISIG_CREATE_DIRECT_SCENARIO:?}"' \
    'outside="${CNTOOLS_MULTISIG_CREATE_DIRECT_OUTSIDE:?}"' \
    'private="${CNTOOLS_MULTISIG_CREATE_DIRECT_PRIVATE:?}"' \
    'root="${CNTOOLS_MULTISIG_CREATE_DIRECT_ROOT:?}"' \
    'template="${*: -1}"' \
    'case "${scenario}" in' \
    '  direct-mktemp-private-symlink)' \
    '    [[ "${template}" == "${private}/multisig-create-version.XXXXXXXX" ]] || exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKTEMP:?}" "$@"' \
    '    target="${private}/multisig-create-version.ABCDEFGH"' \
    '    "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_LN:?}" -s -- "${outside}/private-symlink-sentinel" "${target}"' \
    '    printf '\''%s\n'\'' "${target}"; exit 0 ;;' \
    '  direct-mktemp-private-hardlink)' \
    '    [[ "${template}" == "${private}/multisig-create-version.XXXXXXXX" ]] || exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKTEMP:?}" "$@"' \
    '    target="${private}/multisig-create-version.ABCDEFGH"' \
    '    "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_LN:?}" -- "${outside}/private-hardlink-sentinel" "${target}"' \
    '    printf '\''%s\n'\'' "${target}"; exit 0 ;;' \
    '  direct-mktemp-private-fifo)' \
    '    [[ "${template}" == "${private}/multisig-create-version.XXXXXXXX" ]] || exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKTEMP:?}" "$@"' \
    '    target="${private}/multisig-create-version.ABCDEFGH"' \
    '    "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKFIFO:?}" -- "${target}"' \
    '    "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_CHMOD:?}" 0640 "${target}"' \
    '    printf '\''%s\n'\'' "${target}"; exit 0 ;;' \
    '  direct-mktemp-private-outside-special)' \
    '    [[ "${template}" == "${private}/multisig-create-version.XXXXXXXX" ]] || exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKTEMP:?}" "$@"' \
    '    printf '\''%s\n'\'' "${outside}/private-special"; exit 0 ;;' \
    '  direct-mktemp-stage-outside-directory)' \
    '    [[ "${1:-}" == -d && "${template}" == "${root}/.alpha.cntools-multisig-create.stage.XXXXXXXX" ]] || exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKTEMP:?}" "$@"' \
    '    printf '\''%s\n'\'' "${outside}/stage-outside"; exit 0 ;;' \
    '  direct-mktemp-stage-ancestor-symlink)' \
    '    [[ "${1:-}" == -d && "${template}" == "${root}/.alpha.cntools-multisig-create.stage.XXXXXXXX" ]] || exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKTEMP:?}" "$@"' \
    '    printf '\''%s\n'\'' "${root}/stage-ancestor-link/.alpha.cntools-multisig-create.stage.ABCDEFGH"; exit 0 ;;' \
    '  direct-mktemp-stage-outside-symlink)' \
    '    [[ "${1:-}" == -d && "${template}" == "${root}/.alpha.cntools-multisig-create.stage.XXXXXXXX" ]] || exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKTEMP:?}" "$@"' \
    '    printf '\''%s\n'\'' "${root}/.alpha.cntools-multisig-create.stage.ABCDEFGH"; exit 0 ;;' \
    '  direct-mktemp-stage-prepop-*)' \
    '    [[ "${1:-}" == -d && "${template}" == "${root}/.alpha.cntools-multisig-create.stage.XXXXXXXX" ]] || exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKTEMP:?}" "$@"' \
    '    printf '\''%s\n'\'' "${root}/.alpha.cntools-multisig-create.stage.ABCDEFGH"; exit 0 ;;' \
    'esac' \
    'exec "${CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKTEMP:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/mktemp"
  chmod 0755 "${DIRECT_FAKE_BIN}/mktemp"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s\n'\'' "${0##*/}" >> "${CNTOOLS_MULTISIG_CREATE_DIRECT_NETWORK:?}"' \
      'exit 97' > "${DIRECT_FAKE_BIN}/${command_name}"
    chmod 0755 "${DIRECT_FAKE_BIN}/${command_name}"
  done
}

write_direct_fake_commands

run_bound_public_case() (
  local case_root="${TEST_ROOT}/bound-public" runtime="" wallet_root=""
  local outside="" capture="" stdout_file="" action_stdout=""
  local stderr_file="" events="" vectors="" network="" before="" after=""
  local fault_marker="" status=0
  local -a CASE_CHOICES=(a s c h q)

  runtime="${case_root}/runtime"
  wallet_root="${runtime}/wallet"
  outside="${runtime}/outside"
  capture="${case_root}/capture"
  stdout_file="${capture}/stdout"
  action_stdout="${capture}/action.stdout"
  stderr_file="${capture}/stderr"
  events="${capture}/events"
  vectors="${capture}/vectors"
  network="${capture}/network"
  before="${capture}/before.wallet"
  after="${capture}/after.wallet"
  fault_marker="${capture}/fault.marker"
  mkdir -p -- "${wallet_root}" "${outside}" "${runtime}/tmp" \
    "${runtime}/home" "${runtime}/pool" "${runtime}/asset" "${capture}"
  tree_snapshot "${wallet_root}" "${before}"
  : > "${events}"
  : > "${vectors}"
  : > "${network}"

  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC PATH="${DIRECT_FAKE_BIN}:${BASE_PATH}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_SCENARIO=bound-public-cancel
    export CNTOOLS_MULTISIG_CREATE_DIRECT_VECTORS="${vectors}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_NETWORK="${network}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_ROOT="${wallet_root}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_OUTSIDE="${outside}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_PRIVATE="${runtime}/tmp"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_JQ="${REAL_JQ}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_LN="${REAL_LN}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_CHMOD="${REAL_CHMOD}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKFIFO="${REAL_MKFIFO}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKTEMP="${REAL_MKTEMP}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MV="${REAL_MV}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKDIR="${REAL_MKDIR}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_RM="${REAL_RM}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_RMDIR="${REAL_RMDIR}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_FAULT_MARKER="${fault_marker}"
    HOME="${runtime}/home"
    NODE_HOME="${runtime}/home"
    TMP_DIR="${runtime}/tmp"
    WALLET_FOLDER="${wallet_root}"
    POOL_FOLDER="${runtime}/pool"
    ASSET_FOLDER="${runtime}/asset"
    BLOCKLOG_DB="${runtime}/absent.db"
    ADVANCED_MODE=true
    CNTOOLS_MODE=LOCAL
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=10.1.0
    NETWORK_NAME=Preview
    CURRENCY=off
    CCLI=cardano-cli
    NETWORK_IDENTIFIER='--testnet-magic 2'
    NWMAGIC=2
    WALLET_MULTISIG_PREFIX=multisig-
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_PAY_SCRIPT_FILENAME=payment.script
    WALLET_STAKE_SCRIPT_FILENAME=stake.script
    WALLET_BASE_ADDR_FILENAME=base.addr
    WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_STAKE_ADDR_FILENAME=reward.addr
    WALLET_PAY_SCRIPT_CRED_FILENAME=payment-script.cred
    WALLET_STAKE_SCRIPT_CRED_FILENAME=stake-script.cred
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${events}"
    VECTOR_LOG="${vectors}"
    NETWORK_LOG="${network}"
    OUTSIDE_ROOT="${outside}"
    SCENARIO=bound-public-cancel
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
    CHOICES=("${CASE_CHOICES[@]}")
    CHOICE_CURSOR=0
    getAnswerAnyCust() {
      printf 'action:prompt:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
      [[ "${1:-}" == multisig_create_name ]] || return 70
      return 1
    }
    main
    exit 99
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == 0 ]] ||
    fail "bound public create traversal returned ${status}"
  extract_between_markers "${stdout_file}" "${action_stdout}" \
    '__CNTOOLS_MULTISIG_CREATE_BEGIN__' '__CNTOOLS_MULTISIG_CREATE_END__'
  grep -Fq ' >> ADVANCED >> MULTISIG >> CREATE WALLET' "${action_stdout}" ||
    fail 'bound public create action header changed'
  [[ "$(grep -Fc 'action:compatibility-dispatch:advanced.multisig.create' \
        "${events}" || true)" == 1 &&
     "$(grep -Fc 'action:prompt:multisig_create_name' "${events}" || true)" == 1 &&
     "$(grep -c '^action:waitToProceed$' "${events}" || true)" == 0 &&
     "$(grep -c '^menu:main:a$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:advanced:s$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:multisig:c$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:multisig:h$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:main:q$' "${events}" || true)" == 1 ]] ||
    fail 'bound public create dispatch, wait, or navigation parity changed'
  [[ "$(< "${vectors}")" == $'cardano-cli\t--version' ]] ||
    fail 'bound public create version-gate vector changed'
  [[ ! -s "${stderr_file}" && ! -s "${network}" ]] ||
    fail 'bound public create emitted stderr or attempted network access'
  tree_snapshot "${wallet_root}" "${after}"
  assert_files_equal "${after}" "${before}" \
    'bound public create persistent wallet tree'
  [[ -z "$(find "${runtime}/tmp" -mindepth 1 -print -quit)" ]] ||
    fail 'bound public create retained private bridge state'
)

run_bound_public_case

direct_set_choices() {
  case "$1" in
    direct-cancel) DIRECT_SELECTS=(3) ;;
    direct-empty) DIRECT_SELECTS=(2) ;;
    direct-nonhex) DIRECT_SELECTS=(1 3) ;;
    direct-duplicate) DIRECT_SELECTS=(1 1 1 3) ;;
    direct-two-signers) DIRECT_SELECTS=(1 1 1 0 0) ;;
    direct-wallet-signer|direct-wallet-vkey-symlink|direct-wallet-vkey-hardlink)
      DIRECT_SELECTS=(0 0 0)
      ;;
    direct-timelock|direct-invalid-epoch|direct-malformed-slot)
      DIRECT_SELECTS=(1 0 1)
      ;;
    direct-invalid-threshold) DIRECT_SELECTS=(1 0) ;;
    *) DIRECT_SELECTS=(1 0 0) ;;
  esac
}

select_opt() {
  local selected="${DIRECT_SELECTS[DIRECT_SELECT_INDEX]:-}"
  [[ -n "${selected}" ]] || fail "${DIRECT_SCENARIO} exhausted direct choices"
  DIRECT_SELECT_INDEX=$((DIRECT_SELECT_INDEX + 1))
  printf 'direct:select:%s\n' "${selected}" >> "${EVENT_LOG:?}"
  return "${selected}"
}

getAnswerAnyCust() {
  local output_variable="${1:?}" value=""
  printf 'direct:prompt:%s\n' "${output_variable}" >> "${EVENT_LOG:?}"
  case "${output_variable}" in
    multisig_create_name)
      [[ "${DIRECT_SCENARIO}" == direct-invalid-name ]] && value='../escape' || value=alpha
      ;;
    multisig_create_candidate_pay)
      DIRECT_PAY_COUNT=$((DIRECT_PAY_COUNT + 1))
      case "${DIRECT_SCENARIO}" in
        direct-nonhex) value="${NONHEX_PAY}" ;;
        direct-two-signers) (( DIRECT_PAY_COUNT == 1 )) && value="${PAY_A}" || value="${PAY_B}" ;;
        *) value="${PAY_A}" ;;
      esac
      ;;
    multisig_create_candidate_stake)
      DIRECT_STAKE_COUNT=$((DIRECT_STAKE_COUNT + 1))
      case "${DIRECT_SCENARIO}" in
        direct-two-signers) (( DIRECT_STAKE_COUNT == 1 )) && value="${STAKE_A}" || value="${STAKE_B}" ;;
        direct-duplicate) (( DIRECT_STAKE_COUNT == 1 )) && value="${STAKE_A}" || value="${STAKE_C}" ;;
        *) value="${STAKE_A}" ;;
      esac
      ;;
    multisig_create_required)
      case "${DIRECT_SCENARIO}" in
        direct-invalid-threshold) value=0 ;;
        direct-two-signers) value=2 ;;
        *) value=1 ;;
      esac
      ;;
    epoch_no)
      [[ "${DIRECT_SCENARIO}" == direct-invalid-epoch ]] && value=bad || value=123
      ;;
    *) fail "unexpected direct prompt variable: ${output_variable}" ;;
  esac
  printf -v "${output_variable}" '%s' "${value}"
}

selectWallet() {
  printf 'direct:selectWallet\n' >> "${EVENT_LOG:?}"
  wallet_name=signer
  return 0
}

getEpochStart() {
  printf 'direct:getEpochStart:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  [[ "${DIRECT_SCENARIO}" == direct-malformed-slot ]] &&
    printf 'bad-slot\n' || printf '424242\n'
}

direct_expected_status() {
  case "$1" in
    direct-root-mode|direct-root-symlink|direct-ccli-function-shadow|\
      direct-network-mismatch|direct-filename-collision|direct-json-schema|\
      direct-bad-address|direct-wrong-network|direct-bad-credential|\
      direct-malformed-slot|direct-wallet-vkey-symlink|\
      direct-wallet-vkey-hardlink|direct-symlink-output|\
      direct-hardlink-output|direct-fifo-output|direct-signal-lock|\
      direct-signal-derive|\
      direct-publish-collision|direct-rm-persistent|\
      direct-rmdir-persistent|direct-cli-base-rm-persistent|\
      direct-cli-payment-private-persistent|\
      direct-cli-reward-lock-persistent|direct-mktemp-private-symlink|\
      direct-mktemp-private-hardlink|direct-mktemp-private-fifo|\
      direct-mktemp-private-outside-special|\
      direct-mktemp-stage-outside-directory|\
      direct-mktemp-stage-ancestor-symlink|\
      direct-mktemp-stage-outside-symlink|direct-mktemp-stage-prepop-*)
      printf '70\n'
      ;;
    *) printf '0\n' ;;
  esac
}

direct_expected_waits() {
  case "$1" in
    direct-cancel|direct-root-mode|direct-root-symlink|\
      direct-ccli-function-shadow|direct-network-mismatch|\
      direct-filename-collision|direct-json-schema|direct-bad-address|\
      direct-wrong-network|direct-bad-credential|direct-malformed-slot|\
      direct-wallet-vkey-symlink|direct-wallet-vkey-hardlink|\
      direct-symlink-output|direct-hardlink-output|direct-fifo-output|\
      direct-signal-lock|\
      direct-signal-derive|direct-signal-publish|direct-signal-after-check|\
      direct-publish-collision|direct-rm-persistent|\
      direct-rmdir-persistent|direct-cli-base-rm-persistent|\
      direct-cli-payment-private-persistent|\
      direct-cli-reward-lock-persistent|direct-mktemp-private-symlink|\
      direct-mktemp-private-hardlink|direct-mktemp-private-fifo|\
      direct-mktemp-private-outside-special|\
      direct-mktemp-stage-outside-directory|\
      direct-mktemp-stage-ancestor-symlink|\
      direct-mktemp-stage-outside-symlink|direct-mktemp-stage-prepop-*)
      printf '0\n'
      ;;
    *) printf '1\n' ;;
  esac
}

prepare_direct_case() {
  local scenario="$1" wallet_root="$2" outside="$3"
  local signer="${wallet_root}/signer"
  local stage="${wallet_root}/.alpha.cntools-multisig-create.stage.ABCDEFGH"

  chmod 0755 "${wallet_root}"
  case "${scenario}" in
    direct-root-mode) chmod 0777 "${wallet_root}" ;;
    direct-root-symlink)
      mkdir -p -- "${outside}/wallet-real"
      chmod 0755 "${outside}/wallet-real"
      rmdir -- "${wallet_root}"
      ln -s -- "${outside}/wallet-real" "${wallet_root}"
      ;;
    direct-existing)
      mkdir -m 0700 -- "${wallet_root}/alpha"
      printf 'sentinel\n' > "${wallet_root}/alpha/existing"
      chmod 0600 "${wallet_root}/alpha/existing"
      ;;
    direct-lock-contention)
      mkdir -m 0700 -- "${wallet_root}/.alpha.cntools-multisig-create.lock"
      ;;
    direct-symlink-output)
      printf 'symlink outside sentinel\n' > "${outside}/escaped.addr"
      chmod 0640 "${outside}/escaped.addr"
      ;;
    direct-hardlink-output)
      printf 'hardlink outside sentinel\n' > "${outside}/escaped.addr"
      chmod 0440 "${outside}/escaped.addr"
      ;;
    direct-fifo-output)
      printf 'fifo outside sentinel\n' > "${outside}/escaped.addr"
      chmod 0640 "${outside}/escaped.addr"
      ;;
    direct-mktemp-private-symlink)
      printf 'private symlink sentinel\n' > "${outside}/private-symlink-sentinel"
      chmod 0640 "${outside}/private-symlink-sentinel"
      ;;
    direct-mktemp-private-hardlink)
      printf 'private hardlink sentinel\n' > "${outside}/private-hardlink-sentinel"
      chmod 0440 "${outside}/private-hardlink-sentinel"
      ;;
    direct-mktemp-private-fifo)
      printf 'private fifo outside sentinel\n' > "${outside}/private-fifo-sentinel"
      chmod 0640 "${outside}/private-fifo-sentinel"
      ;;
    direct-mktemp-private-outside-special)
      mkdir -m 0750 -- "${outside}/private-special"
      printf 'private special sentinel\n' > "${outside}/private-special/sentinel"
      chmod 0440 "${outside}/private-special/sentinel"
      ;;
    direct-mktemp-stage-outside-directory)
      mkdir -m 0750 -- "${outside}/stage-outside"
      printf 'stage outside sentinel\n' > "${outside}/stage-outside/sentinel"
      chmod 0440 "${outside}/stage-outside/sentinel"
      ;;
    direct-mktemp-stage-ancestor-symlink)
      mkdir -p -- "${outside}/stage-ancestor-target/.alpha.cntools-multisig-create.stage.ABCDEFGH"
      chmod 0750 "${outside}/stage-ancestor-target/.alpha.cntools-multisig-create.stage.ABCDEFGH"
      printf 'stage ancestor sentinel\n' > \
        "${outside}/stage-ancestor-target/.alpha.cntools-multisig-create.stage.ABCDEFGH/sentinel"
      chmod 0440 \
        "${outside}/stage-ancestor-target/.alpha.cntools-multisig-create.stage.ABCDEFGH/sentinel"
      ln -s -- "${outside}/stage-ancestor-target" \
        "${wallet_root}/stage-ancestor-link"
      ;;
    direct-mktemp-stage-outside-symlink)
      mkdir -m 0750 -- "${outside}/stage-symlink-target"
      printf 'stage symlink sentinel\n' > "${outside}/stage-symlink-target/sentinel"
      chmod 0440 "${outside}/stage-symlink-target/sentinel"
      ln -s -- "${outside}/stage-symlink-target" \
        "${wallet_root}/.alpha.cntools-multisig-create.stage.ABCDEFGH"
      ;;
    direct-mktemp-stage-prepop-symlink)
      mkdir -m 0700 -- "${stage}"
      printf 'prepop stage symlink sentinel\n' > \
        "${outside}/stage-prepop-symlink-sentinel"
      chmod 0640 "${outside}/stage-prepop-symlink-sentinel"
      ln -s -- "${outside}/stage-prepop-symlink-sentinel" \
        "${stage}/payment.script"
      ;;
    direct-mktemp-stage-prepop-hardlink)
      mkdir -m 0700 -- "${stage}"
      printf 'prepop stage hardlink sentinel\n' > \
        "${outside}/stage-prepop-hardlink-sentinel"
      chmod 0440 "${outside}/stage-prepop-hardlink-sentinel"
      ln -- "${outside}/stage-prepop-hardlink-sentinel" \
        "${stage}/stake.script"
      ;;
    direct-mktemp-stage-prepop-fifo)
      mkdir -m 0700 -- "${stage}"
      printf 'prepop stage fifo outside sentinel\n' > \
        "${outside}/stage-prepop-fifo-sentinel"
      chmod 0640 "${outside}/stage-prepop-fifo-sentinel"
      mkfifo -- "${stage}/payment.script"
      chmod 0640 "${stage}/payment.script"
      ;;
    direct-mktemp-stage-prepop-special)
      mkdir -m 0700 -- "${stage}"
      printf 'prepop stage special outside sentinel\n' > \
        "${outside}/stage-prepop-special-sentinel"
      chmod 0440 "${outside}/stage-prepop-special-sentinel"
      mkdir -m 0750 -- "${stage}/stake.script"
      printf 'prepop stage special inner sentinel\n' > \
        "${stage}/stake.script/sentinel"
      chmod 0440 "${stage}/stake.script/sentinel"
      ;;
    direct-mktemp-stage-prepop-unexpected)
      mkdir -m 0700 -- "${stage}"
      printf 'prepop stage unexpected outside sentinel\n' > \
        "${outside}/stage-prepop-unexpected-sentinel"
      chmod 0640 "${outside}/stage-prepop-unexpected-sentinel"
      printf 'prepop unexpected leaf\n' > "${stage}/unexpected.leaf"
      chmod 0640 "${stage}/unexpected.leaf"
      ;;
    direct-wallet-signer|direct-wallet-vkey-symlink|direct-wallet-vkey-hardlink)
      mkdir -m 0700 -- "${signer}"
      printf '{"cborHex":"5820aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","description":"MultiSig Payment Verification Key","type":"PaymentVerificationKeyShelley_ed25519"}\n' > "${signer}/multisig-payment.vkey"
      printf '{"cborHex":"5820bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","description":"MultiSig Stake Verification Key","type":"StakeVerificationKeyShelley_ed25519"}\n' > "${signer}/multisig-stake.vkey"
      chmod 0600 "${signer}/"*.vkey
      if [[ "${scenario}" == direct-wallet-vkey-symlink ]]; then
        mv -- "${signer}/multisig-payment.vkey" "${outside}/payment.vkey"
        ln -s -- "${outside}/payment.vkey" "${signer}/multisig-payment.vkey"
      elif [[ "${scenario}" == direct-wallet-vkey-hardlink ]]; then
        ln -- "${signer}/multisig-payment.vkey" "${outside}/payment.vkey"
      fi
      ;;
  esac
}

write_direct_context() {
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
      nodeNetwork: "preview",
      schemaVersion: 1
    }
  ' > "${target}"
  chmod 0400 "${target}"
}

assert_direct_success() {
  local scenario="$1" destination="$2" leaf="" expected_pay_count=1

  [[ -d "${destination}" && ! -L "${destination}" &&
     "$(file_mode "${destination}")" == 700 ]] ||
    fail "${scenario} destination authority changed"
  [[ "$(find "${destination}" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" == 7 ]] ||
    fail "${scenario} exact inventory changed"
  for leaf in payment.script stake.script base.addr payment.addr reward.addr \
      payment-script.cred stake-script.cred; do
    [[ -f "${destination}/${leaf}" && ! -L "${destination}/${leaf}" &&
       "$(file_mode "${destination}/${leaf}")" == 600 ]] ||
      fail "${scenario} unsafe ${leaf}"
  done
  [[ "$(< "${destination}/base.addr")" != "$(< "${destination}/payment.addr")" ]] ||
    fail "${scenario} address roles collapsed"
  [[ "${scenario}" != direct-two-signers ]] || expected_pay_count=2
  if [[ "${scenario}" == direct-timelock ]]; then
    "${REAL_JQ}" -e --arg pay "${PAY_A}" '
      .type == "all" and .scripts[0] == {slot:424242,type:"after"} and
      .scripts[1].type == "atLeast" and .scripts[1].required == 1 and
      .scripts[1].scripts == [{keyHash:$pay,type:"sig"}]
    ' "${destination}/payment.script" >/dev/null ||
      fail 'corrected timelock schema/order changed'
  else
    "${REAL_JQ}" -e --argjson count "${expected_pay_count}" '
      .type == "atLeast" and .required == $count and
      (.scripts | length) == $count
    ' "${destination}/payment.script" >/dev/null ||
      fail "${scenario} payment schema changed"
  fi
  if [[ "${scenario}" == direct-two-signers ]]; then
    "${REAL_JQ}" -e --arg pay_a "${PAY_A}" --arg pay_b "${PAY_B}" \
      --arg stake_a "${STAKE_A}" --arg stake_b "${STAKE_B}" '
      .scripts == [{keyHash:$pay_a,type:"sig"},{keyHash:$pay_b,type:"sig"}]
    ' "${destination}/payment.script" >/dev/null ||
      fail 'ordered payment signer records changed'
    "${REAL_JQ}" -e --arg stake_a "${STAKE_A}" --arg stake_b "${STAKE_B}" '
      .scripts == [{keyHash:$stake_a,type:"sig"},{keyHash:$stake_b,type:"sig"}]
    ' "${destination}/stake.script" >/dev/null ||
      fail 'ordered stake signer records changed'
  fi
}

run_direct_case() {
  local scenario="$1" mode="$2" case_root="${TEST_ROOT}/direct-cases/$1"
  local runtime="" wallet_root="" outside="" private="" capture=""
  local context="" result="" stdout_file="" stderr_file="" events=""
  local vectors="" network="" before="" after=""
  local fault_marker="" outside_identity_before=""
  local oracle_object="" oracle_kind="" oracle_identity="" oracle_mode=""
  local oracle_content="" oracle_sentinel="" oracle_sentinel_identity=""
  local oracle_sentinel_mode="" oracle_sentinel_content=""
  local prepop_stage="" prepop_stage_identity="" prepop_stage_mode=""
  local prepop_leaf="" prepop_kind="" prepop_identity="" prepop_mode=""
  local prepop_content="" prepop_link="" prepop_sentinel=""
  local prepop_sentinel_identity="" prepop_sentinel_mode=""
  local prepop_sentinel_content=""
  local expected_status="" expected_waits="" status=0 waits=0
  local stage_count=0 lock_count=0 private_count=0 target="" ccli=cardano-cli
  local -a DIRECT_SELECTS=()

  runtime="${case_root}/runtime"
  wallet_root="${runtime}/wallet"
  outside="${runtime}/outside"
  private="${runtime}/private"
  capture="${case_root}/capture"
  context="${private}/context.json"
  result="${private}/result.json"
  stdout_file="${capture}/stdout"
  stderr_file="${capture}/stderr"
  events="${capture}/events"
  vectors="${capture}/vectors"
  network="${capture}/network"
  before="${capture}/before.wallet"
  after="${capture}/after.wallet"
  fault_marker="${capture}/cleanup-fault.marker"

  mkdir -p -- "${wallet_root}" "${outside}" "${private}" "${capture}" \
    "${runtime}/home"
  chmod 0700 "${private}"
  prepare_direct_case "${scenario}" "${wallet_root}" "${outside}"
  case "${scenario}" in
    direct-mktemp-private-symlink)
      oracle_object="${outside}/private-symlink-sentinel"; oracle_kind="file" ;;
    direct-mktemp-private-hardlink)
      oracle_object="${outside}/private-hardlink-sentinel"; oracle_kind="file" ;;
    direct-mktemp-private-fifo)
      oracle_object="${outside}/private-fifo-sentinel"; oracle_kind="file" ;;
    direct-mktemp-private-outside-special)
      oracle_object="${outside}/private-special"; oracle_kind="directory" ;;
    direct-mktemp-stage-outside-directory)
      oracle_object="${outside}/stage-outside"; oracle_kind="directory" ;;
    direct-mktemp-stage-ancestor-symlink)
      oracle_object="${outside}/stage-ancestor-target/.alpha.cntools-multisig-create.stage.ABCDEFGH"
      oracle_kind="directory"
      ;;
    direct-mktemp-stage-outside-symlink)
      oracle_object="${outside}/stage-symlink-target"; oracle_kind="directory" ;;
    direct-mktemp-stage-prepop-symlink)
      oracle_object="${outside}/stage-prepop-symlink-sentinel"
      oracle_kind="file"
      ;;
    direct-mktemp-stage-prepop-hardlink)
      oracle_object="${outside}/stage-prepop-hardlink-sentinel"
      oracle_kind="file"
      ;;
    direct-mktemp-stage-prepop-fifo)
      oracle_object="${outside}/stage-prepop-fifo-sentinel"
      oracle_kind="file"
      ;;
    direct-mktemp-stage-prepop-special)
      oracle_object="${outside}/stage-prepop-special-sentinel"
      oracle_kind="file"
      ;;
    direct-mktemp-stage-prepop-unexpected)
      oracle_object="${outside}/stage-prepop-unexpected-sentinel"
      oracle_kind="file"
      ;;
  esac
  if [[ -n "${oracle_object}" ]]; then
    oracle_identity="$(file_identity "${oracle_object}")"
    oracle_mode="$(file_mode "${oracle_object}")"
    if [[ "${oracle_kind}" == file ]]; then
      oracle_content="$(< "${oracle_object}")"
    else
      oracle_sentinel="${oracle_object}/sentinel"
      oracle_sentinel_identity="$(file_identity "${oracle_sentinel}")"
      oracle_sentinel_mode="$(file_mode "${oracle_sentinel}")"
      oracle_sentinel_content="$(< "${oracle_sentinel}")"
    fi
  fi
  case "${scenario}" in
    direct-mktemp-stage-prepop-symlink)
      prepop_leaf="payment.script"; prepop_kind="symlink" ;;
    direct-mktemp-stage-prepop-hardlink)
      prepop_leaf="stake.script"; prepop_kind="file" ;;
    direct-mktemp-stage-prepop-fifo)
      prepop_leaf="payment.script"; prepop_kind="fifo" ;;
    direct-mktemp-stage-prepop-special)
      prepop_leaf="stake.script"; prepop_kind="directory" ;;
    direct-mktemp-stage-prepop-unexpected)
      prepop_leaf="unexpected.leaf"; prepop_kind="file" ;;
  esac
  if [[ -n "${prepop_leaf}" ]]; then
    prepop_stage="${wallet_root}/.alpha.cntools-multisig-create.stage.ABCDEFGH"
    prepop_stage_identity="$(file_identity "${prepop_stage}")"
    prepop_stage_mode="$(file_mode "${prepop_stage}")"
    if [[ "${prepop_kind}" == symlink ]]; then
      prepop_link="$(readlink "${prepop_stage}/${prepop_leaf}")"
    else
      prepop_identity="$(file_identity "${prepop_stage}/${prepop_leaf}")"
      prepop_mode="$(file_mode "${prepop_stage}/${prepop_leaf}")"
      if [[ "${prepop_kind}" == file ]]; then
        prepop_content="$(< "${prepop_stage}/${prepop_leaf}")"
      elif [[ "${prepop_kind}" == directory ]]; then
        prepop_sentinel="${prepop_stage}/${prepop_leaf}/sentinel"
        prepop_sentinel_identity="$(file_identity "${prepop_sentinel}")"
        prepop_sentinel_mode="$(file_mode "${prepop_sentinel}")"
        prepop_sentinel_content="$(< "${prepop_sentinel}")"
      fi
    fi
  fi
  if [[ -e "${outside}/escaped.addr" ]]; then
    outside_identity_before="$(file_identity "${outside}/escaped.addr")"
  fi
  write_direct_context "${context}" "${mode}" "${runtime}/home"
  : > "${events}"
  : > "${vectors}"
  : > "${network}"
  tree_snapshot "${wallet_root}" "${before}"
  direct_set_choices "${scenario}"
  expected_status="$(direct_expected_status "${scenario}")"
  expected_waits="$(direct_expected_waits "${scenario}")"
  [[ "${scenario}" != direct-absolute-ccli ]] || ccli="${DIRECT_FAKE_BIN}/cardano-cli"
  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC PATH="${DIRECT_FAKE_BIN}:${BASE_PATH}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_SCENARIO="${scenario}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_VECTORS="${vectors}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_NETWORK="${network}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_ROOT="${wallet_root}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_OUTSIDE="${outside}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_PRIVATE="${private}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_JQ="${REAL_JQ}"
    CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_LN="${REAL_LN}"
    CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_CHMOD="${REAL_CHMOD}"
    CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKFIFO="${REAL_MKFIFO}"
    CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKTEMP="${REAL_MKTEMP}"
    CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MV="${REAL_MV}"
    CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKDIR="${REAL_MKDIR}"
    CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_RM="${REAL_RM}"
    CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_RMDIR="${REAL_RMDIR}"
    CNTOOLS_MULTISIG_CREATE_DIRECT_FAULT_MARKER="${fault_marker}"
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_LN
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_CHMOD
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKFIFO
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKTEMP
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MV
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_MKDIR
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_RM
    export CNTOOLS_MULTISIG_CREATE_DIRECT_REAL_RMDIR
    export CNTOOLS_MULTISIG_CREATE_DIRECT_FAULT_MARKER
    [[ "${scenario}" != direct-ccli-function-shadow ]] || cardano-cli() { return 0; }
    HOME="${runtime}/home"
    NODE_HOME="${runtime}/home"
    WALLET_FOLDER="${wallet_root}"
    CNTOOLS_MODE="${mode}"
    CCLI="${ccli}"
    NETWORK_IDENTIFIER='--testnet-magic 2'
    NWMAGIC=2
    [[ "${scenario}" != direct-network-mismatch ]] || {
      NETWORK_IDENTIFIER=--mainnet
      NWMAGIC=764824073
    }
    WALLET_MULTISIG_PREFIX=multisig-
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_PAY_SCRIPT_FILENAME=payment.script
    WALLET_STAKE_SCRIPT_FILENAME=stake.script
    WALLET_BASE_ADDR_FILENAME=base.addr
    WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_STAKE_ADDR_FILENAME=reward.addr
    WALLET_PAY_SCRIPT_CRED_FILENAME=payment-script.cred
    WALLET_STAKE_SCRIPT_CRED_FILENAME=stake-script.cred
    [[ "${scenario}" != direct-filename-collision ]] ||
      WALLET_STAKE_SCRIPT_FILENAME=payment.script
    FG_RED="" FG_GREEN="" FG_YELLOW="" FG_LGRAY="" NC=""
    EVENT_LOG="${events}"
    SCENARIO="${scenario}"
    DIRECT_SCENARIO="${scenario}"
    DIRECT_SELECTS=("${DIRECT_SELECTS[@]}")
    DIRECT_SELECT_INDEX=0
    DIRECT_PAY_COUNT=0
    DIRECT_STAKE_COUNT=0
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
    DIRECT_SIGNAL_WAIT_SENT=N
    unset wallet_name epoch_no
    if [[ "${scenario}" == direct-signal-after-check ]]; then
      set -T
      DIRECT_AFTER_CHECK_ARMED=Y
      trap 'if [[ "${DIRECT_AFTER_CHECK_ARMED:-N}" == Y && "${BASH_COMMAND:-}" == multisig_create_committed=Y ]]; then DIRECT_AFTER_CHECK_ARMED=N; builtin printf '\''direct:signal-after-check\n'\'' >> "${EVENT_LOG:?}"; kill -TERM "${BASHPID}"; fi' DEBUG
    fi
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" "${context}" "${result}"
    direct_status=$?
    [[ ! -e "${result}" && ! -L "${result}" ]] || exit 98
    exit "${direct_status}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} returned ${status}, expected ${expected_status}"
  case "${scenario}" in
    direct-cli-payment-credential-rm-retry|\
      direct-cli-stake-credential-private-retry|\
      direct-cli-stake-credential-lock-retry)
      [[ -f "${fault_marker}" && ! -L "${fault_marker}" &&
         "$(< "${fault_marker}")" == retry ]] ||
        fail "${scenario} cleanup retry oracle did not fire"
      ;;
  esac
  waits="$(grep -c '^action:waitToProceed$' "${events}" || true)"
  [[ "${waits}" == "${expected_waits}" ]] ||
    fail "${scenario} waits ${waits}, expected ${expected_waits}"
  [[ ! -s "${network}" ]] || fail "${scenario} attempted network access"
  ! grep -Fq 'RAW TOOL ERROR' "${stdout_file}" "${stderr_file}" ||
    fail "${scenario} reflected raw tool output"
  ! LC_ALL=C grep -q $'\033' "${stdout_file}" "${stderr_file}" ||
    fail "${scenario} emitted terminal control bytes"
  if [[ "${expected_status}" == 70 ]]; then
    [[ "$(grep -Fxc 'CNTools MultiSig wallet creation action failed validation.' \
          "${stderr_file}" || true)" == 1 &&
       "$(wc -l < "${stderr_file}" | tr -d '[:space:]')" == 1 ]] ||
      fail "${scenario} fixed bounded invariant diagnostic changed"
  elif [[ "${scenario}" == direct-postcommit-lock-release ||
          "${scenario}" == direct-signal-publish ||
          "${scenario}" == direct-signal-after-check ||
          "${scenario}" == direct-signal-wait ||
          "${scenario}" == direct-private-rm-persistent ]]; then
    grep -Fxq 'WARNING: MultiSig wallet was created, but administrative cleanup needs attention.' \
      "${stderr_file}" || fail "${scenario} postcommit warning changed"
  else
    [[ ! -s "${stderr_file}" ]] || fail "${scenario} unexpected stderr"
  fi
  case "${scenario}" in
    direct-symlink-output)
      [[ "$(file_identity "${outside}/escaped.addr")" == "${outside_identity_before}" &&
         "$(file_mode "${outside}/escaped.addr")" == 640 &&
         "$(< "${outside}/escaped.addr")" == 'symlink outside sentinel' ]] ||
        fail 'symlink output mutated outside sentinel'
      ;;
    direct-hardlink-output)
      [[ "$(file_identity "${outside}/escaped.addr")" == "${outside_identity_before}" &&
         "$(file_mode "${outside}/escaped.addr")" == 440 &&
         "$(< "${outside}/escaped.addr")" == 'hardlink outside sentinel' ]] ||
        fail 'hardlink output mutated outside sentinel'
      ;;
    direct-fifo-output)
      [[ "$(file_identity "${outside}/escaped.addr")" == "${outside_identity_before}" &&
         "$(file_mode "${outside}/escaped.addr")" == 640 &&
         "$(< "${outside}/escaped.addr")" == 'fifo outside sentinel' ]] ||
        fail 'special output mutated outside sentinel'
      ;;
  esac
  if [[ -n "${oracle_object}" ]]; then
    [[ "$(file_identity "${oracle_object}")" == "${oracle_identity}" &&
       "$(file_mode "${oracle_object}")" == "${oracle_mode}" ]] ||
      fail "${scenario} mutated outside mktemp object authority"
    if [[ "${oracle_kind}" == file ]]; then
      [[ -f "${oracle_object}" && ! -L "${oracle_object}" &&
         "$(< "${oracle_object}")" == "${oracle_content}" ]] ||
        fail "${scenario} mutated outside mktemp file"
    else
      [[ -d "${oracle_object}" && ! -L "${oracle_object}" &&
         "$(file_identity "${oracle_sentinel}")" == "${oracle_sentinel_identity}" &&
         "$(file_mode "${oracle_sentinel}")" == "${oracle_sentinel_mode}" &&
         "$(< "${oracle_sentinel}")" == "${oracle_sentinel_content}" ]] ||
      fail "${scenario} mutated outside mktemp directory"
    fi
  fi
  if [[ -n "${prepop_stage}" ]]; then
    [[ -d "${prepop_stage}" && ! -L "${prepop_stage}" &&
       "$(file_identity "${prepop_stage}")" == "${prepop_stage_identity}" &&
       "$(file_mode "${prepop_stage}")" == "${prepop_stage_mode}" &&
       "$(find "${prepop_stage}" -mindepth 1 -maxdepth 1 -print | \
           wc -l | tr -d '[:space:]')" == 1 ]] ||
      fail "${scenario} mutated prepopulated stage authority or inventory"
    case "${prepop_kind}" in
      symlink)
        [[ -L "${prepop_stage}/${prepop_leaf}" &&
           "$(readlink "${prepop_stage}/${prepop_leaf}")" == "${prepop_link}" ]] ||
          fail "${scenario} deleted or transformed prepopulated symlink"
        ;;
      file)
        [[ -f "${prepop_stage}/${prepop_leaf}" &&
           ! -L "${prepop_stage}/${prepop_leaf}" &&
           "$(file_identity "${prepop_stage}/${prepop_leaf}")" == "${prepop_identity}" &&
           "$(file_mode "${prepop_stage}/${prepop_leaf}")" == "${prepop_mode}" &&
           "$(< "${prepop_stage}/${prepop_leaf}")" == "${prepop_content}" ]] ||
          fail "${scenario} deleted or transformed prepopulated file"
        ;;
      fifo)
        [[ -p "${prepop_stage}/${prepop_leaf}" &&
           "$(file_identity "${prepop_stage}/${prepop_leaf}")" == "${prepop_identity}" &&
           "$(file_mode "${prepop_stage}/${prepop_leaf}")" == "${prepop_mode}" ]] ||
          fail "${scenario} deleted or transformed prepopulated FIFO"
        ;;
      directory)
        [[ -d "${prepop_stage}/${prepop_leaf}" &&
           ! -L "${prepop_stage}/${prepop_leaf}" &&
           "$(file_identity "${prepop_stage}/${prepop_leaf}")" == "${prepop_identity}" &&
           "$(file_mode "${prepop_stage}/${prepop_leaf}")" == "${prepop_mode}" &&
           "$(file_identity "${prepop_sentinel}")" == "${prepop_sentinel_identity}" &&
           "$(file_mode "${prepop_sentinel}")" == "${prepop_sentinel_mode}" &&
           "$(< "${prepop_sentinel}")" == "${prepop_sentinel_content}" ]] ||
          fail "${scenario} deleted or transformed prepopulated special leaf"
        ;;
      *) fail "${scenario} has no prepopulated object oracle" ;;
    esac
  fi
  case "${scenario}" in
    direct-mktemp-private-symlink)
      [[ -L "${private}/multisig-create-version.ABCDEFGH" ]] ||
        fail 'private mktemp symlink was deleted or transformed'
      ;;
    direct-mktemp-private-hardlink)
      [[ -f "${private}/multisig-create-version.ABCDEFGH" &&
         ! -L "${private}/multisig-create-version.ABCDEFGH" &&
         "$(file_identity "${private}/multisig-create-version.ABCDEFGH")" == "${oracle_identity}" ]] ||
        fail 'private mktemp hardlink was deleted or transformed'
      ;;
    direct-mktemp-private-fifo)
      [[ -p "${private}/multisig-create-version.ABCDEFGH" &&
         "$(file_mode "${private}/multisig-create-version.ABCDEFGH")" == 640 ]] ||
        fail 'private mktemp special file was deleted or transformed'
      ;;
    direct-mktemp-stage-ancestor-symlink)
      [[ -L "${wallet_root}/stage-ancestor-link" ]] ||
        fail 'mktemp stage ancestor symlink was deleted or transformed'
      ;;
  esac
  tree_snapshot "${wallet_root}" "${after}"
  case "${scenario}" in
    direct-success-*|direct-absolute-ccli|direct-timelock|\
      direct-two-signers|direct-wallet-signer|direct-mv-created-nonzero|\
      direct-postcommit-lock-release|direct-signal-wait|\
      direct-lock-rmdir-created-nonzero|direct-lock-rmdir-retry|\
      direct-private-rm-created-nonzero|direct-private-rm-retry|\
      direct-private-rm-persistent)
      assert_direct_success "${scenario}" "${wallet_root}/alpha"
      grep -Fq 'New MultiSig Wallet : alpha' "${stdout_file}" ||
        fail "${scenario} success output changed"
      ;;
    direct-signal-publish|direct-signal-after-check)
      assert_direct_success "${scenario}" "${wallet_root}/alpha"
      ! grep -Fq 'New MultiSig Wallet : alpha' "${stdout_file}" ||
        fail "${scenario} continued after postcommit signal"
      [[ "${scenario}" != direct-signal-after-check ]] ||
        grep -Fxq 'direct:signal-after-check' "${events}" ||
        fail 'after-check signal oracle did not fire'
      ;;
    direct-symlink-output|direct-hardlink-output|direct-fifo-output|\
      direct-publish-collision|direct-cli-base-rm-persistent|\
      direct-cli-payment-private-persistent|\
      direct-cli-reward-lock-persistent|\
      direct-mktemp-stage-outside-directory|\
      direct-mktemp-stage-ancestor-symlink|\
      direct-mktemp-stage-outside-symlink|direct-mktemp-stage-prepop-*)
      :
      ;;
    direct-rm-persistent|direct-rmdir-persistent) : ;;
    *) assert_files_equal "${after}" "${before}" "${scenario} zero mutation" ;;
  esac
  stage_count="$(find -L "${wallet_root}" -mindepth 1 -maxdepth 1 -type d \
    -name '.*.cntools-multisig-create.stage.*' | wc -l | tr -d '[:space:]')"
  case "${scenario}" in
    direct-mktemp-stage-outside-symlink)
      [[ "${stage_count}" == 1 &&
         -L "${wallet_root}/.alpha.cntools-multisig-create.stage.ABCDEFGH" ]] ||
        fail 'mktemp outside stage symlink authority changed'
      ;;
    direct-mktemp-stage-prepop-*)
      [[ "${stage_count}" == 1 && -d "${prepop_stage}" &&
         ! -L "${prepop_stage}" &&
         "$(find "${wallet_root}" -mindepth 1 -maxdepth 1 -print | \
             wc -l | tr -d '[:space:]')" == 2 &&
         ! -e "${wallet_root}/alpha" && ! -L "${wallet_root}/alpha" ]] ||
        fail "${scenario} did not retain only exact stage and lock authority"
      ;;
    direct-symlink-output|direct-hardlink-output|direct-fifo-output|\
      direct-publish-collision|direct-rm-persistent|\
      direct-rmdir-persistent|direct-cli-base-rm-persistent)
      [[ "${stage_count}" == 1 ]] ||
        fail "${scenario} did not retain exact stage authority"
      target="$(find "${wallet_root}" -mindepth 1 -maxdepth 1 -type d \
        -name '.*.cntools-multisig-create.stage.*' -print -quit)"
      [[ -d "${target}" && ! -L "${target}" &&
         "$(file_mode "${target}")" == 700 ]] ||
        fail "${scenario} retained stage type changed"
      if [[ "${scenario}" == direct-fifo-output ]]; then
        [[ -p "${target}/base.addr" &&
           "$(file_mode "${target}/base.addr")" == 640 ]] ||
          fail 'special output was transformed before authentication'
      fi
      ;;
    *) [[ "${stage_count}" == 0 ]] || fail "${scenario} left private stage" ;;
  esac
  lock_count="$(find -L "${wallet_root}" -mindepth 1 -maxdepth 1 -type d \
    -name '.*.cntools-multisig-create.lock' | wc -l | tr -d '[:space:]')"
  case "${scenario}" in
    direct-lock-contention|direct-postcommit-lock-release|\
      direct-symlink-output|direct-hardlink-output|direct-publish-collision|\
      direct-rm-persistent|direct-rmdir-persistent|\
      direct-private-rm-persistent|direct-fifo-output|\
      direct-cli-base-rm-persistent|\
      direct-cli-payment-private-persistent|\
      direct-cli-reward-lock-persistent|\
      direct-mktemp-stage-outside-directory|\
      direct-mktemp-stage-ancestor-symlink|\
      direct-mktemp-stage-outside-symlink|direct-mktemp-stage-prepop-*)
      [[ "${lock_count}" == 1 ]] ||
        fail "${scenario} did not retain exact lock authority"
      [[ -d "${wallet_root}/.alpha.cntools-multisig-create.lock" &&
         ! -L "${wallet_root}/.alpha.cntools-multisig-create.lock" &&
         "$(file_mode "${wallet_root}/.alpha.cntools-multisig-create.lock")" == 700 ]] ||
        fail "${scenario} retained lock authority changed"
      ;;
    *) [[ "${lock_count}" == 0 ]] || fail "${scenario} left operation lock" ;;
  esac
  if [[ "${scenario}" == direct-cli-payment-private-persistent ]]; then
    while IFS= read -r -d '' target; do
      [[ -f "${target}" && ! -L "${target}" &&
         "$(file_mode "${target}")" == 600 ]] ||
        fail 'persistent private cleanup retained unsafe authority'
      private_count=$((private_count + 1))
    done < <(find "${private}" -mindepth 1 -maxdepth 1 -type f \
      -name 'multisig-create-*' -print0)
    (( private_count > 0 )) ||
      fail 'persistent private cleanup did not retain retry authority'
  fi
  if [[ "${scenario}" == direct-mktemp-stage-prepop-* ]]; then
    [[ "$(find "${private}" -mindepth 1 -maxdepth 1 \
        -name 'multisig-create-*' -print | wc -l | tr -d '[:space:]')" == 0 ]] ||
      fail "${scenario} retained unaffiliated private scratch files"
  fi
}

run_direct_case direct-success-local LOCAL
run_direct_case direct-success-light LIGHT
run_direct_case direct-success-offline OFFLINE
run_direct_case direct-absolute-ccli OFFLINE
run_direct_case direct-timelock LOCAL
run_direct_case direct-two-signers LIGHT
run_direct_case direct-wallet-signer OFFLINE
run_direct_case direct-cancel LOCAL
run_direct_case direct-empty LIGHT
run_direct_case direct-existing OFFLINE
run_direct_case direct-invalid-name LOCAL
run_direct_case direct-nonhex LIGHT
run_direct_case direct-duplicate OFFLINE
run_direct_case direct-invalid-threshold LOCAL
run_direct_case direct-invalid-epoch LIGHT
run_direct_case direct-root-mode OFFLINE
run_direct_case direct-root-symlink LOCAL
run_direct_case direct-ccli-function-shadow LIGHT
run_direct_case direct-network-mismatch OFFLINE
run_direct_case direct-filename-collision LOCAL
run_direct_case direct-json-schema LIGHT
run_direct_case direct-cli-failure OFFLINE
run_direct_case direct-cli-base-rm-persistent LOCAL
run_direct_case direct-cli-payment-private-persistent LIGHT
run_direct_case direct-cli-reward-lock-persistent OFFLINE
run_direct_case direct-cli-payment-credential-rm-retry LOCAL
run_direct_case direct-cli-stake-credential-private-retry LIGHT
run_direct_case direct-cli-stake-credential-lock-retry OFFLINE
run_direct_case direct-bad-address LOCAL
run_direct_case direct-wrong-network LIGHT
run_direct_case direct-bad-credential OFFLINE
run_direct_case direct-malformed-slot LOCAL
run_direct_case direct-wallet-vkey-symlink LIGHT
run_direct_case direct-wallet-vkey-hardlink OFFLINE
run_direct_case direct-lock-contention LOCAL
run_direct_case direct-symlink-output LIGHT
run_direct_case direct-hardlink-output OFFLINE
run_direct_case direct-fifo-output LOCAL
run_direct_case direct-mv-created-nonzero LOCAL
run_direct_case direct-mv-failure LIGHT
run_direct_case direct-signal-lock OFFLINE
run_direct_case direct-signal-derive LOCAL
run_direct_case direct-signal-publish LIGHT
run_direct_case direct-signal-after-check OFFLINE
run_direct_case direct-signal-wait LOCAL
run_direct_case direct-publish-collision OFFLINE
run_direct_case direct-rm-created-nonzero LOCAL
run_direct_case direct-rm-retry LIGHT
run_direct_case direct-rm-persistent OFFLINE
run_direct_case direct-rmdir-created-nonzero LOCAL
run_direct_case direct-rmdir-retry LIGHT
run_direct_case direct-rmdir-persistent OFFLINE
run_direct_case direct-lock-rmdir-created-nonzero LOCAL
run_direct_case direct-lock-rmdir-retry LIGHT
run_direct_case direct-private-rm-created-nonzero OFFLINE
run_direct_case direct-private-rm-retry LOCAL
run_direct_case direct-private-rm-persistent LIGHT
run_direct_case direct-postcommit-lock-release LOCAL
run_direct_case direct-mktemp-private-symlink LIGHT
run_direct_case direct-mktemp-private-hardlink OFFLINE
run_direct_case direct-mktemp-private-fifo LOCAL
run_direct_case direct-mktemp-private-outside-special LIGHT
run_direct_case direct-mktemp-stage-outside-directory OFFLINE
run_direct_case direct-mktemp-stage-ancestor-symlink LOCAL
run_direct_case direct-mktemp-stage-outside-symlink LIGHT
run_direct_case direct-mktemp-stage-prepop-symlink OFFLINE
run_direct_case direct-mktemp-stage-prepop-hardlink LOCAL
run_direct_case direct-mktemp-stage-prepop-fifo LIGHT
run_direct_case direct-mktemp-stage-prepop-special OFFLINE
run_direct_case direct-mktemp-stage-prepop-unexpected LOCAL

arity_root="${TEST_ROOT}/wrong-arity"
mkdir -p -- "${arity_root}/private" "${arity_root}/node"
chmod 0700 "${arity_root}/private"
write_direct_context "${arity_root}/private/context.json" OFFLINE \
  "${arity_root}/node"
if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
    "${arity_root}/private/context.json" "${arity_root}/private/result.json" \
    unexpected > "${arity_root}/stdout" 2> "${arity_root}/stderr"; then
  arity_status=0
else
  arity_status=$?
fi
[[ "${arity_status}" == 64 && ! -s "${arity_root}/stdout" &&
   ! -s "${arity_root}/stderr" ]] || fail 'wrong-arity contract changed'

create_arm="${TEST_ROOT}/create-arm"
awk '
  /^[[:space:]]+create-ms-wallet\)/ { capture=1 }
  capture { print }
  capture && /^[[:space:]]+;;/ { exit }
' "${CNTOOLS_SCRIPT}" > "${create_arm}"
[[ "$(grep -Fc 'cntools_compatibility_dispatch_action advanced.multisig.create' \
      "${create_arm}" || true)" == 1 ]] ||
  fail 'advanced.multisig.create public dispatch count changed'
grep -Fq '0) continue ;;' "${create_arm}" ||
  fail 'advanced.multisig.create success mapping changed'
grep -Fq '20|21) break 2 ;;' "${create_arm}" ||
  fail 'advanced.multisig.create parent mapping changed'
grep -Fq '22) myExit 0 "CNTools closed!" ;;' "${create_arm}" ||
  fail 'advanced.multisig.create exit mapping changed'
grep -Fq '*) waitToProceed; continue ;;' "${create_arm}" ||
  fail 'advanced.multisig.create failure mapping changed'
if grep -Eq 'createNewWallet|key_hashes|pay_script=|getBaseAddress|chmod 600' \
    "${create_arm}"; then
  fail 'advanced.multisig.create inline implementation remains after binding'
fi
grep -Fq 'cntools_action_main()' "${ACTION_SOURCE}" ||
  fail 'advanced.multisig.create modular entrypoint changed'
"${REAL_JQ}" -e '.id == "advanced.multisig.create" and
  .executionRequirements.modes == ["local", "light", "offline"]' \
  "${MODULE_SOURCE}" >/dev/null || fail 'module mode contract changed'

printf 'CNTools multisig-create characterization passed: 27 frozen legacy records + 1 public + 71 direct cases\n'
