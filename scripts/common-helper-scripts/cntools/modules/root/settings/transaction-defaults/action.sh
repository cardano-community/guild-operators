#!/usr/bin/env bash
# Persistent transaction-policy editor. Core settings own validation and IO.

cntools_settings_action_on_off() {
  [[ "${1:-N}" == "Y" ]] && printf 'Enabled' || printf 'Disabled'
}

# Whole minutes, hours or days when exact; otherwise grouped seconds.
cntools_settings_action_duration() {
  local seconds="${1:-0}" unit='' count=0
  [[ "${seconds}" =~ ^[0-9]+$ ]] || { printf '%s' "${seconds}"; return 0; }
  if (( seconds == 0 )); then printf 'No expiry'; return 0; fi
  if (( seconds % 86400 == 0 )); then count=$((seconds / 86400)); unit=day
  elif (( seconds % 3600 == 0 )); then count=$((seconds / 3600)); unit=hour
  elif (( seconds % 60 == 0 )); then count=$((seconds / 60)); unit=minute
  else printf '%s seconds' "$(cntools_number_format "${seconds}")"; return 0; fi
  (( count == 1 )) || unit+=s
  printf '%s %s' "$(cntools_number_format "${count}")" "${unit}"
}

cntools_settings_action_collateral_amount() {
  local lovelace="${CNTOOLS_TX_COLLATERAL_LOVELACE:-5000000}"
  if [[ "${lovelace}" =~ ^[0-9]+$ ]] && (( lovelace % 1000000 == 0 )); then
    printf '%s ADA' "$(cntools_number_format "$((lovelace / 1000000))")"
  else cntools_number_format_lovelace "${lovelace}" | tr -d '\n'; fi
}

