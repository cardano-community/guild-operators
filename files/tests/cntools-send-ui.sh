#!/usr/bin/env bash
# Send draft rollback, compact presentation, and managed package persistence.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
. "${CNTOOLS_ROOT}/lib/asset.sh"
. "${CNTOOLS_ROOT}/lib/asset-cache.sh"
CNTOOLS_ASSET_CACHE_ENABLED=N
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-send-ui.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet wallet-query transaction transaction-ui utxo transaction-funding funds-send funds-send-view transaction-files funds-send-files funds-send-ui transaction-metadata send-metadata-ui; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_transaction_log() { :; }
cntools_ui_action_begin() { printf 'CLEAR\n'; }
cntools_ui_render_detail() { printf '%s\n' "$1"; }
cntools_ui_render_status() { printf '%s\n' "$2"; }
cntools_ui_wait() { :; }
cntools_ui_table() { cat; }
cntools_ui_content_width() { printf 120; }
cntools_theme_style_value_into() { printf -v "$1" '<%s>%s</%s>' "$2" "$3" "$2"; }
CNTOOLS_SEND_WALLET=Source
CNTOOLS_FUNDING_TOTAL=10000000
CNTOOLS_FUNDING_ASSET_IDS=(policy.01 policy.02)
CNTOOLS_FUNDING_ASSETS=([policy.01]=9007199254740993 [policy.02]=0)
CNTOOLS_SEND_MODE=exact
CNTOOLS_SEND_ADDRESSES=(old-address)
CNTOOLS_SEND_LABELS=(old-label)
CNTOOLS_SEND_AMOUNTS=(1000000)
CNTOOLS_SEND_HANDLES=('old@handle')
CNTOOLS_SEND_RESOLUTIONS=('{}')
declare -A CNTOOLS_SEND_ASSETS=(['0|policy.01']=2)

cntools_send_render_source > "${TEST_ROOT}/source"
grep -q 'Spendable ADA.*10.000000 ADA' "${TEST_ROOT}/source" || fail 'source balance table'
grep -q 'Native assets.*2' "${TEST_ROOT}/source" || fail 'source asset count'
if grep -q 'Chain data' "${TEST_ROOT}/source"; then fail 'redundant backend'; fi
cntools_send_render_assets 0 > "${TEST_ROOT}/assets"
grep -q '<number>9,007,199,254,740,993</number>' "${TEST_ROOT}/assets" || fail 'lossless available color'
grep -q '<success>2</success>' "${TEST_ROOT}/assets" || fail 'selected color'
grep -q '<muted>0</muted>' "${TEST_ROOT}/assets" || fail 'zero muted'
grep -q '<muted>policy.01</muted>' "${TEST_ROOT}/assets" || fail 'asset identifier not muted'
grep -q '<muted>policy.02</muted>' "${TEST_ROOT}/assets" || fail 'zero-balance asset identifier not muted'

(
  # Equal friendly names must still map to their distinct policy.name identity.
  CNTOOLS_WALLET_ASSET_TICKERS=([policy.01]=TOKEN [policy.02]=TOKEN)
  CNTOOLS_FUNDING_ASSETS[policy.02]=7
  CNTOOLS_SEND_MODE=max
  CNTOOLS_SEND_LABELS[1]='Second recipient'
  CNTOOLS_SEND_ADDRESSES[1]='second-address'
  visits=0
  cntools_ui_choose() {
    [[ "${*: -1}" == '2 · TOKEN · policy.02' ]] || fail 'name / identity menu label'
    visits=$((visits+1))
    if (( visits == 1 )); then printf -v "$1" '%s' '2 · TOKEN · policy.02'
    else printf -v "$1" '%s' 'Done selecting assets'; fi
  }
  cntools_ui_input() { printf -v "$1" '%s' 3; }
  cntools_send_prompt_amounts 1 > "${TEST_ROOT}/asset-menu" || fail 'named asset selection'
  [[ "${CNTOOLS_SEND_ASSETS[1|policy.02]:-}" == 3 &&
     -z "${CNTOOLS_SEND_ASSETS[1|policy.01]:-}" ]] || fail 'duplicate labels select wrong asset'
  grep -q '2 · TOKEN' "${TEST_ROOT}/asset-menu" || fail 'asset table lacks friendly name'
)

for operation in Add Edit; do
  for stage in recipient amounts; do
    for cancellation in 1 130 2; do
      (
        before="$(declare -p CNTOOLS_SEND_MODE CNTOOLS_SEND_ADDRESSES CNTOOLS_SEND_LABELS CNTOOLS_SEND_AMOUNTS CNTOOLS_SEND_ASSETS CNTOOLS_SEND_HANDLES CNTOOLS_SEND_RESOLUTIONS)"
        cntools_send_prompt_recipient() {
          CNTOOLS_SEND_ADDRESSES[$1]=new-address; CNTOOLS_SEND_LABELS[$1]=new-label
          CNTOOLS_SEND_HANDLES[$1]=new-handle; CNTOOLS_SEND_RESOLUTIONS[$1]=changed-evidence
          [[ "${stage}" != recipient ]] || return "${cancellation}"
        }
        cntools_send_prompt_amounts() {
          CNTOOLS_SEND_MODE=sweep; CNTOOLS_SEND_AMOUNTS[$1]=0; CNTOOLS_SEND_ASSETS["$1|policy.01"]=99
          return "${cancellation}"
        }
        index=0; [[ "${operation}" != Add ]] || index=1
        status=0; cntools_send_edit_one "${index}" "${operation}" > /dev/null || status=$?
        [[ "${status}" == "${cancellation}" ]] || fail 'edit status'
        after="$(declare -p CNTOOLS_SEND_MODE CNTOOLS_SEND_ADDRESSES CNTOOLS_SEND_LABELS CNTOOLS_SEND_AMOUNTS CNTOOLS_SEND_ASSETS CNTOOLS_SEND_HANDLES CNTOOLS_SEND_RESOLUTIONS)"
        [[ "${before}" == "${after}" ]] || fail "rollback ${operation}/${stage}/${cancellation}"
      )
    done
  done
