#!/usr/bin/env bash
# Best-effort CNTools health snapshots for the Gum header. Functions only.
# shellcheck disable=SC2034

CNTOOLS_HEALTH_CACHE_SECONDS="${CNTOOLS_HEALTH_CACHE_SECONDS:-5}"
CNTOOLS_HEALTH_LAST_REFRESH=0
CNTOOLS_HEALTH_TEXT="node offline"
CNTOOLS_HEALTH_TONE="quiet"

cntools_health_set_offline() {
  if [[ "${CNTOOLS_MODE:-offline}" == "offline" ]]; then
    CNTOOLS_HEALTH_TEXT=""
    CNTOOLS_HEALTH_TONE="quiet"
  else
    CNTOOLS_HEALTH_TEXT="node offline"
    CNTOOLS_HEALTH_TONE="danger"
  fi
}

cntools_health_now() {
  printf '%(%s)T\n' -1
}

cntools_health_reference_slot() {
  local network="${1:-${CNTOOLS_NETWORK:-}}"
  local now="${2:-}"
  local byron_start=0
  local transition_epoch=0
  local byron_epoch_length=0
  local byron_slot_ms=0
  local shelley_slot_seconds=1
  local byron_slots=0
  local byron_end=0

  [[ -n "${now}" ]] || now="$(cntools_health_now)" || return 1
  [[ "${now}" =~ ^[0-9]+$ ]] || return 1
  case "${network}" in
    mainnet)
      byron_start=1506203091
      transition_epoch=208
      byron_epoch_length=21600
      byron_slot_ms=20000
      ;;
    guild)
      byron_start=1639090522
      transition_epoch=2
      byron_epoch_length=360
      byron_slot_ms=100
      ;;
    preprod)
      byron_start=1654041600
      transition_epoch=4
      byron_epoch_length=21600
      byron_slot_ms=20000
      ;;
    preview)
      byron_start=1666656000
      transition_epoch=0
      byron_epoch_length=4320
      byron_slot_ms=20000
      ;;
    *) return 1 ;;
  esac

  byron_slots=$((transition_epoch * byron_epoch_length))
  byron_end=$((
    byron_start +
    ((transition_epoch * byron_epoch_length * byron_slot_ms) / 1000)
  ))
  if (( now < byron_end )); then
    printf '%s\n' "$((((now - byron_start) * 1000) / byron_slot_ms))"
  else
    printf '%s\n' "$((
      byron_slots + ((now - byron_end) / shelley_slot_seconds)
    ))"
  fi
}

cntools_health_tone_for_gap() {
  local gap="${1:-}"

  [[ "${gap}" =~ ^[0-9]+$ ]] || return 1
  if (( gap <= 120 )); then
    printf 'success\n'
  elif (( gap <= 600 )); then
    printf 'warning\n'
  else
    printf 'danger\n'
  fi
}

