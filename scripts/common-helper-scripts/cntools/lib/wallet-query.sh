#!/usr/bin/env bash
# Wallet query orchestration. Transport, backend parsing, metadata and views
# are declared separately by action metadata; this file owns query state.
# shellcheck disable=SC2034


CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES=1024
CNTOOLS_WALLET_KOIOS_AUTH_PAYLOAD_MAX_BYTES=5120
CNTOOLS_WALLET_KOIOS_RATE_BATCHES=90
CNTOOLS_WALLET_KOIOS_RATE_PAUSE_SECONDS=10
CNTOOLS_WALLET_KOIOS_ADDRESS_SELECT='?select=address%2Cbalance%3A%3Atext%2Cutxo_set'
CNTOOLS_WALLET_KOIOS_ACCOUNT_SELECT='?select=stake_address%2Cstatus%2Cdelegated_pool%2Cdelegated_drep%2Crewards_available%3A%3Atext%2Cdeposit%3A%3Atext'
CNTOOLS_WALLET_KOIOS_ASSET_SELECT='?select=policy_id%2Casset_name%2Casset_name_ascii%2Cfingerprint%2Ctotal_supply%2Cregistry_metadata%3Atoken_registry_metadata%2Cmetadata_20%3Aminting_tx_metadata-%3E%2220%22%2Cmetadata_721%3Aminting_tx_metadata-%3E%22721%22%2Ccip68_metadata'
CNTOOLS_WALLET_LIST_QUERY_LEVEL=""
CNTOOLS_WALLET_LIST_QUERY_SUMMARY=""
CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE=""

cntools_wallet_query_reset() {
  CNTOOLS_WALLET_QUERY_STATUS="unavailable"
  CNTOOLS_WALLET_QUERY_MESSAGE="Live chain data is unavailable."
  CNTOOLS_WALLET_BASE_LOVELACE=""
  CNTOOLS_WALLET_PAYMENT_LOVELACE=""
  CNTOOLS_WALLET_TOTAL_LOVELACE=""
  CNTOOLS_WALLET_REWARD_LOVELACE=""
  CNTOOLS_WALLET_STAKE_DEPOSIT=""
  CNTOOLS_WALLET_REGISTERED="unknown"
  CNTOOLS_WALLET_POOL_DELEGATION=""
  CNTOOLS_WALLET_DREP_DELEGATION=""
  CNTOOLS_WALLET_DREP_DELEGATION_VALID=Y
  CNTOOLS_WALLET_UTXO_COUNT=""
  CNTOOLS_WALLET_ASSET_COUNT=""
  CNTOOLS_WALLET_ASSET_METADATA_STATUS="not-requested"
  CNTOOLS_WALLET_ASSET_IDS=()
  CNTOOLS_WALLET_ASSET_QUANTITIES=()
  CNTOOLS_WALLET_ASSET_FINGERPRINTS=()
  CNTOOLS_WALLET_ASSET_DECIMALS=()
  CNTOOLS_WALLET_ASSET_ASCII_NAMES=()
  CNTOOLS_WALLET_ASSET_METADATA_NAMES=()
  CNTOOLS_WALLET_ASSET_TICKERS=()
  CNTOOLS_WALLET_ASSET_DESCRIPTIONS=()
  CNTOOLS_WALLET_ASSET_URLS=()
  CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES=()
  CNTOOLS_WALLET_ASSET_METADATA_AVAILABLE=()
  CNTOOLS_WALLET_ASSET_METADATA_DECIMALS=()
  CNTOOLS_WALLET_ASSET_METADATA_SOURCES=()
  CNTOOLS_WALLET_ASSET_METADATA_JSON=()
  CNTOOLS_WALLET_ASSET_METADATA_QUERIED=()
  CNTOOLS_WALLET_ASSET_CLASSES=()
  CNTOOLS_WALLET_ASSET_CIP67_LABELS=()
  CNTOOLS_WALLET_FUNDING_EXPECTED=0
  CNTOOLS_WALLET_FUNDING_SUCCEEDED=0
  CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE=""
}

