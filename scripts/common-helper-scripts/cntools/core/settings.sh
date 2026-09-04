#!/usr/bin/env bash
# Persistent CNTools application settings. Functions only.
# Transaction actions consume these values but never modify them.
# shellcheck disable=SC2034

CNTOOLS_SETTINGS_SCHEMA_VERSION=1
CNTOOLS_SETTINGS_STATE_DIR=""
CNTOOLS_SETTINGS_FILE=""
CNTOOLS_SETTINGS_STAGE_FILE=""

cntools_settings_defaults() {
  CNTOOLS_TX_SELECTION_STRATEGY="balanced"
  CNTOOLS_TX_TOKEN_FRAGMENTATION="N"
  CNTOOLS_TX_TOKEN_MAX_ASSETS=20
  CNTOOLS_TX_UTXO_MANAGEMENT="N"
  CNTOOLS_TX_UTXO_TARGET_COUNT=4
  CNTOOLS_TX_UTXO_PERCENTAGES="10,20,30"
  CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3
  CNTOOLS_TX_UTXO_MIN_LOVELACE="2000000"
  CNTOOLS_TX_COLLATERAL_MANAGEMENT="Y"
  CNTOOLS_TX_COLLATERAL_TARGET_COUNT=1
  CNTOOLS_TX_COLLATERAL_LOVELACE="5000000"
}

cntools_settings_log() {
  if declare -F cntools_log >/dev/null 2>&1; then
    cntools_log "${1:-INFO}" "${2:-}" || true
  fi
}

