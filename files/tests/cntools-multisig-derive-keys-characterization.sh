#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools multisig-derive-keys characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f"
ADDRESS_LIBRARY="${LEGACY_ROOT}/040-address-wallet-query.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/advanced/multisig/derive-keys/action.sh"
ACTION_DIRECTORY="${ACTION_SOURCE%/action.sh}"
MODULE_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/advanced/multisig/derive-keys/module.json"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-multisig-derive.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
DIRECT_FAKE_BIN="${TEST_ROOT}/direct-fake-bin"
BASE_PATH="${PATH}"
REAL_CHMOD="$(command -v chmod)"
REAL_JQ="$(command -v jq)"
REAL_MKTEMP="$(command -v mktemp)"
REAL_RM="$(command -v rm)"
REAL_RMDIR="$(command -v rmdir)"
MNEMONIC='one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen'

cleanup_test() {
  if [[ "${CNTOOLS_MULTISIG_DERIVE_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools multisig-derive test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  "${REAL_CHMOD}" -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools multisig-derive-keys characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${CNTOOLS_SCRIPT}" && ! -L "${CNTOOLS_SCRIPT}" ]] ||
  fail 'legacy controller is missing or unsafe'
[[ -f "${ADDRESS_LIBRARY}" && ! -L "${ADDRESS_LIBRARY}" ]] ||
  fail 'legacy address helper library is missing or unsafe'
[[ -f "${ACTION_SOURCE}" && ! -L "${ACTION_SOURCE}" ]] ||
  fail 'modular action is missing or unsafe'
[[ -f "${MODULE_SOURCE}" && ! -L "${MODULE_SOURCE}" ]] ||
  fail 'module metadata is missing or unsafe'
[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'

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

write_fake_commands() {
  local command_name=""
  mkdir -p -- "${FAKE_BIN}"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MULTISIG_DERIVE_SCENARIO:?}"' \
    'log="${CNTOOLS_MULTISIG_DERIVE_VECTOR_LOG:?}"' \
    'wallet_root="${CNTOOLS_MULTISIG_DERIVE_WALLET_ROOT:?}"' \
    'tmp_root="${CNTOOLS_MULTISIG_DERIVE_TMP_ROOT:?}"' \
    'printf '\''cardano-cli'\'' >> "${log}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  [[ "${normalized}" == "${wallet_root}/"* ]] && normalized="<wallet>/${normalized#"${wallet_root}/"}"' \
    '  [[ "${normalized}" == "${tmp_root}/"* ]] && normalized="<tmp>/${normalized#"${tmp_root}/"}"' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${log}"' \
    'done' \
    'printf '\''\n'\'' >> "${log}"' \
    'vk="" sk="" evk="" out="" previous="" operation=""' \
    'case "$*" in' \
    '  "address key-gen "*) operation=cli-payment ;;' \
    '  "latest stake-address key-gen "*) operation=cli-stake ;;' \
    '  "key verification-key "*)' \
    '    [[ "$*" == *multisig-payment.skey* ]] && operation=mnemonic-payment-evkey || operation=mnemonic-stake-evkey ;;' \
    '  "key non-extended-key "*)' \
    '    [[ "$*" == *ms_payment.evkey* ]] && operation=mnemonic-payment-vkey || operation=mnemonic-stake-vkey ;;' \
    '  *) operation=other ;;' \
    'esac' \
    'for argument in "$@"; do' \
    '  case "${previous}" in' \
    '    --verification-key-file) vk="${argument}" ;;' \
    '    --signing-key-file) sk="${argument}" ;;' \
    '    --verification-key-file-output) out="${argument}" ;;' \
    '  esac' \
    '  [[ "${previous}" == --extended-verification-key-file ]] && evk="${argument}"' \
    '  previous="${argument}"' \
    'done' \
    'case "${operation}" in' \
    '  cli-payment)' \
    '    printf '\''{"type":"PaymentVerificationKeyShelley_ed25519","description":"MultiSig Payment Verification Key","cborHex":"5820aaaaaaaa"}\n'\'' > "${vk}"' \
    '    printf '\''{"type":"PaymentSigningKeyShelley_ed25519","description":"MultiSig Payment Signing Key","cborHex":"5820bbbbbbbb"}\n'\'' > "${sk}"' \
    '    if [[ "${scenario}" == cli-payment-failure ]]; then printf '\''%s\n'\'' '\''RAW\033[31mPAYMENT-FAIL'\'' >&2; exit 41; fi ;;' \
    '  cli-stake)' \
    '    printf '\''{"type":"StakeVerificationKeyShelley_ed25519","description":"MultiSig Stake Verification Key","cborHex":"5820cccccccc"}\n'\'' > "${vk}"' \
    '    printf '\''{"type":"StakeSigningKeyShelley_ed25519","description":"MultiSig Stake Signing Key","cborHex":"5820dddddddd"}\n'\'' > "${sk}"' \
    '    if [[ "${scenario}" == cli-stake-failure ]]; then printf '\''%s\n'\'' '\''RAW\033[31mSTAKE-FAIL'\'' >&2; exit 42; fi ;;' \
    '  mnemonic-payment-evkey)' \
    '    out="${vk}"; printf '\''{"type":"PaymentExtendedVerificationKeyShelley_ed25519_bip32","description":"payment evkey","cborHex":"5820eeeeeeee"}\n'\'' > "${out}"' \
    '    if [[ "${scenario}" == mnemonic-payment-evkey-failure ]]; then printf '\''%s\n'\'' '\''payment evkey failed'\'' >&2; exit 43; fi ;;' \
    '  mnemonic-stake-evkey)' \
    '    out="${vk}"; printf '\''{"type":"StakeExtendedVerificationKeyShelley_ed25519_bip32","description":"stake evkey","cborHex":"5820ffffffff"}\n'\'' > "${out}"' \
    '    if [[ "${scenario}" == mnemonic-stake-evkey-failure ]]; then printf '\''%s\n'\'' '\''stake evkey failed'\'' >&2; exit 44; fi ;;' \
    '  mnemonic-payment-vkey)' \
    '    printf '\''{"type":"PaymentVerificationKeyShelley_ed25519","description":"MultiSig Payment Verification Key","cborHex":"582011111111"}\n'\'' > "${vk}"' \
    '    if [[ "${scenario}" == mnemonic-payment-vkey-failure ]]; then printf '\''%s\n'\'' '\''payment vkey failed'\'' >&2; exit 45; fi ;;' \
    '  mnemonic-stake-vkey)' \
    '    printf '\''{"type":"StakeVerificationKeyShelley_ed25519","description":"MultiSig Stake Verification Key","cborHex":"582022222222"}\n'\'' > "${vk}"' \
    '    if [[ "${scenario}" == mnemonic-stake-vkey-failure ]]; then printf '\''%s\n'\'' '\''stake vkey failed'\'' >&2; exit 46; fi ;;' \
    'esac' \
    > "${FAKE_BIN}/cardano-cli"
  chmod 0755 "${FAKE_BIN}/cardano-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MULTISIG_DERIVE_SCENARIO:?}"' \
    'log="${CNTOOLS_MULTISIG_DERIVE_VECTOR_LOG:?}"' \
    'printf '\''cardano-address'\'' >> "${log}"' \
    'for argument in "$@"; do printf '\''\t%s'\'' "${argument}" >> "${log}"; done' \
    'printf '\''\n'\'' >> "${log}"' \
    '[[ "${1:-}" == -v ]] && { printf '\''3.0.0\n'\''; exit 0; }' \
    'input=""; IFS= read -r input || true' \
    'case "$*" in' \
    '  "key from-recovery-phrase Shelley")' \
    '    [[ "${input}" == "${CNTOOLS_MULTISIG_DERIVE_MNEMONIC:?}" ]] || exit 93' \
    '    if [[ "${scenario}" == mnemonic-root-failure ]]; then printf '\''%s\n'\'' '\''ROOT RAW \033[31mFAIL'\'' >&2; exit 47; fi' \
    '    printf '\''root_xprv\n'\'' ;;' \
    '  "key child "*)' \
    '    [[ "${input}" == root_xprv ]] || exit 94' \
    '    [[ "$*" == */0/* ]] && printf '\''payment_xprv\n'\'' || printf '\''stake_xprv\n'\'' ;;' \
    '  "key public"*)' \
    '    [[ "${input}" == payment_xprv ]] && printf '\''payment_xpub\n'\'' || printf '\''stake_xpub\n'\'' ;;' \
    '  *) exit 95 ;;' \
    'esac' \
    > "${FAKE_BIN}/cardano-address"
  chmod 0755 "${FAKE_BIN}/cardano-address"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'input=""; IFS= read -r input || true' \
    'printf '\''bech32\n'\'' >> "${CNTOOLS_MULTISIG_DERIVE_VECTOR_LOG:?}"' \
    'case "${input}" in' \
    '  payment_xprv) printf '\''aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'\'' ;;' \
    '  payment_xpub) printf '\''bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'\'' ;;' \
    '  stake_xprv) printf '\''cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n'\'' ;;' \
    '  stake_xpub) printf '\''dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\n'\'' ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/bech32"
  chmod 0755 "${FAKE_BIN}/bech32"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MULTISIG_DERIVE_SCENARIO:?}"' \
    'log="${CNTOOLS_MULTISIG_DERIVE_VECTOR_LOG:?}"' \
    'wallet_root="${CNTOOLS_MULTISIG_DERIVE_WALLET_ROOT:?}"' \
    'printf '\''cardano-hw-cli'\'' >> "${log}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"; [[ "${normalized}" == "${wallet_root}/"* ]] && normalized="<wallet>/${normalized#"${wallet_root}/"}"' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${log}"' \
    'done' \
    'printf '\''\n'\'' >> "${log}"' \
    'previous="" verification_index=0 signing_index=0' \
    'for argument in "$@"; do' \
    '  case "${previous}" in' \
    '    --verification-key-file)' \
    '      verification_index=$((verification_index + 1))' \
    '      if (( verification_index == 1 )); then description="original payment hardware"; key_type=Payment; else description="original stake hardware"; key_type=Stake; fi' \
    '      printf '\''{"type":"%sVerificationKeyShelley_ed25519","description":"%s","cborHex":"582033333333"}\n'\'' "${key_type}" "${description}" > "${argument}" ;;' \
    '    --hw-signing-file)' \
    '      signing_index=$((signing_index + 1)); printf '\''hardware signing role %s\n'\'' "${signing_index}" > "${argument}" ;;' \
    '  esac' \
    '  previous="${argument}"' \
    'done' \
    'if [[ "${scenario}" == hardware-command-failure ]]; then printf '\''%s\n'\'' '\''HW RAW \033[31mFAIL'\'' >&2; exit 48; fi' \
    > "${FAKE_BIN}/cardano-hw-cli"
  chmod 0755 "${FAKE_BIN}/cardano-hw-cli"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s\n'\'' "${0##*/}" >> "${CNTOOLS_MULTISIG_DERIVE_NETWORK_LOG:?}"' \
      'exit 97' > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}
write_fake_commands

# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=/dev/null
. "${ADDRESS_LIBRARY}"
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

  [[ "${action_id}" == advanced.multisig.derive-keys && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch:%s\n' "${action_id}" >> "${EVENT_LOG:?}"
  tmp_mode="$(file_mode "${TMP_DIR}")" || return 70
  private_root="$("${REAL_MKTEMP}" -d \
    "${TMP_DIR%/}/multisig-derive-test-dispatch.XXXXXXXX")" || return 70
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
    printf '__CNTOOLS_MULTISIG_DERIVE_END__\n'
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
  if [[ "${DIRECT_ACTIVE:-N}" == Y && "${1:-}" == '[c] CLI' ]]; then
    printf 'action:key-source:%s\n' "${DIRECT_SOURCE:-cli}" >> "${EVENT_LOG:?}"
    [[ "${DIRECT_SOURCE:-cli}" == cli ]] && return 0
    [[ "${DIRECT_SOURCE:-cli}" == mnemonic ]] && return 1
    return 70
  fi
  case "${1:-}" in
    '[w] Wallet') menu=main ;;
    '[m] Metadata') menu=advanced ;;
    '[c] Create') menu=multisig ;;
    '[c] CLI') menu='key-source' ;;
    *) fail "unexpected selection menu: ${1:-<empty>}" ;;
  esac
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == multisig:d ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_MULTISIG_DERIVE_BEGIN__\n'
        printf 'action:begin\n' >> "${EVENT_LOG}"
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice unavailable: ${menu}:${choice}"
}

