#!/usr/bin/env bash
# Focused orchestration tests for Transaction -> Sign and Submit.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools transaction UI tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
UI_LIBRARY="${CNTOOLS_ROOT}/lib/transaction-ui.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-transaction-ui.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
TRACE="${TEST_ROOT}/events.log"
LOG_TRACE="${TEST_ROOT}/cntools.log"
TABLE_TRACE="${TEST_ROOT}/tables.log"
SIGN_INPUT="${TEST_ROOT}/sign.package.json"
PREPARED_INPUT="${TEST_ROOT}/sign.prepared.json"
NATIVE_INPUT="${TEST_ROOT}/native.package.json"
SIGNED_INPUT="${TEST_ROOT}/transaction.signed.json"
SIGN_OUTPUT="${TEST_ROOT}/sign.output.json"
HW_SOURCE="${TEST_ROOT}/ledger-payment.hwsfile"
KEY_ID="$(printf '11%.0s' {1..32})"
TX_ID="$(printf 'aa%.0s' {1..32})"
SCRIPT_HASH="$(printf 'bb%.0s' {1..28})"
REFERENCE_INPUT="$(printf 'cc%.0s' {1..32})#0"

cleanup_test() {
  chmod -R u+rwx -- "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="${3:-values differ}"

  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_trace_contains() {
  grep -F -- "$1" "${TRACE}" >/dev/null ||
    fail "${2:-trace entry is missing}: $1"
}

assert_trace_absent() {
  if grep -F -- "$1" "${TRACE}" >/dev/null; then
    fail "${2:-unexpected trace entry}: $1"
  fi
}

assert_trace_count() {
  local expected="$1"
  local entry="$2"
  local actual=""

  actual="$(grep -Fc -- "${entry}" "${TRACE}" || true)"
  assert_eq "${actual}" "${expected}" \
    "${3:-unexpected trace entry count}: ${entry}"
}

assert_table_contains() {
  grep -F -- "$1" "${TABLE_TRACE}" >/dev/null ||
    fail "${2:-table entry is missing}: $1"
}

trace_line() {
  local event="$1"

  awk -v event="${event}" '$0 == event { print NR; exit }' "${TRACE}"
}

assert_trace_before() {
  local first="$1"
  local second="$2"
  local context="${3:-events are out of order}"
  local first_line=""
  local second_line=""

  first_line="$(trace_line "${first}")"
  second_line="$(trace_line "${second}")"
  [[ "${first_line}" =~ ^[0-9]+$ && "${second_line}" =~ ^[0-9]+$ &&
     ${first_line} -lt ${second_line} ]] ||
    fail "${context}: '${first}' must precede '${second}'"
}

assert_file_absent() {
  [[ ! -e "$1" && ! -L "$1" ]] ||
    fail "${2:-unexpected output exists}: $1"
}

trace_event() {
  printf '%s\n' "$*" >> "${TRACE}"
}

write_sign_package() {
  local output_file="$1"
  local hardware_prepared="$2"

  jq -n --arg key_id "${KEY_ID}" --arg tx_id "${TX_ID}" \
    --argjson prepared "${hardware_prepared}" '
    {
      intent: {
        kind: "Test transfer",
        description: "Transaction UI fixture",
        summary: {}
      },
      network: {name: "preview", magic: 2},
      validity: {invalidBefore: null, invalidHereafter: null},
      transaction: {
        id: $tx_id,
        hardwarePrepared: $prepared,
        body: {type: "TxBody ConwayEra", cborHex: "aa00"}
      },
      signing: {
        assurance: "exact",
        required: [{
          keyId: $key_id,
          credential: ($key_id[0:56]),
          labels: ["Ledger payment"],
          roles: ["spending"],
          preferredKind: "hardware",
          hardwareGroup: "ledger-main"
        }],
        changeKeys: [],
        nativeScripts: [],
        witnesses: []
      },
      signedTransaction: null
    }
  ' > "${output_file}" || fail "could not create signing fixture"
  chmod 0600 "${output_file}"
}

for required_command in awk bash cat chmod grep jq mktemp rm; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required test command is unavailable: ${required_command}"
done
[[ -f "${UI_LIBRARY}" && ! -L "${UI_LIBRARY}" && -s "${UI_LIBRARY}" ]] ||
  fail "transaction UI library is missing or unsafe"
bash -n "${UI_LIBRARY}" || fail "transaction UI library has invalid Bash syntax"

mkdir -p "${TEST_ROOT}"
chmod 0700 "${TEST_ROOT}"
: > "${TRACE}"
: > "${LOG_TRACE}"
: > "${TABLE_TRACE}"
chmod 0600 "${TRACE}" "${LOG_TRACE}" "${TABLE_TRACE}"
write_sign_package "${SIGN_INPUT}" false
write_sign_package "${PREPARED_INPUT}" true
jq --arg script_hash "${SCRIPT_HASH}" --arg reference "${REFERENCE_INPUT}" \
  --arg key_id "${KEY_ID}" '
  .signing.nativeScripts = [{
    label: "Reference policy",
    purpose: "mint",
    source: "reference",
    referenceInput: $reference,
    scriptHash: $script_hash,
    selectedKeyIds: [$key_id],
    script: {type: "all", scripts: []}
  }]
' "${SIGN_INPUT}" > "${NATIVE_INPUT}"
chmod 0600 "${NATIVE_INPUT}"
jq -n '{
  type: "Tx ConwayEra",
  description: "Signed transaction fixture",
  cborHex: "aa00"
}' > "${SIGNED_INPUT}"
chmod 0600 "${SIGNED_INPUT}"

