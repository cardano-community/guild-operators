#!/usr/bin/env bash
# Standard CIP-1852 mnemonic generation, parsing, and transactional wallet
# derivation through the pinned cardano-cli. Loaded after wallet-create.sh.
# shellcheck disable=SC2034,SC2178

declare -ag CNTOOLS_WALLET_MNEMONIC_TEMP_FILES=()
declare -g CNTOOLS_WALLET_MNEMONIC_ERROR=""
declare -g CNTOOLS_WALLET_MNEMONIC_ORIGIN=""
declare -g CNTOOLS_WALLET_MNEMONIC_ACCOUNT=""
declare -g CNTOOLS_WALLET_MNEMONIC_KEY_INDEX=""
# Y only when Cardano CLI rejected the phrase itself (an unknown word, a
# wrong word count or a bad checksum): Import asks for it again. Any other
# failure (a timeout, a CLI without the command) leaves it N and stops.
declare -g CNTOOLS_WALLET_MNEMONIC_PHRASE_REJECTED="N"
# BIP39 English word list, loaded on first use. WORDSET maps word → index.
CNTOOLS_WALLET_MNEMONIC_WORDLIST_FILE="${CNTOOLS_ROOT:-}/data/bip39-english.txt"
CNTOOLS_WALLET_MNEMONIC_WORDLIST_READY="N"
declare -ag CNTOOLS_WALLET_MNEMONIC_WORDLIST=()
declare -Ag CNTOOLS_WALLET_MNEMONIC_WORDSET=()

cntools_wallet_mnemonic_log() {
  cntools_log "${1:-INFO}" "${2:-}" || true
}

