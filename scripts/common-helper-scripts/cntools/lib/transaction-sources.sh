#!/usr/bin/env bash
# Local wallet discovery never decrypts keys, repairs artifacts or trusts vkeys
# as proof of a signing source. Match the public ID derived from the source.
# shellcheck disable=SC2034
declare -ag CNTOOLS_TRANSACTION_LOCAL_FILES=() CNTOOLS_TRANSACTION_LOCAL_IDS=()
declare -ag CNTOOLS_TRANSACTION_LOCAL_KINDS=() CNTOOLS_TRANSACTION_LOCAL_TYPES=()
declare -Ag CNTOOLS_TRANSACTION_LOCAL_KEY_TYPES=() CNTOOLS_TRANSACTION_LOCAL_KEY_NAMES=()

cntools_transaction_source_type_into() {
  local output="$1" file="$2" envelope_type='' known_type=Unknown
  [[ "${output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  envelope_type="$(jq -er '.type | strings' "${file}" 2>/dev/null)" || return 1
  case "${envelope_type}" in
    Payment*) known_type=Payment ;;
    StakePool*) known_type='Pool cold' ;;
    Stake*) known_type=Stake ;;
    DRep*) known_type=DRep ;;
    ConstitutionalCommitteeCold*) known_type='Committee cold' ;;
    ConstitutionalCommitteeHot*) known_type='Committee hot' ;;
    GenesisDelegate*) known_type='Genesis delegate' ;;
    GenesisUTxO*) known_type='Genesis UTxO' ;;
    Genesis*) known_type=Genesis ;;
  esac
  printf -v "${output}" '%s' "${known_type}"
}

