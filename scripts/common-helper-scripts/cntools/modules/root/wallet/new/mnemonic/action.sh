#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
# Stage 4 compatibility action for hardened mnemonic-wallet creation.
# Sourcing defines functions only. The compatibility dispatcher supplies an
# authenticated context and the inherited CNTools prompt/display helpers.

_cntools_action_wallet_new_mnemonic_validation_failure() {
  builtin printf '%s\n' \
    'CNTools mnemonic wallet creation action failed validation.' >&2
  return 70
}

_cntools_action_wallet_new_mnemonic_warning() {
  builtin printf '%s\n' \
    'WARNING: the mnemonic wallet was created, but final display was interrupted.' >&2
}

_cntools_action_wallet_new_mnemonic_name_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_wallet_new_mnemonic_index_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
  (( 10#${value} <= 2147483647 ))
}

_cntools_action_wallet_new_mnemonic_terminal_value_valid() {
  local value="${1:-}" maximum="${2:-}"

  [[ "${maximum}" =~ ^[1-9][0-9]*$ && -n "${value}" &&
     "${#value}" -le "${maximum}" &&
     ! "${value}" =~ [[:cntrl:]] && "${value}" != *\\* ]]
}

_cntools_action_wallet_new_mnemonic_address_valid() {
  local value="${1:-}" role="${2:-}" network="${3:-}" prefix=""

  _cntools_action_wallet_new_mnemonic_terminal_value_valid \
    "${value}" 512 || return 1
  case "${network}:${role}" in
    mainnet:base|mainnet:payment) prefix=addr1 ;;
    mainnet:reward) prefix=stake1 ;;
    testnet:base|testnet:payment) prefix=addr_test1 ;;
    testnet:reward) prefix=stake_test1 ;;
    *) return 1 ;;
  esac
  [[ "${value}" == "${prefix}"* ]] || return 1
  value="${value#"${prefix}"}"
  [[ "${#value}" -ge 20 && "${#value}" -le 500 &&
     "${value}" =~ ^[a-z0-9]+$ ]]
}

_cntools_action_wallet_new_mnemonic_publish_committed() {
  local address_network=testnet

  # This boundary depends on the phase helper guaranteeing that a successful
  # publication assigns all three validated addresses before it clears the
  # phrase/state pair, and that no mixed ordering is externally observable.
  # Binding remains blocked until the real helper proves that guarantee.
  [[ "${context_network:-}" == mainnet ]] && address_network=mainnet
  [[ -z "${wallet_new_mnemonic_phrase:-}" &&
     -z "${wallet_new_mnemonic_state:-}" ]] || return 1
  _cntools_action_wallet_new_mnemonic_address_valid \
    "${base_addr:-}" base "${address_network}" &&
  _cntools_action_wallet_new_mnemonic_address_valid \
    "${pay_addr:-}" payment "${address_network}" &&
  _cntools_action_wallet_new_mnemonic_address_valid \
    "${reward_addr:-}" reward "${address_network}" &&
  [[ "${base_addr}" != "${pay_addr}" &&
     "${base_addr}" != "${reward_addr}" &&
     "${pay_addr}" != "${reward_addr}" ]]
}

_cntools_action_wallet_new_mnemonic_prompt_name() {
  local output_variable="${1:-}" prompted="" prompt_status=0

  [[ "${output_variable}" == wallet_name ]] || return 70
  getAnswerAnyCust prompted \
    'Name of wallet (ASCII letters, numbers, underscore and hyphen only)' ||
    prompt_status=$?
  [[ "${prompt_status}" == 0 ]] || {
    [[ "${prompt_status}" == 1 ]] && return 1
    return 70
  }
  _cntools_action_wallet_new_mnemonic_name_valid "${prompted}" || {
    println ERROR 'ERROR: Invalid wallet name, please retry!'
    waitToProceed
    return 1
  }
  builtin printf -v "${output_variable}" '%s' "${prompted}"
}