selectWallet() {
  [[ "${1:-}" == non-ms && "$#" == 1 ]] || fail 'derive selector contract changed'
  printf 'action:selectWallet:non-ms\n' >> "${EVENT_LOG:?}"
  case "${SCENARIO:?}" in
    empty|direct-empty)
      println 'No wallets available!'
      return 1
      ;;
    select-failure|direct-select-failure) return 1 ;;
    select-cancel|direct-select-cancel)
      END_ON_CLEAR=Y
      return 2
      ;;
    traversal-cli|direct-invalid-name) wallet_name='../outside/escape' ;;
    control-name-cli) wallet_name='alpha\033[31mOWNED' ;;
    *) wallet_name=alpha ;;
  esac
  return 0
}

getWalletType() {
  printf 'action:getWalletType:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  case "${SCENARIO:?}" in hardware-*|direct-hardware-*) return 0 ;; *) return 1 ;; esac
}

getCredentials() {
  printf 'action:getCredentials:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  ms_pay_cred='payment-credential-aaaaaaaa'
  ms_stake_cred='stake-credential-bbbbbbbb'
}

cmdAvailable() {
  printf 'action:cmdAvailable:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  case "${SCENARIO:?}:${1:-}" in
    hardware-tool-missing:cardano-hw-cli|mnemonic-tools-missing:bech32) return 1 ;;
  esac
  command -v -- "${1:-}" >/dev/null 2>&1
}

HWCLIversionCheck() {
  printf 'action:HWCLIversionCheck\n' >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:?}" != hardware-version-failure &&
     "${SCENARIO:?}" != direct-hardware-version-failure ]]
}

unlockHWDevice() {
  printf 'action:unlockHWDevice:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:?}" != hardware-unlock-failure &&
     "${SCENARIO:?}" != direct-hardware-unlock-failure ]]
}

getAnswerAnyCust() {
  local variable="${1:?}" value=""
  printf 'action:prompt:%s:%s\n' "${variable}" "${variable:+$([[ "${variable}" == mnemonic || "${variable}" == multisig_derive_mnemonic ]] && printf '<redacted>' || printf '%s' "${2:-}")}" >> "${EVENT_LOG:?}"
  case "${variable}" in
    mnemonic|multisig_derive_mnemonic)
      if [[ "${SCENARIO:?}" == mnemonic-word-count ||
            "${SCENARIO:?}" == direct-mnemonic-word-count ]]; then
        value='only three words'
      else
        value="${MNEMONIC}"
      fi
      ;;
    acct_idx|multisig_derive_account)
      case "${SCENARIO:?}" in
        mnemonic-account-invalid) value=bad ;;
        mnemonic-huge-index|direct-huge-index) value=999999999999999999999999999999999999 ;;
        *) value="" ;;
      esac
      ;;
    key_idx|multisig_derive_key)
      case "${SCENARIO:?}" in
        mnemonic-key-invalid) value=bad ;;
        mnemonic-huge-index|direct-huge-index) value=888888888888888888888888888888888888 ;;
        *) value="" ;;
      esac
      ;;
    prompted)
      case "${2:-}" in
        'Account (default: 0)')
          [[ "${SCENARIO:?}" != direct-huge-index ]] ||
            value=999999999999999999999999999999999999
          ;;
        'Key index (default: 0)')
          [[ "${SCENARIO:?}" != direct-huge-index ]] ||
            value=888888888888888888888888888888888888
          ;;
        *) fail "unexpected scoped index prompt: ${2:-<empty>}" ;;
      esac
      ;;
    *) fail "unexpected prompt variable: ${variable}" ;;
  esac
  printf -v "${variable}" '%s' "${value}"
}

isNumber() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

safeDel() {
  local target="${1:-}"
  printf 'action:safeDel:%s\n' "${target}" >> "${EVENT_LOG:?}"
  rm -rf -- "${target}"
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  printf 'action:globals:acct=%s:key=%s:mnemonic=%s:root=%s\n' \
    "${acct_idx-unset}" "${key_idx-unset}" \
    "$([[ -v mnemonic ]] && printf set || printf unset)" \
    "$([[ -v root_prv ]] && printf set || printf unset)" >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_MULTISIG_DERIVE_END__\n'
    printf 'action:end:wait\n' >> "${EVENT_LOG:?}"
    CAPTURE_ACTIVE=N
  fi
  return 0
}

myExit() {
  printf 'exit:%s:%s\n' "${1:-0}" "${2:-}" >> "${EVENT_LOG:?}"
  exit "${1:-0}"
}

extract_between_markers() {
  local source="$1" target="$2" begin="$3" end="$4"
  [[ "$(grep -cF "${begin}" "${source}" || true)" == 1 &&
     "$(grep -cF "${end}" "${source}" || true)" == 1 ]] ||
    fail "markers changed in ${source}"
  awk -v begin="${begin}" -v end="${end}" \
    '$0 == begin { active=1; next } $0 == end { exit } active' \
    "${source}" > "${target}"
}

normalize_file() {
  local source="$1" target="$2" runtime="$3"
  sed "s#${runtime}#<runtime>#g" "${source}" > "${target}"
}