# Table labels are the menu rows, so each value is found under its own name.
# Rows that depend on a disabled feature say they are inactive.
cntools_settings_action_render() {
  local table_width=""
  local widths=""
  local ada_only="" fragmentation=""

  table_width="$(cntools_ui_content_width 160 64)" || return 1
  widths="33,$((table_width - 40))"
  cntools_ui_render_detail "Transaction defaults" || return 1
  [[ "${CNTOOLS_TX_UTXO_MANAGEMENT}" == Y ]] || ada_only=' · inactive (ADA-only management disabled)'
  [[ "${CNTOOLS_TX_TOKEN_FRAGMENTATION}" == Y ]] || fragmentation=' · inactive (token fragmentation disabled)'
  {
    printf 'Setting\tValue\n'
    printf 'Coin selection\t%s\n' "$(cntools_settings_strategy_name)"
    printf 'Send change-address choice\t%s\n' "$(cntools_settings_action_on_off "${CNTOOLS_SEND_CHOOSE_CHANGE:-N}")"
    printf 'Default transaction expiry\t%s\n' "$(cntools_settings_action_duration "${CNTOOLS_TX_DEFAULT_TTL:-1800}")"
    printf 'Token fragmentation\t%s\n' \
      "$(cntools_settings_action_on_off "${CNTOOLS_TX_TOKEN_FRAGMENTATION}")"
    printf 'Maximum assets per token output\t%s%s\n' \
      "${CNTOOLS_TX_TOKEN_MAX_ASSETS}" "${fragmentation}"
    printf 'ADA-only UTxO management\t%s\n' \
      "$(cntools_settings_action_on_off "${CNTOOLS_TX_UTXO_MANAGEMENT}")"
    printf 'Desired ADA-only UTxOs\t%s%s\n' \
      "${CNTOOLS_TX_UTXO_TARGET_COUNT}" "${ada_only}"
    printf 'Change percentages\t%s%%%s\n' \
      "${CNTOOLS_TX_UTXO_PERCENTAGES//,/% · }" "${ada_only}"
    printf 'Collateral candidate\t%s · %s%s\n' \
      "$(cntools_settings_action_on_off "${CNTOOLS_TX_COLLATERAL_MANAGEMENT}")" "$(cntools_settings_action_collateral_amount)" "${ada_only}"
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
}

cntools_settings_action_explain() {
  local setting="${1:-}" message="" width=""

  case "${setting}" in
    'Coin selection')
      message=$'Balanced: prefer simple ADA-only inputs and avoid carrying\nunneeded native assets into the transaction.\nFewest inputs: prioritize fewer, larger inputs; this can bring\nmore native assets into change.\nBoth select inputs automatically from the wallet.'
      ;;
    'Send change-address choice')
      message=$'Enabled: Send asks where change should return when the wallet\nhas both base and payment-only addresses.\nDisabled: change returns to the primary address.\nThis changes only returned change, not input selection.\nPayment-only change does not participate in staking.'
      ;;
    'Default transaction expiry')
      message=$'Starting expiry for new transactions, in seconds.\n1,800 seconds = 30 minutes. Longer periods allow offline signing.\n0 means no expiry; native-script time limits still apply.\nYou can change the expiry while creating a transaction.\nAllowed: 0 through 31,536,000. Enter keeps the current value.'
      ;;
    'Token fragmentation')
      message=$'Enabled: split token change using the configured maximum number\nof distinct native assets per output.\nDisabled: keep token change together unless protocol limits\nrequire a split. More outputs need more ADA and can raise fees.\nThis shapes change only; it does not reorganize existing UTxOs.'
      ;;
    'Maximum assets per token output')
      message=$'Maximum distinct native assets in a token-change output when\nfragmentation is enabled. This counts asset types, not units.\nLower limits create smaller bundles but need more outputs and ADA.\nAllowed: 1 through 100. Enter keeps the current value.'
      ;;
    'ADA-only UTxO management')
      message=$'Enabled: use change to create useful ADA-only outputs, counting\nthose already left in the wallet after input selection.\nDisabled: do not create optional ADA-only management outputs.\nToken change is funded first. Fees, minimum ADA and output limits\ncan reduce what is created. This is not background maintenance.'
      ;;
    'Desired ADA-only UTxOs')
      message=$'Target number of useful ADA-only UTxOs after a transaction,\nincluding existing outputs and planned residual change.\nThe separately maintained collateral candidate is not counted.\nOnly missing outputs are added; the target is not guaranteed.\nRequires ADA-only management. Allowed: 1 through 12.\nEnter keeps the current value.'
      ;;
    'Change percentages')
      message=$'Each percentage uses the same remaining ADA change after token\noutputs and any new collateral candidate have been funded.\nFor example, 10,20,30 creates differently sized outputs where\nneeded; the remainder stays in residual change.\nRequires ADA-only management. Enter one to six increasing values\nfrom 1 through 75, with a combined total no greater than 75.\nOnly missing outputs that can be funded are created.\nEnter keeps the current values.'
      ;;
    'Collateral candidate')
      message="Enabled: try to retain a suitable ADA-only output, or create"$'\n'"a $(cntools_settings_action_collateral_amount) collateral candidate from change when one is missing."$'\nDisabled: do not specially retain or create a candidate.\nRequires ADA-only UTxO management and sufficient change.\nThis does not lock funds or use collateral in this transaction.'
      ;;
    'Restore safe defaults')
      message=$'Restore safe defaults: replace all transaction preferences with\nthe built-in defaults. Cancel keeps your current preferences.\nDefaults use Balanced inputs and primary-address change, with\na 30-minute expiry. Token fragmentation and ADA-only UTxO\nmanagement are disabled. Wallet files, funds, theme and flow style are unchanged.'
      ;;
    'Done') return 0 ;;
    *) return 2 ;;
  esac
  cntools_ui_action_begin "${setting}" "/ Settings / Transaction Defaults / ${setting}" || return 1
  width="$(cntools_ui_content_width 100 42)" || return 1
  cntools_ui_render_status info "${message}" "$((width - 4))"
}