_cntools_action_wallet_new_mnemonic_prompt_index() {
  local output_variable="${1:-}" prompt="${2:-}" prompted=""
  local prompt_status=0

  [[ "${output_variable}" == acct_idx ||
     "${output_variable}" == key_idx ]] || return 70
  getAnswerAnyCust prompted "${prompt}" || prompt_status=$?
  [[ "${prompt_status}" == 0 ]] || {
    [[ "${prompt_status}" == 1 ]] && return 1
    return 70
  }
  prompted="${prompted:-0}"
  _cntools_action_wallet_new_mnemonic_index_valid "${prompted}" || {
    println ERROR 'ERROR: Invalid derivation index, please retry!'
    waitToProceed
    return 1
  }
  builtin printf -v "${output_variable}" '%s' "${prompted}"
}

_cntools_action_wallet_new_mnemonic_phrase_parse() {
  local remaining="${wallet_new_mnemonic_phrase:-}" word=""

  wallet_new_mnemonic_words=()
  [[ -n "${remaining}" && "${#remaining}" -le 2048 &&
     "${remaining}" != ' '* && "${remaining}" != *' ' &&
     "${remaining}" != *'  '* && ! "${remaining}" =~ [[:cntrl:]] ]] ||
    return 1
  while [[ "${remaining}" == *' '* ]]; do
    word="${remaining%% *}"
    remaining="${remaining#* }"
    [[ "${word}" =~ ^[a-z]{1,32}$ ]] || return 1
    wallet_new_mnemonic_words+=("${word}")
  done
  [[ "${remaining}" =~ ^[a-z]{1,32}$ ]] || return 1
  wallet_new_mnemonic_words+=("${remaining}")
  (( ${#wallet_new_mnemonic_words[@]} == 15 ||
     ${#wallet_new_mnemonic_words[@]} == 24 ))
}

_cntools_action_wallet_new_mnemonic_phrase_display() {
  local word="" word_length=0 index=0

  for word in "${wallet_new_mnemonic_words[@]}"; do
    (( ${#word} <= word_length )) || word_length=${#word}
  done
  println DEBUG \
    "${FG_YELLOW}IMPORTANT!${NC} Please write down and store below words in a secure place to be able to restore wallet at a later time."
  for index in "${!wallet_new_mnemonic_words[@]}"; do
    builtin printf '%2s: %s%-*s%s  ' "$((index + 1))" \
      "${FG_GREEN}" "${word_length}" \
      "${wallet_new_mnemonic_words[index]}" "${NC}"
    (( (index + 1) % 4 != 0 )) || builtin printf '\n'
  done
  (( ${#wallet_new_mnemonic_words[@]} % 4 == 0 )) || builtin printf '\n'
}

_cntools_action_wallet_new_mnemonic_phrase_clear() {
  wallet_new_mnemonic_phrase=
  wallet_new_mnemonic_words=()
}

_cntools_action_wallet_new_mnemonic_secret_clear() {
  _cntools_action_wallet_new_mnemonic_phrase_clear
  wallet_new_mnemonic_state=
}

_cntools_action_wallet_new_mnemonic_defer_signal() {
  wallet_new_mnemonic_signal_pending=Y
}

_cntools_action_wallet_new_mnemonic_critical_enter() {
  wallet_new_mnemonic_critical_depth=$((
    ${wallet_new_mnemonic_critical_depth:-0} + 1))
  trap '_cntools_action_wallet_new_mnemonic_defer_signal' HUP INT TERM
}

_cntools_action_wallet_new_mnemonic_critical_leave() {
  (( ${wallet_new_mnemonic_critical_depth:-0} > 0 )) || return 70
  wallet_new_mnemonic_critical_depth=$((
    wallet_new_mnemonic_critical_depth - 1))
  (( wallet_new_mnemonic_critical_depth == 0 )) || return 0
  if [[ "${wallet_new_mnemonic_exit_active:-N}" == Y ||
        "${wallet_new_mnemonic_signal_handling:-N}" == Y ]]; then
    trap '' HUP INT TERM
    return 0
  fi
  trap '_cntools_action_wallet_new_mnemonic_signal' HUP INT TERM
  if [[ "${wallet_new_mnemonic_signal_pending:-N}" == Y ]]; then
    wallet_new_mnemonic_signal_pending=N
    _cntools_action_wallet_new_mnemonic_signal
  fi
}

_cntools_action_wallet_new_mnemonic_abort() {
  local abort_status=0

  [[ "${wallet_new_mnemonic_abort_active:-N}" != Y ]] || {
    wallet_new_mnemonic_signal_pending=Y
    return 70
  }
  wallet_new_mnemonic_abort_active=Y
  _cntools_action_wallet_new_mnemonic_critical_enter
  _cntools_compatibility_wallet_mnemonic_run abort \
    wallet_new_mnemonic_phrase wallet_new_mnemonic_state || abort_status=$?
  _cntools_action_wallet_new_mnemonic_phrase_clear
  if [[ "${abort_status}" == 0 &&
        -z "${wallet_new_mnemonic_state:-}" ]]; then
    _cntools_action_wallet_new_mnemonic_secret_clear
  else
    abort_status=70
  fi
  wallet_new_mnemonic_abort_active=N
  _cntools_action_wallet_new_mnemonic_critical_leave || abort_status=70
  [[ "${abort_status}" == 0 ]] || return 70
}

_cntools_action_wallet_new_mnemonic_phase_run() {
  local phase_status=0

  wallet_new_mnemonic_phase_active=Y
  _cntools_compatibility_wallet_mnemonic_run "$@" || phase_status=$?
  wallet_new_mnemonic_phase_active=N
  if [[ "${wallet_new_mnemonic_signal_pending:-N}" == Y ]]; then
    wallet_new_mnemonic_signal_pending=N
    _cntools_action_wallet_new_mnemonic_signal
  fi
  return "${phase_status}"
}

_cntools_action_wallet_new_mnemonic_exit() {
  local original_status=$? abort_status=0 attempt=0

  wallet_new_mnemonic_exit_active=Y
  trap '' HUP INT TERM
  if [[ "${wallet_new_mnemonic_committed:-N}" == Y ]] ||
     _cntools_action_wallet_new_mnemonic_publish_committed; then
    wallet_new_mnemonic_committed=Y
    _cntools_action_wallet_new_mnemonic_secret_clear
    trap - EXIT
    exit "${original_status}"
  fi
  abort_status=70
  while (( attempt < 2 )); do
    attempt=$((attempt + 1))
    abort_status=0
    _cntools_action_wallet_new_mnemonic_abort >/dev/null 2>&1 ||
      abort_status=$?
    [[ "${abort_status}" == 0 ]] && break
    [[ -n "${wallet_new_mnemonic_state:-}" ]] || break
  done
  if [[ "${abort_status}" == 0 ]]; then
    trap - EXIT HUP INT TERM
    exit "${original_status}"
  else
    _cntools_action_wallet_new_mnemonic_phrase_clear
  fi
  exit 70
}

_cntools_action_wallet_new_mnemonic_signal() {
  if [[ "${wallet_new_mnemonic_phase_active:-N}" == Y ||
        "${wallet_new_mnemonic_abort_active:-N}" == Y ||
        "${wallet_new_mnemonic_critical_depth:-0}" != 0 ]]; then
    wallet_new_mnemonic_signal_pending=Y
    return 0
  fi
  wallet_new_mnemonic_signal_handling=Y
  trap '' HUP INT TERM
  if [[ "${wallet_new_mnemonic_committed:-N}" == Y ]] ||
     _cntools_action_wallet_new_mnemonic_publish_committed; then
    wallet_new_mnemonic_committed=Y
    _cntools_action_wallet_new_mnemonic_secret_clear
    trap - EXIT
    _cntools_action_wallet_new_mnemonic_warning
    exit 0
  fi
  if _cntools_action_wallet_new_mnemonic_abort >/dev/null 2>&1; then
    trap - EXIT
  fi
  _cntools_action_wallet_new_mnemonic_validation_failure >/dev/null
  exit 70
}

_cntools_action_wallet_new_mnemonic_phase_failure() {
  local phase_status="${1:-}" abort_status=0 return_status=70

  _cntools_action_wallet_new_mnemonic_critical_enter
  _cntools_action_wallet_new_mnemonic_abort || abort_status=$?
  if [[ "${wallet_new_mnemonic_signal_pending:-N}" == Y ]]; then
    return_status=70
  elif [[ "${phase_status}" == 1 && "${abort_status}" == 0 ]]; then
    println ERROR 'ERROR: mnemonic wallet creation failed; no wallet was published.'
    waitToProceed
    return_status=0
  else
    _cntools_action_wallet_new_mnemonic_validation_failure
  fi
  _cntools_action_wallet_new_mnemonic_critical_leave || return_status=70
  if [[ "${abort_status}" == 0 ]]; then
    trap - EXIT HUP INT TERM
  else
    # Exit while the action's dynamically scoped state token is still alive;
    # the EXIT trap owns the authenticated retry.
    exit 70
  fi
  return "${return_status}"
}

_cntools_action_wallet_new_mnemonic_cancel() {
  local abort_status=0

  _cntools_action_wallet_new_mnemonic_critical_enter
  _cntools_action_wallet_new_mnemonic_abort || abort_status=$?
  [[ "${abort_status}" == 0 ]] ||
    _cntools_action_wallet_new_mnemonic_validation_failure
  _cntools_action_wallet_new_mnemonic_critical_leave || abort_status=70
  if [[ "${abort_status}" == 0 ]]; then
    trap - EXIT HUP INT TERM
    return 0
  fi
  # Do not unwind the main function and lose its private retry token.
  exit 70
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}"
  local context_mode="" context_network="" network_magic=""
  local private_parent="" action_status=0 choice_status=0
  local wallet_name="" acct_idx="" key_idx=""
  local wallet_new_mnemonic_phrase="" wallet_new_mnemonic_state=""
  local base_addr="" pay_addr="" reward_addr=""
  local wallet_new_mnemonic_committed=N wallet_new_mnemonic_phase_active=N
  local wallet_new_mnemonic_abort_active=N wallet_new_mnemonic_exit_active=N
  local wallet_new_mnemonic_signal_handling=N
  local wallet_new_mnemonic_signal_pending=N
  local wallet_new_mnemonic_postcommit_warning=N
  local wallet_new_mnemonic_critical_depth=0
  local -a wallet_new_mnemonic_words=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_private_parent_validate \
       >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_compatibility_wallet_mnemonic_run \
       >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F getAnswerAnyCust >/dev/null 2>&1 ||
     ! builtin declare -F select_opt >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F printWalletInfo >/dev/null 2>&1; then
    _cntools_action_wallet_new_mnemonic_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_wallet_new_mnemonic_validation_failure; return 70; }
  context_network="$(cntools_context_get "${context_file}" nodeNetwork)" || {
    _cntools_action_wallet_new_mnemonic_validation_failure; return 70; }
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" ]] || {
    _cntools_action_wallet_new_mnemonic_validation_failure; return 70; }
  case "${NETWORK_IDENTIFIER:-}" in
    --mainnet)
      [[ "${context_network}" == mainnet &&
         ( -z "${NWMAGIC+x}" || "${NWMAGIC}" == 764824073 ) ]] || {
        _cntools_action_wallet_new_mnemonic_validation_failure; return 70; }
      ;;
    --testnet-magic\ *)
      network_magic="${NETWORK_IDENTIFIER#--testnet-magic }"
      [[ "${context_network}" != mainnet &&
         "${network_magic}" =~ ^(0|[1-9][0-9]{0,9})$ &&
         "${network_magic}" -le 4294967295 &&
         ( -z "${NWMAGIC+x}" || "${NWMAGIC}" == "${network_magic}" ) ]] || {
        _cntools_action_wallet_new_mnemonic_validation_failure; return 70; }
      ;;
    *)
      _cntools_action_wallet_new_mnemonic_validation_failure
      return 70
      ;;
  esac
  private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${private_parent}" || {
    _cntools_action_wallet_new_mnemonic_validation_failure; return 70; }

  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> WALLET >> NEW >> MNEMONIC'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  builtin printf '\n'

  _cntools_action_wallet_new_mnemonic_prompt_name wallet_name ||
    choice_status=$?
  if [[ "${choice_status}" == 1 ]]; then
    return 0
  elif [[ "${choice_status}" != 0 ]]; then
    _cntools_action_wallet_new_mnemonic_validation_failure
    return 70
  fi
  println DEBUG \
    'Enter a custom account index to derive keys for (enter for default)'
  choice_status=0
  _cntools_action_wallet_new_mnemonic_prompt_index \
    acct_idx 'Account (default: 0)' || choice_status=$?
  if [[ "${choice_status}" == 1 ]]; then
    return 0
  elif [[ "${choice_status}" != 0 ]]; then
    _cntools_action_wallet_new_mnemonic_validation_failure
    return 70
  fi
  println DEBUG \
    $'\nEnter a custom key index to derive keys for (enter for default)'
  choice_status=0
  _cntools_action_wallet_new_mnemonic_prompt_index \
    key_idx 'Key index (default: 0)' || choice_status=$?
  if [[ "${choice_status}" == 1 ]]; then
    return 0
  elif [[ "${choice_status}" != 0 ]]; then
    _cntools_action_wallet_new_mnemonic_validation_failure
    return 70
  fi

  trap '_cntools_action_wallet_new_mnemonic_exit' EXIT
  trap '_cntools_action_wallet_new_mnemonic_signal' HUP INT TERM
  _cntools_action_wallet_new_mnemonic_phase_run prepare \
    wallet_new_mnemonic_phrase wallet_new_mnemonic_state \
    base_addr pay_addr reward_addr || action_status=$?
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_new_mnemonic_phase_failure "${action_status}"
    return $?
  fi
  if [[ -z "${wallet_new_mnemonic_state}" || -n "${base_addr}" ||
        -n "${pay_addr}" || -n "${reward_addr}" ]] ||
     ! _cntools_action_wallet_new_mnemonic_phrase_parse; then
    _cntools_action_wallet_new_mnemonic_phase_failure 70
    return $?
  fi

  builtin printf '\n'
  _cntools_action_wallet_new_mnemonic_phrase_display
  builtin printf '\n'
  println DEBUG \
    'Confirm only after the recovery phrase has been recorded in a secure place.'
  choice_status=0
  select_opt '[n] Not yet' \
    '[y] I have safely recorded the recovery phrase' '[Esc] Cancel' ||
    choice_status=$?
  if [[ "${choice_status}" == 0 || "${choice_status}" == 2 ]]; then
    _cntools_action_wallet_new_mnemonic_cancel
    return $?
  elif [[ "${choice_status}" != 1 ]]; then
    _cntools_action_wallet_new_mnemonic_phase_failure 70
    return $?
  fi

  action_status=0
  _cntools_action_wallet_new_mnemonic_phase_run acknowledge \
    wallet_new_mnemonic_phrase wallet_new_mnemonic_state || action_status=$?
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_new_mnemonic_phase_failure "${action_status}"
    return $?
  fi
  [[ -n "${wallet_new_mnemonic_phrase}" &&
     -n "${wallet_new_mnemonic_state}" ]] || {
    _cntools_action_wallet_new_mnemonic_phase_failure 70
    return $?
  }

  action_status=0
  _cntools_action_wallet_new_mnemonic_phase_run publish \
    wallet_new_mnemonic_phrase wallet_new_mnemonic_state \
    base_addr pay_addr reward_addr || action_status=$?
  if _cntools_action_wallet_new_mnemonic_publish_committed; then
    wallet_new_mnemonic_committed=Y
    [[ "${action_status}" == 0 ]] ||
      wallet_new_mnemonic_postcommit_warning=Y
  elif [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_new_mnemonic_phase_failure "${action_status}"
    return $?
  else
    _cntools_action_wallet_new_mnemonic_phase_failure 70
    return $?
  fi
  _cntools_action_wallet_new_mnemonic_phrase_clear
  trap - EXIT
  trap '_cntools_action_wallet_new_mnemonic_signal' HUP INT TERM

  if [[ "${wallet_new_mnemonic_postcommit_warning}" == Y ]]; then
    builtin printf '%s\n' \
      'WARNING: the mnemonic wallet was created despite an ambiguous helper return.' >&2
  fi

  builtin printf '\nWallet Imported : %s%s%s\n' \
    "${FG_GREEN}" "${wallet_name}" "${NC}"
  builtin printf 'Address         : %s%s%s\n' \
    "${FG_LGRAY}" "${base_addr}" "${NC}"
  builtin printf 'Payment Address : %s%s%s\n\n' \
    "${FG_LGRAY}" "${pay_addr}" "${NC}"
  printWalletInfo
  waitToProceed
  trap - HUP INT TERM
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  builtin printf '%s\n' \
    'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