setup_wallet() {
  local scenario="$1" wallet_root="$2" outside="$3" selected=""
  case "${scenario}" in
    empty|select-failure|select-cancel) return 0 ;;
    traversal-cli) selected="${outside}/escape" ;;
    control-name-cli) selected="${wallet_root}/alpha\\033[31mOWNED" ;;
    symlink-cli)
      selected="${outside}/symlink-wallet"
      mkdir -p -- "${selected}"
      ln -s -- "${selected}" "${wallet_root}/alpha"
      ;;
    *) selected="${wallet_root}/alpha" ;;
  esac
  mkdir -p -- "${selected}"
  printf 'base payment key\n' > "${selected}/payment.vkey"
  printf 'base stake key\n' > "${selected}/stake.vkey"
  printf 'base payment secret\n' > "${selected}/payment.skey"
  printf 'base stake secret\n' > "${selected}/stake.skey"
  chmod 0600 "${selected}"/*
  case "${scenario}" in
    cli-existing) printf 'existing multisig secret\n' > "${selected}/multisig-payment.skey"; chmod 0600 "${selected}/multisig-payment.skey" ;;
    hardlink-vkey-cli)
      printf 'outside verification sentinel\n' > "${outside}/outside.vkey"
      ln -- "${outside}/outside.vkey" "${selected}/multisig-payment.vkey"
      chmod 0600 "${outside}/outside.vkey"
      ;;
    hardware-saved-success)
      printf '1852H/1815H/7H/x/9\n' > "${selected}/derivation.path"
      chmod 0644 "${selected}/derivation.path"
      ;;
  esac
}

assert_zero_mutation() {
  local scenario="$1" before="$2" after="$3"
  assert_files_equal "${after}" "${before}" "${scenario} zero mutation"
}

assert_key_mode() {
  local path="$1" expected="$2" label="$3"
  [[ -f "${path}" && ! -L "${path}" && "$(file_mode "${path}")" == "${expected}" ]] ||
    fail "${label} mode/inventory changed"
}

assert_mutation_contract() {
  local scenario="$1" wallet_root="$2" outside="$3" before="$4" after="$5"
  local selected="${wallet_root}/alpha"
  case "${scenario}" in
    empty|select-failure|select-cancel|cli-existing|mnemonic-tools-missing|mnemonic-word-count|mnemonic-account-invalid|mnemonic-key-invalid|hardware-tool-missing|hardware-version-failure)
      assert_zero_mutation "${scenario}" "${before}" "${after}"
      ;;
    cli-success-*|mnemonic-success|mnemonic-huge-index|hardware-success|hardware-saved-success|hardlink-vkey-cli|control-name-cli|traversal-cli|symlink-cli)
      case "${scenario}" in
        traversal-cli) selected="${outside}/escape" ;;
        symlink-cli) selected="${outside}/symlink-wallet" ;;
        control-name-cli) selected="${wallet_root}/alpha\\033[31mOWNED" ;;
      esac
      assert_key_mode "${selected}/multisig-payment.vkey" 600 "${scenario} payment vkey"
      assert_key_mode "${selected}/multisig-stake.vkey" 600 "${scenario} stake vkey"
      if [[ "${scenario}" == hardware-* ]]; then
        assert_key_mode "${selected}/multisig-payment.hwsfile" 600 "${scenario} payment hwsfile"
        assert_key_mode "${selected}/multisig-stake.hwsfile" 600 "${scenario} stake hwsfile"
      else
        assert_key_mode "${selected}/multisig-payment.skey" 600 "${scenario} payment skey"
        assert_key_mode "${selected}/multisig-stake.skey" 600 "${scenario} stake skey"
      fi
      if [[ "${scenario}" == mnemonic-* || "${scenario}" == hardware-* ]]; then
        [[ "$(file_mode "${selected}/derivation.path")" == 644 ]] ||
          fail "${scenario} derivation-path mode changed"
      fi
      ;;
    cli-payment-failure)
      assert_key_mode "${selected}/multisig-payment.vkey" 644 'payment failure partial vkey'
      assert_key_mode "${selected}/multisig-payment.skey" 644 'payment failure partial skey'
      ;;
    cli-stake-failure)
      for key in multisig-payment.vkey multisig-payment.skey multisig-stake.vkey multisig-stake.skey; do
        assert_key_mode "${selected}/${key}" 644 "stake failure ${key}"
      done
      ;;
    mnemonic-root-failure|hardware-unlock-failure)
      assert_key_mode "${selected}/derivation.path" 644 "${scenario} derivation residue"
      ;;
    mnemonic-*-failure)
      assert_key_mode "${selected}/derivation.path" 644 "${scenario} derivation residue"
      assert_key_mode "${selected}/multisig-payment.skey" 644 "${scenario} payment secret residue"
      assert_key_mode "${selected}/multisig-stake.skey" 644 "${scenario} stake secret residue"
      case "${scenario}" in
        mnemonic-payment-vkey-failure|mnemonic-stake-vkey-failure)
          assert_key_mode "${selected}/multisig-payment.vkey" 644 "${scenario} payment vkey residue" ;;
      esac
      case "${scenario}" in
        mnemonic-stake-vkey-failure)
          assert_key_mode "${selected}/multisig-stake.vkey" 644 "${scenario} stake vkey residue" ;;
      esac
      ;;
    hardware-command-failure)
      [[ ! -e "${selected}" && ! -L "${selected}" ]] ||
        fail 'hardware failure no longer deletes the complete selected wallet'
      ;;
  esac
  if [[ "${scenario}" == hardlink-vkey-cli ]]; then
    [[ "$(< "${outside}/outside.vkey")" == *'MultiSig Payment Verification Key'* ]] ||
      fail 'hardlink overwrite escape changed'
  fi
}

assert_derivation_vectors() {
  local scenario="$1" actual="$2" expected="" account="" key=""
  expected="${actual}.expected"
  case "${scenario}" in
    cli-success-local|cli-success-light|cli-success-offline)
      printf '%s\n' \
        $'cardano-cli\taddress\tkey-gen\t--verification-key-file\t<wallet>/alpha/multisig-payment.vkey\t--signing-key-file\t<wallet>/alpha/multisig-payment.skey' \
        $'cardano-cli\tlatest\tstake-address\tkey-gen\t--verification-key-file\t<wallet>/alpha/multisig-stake.vkey\t--signing-key-file\t<wallet>/alpha/multisig-stake.skey' > "${expected}"
      ;;
    mnemonic-success|mnemonic-huge-index)
      if [[ "${scenario}" == mnemonic-huge-index ]]; then
        account=999999999999999999999999999999999999
        key=888888888888888888888888888888888888
      else
        account=0
        key=0
      fi
      printf '%s\n' \
        $'cardano-address\t-v' \
        $'cardano-address\tkey\tfrom-recovery-phrase\tShelley' \
        "cardano-address"$'\tkey\tchild\t'"1854H/1815H/${account}H/0/${key}" \
        "cardano-address"$'\tkey\tchild\t'"1854H/1815H/${account}H/2/${key}" \
        $'cardano-address\tkey\tpublic\t--with-chain-code' \
        $'cardano-address\tkey\tpublic\t--with-chain-code' \
        bech32 bech32 bech32 bech32 \
        $'cardano-cli\tkey\tverification-key\t--signing-key-file\t<wallet>/alpha/multisig-payment.skey\t--verification-key-file\t<tmp>/ms_payment.evkey' \
        $'cardano-cli\tkey\tverification-key\t--signing-key-file\t<wallet>/alpha/multisig-stake.skey\t--verification-key-file\t<tmp>/ms_stake.evkey' \
        $'cardano-cli\tkey\tnon-extended-key\t--extended-verification-key-file\t<tmp>/ms_payment.evkey\t--verification-key-file\t<wallet>/alpha/multisig-payment.vkey' \
        $'cardano-cli\tkey\tnon-extended-key\t--extended-verification-key-file\t<tmp>/ms_stake.evkey\t--verification-key-file\t<wallet>/alpha/multisig-stake.vkey' > "${expected}"
      ;;
    hardware-success|hardware-saved-success)
      if [[ "${scenario}" == hardware-saved-success ]]; then
        account=7
        key=9
      else
        account=0
        key=0
      fi
      printf '%s\n' \
        "cardano-hw-cli"$'\taddress\tkey-gen\t--path\t'"1854H/1815H/${account}H/0/${key}"$'\t--path\t'"1854H/1815H/${account}H/2/${key}"$'\t--verification-key-file\t<wallet>/alpha/multisig-payment.vkey\t--verification-key-file\t<wallet>/alpha/multisig-stake.vkey\t--hw-signing-file\t<wallet>/alpha/multisig-payment.hwsfile\t--hw-signing-file\t<wallet>/alpha/multisig-stake.hwsfile' > "${expected}"
      ;;
    *) return 0 ;;
  esac
  assert_files_equal "${actual}" "${expected}" "${scenario} exact derivation vectors"
}

expected_signature() {
  case "$1" in
    empty) printf '%s\n' 9882fed1050377dcca920e651150a51c3849506ca37d585e0208f3c2d802f612 ;;
    select-failure) printf '%s\n' 745fc02035f99528d138a5f6234eefce72f5b317a7af18d8cb25c1d403525607 ;;
    select-cancel) printf '%s\n' 703c38eccdb2f752322c7b353703a1a8547ae05dee4b0eaf658dc462a7a83bea ;;
    cli-existing) printf '%s\n' aa8cda5bb8d65502b34c2e6f18c38bb52679da8faa7857d0e38a1f7c2f6d1015 ;;
    cli-success-local) printf '%s\n' 87cf8067b8c5bdf3164cffef94d9a1cf5097907cd632faa86ad22da0779369f4 ;;
    cli-success-light) printf '%s\n' 0fbbac467b6b046b9231b0d14845cdfcda12c28121e9314e2077be8393e00677 ;;
    cli-success-offline) printf '%s\n' ea56562f58ccd85af6fcd541cbc49605c8799c6c2a6a7177675c8287c681e5a1 ;;
    cli-payment-failure) printf '%s\n' a2c3aa7f9fb2162ae3169c58b3da9b94753d2f532287ba3674b2998fcb955748 ;;
    cli-stake-failure) printf '%s\n' 1ad6633365bc1e410fb15ac6bdc30f41ca4370565529f7fa7ae571e5c0a1b82c ;;
    mnemonic-tools-missing) printf '%s\n' 1a297d3d3f501fcf70c7d0fd6b17205c44b4d263baa5bd594d44722ebfe47867 ;;
    mnemonic-word-count) printf '%s\n' 0f744a955aabc35229613e8feb4cd02b33000416de15ca15108acc8747a6ca3e ;;
    mnemonic-account-invalid) printf '%s\n' 60d908ed4bc3867cb56204e275139d27cc5951bff04c5f07713d5afbfff0e0c7 ;;
    mnemonic-key-invalid) printf '%s\n' d18abc6e7faa1715f52a35595db673c86e3eed2e80ca1296cc5ed9997b0078fc ;;
    mnemonic-root-failure) printf '%s\n' 4fff2bc3963dd5b9402ad84c973759aaf527dd16dbf573c859506164d9b3b74a ;;
    mnemonic-payment-evkey-failure) printf '%s\n' b2b368d2ad90a8777972d17ed462fb4f9aa9abf0c06a257c3aecaeacaa698142 ;;
    mnemonic-stake-evkey-failure) printf '%s\n' 8c14738edd5290229ce77b560a49fd24dad83cf342268f6483005c3fd6d7c422 ;;
    mnemonic-payment-vkey-failure) printf '%s\n' b652f0791f5d188d3bd227a90821e180afb9ab3eee82f24a536c089f25988422 ;;
    mnemonic-stake-vkey-failure) printf '%s\n' 1db9d92fa2d1094b766ef5d46399025d14dbcff7de58e5f108a85b86eed3cbe8 ;;
    mnemonic-success) printf '%s\n' ee004e66ec09fb9f385919fcf7670fd54cc214b21a87e5032c3234d77143858f ;;
    mnemonic-huge-index) printf '%s\n' ac710e5176ff57a688542214ca6431202d41d37952e00d92a1f133501143665a ;;
    hardware-tool-missing) printf '%s\n' 5774b606c6b7db79a50f520ad3f7925a5e1b1b84c220b5da5317fb4c985e5a98 ;;
    hardware-version-failure) printf '%s\n' 73cd4f1e0336c01ba041ae4238d26c4c8fd6a1b8af7c8045bb23cc2fefe9a6aa ;;
    hardware-unlock-failure) printf '%s\n' 8c5d1154e2481fa7425faae4fe6dceefb6be5e01f44fc60ede85fab4e6b95fb9 ;;
    hardware-command-failure) printf '%s\n' 2bb6a7e0110879dd2a4d2b2cf48ee9ffcf2271892ce488a00599045d0281c27a ;;
    hardware-success) printf '%s\n' b26adf2b90aa0f894264e315dc3f653f52b77481608a2e89f1fd9773a0f37fec ;;
    hardware-saved-success) printf '%s\n' 8a80f8a4b3dd3045b0b269d03253c4ddccc0ec1a4d71ceff9c9888125a93cf10 ;;
    traversal-cli) printf '%s\n' 76e2a99c1cbbe46c344c648b39dd2bafc36155a23ce51a92aa9ca9dea2a47337 ;;
    symlink-cli) printf '%s\n' 3e515d36f857772203f326247c97b21a496c35db589ba28c82d080d969dba4c7 ;;
    hardlink-vkey-cli) printf '%s\n' 190f1c0d828bda93cce0a5cdb0f16a03c05d0edc9bde9e034a653b454c9fc569 ;;
    control-name-cli) printf '%s\n' 82bb90ee33e435ccb3acd12ec51fc2a2a8f8ae20c71def02d51d494dca6b3a9f ;;
    *) return 1 ;;
  esac
}

run_case() (
  local scenario="$1" mode="$2" source_choice="${3:-}"
  local case_root="${TEST_ROOT}/cases/${scenario}" runtime="" wallet_root="" outside=""
  local full_stdout="" action_stdout="" stderr_file="" events="" action_events=""
  local vectors="" network="" before="" after="" normalized_events="" normalized_vectors=""
  local normalized_after=""
  local signature="" expected="" status=0 waits=0
  runtime="${case_root}/runtime"
  wallet_root="${runtime}/wallet"
  outside="${runtime}/outside"
  full_stdout="${case_root}/full.stdout"
  action_stdout="${case_root}/action.stdout"
  stderr_file="${case_root}/stderr"
  events="${case_root}/events"
  action_events="${case_root}/action.events"
  vectors="${case_root}/vectors"
  network="${case_root}/network"
  before="${case_root}/before.tree"
  after="${case_root}/after.tree"
  normalized_events="${case_root}/events.normalized"
  normalized_vectors="${case_root}/vectors.normalized"
  normalized_after="${case_root}/after.normalized"
  mkdir -p -- "${wallet_root}" "${outside}" "${runtime}/tmp" "${runtime}/home" \
    "${runtime}/pool" "${runtime}/asset"
  setup_wallet "${scenario}" "${wallet_root}" "${outside}"
  tree_snapshot "${runtime}" "${before}" || fail "${scenario} pre-snapshot failed"
  : > "${events}"
  : > "${vectors}"
  : > "${network}"
  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    PATH="${FAKE_BIN}:${BASE_PATH}"
    export PATH
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
    WALLET_PAY_SK_FILENAME=payment.skey
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_STAKE_SK_FILENAME=stake.skey
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_HW_PAY_SK_FILENAME=payment.hwsfile
    WALLET_HW_STAKE_SK_FILENAME=stake.hwsfile
    WALLET_DERIVATION_PATH_FILENAME=derivation.path
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE="" FG_MAGENTA=""
    FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE="" FG_WHITE="" NC=""
    EVENT_LOG="${events}"
    SCENARIO="${scenario}"
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
    CHOICES=(a s d)
    [[ -z "${source_choice}" ]] || CHOICES+=("${source_choice}")
    CHOICES+=(h q)
    CHOICE_CURSOR=0
    export CNTOOLS_MULTISIG_DERIVE_SCENARIO="${scenario}"
    export CNTOOLS_MULTISIG_DERIVE_VECTOR_LOG="${vectors}"
    export CNTOOLS_MULTISIG_DERIVE_NETWORK_LOG="${network}"
    export CNTOOLS_MULTISIG_DERIVE_WALLET_ROOT="${wallet_root}"
    export CNTOOLS_MULTISIG_DERIVE_TMP_ROOT="${runtime}/tmp"
    export CNTOOLS_MULTISIG_DERIVE_MNEMONIC="${MNEMONIC}"
    unset acct_idx key_idx mnemonic root_prv payment_xprv stake_xprv payment_xpub stake_xpub
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"
  extract_between_markers "${full_stdout}" "${action_stdout}" \
    '__CNTOOLS_MULTISIG_DERIVE_BEGIN__' '__CNTOOLS_MULTISIG_DERIVE_END__'
  awk '$0=="action:begin"{p=1;next}$0 ~ /^action:end:/{exit}p' "${events}" > "${action_events}"
  normalize_file "${events}" "${normalized_events}" "${runtime}"
  normalize_file "${vectors}" "${normalized_vectors}" "${runtime}"
  assert_derivation_vectors "${scenario}" "${normalized_vectors}"
  [[ ! -s "${network}" ]] || fail "${scenario} attempted network access"
  ! grep -Fq "${MNEMONIC}" "${full_stdout}" "${stderr_file}" "${events}" "${vectors}" ||
    fail "${scenario} exposed mnemonic"
  grep -Fq ' >> ADVANCED >> MULTISIG >> DERIVE KEYS' "${action_stdout}" ||
    fail "${scenario} action header changed"
  [[ "$(grep -c '^menu:main:a$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:advanced:s$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:multisig:d$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:multisig:h$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:main:q$' "${events}" || true)" == 1 ]] ||
    fail "${scenario} navigation changed"
  waits="$(grep -c '^action:waitToProceed$' "${events}" || true)"
  if [[ "${scenario}" == select-cancel ]]; then
    [[ "${waits}" == 0 ]] || fail 'selector cancel wait behavior changed'
  else
    [[ "${waits}" == 1 ]] || fail "${scenario} wait behavior changed"
  fi
  tree_snapshot "${runtime}" "${after}" || fail "${scenario} post-snapshot failed"
  assert_mutation_contract "${scenario}" "${wallet_root}" "${outside}" "${before}" "${after}"
  normalize_file "${after}" "${normalized_after}" "${runtime}"

  if [[ "${scenario}" == cli-payment-failure ||
        "${scenario}" == cli-stake-failure ||
        "${scenario}" == hardware-command-failure ]]; then
    LC_ALL=C grep -q $'\033\[31m' "${action_stdout}" ||
      fail "${scenario} raw diagnostic terminal interpretation changed"
  fi
  if [[ "${scenario}" == control-name-cli ]]; then
    LC_ALL=C grep -q $'alpha\033\[31mOWNED' "${action_stdout}" ||
      fail 'control-bearing wallet name terminal interpretation changed'
  fi
  if [[ "${scenario}" == mnemonic-root-failure ]]; then
    grep -Fq 'ROOT RAW \033[31mFAIL' "${stderr_file}" ||
      fail 'mnemonic root raw stderr changed'
  elif [[ ! -s "${stderr_file}" ]]; then
    :
  else
    fail "${scenario} unexpected stderr"
  fi
  signature="$(
    printf '%s\t%s\t%s\t%s\t%s' \
      "$(file_hash "${action_stdout}")" \
      "$(file_hash "${stderr_file}")" \
      "$(file_hash "${normalized_events}")" \
      "$(file_hash "${normalized_vectors}")" \
      "$(file_hash "${normalized_after}")" |
      stream_hash
  )"
  expected="$(expected_signature "${scenario}")" ||
    fail "${scenario} has no frozen signature"
  [[ "${signature}" == "${expected}" ]] ||
    fail "${scenario} exact stream/vector/tree signature changed (${signature})"
)

# The exact pre-bind records remain reviewable even though the public arm now
# owns only transport. Hardened behavior is covered below by one real public
# traversal and the complete direct matrix.
legacy_fingerprint_count=0
for legacy_scenario in \
  empty select-failure select-cancel cli-existing cli-success-local \
  cli-success-light cli-success-offline cli-payment-failure \
  cli-stake-failure mnemonic-tools-missing mnemonic-word-count \
  mnemonic-account-invalid mnemonic-key-invalid mnemonic-root-failure \
  mnemonic-payment-evkey-failure mnemonic-stake-evkey-failure \
  mnemonic-payment-vkey-failure mnemonic-stake-vkey-failure \
  mnemonic-success mnemonic-huge-index hardware-tool-missing \
  hardware-version-failure hardware-unlock-failure hardware-command-failure \
  hardware-success hardware-saved-success traversal-cli symlink-cli \
  hardlink-vkey-cli control-name-cli; do
  legacy_fingerprint="$(expected_signature "${legacy_scenario}")"
  [[ "${legacy_fingerprint}" =~ ^[0-9a-f]{64}$ ]] ||
    fail "invalid frozen legacy fingerprint: ${legacy_scenario}"
  legacy_fingerprint_count=$((legacy_fingerprint_count + 1))
done
[[ "${legacy_fingerprint_count}" == 30 ]] ||
  fail 'frozen legacy fingerprint coverage changed'

write_direct_fake_commands() {
  local command_name=""
  mkdir -p -- "${DIRECT_FAKE_BIN}"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MS_SCENARIO:?}" log="${CNTOOLS_MS_VECTOR_LOG:?}"' \
    'wallet="${CNTOOLS_MS_WALLET_ROOT:?}" outside="${CNTOOLS_MS_OUTSIDE:?}"' \
    'printf '\''cardano-cli'\'' >> "${log}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  [[ "${normalized}" == "${wallet}/"* ]] && normalized="<wallet>/${normalized#"${wallet}/"}"' \
    '  [[ "${normalized}" == "${CNTOOLS_MS_PRIVATE_ROOT}/"* ]] && normalized="<private>/${normalized#"${CNTOOLS_MS_PRIVATE_ROOT}/"}"' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${log}"' \
    'done' \
    'printf '\''\n'\'' >> "${log}"' \
    'operation=unknown previous="" vkey="" skey="" outfile="" extended=""' \
    'case "$*" in' \
    '  "address key-gen "*) operation=payment-keygen ;;' \
    '  "latest stake-address key-gen "*) operation=stake-keygen ;;' \
    '  "address key-hash "*) operation=payment-hash ;;' \
    '  "latest stake-address key-hash "*) operation=stake-hash ;;' \
    '  "key verification-key "*) operation=extended-vkey ;;' \
    '  "key non-extended-key "*) operation=nonextended-vkey ;;' \
    'esac' \
    'for argument in "$@"; do' \
    '  case "${previous}" in' \
    '    --verification-key-file) vkey="${argument}" ;;' \
    '    --signing-key-file) skey="${argument}" ;;' \
    '    --out-file) outfile="${argument}" ;;' \
    '    --extended-verification-key-file) extended="${argument}" ;;' \
    '  esac' \
    '  previous="${argument}"' \
    'done' \
    'pay_vkey_hex=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'pay_skey_hex=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    'stake_vkey_hex=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
    'stake_skey_hex=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
    'case "${operation}" in' \
    '  payment-keygen)' \
    '    type=PaymentVerificationKeyShelley_ed25519' \
    '    [[ "${scenario}" != direct-wrong-role ]] || type=StakeVerificationKeyShelley_ed25519' \
    '    printf '\''{"cborHex":"5820%s","description":"Payment Verification Key","type":"%s"}\n'\'' "${pay_vkey_hex}" "${type}" > "${vkey}"' \
    '    printf '\''{"cborHex":"5820%s","description":"Payment Signing Key","type":"PaymentSigningKeyShelley_ed25519"}\n'\'' "${pay_skey_hex}" > "${skey}"' \
    '    case "${scenario}" in' \
    '      direct-malformed-key) printf '\''not-json\n'\'' > "${vkey}" ;;' \
    '      direct-symlink-output) rm -f -- "${skey}"; printf '\''outside secret\n'\'' > "${outside}/escaped.skey"; chmod 0640 "${outside}/escaped.skey"; ln -s -- "${outside}/escaped.skey" "${skey}" ;;' \
    '      direct-hardlink-output) rm -f -- "${skey}"; printf '\''outside secret\n'\'' > "${outside}/escaped.skey"; chmod 0640 "${outside}/escaped.skey"; "${CNTOOLS_MS_REAL_LN:?}" -- "${outside}/escaped.skey" "${skey}" ;;' \
    '      direct-fifo-output) rm -f -- "${skey}"; mkfifo "${skey}" ;;' \
    '      direct-signal-derive) kill -TERM "${PPID}" ;;' \
    '      direct-cli-payment-failure) printf '\''%s\n'\'' '\''RAW SECRET PAYMENT FAILURE \033[31m'\'' >&2; exit 41 ;;' \
    '    esac' \
    '    ;;' \
    '  stake-keygen)' \
    '    printf '\''{"cborHex":"5820%s","description":"Stake Verification Key","type":"StakeVerificationKeyShelley_ed25519"}\n'\'' "${stake_vkey_hex}" > "${vkey}"' \
    '    printf '\''{"cborHex":"5820%s","description":"Stake Signing Key","type":"StakeSigningKeyShelley_ed25519"}\n'\'' "${stake_skey_hex}" > "${skey}"' \
    '    [[ "${scenario}" != direct-cli-stake-failure ]] || { printf '\''%s\n'\'' '\''RAW SECRET STAKE FAILURE \033[31m'\'' >&2; exit 42; }' \
    '    ;;' \
    '  extended-vkey)' \
    '    if [[ "${skey}" == *multisig-payment.skey ]]; then' \
    '      printf '\''{"cborHex":"5840%s%s","description":"Payment Extended Verification Key","type":"PaymentExtendedVerificationKeyShelley_ed25519_bip32"}\n'\'' "${pay_vkey_hex}" "${pay_vkey_hex}" > "${vkey}"' \
    '      if [[ "${scenario}" == direct-evkey-hardlink-output ]]; then rm -f -- "${vkey}"; printf '\''outside evkey\n'\'' > "${outside}/escaped.evkey"; chmod 0640 "${outside}/escaped.evkey"; "${CNTOOLS_MS_REAL_LN:?}" -- "${outside}/escaped.evkey" "${vkey}"; fi' \
    '    else' \
    '      printf '\''{"cborHex":"5840%s%s","description":"Stake Extended Verification Key","type":"StakeExtendedVerificationKeyShelley_ed25519_bip32"}\n'\'' "${stake_vkey_hex}" "${stake_vkey_hex}" > "${vkey}"' \
    '    fi' \
    '    ;;' \
    '  nonextended-vkey)' \
    '    if [[ "${extended}" == *payment* ]]; then' \
    '      printf '\''{"cborHex":"5820%s","description":"Payment Verification Key","type":"PaymentVerificationKeyShelley_ed25519"}\n'\'' "${pay_vkey_hex}" > "${vkey}"' \
    '    else' \
    '      printf '\''{"cborHex":"5820%s","description":"Stake Verification Key","type":"StakeVerificationKeyShelley_ed25519"}\n'\'' "${stake_vkey_hex}" > "${vkey}"' \
    '    fi' \
    '    ;;' \
    '  payment-hash)' \
    '    printf '\''eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n'\'' > "${outfile}"' \
    '    case "${scenario}" in' \
    '      direct-credential-symlink-output) rm -f -- "${outfile}"; printf '\''outside credential\n'\'' > "${outside}/escaped.cred"; chmod 0640 "${outside}/escaped.cred"; ln -s -- "${outside}/escaped.cred" "${outfile}" ;;' \
    '      direct-credential-hardlink-output) rm -f -- "${outfile}"; printf '\''outside credential\n'\'' > "${outside}/escaped.cred"; chmod 0640 "${outside}/escaped.cred"; "${CNTOOLS_MS_REAL_LN:?}" -- "${outside}/escaped.cred" "${outfile}" ;;' \
    '    esac' \
    '    ;;' \
    '  stake-hash)' \
    '    if [[ "${scenario}" == direct-credential-control ]]; then printf '\''bad\\033[31mcredential\n'\'' > "${outfile}"; else printf '\''ffffffffffffffffffffffffffffffffffffffffffffffffffffffff\n'\'' > "${outfile}"; fi' \
    '    [[ "${scenario}" != direct-credential-failure ]] || { printf '\''raw credential error\n'\'' >&2; exit 43; }' \
    '    if [[ "${scenario}" == direct-inventory-race ]]; then printf '\''attacker\n'\'' > "${wallet}/alpha/injected.race"; chmod 0600 "${wallet}/alpha/injected.race"; fi' \
    '    if [[ "${scenario}" == direct-base-tamper ]]; then printf '\''tamper\n'\'' >> "${wallet}/alpha/base.marker"; fi' \
    '    ;;' \
    'esac' \
    > "${DIRECT_FAKE_BIN}/cardano-cli"
  chmod 0755 "${DIRECT_FAKE_BIN}/cardano-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MS_SCENARIO:?}" log="${CNTOOLS_MS_VECTOR_LOG:?}"' \
    'printf '\''cardano-address'\'' >> "${log}"; for argument in "$@"; do printf '\''\t%s'\'' "${argument}" >> "${log}"; done; printf '\''\n'\'' >> "${log}"' \
    '[[ "${1:-}" == -v ]] && { printf '\''3.0.0\n'\''; exit 0; }' \
    'input=""; IFS= read -r input || true' \
    'case "$*" in' \
    '  "key from-recovery-phrase Shelley")' \
    '    if [[ "${scenario}" == direct-mnemonic-tool-failure ]]; then printf '\''RAW MNEMONIC %s \033[31m\n'\'' "${input}" >&2; exit 51; fi' \
    '    printf '\''root_xsk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'\'' ;;' \
    '  "key child "*) [[ "$*" == */0/* ]] && printf '\''payment_xsk_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'\'' || printf '\''stake_xsk_cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n'\'' ;;' \
    '  "key public"*) [[ "${input}" == payment_* ]] && printf '\''payment_xvk_dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\n'\'' || printf '\''stake_xvk_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n'\'' ;;' \
    '  *) exit 52 ;;' \
    'esac' \
    > "${DIRECT_FAKE_BIN}/cardano-address"
  chmod 0755 "${DIRECT_FAKE_BIN}/cardano-address"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'input=""; IFS= read -r input || true' \
    'printf '\''bech32\n'\'' >> "${CNTOOLS_MS_VECTOR_LOG:?}"' \
    'case "${input}" in' \
    '  payment_xsk_*) printf '\''aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'\'' ;;' \
    '  stake_xsk_*) printf '\''bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'\'' ;;' \
    '  payment_xvk_*) printf '\''aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'\'' ;;' \
    '  stake_xvk_*) printf '\''cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n'\'' ;;' \
    '  *) exit 53 ;;' \
    'esac' \
    > "${DIRECT_FAKE_BIN}/bech32"
  chmod 0755 "${DIRECT_FAKE_BIN}/bech32"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MS_SCENARIO:?}" log="${CNTOOLS_MS_VECTOR_LOG:?}"' \
    'wallet="${CNTOOLS_MS_WALLET_ROOT:?}" outside="${CNTOOLS_MS_OUTSIDE:?}" previous="" vk_index=0 sk_index=0 path_index=0 payment_path="" stake_path=""' \
    'printf '\''cardano-hw-cli'\'' >> "${log}"; for argument in "$@"; do normalized="${argument}"; [[ "${normalized}" == "${wallet}/"* ]] && normalized="<wallet>/${normalized#"${wallet}/"}"; printf '\''\t%s'\'' "${normalized}" >> "${log}"; done; printf '\''\n'\'' >> "${log}"' \
    'for argument in "$@"; do' \
    '  case "${previous}" in' \
    '    --path) path_index=$((path_index + 1)); if (( path_index == 1 )); then payment_path="${argument}"; else stake_path="${argument}"; fi ;;' \
    '    --verification-key-file)' \
    '      vk_index=$((vk_index + 1)); if (( vk_index == 1 )); then role=Payment; hex=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; else role=Stake; hex=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc; fi' \
    '      [[ "${scenario}" != direct-hardware-wrong-pair || "${role}" != Stake ]] || hex=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
    '      printf '\''{"cborHex":"5820%s","description":"%s Hardware Verification Key","type":"%sVerificationKeyShelley_ed25519"}\n'\'' "${hex}" "${role}" "${role}" > "${argument}" ;;' \
    '    --hw-signing-file)' \
    '      sk_index=$((sk_index + 1)); if (( sk_index == 1 )); then role=Payment; hex=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; path="${payment_path}"; else role=Stake; hex=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc; path="${stake_path}"; fi' \
    '      printf '\''{"cborXPubKeyHex":"5840%s9999999999999999999999999999999999999999999999999999999999999999","description":"%s Hardware Signing File","path":"%s","type":"%sHWSigningFileShelley_ed25519"}\n'\'' "${hex}" "${role}" "${path}" "${role}" > "${argument}" ;;' \
    '  esac' \
    '  previous="${argument}"' \
    'done' \
    'if [[ "${scenario}" == direct-hardware-hardlink-output ]]; then target="${*: -1}"; rm -f -- "${target}"; printf '\''outside hardware signing file\n'\'' > "${outside}/escaped.hws"; chmod 0640 "${outside}/escaped.hws"; "${CNTOOLS_MS_REAL_LN:?}" -- "${outside}/escaped.hws" "${target}"; fi' \
    '[[ "${scenario}" != direct-hardware-command-failure ]] || { printf '\''RAW HW SECRET \033[31m\n'\'' >&2; exit 61; }' \
    > "${DIRECT_FAKE_BIN}/cardano-hw-cli"
  chmod 0755 "${DIRECT_FAKE_BIN}/cardano-hw-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'printf '\''jq'\'' >> "${CNTOOLS_MS_ARGV_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%s'\'' "${argument}" >> "${CNTOOLS_MS_ARGV_LOG}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_MS_ARGV_LOG}"' \
    'exec "${CNTOOLS_MS_REAL_JQ:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/jq"
  chmod 0755 "${DIRECT_FAKE_BIN}/jq"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MS_SCENARIO:?}" target="${*: -1}" marker="${CNTOOLS_MS_FAULT_MARKER:?}"' \
    'printf '\''ln'\'' >> "${CNTOOLS_MS_VECTOR_LOG:?}"; for argument in "$@"; do printf '\''\t%s'\'' "${argument}" >> "${CNTOOLS_MS_VECTOR_LOG}"; done; printf '\''\n'\'' >> "${CNTOOLS_MS_VECTOR_LOG}"' \
    'if [[ "${scenario}" == direct-lock-swap && ! -e "${marker}.lock" ]]; then' \
    '  : > "${marker}.lock"; lock="${CNTOOLS_MS_WALLET_ROOT}/.alpha.cntools-multisig-derive.lock"; "${CNTOOLS_MS_REAL_MV:?}" -- "${lock}" "${lock}.captured" || exit $?; "${CNTOOLS_MS_REAL_MKDIR:?}" -m 0700 -- "${lock}" || exit $?' \
    'fi' \
    'case "${scenario}:${target##*/}" in' \
    '  direct-ln-created-nonzero:multisig-payment.vkey) "${CNTOOLS_MS_REAL_LN:?}" "$@" || exit $?; exit 71 ;;' \
    '  direct-publish-failure:multisig-stake.vkey) exit 72 ;;' \
    '  direct-signal-publish:multisig-payment.vkey) "${CNTOOLS_MS_REAL_LN:?}" "$@" || exit $?; kill -TERM "${PPID}"; exit 0 ;;' \
    '  direct-publish-collision:multisig-payment.vkey) printf '\''competitor\n'\'' > "${target}"; chmod 0600 "${target}"; exit 73 ;;' \
    'esac' \
    'exec "${CNTOOLS_MS_REAL_LN:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/ln"
  chmod 0755 "${DIRECT_FAKE_BIN}/ln"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MS_SCENARIO:?}" target="${*: -1}"' \
    'if [[ "${scenario}" == direct-signal-lock-mkdir && "${target}" == *.cntools-multisig-derive.lock ]]; then "${CNTOOLS_MS_REAL_MKDIR:?}" "$@" || exit $?; kill -TERM "${PPID}"; exit 0; fi' \
    'exec "${CNTOOLS_MS_REAL_MKDIR:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/mkdir"
  chmod 0755 "${DIRECT_FAKE_BIN}/mkdir"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MS_SCENARIO:?}" target="${*: -1}"' \
    'if [[ "${scenario}" == direct-postcommit-lock-release && "${target}" == *.cntools-multisig-derive.lock ]]; then exit 74; fi' \
    'exec "${CNTOOLS_MS_REAL_RMDIR:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/rmdir"
  chmod 0755 "${DIRECT_FAKE_BIN}/rmdir"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s\n'\'' "${0##*/}" >> "${CNTOOLS_MS_NETWORK_LOG:?}"' \
      'exit 97' > "${DIRECT_FAKE_BIN}/${command_name}"
    chmod 0755 "${DIRECT_FAKE_BIN}/${command_name}"
  done
}

