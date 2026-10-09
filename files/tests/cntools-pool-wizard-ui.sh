#!/usr/bin/env bash
# Public metadata wizard cancellation/default/snapshot contracts; no network/keys.
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-pool-wizard-ui.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
for lib in number wallet wallet-query-transport wallet-query-local asset-metadata wallet-query-koios wallet-list-query asset-view wallet-view wallet-query transaction pool pool-files pool-config pool-registration-ui pool-metadata pool-parameters; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)"
  chmod() { local argument=''; local -a args=(); for argument in "$@"; do [[ "${argument}" == -- ]] || args+=("${argument}"); done; "${REAL_CHMOD}" "${args[@]}"; }
fi
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_POOL_DIR="${TEST_ROOT}" CNTOOLS_POOL_REG_INDEX=0
mkdir -m 700 "${TEST_ROOT}/Example"
CNTOOLS_POOL_DIRECTORIES=("${TEST_ROOT}/Example")
CNTOOLS_POOL_REG_METADATA_URL=https://example.test/pool.json
FIXTURE_HASH="$(printf '11%.0s' {1..32})"
CNTOOLS_POOL_REG_METADATA="$(jq -cn --arg url "${CNTOOLS_POOL_REG_METADATA_URL}" --arg hash "${FIXTURE_HASH}" '{url:$url,hash:$hash}')"
printf '{"name":"Existing","description":"test","ticker":"TEST","homepage":"https://example.test"}\n' > "${TEST_ROOT}/Example/poolmeta.json"
printf '{"name":"Local","description":"test","ticker":"TEST","homepage":"https://example.test"}\n' > "${TEST_ROOT}/local.json"
cntools_log() { :; }
cntools_log_sanitize_line() { printf '%s' "$1"; }
cntools_run_command_timeout() { shift 3; "$@"; }
cntools_ui_render_status() { :; }
cntools_ui_wait() { :; }
cntools_table_pair() { printf '%s=%s\n' "$1" "$2"; }
cntools_table_render() { local row=''; while IFS= read -r row; do :; done; }
cntools_ui_choose() { printf -v "$1" '%s' 'Local JSON file + published URL'; }
cntools_pool_metadata_file_hash_into() { [[ "$(jq -r .name "$2")" == Local ]] || fail 'wrong metadata snapshot'; printf -v "$1" '%s' "${FIXTURE_HASH}"; }
cntools_ui_input() {
  if [[ "$2" == 'Pool metadata JSON file' ]]; then printf -v "$1" '%s' "${TEST_ROOT}/local.json"
  else
    [[ "${cancel_url}" != Y ]] || return 1
    # Simulate an editor changing the original file during the URL prompt.
    printf '{"name":"Changed"}' > "${TEST_ROOT}/local.json"
    printf -v "$1" '%s' ''
  fi
}
cancel_url=Y
status=0; cntools_pool_metadata_wizard || status=$?
[[ "${status}" == 1 && "$(jq -r .name "${TEST_ROOT}/Example/poolmeta.json")" == Existing &&
   ! -e "${TEST_ROOT}/Example/poolmeta.json.previous" ]] || fail 'cancel modified saved metadata'
cancel_url=N
cntools_pool_metadata_wizard || fail 'local metadata wizard'
[[ "$(jq -r .name "${TEST_ROOT}/Example/poolmeta.json")" == Local ]] || fail 'published original changed after hashing'
[[ "$(jq -r .name "${TEST_ROOT}/Example/poolmeta.json.previous")" == Existing ]] || fail 'old metadata not backed up'
[[ "$(jq -r .url <<< "${CNTOOLS_POOL_REG_METADATA}")" == https://example.test/pool.json ]] || fail 'empty input failed to retain URL default'
[[ "$(jq -r .hash <<< "${CNTOOLS_POOL_REG_METADATA}")" == "${FIXTURE_HASH}" ]] || fail 'selected metadata hash'
HTTP_APPROVAL=N HTTP_CALLS=0
CNTOOLS_KOIOS_TOKEN=do-not-send-this
cntools_ui_choose() {
  case "$2" in
    'Pool metadata') printf -v "$1" '%s' 'Download and reuse published metadata' ;;
    'Download unencrypted public metadata?')
      if [[ "${HTTP_APPROVAL}" == Y ]]; then printf -v "$1" '%s' 'Yes, download'
      else printf -v "$1" '%s' 'Use another URL'; fi ;;
    'Reuse this metadata?') printf -v "$1" '%s' 'Reuse unchanged' ;;
    *) fail "unexpected chooser: $2" ;;
  esac
}
cntools_ui_input() { printf -v "$1" '%s' 'http://example.test/pool.json'; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_api_request() {
  [[ "${CNTOOLS_HTTP_PUBLIC_POOL_METADATA:-N}" == Y && "$*" != *do-not-send-this* && "$*" != *Authorization* ]] || fail 'public HTTP scope/authorization'
  HTTP_CALLS=$((HTTP_CALLS+1)); cp "${TEST_ROOT}/Example/poolmeta.json" "$3"
}
status=0; cntools_pool_metadata_wizard || status=$?
[[ "${status}" == 1 && "${HTTP_CALLS}" == 0 ]] || fail 'plaintext download before confirmation'
HTTP_APPROVAL=Y; cntools_pool_metadata_wizard || fail 'confirmed public HTTP metadata'
[[ "${HTTP_CALLS}" == 1 && "${CNTOOLS_HTTP_PUBLIC_POOL_METADATA:-N}" == N &&
   "$(jq -r .url <<< "${CNTOOLS_POOL_REG_METADATA}")" == http://example.test/pool.json ]] || fail 'HTTP reuse result or scope leak'
cntools_pool_files_cleanup
cntools_transaction_cleanup
printf 'CNTools pool metadata wizard UI tests passed.\n'
