#!/usr/bin/env bash
# Amount precision selector. The preference is owned by core/settings.sh and
# applied by lib/number.sh.

cntools_action_cleanup() {
  cntools_settings_cleanup || true
}

cntools_decimals_choose_into() {
  local _cntools_output_name="${1:-}"
  local selected=""
  local trim_label="Trimmed · 340 ADA, 340.05 ADA"
  local full_label="Full precision · 340.000000 ADA, 340.050000 ADA"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  case "${CNTOOLS_AMOUNT_PRECISION:-}" in
    full) full_label+=" · current" ;;
    *) trim_label+=" · current" ;;
  esac
  cntools_ui_render_status info $'Trimmed drops the trailing zeros of ADA and token amounts. Full precision\nshows every decimal place: six for ADA, and a token\'s registered decimals.\nAmounts you enter are never rounded either way.' || return 1
  cntools_ui_choose selected 'Decimals' "${trim_label}" "${full_label}" Cancel || return $?
  case "${selected}" in
    "${trim_label}") _cntools_output_ref=trim ;;
    "${full_label}") _cntools_output_ref=full ;;
    Cancel) return 1 ;;
    *) return 2 ;;
  esac
}

cntools_action_main() {
  local precision="" status=0

  cntools_ui_action_begin "Decimals" "/ Settings / Decimals"
  cntools_decimals_choose_into precision || status=$?
  if (( status == 1 )); then
    cntools_log CHOICE "amount precision selection cancelled" || true
    cntools_gum_clear
    return 0
  elif (( status != 0 )); then
    return "${status}"
  fi
  cntools_ui_action_begin "Decimals" "/ Settings / Decimals"
  if cntools_amount_precision_save "${precision}"; then
    cntools_ui_render_status success \
      "Saved: $(cntools_amount_precision_name "${precision}"). For example $(cntools_number_format_lovelace 340050000)."
  else
    cntools_ui_render_status error \
      "Amount precision could not be saved and is unchanged. See ${CNTOOLS_LOG}."
  fi
  cntools_ui_wait
}