write_direct_fake_commands

run_bound_public_case() (
  local case_root="${TEST_ROOT}/bound-public" runtime="" wallet_root=""
  local outside="" capture="" stdout_file="" action_stdout=""
  local stderr_file="" events="" vectors="" network="" argv_log=""
  local before="" after="" status=0

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
  argv_log="${capture}/argv"
  before="${capture}/before.wallet"
  after="${capture}/after.wallet"
  mkdir -p -- "${wallet_root}" "${outside}" "${runtime}/tmp" \
    "${runtime}/home" "${runtime}/pool" "${runtime}/asset" "${capture}"
  chmod 0755 "${wallet_root}"
  tree_snapshot "${wallet_root}" "${before}"
  : > "${events}"
  : > "${vectors}"
  : > "${network}"
  : > "${argv_log}"

  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_MS_SCENARIO=direct-select-cancel
    export CNTOOLS_MS_VECTOR_LOG="${vectors}"
    export CNTOOLS_MS_NETWORK_LOG="${network}"
    export CNTOOLS_MS_ARGV_LOG="${argv_log}"
    export CNTOOLS_MS_WALLET_ROOT="${wallet_root}"
    export CNTOOLS_MS_OUTSIDE="${outside}"
    export CNTOOLS_MS_PRIVATE_ROOT="${runtime}/tmp"
    export CNTOOLS_MS_FAULT_MARKER="${capture}/fault"
    CNTOOLS_MS_REAL_LN="$(type -P ln)"
    CNTOOLS_MS_REAL_MV="$(type -P mv)"
    CNTOOLS_MS_REAL_MKDIR="$(type -P mkdir)"
    CNTOOLS_MS_REAL_RMDIR="$(type -P rmdir)"
    CNTOOLS_MS_REAL_JQ="${REAL_JQ}"
    export CNTOOLS_MS_REAL_LN CNTOOLS_MS_REAL_MV CNTOOLS_MS_REAL_MKDIR
    export CNTOOLS_MS_REAL_RMDIR CNTOOLS_MS_REAL_JQ
    PATH="${DIRECT_FAKE_BIN}:${BASE_PATH}"
    export PATH
    HOME="${runtime}/home"
    NODE_HOME="${runtime}/home"
    TMP_DIR="${runtime}/tmp"
    WALLET_FOLDER="${wallet_root}"
    POOL_FOLDER="${runtime}/pool"
    ASSET_FOLDER="${runtime}/asset"
    BLOCKLOG_DB="${runtime}/absent.db"
    ADVANCED_MODE=true
    CNTOOLS_MODE=LIGHT
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=10.1.0
    NETWORK_NAME=Preview
    CURRENCY=off
    CCLI=cardano-cli
    WALLET_MULTISIG_PREFIX=multisig-
    WALLET_PAY_SK_FILENAME=payment.skey
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_STAKE_SK_FILENAME=stake.skey
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_HW_PAY_SK_FILENAME=payment.hwsfile
    WALLET_HW_STAKE_SK_FILENAME=stake.hwsfile
    WALLET_PAY_CRED_FILENAME=payment.cred
    WALLET_STAKE_CRED_FILENAME=stake.cred
    WALLET_DERIVATION_PATH_FILENAME=derivation.path
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${events}"
    SCENARIO=select-cancel
    DIRECT_ACTIVE=N
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
    CHOICES=(a s d h q)
    CHOICE_CURSOR=0
    unset wallet_name mnemonic acct_idx key_idx root_prv
    main
    exit 99
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == 0 ]] ||
    fail "bound public derive traversal returned ${status}"
  extract_between_markers "${stdout_file}" "${action_stdout}" \
    '__CNTOOLS_MULTISIG_DERIVE_BEGIN__' '__CNTOOLS_MULTISIG_DERIVE_END__'
  grep -Fq ' >> ADVANCED >> MULTISIG >> DERIVE KEYS' "${action_stdout}" ||
    fail 'bound public derive action header changed'
  [[ "$(grep -Fc 'action:compatibility-dispatch:advanced.multisig.derive-keys' \
        "${events}" || true)" == 1 &&
     "$(grep -Fc 'action:selectWallet:non-ms' "${events}" || true)" == 1 &&
     "$(grep -c '^action:waitToProceed$' "${events}" || true)" == 0 &&
     "$(grep -c '^menu:main:a$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:advanced:s$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:multisig:d$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:multisig:h$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:main:q$' "${events}" || true)" == 1 ]] ||
    fail 'bound public derive dispatch, wait, or navigation parity changed'
  [[ ! -s "${vectors}" && ! -s "${stderr_file}" && ! -s "${network}" ]] ||
    fail 'bound public derive invoked action tools, emitted stderr, or attempted network'
  [[ "$(grep -c $'^jq\t' "${argv_log}" || true)" == 13 &&
     "$(grep -Fc "${MODULE_SOURCE}" "${argv_log}" || true)" -gt 0 &&
     "$(grep -Fc '/context.json' "${argv_log}" || true)" -gt 0 &&
     "$(grep -Fc "${wallet_root}" "${argv_log}" || true)" == 0 ]] ||
    fail 'bound public derive dispatcher validation vector changed'
  tree_snapshot "${wallet_root}" "${after}"
  assert_files_equal "${after}" "${before}" \
    'bound public derive persistent wallet tree'
  [[ -z "$(find "${runtime}/tmp" -mindepth 1 -print -quit)" ]] ||
    fail 'bound public derive retained private bridge state'
)