cntools_settings_state_paths() {
  local node_home="${CNTOOLS_NODE_HOME:-}"

  CNTOOLS_SETTINGS_STATE_DIR=""
  CNTOOLS_SETTINGS_FILE=""
  [[ -n "${node_home}" && "${node_home}" = /* && "${node_home}" != "/" &&
     -d "${node_home}" && ! -L "${node_home}" && -O "${node_home}" &&
     -w "${node_home}" && "${node_home}" != *$'\n'* &&
     "${node_home}" != *$'\r'* ]] || return 1
  CNTOOLS_SETTINGS_STATE_DIR="${node_home}/.cntools"
  CNTOOLS_SETTINGS_FILE="${CNTOOLS_SETTINGS_STATE_DIR}/transaction-settings.json"
}

cntools_settings_state_directory_safe() {
  [[ -n "${CNTOOLS_SETTINGS_STATE_DIR:-}" &&
     "${CNTOOLS_SETTINGS_STATE_DIR}" == "${CNTOOLS_NODE_HOME}/.cntools" &&
     -d "${CNTOOLS_SETTINGS_STATE_DIR}" &&
     ! -L "${CNTOOLS_SETTINGS_STATE_DIR}" &&
     -O "${CNTOOLS_SETTINGS_STATE_DIR}" ]] || return 1
  cntools_theme_private_path "${CNTOOLS_SETTINGS_STATE_DIR}"
}

cntools_settings_state_directory_ready() {
  local previous_umask=""

  [[ -n "${CNTOOLS_SETTINGS_STATE_DIR:-}" &&
     "${CNTOOLS_SETTINGS_STATE_DIR}" == "${CNTOOLS_NODE_HOME}/.cntools" ]] ||
    return 1
  if [[ ! -e "${CNTOOLS_SETTINGS_STATE_DIR}" &&
        ! -L "${CNTOOLS_SETTINGS_STATE_DIR}" ]]; then
    previous_umask="$(umask)"
    umask 077
    if mkdir -- "${CNTOOLS_SETTINGS_STATE_DIR}"; then
      umask "${previous_umask}"
    else
      umask "${previous_umask}"
      return 1
    fi
  fi
  [[ -d "${CNTOOLS_SETTINGS_STATE_DIR}" &&
     ! -L "${CNTOOLS_SETTINGS_STATE_DIR}" &&
     -O "${CNTOOLS_SETTINGS_STATE_DIR}" ]] || return 1
  chmod 0700 "${CNTOOLS_SETTINGS_STATE_DIR}" || return 1
  cntools_settings_state_directory_safe || return 1
  [[ -w "${CNTOOLS_SETTINGS_STATE_DIR}" ]]
}

cntools_settings_file_valid() {
  local file="${1:-}"
  local size=""

  cntools_settings_state_directory_safe || return 1
  [[ -n "${file}" && "${file}" == "${CNTOOLS_SETTINGS_FILE}" &&
     -f "${file}" && ! -L "${file}" && -O "${file}" ]] || return 1
  cntools_theme_private_path "${file}" || return 1
  size="$(wc -c < "${file}" 2>/dev/null)" || return 1
  size="${size//[[:space:]]/}"
  [[ "${size}" =~ ^[0-9]+$ && ${size} -gt 0 && ${size} -le 16384 ]] ||
    return 1
  jq -e --argjson schema "${CNTOOLS_SETTINGS_SCHEMA_VERSION}" '
    def uint_string:
      type == "string" and length > 0 and length <= 20 and
      test("^(0|[1-9][0-9]*)$");
    type == "object" and
    keys == ["coinSelection", "schemaVersion", "tokenFragmentation", "utxoManagement"] and
    .schemaVersion == $schema and
    (.coinSelection | type == "object" and keys == ["strategy"] and
      (.strategy == "balanced" or .strategy == "fewest-inputs")) and
    (.tokenFragmentation | type == "object" and
      keys == ["enabled", "maxAssetsPerOutput"] and
      (.enabled | type == "boolean") and
      (.maxAssetsPerOutput | type == "number" and floor == . and
        . >= 1 and . <= 100)) and
    (.utxoManagement | type == "object" and
      keys == ["collateral", "enabled", "maxNewOutputs", "minimumLovelace", "percentages", "targetCount"] and
      (.enabled | type == "boolean") and
      (.targetCount | type == "number" and floor == . and . >= 1 and . <= 12) and
      (.maxNewOutputs | type == "number" and floor == . and . >= 1 and . <= 6) and
      (.maxNewOutputs <= (.percentages | length)) and
      (.minimumLovelace | uint_string) and
      (.percentages | type == "array" and length >= 1 and length <= 6 and
        all(.[]; type == "number" and floor == . and . >= 1 and . <= 75) and
        . == sort and length == (unique | length) and add <= 75) and
      (.collateral | type == "object" and
        keys == ["enabled", "lovelace", "targetCount"] and
        (.enabled | type == "boolean") and
        (.targetCount | type == "number" and floor == . and . >= 0 and . <= 2) and
        (.lovelace | uint_string)))
  ' "${file}" >/dev/null 2>&1
}

cntools_settings_apply_file() {
  local file="${1:-}"
  local record=""
  local sentinel=""

  cntools_settings_file_valid "${file}" || return 1
  record="$(jq -er '
    [
      .coinSelection.strategy,
      (if .tokenFragmentation.enabled then "Y" else "N" end),
      (.tokenFragmentation.maxAssetsPerOutput | tostring),
      (if .utxoManagement.enabled then "Y" else "N" end),
      (.utxoManagement.targetCount | tostring),
      (.utxoManagement.percentages | map(tostring) | join(",")),
      (.utxoManagement.maxNewOutputs | tostring),
      .utxoManagement.minimumLovelace,
      (if .utxoManagement.collateral.enabled then "Y" else "N" end),
      (.utxoManagement.collateral.targetCount | tostring),
      .utxoManagement.collateral.lovelace,
      "."
    ] | join("\u001f")
  ' "${file}")" || return 1
  IFS=$'\037' read -r \
    CNTOOLS_TX_SELECTION_STRATEGY \
    CNTOOLS_TX_TOKEN_FRAGMENTATION \
    CNTOOLS_TX_TOKEN_MAX_ASSETS \
    CNTOOLS_TX_UTXO_MANAGEMENT \
    CNTOOLS_TX_UTXO_TARGET_COUNT \
    CNTOOLS_TX_UTXO_PERCENTAGES \
    CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS \
    CNTOOLS_TX_UTXO_MIN_LOVELACE \
    CNTOOLS_TX_COLLATERAL_MANAGEMENT \
    CNTOOLS_TX_COLLATERAL_TARGET_COUNT \
    CNTOOLS_TX_COLLATERAL_LOVELACE \
    sentinel <<< "${record}"
  [[ "${sentinel}" == "." ]]
}

cntools_settings_values_valid() {
  local value=""
  local previous=0
  local sum=0
  local -a percentages=()

  case "${CNTOOLS_TX_SELECTION_STRATEGY:-}" in
    balanced|fewest-inputs) ;;
    *) return 1 ;;
  esac
  [[ "${CNTOOLS_TX_TOKEN_FRAGMENTATION:-}" =~ ^[YN]$ &&
     "${CNTOOLS_TX_UTXO_MANAGEMENT:-}" =~ ^[YN]$ &&
     "${CNTOOLS_TX_COLLATERAL_MANAGEMENT:-}" =~ ^[YN]$ &&
     "${CNTOOLS_TX_TOKEN_MAX_ASSETS:-}" =~ ^[0-9]{1,3}$ &&
     "${CNTOOLS_TX_UTXO_TARGET_COUNT:-}" =~ ^[0-9]{1,2}$ &&
     "${CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS:-}" =~ ^[0-9]$ &&
     "${CNTOOLS_TX_UTXO_MIN_LOVELACE:-}" =~ ^(0|[1-9][0-9]{0,19})$ &&
     "${CNTOOLS_TX_COLLATERAL_TARGET_COUNT:-}" =~ ^[0-9]$ &&
     "${CNTOOLS_TX_COLLATERAL_LOVELACE:-}" =~ ^(0|[1-9][0-9]{0,19})$ ]] ||
    return 1
  (( 10#${CNTOOLS_TX_TOKEN_MAX_ASSETS} >= 1 &&
     10#${CNTOOLS_TX_TOKEN_MAX_ASSETS} <= 100 &&
     10#${CNTOOLS_TX_UTXO_TARGET_COUNT} >= 1 &&
     10#${CNTOOLS_TX_UTXO_TARGET_COUNT} <= 12 &&
     10#${CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS} >= 1 &&
     10#${CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS} <= 6 &&
     10#${CNTOOLS_TX_COLLATERAL_TARGET_COUNT} <= 2 )) || return 1
  [[ "${CNTOOLS_TX_UTXO_PERCENTAGES:-}" =~ ^[0-9]{1,2}(,[0-9]{1,2})*$ ]] ||
    return 1
  IFS=',' read -r -a percentages <<< "${CNTOOLS_TX_UTXO_PERCENTAGES}"
  (( ${#percentages[@]} >= 1 && ${#percentages[@]} <= 6 &&
     CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS <= ${#percentages[@]} )) || return 1
  for value in "${percentages[@]}"; do
    (( 10#${value} >= 1 && 10#${value} <= 75 &&
       10#${value} > previous )) || return 1
    previous=$((10#${value}))
    sum=$((sum + previous))
  done
  (( sum <= 75 ))
}

cntools_settings_json() {
  local token_enabled=false
  local utxo_enabled=false
  local collateral_enabled=false
  local percentages_json=""

  cntools_settings_values_valid || return 1
  [[ "${CNTOOLS_TX_TOKEN_FRAGMENTATION}" != "Y" ]] || token_enabled=true
  [[ "${CNTOOLS_TX_UTXO_MANAGEMENT}" != "Y" ]] || utxo_enabled=true
  [[ "${CNTOOLS_TX_COLLATERAL_MANAGEMENT}" != "Y" ]] ||
    collateral_enabled=true
  percentages_json="$(jq -cn --arg csv "${CNTOOLS_TX_UTXO_PERCENTAGES}" '
    $csv | split(",") | map(tonumber)
  ')" || return 1
  jq -cn \
    --argjson schemaVersion "${CNTOOLS_SETTINGS_SCHEMA_VERSION}" \
    --arg strategy "${CNTOOLS_TX_SELECTION_STRATEGY}" \
    --argjson tokenEnabled "${token_enabled}" \
    --argjson maxAssets "${CNTOOLS_TX_TOKEN_MAX_ASSETS}" \
    --argjson utxoEnabled "${utxo_enabled}" \
    --argjson targetCount "${CNTOOLS_TX_UTXO_TARGET_COUNT}" \
    --argjson percentages "${percentages_json}" \
    --argjson maxNewOutputs "${CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS}" \
    --arg minimumLovelace "${CNTOOLS_TX_UTXO_MIN_LOVELACE}" \
    --argjson collateralEnabled "${collateral_enabled}" \
    --argjson collateralTarget "${CNTOOLS_TX_COLLATERAL_TARGET_COUNT}" \
    --arg collateralLovelace "${CNTOOLS_TX_COLLATERAL_LOVELACE}" '
      {
        schemaVersion: $schemaVersion,
        coinSelection: {strategy: $strategy},
        tokenFragmentation: {
          enabled: $tokenEnabled,
          maxAssetsPerOutput: $maxAssets
        },
        utxoManagement: {
          enabled: $utxoEnabled,
          targetCount: $targetCount,
          percentages: $percentages,
          maxNewOutputs: $maxNewOutputs,
          minimumLovelace: $minimumLovelace,
          collateral: {
            enabled: $collateralEnabled,
            targetCount: $collateralTarget,
            lovelace: $collateralLovelace
          }
        }
      }
    '
}

cntools_settings_cleanup() {
  local stage="${CNTOOLS_SETTINGS_STAGE_FILE:-}"

  if [[ -n "${stage}" &&
        "${stage}" == "${CNTOOLS_SETTINGS_STATE_DIR:-/invalid}/.transaction-settings."* &&
        -f "${stage}" && ! -L "${stage}" && -O "${stage}" ]]; then
    rm -f -- "${stage}" 2>/dev/null || true
  fi
  CNTOOLS_SETTINGS_STAGE_FILE=""
}

cntools_settings_save() {
  local content=""

  cntools_settings_state_directory_ready || return 1
  content="$(cntools_settings_json)" || return 1
  cntools_settings_cleanup
  CNTOOLS_SETTINGS_STAGE_FILE="$(mktemp \
    "${CNTOOLS_SETTINGS_STATE_DIR}/.transaction-settings.XXXXXX")" || return 1
  if ! chmod 0600 "${CNTOOLS_SETTINGS_STAGE_FILE}" ||
     ! printf '%s\n' "${content}" > "${CNTOOLS_SETTINGS_STAGE_FILE}" ||
     ! mv -f -- "${CNTOOLS_SETTINGS_STAGE_FILE}" "${CNTOOLS_SETTINGS_FILE}";
  then
    cntools_settings_cleanup
    return 1
  fi
  CNTOOLS_SETTINGS_STAGE_FILE=""
  cntools_settings_apply_file "${CNTOOLS_SETTINGS_FILE}" || return 1
  cntools_settings_log SETTINGS \
    "saved selection=${CNTOOLS_TX_SELECTION_STRATEGY} token_fragmentation=${CNTOOLS_TX_TOKEN_FRAGMENTATION} max_assets=${CNTOOLS_TX_TOKEN_MAX_ASSETS} utxo_management=${CNTOOLS_TX_UTXO_MANAGEMENT} target=${CNTOOLS_TX_UTXO_TARGET_COUNT} percentages=${CNTOOLS_TX_UTXO_PERCENTAGES} collateral=${CNTOOLS_TX_COLLATERAL_MANAGEMENT}"
}

cntools_settings_init() {
  cntools_settings_defaults
  if ! cntools_settings_state_paths; then
    cntools_settings_log WARN \
      "Transaction settings persistence is unavailable; using safe defaults"
    return 0
  fi
  if [[ ! -e "${CNTOOLS_SETTINGS_FILE}" &&
        ! -L "${CNTOOLS_SETTINGS_FILE}" ]]; then
    cntools_settings_log SETTINGS "using default transaction settings"
    return 0
  fi
  if ! cntools_settings_apply_file "${CNTOOLS_SETTINGS_FILE}"; then
    cntools_settings_defaults
    cntools_settings_log WARN \
      "Saved transaction settings are unsafe or invalid; using safe defaults"
    return 0
  fi
  cntools_settings_log SETTINGS \
    "loaded selection=${CNTOOLS_TX_SELECTION_STRATEGY} token_fragmentation=${CNTOOLS_TX_TOKEN_FRAGMENTATION} utxo_management=${CNTOOLS_TX_UTXO_MANAGEMENT}"
}

cntools_settings_reload() {
  local previous_strategy="${CNTOOLS_TX_SELECTION_STRATEGY:-balanced}"

  if [[ -e "${CNTOOLS_SETTINGS_FILE:-}" ||
        -L "${CNTOOLS_SETTINGS_FILE:-}" ]]; then
    if ! cntools_settings_apply_file "${CNTOOLS_SETTINGS_FILE}"; then
      cntools_settings_log WARN \
        "Saved transaction settings became unsafe or invalid; retaining ${previous_strategy}"
      return 1
    fi
  else
    cntools_settings_defaults
  fi
  cntools_settings_log SETTINGS \
    "activated selection=${CNTOOLS_TX_SELECTION_STRATEGY} token_fragmentation=${CNTOOLS_TX_TOKEN_FRAGMENTATION} utxo_management=${CNTOOLS_TX_UTXO_MANAGEMENT}"
}

cntools_settings_strategy_name() {
  case "${1:-${CNTOOLS_TX_SELECTION_STRATEGY:-balanced}}" in
    balanced) printf 'Balanced' ;;
    fewest-inputs) printf 'Fewest inputs' ;;
    *) return 2 ;;
  esac
}

cntools_settings_defaults
