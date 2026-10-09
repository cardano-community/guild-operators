#!/usr/bin/env bash
# Password/confirmation contracts only; no real keys or GPG processes.
# shellcheck disable=SC1090,SC1091,SC2034,SC2154,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-pool-protection-ui.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number pool pool-manage-ui; do . "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for scenario in calidus-encrypt calidus-decrypt lock-only decline cancel-password short-encrypt mismatch legacy-decrypt; do
  (
    directory="${TEST_ROOT}/${scenario}"; mkdir -m700 "${directory}"
    operation=encrypt; [[ "${scenario}" != *decrypt ]] || operation=decrypt
    if [[ "${scenario}" != lock-only ]]; then
      filename=calidus.skey; [[ "${operation}" != decrypt ]] || filename+='.gpg'
      : > "${directory}/${filename}"
    fi
    prompts=0 confirmed=0 protected=0
    CNTOOLS_POOL_NAMES=(HardwarePool); CNTOOLS_POOL_DIRECTORIES=("${directory}"); CNTOOLS_POOL_PROTECTIONS=(Hardware)
    CNTOOLS_POOL_LOCK_METHOD='read-only permissions' CNTOOLS_POOL_WRITE_WARNING='' CNTOOLS_LOG=/logs/cntools.log
    cntools_ui_action_begin() { :; }
    cntools_pool_catalog_build() { :; }
    cntools_pool_choose_into() { printf -v "$1" '%s' 0; }
    cntools_table_pair() { printf '%s = %s\n' "$1" "$2"; }
    cntools_table_render() { cat; }
    cntools_ui_render_status() { :; }
    cntools_ui_wait() { :; }
    cntools_transaction_log() { :; }
    cntools_ui_confirm() { [[ "$2" == false ]] || fail 'confirmation must default No'; confirmed=$((confirmed+1)); [[ "${scenario}" != decline ]]; }
    cntools_ui_password() {
      prompts=$((prompts+1))
      [[ "$2" == *'signing-key password'* ]] || fail 'password prompt implies cold-only protection'
      [[ "${scenario}" != cancel-password ]] || return 1
      value=long-test-password
      [[ "${scenario}" != legacy-decrypt ]] || value=old
      [[ "${scenario}" != short-encrypt || "${prompts}" != 1 ]] || value=short
      [[ "${scenario}" != mismatch || "${prompts}" != 2 ]] || value=different-password
      printf -v "$1" '%s' "${value}"
    }
    cntools_ui_spin_function() { shift; "$@"; }
    cntools_pool_protect() {
      [[ "$1" == "${directory}" && "$2" == "${operation}" ]] || fail 'wrong protection target/operation'
      expected=long-test-password
      [[ "${scenario}" != lock-only ]] || expected=''
      [[ "${scenario}" != legacy-decrypt ]] || expected=old
      [[ "$3" == "${expected}" ]] || fail 'password/default handling'
      protected=$((protected+1)); CNTOOLS_POOL_PROTECTION_KEYS=1
      [[ "${scenario}" != lock-only ]] || CNTOOLS_POOL_PROTECTION_KEYS=0
    }
    cntools_pool_action_protection "${operation}" > "${directory}/output"
    case "${scenario}" in
      decline|cancel-password) [[ "${protected}" == 0 ]] || fail 'protection after cancellation' ;;
      lock-only) [[ "${protected}" == 1 && "${prompts}" == 0 ]] || fail 'password required without a secret' ;;
      calidus-encrypt) [[ "${protected}" == 1 && "${prompts}" == 2 ]] || fail 'Calidus-only encryption skipped password/confirmation' ;;
      calidus-decrypt|legacy-decrypt) [[ "${protected}" == 1 && "${prompts}" == 1 ]] || fail 'Calidus decryption input' ;;
      short-encrypt) [[ "${protected}" == 1 && "${prompts}" == 3 ]] || fail 'short encryption password not retried' ;;
      mismatch) [[ "${protected}" == 1 && "${prompts}" == 4 ]] || fail 'password mismatch not retried' ;;
    esac
    if [[ "${protected}" == 1 && "${scenario}" != lock-only ]]; then
      [[ "$(< "${directory}/output")" == *'Calidus key'* && "$(< "${directory}/output")" == *'Signing keys processed = 1'* ]] || fail 'Calidus state/count missing from UI'
    fi
  )
done
printf 'PASS: Pool protection Calidus-only prompts, cancellation, legacy passwords and lock-only UI\n'