run_bound_public_case

prepare_direct_wallet() {
  local scenario="$1" runtime="$2" wallet_root="$3" selected=""
  local outside="${runtime}/outside"

  selected="${wallet_root}/alpha"

  chmod 0755 "${wallet_root}"
  [[ "${scenario}" == direct-empty ]] && return 0
  mkdir -p -- "${selected}" "${outside}"
  chmod 0700 "${selected}"
  printf 'base wallet sentinel\n' > "${selected}/base.marker"
  chmod 0600 "${selected}/base.marker"
  case "${scenario}" in
    direct-existing)
      printf 'existing multisig key\n' > "${selected}/multisig-payment.skey"
      chmod 0600 "${selected}/multisig-payment.skey"
      ;;
    direct-wallet-symlink)
      mv -- "${selected}" "${outside}/alpha"
      ln -s -- "${outside}/alpha" "${selected}"
      ;;
    direct-base-symlink)
      mv -- "${selected}/base.marker" "${outside}/base.marker"
      ln -s -- "${outside}/base.marker" "${selected}/base.marker"
      ;;
    direct-base-hardlink)
      ln -- "${selected}/base.marker" "${outside}/base.link"
      ;;
    direct-special-leaf)
      mkfifo "${selected}/unsafe.pipe"
      ;;
    direct-root-mode)
      chmod 0777 "${wallet_root}"
      ;;
    direct-wallet-mode)
      chmod 0777 "${selected}"
      ;;
    direct-file-mode)
      chmod 0666 "${selected}/base.marker"
      ;;
    direct-saved-path|direct-hardware-saved)
      printf '1852H/1815H/7H/x/9\n' > "${selected}/derivation.path"
      chmod 0644 "${selected}/derivation.path"
      ;;
    direct-malformed-path)
      printf '1852H/1815H/999999999999999999H/x/../../escape\n' > "${selected}/derivation.path"
      chmod 0644 "${selected}/derivation.path"
      ;;
    direct-lock-contention)
      mkdir -m 0700 -- "${wallet_root}/.alpha.cntools-multisig-derive.lock"
      ;;
  esac
}

