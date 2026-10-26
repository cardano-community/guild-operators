#!/usr/bin/env bash
# Optional unauthenticated anchor reads; hash original bytes before rendering.
# shellcheck disable=SC2034
CNTOOLS_PUBLIC_METADATA_FILE='' CNTOOLS_PUBLIC_METADATA_HASH='' CNTOOLS_PUBLIC_METADATA_ERROR=''

cntools_public_metadata_fetch() {
  local url="$1" expected="${2:-}" limit="${3:-262144}" fetched='' output='' errors='' status=0
  local CNTOOLS_HTTP_PUBLIC_METADATA=Y
  CNTOOLS_PUBLIC_METADATA_FILE='' CNTOOLS_PUBLIC_METADATA_HASH=''
  CNTOOLS_PUBLIC_METADATA_ERROR='Published metadata could not be downloaded or verified. See the API/command log.'
  if [[ "${url}" == ipfs://* ]]; then
    local content="${url#ipfs://}"; content="${content#ipfs/}"
    [[ "${content}" =~ ^[A-Za-z0-9]{32,120}(/[A-Za-z0-9._~-]+)*$ && "/${content}/" != */../* && "/${content}/" != */./* ]] || return 1
    url="https://ipfs.io/ipfs/${content}"
  fi
  [[ "${CNTOOLS_MODE:-offline}" != offline && "${url}" =~ ^https?://[^[:space:]]+$ &&
     "${url}" != *'@'* && ! "${url}" =~ [[:cntrl:]] && ( -z "${expected}" || "${expected}" =~ ^[0-9a-fA-F]{64}$ ) &&
     "${limit}" =~ ^[0-9]{1,7}$ && -x "${CNTOOLS_CLI:-}" ]] || return 1
  cntools_wallet_query_temp_file fetched && cntools_wallet_query_temp_file output &&
    cntools_wallet_query_temp_file errors || return 1
  # Deliberately no Koios token or user-supplied authorization headers.
  cntools_api_request GET "${url}" "${fetched}" --header 'Accept: application/json' \
    --location --max-redirs 3 --proto '=http,https' --proto-redir '=https' --max-filesize "${limit}" || return 1
  cntools_wallet_safe_regular_file "${fetched}" "${limit}" &&
    jq -se 'length == 1 and (.[0] | type == "object")' "${fetched}" >/dev/null 2>&1 || return 1
  cntools_wallet_query_run_cli "${output}" "${errors}" "${CNTOOLS_CLI}" hash anchor-data --file-binary "${fetched}" || status=$?
  if ((status != 0)); then
    cntools_wallet_query_log_failure 'Metadata byte hashing failed' "${status}" "${errors}" "${output}"; return 1
  fi
  CNTOOLS_PUBLIC_METADATA_HASH="$(< "${output}")"
  [[ "${CNTOOLS_PUBLIC_METADATA_HASH}" =~ ^[0-9a-f]{64}$ ]] || return 1
  CNTOOLS_PUBLIC_METADATA_FILE="${fetched}"
  if [[ -n "${expected}" && "${CNTOOLS_PUBLIC_METADATA_HASH}" != "${expected,,}" ]]; then
    CNTOOLS_PUBLIC_METADATA_ERROR='The published bytes do not match the on-chain metadata hash. Content was not displayed.'
    cntools_wallet_log WARN "Metadata hash mismatch url=${url} expected=${expected} actual=${CNTOOLS_PUBLIC_METADATA_HASH}"
    return 3
  fi
  CNTOOLS_PUBLIC_METADATA_ERROR=''
  cntools_wallet_log QUERY "Published metadata url=${url} hash=${CNTOOLS_PUBLIC_METADATA_HASH} verified=$([[ -n "${expected}" ]] && printf Y || printf N)"
}

cntools_public_metadata_render() {
  local field='' value='' title='Published metadata · verified bytes, untrusted content'
  [[ "${2:-Y}" == Y ]] || title='Downloaded metadata · hashed bytes, untrusted content'
  {
    while IFS=$'\037' read -r field value; do
      [[ -n "${field}" ]] || continue
      cntools_table_pair "${field}" "${value}"
    done < <(jq -r '[paths(scalars) as $p | select(getpath($p) != null) |
      [($p|map(tostring)|join(" / ")),(getpath($p)|tostring)] |
      map(gsub("[\u0000-\u001f\u007f]";" ")) | join("\u001f")] |
      if length <= 400 then .[] else .[:400][],"…\u001fRemaining fields omitted" end' "$1")
  } | cntools_table_render "${title}"
}

# True when this anchor can be downloaded and checked against its hash here.
cntools_public_metadata_verifiable() {
  [[ "${CNTOOLS_MODE:-offline}" != offline && -n "$1" && "$2" =~ ^[0-9a-fA-F]{64}$ ]] &&
    [[ "$1" =~ ^https?://[^[:space:]]+$ || "$1" == ipfs://* ]]
}

# Downloads, verifies and shows the anchor (no prompt). Optional 4th argument
# "shown": the content is already on screen (e.g. from an indexer), so a
# successful download only reports the verified hash.
cntools_public_metadata_verify() {
  local url="$1" expected="$2" limit="${3:-262144}" shown="${4:-}" status=0
  [[ "${url}" != ipfs://* ]] || cntools_ui_render_status info 'IPFS content is fetched through the public ipfs.io gateway and checked against the on-chain byte hash.'
  [[ "${url}" != http://* ]] || cntools_ui_render_status warn 'This URL uses unencrypted HTTP. Only the matching on-chain hash establishes byte integrity.'
  cntools_ui_spin_function 'Downloading and verifying published metadata…' cntools_public_metadata_fetch "${url}" "${expected}" "${limit}" || status=$?
  if ((status != 0)); then
    cntools_ui_render_status warn "${CNTOOLS_PUBLIC_METADATA_ERROR}"; return 0
  fi
  if [[ "${shown}" == shown ]]; then
    cntools_ui_render_status success 'Published bytes match the on-chain hash. The content above is the indexed copy.'; return 0
  fi
  cntools_public_metadata_render "${CNTOOLS_PUBLIC_METADATA_FILE}"
}

# Asks before downloading. Same arguments as cntools_public_metadata_verify;
# returns 130 on Ctrl+C, otherwise 0 whether or not it was downloaded.
cntools_public_metadata_offer() {
  local url="$1" expected="$2" status=0
  [[ "${CNTOOLS_MODE:-offline}" != offline && -n "${url}" && "${expected}" =~ ^[0-9a-fA-F]{64}$ ]] || return 0
  if ! cntools_public_metadata_verifiable "${url}" "${expected}"; then
    cntools_ui_render_status info 'This anchor is not a public HTTP(S) URL. Download it independently and compare its exact byte hash.'; return 0
  fi
  cntools_ui_confirm "Download and verify published metadata from ${url}?" false || status=$?
  ((status != 130)) || return 130
  ((status == 0)) || return 0
  cntools_public_metadata_verify "$@"
}

# Hash for an anchor URL the user publishes (DRep metadata, vote rationale).
# Keeps the URL across failed attempts. Quick tries the download first when
# online, falling back to asking. Returns 1 on Cancel.
# Usage: OUTPUT URL NOUN LABEL FILE_HASHER [DOWNLOAD_LIMIT] [FILE_NOTE]
cntools_public_metadata_anchor_hash_into() {
  local pm_output="$1" pm_url="$2" pm_noun="$3" pm_label="$4" pm_hasher="$5" pm_limit="${6:-262144}" pm_note="${7:-}"
  local pm_method='' pm_hash='' pm_file='' pm_status=0 pm_auto=N
  local -a pm_methods=('Hash local JSON file' 'Enter known hash')
  [[ "${pm_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && declare -F "${pm_hasher}" >/dev/null || return 2
  if [[ "${CNTOOLS_MODE:-offline}" != offline ]]; then
    pm_methods=('Download published JSON' "${pm_methods[@]}")
    ! cntools_flow_quick || pm_auto=Y
  fi
  while true; do
    if [[ "${pm_auto}" == Y ]]; then
      pm_auto=N pm_method='Download published JSON'
      cntools_wallet_log CHOICE "${pm_noun} hash method default=download flow=quick"
    else
      cntools_ui_choose pm_method "${pm_label} hash" "${pm_methods[@]}" Cancel || return $?
      cntools_wallet_log CHOICE "${pm_noun} hash method=${pm_method}"
    fi
    pm_status=0
    case "${pm_method}" in
      Cancel) return 1 ;;
      'Download published JSON')
        [[ "${pm_url}" != ipfs://* ]] || cntools_ui_render_status info 'IPFS content is fetched through the public ipfs.io gateway.'
        if ! cntools_ui_spin_function "Downloading and hashing published ${pm_noun}…" cntools_public_metadata_fetch "${pm_url}" '' "${pm_limit}"; then
          cntools_ui_render_status warn "${CNTOOLS_PUBLIC_METADATA_ERROR} Choose another way to hash it."; continue
        fi
        pm_hash="${CNTOOLS_PUBLIC_METADATA_HASH}"
        # Quick uses them at once, so the content table would only flash by.
        if ! cntools_flow_quick; then
          cntools_public_metadata_render "${CNTOOLS_PUBLIC_METADATA_FILE}" N || return 2
          cntools_ui_confirm 'Use these published bytes and hash?' false || pm_status=$?
          ((pm_status == 0)) || { ((pm_status == 130)) && return 130; continue; }
        fi
        ;;
      'Hash local JSON file')
        cntools_ui_pick_path pm_file "${pm_label} JSON file" 'Choose the exact published JSON bytes; the file is not uploaded.' || pm_status=$?
        ((pm_status == 0)) || { ((pm_status == 1)) && continue; return "${pm_status}"; }
        # The hasher's own reason only: never a stale error, and none left behind.
        CNTOOLS_TRANSACTION_ERROR=''
        if ! cntools_ui_spin_function "Hashing ${pm_noun}…" "${pm_hasher}" pm_hash "${pm_file}"; then
          cntools_ui_render_status warn "${CNTOOLS_TRANSACTION_ERROR:-Could not hash that ${pm_noun} file.}"
          CNTOOLS_TRANSACTION_ERROR=''; continue
        fi
        # A warning, so the build and review redraws repeat it until answered.
        [[ -z "${pm_note}" ]] || cntools_ui_render_status warn "${pm_note}"
        ;;
      'Enter known hash')
        cntools_ui_input pm_hash "${pm_label} hash" '64 hexadecimal characters (Blake2b-256)' || pm_status=$?
        ((pm_status == 0)) || { ((pm_status == 1)) && continue; return "${pm_status}"; }
        pm_hash="${pm_hash,,}"
        [[ "${pm_hash}" =~ ^[0-9a-f]{64}$ ]] || { cntools_ui_render_status warn 'Enter exactly 64 hexadecimal characters.'; continue; }
        ;;
      *) return 2 ;;
    esac
    printf -v "${pm_output}" '%s' "${pm_hash}"
    return 0
  done
}