done
(
  CNTOOLS_SEND_ADDRESSES=()
  cntools_ui_table() { fail 'empty recipient table'; }
  cntools_send_render_recipients > /dev/null || fail 'empty recipient state'
)
(
  CNTOOLS_SEND_EDIT_CANCEL='Cancel edit'
  cntools_ui_choose() { [[ "${*: -1}" == 'Cancel edit' ]] || fail 'cancel option missing'; printf -v "$1" '%s' 'Cancel edit'; }
  if cntools_send_choose selected Test One Two > /dev/null; then fail 'cancel not returned'; fi
)
(
  # Cancel the initial add, then add successfully without leaving Send.
  CNTOOLS_SEND_ADDRESSES=(); CNTOOLS_SEND_LABELS=(); CNTOOLS_SEND_AMOUNTS=()
  visits=0; edits=0
  cntools_send_edit_one() {
    edits=$((edits+1)); (( edits > 1 )) || return 1
    CNTOOLS_SEND_ADDRESSES=(address); CNTOOLS_SEND_LABELS=(label); CNTOOLS_SEND_AMOUNTS=(1)
  }
  cntools_send_render_recipients() { :; }
  cntools_ui_choose() {
    [[ "$2" == Recipients ]] || fail 'unexpected selector'
    visits=$((visits+1))
    if (( visits == 1 )); then printf -v "$1" '%s' Add; else printf -v "$1" '%s' Continue; fi
  }
  cntools_send_edit_recipients > /dev/null || fail 'cancel add aborted send'
  (( visits == 2 && edits == 2 )) || fail 'recipient menu did not resume'
)

printf '{"msg":["first","second"]}' > "${TEST_ROOT}/message.json"
CNTOOLS_METADATA_MESSAGE="${TEST_ROOT}/message.json"; CNTOOLS_METADATA_MODE=plain
printf '{"123":{"count":9007199254740993,"note":"custom"}}' > "${TEST_ROOT}/custom.json"
CNTOOLS_METADATA_CUSTOM="${TEST_ROOT}/custom.json"
cntools_send_metadata_render > "${TEST_ROOT}/metadata"
[[ "$(grep -c 'CIP-20 message' "${TEST_ROOT}/metadata")" == 1 ]] || fail 'message repeated as separate metadata'
grep -q $'674\t1\t.*first' "${TEST_ROOT}/metadata" || fail 'message label/line'
grep -q $'\t2\t.*second' "${TEST_ROOT}/metadata" || fail 'second line'
grep -q '9007199254740993' "${TEST_ROOT}/metadata" || fail 'custom integer rounded'
grep -q $'123\t\["count"\]' "${TEST_ROOT}/metadata" || fail 'custom label/path'
(
  edits=0
  cntools_send_render_recipients() { :; }
  cntools_send_metadata_render() { printf 'DRAFT\n'; }
  cntools_ui_choose() {
    edits=$((edits+1))
    if (( edits == 1 )); then printf -v "$1" '%s' 'Remove message'; else printf -v "$1" '%s' Done; fi
  }
  cntools_send_metadata_edit_inner > "${TEST_ROOT}/redraw" || fail 'metadata editor'
  [[ "$(grep -c CLEAR "${TEST_ROOT}/redraw")" == 2 ]] || fail 'metadata not cleared before each draft'
)
cntools_send_render_result danger 'Submission failed' txid /saved.json > "${TEST_ROOT}/result"
grep -q $'Transaction ID\t.*txid' "${TEST_ROOT}/result" || fail 'result ID table'
grep -q 'danger.*Submission failed' "${TEST_ROOT}/result" || fail 'result error table'
[[ "${CNTOOLS_SEND_RESULT_SHOWN}" == Y ]] || fail 'duplicate error suppression'

# Real publication helpers: unique, private and outside action cleanup.
CNTOOLS_NODE_HOME="${TEST_ROOT}/node"; CNTOOLS_TMP_DIR="${TEST_ROOT}/tmp"
mkdir -m 700 "${CNTOOLS_NODE_HOME}" "${CNTOOLS_TMP_DIR}"
cntools_transaction_temp_file draft send-test
printf '{}' > "${draft}"
cntools_send_save_into first "${draft}" unsigned || fail 'save unsigned'
cntools_transaction_temp_file draft send-test
printf '{}' > "${draft}"
cntools_send_save_into second "${draft}" unsigned || fail 'save collision'
[[ "${first}" != "${second}" && -f "${first}" && -f "${second}" ]] || fail 'unique exports'
cntools_send_signed_path_into signed_path || fail 'temporary signed path'
[[ "${signed_path}" == "${CNTOOLS_TRANSACTION_TEMP_DIR}/"* && ! -e "${signed_path}" ]] || fail 'signed path not temporary/new'
cntools_transaction_cleanup
[[ -f "${first}" && -f "${second}" && ! -e "${draft}" ]] || fail 'export lifecycle'
mv "${CNTOOLS_NODE_HOME}/transactions" "${CNTOOLS_NODE_HOME}/original"
ln -s "${CNTOOLS_NODE_HOME}/original" "${CNTOOLS_NODE_HOME}/transactions"
if cntools_send_save_into rejected "${first}" unsigned; then fail 'symlink export directory accepted'; fi
printf 'CNTools Send UI tests passed.\n'
