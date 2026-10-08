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

cntools_public_metadata_offer() {
  local url="$1" expected="$2" limit="${3:-262144}" status=0
  [[ "${CNTOOLS_MODE:-offline}" != offline && -n "${url}" && "${expected}" =~ ^[0-9a-fA-F]{64}$ ]] || return 0
  if [[ ! "${url}" =~ ^https?://[^[:space:]]+$ && "${url}" != ipfs://* ]]; then
    cntools_ui_render_status info 'This anchor is not a public HTTP(S) URL. Download it independently and compare its exact byte hash.'; return 0
  fi
  cntools_ui_confirm "Download and verify published metadata from ${url}?" false || return 0
  [[ "${url}" != ipfs://* ]] || cntools_ui_render_status info 'IPFS content is fetched through the public ipfs.io gateway and checked against the on-chain byte hash.'
  [[ "${url}" != http://* ]] || cntools_ui_render_status warn 'This URL uses unencrypted HTTP. Only the matching on-chain hash establishes byte integrity.'
  cntools_ui_spin_function 'Downloading and verifying published metadata…' cntools_public_metadata_fetch "${url}" "${expected}" "${limit}" || status=$?
  if ((status != 0)); then
    cntools_ui_render_status warn "${CNTOOLS_PUBLIC_METADATA_ERROR}"; return 0
  fi
  cntools_public_metadata_render "${CNTOOLS_PUBLIC_METADATA_FILE}"
}
