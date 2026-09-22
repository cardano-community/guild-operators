#!/usr/bin/env bash

cntools_action_main() {
  cntools_ui_action_begin 'Clear asset cache' '/ Advanced / Clear asset cache'
  cntools_ui_render_status info 'Asset names and metadata from Koios are cached for one day. Clearing this deployment’s cache affects all networks, not wallet balances or keys.'
  if ! cntools_ui_confirm 'Clear cached asset details?'; then
    cntools_log CHOICE 'Asset cache clearing cancelled' || true
    return 0
  fi
  if cntools_asset_cache_clear; then
    cntools_ui_render_status success 'Asset cache cleared. The next lookup will request fresh metadata from Koios.'
  else
    cntools_ui_render_status error 'The asset cache could not be cleared safely. Check directory ownership and permissions.'
  fi
  cntools_ui_wait
}