cntools_transaction_sources_collect() {
  local root="${CNTOOLS_WALLET_DIR:-}" directory='' file='' kind='' identity='' key_type='' wallet_name=''
  local previous_error="${CNTOOLS_TRANSACTION_ERROR:-}"
  local -A seen=()
  local -a configured_names=(
    "${CNTOOLS_WALLET_PAY_SKEY_FILENAME:-payment.skey}" "${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME:-payment.hwsfile}"
    "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME:-stake.skey}" "${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME:-stake.hwsfile}"
    "${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}" "${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}"
    "${CNTOOLS_WALLET_CC_COLD_SKEY_FILENAME:-cc-cold.skey}" "${CNTOOLS_WALLET_CC_HOT_SKEY_FILENAME:-cc-hot.skey}")
  local -a public_names=("${CNTOOLS_WALLET_PAY_VKEY_FILENAME:-payment.vkey}" "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME:-stake.vkey}"
    "${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}" "${CNTOOLS_WALLET_CC_COLD_VKEY_FILENAME:-cc-cold.vkey}"
    "${CNTOOLS_WALLET_CC_HOT_VKEY_FILENAME:-cc-hot.vkey}")
  CNTOOLS_TRANSACTION_LOCAL_FILES=(); CNTOOLS_TRANSACTION_LOCAL_IDS=()
  CNTOOLS_TRANSACTION_LOCAL_KINDS=(); CNTOOLS_TRANSACTION_LOCAL_TYPES=()
  CNTOOLS_TRANSACTION_LOCAL_KEY_TYPES=()
  CNTOOLS_TRANSACTION_LOCAL_KEY_NAMES=()
  [[ -n "${root}" && "${root}" == /* && "${root}" != / && -d "${root}" &&
     -r "${root}" && -x "${root}" ]] || return 0
  cntools_filesystem_path_components_safe "${root}" || return 0
  for directory in "${root}/"*; do
    cntools_transaction_directory_safe "${directory}" || continue
    wallet_name="${directory##*/}"
    # Top-level sources only. Do not traverse hidden staging/recovery folders,
    # import archives, or follow wallet/file symlinks.
    for file in "${directory}/"*.skey "${directory}/"*.hwsfile "${configured_names[@]/#/${directory}/}"; do
      [[ -z "${seen[${file}]:-}" ]] || continue
      seen["${file}"]=Y
      cntools_transaction_source_kind_into kind "${file}" || continue
      cntools_transaction_source_key_id_into identity "${file}" || continue
      cntools_transaction_source_type_into key_type "${file}" || continue
      CNTOOLS_TRANSACTION_LOCAL_FILES+=("${file}"); CNTOOLS_TRANSACTION_LOCAL_IDS+=("${identity}")
      CNTOOLS_TRANSACTION_LOCAL_KINDS+=("${kind}"); CNTOOLS_TRANSACTION_LOCAL_TYPES+=("${key_type}")
      CNTOOLS_TRANSACTION_LOCAL_KEY_TYPES["${identity}"]="${key_type}"
      [[ -n "${CNTOOLS_TRANSACTION_LOCAL_KEY_NAMES[${identity}]:-}" ]] || CNTOOLS_TRANSACTION_LOCAL_KEY_NAMES["${identity}"]="${wallet_name}"
    done
    for file in "${directory}/"*.vkey "${public_names[@]/#/${directory}/}"; do
      [[ -z "${seen[${file}]:-}" ]] || continue
      seen["${file}"]=Y
      cntools_transaction_key_id_from_verification_file_into identity "${file}" || continue
      cntools_transaction_source_type_into key_type "${file}" || continue
      # Public-only/encrypted wallets can identify the requested type, but
      # their public files never count as an available signing source.
      [[ -n "${CNTOOLS_TRANSACTION_LOCAL_KEY_TYPES[${identity}]:-}" ]] || CNTOOLS_TRANSACTION_LOCAL_KEY_TYPES["${identity}"]="${key_type}"
      [[ -n "${CNTOOLS_TRANSACTION_LOCAL_KEY_NAMES[${identity}]:-}" ]] || CNTOOLS_TRANSACTION_LOCAL_KEY_NAMES["${identity}"]="${wallet_name}"
    done
  done
  CNTOOLS_TRANSACTION_ERROR="${previous_error}"
  cntools_transaction_log CHOICE "Local wallet signing discovery sources=${#CNTOOLS_TRANSACTION_LOCAL_FILES[@]}"
}

cntools_transaction_ui_local_source_into() {
  local output="$1" expected="$2" labels="$3" preferred="$4" hardware_group="${5:-}" allow_defer="${6:-Y}"
  local index=0 selected='' selected_path='' key_type=Unknown signer_name=''
  local matching_types='' candidate='' wallet_name='' candidate_kind='' candidate_id='' found=N status=0
  local matching_names=''
  local -A matched_wallets=()
  local -a choices=() matched_files=()
  [[ "${output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "${expected}" =~ ^[0-9a-f]{64}$ ]] || return 2
  case "${preferred}" in cli|hardware|either) ;; *) return 2 ;; esac
  case "${allow_defer}" in Y|N) ;; *) return 2 ;; esac
  key_type="${CNTOOLS_TRANSACTION_LOCAL_KEY_TYPES[${expected}]:-Unknown}"
  for index in "${!CNTOOLS_TRANSACTION_LOCAL_FILES[@]}"; do
    [[ "${CNTOOLS_TRANSACTION_LOCAL_IDS[index]}" == "${expected}" ]] || continue
    [[ "${preferred}" == either || "${CNTOOLS_TRANSACTION_LOCAL_KINDS[index]}" == "${preferred}" ]] || continue
    candidate="${CNTOOLS_TRANSACTION_LOCAL_FILES[index]}"
    wallet_name="${candidate%/*}"; wallet_name="${wallet_name##*/}"
    choices+=("${wallet_name} · ${candidate##*/}")
    matched_files+=("${candidate}")
    if [[ -z "${matched_wallets[${wallet_name}]:-}" ]]; then
      matching_names+="${matching_names:+, }${wallet_name}"
      matched_wallets["${wallet_name}"]=Y
    fi
    key_type="${CNTOOLS_TRANSACTION_LOCAL_TYPES[index]}"
    [[ "${matching_types}" == *"${key_type}"* ]] || matching_types+="${matching_types:+, }${key_type}"
  done
  # Roles do not reliably identify a certificate/vote signer key type. Avoid
  # guessing from an imported label; use the verified local envelope if known.
  [[ -z "${matching_types}" ]] || key_type="${matching_types}"
  cntools_transaction_ui_signer_name_into signer_name "${expected}" "${labels}"
  [[ -z "${matching_names}" ]] || signer_name="${matching_names}"
  choices+=('Select file manually')
  if [[ "${allow_defer}" == Y ]]; then
    [[ -z "${hardware_group}" ]] && choices+=('Skip this signer') || choices+=('Defer this hardware session')
  fi
  choices+=(Cancel)
  local -n local_source_result="${output}"
  local_source_result=''
  while true; do
    cntools_gum_clear
    cntools_transaction_ui_sign_begin || return 2
    {
      cntools_table_pair Signer "${signer_name}" identifier
      cntools_table_pair 'Key type' "${key_type}" value
      cntools_table_pair 'Signing method' "${preferred}" accent
    } | cntools_table_render 'Required signer' || return 2
    if (( ${#matched_files[@]} == 0 )); then
      cntools_ui_render_status info 'No usable matching key was found in local wallets. Choose a file manually; encrypted keys must be decrypted through Wallet → Decrypt first.' || return 2
    fi
    if [[ -n "${hardware_group}" ]]; then
      cntools_ui_render_status info "Hardware session ${hardware_group} collects its missing witnesses together. Once selected, all required session references must be supplied; otherwise defer the whole session." || return 2
    fi
    cntools_ui_choose selected 'Signing source' "${choices[@]}" || return $?
    cntools_transaction_log CHOICE "Signer source choice id=${expected} selection=${selected}"
    case "${selected}" in
      Cancel) return 1 ;;
      'Skip this signer') [[ "${allow_defer}" == Y && -z "${hardware_group}" ]] || return 2; return 0 ;;
      'Defer this hardware session') [[ "${allow_defer}" == Y && -n "${hardware_group}" ]] || return 2; return 0 ;;
      'Select file manually')
        status=0
        cntools_transaction_ui_prompt_signer_into selected_path "${expected}" "${signer_name}" "${preferred}" "${hardware_group}" "${allow_defer}" || status=$?
        ((status == 0 || status == 1)) || return "${status}"
        ((status == 0)) || continue
        if [[ -n "${selected_path}" ]] && cntools_transaction_source_type_into key_type "${selected_path}"; then
          CNTOOLS_TRANSACTION_LOCAL_KEY_TYPES["${expected}"]="${key_type}"
        fi
        local_source_result="${selected_path}"; return 0 ;;
      *)
        found=N
        for index in "${!matched_files[@]}"; do
          [[ "${selected}" == "${choices[index]}" ]] || continue
          found=Y
          candidate="${matched_files[index]}"
          # Recheck after selection. Actual signing also validates its private
          # source snapshot, so discovery cannot bypass the existing safeguards.
          if cntools_transaction_source_kind_into candidate_kind "${candidate}" &&
             [[ "${preferred}" == either || "${candidate_kind}" == "${preferred}" ]] &&
             cntools_transaction_source_key_id_into candidate_id "${candidate}" && [[ "${candidate_id}" == "${expected}" ]]; then
            local_source_result="${candidate}"; return 0
          fi
          cntools_ui_render_status warn 'That key changed or is no longer usable. Choose another source.'
          cntools_ui_wait
          break
        done
        [[ "${found}" == Y ]] || return 2
        ;;
    esac
  done
}
