#!/usr/bin/env bash
# Persistent transaction-policy editor. Core settings own validation and IO.

cntools_settings_action_on_off() {
  [[ "${1:-N}" == "Y" ]] && printf 'Enabled' || printf 'Disabled'
}

cntools_settings_action_render() {
  local table_width=""
  local widths=""

  table_width="$(cntools_ui_content_width 160 64)" || return 1
  widths="27,$((table_width - 34))"
  cntools_ui_render_detail "Transaction defaults" || return 1
  {
    printf 'Setting\tValue\n'
    printf 'Coin selection\t%s\n' "$(cntools_settings_strategy_name)"
    printf 'Token fragmentation\t%s\n' \
      "$(cntools_settings_action_on_off "${CNTOOLS_TX_TOKEN_FRAGMENTATION}")"
    printf 'Assets per token output\t%s\n' \
      "${CNTOOLS_TX_TOKEN_MAX_ASSETS}"
    printf 'ADA-only UTxO management\t%s\n' \
      "$(cntools_settings_action_on_off "${CNTOOLS_TX_UTXO_MANAGEMENT}")"
    printf 'Desired ADA-only UTxOs\t%s\n' \
      "${CNTOOLS_TX_UTXO_TARGET_COUNT}"
    printf 'Change percentages\t%s%%\n' \
      "${CNTOOLS_TX_UTXO_PERCENTAGES//,/% · }"
    printf 'Collateral candidate\t%s · 5 ADA\n' \
      "$(cntools_settings_action_on_off "${CNTOOLS_TX_COLLATERAL_MANAGEMENT}")"
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
}

cntools_settings_action_choose_toggle() {
  local _cntools_output_name="${1:-}"
  local label="${2:-Setting}"
  local current="${3:-N}"
  local selected=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  if cntools_ui_choose selected "${label}…" "Enabled" "Disabled"; then
    [[ "${selected}" == "Enabled" ]] && _cntools_output_ref="Y" ||
      _cntools_output_ref="N"
    return 0
  fi
  _cntools_output_ref="${current}"
  return 1
}

cntools_settings_action_input_integer() {
  local _cntools_output_name="${1:-}"
  local label="${2:-Value}"
  local current="${3:-}"
  local minimum="${4:-1}"
  local maximum="${5:-100}"
  local entered=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  while true; do
    if ! cntools_ui_input entered "${label}" "${current}"; then
      return 1
    fi
    [[ -n "${entered}" ]] || entered="${current}"
    if [[ "${entered}" =~ ^[0-9]{1,3}$ ]] &&
       (( 10#${entered} >= minimum && 10#${entered} <= maximum )); then
      _cntools_output_ref="$((10#${entered}))"
      return 0
    fi
    cntools_ui_render_status warn \
      "Enter a whole number from ${minimum} through ${maximum}."
  done
}

cntools_settings_action_percentages_valid() {
  local input="${1:-}"
  local value=""
  local previous=0
  local sum=0
  local -a values=()

  input="${input//[[:space:]]/}"
  [[ ${#input} -le 32 &&
     "${input}" =~ ^[0-9]{1,2}(,[0-9]{1,2})*$ ]] || return 1
  IFS=',' read -r -a values <<< "${input}"
  (( ${#values[@]} >= 1 && ${#values[@]} <= 6 )) || return 1
  for value in "${values[@]}"; do
    (( 10#${value} >= 1 && 10#${value} <= 75 &&
       10#${value} > previous )) || return 1
    previous=$((10#${value}))
    sum=$((sum + previous))
  done
  (( sum <= 75 ))
}

cntools_settings_action_edit_percentages() {
  local entered=""
  local -a values=()

  while true; do
    if ! cntools_ui_input entered "Comma-separated percentages" \
        "${CNTOOLS_TX_UTXO_PERCENTAGES}"; then
      return 1
    fi
    [[ -n "${entered}" ]] || entered="${CNTOOLS_TX_UTXO_PERCENTAGES}"
    entered="${entered//[[:space:]]/}"
    if cntools_settings_action_percentages_valid "${entered}"; then
      CNTOOLS_TX_UTXO_PERCENTAGES="${entered}"
      IFS=',' read -r -a values <<< "${entered}"
      if (( CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS > ${#values[@]} )); then
        CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS="${#values[@]}"
      fi
      return 0
    fi
    cntools_ui_render_status warn \
      "Use one to six increasing percentages whose total is no more than 75, for example 10,20,30."
  done
}

cntools_action_cleanup() {
  cntools_settings_cleanup || true
}

cntools_action_main() {
  local selected=""
  local status=0
  local strategy=""
  local -a rows=(
    "Coin selection"
    "Token fragmentation"
    "Maximum assets per token output"
    "ADA-only UTxO management"
    "Desired ADA-only UTxOs"
    "Change percentages"
    "Maintain 5 ADA collateral candidate"
    "Restore safe defaults"
    "Done"
  )

  while true; do
    cntools_ui_action_begin \
      "Transaction Defaults" "/ Settings / Transaction Defaults"
    cntools_settings_action_render || return 1
    printf '\n'
    if cntools_ui_choose selected "Choose a setting…" "${rows[@]}"; then
      status=0
    else
      status=$?
    fi
    if (( status == 1 )); then
      cntools_gum_clear
      return 0
    elif (( status != 0 )); then
      return "${status}"
    fi
    case "${selected}" in
      "Coin selection")
        if cntools_ui_choose strategy "Coin selection…" \
            "Balanced" "Fewest inputs"; then
          [[ "${strategy}" == "Balanced" ]] &&
            CNTOOLS_TX_SELECTION_STRATEGY="balanced" ||
            CNTOOLS_TX_SELECTION_STRATEGY="fewest-inputs"
        else
          continue
        fi
        ;;
      "Token fragmentation")
        cntools_settings_action_choose_toggle \
          CNTOOLS_TX_TOKEN_FRAGMENTATION "Token fragmentation" \
          "${CNTOOLS_TX_TOKEN_FRAGMENTATION}" || continue
        ;;
      "Maximum assets per token output")
        cntools_settings_action_input_integer CNTOOLS_TX_TOKEN_MAX_ASSETS \
          "Maximum assets" "${CNTOOLS_TX_TOKEN_MAX_ASSETS}" 1 100 || continue
        ;;
      "ADA-only UTxO management")
        cntools_settings_action_choose_toggle \
          CNTOOLS_TX_UTXO_MANAGEMENT "ADA-only UTxO management" \
          "${CNTOOLS_TX_UTXO_MANAGEMENT}" || continue
        ;;
      "Desired ADA-only UTxOs")
        cntools_settings_action_input_integer CNTOOLS_TX_UTXO_TARGET_COUNT \
          "Desired count" "${CNTOOLS_TX_UTXO_TARGET_COUNT}" 1 12 || continue
        ;;
      "Change percentages")
        cntools_settings_action_edit_percentages || continue
        ;;
      "Maintain 5 ADA collateral candidate")
        cntools_settings_action_choose_toggle \
          CNTOOLS_TX_COLLATERAL_MANAGEMENT "Collateral candidate" \
          "${CNTOOLS_TX_COLLATERAL_MANAGEMENT}" || continue
        ;;
      "Restore safe defaults")
        if ! cntools_ui_confirm \
            "Restore all transaction settings to their safe defaults?"; then
          continue
        fi
        cntools_settings_defaults
        ;;
      "Done") return 0 ;;
      *) return 2 ;;
    esac
    if ! cntools_settings_save; then
      cntools_log ERROR "Could not persist transaction settings" || true
      cntools_ui_render_status error \
        "The transaction settings could not be saved safely."
      cntools_ui_wait
      return 1
    fi
    cntools_log CHOICE \
      "transaction setting changed selection=${CNTOOLS_TX_SELECTION_STRATEGY} token_fragmentation=${CNTOOLS_TX_TOKEN_FRAGMENTATION} utxo_management=${CNTOOLS_TX_UTXO_MANAGEMENT}" || true
  done
}
