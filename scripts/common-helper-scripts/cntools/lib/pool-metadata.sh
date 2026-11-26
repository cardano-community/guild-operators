#!/usr/bin/env bash
# Metadata authoring/reuse. Arbitrary hosts never receive Koios authorization.
# shellcheck disable=SC2034
cntools_pool_metadata_download_into() {
  local output="$1" url="$2" downloaded='' downloaded_hash=''
  local CNTOOLS_HTTP_PUBLIC_POOL_METADATA=Y
  cntools_pool_metadata_valid "$(jq -cn --arg url "${url}" '{url:$url,hash:("0"*64)}')" &&
    [[ "${url}" != *'@'* ]] || {
    cntools_transaction_set_error 'Downloading metadata requires a public HTTP(S) URL without embedded credentials.'; return 1;
  }
  cntools_transaction_temp_file downloaded pool-published-metadata || return 1
  if ! cntools_api_request GET "${url}" "${downloaded}" --header 'Accept: application/json' \
      --location --max-redirs 3 --proto '=http,https' --proto-redir '=https' --max-filesize 1024; then
    cntools_transaction_set_error 'Published metadata could not be downloaded within the size/time limits. Check the URL and API log.'; return 1
  fi
  cntools_pool_metadata_file_hash_into downloaded_hash "${downloaded}" || return 1
  printf -v "${output}" '%s' "${downloaded}"
}