cntools_wallet_mnemonic_wordlist_load() {
  local _cntools_wordlist_file="${CNTOOLS_WALLET_MNEMONIC_WORDLIST_FILE:-}"
  local _cntools_wordlist_word=""
  local _cntools_wordlist_index=0

  [[ "${CNTOOLS_WALLET_MNEMONIC_WORDLIST_READY:-N}" != "Y" ]] || return 0
  CNTOOLS_WALLET_MNEMONIC_WORDLIST=()
  CNTOOLS_WALLET_MNEMONIC_WORDSET=()
  if [[ -z "${_cntools_wordlist_file}" ||
        "${_cntools_wordlist_file}" != /* ||
        ! -f "${_cntools_wordlist_file}" ||
        -L "${_cntools_wordlist_file}" ||
        ! -r "${_cntools_wordlist_file}" ]]; then
    cntools_wallet_mnemonic_log ERROR \
      "BIP39 English word list is missing or unsafe: ${_cntools_wordlist_file:-unset}"
    return 2
  fi
  mapfile -t CNTOOLS_WALLET_MNEMONIC_WORDLIST \
    < "${_cntools_wordlist_file}" || {
    CNTOOLS_WALLET_MNEMONIC_WORDLIST=()
    cntools_wallet_mnemonic_log ERROR \
      "BIP39 English word list could not be read"
    return 2
  }
  if (( ${#CNTOOLS_WALLET_MNEMONIC_WORDLIST[@]} != 2048 )) ||
     [[ "${CNTOOLS_WALLET_MNEMONIC_WORDLIST[0]:-}" != "abandon" ||
        "${CNTOOLS_WALLET_MNEMONIC_WORDLIST[2047]:-}" != "zoo" ]]; then
    CNTOOLS_WALLET_MNEMONIC_WORDLIST=()
    cntools_wallet_mnemonic_log ERROR \
      "BIP39 English word list failed inventory validation"
    return 2
  fi
  for _cntools_wordlist_word in \
      "${CNTOOLS_WALLET_MNEMONIC_WORDLIST[@]}"; do
    if [[ ! "${_cntools_wordlist_word}" =~ ^[a-z]+$ ||
          -n "${CNTOOLS_WALLET_MNEMONIC_WORDSET[${_cntools_wordlist_word}]+x}" ]]; then
      CNTOOLS_WALLET_MNEMONIC_WORDLIST=()
      CNTOOLS_WALLET_MNEMONIC_WORDSET=()
      cntools_wallet_mnemonic_log ERROR \
        "BIP39 English word list failed content validation"
      return 2
    fi
    CNTOOLS_WALLET_MNEMONIC_WORDSET["${_cntools_wordlist_word}"]="${_cntools_wordlist_index}"
    _cntools_wordlist_index=$((_cntools_wordlist_index + 1))
  done
  CNTOOLS_WALLET_MNEMONIC_WORDLIST_READY="Y"
  cntools_wallet_mnemonic_log INFO \
    "BIP39 English word list loaded words=2048"
}

# SHA-256 of stdin as 64 hex characters. Reads a pipe: secrets never reach
# argv or a temporary file.
cntools_wallet_mnemonic_sha256_stdin_into() {
  local _cntools_sha_output="${1:-}" _cntools_sha_digest=""
  [[ "${_cntools_sha_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_sha_ref="${_cntools_sha_output}"
  _cntools_sha_ref=""
  if command -v sha256sum >/dev/null 2>&1; then
    _cntools_sha_digest="$(sha256sum 2>/dev/null)" || return 2
  elif command -v shasum >/dev/null 2>&1; then
    _cntools_sha_digest="$(shasum -a 256 2>/dev/null)" || return 2
  else
    return 2
  fi
  _cntools_sha_digest="${_cntools_sha_digest:0:64}"
  [[ "${_cntools_sha_digest}" =~ ^[0-9a-f]{64}$ ]] || return 2
  _cntools_sha_ref="${_cntools_sha_digest}"
}

# BIP39 checksum check of a recovery phrase held in a word array (lower-case
# words, 12–24 of them). Shared by every phrase entry (Wallet, Governance
# Derive Keys, MultiSig) so a wrong word is caught before any derivation.
# Returns 0 valid, 1 checksum mismatch (CNTools keeps the words for a
# correction), 2 cannot be checked here (word list or SHA-256 tool missing,
# unknown word, unsupported length); Cardano CLI then still validates.
cntools_wallet_mnemonic_checksum_valid() {
  local -
  set +x # The phrase and its entropy never reach a trace.
  local _cntools_checksum_words_name="${1:-}"
  local _cntools_checksum_word=""
  local _cntools_checksum_bits=""
  local _cntools_checksum_format=""
  local _cntools_checksum_digest=""
  local _cntools_checksum_index=0
  local _cntools_checksum_bit=0
  local _cntools_checksum_count=0
  local _cntools_checksum_entropy=0
  local _cntools_checksum_size=0
  local _cntools_checksum_position=0
  local _cntools_checksum_status=0

  [[ "${_cntools_checksum_words_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_checksum_words_ref="${_cntools_checksum_words_name}"
  _cntools_checksum_count="${#_cntools_checksum_words_ref[@]}"
  cntools_wallet_mnemonic_word_count_valid "${_cntools_checksum_count}" || return 2
  cntools_wallet_mnemonic_wordlist_load || return 2
  for _cntools_checksum_word in "${_cntools_checksum_words_ref[@]}"; do
    [[ "${_cntools_checksum_word}" =~ ^[a-z]+$ &&
       -n "${CNTOOLS_WALLET_MNEMONIC_WORDSET[${_cntools_checksum_word}]+x}" ]] || return 2
    _cntools_checksum_index="${CNTOOLS_WALLET_MNEMONIC_WORDSET[${_cntools_checksum_word}]}"
    for ((_cntools_checksum_bit = 10; _cntools_checksum_bit >= 0; _cntools_checksum_bit--)); do
      _cntools_checksum_bits+=$(( (_cntools_checksum_index >> _cntools_checksum_bit) & 1 ))
    done
  done
  # 11 bits per word: ENT entropy bits followed by ENT/32 checksum bits.
  _cntools_checksum_entropy=$((_cntools_checksum_count * 11 * 32 / 33))
  _cntools_checksum_size=$((_cntools_checksum_entropy / 32))
  for ((_cntools_checksum_position = 0;
        _cntools_checksum_position < _cntools_checksum_entropy;
        _cntools_checksum_position += 8)); do
    printf -v _cntools_checksum_format '%s\\x%02x' "${_cntools_checksum_format}" \
      "$((2#${_cntools_checksum_bits:_cntools_checksum_position:8}))"
  done
  cntools_wallet_mnemonic_sha256_stdin_into _cntools_checksum_digest \
    < <(printf '%b' "${_cntools_checksum_format}") || _cntools_checksum_status=2
  if (( _cntools_checksum_status == 0 )) &&
     (( (16#${_cntools_checksum_digest:0:2} >> (8 - _cntools_checksum_size)) !=
        2#${_cntools_checksum_bits:_cntools_checksum_entropy:_cntools_checksum_size} )); then
    _cntools_checksum_status=1
  fi
  unset _cntools_checksum_bits _cntools_checksum_format _cntools_checksum_digest \
    _cntools_checksum_index _cntools_checksum_word
  return "${_cntools_checksum_status}"
}

# A Cardano CLI error file that reports a rejected recovery phrase (wording of
# cardano-cli 10.x/11.x). The file is read by grep, never logged or shown.
cntools_wallet_mnemonic_rejection_reported() {
  [[ -f "${1:-}" && ! -L "${1:-}" ]] || return 1
  grep -qiE 'invalid mnemonic|mnemonic sentence|entropy checksum|(memonic|mnemonic) dictionary|number of words' -- "$1" 2>/dev/null
}

# The first error line, only when it names none of the phrase words: CLI
# errors can echo recovery words, which must never reach a log or screen.
cntools_wallet_mnemonic_safe_detail_into() {
  local -
  set +x
  local _cntools_detail_output="${1:-}" _cntools_detail_file="${2:-}" _cntools_detail_phrase="${3:-}"
  local _cntools_detail_line="" _cntools_detail_words="" _cntools_detail_word=""
  [[ "${_cntools_detail_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_detail_ref="${_cntools_detail_output}"
  _cntools_detail_ref=""
  [[ -f "${_cntools_detail_file}" && ! -L "${_cntools_detail_file}" ]] || return 0
  _cntools_detail_line="$(grep -m 1 -v '^[[:space:]]*$' -- "${_cntools_detail_file}" 2>/dev/null)" || return 0
  _cntools_detail_line="${_cntools_detail_line:0:300}"
  _cntools_detail_words=" ${_cntools_detail_line,,} "
  _cntools_detail_words="${_cntools_detail_words//[^a-z]/ }"
  set -f
  for _cntools_detail_word in ${_cntools_detail_phrase,,}; do
    [[ "${_cntools_detail_words}" != *" ${_cntools_detail_word} "* ]] || return 0
  done
  if declare -F cntools_log_sanitize_line >/dev/null 2>&1; then
    _cntools_detail_line="$(cntools_log_sanitize_line "${_cntools_detail_line}")"
  fi
  _cntools_detail_ref="${_cntools_detail_line}"
}

cntools_wallet_mnemonic_set_error() {
  CNTOOLS_WALLET_MNEMONIC_ERROR="${1:-Mnemonic wallet creation failed.}"
  CNTOOLS_WALLET_CREATE_ERROR="${CNTOOLS_WALLET_MNEMONIC_ERROR}"
  cntools_wallet_mnemonic_log ERROR "${CNTOOLS_WALLET_MNEMONIC_ERROR}"
}

cntools_wallet_mnemonic_reset_result() {
  CNTOOLS_WALLET_MNEMONIC_ERROR=""
  CNTOOLS_WALLET_MNEMONIC_ORIGIN=""
  CNTOOLS_WALLET_MNEMONIC_ACCOUNT=""
  CNTOOLS_WALLET_MNEMONIC_KEY_INDEX=""
  CNTOOLS_WALLET_MNEMONIC_PHRASE_REJECTED="N"
  CNTOOLS_WALLET_CREATED_NAME=""
  CNTOOLS_WALLET_CREATED_DIRECTORY=""
  CNTOOLS_WALLET_CREATE_ERROR=""
  CNTOOLS_WALLET_CREATE_WARNING=""
  CNTOOLS_WALLET_CREATE_CLEANUP_WARNING=""
}

cntools_wallet_mnemonic_temp_file_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_label="${2:-operation}"
  local _cntools_directory="${CNTOOLS_TMP_DIR:-}"
  local _cntools_previous_umask=""
  local _cntools_file=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_label}" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  [[ -n "${_cntools_directory}" && "${_cntools_directory}" = /* &&
     -d "${_cntools_directory}" && ! -L "${_cntools_directory}" &&
     -O "${_cntools_directory}" && -w "${_cntools_directory}" &&
     -x "${_cntools_directory}" ]] || return 1
  _cntools_previous_umask="$(umask)"
  umask 077
  _cntools_file="$(mktemp \
    "${_cntools_directory}/.cntools-mnemonic-${_cntools_label}.XXXXXX")" || {
      umask "${_cntools_previous_umask}"
      return 1
    }
  umask "${_cntools_previous_umask}"
  if [[ ! -f "${_cntools_file}" || -L "${_cntools_file}" ||
        ! -O "${_cntools_file}" ]] ||
     ! chmod 0600 "${_cntools_file}"; then
    rm -f -- "${_cntools_file}" 2>/dev/null || true
    return 1
  fi
  CNTOOLS_WALLET_MNEMONIC_TEMP_FILES+=("${_cntools_file}")
  _cntools_output_ref="${_cntools_file}"
}

cntools_wallet_mnemonic_temp_remove() {
  local requested="${1:-}"
  local candidate=""
  local tracked="N"
  local -a remaining=()

  for candidate in "${CNTOOLS_WALLET_MNEMONIC_TEMP_FILES[@]}"; do
    if [[ "${candidate}" == "${requested}" ]]; then
      tracked="Y"
    else
      remaining+=("${candidate}")
    fi
  done
  [[ "${tracked}" == "Y" ]] || return 2
  if [[ -f "${requested}" && ! -L "${requested}" && -O "${requested}" ]]; then
    rm -f -- "${requested}" 2>/dev/null || return 1
  elif [[ -e "${requested}" || -L "${requested}" ]]; then
    return 1
  fi
  CNTOOLS_WALLET_MNEMONIC_TEMP_FILES=("${remaining[@]}")
}

cntools_wallet_mnemonic_cleanup() {
  local file=""

  for file in "${CNTOOLS_WALLET_MNEMONIC_TEMP_FILES[@]}"; do
    cntools_wallet_mnemonic_temp_remove "${file}" || true
  done
  CNTOOLS_WALLET_MNEMONIC_TEMP_FILES=()
}

cntools_wallet_mnemonic_word_count_valid() {
  case "${1:-}" in 12|15|18|21|24) return 0 ;; *) return 1 ;; esac
}

cntools_wallet_mnemonic_word_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_input="${2:-}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_input="${_cntools_input#"${_cntools_input%%[![:space:]]*}"}"
  _cntools_input="${_cntools_input%"${_cntools_input##*[![:space:]]}"}"
  [[ "${_cntools_input}" =~ ^[A-Za-z]+$ ]] || return 1
  _cntools_output_ref="${_cntools_input,,}"
}

cntools_wallet_mnemonic_words_into() {
  local -
  set +x
  local _cntools_output_name="${1:-}"
  local _cntools_phrase="${2:-}"
  local _cntools_expected="${3:-}"
  local _cntools_mnemonic_word=""
  local _cntools_mnemonic_cleaned=""
  local -a _cntools_mnemonic_parsed=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=()
  _cntools_mnemonic_cleaned="${_cntools_phrase//$'\r'/ }"
  _cntools_mnemonic_cleaned="${_cntools_mnemonic_cleaned//$'\n'/ }"
  # Split in memory: a here-string is a temporary file in Bash 4.4–5.0.
  set -f
  local IFS=$' \t'
  # shellcheck disable=SC2206 # Deliberate splitting with globbing disabled.
  _cntools_mnemonic_parsed=(${_cntools_mnemonic_cleaned})
  cntools_wallet_mnemonic_word_count_valid \
    "${#_cntools_mnemonic_parsed[@]}" || return 1
  [[ -z "${_cntools_expected}" ||
     "${#_cntools_mnemonic_parsed[@]}" == "${_cntools_expected}" ]] || return 1
  for _cntools_mnemonic_word in "${_cntools_mnemonic_parsed[@]}"; do
    [[ "${_cntools_mnemonic_word}" =~ ^[A-Za-z]+$ ]] || return 1
    _cntools_output_ref+=("${_cntools_mnemonic_word,,}")
  done
}

cntools_wallet_mnemonic_phrase_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_words_name="${2:-}"
  local _cntools_mnemonic_joined=""
  local _cntools_mnemonic_word=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_words_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  local -n _cntools_words_ref="${_cntools_words_name}"
  _cntools_output_ref=""
  cntools_wallet_mnemonic_word_count_valid "${#_cntools_words_ref[@]}" ||
    return 1
  for _cntools_mnemonic_word in "${_cntools_words_ref[@]}"; do
    [[ "${_cntools_mnemonic_word}" =~ ^[a-z]+$ ]] || return 1
    [[ -z "${_cntools_mnemonic_joined}" ]] || _cntools_mnemonic_joined+=" "
    _cntools_mnemonic_joined+="${_cntools_mnemonic_word}"
  done
  _cntools_output_ref="${_cntools_mnemonic_joined}"
}

cntools_wallet_mnemonic_index_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_input="${2:-}"
  local _cntools_mnemonic_index=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_input="${_cntools_input#"${_cntools_input%%[![:space:]]*}"}"
  _cntools_input="${_cntools_input%"${_cntools_input##*[![:space:]]}"}"
  [[ -n "${_cntools_input}" ]] || _cntools_input="0"
  [[ "${_cntools_input}" =~ ^[0-9]{1,10}$ ]] || return 1
  _cntools_mnemonic_index=$((10#${_cntools_input}))
  (( _cntools_mnemonic_index <= 2147483647 )) || return 1
  _cntools_output_ref="${_cntools_mnemonic_index}"
}

cntools_wallet_mnemonic_challenge_indices_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_word_count="${2:-}"
  local _cntools_wanted="${3:-4}"
  local _cntools_candidate=0
  local _cntools_existing=0
  local _cntools_position=0
  local _cntools_value=0
  local _cntools_duplicate="N"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_word_count}" =~ ^[1-9][0-9]*$ &&
     "${_cntools_wanted}" =~ ^[1-9][0-9]*$ &&
     ${_cntools_wanted} -le ${_cntools_word_count} ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=()
  while (( ${#_cntools_output_ref[@]} < _cntools_wanted )); do
    _cntools_candidate=$((RANDOM % _cntools_word_count))
    _cntools_duplicate="N"
    for _cntools_existing in "${_cntools_output_ref[@]}"; do
      [[ "${_cntools_existing}" != "${_cntools_candidate}" ]] ||
        _cntools_duplicate="Y"
    done
    [[ "${_cntools_duplicate}" == "N" ]] || continue
    _cntools_output_ref+=("${_cntools_candidate}")
  done
  # Sort four small integers without an external process.
  for ((_cntools_position = 1;
       _cntools_position < ${#_cntools_output_ref[@]};
       _cntools_position++)); do
    _cntools_value="${_cntools_output_ref[_cntools_position]}"
    _cntools_candidate="${_cntools_position}"
    while (( _cntools_candidate > 0 &&
             _cntools_output_ref[_cntools_candidate - 1] > _cntools_value )); do
      _cntools_output_ref[_cntools_candidate]="${_cntools_output_ref[_cntools_candidate - 1]}"
      _cntools_candidate=$((_cntools_candidate - 1))
    done
    _cntools_output_ref[_cntools_candidate]="${_cntools_value}"
  done
}

cntools_wallet_mnemonic_command_failure() {
  local context="${1:-Cardano CLI mnemonic operation failed}"
  local status="${2:-1}"
  local error_file="${3:-}"
  local detail=""

  if [[ "${status}" == "124" ]]; then
    detail="timed out after ${CNTOOLS_CLI_TIMEOUT:-10} seconds"
  elif [[ -f "${error_file}" && ! -L "${error_file}" ]]; then
    IFS= read -r detail < "${error_file}" || true
    detail="${detail:0:400}"
    detail="$(cntools_log_sanitize_line "${detail}")"
  fi
  cntools_wallet_mnemonic_log ERROR \
    "${context} status=${status}${detail:+: ${detail}}"
}

cntools_wallet_mnemonic_generate_into() {
  local -
  set +x # The generated phrase must never reach an xtrace log.
  local _cntools_output_name="${1:-}"
  local _cntools_error_file=""
  local _cntools_generated_raw=""
  local _cntools_normalized_result=""
  local _cntools_status=0
  local -a _cntools_generated_words=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_create_environment_ready || return 1
  cntools_wallet_mnemonic_temp_file_into \
    _cntools_error_file generate-error || {
      cntools_wallet_mnemonic_set_error \
        "A private mnemonic error file could not be created."
      return 1
    }
  if _cntools_generated_raw="$(cntools_run_command_timeout \
      "${CNTOOLS_CLI_TIMEOUT:-10}" 000000 -- \
      "${CNTOOLS_CLI}" latest key generate-mnemonic --size 24 \
      2> "${_cntools_error_file}")"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    cntools_wallet_mnemonic_command_failure \
      "Could not generate a recovery phrase" "${_cntools_status}" \
      "${_cntools_error_file}"
    cntools_wallet_mnemonic_temp_remove "${_cntools_error_file}" || true
    cntools_wallet_mnemonic_set_error \
      "Cardano CLI could not generate a 24-word recovery phrase."
    return 1
  fi
  cntools_wallet_mnemonic_temp_remove "${_cntools_error_file}" || true
  if ! cntools_wallet_mnemonic_words_into \
       _cntools_generated_words "${_cntools_generated_raw}" 24 ||
     ! cntools_wallet_mnemonic_phrase_into \
       _cntools_normalized_result _cntools_generated_words; then
    cntools_wallet_mnemonic_set_error \
      "Cardano CLI returned an invalid recovery phrase."
    return 1
  fi
  _cntools_output_ref="${_cntools_normalized_result}"
  unset _cntools_generated_raw _cntools_normalized_result \
    _cntools_generated_words
}

cntools_wallet_mnemonic_derive_role() {
  local -
  set +x # The phrase must never reach an xtrace log.
  local stage="${1:-}"
  local role="${2:-}"
  local account="${3:-}"
  local key_index="${4:-}"
  local phrase="${5:-}"
  local signing_file=""
  local selector=""
  local error_file=""
  local mask=""
  local status=0
  local signing_form=""
  local rejected="N"
  local detail=""
  local -a command=()

  # The flag describes this derivation only (callers such as Governance
  # Derive Keys call this directly, without a result reset).
  CNTOOLS_WALLET_MNEMONIC_PHRASE_REJECTED="N"
  cntools_wallet_create_stage_safe "${stage}" || return 1
  cntools_wallet_mnemonic_index_into account "${account}" || return 2
  cntools_wallet_mnemonic_index_into key_index "${key_index}" || return 2
  case "${role}" in
    payment)
      signing_file="${stage}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}"
      selector="--payment-key-with-number"
      ;;
    stake)
      signing_file="${stage}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"
      selector="--stake-key-with-number"
      ;;
    drep)
      [[ "${key_index}" == 0 ]] || return 2
      signing_file="${stage}/${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}"
      selector="--drep-key"
      ;;
    *) return 2 ;;
  esac
  [[ ! -e "${signing_file}" && ! -L "${signing_file}" ]] || return 1
  cntools_wallet_material_temp_file \
    error_file "${stage}" "derive-${role}-mnemonic-error" || return 1
  command=(
    "${CNTOOLS_CLI}" latest key derive-from-mnemonic
    --key-output-text-envelope
    "${selector}"
  )
  [[ "${role}" == drep ]] || command+=("${key_index}")
  command+=(
    --account-number "${account}"
    --mnemonic-from-interactive-prompt
    --signing-key-file "${signing_file}"
  )
  printf -v mask '%*s' "${#command[@]}" ''
  mask="${mask// /0}"
  # A pipe, not a here-string: Bash 4.4–5.0 back here-strings with a file.
  if cntools_run_command_timeout "${CNTOOLS_CLI_TIMEOUT:-10}" \
      "${mask}" -- "${command[@]}" \
      > /dev/null 2> "${error_file}" < <(printf '%s\n' "${phrase}"); then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    # Only a reported phrase problem is a rejection; a timeout or a CLI
    # without this command is not, and asking for the phrase again would loop.
    if (( status != 124 )) &&
       cntools_wallet_mnemonic_rejection_reported "${error_file}"; then
      rejected="Y"
    elif (( status != 124 )); then
      cntools_wallet_mnemonic_safe_detail_into detail "${error_file}" "${phrase}" || detail=""
    fi
    # Derivation errors can echo recovery words: the raw output is never logged.
    cntools_wallet_mnemonic_log ERROR \
      "Mnemonic ${role} derivation failed status=${status} phrase_rejected=${rejected}; secret-bearing output suppressed${detail:+; first line: ${detail}}"
    cntools_wallet_material_remove_temp "${error_file}" || true
    if (( status == 124 )); then
      cntools_wallet_mnemonic_set_error \
        "Cardano CLI timed out while deriving the ${role} key."
    elif [[ "${rejected}" == Y ]]; then
      CNTOOLS_WALLET_MNEMONIC_PHRASE_REJECTED="Y"
      cntools_wallet_mnemonic_set_error \
        "Cardano CLI rejected the recovery phrase (a wrong word or checksum)."
    else
      cntools_wallet_mnemonic_set_error \
        "Cardano CLI could not derive the ${role} key (status ${status})${detail:+: ${detail}}. Check that ${CNTOOLS_CLI##*/} supports key derive-from-mnemonic."
    fi
    unset phrase
    return 1
  fi
  unset phrase
  cntools_wallet_material_remove_temp "${error_file}" || true
  [[ -f "${signing_file}" && ! -L "${signing_file}" &&
     -O "${signing_file}" ]] && chmod 0600 "${signing_file}" || return 1
  if ! cntools_wallet_key_signing_type \
       "${role}" "${signing_file}" signing_form ||
     [[ "${signing_form}" != "extended" ]] ||
     ! cntools_wallet_key_extended_envelope_valid \
       "${signing_file}" "${role}" signing; then
    cntools_wallet_mnemonic_set_error \
      "Cardano CLI returned an invalid extended ${role} signing key."
    return 1
  fi
}

cntools_wallet_mnemonic_path_write() {
  local stage="${1:-}"
  local account="${2:-}"
  local key_index="${3:-}"
  local path_file=""

  cntools_wallet_create_stage_safe "${stage}" || return 1
  cntools_wallet_mnemonic_index_into account "${account}" || return 2
  cntools_wallet_mnemonic_index_into key_index "${key_index}" || return 2
  path_file="${stage}/${CNTOOLS_WALLET_DERIVATION_PATH_FILENAME}"
  [[ ! -e "${path_file}" && ! -L "${path_file}" ]] || return 1
  printf '1852H/1815H/%sH/x/%s\n' \
    "${account}" "${key_index}" > "${path_file}" || return 1
  chmod 0600 "${path_file}"
}

cntools_wallet_mnemonic_required_entries_valid() {
  local directory="${1:-}"
  local entry=""
  local name=""
  local mode=""
  local wallet_type=""
  local count=0
  local expected_count=10
  local -a entries=()
  local -a required=(
    "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}"
    "${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"
    "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"
    "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"
    "${CNTOOLS_WALLET_PAY_ADDR_FILENAME}"
    "${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}"
    "${CNTOOLS_WALLET_BASE_ADDR_FILENAME}"
    "${CNTOOLS_WALLET_PAY_CRED_FILENAME}"
    "${CNTOOLS_WALLET_STAKE_CRED_FILENAME}"
    "${CNTOOLS_WALLET_DERIVATION_PATH_FILENAME}"
  )

  cntools_wallet_directory_safe "${directory}" || return 1
  chmod 0700 -- "${directory}" || return 1
  for name in "${required[@]}"; do
    entry="${directory}/${name}"
    [[ -f "${entry}" && ! -L "${entry}" && -O "${entry}" ]] || return 1
    chmod 0600 -- "${entry}" || return 1
  done
  entries=(
    "${directory}"/*
    "${directory}"/.[!.]*
    "${directory}"/..?*
  )
  for entry in "${entries[@]}"; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    count=$((count + 1))
    name="${entry##*/}"
    case " ${required[*]} " in *" ${name} "*) ;; *) return 1 ;; esac
    cntools_wallet_create_mode_into mode "${entry}" || return 1
    [[ "${mode}" == "600" || "${mode}" == "0600" ]] || return 1
  done
  (( count == expected_count )) || return 1
  cntools_wallet_create_mode_into mode "${directory}" || return 1
  [[ "${mode}" == "700" || "${mode}" == "0700" ]] || return 1

  cntools_wallet_key_extended_envelope_valid \
    "${directory}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" payment signing &&
    cntools_wallet_key_extended_envelope_valid \
      "${directory}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" stake signing &&
    cntools_wallet_key_normal_envelope_valid \
      "${directory}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" \
      payment verification &&
    cntools_wallet_key_normal_envelope_valid \
      "${directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" \
      stake verification &&
    cntools_wallet_key_extended_pair_matches \
      "${directory}" payment \
      "${directory}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" \
      "${directory}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" &&
    cntools_wallet_key_extended_pair_matches \
      "${directory}" stake \
      "${directory}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" \
      "${directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" &&
    cntools_wallet_address_validate \
      "${directory}/${CNTOOLS_WALLET_PAY_ADDR_FILENAME}" payment &&
    cntools_wallet_address_validate \
      "${directory}/${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}" reward &&
    cntools_wallet_address_validate \
      "${directory}/${CNTOOLS_WALLET_BASE_ADDR_FILENAME}" base &&
    cntools_wallet_id_validate \
      "${directory}/${CNTOOLS_WALLET_PAY_CRED_FILENAME}" &&
    cntools_wallet_id_validate \
      "${directory}/${CNTOOLS_WALLET_STAKE_CRED_FILENAME}" &&
    cntools_wallet_derivation_path_valid "${directory}" || return 1
  wallet_type="$(cntools_wallet_type "${directory}")" || return 1
  [[ "${wallet_type}" == "Mnemonic" ]]
}