# shellcheck source=/dev/null
. "${UI_LIBRARY}"

CNTOOLS_LOG="${LOG_TRACE}"
CNTOOLS_NETWORK="preview"
CNTOOLS_BACKEND="cnode"
CNTOOLS_KOIOS_ENABLED="Y"
CNTOOLS_KOIOS_API="https://preview.koios.rest/api/v1"
CNTOOLS_GUM_COLOR_DIVIDER="divider"
CNTOOLS_GUM_COLOR_TEXT="text"
CNTOOLS_TRANSACTION_ERROR=""
CNTOOLS_TRANSACTION_SELECTED_KEY_IDS=()
CNTOOLS_TRANSACTION_SELECTED_SOURCES=()
CNTOOLS_TRANSACTION_SELECTED_KINDS=()
CNTOOLS_TRANSACTION_SELECTED_HARDWARE_GROUPS=()
CNTOOLS_TRANSACTION_SELECTED_CHANGE_KEY_IDS=()
CNTOOLS_TRANSACTION_SELECTED_CHANGE_SOURCES=()
CNTOOLS_TRANSACTION_SELECTED_CHANGE_HARDWARE_GROUPS=()

INPUT_INDEX=0
CONFIRM_INDEX=0
CONFIRM_SIDE_EFFECT=""
LOCAL_READY_CALLS=0
LOCAL_READY_DEFAULT=1
PACKAGE_LOAD_STATUS=0
SUBMIT_PREPARE_STATUS=0
KOIOS_SUBMIT_STATUS=0
SIGN_CALLS=0
LOCAL_SUBMIT_CALLS=0
KOIOS_SUBMIT_CALLS=0
declare -a CONFIRM_RESULTS=()
declare -a INPUT_VALUES=()
declare -a INPUT_STATUSES=()
declare -a LOCAL_READY_RESULTS=()

cntools_log() {
  printf '%s\t%s\n' "${1:-INFO}" "${2:-}" >> "${LOG_TRACE}"
  trace_event "log:${1:-INFO}:${2:-}"
}

cntools_transaction_log() {
  cntools_log "${1:-INFO}" "${2:-}"
}

cntools_transaction_set_error() {
  CNTOOLS_TRANSACTION_ERROR="${1:-Transaction operation failed.}"
  cntools_transaction_log ERROR "${CNTOOLS_TRANSACTION_ERROR}"
}

cntools_ui_action_begin() {
  trace_event "ui:begin:${1:-}:${2:-}"
}

cntools_ui_render_status() {
  trace_event "ui:status:${1:-}:${2:-}"
}

cntools_ui_render_field() {
  trace_event "ui:field:${1:-}:${2:-}"
}

cntools_ui_render_detail() {
  trace_event "ui:detail:${1:-}"
}