direct_expected_status() {
  case "$1" in
    direct-invalid-name|direct-wallet-symlink|direct-base-symlink|direct-base-hardlink|direct-special-leaf|direct-root-mode|direct-wallet-mode|direct-file-mode|direct-root-control|direct-malformed-path|direct-ccli-function-shadow|direct-wrong-role|direct-malformed-key|direct-symlink-output|direct-hardlink-output|direct-fifo-output|direct-evkey-hardlink-output|direct-credential-symlink-output|direct-credential-hardlink-output|direct-credential-control|direct-hardware-wrong-pair|direct-hardware-hardlink-output|direct-inventory-race|direct-base-tamper|direct-lock-swap|direct-publish-failure|direct-signal-lock-mkdir|direct-signal-derive|direct-signal-publish|direct-publish-collision)
      printf '70\n' ;;
    *) printf '0\n' ;;
  esac
}

direct_expected_waits() {
  case "$1" in
    direct-select-cancel|direct-invalid-name|direct-wallet-symlink|direct-base-symlink|direct-base-hardlink|direct-special-leaf|direct-root-mode|direct-wallet-mode|direct-file-mode|direct-root-control|direct-malformed-path|direct-ccli-function-shadow|direct-wrong-role|direct-malformed-key|direct-symlink-output|direct-hardlink-output|direct-fifo-output|direct-evkey-hardlink-output|direct-credential-symlink-output|direct-credential-hardlink-output|direct-credential-control|direct-hardware-wrong-pair|direct-hardware-hardlink-output|direct-inventory-race|direct-base-tamper|direct-lock-swap|direct-publish-failure|direct-signal-lock-mkdir|direct-signal-derive|direct-signal-publish|direct-publish-collision|direct-signal-commit-boundary)
      printf '0\n' ;;
    *) printf '1\n' ;;
  esac
}