cntools_wallet_mnemonic_create() {
  local -
  set +x # The phrase must never reach an xtrace log.
  local name="${1:-}"
  local account_input="${2:-}"
  local key_index_input="${3:-}"
  local phrase="${4:-}"
  local origin="${5:-import}"
  local account=""
  local key_index=""
  local normalized_phrase=""
  local target=""
  local stage=""
  local complete="N"
  local -a words=()

  cntools_wallet_mnemonic_reset_result
  case "${origin}" in new|import) ;; *) return 2 ;; esac
  cntools_wallet_create_name_valid "${name}" || {
    cntools_wallet_mnemonic_set_error \
      "Wallet names must use 1–64 ASCII letters, numbers, dots, underscores, or hyphens, and must start with a letter or number."
    return 2
  }
  cntools_wallet_mnemonic_index_into account "${account_input}" || {
    cntools_wallet_mnemonic_set_error \
      "The account number must be between 0 and 2,147,483,647."
    return 2
  }
  cntools_wallet_mnemonic_index_into key_index "${key_index_input}" || {
    cntools_wallet_mnemonic_set_error \
      "The key index must be between 0 and 2,147,483,647."
    return 2
  }
  if ! cntools_wallet_mnemonic_words_into words "${phrase}" ||
     ! cntools_wallet_mnemonic_phrase_into normalized_phrase words; then
    cntools_wallet_mnemonic_set_error \
      "Enter a valid 12, 15, 18, 21, or 24-word recovery phrase."
    return 2
  fi
  cntools_wallet_create_environment_ready || return 1
  cntools_wallet_create_root_prepare || return 1
  cntools_wallet_create_target_into target "${name}" || return 2
  if [[ -e "${target}" || -L "${target}" ]]; then
    cntools_wallet_mnemonic_set_error \
      "A wallet or filesystem entry named ${name} already exists."
    return 1
  fi
  cntools_wallet_create_stage_into stage || {
    cntools_wallet_mnemonic_set_error \
      "A private staging directory could not be created."
    return 1
  }
  cntools_wallet_mnemonic_log WALLET \
    "creating wallet=${name} type=Mnemonic source=${origin} network=${CNTOOLS_NETWORK} account=${account} key_index=${key_index} words=${#words[@]}"
  if ! cntools_wallet_mnemonic_derive_role \
      "${stage}" payment "${account}" "${key_index}" "${normalized_phrase}"; then
    : # The command helper already recorded a focused error.
  elif ! cntools_wallet_mnemonic_derive_role \
      "${stage}" stake "${account}" "${key_index}" "${normalized_phrase}"; then
    : # The command helper already recorded a focused error.
  elif ! cntools_wallet_mnemonic_path_write \
      "${stage}" "${account}" "${key_index}"; then
    cntools_wallet_mnemonic_set_error \
      "The mnemonic derivation path could not be recorded safely."
  elif ! cntools_wallet_materialize_wallet "${stage}"; then
    cntools_wallet_mnemonic_set_error \
      "The public keys, addresses, or credentials could not be derived from the mnemonic signing keys."
  elif ! cntools_wallet_mnemonic_required_entries_valid "${stage}"; then
    cntools_wallet_mnemonic_set_error \
      "The derived mnemonic wallet did not pass complete artifact validation."
  else
    complete="Y"
  fi
  if [[ "${complete}" != "Y" ]]; then
    [[ -n "${CNTOOLS_WALLET_MNEMONIC_ERROR}" ]] ||
      cntools_wallet_mnemonic_set_error "Mnemonic wallet creation failed."
    cntools_wallet_material_cleanup
    cntools_wallet_create_remove_stage "${stage}" || true
    [[ -z "${CNTOOLS_WALLET_CREATE_CLEANUP_WARNING}" ]] ||
      CNTOOLS_WALLET_MNEMONIC_ERROR+=" ${CNTOOLS_WALLET_CREATE_CLEANUP_WARNING}"
    CNTOOLS_WALLET_CREATE_ERROR="${CNTOOLS_WALLET_MNEMONIC_ERROR}"
    unset normalized_phrase phrase words
    return 1
  fi
  if ! cntools_wallet_create_publish \
      "${stage}" "${target}" \
      cntools_wallet_mnemonic_required_entries_valid; then
    cntools_wallet_material_cleanup
    cntools_wallet_create_remove_stage "${stage}" || true
    [[ -n "${CNTOOLS_WALLET_CREATE_ERROR}" ]] &&
      CNTOOLS_WALLET_MNEMONIC_ERROR="${CNTOOLS_WALLET_CREATE_ERROR}"
    unset normalized_phrase phrase words
    return 1
  fi
  CNTOOLS_WALLET_CREATED_NAME="${name}"
  CNTOOLS_WALLET_CREATED_DIRECTORY="${target}"
  CNTOOLS_WALLET_MNEMONIC_ORIGIN="${origin}"
  CNTOOLS_WALLET_MNEMONIC_ACCOUNT="${account}"
  CNTOOLS_WALLET_MNEMONIC_KEY_INDEX="${key_index}"
  cntools_wallet_mnemonic_log WALLET \
    "created wallet=${name} type=Mnemonic source=${origin} network=${CNTOOLS_NETWORK} account=${account} key_index=${key_index}"
  unset normalized_phrase phrase words
}
