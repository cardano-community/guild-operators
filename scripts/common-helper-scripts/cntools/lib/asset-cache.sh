#!/usr/bin/env bash
# One-day, network/API-scoped cache of public Koios asset details.
# Never used for spendable balances, coin selection, or Handle destinations.
# shellcheck disable=SC2034

cntools_asset_response_valid() {
  local response_file="$1" requested="$2"
  jq -e --argjson requested "${requested}" '
    def uint:
      type == "string" and length <= 80 and test("^[0-9]+$");
    def optional_text:
      type == "null" or type == "string";
    def optional_object:
      type == "null" or type == "object";
    def identity:
      ((.policy_id | ascii_downcase) + "." +
        ((.asset_name // "") | ascii_downcase));
    type == "array" and
    length == ($requested | length) and
    all(.[];
      (.policy_id | type == "string" and
        test("^[0-9a-fA-F]{56}$")) and
      ((.asset_name == null) or
        (.asset_name | type == "string" and
          test("^([0-9a-fA-F]{2}){0,32}$"))) and
      (identity as $id | ($requested | index($id)) != null) and
      (.asset_name_ascii | optional_text) and
      (.fingerprint | type == "string" and
        test("^asset1[023456789acdefghjklmnpqrstuvwxyz]{38}$")) and
      (.total_supply | uint) and
      (.registry_metadata | optional_object) and
      (.metadata_20 | optional_object) and
      (.metadata_721 | optional_object) and
      (.cip68_metadata | optional_object)) and
    ([.[] | identity] | unique | length) == length
  ' "${response_file}" >/dev/null 2>&1
}

cntools_asset_cache_directory() {
  local base="${CNTOOLS_NODE_HOME:-}" directory=""
  [[ "${CNTOOLS_ASSET_CACHE_ENABLED:-Y}" == Y && "${base}" == /* &&
     "${base}" != / && -d "${base}" && ! -L "${base}" && -O "${base}" ]] || return 1
  for directory in "${base}/.cntools" "${base}/.cntools/asset-cache"; do
    if [[ ! -e "${directory}" && ! -L "${directory}" ]]; then
      (umask 077; mkdir -- "${directory}") 2>/dev/null || return 1
    fi
    [[ -d "${directory}" && ! -L "${directory}" && -O "${directory}" &&
       -w "${directory}" ]] || return 1
    cntools_theme_private_path "${directory}" || return 1
  done
  printf '%s' "${directory}"
}

cntools_asset_cache_read() {
  local file="$1" identity="$2" now="$3" size="" data="" requested=""
  [[ -f "${file}" && ! -L "${file}" && -O "${file}" ]] || return 1
  cntools_theme_private_path "${file}" || return 1
  size="$(wc -c < "${file}")" || return 1
  (( size > 0 && size <= 2097152 )) || return 1
  data="$(jq -ce --arg api "${CNTOOLS_KOIOS_API%/}" --argjson now "${now}" '
    select(.schema == 1 and .api == $api and
      (.fetchedAt | type == "number" and floor == .) and
      .fetchedAt <= $now and ($now - .fetchedAt) < 86400)
    | [.data]
  ' "${file}" 2>/dev/null)" || return 1
  requested="$(jq -cn --arg id "${identity}" '[$id]')" || return 1
  cntools_asset_response_valid /dev/stdin "${requested}" <<< "${data}" || return 1
  printf '%s' "${data}"
}

cntools_asset_cache_write() {
  local directory="$1" identity="$2" now="$3" data="$4" stage="" target=""
  target="${directory}/${CNTOOLS_NETWORK}-${identity}.json"
  [[ ! -L "${target}" && ( ! -e "${target}" || -f "${target}" ) ]] || return 1
  stage="$(umask 077; mktemp "${directory}/.asset.XXXXXX")" || return 1
  if jq -cn --arg api "${CNTOOLS_KOIOS_API%/}" --argjson time "${now}" --argjson data "${data}" \
      '{schema:1, api:$api, fetchedAt:$time, data:$data}' > "${stage}" &&
     mv -f -- "${stage}" "${target}"; then return 0; fi
  rm -f -- "${stage}"
  return 1
}

# Keep bulk requests: only cache misses go to the existing logged HTTP helper.
# Every response, cached or fresh, passes the same strict identity/schema check.
cntools_asset_details_fetch() {
  local destination="$1" directory="" identity="" cached="" combined='[]'
  local payload="" requested="" fresh="" record="" now="" cached_count=0
  local -a missing=()
  shift
  [[ "${CNTOOLS_NETWORK:-}" =~ ^(mainnet|preprod|preview|guild)$ ]] || return 1
  printf -v now '%(%s)T' -1
  directory="$(cntools_asset_cache_directory)" || directory=""
  for identity in "$@"; do
    [[ "${identity}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ ]] || return 2
    if [[ -n "${directory}" ]] && cached="$(cntools_asset_cache_read \
        "${directory}/${CNTOOLS_NETWORK}-${identity}.json" "${identity}" "${now}")"; then
      combined="$(jq -cn --argjson a "${combined}" --argjson b "${cached}" '$a+$b')" || return 1
      cached_count=$((cached_count+1))
    else missing+=("${identity}"); fi
  done
  if (( cached_count > 0 )); then
    cntools_wallet_log CACHE "Koios asset details cache hits=${cached_count} max_age=86400s"
  fi
  if (( ${#missing[@]} > 0 )); then
    cntools_wallet_query_koios_asset_payload payload "${missing[@]}" || return 1
    requested="$(jq -c '[._asset_list[] | (.[0]+"."+.[1])]' <<< "${payload}")" || return 1
    cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/asset_info${CNTOOLS_WALLET_KOIOS_ASSET_SELECT}" \
      "${payload}" "${destination}" || return 1
    cntools_asset_response_valid "${destination}" "${requested}" || {
      cntools_wallet_log ERROR 'Koios asset_info returned invalid JSON; not caching the response'
      return 1
    }
    fresh="$(< "${destination}")"
    combined="$(jq -cn --argjson a "${combined}" --argjson b "${fresh}" '$a+$b')" || return 1
    if [[ -n "${directory}" ]]; then
      for identity in "${missing[@]}"; do
        record="$(jq -c --arg id "${identity}" '.[] | select(
          ((.policy_id+"."+(.asset_name // "")) | ascii_downcase) == $id)' <<< "${fresh}")" || return 1
        cntools_asset_cache_write "${directory}" "${identity}" "${now}" "${record}" ||
          cntools_wallet_log WARN "Could not cache asset=${identity}; using live metadata"
      done
    fi
  fi
  printf '%s\n' "${combined}" > "${destination}"
}

cntools_asset_cache_clear() {
  local directory="" file="" name="" count=0
  directory="$(cntools_asset_cache_directory)" || return 1
  for file in "${directory}/"*.json; do
    name="${file##*/}"
    [[ "${name}" =~ ^(mainnet|preprod|preview|guild)-[0-9a-f]{56}\.([0-9a-f]{2}){0,32}\.json$ ]] || continue
    [[ -f "${file}" && ! -L "${file}" && -O "${file}" ]] || continue
    rm -- "${file}" || return 1
    count=$((count+1))
  done
  cntools_log CACHE "Cleared asset metadata cache entries=${count}" || true
}