assert_direct_success() {
  local scenario="$1" wallet_root="$2" source="$3" selected=""
  local leaf="" path_mode=600

  selected="${wallet_root}/alpha"

  for leaf in multisig-payment.vkey multisig-stake.vkey \
      multisig-payment.cred multisig-stake.cred; do
    [[ -f "${selected}/${leaf}" && ! -L "${selected}/${leaf}" &&
       "$(file_mode "${selected}/${leaf}")" == 600 ]] ||
      fail "${scenario} missing safe ${leaf}"
  done
  case "${source}" in
    cli|mnemonic)
      for leaf in multisig-payment.skey multisig-stake.skey; do
        [[ -f "${selected}/${leaf}" && ! -L "${selected}/${leaf}" &&
           "$(file_mode "${selected}/${leaf}")" == 600 ]] ||
          fail "${scenario} missing safe ${leaf}"
      done
      ;;
    hardware)
      for leaf in multisig-payment.hwsfile multisig-stake.hwsfile; do
        [[ -f "${selected}/${leaf}" && ! -L "${selected}/${leaf}" &&
           "$(file_mode "${selected}/${leaf}")" == 600 ]] ||
          fail "${scenario} missing safe ${leaf}"
      done
      [[ "$(jq -er '.description' "${selected}/multisig-payment.vkey")" == 'MultiSig Payment Hardware Verification Key' &&
         "$(jq -er '.description' "${selected}/multisig-stake.vkey")" == 'MultiSig Stake Hardware Verification Key' ]] ||
        fail "${scenario} hardware verification-key descriptions changed"
      ;;
  esac
  if [[ "${source}" == mnemonic || "${source}" == hardware ]]; then
    case "${scenario}" in
      direct-saved-path|direct-hardware-saved) path_mode=644 ;;
    esac
    [[ -f "${selected}/derivation.path" &&
       "$(file_mode "${selected}/derivation.path")" == "${path_mode}" ]] ||
      fail "${scenario} derivation path mode changed"
  fi
}

run_direct_case() {
  local scenario="$1" mode="$2" source="${3:-cli}" absolute_ccli="${4:-N}"
  local case_root="${TEST_ROOT}/direct-cases/${scenario}" runtime="" wallet_root=""
  local outside="" capture="" private="" context="" result=""
  local stdout_file="" stderr_file="" events="" vectors="" network=""
  local argv_log="" xtrace_log=""
  local before="" after="" expected_status="" expected_waits="" status=0 waits=0
  local ccli_value=cardano-cli stage_count=0 lock_count=0

  runtime="${case_root}/runtime"
  wallet_root="${runtime}/wallet"
  [[ "${scenario}" != direct-root-control ]] || wallet_root="${runtime}/wallet\\033[31mOWNED"
  outside="${runtime}/outside"
  capture="${case_root}/capture"
  private="${runtime}/private"
  context="${private}/context.json"
  result="${private}/result.json"
  stdout_file="${capture}/stdout"
  stderr_file="${capture}/stderr"
  events="${capture}/events"
  vectors="${capture}/vectors"
  network="${capture}/network"
  argv_log="${capture}/argv"
  xtrace_log="${capture}/xtrace"
  before="${capture}/before.tree"
  after="${capture}/after.tree"
  mkdir -p -- "${wallet_root}" "${outside}" "${capture}" "${private}" \
    "${runtime}/home" "${runtime}/pool" "${runtime}/asset" "${runtime}/tmp"
  chmod 0700 "${private}"
  prepare_direct_wallet "${scenario}" "${runtime}" "${wallet_root}"
  write_context "${context}" "${mode}" "${runtime}/home"
  chmod 0400 "${context}"
  tree_snapshot "${runtime}" "${before}" || fail "${scenario} direct pre-snapshot failed"
  : > "${events}"; : > "${vectors}"; : > "${network}"
  : > "${argv_log}"; : > "${xtrace_log}"
  expected_status="$(direct_expected_status "${scenario}")"
  expected_waits="$(direct_expected_waits "${scenario}")"
  [[ "${absolute_ccli}" != Y ]] || ccli_value="${DIRECT_FAKE_BIN}/cardano-cli"
  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_MS_SCENARIO="${scenario}"
    export CNTOOLS_MS_VECTOR_LOG="${vectors}"
    export CNTOOLS_MS_NETWORK_LOG="${network}"
    export CNTOOLS_MS_ARGV_LOG="${argv_log}"
    export CNTOOLS_MS_WALLET_ROOT="${wallet_root}"
    export CNTOOLS_MS_OUTSIDE="${outside}"
    export CNTOOLS_MS_PRIVATE_ROOT="${private}"
    export CNTOOLS_MS_FAULT_MARKER="${capture}/fault"
    CNTOOLS_MS_REAL_LN="$(type -P ln)"
    CNTOOLS_MS_REAL_MV="$(type -P mv)"
    CNTOOLS_MS_REAL_MKDIR="$(type -P mkdir)"
    CNTOOLS_MS_REAL_RMDIR="$(type -P rmdir)"
    CNTOOLS_MS_REAL_JQ="${REAL_JQ}"
    export CNTOOLS_MS_REAL_LN CNTOOLS_MS_REAL_MV CNTOOLS_MS_REAL_MKDIR CNTOOLS_MS_REAL_RMDIR CNTOOLS_MS_REAL_JQ
    PATH="${DIRECT_FAKE_BIN}:${BASE_PATH}"
    export PATH
    [[ "${scenario}" != direct-ccli-function-shadow ]] || cardano-cli() { return 0; }
    HOME="${runtime}/home"
    NODE_HOME="${runtime}/home"
    TMP_DIR="${runtime}/tmp"
    WALLET_FOLDER="${wallet_root}"
    POOL_FOLDER="${runtime}/pool"
    ASSET_FOLDER="${runtime}/asset"
    CNTOOLS_MODE="${mode}"
    CCLI="${ccli_value}"
    WALLET_MULTISIG_PREFIX=multisig-
    WALLET_PAY_SK_FILENAME=payment.skey
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_STAKE_SK_FILENAME=stake.skey
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_HW_PAY_SK_FILENAME=payment.hwsfile
    WALLET_HW_STAKE_SK_FILENAME=stake.hwsfile
    WALLET_PAY_CRED_FILENAME=payment.cred
    WALLET_STAKE_CRED_FILENAME=stake.cred
    WALLET_DERIVATION_PATH_FILENAME=derivation.path
    FG_RED="" FG_GREEN="" FG_YELLOW="" FG_LGRAY="" NC=""
    EVENT_LOG="${events}"
    SCENARIO="${scenario}"
    DIRECT_ACTIVE=Y
    DIRECT_SOURCE="${source}"
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
    unset wallet_name mnemonic acct_idx key_idx root_prv
    if [[ "${scenario}" == direct-signal-commit-boundary ]]; then
      CNTOOLS_MS_BOUNDARY_ARMED=Y
      _cntools_ms_commit_boundary_debug() {
        if [[ "${CNTOOLS_MS_BOUNDARY_ARMED:-N}" == Y &&
              "${BASH_COMMAND:-}" == "trap '_cntools_action_advanced_multisig_derive_keys_postcommit_signal' HUP INT TERM" ]]; then
          CNTOOLS_MS_BOUNDARY_ARMED=N
          trap - DEBUG
          builtin printf 'reached\n' > "${CNTOOLS_MS_FAULT_MARKER}.commit-boundary"
          builtin kill -TERM "${BASHPID}"
        fi
      }
      builtin set -T
      trap _cntools_ms_commit_boundary_debug DEBUG
    fi
    if [[ "${scenario}" == direct-mnemonic-xtrace ]]; then
      exec 9> "${xtrace_log}"
      BASH_XTRACEFD=9
      builtin set -x
    fi
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" "${context}" "${result}"
    direct_status=$?
    if [[ "${scenario}" == direct-mnemonic-xtrace ]]; then
      builtin set +x
      exec 9>&-
    fi
    [[ ! -e "${result}" && ! -L "${result}" ]] || exit 98
    exit "${direct_status}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} returned ${status}, expected ${expected_status}"
  waits="$(grep -c '^action:waitToProceed$' "${events}" || true)"
  [[ "${waits}" == "${expected_waits}" ]] ||
    fail "${scenario} waits ${waits}, expected ${expected_waits}"
  if [[ "${source}" == hardware ]]; then
    local version_line=0 unlock_line=0 command_line=0
    version_line="$(grep -n '^action:HWCLIversionCheck$' "${events}" | head -n 1 | cut -d: -f1 || true)"
    unlock_line="$(grep -n '^action:unlockHWDevice:extract MultiSig keys$' "${events}" | head -n 1 | cut -d: -f1 || true)"
    command_line="$(grep -n $'^cardano-hw-cli\taddress\tkey-gen\t' "${vectors}" | head -n 1 | cut -d: -f1 || true)"
    [[ "${version_line}" =~ ^[1-9][0-9]*$ ]] ||
      fail "${scenario} omitted hardware version gate"
    if [[ "${scenario}" != direct-hardware-version-failure ]]; then
      [[ "${unlock_line}" =~ ^[1-9][0-9]*$ &&
         "${version_line}" -lt "${unlock_line}" ]] ||
        fail "${scenario} hardware version/unlock gate order changed"
    fi
    if [[ "${expected_status}" == 0 &&
          "${scenario}" != direct-hardware-version-failure &&
          "${scenario}" != direct-hardware-unlock-failure ]]; then
      [[ "${command_line}" =~ ^[1-9][0-9]*$ ]] ||
        fail "${scenario} omitted hardware derivation command"
    fi
  fi
  [[ ! -s "${network}" ]] || fail "${scenario} attempted network"
  ! grep -Fq "${MNEMONIC}" "${argv_log}" "${xtrace_log}" ||
    fail "${scenario} exposed mnemonic through argv or xtrace"
  ! grep -Eq 'root_xsk_|payment_xsk_|stake_xsk_|5880[0-9a-fA-F]{192}' \
      "${argv_log}" "${xtrace_log}" ||
    fail "${scenario} exposed derived signing material through argv or xtrace"
  ! grep -Fq -- $'--arg\tcbor\t' "${argv_log}" ||
    fail "${scenario} passed private signing CBOR in jq argv"
  if [[ "${source}" == mnemonic &&
        -f "${wallet_root}/alpha/multisig-payment.skey" ]]; then
    grep -Fq -- $'--rawfile\tcbor\t' "${argv_log}" ||
      fail "${scenario} did not transport private signing CBOR by file"
  fi
  if [[ "${scenario}" == direct-mnemonic-xtrace ]]; then
    grep -Fq "+ println 'Wallet   : alpha'" "${xtrace_log}" ||
      fail 'mnemonic xtrace state was not restored after secret cleanup'
  fi
  ! grep -Fq "${MNEMONIC}" "${stdout_file}" "${stderr_file}" "${events}" "${vectors}" ||
    fail "${scenario} exposed mnemonic"
  ! grep -Fq 'RAW SECRET' "${stdout_file}" "${stderr_file}" ||
    fail "${scenario} reflected raw tool diagnostics"
  ! LC_ALL=C grep -q $'\033' "${stdout_file}" "${stderr_file}" ||
    fail "${scenario} emitted terminal control bytes"
  if [[ "${expected_status}" == 70 ]]; then
    grep -Fxq 'CNTools MultiSig key derivation action failed validation.' \
      "${stderr_file}" || fail "${scenario} fixed validation diagnostic changed"
  elif [[ "${scenario}" == direct-postcommit-lock-release ||
          "${scenario}" == direct-signal-commit-boundary ]]; then
    grep -Fxq 'WARNING: MultiSig keys were derived, but administrative cleanup needs attention.' \
      "${stderr_file}" || fail 'postcommit warning changed'
  else
    [[ ! -s "${stderr_file}" ]] || fail "${scenario} unexpected stderr"
  fi
  tree_snapshot "${runtime}" "${after}" || fail "${scenario} direct post-snapshot failed"
  case "${scenario}" in
    direct-success-*|direct-mnemonic-success|direct-mnemonic-xtrace|direct-hardware-success|direct-hardware-saved|direct-saved-path|direct-absolute-ccli|direct-ln-created-nonzero|direct-postcommit-lock-release)
      assert_direct_success "${scenario}" "${wallet_root}" "${source}"
      grep -Fq 'Wallet   : alpha' "${stdout_file}" || fail "${scenario} success output changed"
      grep -Fq 'Payment  : eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' "${stdout_file}" || fail "${scenario} payment credential changed"
      ;;
    direct-signal-commit-boundary)
      assert_direct_success "${scenario}" "${wallet_root}" "${source}"
      [[ -f "${capture}/fault.commit-boundary" ]] ||
        fail 'commit-boundary signal oracle did not reach the deferred window'
      ;;
    direct-inventory-race|direct-base-tamper|direct-publish-collision|direct-lock-swap)
      : ;;
    direct-symlink-output|direct-hardlink-output)
      [[ -f "${outside}/escaped.skey" && ! -L "${outside}/escaped.skey" &&
         "$(file_mode "${outside}/escaped.skey")" == 640 &&
         "$(< "${outside}/escaped.skey")" == 'outside secret' ]] ||
        fail "${scenario} escaped-secret residue contract changed"
      grep -v $'^f\toutside/escaped\.skey\t' "${after}" \
        > "${capture}/after.without-escaped-secret"
      assert_files_equal "${capture}/after.without-escaped-secret" "${before}" \
        "${scenario} contained mutation"
      ;;
    direct-evkey-hardlink-output)
      [[ -f "${outside}/escaped.evkey" && ! -L "${outside}/escaped.evkey" &&
         "$(file_mode "${outside}/escaped.evkey")" == 640 &&
         "$(< "${outside}/escaped.evkey")" == 'outside evkey' ]] ||
        fail "${scenario} mutated external evkey inode"
      grep -v $'^f\toutside/escaped\.evkey\t' "${after}" > "${capture}/after.filtered"
      assert_files_equal "${capture}/after.filtered" "${before}" "${scenario} contained mutation"
      ;;
    direct-credential-symlink-output|direct-credential-hardlink-output)
      [[ -f "${outside}/escaped.cred" && ! -L "${outside}/escaped.cred" &&
         "$(file_mode "${outside}/escaped.cred")" == 640 &&
         "$(< "${outside}/escaped.cred")" == 'outside credential' ]] ||
        fail "${scenario} mutated external credential inode"
      grep -v $'^f\toutside/escaped\.cred\t' "${after}" > "${capture}/after.filtered"
      assert_files_equal "${capture}/after.filtered" "${before}" "${scenario} contained mutation"
      ;;
    direct-hardware-hardlink-output)
      [[ -f "${outside}/escaped.hws" && ! -L "${outside}/escaped.hws" &&
         "$(file_mode "${outside}/escaped.hws")" == 640 &&
         "$(< "${outside}/escaped.hws")" == 'outside hardware signing file' ]] ||
        fail "${scenario} mutated external hardware inode"
      grep -v $'^f\toutside/escaped\.hws\t' "${after}" > "${capture}/after.filtered"
      assert_files_equal "${capture}/after.filtered" "${before}" "${scenario} contained mutation"
      ;;
    direct-lock-contention)
      assert_files_equal "${after}" "${before}" "${scenario} zero mutation" ;;
    *)
      assert_files_equal "${after}" "${before}" "${scenario} zero mutation" ;;
  esac
  stage_count="$(find "${wallet_root}" -mindepth 1 -maxdepth 1 -type d -name '.*.cntools-multisig-derive.stage.*' | wc -l | tr -d '[:space:]')"
  [[ "${stage_count}" == 0 ]] || fail "${scenario} left private stage"
  lock_count="$(find "${wallet_root}" -mindepth 1 -maxdepth 1 -type d -name '.*.cntools-multisig-derive.lock' | wc -l | tr -d '[:space:]')"
  case "${scenario}" in
    direct-lock-contention|direct-lock-swap|direct-postcommit-lock-release) : ;;
    *) [[ "${lock_count}" == 0 ]] || fail "${scenario} left operation lock" ;;
  esac
}