cntools_health_nonnegative_integer() {
  local value="${1:-}"

  [[ "${value}" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] || return 1
  LC_NUMERIC=C printf '%.0f\n' "${value}"
}

cntools_health_prometheus_value() {
  local metrics="${1:-}"
  local wanted=""
  local IFS=,
  shift || return 2
  (( $# > 0 )) || return 2
  wanted="$*"

  LC_ALL=C awk -v wanted="${wanted}" '
    BEGIN {
      count = split(wanted, names, ",")
      for (item = 1; item <= count; item++) {
        accepted[names[item]] = 1
      }
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      name = line
      sub(/\{.*/, "", name)
      sub(/[[:space:]].*/, "", name)
      if (!(name in accepted)) {
        next
      }
      line = substr(line, length(name) + 1)
      if (substr(line, 1, 1) == "{") {
        sub(/^[^}]*\}[[:space:]]+/, "", line)
      } else {
        sub(/^[[:space:]]+/, "", line)
      }
      value = line
      sub(/[[:space:]].*$/, "", value)
      if (value ~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/) {
        print value
        exit
      }
    }
  ' <<< "${metrics}"
}

cntools_health_cnode_metrics_url() {
  local config="${CNTOOLS_CONFIG:-${CONFIG:-${CNTOOLS_NODE_HOME:-}/files/config.json}}"
  local endpoint=""
  local host=""
  local port=""

  [[ -f "${config}" && ! -L "${config}" ]] || return 1
  endpoint="$(jq -er '
    first(
      (.TraceOptions."".backends // [])[]
      | select(test("(?i)PrometheusSimple"))
      | split(" ")
    )
    | [.[-2], .[-1]]
    | @tsv
  ' "${config}" 2>/dev/null)" || return 1
  IFS=$'\t' read -r host port <<< "${endpoint}"
  [[ -n "${host}" && "${host}" != *[[:space:]/]* &&
     "${port}" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  (( port <= 65535 )) || return 1
  printf 'http://%s:%s/metrics\n' "${host}" "${port}"
}

cntools_health_local_metrics_url() {
  local url="${CNTOOLS_METRICS_URL:-}"
  local host="${CNTOOLS_METRICS_HOST:-}"
  local port="${CNTOOLS_METRICS_PORT:-}"
  local path="${CNTOOLS_METRICS_PATH:-/metrics}"

  if [[ -z "${url}" && -n "${host}" && -n "${port}" ]]; then
    url="http://${host}:${port}${path}"
  elif [[ -z "${url}" && "${CNTOOLS_IMPLEMENTATION:-}" == "cnode" ]]; then
    url="$(cntools_health_cnode_metrics_url)" || return 1
  fi
  [[ "${url}" =~ ^https?://[^[:space:]]+$ ]] || return 1
  printf '%s\n' "${url}"
}

cntools_health_fetch_local() {
  local url="${1:-}"
  local response_file=""
  local response=""
  local http_status="000"
  local curl_status=0
  local started=0
  local finished=0

  [[ "${url}" =~ ^https?://[^[:space:]]+$ ]] || return 2
  response_file="$(mktemp \
    "${CNTOOLS_TMP_DIR:-/tmp}/.cntools-health.XXXXXX")" || return 1
  chmod 0600 "${response_file}" || {
    rm -f -- "${response_file}"
    return 1
  }
  started="$(cntools_health_now 2>/dev/null || printf '0')"
  if http_status="$(command curl --fail --silent --no-show-error \
      --connect-timeout 1 --max-time 1 --max-filesize 1048576 \
      --output "${response_file}" --write-out '%{http_code}' \
      "${url}")"; then
    curl_status=0
  else
    curl_status=$?
  fi
  finished="$(cntools_health_now 2>/dev/null || printf '%s' "${started}")"
  if (( curl_status != 0 )); then
    cntools_log API \
      "GET node-metrics -> curl:${curl_status} ($((finished - started))s)" || true
    rm -f -- "${response_file}"
    return "${curl_status}"
  fi
  cntools_log API \
    "GET node-metrics -> ${http_status} ($((finished - started))s)" || true
  [[ "${http_status}" =~ ^[23][0-9]{2}$ ]] || {
    rm -f -- "${response_file}"
    return 22
  }
  response="$(< "${response_file}")"
  rm -f -- "${response_file}"
  [[ -n "${response}" ]] || return 1
  printf '%s\n' "${response}"
}

cntools_health_fetch_koios() {
  local response_file=""
  local auth_header_file=""
  local response=""
  local endpoint="${CNTOOLS_KOIOS_API%/}/tip"
  local request_status=0
  local -a request_arguments=(
    --connect-timeout 1
    --max-time 2
    --max-filesize 65536
    --header "accept: application/json"
  )

  [[ "${endpoint}" =~ ^https://[^[:space:]]+$ ]] || return 2
  response_file="$(mktemp \
    "${CNTOOLS_TMP_DIR:-/tmp}/.cntools-health.XXXXXX")" || return 1
  chmod 0600 "${response_file}" || {
    rm -f -- "${response_file}"
    return 1
  }
  if [[ -n "${CNTOOLS_KOIOS_TOKEN:-}" ]]; then
    if ! cntools_http_secret_file_create auth_header_file; then
      cntools_log ERROR "Could not prepare the protected Koios authorization header" || true
      rm -f -- "${response_file}"
      return 1
    fi
    request_arguments+=(--header "@${auth_header_file}")
  fi
  if cntools_http_request GET "${endpoint}" "${response_file}" \
      "${request_arguments[@]}"; then
    request_status=0
  else
    request_status=$?
  fi
  [[ -z "${auth_header_file}" ]] ||
    cntools_http_secret_file_remove "${auth_header_file}" || true
  if (( request_status != 0 )); then
    rm -f -- "${response_file}"
    return "${request_status}"
  fi
  response="$(< "${response_file}")"
  rm -f -- "${response_file}"
  [[ -n "${response}" ]] || return 1
  printf '%s\n' "${response}"
}

cntools_health_set_online() {
  local epoch="${1:-}"
  local block="${2:-}"
  local gap="${3:-}"
  local suffix="slots"

  [[ "${epoch}" =~ ^[0-9]+$ && "${block}" =~ ^[0-9]+$ ]] || return 2
  if [[ "${gap}" =~ ^[0-9]+$ ]]; then
    (( gap != 1 )) || suffix="slot"
    CNTOOLS_HEALTH_TEXT="Epoch ${epoch}  ·  Tip #${block}  ·  Gap ${gap} ${suffix}"
    CNTOOLS_HEALTH_TONE="$(cntools_health_tone_for_gap "${gap}")" ||
      CNTOOLS_HEALTH_TONE="warning"
  else
    CNTOOLS_HEALTH_TEXT="Epoch ${epoch}  ·  Tip #${block}  ·  Gap unavailable"
    CNTOOLS_HEALTH_TONE="warning"
  fi
}

cntools_health_collect_local() {
  local url=""
  local metrics=""
  local epoch=""
  local block=""
  local slot=""
  local gap=""
  local reference_slot=""

  url="$(cntools_health_local_metrics_url)" || return 1
  metrics="$(cntools_health_fetch_local "${url}")" || return 1
  epoch="$(cntools_health_prometheus_value "${metrics}" \
    cardano_node_metrics_epoch_int)"
  block="$(cntools_health_prometheus_value "${metrics}" \
    cardano_node_metrics_blockNum_int)"
  slot="$(cntools_health_prometheus_value "${metrics}" \
    cardano_node_metrics_slotNum_int)"
  gap="$(cntools_health_prometheus_value "${metrics}" \
    dingo_tip_gap_slots)"
  epoch="$(cntools_health_nonnegative_integer "${epoch}")" || return 1
  block="$(cntools_health_nonnegative_integer "${block}")" || return 1
  if gap="$(cntools_health_nonnegative_integer "${gap}")"; then
    :
  elif slot="$(cntools_health_nonnegative_integer "${slot}")" &&
       reference_slot="$(cntools_health_reference_slot)"; then
    gap=$((reference_slot - slot))
    (( gap >= 0 )) || gap=0
  else
    gap=""
  fi
  cntools_health_set_online "${epoch}" "${block}" "${gap}"
}

cntools_health_collect_light() {
  local response=""
  local record=""
  local epoch=""
  local slot=""
  local block=""
  local block_time=""
  local reference_slot=""
  local gap=""
  local now=""

  response="$(cntools_health_fetch_koios)" || return 1
  record="$(jq -er '
    (if type == "array" then .[0] else . end)
    | [.epoch_no, .abs_slot, (.block_height // .block_no), .block_time]
    | select(all(.[]; type == "number" and . >= 0 and floor == .))
    | @tsv
  ' <<< "${response}" 2>/dev/null)" || return 1
  IFS=$'\t' read -r epoch slot block block_time <<< "${record}"
  [[ "${epoch}" =~ ^[0-9]+$ && "${slot}" =~ ^[0-9]+$ &&
     "${block}" =~ ^[0-9]+$ && "${block_time}" =~ ^[0-9]+$ ]] || return 1

  if reference_slot="$(cntools_health_reference_slot)"; then
    gap=$((reference_slot - slot))
  else
    now="$(cntools_health_now)" || return 1
    gap=$((now - block_time))
  fi
  (( gap >= 0 )) || gap=0
  cntools_health_set_online "${epoch}" "${block}" "${gap}"
}

cntools_health_refresh() {
  local force="${1:-N}"
  local now=""
  local cache_seconds="${CNTOOLS_HEALTH_CACHE_SECONDS:-5}"
  local last_refresh="${CNTOOLS_HEALTH_LAST_REFRESH:-0}"

  [[ "${cache_seconds}" =~ ^[0-9]+$ ]] || cache_seconds=5
  cache_seconds=$((10#${cache_seconds}))
  now="$(cntools_health_now 2>/dev/null || printf '0')"
  [[ "${now}" =~ ^[0-9]+$ ]] || now=0
  [[ "${last_refresh}" =~ ^[0-9]+$ ]] || last_refresh=0
  now=$((10#${now}))
  last_refresh=$((10#${last_refresh}))
  if [[ "${force}" != "Y" ]] &&
     (( now >= last_refresh && now - last_refresh < cache_seconds )); then
    return 0
  fi
  CNTOOLS_HEALTH_LAST_REFRESH="${now}"

  case "${CNTOOLS_MODE:-offline}" in
    offline)
      cntools_health_set_offline
      ;;
    local)
      if ! cntools_health_collect_local; then
        cntools_health_set_offline
        cntools_log HEALTH \
          "local node health unavailable implementation=${CNTOOLS_IMPLEMENTATION:-unknown}" || true
      fi
      ;;
    light)
      if ! cntools_health_collect_light; then
        cntools_health_set_offline
        cntools_log HEALTH "Koios health unavailable" || true
      fi
      ;;
    *)
      cntools_health_set_offline
      ;;
  esac
  return 0
}
