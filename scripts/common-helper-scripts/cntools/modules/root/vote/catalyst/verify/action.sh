#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2154
# Stage 4 compatibility action for Catalyst registration verification.
# Sourcing defines functions only; the dispatcher supplies the authenticated
# context plus inherited legacy display, selection, wallet, and format helpers.

_cntools_action_vote_catalyst_verify_validation_failure() {
  builtin printf '%s\n' \
    'CNTools Catalyst verification action failed validation.' >&2
  return 70
}

_cntools_action_vote_catalyst_verify_cleanup() {
  local cleanup_target=""

  trap - EXIT HUP INT TERM
  for cleanup_target in \
      "${catalyst_voter_response_file:-}" \
      "${catalyst_delegation_response_file:-}"; do
    [[ -n "${cleanup_target}" ]] || continue
    if [[ -e "${cleanup_target}" || -L "${cleanup_target}" ]]; then
      "${catalyst_rm_path}" -f -- "${cleanup_target}" >/dev/null 2>&1 ||
        return 1
    fi
  done
}

_cntools_action_vote_catalyst_verify_file_size() {
  local target="${1:-}"
  local file_size=""

  [[ -n "${target}" ]] || return 1
  file_size="$("${catalyst_wc_path}" -c < "${target}" 2>/dev/null)" ||
    return 1
  file_size="${file_size//[[:space:]]/}"
  [[ "${file_size}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${file_size}"
}

_cntools_action_vote_catalyst_verify_private_file_create() {
  local response_kind="${1:-}"
  local target_variable="${2:-}"
  local created_file="" metadata="" owner="" mode="" links="" size=""

  [[ "${response_kind}" == "voter" ||
     "${response_kind}" == "delegation" ]] || return 1
  [[ "${target_variable}" == "catalyst_voter_response_file" ||
     "${target_variable}" == "catalyst_delegation_response_file" ]] ||
    return 1
  created_file="$("${catalyst_mktemp_path}" \
    "${catalyst_private_parent%/}/catalyst-${response_kind}.XXXXXXXX")" ||
    return 1
  printf -v "${target_variable}" '%s' "${created_file}"
  [[ "${created_file%/*}" == "${catalyst_private_parent}" &&
     "${created_file##*/}" =~ ^catalyst-(voter|delegation)\.[A-Za-z0-9]{8}$ &&
     -f "${created_file}" && ! -L "${created_file}" ]] || return 1
  "${catalyst_chmod_path}" 0600 "${created_file}" || return 1
  metadata="$(_cntools_result_stat "${created_file}")" || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  [[ "${owner}" == "${EUID}" &&
     ( "${mode}" == "600" || "${mode}" == "0600" ) &&
     "${links}" == "1" && "${size}" == "0" ]]
}

_cntools_action_vote_catalyst_verify_fetch() {
  local url="${1:-}"
  local limit="${2:-}"
  local target="${3:-}"
  local curl_status=0 file_size=""
  local -a curl_command=()

  [[ "${url}" == https://* &&
     ( "${limit}" == "262144" || "${limit}" == "65536" ) &&
     -f "${target}" && ! -L "${target}" ]] || return 70
  curl_command=(
    "${catalyst_curl_path}"
    --disable
    --silent
    --location
    --max-redirs 3
    --proto '=https'
    --proto-redir '=https'
    --max-time "${catalyst_curl_timeout}"
    --fail
    --max-filesize "${limit}"
    --header 'Accept: application/json'
    --output "${target}"
    --url "${url}"
  )
  println ACTION "${curl_command[*]}"
  if "${curl_command[@]}" 2>/dev/null; then
    curl_status=0
  else
    curl_status=$?
  fi
  file_size="$(_cntools_action_vote_catalyst_verify_file_size "${target}")" || return 70
  if [[ "${curl_status}" == "63" || "${file_size}" -gt "${limit}" ]]; then
    return 63
  fi
  [[ "${curl_status}" == "0" ]] || return 1
  return 0
}

_cntools_action_vote_catalyst_verify_voter_kind() {
  local response_file="${1:-}"

  "${catalyst_jq_path}" -er '
    def safe_error:
      type == "string" and
      (length >= 1 and length <= 160) and
      (explode | all(. >= 32 and . <= 126 and . != 92));
    def bounded_integer:
      type == "number" and floor == . and . >= 0 and . <= 45000000000000000;
    def valid_timestamp:
      . as $timestamp |
      type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      ((try (fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ"))
        catch "") == $timestamp);
    if type == "object" and keys == ["error"] and (.error | safe_error)
    then "error"
    elif
      type == "object" and keys == ["final", "last_updated", "voter_info"] and
      (.last_updated | valid_timestamp) and
      (.final | type == "boolean") and
      (.voter_info | type == "object" and
        keys == ["delegations_count", "delegator_addresses", "voting_power"] and
        (.voting_power | bounded_integer) and
        (.delegations_count | bounded_integer and . <= 100) and
        (.delegator_addresses | type == "array") and
        (.delegations_count == (.delegator_addresses | length)) and
        (.delegator_addresses |
          all(.[]; type == "string" and test("^0x[0-9A-Fa-f]{64}$"))) and
        (.delegator_addresses | map(ascii_downcase) | length) ==
          (.delegator_addresses | map(ascii_downcase) | unique | length))
    then "registered"
    else error("invalid Catalyst voter response")
    end
  ' "${response_file}" 2>/dev/null
}

_cntools_action_vote_catalyst_verify_delegation_valid() {
  local response_file="${1:-}"

  "${catalyst_jq_path}" -e '
    def bounded_integer:
      type == "number" and floor == . and . >= 0 and . <= 45000000000000000;
    type == "object" and
    keys == ["raw_power", "reward_address", "reward_payable"] and
    (.reward_address | type == "string" and
      test("^[A-Za-z0-9:_-]{1,256}$")) and
    (.reward_payable | type == "boolean") and
    (.raw_power | bounded_integer)
  ' "${response_file}" >/dev/null 2>&1
}

cntools_action_main() {
  local context_file="${1:-}"
  local result_file="${2:-}"
  local context_mode="" context_network="" api_authority=""
  local vote_key_hex="" catalyst_vk_file="" catalyst_cbor_hex=""
  local wallet_root_physical="" wallet_directory_physical=""
  local voter_status_url="" voter_kind="" safe_error=""
  local last_updated="" final="" voting_power=""
  local delegations_count="" pubkey_hex="" wallet_match=""
  local wallet_candidate="" delegation_wallet="" stake_addr=""
  local delegator_status_url="" reward_address="" reward_payable=""
  local raw_power="" final_color="" payable_color="" fetch_status=0
  local key_file_size="" cleanup_status=0
  local catalyst_jq_path="" catalyst_curl_path="" catalyst_mktemp_path=""
  local catalyst_chmod_path="" catalyst_rm_path="" catalyst_wc_path=""
  local catalyst_grep_path="" catalyst_curl_timeout=""
  local catalyst_api_base="" catalyst_private_parent=""
  local catalyst_voter_response_file=""
  local catalyst_delegation_response_file=""
  local -a delegator_addresses=() grep_command=() ccli_command=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64

  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F select_opt >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F selectWallet >/dev/null 2>&1 ||
     ! builtin declare -F getAnswerAnyCust >/dev/null 2>&1 ||
     ! builtin declare -F formatLovelace >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks \
       >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_stat >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_private_parent_validate \
       >/dev/null 2>&1; then
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_vote_catalyst_verify_validation_failure
    return 70
  }
  context_network="$(cntools_context_get "${context_file}" nodeNetwork)" || {
    _cntools_action_vote_catalyst_verify_validation_failure
    return 70
  }

  if [[ "${context_mode}" != "offline" &&
        "${context_network}" == "mainnet" ]]; then
    catalyst_jq_path="$(builtin type -P jq 2>/dev/null)" || {
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
    catalyst_curl_path="$(builtin type -P curl 2>/dev/null)" || {
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
    catalyst_mktemp_path="$(builtin type -P mktemp 2>/dev/null)" || {
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
    catalyst_chmod_path="$(builtin type -P chmod 2>/dev/null)" || {
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
    catalyst_rm_path="$(builtin type -P rm 2>/dev/null)" || {
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
    catalyst_wc_path="$(builtin type -P wc 2>/dev/null)" || {
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
    catalyst_grep_path="$(builtin type -P grep 2>/dev/null)" || {
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
    CCLI="$(builtin type -P "${CCLI:-}" 2>/dev/null)" || {
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
    [[ "${catalyst_jq_path}" == /* && -x "${catalyst_jq_path}" &&
       "${catalyst_curl_path}" == /* && -x "${catalyst_curl_path}" &&
       "${catalyst_mktemp_path}" == /* && -x "${catalyst_mktemp_path}" &&
       "${catalyst_chmod_path}" == /* && -x "${catalyst_chmod_path}" &&
       "${catalyst_rm_path}" == /* && -x "${catalyst_rm_path}" &&
       "${catalyst_wc_path}" == /* && -x "${catalyst_wc_path}" &&
       "${catalyst_grep_path}" == /* && -x "${catalyst_grep_path}" &&
       "${CCLI}" == /* && -x "${CCLI}" ]] || {
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
    catalyst_curl_timeout="${CURL_TIMEOUT:-}"
    [[ "${catalyst_curl_timeout}" =~ ^([1-9]|[1-9][0-9]|[12][0-9][0-9]|300)$ ]] || {
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
    catalyst_api_base="${CATALYST_API:-}"
    [[ "${#catalyst_api_base}" -ge 9 &&
       "${#catalyst_api_base}" -le 2048 &&
       "${catalyst_api_base}" == https://* &&
       "${catalyst_api_base}" != *'?'* &&
       "${catalyst_api_base}" != *'#'* &&
       "${catalyst_api_base}" != *\\* &&
       ! "${catalyst_api_base}" =~ [[:cntrl:][:space:]] ]] || {
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
    catalyst_api_base="${catalyst_api_base%/}"
    api_authority="${catalyst_api_base#https://}"
    [[ -n "${api_authority}" && "${api_authority}" != /* ]] || {
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
    catalyst_private_parent="${result_file%/*}"
    if [[ -z "${catalyst_private_parent}" ]] ||
       ! _cntools_result_private_parent_validate \
         "${catalyst_private_parent}"; then
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    fi
  fi

  clear
  println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println " >> VOTE >> CATALYST >> VERIFY"
  println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  if [[ "${context_mode}" == "offline" ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
    waitToProceed
    return 0
  fi
  if [[ "${context_network}" != "mainnet" ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Catalyst registration verification only available for Mainnet at this time!"
    waitToProceed
    return 0
  fi

  umask 077
  catalyst_voter_response_file=""
  catalyst_delegation_response_file=""
  trap '_cntools_action_vote_catalyst_verify_cleanup' EXIT
  trap '_cntools_action_vote_catalyst_verify_cleanup; exit 70' HUP INT TERM

  println DEBUG "Select wallet or enter vote public key?"
  select_opt "[w] Wallet" "[p] Vote public key"
  case $? in
    0)
      println DEBUG "\nSelect a Catalyst registered wallet"
      selectWallet "none" "${WALLET_CATALYST_VK_FILENAME}"
      case $? in
        1)
          waitToProceed
          _cntools_action_vote_catalyst_verify_cleanup || return 70
          return 0
          ;;
        2)
          _cntools_action_vote_catalyst_verify_cleanup || return 70
          return 0
          ;;
      esac
      if [[ ! "${wallet_name}" =~ ^[A-Za-z0-9._+@:-]+$ ||
            "${wallet_name}" == "." || "${wallet_name}" == ".." ||
            "${wallet_name}" == *\\* ]]; then
        println ERROR "\n${FG_RED}ERROR${NC}: selected wallet has an invalid Catalyst verification key file!"
        waitToProceed
        _cntools_action_vote_catalyst_verify_cleanup || return 70
        return 0
      fi
      catalyst_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_CATALYST_VK_FILENAME}"
      wallet_root_physical="$(cd -P -- "${WALLET_FOLDER}" \
        >/dev/null 2>&1 && pwd -P)" || wallet_root_physical=""
      wallet_directory_physical="$(cd -P -- \
        "${WALLET_FOLDER}/${wallet_name}" >/dev/null 2>&1 && pwd -P)" ||
        wallet_directory_physical=""
      if [[ -z "${wallet_root_physical}" ||
            "${wallet_directory_physical}" != \
              "${wallet_root_physical}/${wallet_name}" ||
            ! -f "${catalyst_vk_file}" || -L "${catalyst_vk_file}" ]] ||
         ! _cntools_registry_path_has_no_symlinks "${catalyst_vk_file}"; then
        println ERROR "\n${FG_RED}ERROR${NC}: selected wallet has an invalid Catalyst verification key file!"
        waitToProceed
        _cntools_action_vote_catalyst_verify_cleanup || return 70
        return 0
      fi
      key_file_size="$(_cntools_action_vote_catalyst_verify_file_size \
        "${catalyst_vk_file}")" || key_file_size=""
      if [[ ! "${key_file_size}" =~ ^[0-9]+$ ||
            "${key_file_size}" -lt 1 || "${key_file_size}" -gt 16384 ]]; then
        println ERROR "\n${FG_RED}ERROR${NC}: selected wallet has an invalid Catalyst verification key file!"
        waitToProceed
        _cntools_action_vote_catalyst_verify_cleanup || return 70
        return 0
      fi
      catalyst_cbor_hex="$("${catalyst_jq_path}" -er \
        '.cborHex | select(type == "string")' \
        "${catalyst_vk_file}" 2>/dev/null)" || catalyst_cbor_hex=""
      if [[ ! "${catalyst_cbor_hex}" =~ ^5820[0-9A-Fa-f]{64}$ ]]; then
        println ERROR "\n${FG_RED}ERROR${NC}: selected wallet has an invalid Catalyst verification key file!"
        waitToProceed
        _cntools_action_vote_catalyst_verify_cleanup || return 70
        return 0
      fi
      vote_key_hex="${catalyst_cbor_hex:4}"
      ;;
    1)
      getAnswerAnyCust vote_key_hex "Enter public key"
      if [[ ! "${vote_key_hex}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
        println ERROR "\n${FG_RED}ERROR${NC}: invalid pub key, expected 64 characters! Supply public key in hex format without prefix (5820 or 0x)"
        waitToProceed
        _cntools_action_vote_catalyst_verify_cleanup || return 70
        return 0
      fi
      ;;
    *)
      _cntools_action_vote_catalyst_verify_cleanup || return 70
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
      ;;
  esac

  _cntools_action_vote_catalyst_verify_private_file_create voter \
    catalyst_voter_response_file || {
      _cntools_action_vote_catalyst_verify_cleanup || true
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
  voter_status_url="${catalyst_api_base}/registration/voter/0x${vote_key_hex}?with_delegators=true"
  if _cntools_action_vote_catalyst_verify_fetch "${voter_status_url}" 262144 \
      "${catalyst_voter_response_file}"; then
    fetch_status=0
  else
    fetch_status=$?
  fi
  case "${fetch_status}" in
    0) ;;
    63)
      println ERROR "\n${FG_RED}ERROR${NC}: Catalyst verification response exceeded the 262144-byte safety limit!"
      waitToProceed
      _cntools_action_vote_catalyst_verify_cleanup || return 70
      return 0
      ;;
    1)
      println ERROR "\n${FG_RED}ERROR${NC}: failure during Catalyst verification query!"
      waitToProceed
      _cntools_action_vote_catalyst_verify_cleanup || return 70
      return 0
      ;;
    *)
      _cntools_action_vote_catalyst_verify_cleanup || true
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
      ;;
  esac

  voter_kind="$(_cntools_action_vote_catalyst_verify_voter_kind \
    "${catalyst_voter_response_file}")" || voter_kind=""
  echo
  if [[ "${voter_kind}" == "error" ]]; then
    safe_error="$("${catalyst_jq_path}" -er '.error' \
      "${catalyst_voter_response_file}" 2>/dev/null)" || safe_error=""
    if [[ -z "${safe_error}" ]]; then
      println ERROR "${FG_RED}ERROR${NC}: Catalyst verification service returned an invalid response!"
    else
      println DEBUG "Status:           ${FG_YELLOW}${safe_error}${NC}"
    fi
    waitToProceed
    _cntools_action_vote_catalyst_verify_cleanup || return 70
    return 0
  fi
  if [[ "${voter_kind}" != "registered" ]]; then
    println ERROR "${FG_RED}ERROR${NC}: Catalyst verification service returned an invalid response!"
    waitToProceed
    _cntools_action_vote_catalyst_verify_cleanup || return 70
    return 0
  fi

  last_updated="$("${catalyst_jq_path}" -er \
    '.last_updated | fromdateiso8601 | strftime("%Y-%m-%d %H:%M:%S UTC")' \
    "${catalyst_voter_response_file}" 2>/dev/null)" || {
      _cntools_action_vote_catalyst_verify_cleanup || true
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
  final="$("${catalyst_jq_path}" -er '.final | tostring' \
    "${catalyst_voter_response_file}" 2>/dev/null)" || {
      _cntools_action_vote_catalyst_verify_cleanup || true
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
  voting_power="$("${catalyst_jq_path}" -er '.voter_info.voting_power' \
    "${catalyst_voter_response_file}" 2>/dev/null)" || {
      _cntools_action_vote_catalyst_verify_cleanup || true
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
  delegations_count="$("${catalyst_jq_path}" -er \
    '.voter_info.delegations_count' \
    "${catalyst_voter_response_file}" 2>/dev/null)" || {
      _cntools_action_vote_catalyst_verify_cleanup || true
      _cntools_action_vote_catalyst_verify_validation_failure
      return 70
    }
  mapfile -t delegator_addresses < <("${catalyst_jq_path}" -er \
    '.voter_info.delegator_addresses[]' \
    "${catalyst_voter_response_file}" 2>/dev/null)

  final_color=$([[ "${final}" == "false" ]] &&
    echo "${FG_YELLOW}" || echo "${FG_GREEN}")
  println DEBUG "Status:           ${FG_GREEN}registered${NC}"
  println DEBUG "Last updated:     ${FG_LGRAY}${last_updated}${NC}"
  println DEBUG "Is Finalized:     ${final_color}${final}${NC}"
  println DEBUG "Voting power:     ${FG_LBLUE}$(formatLovelace "${voting_power}")${NC}"
  println DEBUG "Delegation count: ${FG_LBLUE}${delegations_count}${NC}"
  println DEBUG "\nDelegator list:"

  for pubkey_hex in "${delegator_addresses[@]}"; do
    echo
    wallet_match=""
    grep_command=(
      "${catalyst_grep_path}"
      --recursive
      --fixed-strings
      --
      "${pubkey_hex:2}"
      "${WALLET_FOLDER}"
    )
    while IFS= read -r wallet_candidate; do
      wallet_match="${wallet_candidate}"
      break
    done < <("${grep_command[@]}" 2>/dev/null)
    if [[ -n "${wallet_match}" ]]; then
      delegation_wallet="${wallet_match%/*}"
      println DEBUG "Wallet:           ${FG_GREEN}${delegation_wallet##*/}${NC}"
    fi

    ccli_command=(
      "${CCLI}"
      latest
      stake-address
      build
      --stake-verification-key "${pubkey_hex:2}"
      --mainnet
    )
    println ACTION "${ccli_command[*]}"
    if ! stake_addr="$("${ccli_command[@]}" 2>/dev/null)" ||
       [[ "${#stake_addr}" -gt 256 ||
          ! "${stake_addr}" =~ ^stake1[0-9a-z]+$ ]]; then
      println ERROR "${FG_RED}ERROR${NC}: failure during Catalyst stake address construction!"
      continue
    fi
    println DEBUG "Stake address:    ${FG_LGRAY}${stake_addr}${NC}"

    if [[ -n "${catalyst_delegation_response_file}" ]]; then
      "${catalyst_rm_path}" -f -- \
        "${catalyst_delegation_response_file}" >/dev/null 2>&1 || {
          _cntools_action_vote_catalyst_verify_cleanup || true
          _cntools_action_vote_catalyst_verify_validation_failure
          return 70
        }
      catalyst_delegation_response_file=""
    fi
    _cntools_action_vote_catalyst_verify_private_file_create delegation \
      catalyst_delegation_response_file || {
        _cntools_action_vote_catalyst_verify_cleanup || true
        _cntools_action_vote_catalyst_verify_validation_failure
        return 70
      }
    delegator_status_url="${catalyst_api_base}/registration/delegations/${pubkey_hex}"
    if _cntools_action_vote_catalyst_verify_fetch "${delegator_status_url}" 65536 \
        "${catalyst_delegation_response_file}"; then
      fetch_status=0
    else
      fetch_status=$?
    fi
    case "${fetch_status}" in
      0) ;;
      63)
        println ERROR "${FG_RED}ERROR${NC}: Catalyst delegation response exceeded the 65536-byte safety limit!"
        continue
        ;;
      1)
        println ERROR "${FG_RED}ERROR${NC}: failure during Catalyst delegation query!"
        continue
        ;;
      *)
        _cntools_action_vote_catalyst_verify_cleanup || true
        _cntools_action_vote_catalyst_verify_validation_failure
        return 70
        ;;
    esac
    if ! _cntools_action_vote_catalyst_verify_delegation_valid \
        "${catalyst_delegation_response_file}"; then
      println ERROR "${FG_RED}ERROR${NC}: Catalyst delegation service returned an invalid response!"
      continue
    fi
    reward_address="$("${catalyst_jq_path}" -er '.reward_address' \
      "${catalyst_delegation_response_file}" 2>/dev/null)" || {
        _cntools_action_vote_catalyst_verify_cleanup || true
        _cntools_action_vote_catalyst_verify_validation_failure
        return 70
      }
    reward_payable="$("${catalyst_jq_path}" -er '.reward_payable | tostring' \
      "${catalyst_delegation_response_file}" 2>/dev/null)" || {
        _cntools_action_vote_catalyst_verify_cleanup || true
        _cntools_action_vote_catalyst_verify_validation_failure
        return 70
      }
    raw_power="$("${catalyst_jq_path}" -er '.raw_power' \
      "${catalyst_delegation_response_file}" 2>/dev/null)" || {
        _cntools_action_vote_catalyst_verify_cleanup || true
        _cntools_action_vote_catalyst_verify_validation_failure
        return 70
      }
    payable_color=$([[ "${reward_payable}" == "false" ]] &&
      echo "${FG_YELLOW}" || echo "${FG_GREEN}")
    println DEBUG "Reward address:   ${FG_LGRAY}${reward_address}${NC}"
    println DEBUG "Reward payable:   ${payable_color}${reward_payable}${NC}"
    println DEBUG "Raw power:        ${FG_LBLUE}$(formatLovelace "${raw_power}")${NC}"
  done

  waitToProceed
  _cntools_action_vote_catalyst_verify_cleanup || cleanup_status=1
  [[ "${cleanup_status}" == "0" ]] || {
    _cntools_action_vote_catalyst_verify_validation_failure
    return 70
  }
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