# Asks each field with the current value as its default. Metadata is limited
# to 512 bytes, so a longer result asks again for the fields that can make
# it long: the description and the extended metadata URL.
cntools_pool_metadata_author_into() {
  local output="$1" defaults="${2:-}" title='' value='' previous='' prompt='' candidate='{}' authored_file='' hash='' limit=0 size=0
  local -a fields=(name ticker description homepage extended)
  [[ -n "${defaults}" ]] || defaults='{}'
  while true; do
    for title in "${fields[@]}"; do
      value="$(jq -r --arg field "${title}" '.[$field] // empty' <<< "${defaults}")" || return 2
      case "${title}" in
        name) prompt='Pool name (1–50 characters)'; limit=50 ;;
        ticker) prompt='Ticker (3–5 letters/numbers)'; limit=5 ;;
        description) prompt='Description (up to 255 characters)'; limit=255 ;;
        homepage) prompt='Homepage URL (up to 64 characters)'; limit=64 ;;
        extended) prompt='Extended metadata URL (optional, up to 128 characters; - clears)'; limit=128 ;;
      esac
      while true; do
        previous="${value}"
        cntools_pool_registration_input value "${prompt}${value:+ · Enter keeps current}" "${value}" || return $?
        [[ -n "${value}" ]] || value="${previous}"
        [[ "${title}" != extended || "${value}" != - ]] || value=''
        [[ "${title}" != ticker ]] || value="${value^^}"
        if (( ${#value} <= limit )); then
          case "${title}" in
            name) [[ -n "${value}" ]] && break ;;
            ticker) [[ "${value}" =~ ^[A-Z0-9]{3,5}$ ]] && break ;;
            description) break ;;
            homepage) [[ "${value}" =~ ^https?://[^[:space:]]+$ ]] && break ;;
            extended) [[ -z "${value}" || "${value}" =~ ^https?://[^[:space:]]+$ ]] && break ;;
          esac
        fi
        cntools_transaction_log WARN "Invalid pool metadata field=${title}"
        # The prompt follows below this warning; no extra Enter.
        cntools_ui_render_status warn "Check ${title}: ${prompt}."
      done
      if [[ "${title}" == extended && -z "${value}" ]]; then
        candidate="$(jq -c 'del(.extended)' <<< "${candidate}")" || return 2
      else
        candidate="$(jq -c --arg field "${title}" --arg value "${value}" '.+{($field):$value}' <<< "${candidate}")" || return 2
      fi
    done
    cntools_transaction_temp_file authored_file pool-authored-metadata || return 2
    jq -c --arg nonce "$(date +%s)" '.+{nonce:$nonce}' <<< "${candidate}" > "${authored_file}" || return 2
    size="$(wc -c < "${authored_file}")"; size="${size//[[:space:]]/}"
    (( size > CNTOOLS_POOL_METADATA_MAX_BYTES )) || break
    cntools_transaction_log WARN "Authored pool metadata too long bytes=${size}"
    # The next prompt follows below this warning.
    cntools_ui_render_status warn "This metadata is $(cntools_number_format "${size}") bytes; the limit is ${CNTOOLS_POOL_METADATA_MAX_BYTES}. Shorten the description or the extended metadata URL."
    defaults="${candidate}" fields=(description extended)
  done
  cntools_pool_metadata_file_hash_into hash "${authored_file}" || return 3
  printf -v "${output}" '%s' "${authored_file}"
}

# 0 when the file published at the URL hashes to the expected value; the
# message (match, mismatch or download failure) is left for the caller.
CNTOOLS_POOL_METADATA_VERIFY_MESSAGE=''
cntools_pool_metadata_verify_published() {
  local url="$1" expected="$2" file='' published=''
  CNTOOLS_POOL_METADATA_VERIFY_MESSAGE=''
  if ! cntools_pool_metadata_download_into file "${url}" || ! cntools_pool_metadata_file_hash_into published "${file}"; then
    CNTOOLS_POOL_METADATA_VERIFY_MESSAGE="${CNTOOLS_TRANSACTION_ERROR:-The published metadata could not be read.} Publish the file before submitting."
    return 1
  fi
  if [[ "${published}" != "${expected}" ]]; then
    CNTOOLS_POOL_METADATA_VERIFY_MESSAGE="The file at ${url} does not match the metadata hash yet. Publish the exact file before submitting; the registration commits to its hash."
    return 1
  fi
  CNTOOLS_POOL_METADATA_VERIFY_MESSAGE="The file at ${url} matches the metadata hash."
}

cntools_pool_metadata_wizard() {
  local choice='' file='' url="${CNTOOLS_POOL_REG_METADATA_URL:-}" hash='' defaults='{}' directory="${CNTOOLS_POOL_DIRECTORIES[CNTOOLS_POOL_REG_INDEX]}" published=N
  [[ "${CNTOOLS_POOL_REG_METADATA}" == null ]] || url="$(jq -r .url <<< "${CNTOOLS_POOL_REG_METADATA}")"
  cntools_pool_registration_choose choice 'Pool metadata' 'Keep current metadata' 'Create metadata' 'Download and reuse published metadata' \
    'Local JSON file + published URL' 'URL + known hash' 'No metadata' Back || return $?
  case "${choice}" in
    Back|'Keep current metadata') return 0 ;;
    'No metadata') CNTOOLS_POOL_REG_METADATA=null; return 0 ;;
    'URL + known hash') cntools_pool_registration_input hash 'Pool metadata hash' '64 hexadecimal characters' || return $?; hash="${hash,,}" ;;
    'Local JSON file + published URL')
      cntools_ui_pick_path file 'Pool metadata JSON file' 'Up to 512 bytes. Choose the exact bytes to publish.' "${directory}" || return $?
      cntools_transaction_input_path_into file "${file}" &&
        cntools_transaction_snapshot_into file "${file}" 1024 pool-metadata-edit && cntools_pool_metadata_file_hash_into hash "${file}" || return 3 ;;
    'Download and reuse published metadata')
      while true; do
        cntools_pool_registration_input_default url 'Published metadata URL' "${url}" || return $?
        [[ "${url}" == http://* ]] || break
        cntools_ui_render_status warn 'This metadata URL is unencrypted HTTP. Prefer HTTPS; inspect the downloaded content before approving its hash.'
        cntools_pool_registration_choose choice 'Download unencrypted public metadata?' 'Use another URL' 'Yes, download' || return $?
        [[ "${choice}" != 'Yes, download' ]] || break
      done
      cntools_ui_spin_function 'Downloading and validating pool metadata…' cntools_pool_metadata_download_into file "${url}" || return 3
      # Quick reuses metadata fetched over HTTPS (the settings table shows its
      # URL and hash next); plain HTTP content is always reviewed.
      if [[ "${url}" == https://* || "${url}" == ipfs://* ]] && cntools_flow_quick; then
        choice='Reuse unchanged'
        cntools_transaction_log CHOICE "Pool menu=Reuse this metadata? default=${choice} flow=quick name=$(jq -r .name "${file}") ticker=$(jq -r .ticker "${file}")"
      else
        { cntools_table_pair Name "$(jq -r .name "${file}")" identifier
          cntools_table_pair Ticker "$(jq -r .ticker "${file}")" identifier
          cntools_table_pair Description "$(jq -r .description "${file}")"
          cntools_table_pair Homepage "$(jq -r .homepage "${file}")" identifier
        } | cntools_table_render 'Published metadata' || return 2
        cntools_pool_registration_choose choice 'Reuse this metadata?' 'Reuse unchanged' 'Edit a copy' Cancel || return $?
      fi
      case "${choice}" in
        'Reuse unchanged') published=Y ;;
        'Edit a copy') defaults="$(jq . "${file}")"; cntools_pool_metadata_author_into file "${defaults}" || return $? ;;
        *) return 1 ;;
      esac
      cntools_pool_metadata_file_hash_into hash "${file}" || return 3 ;;
    'Create metadata')
      if cntools_pool_public_file_safe "${directory}/poolmeta.json" 1024; then defaults="$(jq . "${directory}/poolmeta.json")" || defaults='{}'; fi
      cntools_pool_metadata_author_into file "${defaults}" || return $?
      cntools_pool_metadata_file_hash_into hash "${file}" || return 3 ;;
    *) return 2 ;;
  esac
  # Unchanged downloaded metadata is already published at the URL just entered.
  [[ "${published}" == Y ]] || cntools_pool_registration_input_default url 'Published metadata URL (up to 128 bytes)' "${url}" || return $?
  cntools_pool_metadata_valid "$(jq -cn --arg url "${url}" --arg hash "${hash}" '{url:$url,hash:$hash}')" || return 3
  if [[ -n "${file}" ]]; then
    cntools_pool_public_save "${directory}" poolmeta.json "${file}" || {
      cntools_transaction_set_error 'Could not save poolmeta.json safely; check pool directory permissions.'; return 3;
    }
  fi
  CNTOOLS_POOL_REG_METADATA="$(jq -cn --arg url "${url}" --arg hash "${hash}" '{url:$url,hash:$hash}')"
  CNTOOLS_POOL_REG_METADATA_URL="${url}"
  # Reused unchanged: the settings table that follows shows the URL and hash.
  if [[ "${published}" == Y ]]; then
    cntools_transaction_log CHOICE "Pool metadata reused as published url=${url} copy=${directory}/poolmeta.json"
    return 0
  fi
  if [[ -n "${file}" ]]; then
    cntools_ui_render_status info "Publish the exact file ${directory}/poolmeta.json at ${url}. Uploading is not automatic."
  else
    cntools_ui_render_status info "Check that ${url} serves the file matching the supplied hash. Uploading is not automatic."
  fi
  if [[ "${CNTOOLS_MODE:-offline}" == offline ]]; then cntools_ui_wait; return 0; fi
  # Online, the published file can be compared now; Continue is the default.
  cntools_pool_registration_choose choice 'Published metadata file' Continue 'Verify published file' || { (( $? != 130 )) || return 130; return 0; }
  [[ "${choice}" == 'Verify published file' ]] || return 0
  if cntools_ui_spin_function 'Downloading and checking the published metadata…' cntools_pool_metadata_verify_published "${url}" "${hash}"; then
    cntools_ui_render_status success "${CNTOOLS_POOL_METADATA_VERIFY_MESSAGE}"
    cntools_ui_wait
  else
    # The settings screen follows and repeats this warning.
    cntools_ui_render_status warn "${CNTOOLS_POOL_METADATA_VERIFY_MESSAGE}"
  fi
  cntools_transaction_clear_error
}