run_direct_case direct-empty OFFLINE
run_direct_case direct-select-failure LOCAL
run_direct_case direct-select-cancel LIGHT
run_direct_case direct-existing OFFLINE
run_direct_case direct-success-local LOCAL cli
run_direct_case direct-success-light LIGHT cli
run_direct_case direct-success-offline OFFLINE cli
run_direct_case direct-absolute-ccli OFFLINE cli Y
run_direct_case direct-mnemonic-success LIGHT mnemonic
run_direct_case direct-mnemonic-xtrace OFFLINE mnemonic
run_direct_case direct-saved-path OFFLINE mnemonic
run_direct_case direct-huge-index OFFLINE mnemonic
run_direct_case direct-mnemonic-word-count LIGHT mnemonic
run_direct_case direct-mnemonic-tool-failure OFFLINE mnemonic
run_direct_case direct-hardware-success OFFLINE hardware
run_direct_case direct-hardware-saved LIGHT hardware
run_direct_case direct-hardware-version-failure OFFLINE hardware
run_direct_case direct-hardware-unlock-failure LIGHT hardware
run_direct_case direct-hardware-command-failure LOCAL hardware
run_direct_case direct-invalid-name OFFLINE
run_direct_case direct-wallet-symlink OFFLINE
run_direct_case direct-base-symlink OFFLINE
run_direct_case direct-base-hardlink OFFLINE
run_direct_case direct-special-leaf OFFLINE
run_direct_case direct-root-mode OFFLINE
run_direct_case direct-wallet-mode OFFLINE
run_direct_case direct-file-mode OFFLINE
run_direct_case direct-root-control OFFLINE
run_direct_case direct-malformed-path OFFLINE mnemonic
run_direct_case direct-ccli-function-shadow OFFLINE
run_direct_case direct-cli-payment-failure OFFLINE
run_direct_case direct-cli-stake-failure OFFLINE
run_direct_case direct-wrong-role OFFLINE
run_direct_case direct-malformed-key OFFLINE
run_direct_case direct-symlink-output OFFLINE
run_direct_case direct-hardlink-output OFFLINE
run_direct_case direct-fifo-output OFFLINE
run_direct_case direct-evkey-hardlink-output OFFLINE mnemonic
run_direct_case direct-credential-failure OFFLINE
run_direct_case direct-credential-control OFFLINE
run_direct_case direct-credential-symlink-output OFFLINE
run_direct_case direct-credential-hardlink-output OFFLINE
run_direct_case direct-hardware-wrong-pair OFFLINE hardware
run_direct_case direct-hardware-hardlink-output OFFLINE hardware
run_direct_case direct-inventory-race OFFLINE
run_direct_case direct-base-tamper OFFLINE
run_direct_case direct-lock-contention OFFLINE
run_direct_case direct-lock-swap OFFLINE
run_direct_case direct-ln-created-nonzero OFFLINE
run_direct_case direct-publish-failure OFFLINE
run_direct_case direct-signal-lock-mkdir OFFLINE
run_direct_case direct-signal-derive OFFLINE
run_direct_case direct-signal-publish OFFLINE
run_direct_case direct-publish-collision OFFLINE
run_direct_case direct-signal-commit-boundary OFFLINE
run_direct_case direct-postcommit-lock-release OFFLINE

arity_root="${TEST_ROOT}/wrong-arity"
mkdir -p -- "${arity_root}/private" "${arity_root}/node"
chmod 0700 "${arity_root}/private"
write_context "${arity_root}/private/context.json" OFFLINE "${arity_root}/node"
if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
    "${arity_root}/private/context.json" "${arity_root}/private/result.json" \
    unexpected > "${arity_root}/stdout" 2> "${arity_root}/stderr"; then
  arity_status=0
else
  arity_status=$?
fi
[[ "${arity_status}" == 64 && ! -s "${arity_root}/stdout" &&
   ! -s "${arity_root}/stderr" ]] || fail 'wrong-arity contract changed'

derive_arm="${TEST_ROOT}/derive-arm"
awk '
  /^[[:space:]]+derive-ms-keys\)/ { capture=1 }
  capture { print }
  capture && /^[[:space:]]+;;/ { exit }
' "${CNTOOLS_SCRIPT}" > "${derive_arm}"
[[ "$(grep -Fc 'cntools_compatibility_dispatch_action advanced.multisig.derive-keys' \
      "${derive_arm}" || true)" == 1 ]] ||
  fail 'advanced.multisig.derive-keys public dispatch count changed'
grep -Fq '0) continue ;;' "${derive_arm}" ||
  fail 'advanced.multisig.derive-keys success mapping changed'
grep -Fq '20|21) break 2 ;;' "${derive_arm}" ||
  fail 'advanced.multisig.derive-keys parent mapping changed'
grep -Fq '22) myExit 0 "CNTools closed!" ;;' "${derive_arm}" ||
  fail 'advanced.multisig.derive-keys exit mapping changed'
grep -Fq '*) waitToProceed; continue ;;' "${derive_arm}" ||
  fail 'advanced.multisig.derive-keys failure mapping changed'
if grep -Eq 'getWalletType|HW_DERIVATION_CMD|cardano-address key child|ms_payment_sk_file|chmod 600' \
    "${derive_arm}"; then
  fail 'advanced.multisig.derive-keys inline implementation remains after binding'
fi
grep -Fq 'cntools_action_main()' "${ACTION_SOURCE}" ||
  fail 'advanced.multisig.derive-keys modular entrypoint changed'
! grep -Fq -- '--arg cbor' "${ACTION_SOURCE}" ||
  fail 'private signing CBOR returned to process argv'
grep -Fq -- '--rawfile cbor' "${ACTION_SOURCE}" ||
  fail 'private signing CBOR file transport is missing'
grep -Fq "trap '_cntools_action_advanced_multisig_derive_keys_defer_signal' HUP INT TERM" \
  "${ACTION_SOURCE}" || fail 'deferred commit-boundary signal authority is missing'
jq -e '.id == "advanced.multisig.derive-keys" and
  .executionRequirements.modes == ["local", "light", "offline"]' \
  "${MODULE_SOURCE}" >/dev/null || fail 'module mode contract changed'

printf 'CNTools multisig-derive-keys characterization passed: 30 frozen legacy records + 1 public + 56 direct cases\n'
