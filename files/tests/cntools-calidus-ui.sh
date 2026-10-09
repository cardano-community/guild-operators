#!/usr/bin/env bash
# Calidus interaction tests. No key generation, devices or network required.
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/pool-calidus-ui.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_ui_action_begin() { :; }
cntools_ui_wait() { :; }
cntools_transaction_log() { :; }
cntools_pool_catalog_build() { CNTOOLS_POOL_NAMES=(Example); CNTOOLS_POOL_DIRECTORIES=(/pools/Example); }
cntools_pool_choose_into() { printf -v "$1" '%s' 0; }
cntools_calidus_inspect() { CNTOOLS_CALIDUS_STATE='Public only'; CNTOOLS_CALIDUS_ID=calidus-id; CNTOOLS_CALIDUS_PUBLIC=public-key; }
cntools_table_pair() { printf '%s = %s\n' "$1" "$2"; }
cntools_table_render() { cat; }
cntools_ui_render_status() { printf '%s: %s\n' "$1" "$2"; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_calidus_preflight() { :; }
CNTOOLS_LOG=/logs/cntools.log CNTOOLS_POOL_WRITE_ERROR=''
for test_case in back cancel-import decline create repair fail revoke revoke-metadata; do
  (
    choices=0 prepared=0 cleanups=0 confirmations=0 routed=0
    cntools_ui_choose() {
      [[ "$*" == *'Create CLI key'* && "$*" == *'Repair missing public files'* && "$*" == *'Prepare revocation metadata'* && "$*" == *'Revoke on-chain'* && "$*" == *Back* ]] || fail 'missing choices'
      choices=$((choices+1))
      if ((choices > 1)) || [[ "${test_case}" == back ]]; then printf -v "$1" '%s' Back; return; fi
      case "${test_case}" in
        cancel-import) printf -v "$1" '%s' 'Import signing key' ;;
        repair) printf -v "$1" '%s' 'Repair missing public files' ;;
        revoke) printf -v "$1" '%s' 'Revoke on-chain' ;;
        revoke-metadata) printf -v "$1" '%s' 'Prepare revocation metadata' ;;
        *) printf -v "$1" '%s' 'Create CLI key' ;;
      esac
    }
    cntools_ui_input() { return 1; }
    cntools_ui_confirm() { confirmations=$((confirmations+1)); [[ "${test_case}" != decline ]]; }
    cntools_calidus_prepare() {
      prepared=$((prepared+1))
      [[ "$1" == /pools/Example ]] || fail 'wrong pool'
      if [[ "${test_case}" == repair ]]; then [[ "$2" == repair ]] || fail 'wrong repair operation'; fi
      if [[ "${test_case}" == fail ]]; then CNTOOLS_POOL_WRITE_ERROR='Retained original files'; return 1; fi
    }
    cntools_calidus_publication_cleanup() { cleanups=$((cleanups+1)); }
    cntools_pool_files_cleanup() { [[ "${cleanups}" == 1 ]] || fail 'staging removed before link rollback'; }
    cntools_transaction_cleanup() { :; }
    cntools_calidus_registration_action() { [[ "$1" == 0 && "$2" == "${test_case}" ]] || fail 'wrong revocation routing'; routed=$((routed+1)); }
    cntools_pool_action_calidus >/dev/null
    case "${test_case}" in
      back|cancel-import|decline) [[ "${prepared}" == 0 ]] || fail 'writes after cancellation' ;;
      revoke|revoke-metadata) [[ "${prepared}" == 0 && "${routed}" == 1 ]] || fail 'revocation routed to key generation' ;;
      *) [[ "${prepared}" == 1 && "${cleanups}" == 1 ]] || fail 'prepare/cleanup flow' ;;
    esac
  )
done
output="$(cntools_calidus_render /pools/Example)"
[[ "${output}" == *'Public only'* && "${output}" == *'Use Check on-chain status'* && "${output}" == *calidus-id* ]] || fail 'local status overstated chain registration'
(
  cntools_calidus_inspect() { CNTOOLS_POOL_WRITE_ERROR='Invalid key'; return 1; }
  output="$(cntools_calidus_render /pools/Example)"
  [[ "${output}" == *'Needs attention'* && "${output}" == *'Invalid key'* ]] || fail 'inspection failure hidden'
)
printf 'PASS: Calidus interaction and cancellation\n'