cntools_wallet_query_finalize_funding() {
  local expected="${CNTOOLS_WALLET_FUNDING_EXPECTED:-0}"
  local succeeded="${CNTOOLS_WALLET_FUNDING_SUCCEEDED:-0}"
  local balance_count=0
  local total="0"

  [[ "${expected}" =~ ^[0-9]+$ ]] || expected=0
  [[ "${succeeded}" =~ ^[0-9]+$ ]] || succeeded=0
  if (( expected > 0 && succeeded == expected )); then
    if [[ "${CNTOOLS_WALLET_BASE_LOVELACE}" =~ ^[0-9]+$ ]]; then
      cntools_uint_add_into \
        total "${total}" "${CNTOOLS_WALLET_BASE_LOVELACE}" || return 1
      balance_count=$((balance_count + 1))
    fi
    if [[ "${CNTOOLS_WALLET_PAYMENT_LOVELACE}" =~ ^[0-9]+$ ]]; then
      cntools_uint_add_into \
        total "${total}" "${CNTOOLS_WALLET_PAYMENT_LOVELACE}" || return 1
      balance_count=$((balance_count + 1))
    fi
    if (( balance_count == expected )) &&
       [[ "${CNTOOLS_WALLET_UTXO_COUNT}" =~ ^[0-9]+$ &&
          "${CNTOOLS_WALLET_ASSET_COUNT}" =~ ^[0-9]+$ ]]; then
      CNTOOLS_WALLET_TOTAL_LOVELACE="${total}"
      return 0
    fi
    cntools_wallet_log ERROR \
      "Funding query completed without a complete aggregate result"
  fi

  CNTOOLS_WALLET_TOTAL_LOVELACE=""
  CNTOOLS_WALLET_UTXO_COUNT=""
  CNTOOLS_WALLET_ASSET_COUNT=""
}

cntools_wallet_query() {
  local base_address="${1:-}"
  local payment_address="${2:-}"
  local reward_address="${3:-}"

  cntools_wallet_query_reset
  if [[ -n "${base_address}" && "${base_address}" == "${payment_address}" ]]; then
    payment_address=""
    cntools_wallet_log WALLET \
      "Identical base and payment address detected; querying it once"
  fi
  [[ -z "${base_address}" ]] ||
    CNTOOLS_WALLET_FUNDING_EXPECTED=$((CNTOOLS_WALLET_FUNDING_EXPECTED + 1))
  [[ -z "${payment_address}" ]] ||
    CNTOOLS_WALLET_FUNDING_EXPECTED=$((CNTOOLS_WALLET_FUNDING_EXPECTED + 1))
  case "${CNTOOLS_MODE:-offline}" in
    offline)
      CNTOOLS_WALLET_QUERY_STATUS="offline"
      CNTOOLS_WALLET_QUERY_MESSAGE="Offline mode — live balances and delegation are not queried."
      cntools_wallet_log WALLET "wallet query skipped in offline mode"
      ;;
    local)
      cntools_wallet_query_local \
        "${base_address}" "${payment_address}" "${reward_address}"
      ;;
    light)
      cntools_wallet_query_koios \
        "${base_address}" "${payment_address}" "${reward_address}"
      ;;
    *) return 2 ;;
  esac
  cntools_wallet_query_finalize_funding
  cntools_wallet_log WALLET \
    "wallet query status=${CNTOOLS_WALLET_QUERY_STATUS} backend=${CNTOOLS_BACKEND}"
}

cntools_wallet_query_details() {
  cntools_wallet_query "$@" || return $?
  if [[ "${CNTOOLS_MODE:-offline}" == "local" &&
        "${CNTOOLS_KOIOS_ENABLED:-Y}" == "Y" &&
        "${CNTOOLS_WALLET_ASSET_COUNT:-}" =~ ^[1-9][0-9]*$ ]]; then
    # CIP-14 is deterministic. Establish it locally before optional Koios
    # enrichment so an API response can never replace the local value.
    cntools_wallet_asset_fill_fingerprints
    cntools_wallet_log WALLET \
      "local native-asset holdings ready; requesting metadata from Koios API"
    if cntools_wallet_query_koios_asset_metadata; then
      cntools_wallet_log WALLET \
        "native-asset metadata source=koios status=available"
    else
      cntools_wallet_log WALLET \
        "Koios token metadata is incomplete; preserving local holdings"
    fi
  fi
  cntools_wallet_asset_fill_fingerprints
}

cntools_wallet_action_show() {
  local status=0

  if cntools_wallet_action_show_impl; then
    status=0
  else
    status=$?
  fi
  cntools_wallet_query_cleanup || true
  cntools_wallet_cleanup_material || true
  return "${status}"
}