cntools_ui_wait() {
  trace_event "ui:wait"
}

cntools_gum_clear() {
  trace_event "ui:clear"
}

cntools_gum() {
  trace_event "gum:${1:-}"
}

cntools_ui_table() {
  trace_event "ui:table"
  cat >> "${TABLE_TRACE}"
}

cntools_ui_content_width() {
  printf '120\n'
}

cntools_theme_style_value_into() {
  local -n output_ref="$1"
  output_ref="$3"
}

cntools_ui_spin_function() {
  local message="$1"
  shift
  trace_event "spin:${message}"
  "$@"
}

cntools_ui_confirm() {
  local result=2

  trace_event "confirm:$1"
  if (( CONFIRM_INDEX < ${#CONFIRM_RESULTS[@]} )); then
    result="${CONFIRM_RESULTS[CONFIRM_INDEX]}"
  fi
  CONFIRM_INDEX=$((CONFIRM_INDEX + 1))
  if [[ "${CONFIRM_SIDE_EFFECT}" == "local-ready" ]]; then
    LOCAL_READY_DEFAULT=0
    CONFIRM_SIDE_EFFECT=""
  fi
  return "${result}"
}

cntools_ui_input() {
  local -n output_ref="$1"
  local result=2

  trace_event "ui:input:${2:-}"
  if (( INPUT_INDEX < ${#INPUT_STATUSES[@]} )); then
    result="${INPUT_STATUSES[INPUT_INDEX]}"
  fi
  if (( result == 0 && INPUT_INDEX < ${#INPUT_VALUES[@]} )); then
    output_ref="${INPUT_VALUES[INPUT_INDEX]}"
  fi
  INPUT_INDEX=$((INPUT_INDEX + 1))
  return "${result}"
}

cntools_transaction_input_path_into() {
  local -n output_ref="$1"
  output_ref="$2"
}

cntools_transaction_default_output_into() {
  local -n output_ref="$1"
  output_ref="${SIGN_OUTPUT}"
}

cntools_transaction_output_path_safe() {
  [[ "$1" == "${SIGN_OUTPUT}" && ! -e "$1" && ! -L "$1" ]]
}

cntools_transaction_package_load() {
  local package_file="$1"

  trace_event "package:load:${package_file}"
  if (( PACKAGE_LOAD_STATUS != 0 )); then
    cntools_transaction_set_error "Package validation fixture failed."
    return "${PACKAGE_LOAD_STATUS}"
  fi
  CNTOOLS_TRANSACTION_PACKAGE_FILE="${package_file}"
  CNTOOLS_TRANSACTION_BODY_FILE="${package_file}.body"
  CNTOOLS_TRANSACTION_ID="$(jq -r '.transaction.id' "${package_file}")"
  CNTOOLS_TRANSACTION_PACKAGE_NETWORK="$(jq -r '.network.name' "${package_file}")"
  CNTOOLS_TRANSACTION_PACKAGE_ASSURANCE="$(jq -r '.signing.assurance' "${package_file}")"
  CNTOOLS_TRANSACTION_PACKAGE_INTENT="$(jq -r '.intent.kind' "${package_file}")"
  CNTOOLS_TRANSACTION_PACKAGE_DESCRIPTION="$(jq -r '.intent.description' "${package_file}")"
  CNTOOLS_TRANSACTION_PACKAGE_INVALID_BEFORE=""
  CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER=""
  CNTOOLS_TRANSACTION_PACKAGE_HARDWARE_PREPARED="$(
    jq -r 'if .transaction.hardwarePrepared then "Y" else "N" end' \
      "${package_file}"
  )"
  CNTOOLS_TRANSACTION_REQUIRED_COUNT="$(jq -r '.signing.required | length' \
    "${package_file}")"
  CNTOOLS_TRANSACTION_WITNESS_COUNT="$(jq -r '.signing.witnesses | length' \
    "${package_file}")"
  CNTOOLS_TRANSACTION_COMPLETE="N"
}

cntools_transaction_view_into() {
  local -n output_ref="$1"

  trace_event "decode:$2"
  output_ref='{"decoded":true,"authoritative":"cardano-cli"}'
}

cntools_transaction_sign_selection_reset() {
  CNTOOLS_TRANSACTION_SELECTED_KEY_IDS=()
  CNTOOLS_TRANSACTION_SELECTED_SOURCES=()
  CNTOOLS_TRANSACTION_SELECTED_KINDS=()
  CNTOOLS_TRANSACTION_SELECTED_HARDWARE_GROUPS=()
  CNTOOLS_TRANSACTION_SELECTED_CHANGE_KEY_IDS=()
  CNTOOLS_TRANSACTION_SELECTED_CHANGE_SOURCES=()
  CNTOOLS_TRANSACTION_SELECTED_CHANGE_HARDWARE_GROUPS=()
}

cntools_transaction_sign_selection_add() {
  CNTOOLS_TRANSACTION_SELECTED_KEY_IDS+=("${KEY_ID}")
  CNTOOLS_TRANSACTION_SELECTED_SOURCES+=("$2")
  CNTOOLS_TRANSACTION_SELECTED_KINDS+=("hardware")
  CNTOOLS_TRANSACTION_SELECTED_HARDWARE_GROUPS+=("ledger-main")
}

cntools_transaction_change_selection_add() {
  return 0
}

cntools_transaction_hardware_group_selection_complete() {
  trace_event "hardware:group-complete:$2"
}

cntools_transaction_hardware_group_change_selection_complete() {
  trace_event "hardware:change-complete:$2"
}

cntools_transaction_source_kind_into() {
  local -n output_ref="$1"
  output_ref="hardware"
}

cntools_transaction_source_key_id_into() {
  local -n output_ref="$1"
  output_ref="${KEY_ID}"
}

cntools_transaction_package_prepare_hardware_into() {
  local -n output_ref="$1"

  trace_event "hardware:prepare:$2"
  output_ref="${PREPARED_INPUT}"
}

cntools_transaction_sign_package() {
  SIGN_CALLS=$((SIGN_CALLS + 1))
  trace_event "sign:execute:$1:$2"
  printf '{}\n' > "$2"
}

cntools_transaction_submit_reset() {
  return 0
}

cntools_transaction_package_reset_loaded() {
  return 0
}

cntools_transaction_clear_error() {
  CNTOOLS_TRANSACTION_ERROR=""
}

cntools_transaction_submit_input_prepare() {
  trace_event "submit:input-prepare:$1"
  if (( SUBMIT_PREPARE_STATUS != 0 )); then
    cntools_transaction_set_error "Signed transaction validation fixture failed."
    return "${SUBMIT_PREPARE_STATUS}"
  fi
  CNTOOLS_TRANSACTION_SUBMIT_INPUT_KIND="external-envelope"
  CNTOOLS_TRANSACTION_SUBMIT_COMPLETENESS="unverified"
  CNTOOLS_TRANSACTION_SUBMIT_VKEY_WITNESS_COUNT=1
  CNTOOLS_TRANSACTION_SUBMIT_ID="${TX_ID}"
  CNTOOLS_TRANSACTION_SIGNED_FILE="${SIGNED_INPUT}"
}

cntools_transaction_submit_local_ready() {
  local result="${LOCAL_READY_DEFAULT}"
  local index="${LOCAL_READY_CALLS}"

  LOCAL_READY_CALLS=$((LOCAL_READY_CALLS + 1))
  if (( index < ${#LOCAL_READY_RESULTS[@]} )); then
    result="${LOCAL_READY_RESULTS[index]}"
  fi
  trace_event "backend:local-ready:${result}"
  return "${result}"
}

cntools_transaction_submit_require_xxd() {
  trace_event "backend:koios-prerequisite"
}

cntools_transaction_submit_local() {
  LOCAL_SUBMIT_CALLS=$((LOCAL_SUBMIT_CALLS + 1))
  trace_event "submit:local:$2"
}

cntools_transaction_submit_koios() {
  KOIOS_SUBMIT_CALLS=$((KOIOS_SUBMIT_CALLS + 1))
  trace_event "submit:koios:$2"
  if (( KOIOS_SUBMIT_STATUS != 0 )); then
    cntools_transaction_set_error "Koios fixture submission failed."
    return "${KOIOS_SUBMIT_STATUS}"
  fi
  CNTOOLS_TRANSACTION_SUBMIT_BACKEND="koios"
  CNTOOLS_TRANSACTION_SUBMIT_MESSAGE="Transaction accepted by Koios."
}

reset_scenario() {
  : > "${TRACE}"
  : > "${LOG_TRACE}"
  : > "${TABLE_TRACE}"
  INPUT_VALUES=()
  INPUT_STATUSES=()
  INPUT_INDEX=0
  CONFIRM_RESULTS=()
  CONFIRM_INDEX=0
  CONFIRM_SIDE_EFFECT=""
  LOCAL_READY_RESULTS=()
  LOCAL_READY_CALLS=0
  LOCAL_READY_DEFAULT=1
  PACKAGE_LOAD_STATUS=0
  SUBMIT_PREPARE_STATUS=0
  KOIOS_SUBMIT_STATUS=0
  SIGN_CALLS=0
  LOCAL_SUBMIT_CALLS=0
  KOIOS_SUBMIT_CALLS=0
  CNTOOLS_MODE="local"
  CNTOOLS_TRANSACTION_ERROR=""
  CNTOOLS_TRANSACTION_UI_SOURCE_FILE=""
  CNTOOLS_TRANSACTION_SUBMIT_COMPLETENESS=""
  CNTOOLS_TRANSACTION_SUBMIT_VKEY_WITNESS_COUNT=0
  rm -f -- "${SIGN_OUTPUT}"
}

test_sign_cancel_after_initial_review() {
  local status=0
  local decode="decode:${SIGN_INPUT}.body"
  local confirm="confirm:Continue and select signing sources for this transaction?"

  reset_scenario
  INPUT_VALUES=("${SIGN_INPUT}")
  INPUT_STATUSES=(0)
  CONFIRM_RESULTS=(1)
  if cntools_transaction_action_sign; then status=0; else status=$?; fi
  assert_eq "${status}" 0 "initial-review cancellation status"
  assert_trace_before "${decode}" "${confirm}" \
    "transaction was not reviewed before the cancellation choice"
  assert_trace_contains \
    "log:CHOICE:transaction package selected id=${TX_ID} path=${SIGN_INPUT}" \
    "accepted signing package was not logged"
  assert_trace_contains \
    "log:CHOICE:transaction signing cancelled after initial review id=${TX_ID}" \
    "initial-review cancellation was not logged"
  assert_trace_contains "ui:clear" "cancelled signing did not clear the UI"
  assert_trace_absent "ui:input:Signing key / HWS path" \
    "cancelled signing requested a private source"
  assert_eq "${SIGN_CALLS}" 0 "cancelled signing call count"
  assert_file_absent "${SIGN_OUTPUT}" "cancelled signing published output"
}

test_hardware_group_defer_is_explicit() {
  local selected="sentinel"
  local status=0
  local message="Hardware session ledger-main must collect every missing group witness together. Select the HWS file for Ledger payment to begin, or leave it blank to defer the entire session."

  reset_scenario
  INPUT_VALUES=("")
  INPUT_STATUSES=(0)
  if cntools_transaction_ui_prompt_signer_into selected \
      "${KEY_ID}" "Ledger payment" hardware ledger-main Y; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" 0 "hardware group deferral status"
  assert_eq "${selected}" "" "hardware group deferral source"
  assert_trace_contains "ui:status:info:${message}" \
    "hardware group did not explain whole-session deferral"
  assert_trace_contains "log:CHOICE:signer deferred id=${KEY_ID}" \
    "hardware group deferral was not logged"
}

test_active_hardware_group_cannot_partially_defer() {
  local selected=""
  local status=0
  local warning="Hardware session ledger-main is already selected. Choose this HWS file, or press Esc to cancel signing."

  reset_scenario
  INPUT_VALUES=("" "${HW_SOURCE}")
  INPUT_STATUSES=(0 0)
  if cntools_transaction_ui_prompt_signer_into selected \
      "${KEY_ID}" "Ledger payment" hardware ledger-main N; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" 0 "active hardware group source status"
  assert_eq "${selected}" "${HW_SOURCE}" \
    "active hardware group source after blank retry"
  assert_trace_count 2 "ui:input:Signing key / HWS path" \
    "active hardware group did not immediately reprompt"
  assert_trace_contains "ui:status:warn:${warning}" \
    "active hardware group retry did not explain the all-or-none rule"
  assert_trace_contains \
    "log:CHOICE:required hardware group signer omitted id=${KEY_ID} group=ledger-main" \
    "partial hardware group attempt was not logged"
}

test_sign_hardware_final_decline() {
  local status=0
  local initial_decode="decode:${SIGN_INPUT}.body"
  local prepared_decode="decode:${PREPARED_INPUT}.body"
  local source_prompt="ui:input:Signing key / HWS path"
  local final_confirm="confirm:Sign the reviewed transaction with the selected sources?"

  reset_scenario
  INPUT_VALUES=("${SIGN_INPUT}" "${HW_SOURCE}" "${SIGN_OUTPUT}")
  INPUT_STATUSES=(0 0 0)
  CONFIRM_RESULTS=(0 1)
  if cntools_transaction_action_sign; then status=0; else status=$?; fi
  assert_eq "${status}" 0 "final signing decline status"
  assert_trace_before "${initial_decode}" "${source_prompt}" \
    "authoritative review did not precede private-source selection"
  assert_trace_before "hardware:prepare:${SIGN_INPUT}" "${prepared_decode}" \
    "hardware preparation did not precede the final review"
  assert_trace_before "${prepared_decode}" "${final_confirm}" \
    "the hardware-prepared transaction was not reviewed before confirmation"
  assert_trace_contains "ui:detail:Decoded transaction · authoritative" \
    "authoritative transaction heading was not rendered"
  assert_trace_contains \
    "log:CHOICE:transaction signing review accepted id=${TX_ID}" \
    "accepted initial review was not logged"
  assert_trace_contains \
    "log:CHOICE:signing source selected id=${KEY_ID} kind=hardware path=${HW_SOURCE}" \
    "selected hardware signing source was not logged"
  assert_trace_contains \
    "log:CHOICE:transaction output selected path=${SIGN_OUTPUT}" \
    "selected transaction output was not logged"
  assert_trace_contains "log:CHOICE:transaction signing declined id=${TX_ID}" \
    "final signing decline was not logged"
  assert_eq "${SIGN_CALLS}" 0 "declined signing call count"
  assert_file_absent "${SIGN_OUTPUT}" "declined signing published output"
}

test_submit_offline_rejected() {
  local status=0

  reset_scenario
  INPUT_VALUES=("${SIGNED_INPUT}")
  INPUT_STATUSES=(0)
  CNTOOLS_MODE="offline"
  if cntools_transaction_action_submit; then status=0; else status=$?; fi
  assert_eq "${status}" 1 "offline submission status"
  assert_trace_contains \
    "log:ERROR:Transaction submission is unavailable in offline mode." \
    "offline rejection was not logged"
  assert_trace_contains \
    "ui:status:error:Transaction submission is unavailable in offline mode." \
    "offline rejection was not shown"
  assert_trace_absent "decode:" "offline submission rendered a review"
  assert_trace_absent "confirm:" "offline submission asked for confirmation"
  assert_eq "$((LOCAL_SUBMIT_CALLS + KOIOS_SUBMIT_CALLS))" 0 \
    "offline submission call count"
}

test_submit_decline_after_review() {
  local status=0
  local confirm="confirm:Submit transaction ${TX_ID:0:16}… using koios?"

  reset_scenario
  INPUT_VALUES=("${SIGNED_INPUT}")
  INPUT_STATUSES=(0)
  LOCAL_READY_RESULTS=(1)
  CONFIRM_RESULTS=(1)
  if cntools_transaction_action_submit; then status=0; else status=$?; fi
  assert_eq "${status}" 0 "submission decline status"
  assert_trace_before "decode:${SIGNED_INPUT}" "${confirm}" \
    "signed transaction was not decoded before confirmation"
  assert_trace_before \
    "ui:detail:Decoded transaction · authoritative" "${confirm}" \
    "authoritative transaction review was not rendered before confirmation"
  assert_trace_contains \
    "log:CHOICE:transaction artifact selected id=${TX_ID} kind=external-envelope path=${SIGNED_INPUT}" \
    "accepted submission input was not logged"
  assert_trace_contains \
    "log:TRANSACTION:submission backend selected backend=koios" \
    "submission backend selection was not logged"
  assert_trace_contains \
    "log:CHOICE:transaction submission declined id=${TX_ID} backend=koios" \
    "submission decline was not logged"
  assert_trace_contains \
    "ui:status:warn:External-envelope completeness cannot be inferred." \
    "external-envelope completeness warning was not rendered"
  assert_eq "$((LOCAL_SUBMIT_CALLS + KOIOS_SUBMIT_CALLS))" 0 \
    "declined submission call count"
}

test_reference_script_review_identifies_input() {
  reset_scenario
  cntools_transaction_ui_render_native_scripts "${NATIVE_INPUT}" ||
    fail "native reference-script review could not be rendered"
  assert_trace_contains "ui:detail:Native scripts" \
    "native-script review heading was not rendered"
  assert_table_contains "Reference policy" \
    "native-script label was not rendered"
  assert_table_contains $'Reference input\t' \
    "native reference input property was not rendered"
  assert_table_contains "${REFERENCE_INPUT}" \
    "native reference input value was not rendered"
  assert_table_contains "Ledger payment" \
    "selected native-script signer was not rendered"
  assert_table_contains "${KEY_ID}" \
    "selected native-script signer ID was not rendered"
  assert_trace_contains \
    "ui:detail:Declared reference script · Reference policy" \
    "declared reference script was not rendered"
}

test_submit_backend_pinned_and_failure_visible() {
  local status=0
  local confirm="confirm:Submit transaction ${TX_ID:0:16}… using koios?"

  reset_scenario
  INPUT_VALUES=("${SIGNED_INPUT}")
  INPUT_STATUSES=(0)
  LOCAL_READY_RESULTS=(1)
  LOCAL_READY_DEFAULT=1
  CONFIRM_RESULTS=(0)
  CONFIRM_SIDE_EFFECT="local-ready"
  KOIOS_SUBMIT_STATUS=7
  if cntools_transaction_action_submit; then status=0; else status=$?; fi
  assert_eq "${status}" 7 "failed pinned-backend submission status"
  assert_trace_before "decode:${SIGNED_INPUT}" "${confirm}" \
    "failed submission was not reviewed first"
  assert_eq "${LOCAL_READY_CALLS}" 1 \
    "submission backend was re-selected after confirmation"
  assert_eq "${LOCAL_SUBMIT_CALLS}" 0 \
    "newly available local backend replaced the confirmed backend"
  assert_eq "${KOIOS_SUBMIT_CALLS}" 1 "confirmed Koios submission call count"
  assert_trace_contains "log:ERROR:Koios fixture submission failed." \
    "submission failure was not logged"
  assert_trace_contains "ui:status:error:Koios fixture submission failed." \
    "submission failure was not shown"
}

test_validation_interrupts_propagate() {
  local selected=""
  local status=0

  reset_scenario
  INPUT_VALUES=("${SIGN_INPUT}")
  INPUT_STATUSES=(0)
  PACKAGE_LOAD_STATUS=130
  if cntools_transaction_ui_prompt_package_into selected; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" 130 "signing validation interruption status"
  assert_eq "${INPUT_INDEX}" 1 \
    "signing validation interruption reopened the file prompt"

  reset_scenario
  INPUT_VALUES=("${SIGNED_INPUT}")
  INPUT_STATUSES=(0)
  SUBMIT_PREPARE_STATUS=143
  if cntools_transaction_ui_prompt_submit_input_into selected; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" 143 "submission validation interruption status"
  assert_eq "${INPUT_INDEX}" 1 \
    "submission validation interruption reopened the file prompt"
}

test_sign_cancel_after_initial_review
test_hardware_group_defer_is_explicit
test_active_hardware_group_cannot_partially_defer
test_sign_hardware_final_decline
test_submit_offline_rejected
test_submit_decline_after_review
test_submit_backend_pinned_and_failure_visible
test_validation_interrupts_propagate
test_reference_script_review_identifies_input

printf 'CNTools transaction UI tests passed\n'