# The current value is marked and listed first, so Enter keeps it.
cntools_settings_action_choose_toggle() {
  local _cntools_output_name="${1:-}"
  local label="${2:-Setting}"
  local current="${3:-N}"
  local selected=""
  local toggle_status=0
  local -a options=('Enabled' 'Disabled')

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  if [[ "${current}" == Y ]]; then options=('Enabled · current' 'Disabled')
  else options=('Disabled · current' 'Enabled'); fi
  # Esc keeps the value (1); Ctrl+C (130) leaves the editor.
  cntools_ui_choose selected "${label}…" "${options[@]}" "Cancel" || toggle_status=$?
  (( toggle_status == 0 )) || return "${toggle_status}"
  case "${selected%% · current}" in
    Enabled) _cntools_output_ref=Y; return 0 ;;
    Disabled) _cntools_output_ref=N; return 0 ;;
    Cancel) return 1 ;;
    *) return 2 ;;
  esac
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
  # Straight to the input under the explanation: Esc cancels, Enter keeps
  # the current value and an invalid number asks again.
  while true; do
    cntools_ui_input entered "${label}" "${current}" || return $?
    [[ -n "${entered}" ]] || entered="${current}"
    cntools_number_normalize_into entered "${entered}" || entered=invalid
    if [[ "${entered}" =~ ^[0-9]{1,8}$ ]] &&
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

  # Esc cancels, Enter keeps the current values, invalid input asks again.
  while true; do
    cntools_ui_input entered "Comma-separated percentages" \
      "${CNTOOLS_TX_UTXO_PERCENTAGES}" || return $?
    [[ -n "${entered}" ]] || entered="${CNTOOLS_TX_UTXO_PERCENTAGES}"
    entered="${entered//[[:space:]]/}"
    if cntools_settings_action_percentages_valid "${entered}"; then
      CNTOOLS_TX_UTXO_PERCENTAGES="${entered}"
      IFS=',' read -r -a values <<< "${entered}"
      # One new output per percentage: more percentages raise the limit too.
      # shellcheck disable=SC2034 # Saved by cntools_settings_save.
      CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS="${#values[@]}"
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
  local restore_choice=""
  local -a strategies=()
  local -a rows=(
    "Coin selection"
    "Send change-address choice"
    "Default transaction expiry"
    "Token fragmentation"
    "Maximum assets per token output"
    "ADA-only UTxO management"
    "Desired ADA-only UTxOs"
    "Change percentages"
    "Collateral candidate"
    "Restore safe defaults"
    "Done"
  )

  while true; do
    cntools_ui_action_begin \
      "Transaction Defaults" "/ Settings / Transaction Defaults"
    # A failed render or explanation is not shown yet: 2 gives the menu banner.
    cntools_settings_action_render || return 2
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
    cntools_settings_action_explain "${selected}" || return 2
    # Esc (1) keeps the value and returns to the list; Ctrl+C (130) leaves.
    status=0
    case "${selected}" in
      'Send change-address choice')
        cntools_settings_action_choose_toggle CNTOOLS_SEND_CHOOSE_CHANGE 'Choose Send change address' "${CNTOOLS_SEND_CHOOSE_CHANGE:-N}" || status=$? ;;
      'Default transaction expiry')
        cntools_settings_action_input_integer CNTOOLS_TX_DEFAULT_TTL 'Seconds (0 for no expiry)' "${CNTOOLS_TX_DEFAULT_TTL:-1800}" 0 31536000 || status=$? ;;
      "Coin selection")
        if [[ "${CNTOOLS_TX_SELECTION_STRATEGY:-balanced}" == fewest-inputs ]]; then strategies=('Fewest inputs · current' 'Balanced')
        else strategies=('Balanced · current' 'Fewest inputs'); fi
        cntools_ui_choose strategy "Coin selection…" "${strategies[@]}" "Cancel" || status=$?
        if (( status == 0 )); then
          case "${strategy%% · current}" in
            Balanced) CNTOOLS_TX_SELECTION_STRATEGY=balanced ;;
            'Fewest inputs') CNTOOLS_TX_SELECTION_STRATEGY=fewest-inputs ;;
            Cancel) status=1 ;;
            *) return 2 ;;
          esac
        fi
        ;;
      "Token fragmentation")
        cntools_settings_action_choose_toggle \
          CNTOOLS_TX_TOKEN_FRAGMENTATION "Token fragmentation" \
          "${CNTOOLS_TX_TOKEN_FRAGMENTATION}" || status=$?
        ;;
      "Maximum assets per token output")
        cntools_settings_action_input_integer CNTOOLS_TX_TOKEN_MAX_ASSETS \
          "Maximum assets" "${CNTOOLS_TX_TOKEN_MAX_ASSETS}" 1 100 || status=$?
        ;;
      "ADA-only UTxO management")
        cntools_settings_action_choose_toggle \
          CNTOOLS_TX_UTXO_MANAGEMENT "ADA-only UTxO management" \
          "${CNTOOLS_TX_UTXO_MANAGEMENT}" || status=$?
        ;;
      "Desired ADA-only UTxOs")
        cntools_settings_action_input_integer CNTOOLS_TX_UTXO_TARGET_COUNT \
          "Desired count" "${CNTOOLS_TX_UTXO_TARGET_COUNT}" 1 12 || status=$?
        ;;
      "Change percentages")
        cntools_settings_action_edit_percentages || status=$?
        ;;
      "Collateral candidate")
        cntools_settings_action_choose_toggle \
          CNTOOLS_TX_COLLATERAL_MANAGEMENT "Collateral candidate" \
          "${CNTOOLS_TX_COLLATERAL_MANAGEMENT}" || status=$?
        ;;
      "Restore safe defaults")
        cntools_ui_choose restore_choice "Restore transaction defaults…" \
          "Cancel" "Restore safe defaults" || status=$?
        if (( status == 0 )); then
          case "${restore_choice}" in
            Cancel) status=1 ;;
            'Restore safe defaults') cntools_settings_defaults ;;
            *) return 2 ;;
          esac
        fi
        ;;
      "Done") return 0 ;;
      *) return 2 ;;
    esac
    (( status != 1 )) || continue
    (( status == 0 )) || return "${status}"
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
