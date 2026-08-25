#!/usr/bin/env bash
# Focused contract for the authenticated Stage 4 mnemonic compatibility helper.
# shellcheck disable=SC1090,SC1091,SC2026,SC2034,SC2123,SC2154,SC2163,SC2209
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools mnemonic helper test skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MANIFEST="${REPO_ROOT}/scripts/common-helper-scripts/cntools/manifest.json"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-mnemonic-helper.XXXXXX")"
TEST_ROOT="$(cd -P -- "${TEST_ROOT}" && pwd -P)"
TEST_REAL_CHMOD="$(command -v chmod 2>/dev/null || true)"
TEST_REAL_FIND="$(command -v find 2>/dev/null || true)"
TEST_REAL_MKDIR="$(command -v mkdir 2>/dev/null || true)"
TEST_REAL_PS="$(command -v ps 2>/dev/null || true)"
TEST_REAL_RM="$(command -v rm 2>/dev/null || true)"
TEST_REAL_STAT="$(command -v stat 2>/dev/null || true)"
EXPECTED_FUNCTIONS="${TEST_ROOT}/expected-functions"
ACTUAL_FUNCTIONS="${TEST_ROOT}/actual-functions"
FAKE_BIN="${TEST_ROOT}/fake-bin"
FAULT_BIN="${TEST_ROOT}/fault-bin"
WALLET_ROOT="${TEST_ROOT}/wallets"
VECTOR_LOG="${TEST_ROOT}/vectors"
ACTUAL_CCLI_VECTORS="${TEST_ROOT}/actual-ccli-vectors"
EXPECTED_CCLI_VECTORS="${TEST_ROOT}/expected-ccli-vectors"
EXPECTED_KEY_ENVELOPE="${TEST_ROOT}/expected-key-envelope.json"
PHASE_STDOUT="${TEST_ROOT}/phase.stdout"
PHASE_STDERR="${TEST_ROOT}/phase.stderr"
PHASE_CAPTURE_DIR="${TEST_ROOT}/phase-captures"
FAILURE_EVIDENCE_DIR="${TEST_ROOT}/failure-evidence"
TEST_FAILED=N
LAST_PHASE=none
LAST_PHASE_CALL=0
LAST_PHASE_STATUS=none
LAST_PHASE_STDOUT=
LAST_PHASE_STDERR=
LAST_PHASE_WALLET=
MNEMONIC_HELPER_FAULT_MARKER="${TEST_ROOT}/fault.marker"
MNEMONIC_HELPER_OUTPUT_OUTSIDE="${TEST_ROOT}/outside-output.json"
MNEMONIC_HELPER_OUTPUT_SNAPSHOT="${TEST_ROOT}/outside-output.snapshot.json"
MNEMONIC_HELPER_OUTPUT_FAULT_MARKER="${TEST_ROOT}/output-fault.marker"
MNEMONIC_HELPER_OUTPUT_TARGET=
MNEMONIC_HELPER_OUTPUT_REPLACEMENT=
MNEMONIC_HELPER_OUTPUT_LATE_PATH=
MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE="${TEST_ROOT}/phase-lock.outside"
MNEMONIC_HELPER_CAPTURE_PID_FILE="${TEST_ROOT}/capture.pid"
MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE="${TEST_ROOT}/capture-descendant.pid"
MNEMONIC_HELPER_CAPTURE_DESCENDANT_HANDSHAKE_FILE="${TEST_ROOT}/capture-descendant.handshake"
MNEMONIC_HELPER_CAPTURE_DESCENDANT_SURVIVOR_FILE="${TEST_ROOT}/capture-descendant.survivor"

cleanup_test() {
  local cleanup_status=$?
  if (( cleanup_status != 0 )) && [[ "${TEST_FAILED}" != Y ]] &&
     builtin declare -F preserve_failure_evidence >/dev/null; then
    TEST_FAILED=Y
    preserve_failure_evidence "${cleanup_status}" \
      'unexpected test exit outside fail()' || true
  fi
  if [[ "${TEST_FAILED}" == Y ||
        "${CNTOOLS_MNEMONIC_HELPER_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools mnemonic helper test root preserved: %s\n' \
      "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

preserve_failure_evidence() {
  local failure_status="${1:-unknown}" failure_message="${2:-unknown}"
  local target="" relative="" metadata="" kind="" digest="-"
  local fd=0 fd_metadata="" variable_name="" hash_output=""

  [[ -n "${TEST_REAL_MKDIR}" && -x "${TEST_REAL_MKDIR}" ]] || return 1
  "${TEST_REAL_MKDIR}" -p -- "${FAILURE_EVIDENCE_DIR}" || return 1
  [[ -z "${TEST_REAL_CHMOD}" ]] ||
    "${TEST_REAL_CHMOD}" 0700 "${FAILURE_EVIDENCE_DIR}" 2>/dev/null || true

  {
    printf 'message\t%s\n' "${failure_message}"
    printf 'failure_status\t%s\n' "${failure_status}"
    printf 'bash\t%s\n' "${BASH_VERSION}"
    printf 'pid\t%s\n' "$$"
    printf 'bashpid\t%s\n' "${BASHPID}"
    printf 'ppid\t%s\n' "${PPID}"
    printf 'last_phase\t%s\n' "${LAST_PHASE}"
    printf 'last_phase_call\t%s\n' "${LAST_PHASE_CALL}"
    printf 'last_phase_status\t%s\n' "${LAST_PHASE_STATUS}"
    printf 'last_phase_stdout\t%s\n' "${LAST_PHASE_STDOUT}"
    printf 'last_phase_stderr\t%s\n' "${LAST_PHASE_STDERR}"
    printf 'last_phase_wallet\t%s\n' "${LAST_PHASE_WALLET}"
    printf 'fault\t%s\n' "${MNEMONIC_HELPER_FAULT:-}"
    printf 'signal_pid\t%s\n' "${MNEMONIC_HELPER_SIGNAL_PID:-}"
  } > "${FAILURE_EVIDENCE_DIR}/summary.tsv" 2>/dev/null || true

  {
    for variable_name in wallet_name acct_idx key_idx NETWORK_IDENTIFIER \
        NWMAGIC CCLI phrase state base payment reward mnemonic words \
        MNEMONIC_HELPER_FAULT MNEMONIC_HELPER_OUTPUT_TARGET \
        MNEMONIC_HELPER_OUTPUT_REPLACEMENT MNEMONIC_HELPER_OUTPUT_LATE_PATH; do
      builtin declare -p "${variable_name}" 2>/dev/null ||
        printf 'unset -- %q\n' "${variable_name}"
    done
  } > "${FAILURE_EVIDENCE_DIR}/caller-vars.sh" 2>/dev/null || true

  {
    builtin jobs -l 2>&1 || true
  } > "${FAILURE_EVIDENCE_DIR}/jobs.txt" 2>&1 || true
  {
    printf 'shell_pid\t%s\nbashpid\t%s\nparent_pid\t%s\n' \
      "$$" "${BASHPID}" "${PPID}"
    while IFS= builtin read -r variable_name; do
      case "${variable_name}" in
        *PID*|*pid*) builtin declare -p "${variable_name}" 2>/dev/null || true ;;
      esac
    done < <(compgen -A variable)
  } > "${FAILURE_EVIDENCE_DIR}/pids.txt" 2>/dev/null || true
  if [[ -n "${TEST_REAL_PS}" && -x "${TEST_REAL_PS}" ]]; then
    "${TEST_REAL_PS}" -axo pid,ppid,state,command \
      > "${FAILURE_EVIDENCE_DIR}/processes.txt" 2>&1 || true
  fi

  {
    for ((fd=0; fd<256; fd++)); do
      if [[ -e "/dev/fd/${fd}" ]]; then
        fd_metadata=
        if [[ -n "${TEST_REAL_STAT}" ]]; then
          if fd_metadata="$("${TEST_REAL_STAT}" -f \
              $'%u\t%Lp\t%l\t%z\t%d\t%i' "/dev/fd/${fd}" \
              2>/dev/null)"; then
            :
          else
            fd_metadata="$("${TEST_REAL_STAT}" -c \
              $'%u\t%a\t%h\t%s\t%d\t%i' -- "/dev/fd/${fd}" \
              2>/dev/null || true)"
          fi
        fi
        printf '%s\t%s\n' "${fd}" "${fd_metadata}"
      fi
    done
  } > "${FAILURE_EVIDENCE_DIR}/open-fds.tsv" 2>/dev/null || true

  if [[ -n "${TEST_REAL_FIND}" && -x "${TEST_REAL_FIND}" ]]; then
    while IFS= builtin read -r -d '' target; do
      relative="${target#"${TEST_ROOT}"}"
      [[ -n "${relative}" ]] || relative=/
      if [[ -L "${target}" ]]; then
        kind=symlink
      elif [[ -d "${target}" ]]; then
        kind=directory
      elif [[ -f "${target}" ]]; then
        kind=file
      elif [[ -p "${target}" ]]; then
        kind=fifo
      elif [[ -S "${target}" ]]; then
        kind=socket
      elif [[ -b "${target}" ]]; then
        kind=block
      elif [[ -c "${target}" ]]; then
        kind=character
      else
        kind=other
      fi
      metadata=
      if [[ -n "${TEST_REAL_STAT}" ]]; then
        if metadata="$("${TEST_REAL_STAT}" -f \
            $'%u\t%Lp\t%l\t%z\t%d\t%i' "${target}" 2>/dev/null)"; then
          :
        else
          metadata="$("${TEST_REAL_STAT}" -c \
            $'%u\t%a\t%h\t%s\t%d\t%i' -- "${target}" \
            2>/dev/null || true)"
        fi
      fi
      digest=-
      if [[ "${kind}" == file && -n "${MNEMONIC_HELPER_REAL_HASH:-}" ]]; then
        if [[ "${MNEMONIC_HELPER_HASH_NAME:-}" == sha256sum ]]; then
          hash_output="$("${MNEMONIC_HELPER_REAL_HASH}" "${target}" \
            2>/dev/null || true)"
        else
          hash_output="$("${MNEMONIC_HELPER_REAL_HASH}" -a 256 "${target}" \
            2>/dev/null || true)"
        fi
        digest="${hash_output%% *}"
        [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || digest=-
      fi
      printf '%q\t%s\t%s\t%s\n' "${relative}" "${kind}" \
        "${metadata}" "${digest}"
    done < <("${TEST_REAL_FIND}" "${TEST_ROOT}" -xdev -print0 2>/dev/null)
  fi > "${FAILURE_EVIDENCE_DIR}/tree.tsv" 2>/dev/null || true

  if [[ -n "${TEST_REAL_CHMOD}" ]]; then
    "${TEST_REAL_CHMOD}" 0600 "${FAILURE_EVIDENCE_DIR}"/* \
      2>/dev/null || true
  fi
}

fail() {
  local failure_status=$?
  TEST_FAILED=Y
  preserve_failure_evidence "${failure_status}" "${1:-unknown}" || true
  printf 'CNTools mnemonic helper test failed: %s (status %s)\n' \
    "$1" "${failure_status}" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

file_identity_links() {
  local target="$1" metadata=""
  if metadata="$(stat -f $'%d\t%i\t%l' "${target}" 2>/dev/null)"; then
    :
  else
    metadata="$(stat -c $'%d\t%i\t%h' -- "${target}" 2>/dev/null)" ||
      return 1
  fi
  printf '%s\n' "${metadata}"
}

for required_command in cmp cp find grep jq mkfifo sed sort stat; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command unavailable: ${required_command}"
done
MNEMONIC_HELPER_REAL_STAT="$(command -v stat)"
if MNEMONIC_HELPER_REAL_HASH="$(command -v sha256sum 2>/dev/null)"; then
  MNEMONIC_HELPER_HASH_NAME=sha256sum
elif MNEMONIC_HELPER_REAL_HASH="$(command -v shasum 2>/dev/null)"; then
  MNEMONIC_HELPER_HASH_NAME=shasum
else
  fail 'required SHA-256 command unavailable'
fi

# Dispatch wrappers around dynamic `exec` redirections leak Bash 4.4's saved
# cross-function descriptors. Prove the quoted bare-special-builtin primitive
# used by the helper creates, transfers, and closes a descriptor repeatedly
# without advancing the allocator.
EXEC_CLOSE_ORACLE_FILE="${TEST_ROOT}/exec-close-oracle"
EXEC_CLOSE_ORACLE_MARKER="${TEST_ROOT}/exec-close-intercepted"
: > "${EXEC_CLOSE_ORACLE_FILE}"
chmod 0600 "${EXEC_CLOSE_ORACLE_FILE}"
"${BASH}" --noprofile --norc -c '
  set -euo pipefail
  oracle_file=$1
  open_oracle_fd() {
    local result_name=$1 opened_fd=""
    ex""ec {opened_fd}<> "${oracle_file}"
    builtin printf -v "${result_name}" %s "${opened_fd}"
  }
  close_oracle_fd() {
    local opened_fd=$1
    ex""ec {opened_fd}>&-
  }
  ex""ec {baseline_fd}</dev/null
  close_oracle_fd "${baseline_fd}"
  for ((iteration=0; iteration<200; iteration++)); do
    oracle_fd=
    open_oracle_fd oracle_fd
    [[ "${oracle_fd}" =~ ^[1-9][0-9]*$ && -e "/dev/fd/${oracle_fd}" ]]
    close_oracle_fd "${oracle_fd}"
    [[ ! -e "/dev/fd/${oracle_fd}" ]]
  done
  ex""ec {final_fd}</dev/null
  [[ "${final_fd}" == "${baseline_fd}" ]]
  close_oracle_fd "${final_fd}"
' bash "${EXEC_CLOSE_ORACLE_FILE}" "${EXEC_CLOSE_ORACLE_MARKER}" ||
  fail 'bare special-builtin descriptor primitive leaked across function calls'
export MNEMONIC_HELPER_REAL_STAT MNEMONIC_HELPER_FAULT_MARKER
export MNEMONIC_HELPER_REAL_HASH
export MNEMONIC_HELPER_OUTPUT_OUTSIDE MNEMONIC_HELPER_OUTPUT_FAULT_MARKER
export MNEMONIC_HELPER_OUTPUT_TARGET MNEMONIC_HELPER_OUTPUT_REPLACEMENT
export MNEMONIC_HELPER_OUTPUT_LATE_PATH
export MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE
export MNEMONIC_HELPER_CAPTURE_PID_FILE
export MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE
export MNEMONIC_HELPER_CAPTURE_DESCENDANT_HANDSHAKE_FILE
export MNEMONIC_HELPER_CAPTURE_DESCENDANT_SURVIVOR_FILE

if [[ -n "${CNTOOLS_MNEMONIC_HELPER_MEMBER:-}" ]]; then
  MEMBER_SOURCE="${CNTOOLS_MNEMONIC_HELPER_MEMBER}"
else
  BUNDLE_PATH="$(jq -er '.legacyBundle.path' "${MANIFEST}")" ||
    fail 'manifest legacy bundle path is unavailable'
  MEMBER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/${BUNDLE_PATH}/050-wallet-create-registration.sh"
fi
[[ -f "${MEMBER_SOURCE}" && ! -L "${MEMBER_SOURCE}" ]] ||
  fail 'current mnemonic sidecar member is missing or unsafe'

printf '%s\n' \
  _cntools_compatibility_wallet_mnemonic_run \
  buildOfflineJSON \
  createMnemonicWallet \
  createNewWallet \
  deregisterStakeWallet \
  printWalletInfo \
  registerStakeWallet \
  | sort > "${EXPECTED_FUNCTIONS}"

HOME="${TEST_ROOT}/source-home" TMPDIR="${TEST_ROOT}" \
  BASH_ENV=/dev/null ENV=/dev/null \
  "${BASH}" --noprofile --norc -c '
    source_file=$1
    mkdir -p -- "${HOME}"
    while IFS= read -r name; do
      builtin unset -f "${name}" 2>/dev/null || true
    done < <(compgen -A function)
    # shellcheck source=/dev/null
    builtin source "${source_file}" || exit 1
    compgen -A function | LC_ALL=C sort
  ' bash "${MEMBER_SOURCE}" > "${ACTUAL_FUNCTIONS}" ||
  fail 'current mnemonic sidecar member failed clean sourcing'

cmp -s -- "${ACTUAL_FUNCTIONS}" "${EXPECTED_FUNCTIONS}" || {
  diff -u -- "${EXPECTED_FUNCTIONS}" "${ACTUAL_FUNCTIONS}" >&2 || true
  fail 'mnemonic sidecar exact function inventory changed'
}

mkdir -m 0700 -- "${FAKE_BIN}" "${FAULT_BIN}" "${WALLET_ROOT}"
: > "${VECTOR_LOG}"
chmod 0600 "${VECTOR_LOG}"

cat > "${FAKE_BIN}/cardano-address" <<'EOF_CARDANO_ADDRESS'
#!/usr/bin/env bash
set -euo pipefail
phase_guard_acquired=N
cleanup_phase_guard() {
  [[ "${phase_guard_acquired}" != Y ]] ||
    /bin/rmdir -- "${MNEMONIC_HELPER_PHASE_GUARD_DIR}" 2>/dev/null || true
}
if [[ -n "${MNEMONIC_HELPER_PHASE_GUARD_DIR:-}" ]]; then
  /bin/mkdir -- "${MNEMONIC_HELPER_PHASE_GUARD_DIR}" || exit 97
  phase_guard_acquired=Y
  builtin trap cleanup_phase_guard EXIT
  /bin/sleep 0.01
fi
if /usr/bin/env | /usr/bin/grep -Eq '^environment_phrase='; then
  exit 96
fi
if /usr/bin/env | /usr/bin/grep -E '^_wmh_(value|cleanup_marker_value|phrase|phrase_sha|saved_phrase_sha|inventory_sha|saved_inventory_sha|key|expected_key|digest|live_digest|captured|read_value|capture_outer_value|capture_value|capture_chunk|auth_helper_program|rest|word|root_prv|hex|es_key|xprv|xpub|root|root_identity|destination|phase_lock|phase_lock_identity|phase_lock_token|phase_lock_seen_token|phase_lock_extra|phase_lock_snapshot|phase_lock_first_snapshot|phase_lock_pid|phase_lock_root_device|phase_lock_saved_umask|lock|lock_identity|stage|stage_identity|state|inventory|ack|cleanup_marker|saved_root|saved_root_identity|saved_destination|saved_destination_identity|saved_lock_identity|saved_stage_identity|publish_active_leaf)=' |
    /usr/bin/grep -Ev '=ambient-export-sentinel$' >/dev/null; then
  exit 96
fi
printf 'cardano-address' >> "${VECTOR_LOG:?}"
printf '\t%q' "$@" >> "${VECTOR_LOG}"
printf '\n' >> "${VECTOR_LOG}"
case "${1:-}:${2:-}:${3:-}" in
  recovery-phrase:generate:)
    printf '%s\n' \
      'alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean piano quartz river solar tango unity vivid willow xenon'
    [[ "${MNEMONIC_HELPER_FAULT:-}" != signal-prepare ]] ||
      kill -TERM "${MNEMONIC_HELPER_SIGNAL_PID:?}"
    ;;
  -v::) printf '3.12.0\n' ;;
  key:from-recovery-phrase:Shelley)
    IFS= read -r phrase
    [[ "${phrase}" == 'alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean piano quartz river solar tango unity vivid willow xenon' ||
       "${phrase}" == 'alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean' ]]
    printf 'root_xsk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    ;;
  key:child:*)
    IFS= read -r root
    [[ "${root}" == root_xsk_* ]]
    printf 'child_xsk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    ;;
  key:public:*)
    IFS= read -r child
    [[ "${child}" == child_xsk_* ]]
    printf 'addr_xvk_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
    ;;
  *) exit 64 ;;
esac
EOF_CARDANO_ADDRESS

cat > "${FAKE_BIN}/bech32" <<'EOF_BECH32'
#!/usr/bin/env bash
set -euo pipefail
phase_guard_acquired=N
cleanup_phase_guard() {
  [[ "${phase_guard_acquired}" != Y ]] ||
    /bin/rmdir -- "${MNEMONIC_HELPER_PHASE_GUARD_DIR}" 2>/dev/null || true
}
if [[ -n "${MNEMONIC_HELPER_PHASE_GUARD_DIR:-}" ]]; then
  /bin/mkdir -- "${MNEMONIC_HELPER_PHASE_GUARD_DIR}" || exit 97
  phase_guard_acquired=Y
  builtin trap cleanup_phase_guard EXIT
  /bin/sleep 0.01
fi
if /usr/bin/env | /usr/bin/grep -Eq '^environment_phrase='; then
  exit 96
fi
if /usr/bin/env | /usr/bin/grep -E '^_wmh_(value|cleanup_marker_value|phrase|phrase_sha|saved_phrase_sha|inventory_sha|saved_inventory_sha|key|expected_key|digest|live_digest|captured|read_value|capture_outer_value|capture_value|capture_chunk|auth_helper_program|rest|word|root_prv|hex|es_key|xprv|xpub|root|root_identity|destination|phase_lock|phase_lock_identity|phase_lock_token|phase_lock_seen_token|phase_lock_extra|phase_lock_snapshot|phase_lock_first_snapshot|phase_lock_pid|phase_lock_root_device|phase_lock_saved_umask|lock|lock_identity|stage|stage_identity|state|inventory|ack|cleanup_marker|saved_root|saved_root_identity|saved_destination|saved_destination_identity|saved_lock_identity|saved_stage_identity|publish_active_leaf)=' |
    /usr/bin/grep -Ev '=ambient-export-sentinel$' >/dev/null; then
  exit 96
fi
printf 'bech32' >> "${VECTOR_LOG:?}"
printf '\t%q' "$@" >> "${VECTOR_LOG}"
printf '\n' >> "${VECTOR_LOG}"
IFS= read -r value
case "${value}" in
  child_xsk_*) for ((i=0; i<256; i++)); do printf a; done ;;
  addr_xvk_*) for ((i=0; i<128; i++)); do printf b; done ;;
  *) exit 64 ;;
esac
printf '\n'
EOF_BECH32

cat > "${FAKE_BIN}/cardano-cli" <<'EOF_CARDANO_CLI'
#!/usr/bin/env bash
set -euo pipefail
phase_guard_acquired=N
cleanup_phase_guard() {
  [[ "${phase_guard_acquired}" != Y ]] ||
    /bin/rmdir -- "${MNEMONIC_HELPER_PHASE_GUARD_DIR}" 2>/dev/null || true
}
if [[ -n "${MNEMONIC_HELPER_PHASE_GUARD_DIR:-}" ]]; then
  /bin/mkdir -- "${MNEMONIC_HELPER_PHASE_GUARD_DIR}" || exit 97
  phase_guard_acquired=Y
  builtin trap cleanup_phase_guard EXIT
  /bin/sleep 0.01
fi
if /usr/bin/env | /usr/bin/grep -Eq '^environment_phrase='; then
  exit 96
fi
if /usr/bin/env | /usr/bin/grep -E '^_wmh_(value|cleanup_marker_value|phrase|phrase_sha|saved_phrase_sha|inventory_sha|saved_inventory_sha|key|expected_key|digest|live_digest|captured|read_value|capture_outer_value|capture_value|capture_chunk|auth_helper_program|rest|word|root_prv|hex|es_key|xprv|xpub|root|root_identity|destination|phase_lock|phase_lock_identity|phase_lock_token|phase_lock_seen_token|phase_lock_extra|phase_lock_snapshot|phase_lock_first_snapshot|phase_lock_pid|phase_lock_root_device|phase_lock_saved_umask|lock|lock_identity|stage|stage_identity|state|inventory|ack|cleanup_marker|saved_root|saved_root_identity|saved_destination|saved_destination_identity|saved_lock_identity|saved_stage_identity|publish_active_leaf)=' |
    /usr/bin/grep -Ev '=ambient-export-sentinel$' >/dev/null; then
  exit 96
fi
printf 'cardano-cli' >> "${VECTOR_LOG:?}"
printf '\t%q' "$@" >> "${VECTOR_LOG}"
printf '\n' >> "${VECTOR_LOG}"
args=("${@}")
payment_file=
stake_file=
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    --payment-verification-key-file) payment_file="${args[i+1]}" ;;
    --stake-verification-key-file) stake_file="${args[i+1]}" ;;
  esac
done
if [[ " $* " == *' verification-key '* ||
      " $* " == *' non-extended-key '* ]]; then
  exit 95
fi
case "${MNEMONIC_HELPER_FAULT:-}" in
  ccli-input-symlink|ccli-input-hardlink|ccli-input-fifo|ccli-input-special)
    if [[ ! -e "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER:?}" ]]; then
      target="${MNEMONIC_HELPER_OUTPUT_LATE_PATH:?}"
      /bin/rm -f -- "${target}"
      case "${MNEMONIC_HELPER_FAULT}" in
        ccli-input-symlink)
          /bin/ln -s -- "${MNEMONIC_HELPER_OUTPUT_OUTSIDE:?}" "${target}" ;;
        ccli-input-hardlink)
          /bin/ln -- "${MNEMONIC_HELPER_OUTPUT_OUTSIDE:?}" "${target}" ;;
        ccli-input-fifo) mkfifo -- "${target}" ;;
        ccli-input-special) mkdir -m 0700 -- "${target}" ;;
      esac
      : > "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER}"
    fi
    ;;
esac
for input_file in "${payment_file}" "${stake_file}"; do
  [[ -z "${input_file}" ]] && continue
  [[ "${input_file}" =~ ^/dev/fd/[1-9][0-9]*$ ]] || exit 94
  jq -e '
    type == "object" and
    keys == ["cborHex","description","type"] and
    (.cborHex | test("^5820[0-9a-f]{64}$"))
  ' "${input_file}" >/dev/null
done
if [[ "${MNEMONIC_HELPER_FAULT:-}" == ccli-capture-stderr ]]; then
  printf 'unexpected successful diagnostic\n' >&2
fi
if [[ "${MNEMONIC_HELPER_FAULT:-}" == ccli-capture-overflow ]]; then
  for ((i=0; i<600; i++)); do printf x; done
  printf '\n'
elif [[ "${MNEMONIC_HELPER_FAULT:-}" == ccli-command-failure ]]; then
  exit 42
elif [[ "${1:-}:${2:-}" == address:build ]]; then
  printf 'addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq\n'
elif [[ "${1:-}:${2:-}" == stake-address:build ]]; then
  printf 'stake_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq\n'
elif [[ "${2:-}" == key-hash ]]; then
  for ((i=0; i<56; i++)); do printf e; done
  printf '\n'
else
  exit 64
fi
EOF_CARDANO_CLI

cat > "${FAKE_BIN}/capture-writer" <<'EOF_CAPTURE_WRITER'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-}"
emit_count() {
  local count="${1:-0}" i=0
  for ((i=0; i<count; i++)); do builtin printf x; done
}
case "${mode}" in
  nul)
    builtin printf 'nul\0tail'
    ;;
  max-minus-one)
    emit_count 511
    ;;
  max)
    emit_count 512
    ;;
  max-plus-one)
    emit_count 513
    ;;
  delayed)
    builtin printf delayed-
    /bin/sleep 0.2
    builtin printf value
    ;;
  hung)
    builtin printf '%s\n' "$$" > "${MNEMONIC_HELPER_CAPTURE_PID_FILE:?}"
    builtin trap 'builtin exit 70' HUP INT TERM
    while :; do /bin/sleep 1; done
    ;;
  descendant-held)
    builtin printf '%s\n' "$$" > "${MNEMONIC_HELPER_CAPTURE_PID_FILE:?}"
    (
      builtin trap 'builtin exit 0' HUP INT TERM
      builtin trap \
        'builtin printf survived > "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_SURVIVOR_FILE:?}"' \
        USR1
      for ((i=0; i<100; i++)); do
        [[ ! -s "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE:?}" ]] || break
        /bin/sleep 0.01
      done
      [[ -s "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE:?}" ]]
      IFS= builtin read -r descendant_pid \
        < "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE:?}"
      [[ "${descendant_pid}" =~ ^[1-9][0-9]*$ ]]
      builtin printf descendant-value
      builtin printf '%s\n' "${descendant_pid}" \
        > "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_HANDSHAKE_FILE:?}"
      while :; do /bin/sleep 1; done
    ) &
    descendant_pid=$!
    builtin printf '%s\n' "${descendant_pid}" \
      > "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE:?}"
    for ((i=0; i<100; i++)); do
      [[ ! -s "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_HANDSHAKE_FILE:?}" ]] || break
      /bin/sleep 0.01
    done
    [[ -s "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_HANDSHAKE_FILE:?}" ]]
    IFS= builtin read -r descendant_handshake \
      < "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_HANDSHAKE_FILE:?}"
    [[ "${descendant_handshake}" == "${descendant_pid}" ]]
    ;;
  nonzero)
    builtin exit 42
    ;;
  signal)
    builtin printf '%s\n' "$$" > "${MNEMONIC_HELPER_CAPTURE_PID_FILE:?}"
    builtin kill -TERM "${MNEMONIC_HELPER_SIGNAL_PID:?}"
    builtin trap 'builtin exit 70' HUP INT TERM
    while :; do /bin/sleep 1; done
    ;;
  worker-signal)
    builtin printf '%s\n' "$$" > "${MNEMONIC_HELPER_CAPTURE_PID_FILE:?}"
    builtin trap 'builtin exit 70' HUP INT TERM
    builtin kill -TERM "${PPID}"
    while :; do /bin/sleep 1; done
    ;;
  *) builtin exit 64 ;;
esac
EOF_CAPTURE_WRITER
chmod 0700 "${FAKE_BIN}/cardano-address" "${FAKE_BIN}/bech32" \
  "${FAKE_BIN}/cardano-cli" "${FAKE_BIN}/capture-writer"

cat > "${FAULT_BIN}/ln" <<'EOF_FAULT_LN'
#!/usr/bin/env bash
set -euo pipefail
real_ln=/bin/ln
"${real_ln}" "$@"
target="${*: -1}"
case "${MNEMONIC_HELPER_FAULT:-}" in
  ack-ln-error)
    [[ "${target}" != */acknowledged ]] || exit 1
    ;;
  publish-ln-error)
    [[ "${target}" != */derivation.path ]] || exit 1
    ;;
  signal-ack)
    if [[ "${target}" == */acknowledged ]]; then
      kill -TERM "${PPID}"
    fi
    ;;
  signal-publish|signal-publish-first|signal-publish-unlink-failure|signal-publish-race)
    if [[ "${target}" == */derivation.path ]]; then
      kill -TERM "${PPID}"
    fi
    ;;
  signal-publish-middle)
    if [[ "${target}" == */ms-payment.skey ]]; then
      kill -TERM "${PPID}"
    fi
    ;;
  signal-publish-last)
    if [[ "${target}" == */ms-stake.cred ]]; then
      kill -TERM "${PPID}"
    fi
    ;;
esac
EOF_FAULT_LN

cat > "${FAULT_BIN}/rm" <<'EOF_FAULT_RM'
#!/usr/bin/env bash
set -euo pipefail
real_rm=/bin/rm
case "${MNEMONIC_HELPER_FAULT:-}" in
  capture-unlink-failure)
    for value in "$@"; do
      if [[ "${value}" == */.capture-*.pipe &&
            ! -e "${MNEMONIC_HELPER_FAULT_MARKER:?}" ]]; then
        : > "${MNEMONIC_HELPER_FAULT_MARKER}"
        exit 1
      fi
    done
    ;;
  abort-rm)
    for value in "$@"; do
      [[ "${value}" != */.abort_retry_wallet.cntools-wallet-mnemonic.lock/stage/derivation.path ]] ||
        exit 1
    done
    ;;
  abort-after-stage-rm)
    for value in "$@"; do
      if [[ "${value}" == */.abort_after_stage_wallet.cntools-wallet-mnemonic.lock/acknowledged &&
            ! -e "${value%/acknowledged}/stage" &&
            ! -e "${MNEMONIC_HELPER_FAULT_MARKER:?}" ]]; then
        : > "${MNEMONIC_HELPER_FAULT_MARKER}"
        exit 1
      fi
    done
    ;;
  abort-public-rm)
    for value in "$@"; do
      [[ "${value}" != */persistent_retain_wallet/derivation.path ]] ||
        exit 1
    done
    ;;
  existing-rollback-noop)
    for value in "$@"; do
      [[ "${value}" != */existing_noop_wallet/derivation.path ]] || exit 0
    done
    ;;
  existing-rollback-rename)
    for value in "$@"; do
      if [[ "${value}" == */existing_rename_wallet/derivation.path ]]; then
        /bin/mv -- "${value}" "${value}.unknown"
        exit 0
      fi
    done
    ;;
  signal-publish-unlink-failure)
    for value in "$@"; do
      [[ "${value}" != */signal_publish_unlink_failure_wallet/derivation.path ]] ||
        exit 1
    done
    ;;
  signal-publish-race)
    for value in "$@"; do
      if [[ "${value}" == */signal_publish_race_wallet/derivation.path ]]; then
        /bin/rm -f -- "${value}"
        /bin/ln -s -- "${MNEMONIC_HELPER_OUTPUT_OUTSIDE:?}" "${value}"
        exit 0
      fi
    done
    ;;
  signal-postcommit)
    for value in "$@"; do
      if [[ "${value}" == */.signal_postcommit_wallet.cntools-wallet-mnemonic.lock/stage/derivation.path ]]; then
        kill -TERM "${PPID}"
        break
      fi
    done
    ;;
esac
exec "${real_rm}" "$@"
EOF_FAULT_RM

cat > "${FAULT_BIN}/stat" <<'EOF_FAULT_STAT'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
target="${args[${#args[@]}-1]}"
if [[ "${MNEMONIC_HELPER_FAULT:-}" == post-link-verify &&
      "${target}" == */post_link_verify_wallet/derivation.path &&
      -f "${target}" ]]; then
  count=0
  [[ ! -f "${MNEMONIC_HELPER_FAULT_MARKER:?}" ]] ||
    IFS= read -r count < "${MNEMONIC_HELPER_FAULT_MARKER}"
  if (( count < 2 )); then
    printf '%s\n' "$((count + 1))" > "${MNEMONIC_HELPER_FAULT_MARKER}"
    exit 1
  fi
fi
if [[ ( "${MNEMONIC_HELPER_FAULT:-}" == existing-rollback-noop &&
        "${target}" == */existing_noop_wallet/derivation.path ) ||
      ( "${MNEMONIC_HELPER_FAULT:-}" == existing-rollback-rename &&
        "${target}" == */existing_rename_wallet/derivation.path ) ]] &&
   [[ -f "${target}" ]]; then
  count=0
  [[ ! -f "${MNEMONIC_HELPER_FAULT_MARKER:?}" ]] ||
    IFS= read -r count < "${MNEMONIC_HELPER_FAULT_MARKER}"
  if (( count < 2 )); then
    printf '%s\n' "$((count + 1))" > "${MNEMONIC_HELPER_FAULT_MARKER}"
    exit 1
  fi
fi
if [[ "${MNEMONIC_HELPER_FAULT:-}" == persistent-post-link &&
      ( "${target}" == */persistent_recovery_wallet/derivation.path ||
        "${target}" == */persistent_retain_wallet/derivation.path ) &&
      -f "${target}" ]]; then
  exit 1
fi
if [[ "${MNEMONIC_HELPER_FAULT:-}" == phase-lock-injected-hardlink &&
      "${target}" == */.cntools-wallet-mnemonic.phase.lock &&
      -f "${target}" && ! -L "${target}" &&
      ! -e "${MNEMONIC_HELPER_FAULT_MARKER:?}" ]]; then
  /bin/ln -- "${target}" "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE:?}"
  : > "${MNEMONIC_HELPER_FAULT_MARKER}"
fi
exec "${MNEMONIC_HELPER_REAL_STAT:?}" "$@"
EOF_FAULT_STAT

cat > "${FAULT_BIN}/${MNEMONIC_HELPER_HASH_NAME}" <<'EOF_FAULT_HASH'
#!/usr/bin/env bash
set -euo pipefail
if /usr/bin/env | /usr/bin/grep -Eq '^environment_phrase='; then
  exit 96
fi
if /usr/bin/env | /usr/bin/grep -E '^_wmh_(value|cleanup_marker_value|phrase|phrase_sha|saved_phrase_sha|inventory_sha|saved_inventory_sha|key|expected_key|digest|live_digest|captured|read_value|capture_outer_value|capture_value|capture_chunk|auth_helper_program|rest|word|root_prv|hex|es_key|xprv|xpub|root|root_identity|destination|phase_lock|phase_lock_identity|phase_lock_token|phase_lock_seen_token|phase_lock_extra|phase_lock_snapshot|phase_lock_first_snapshot|phase_lock_pid|phase_lock_root_device|phase_lock_saved_umask|lock|lock_identity|stage|stage_identity|state|inventory|ack|cleanup_marker|saved_root|saved_root_identity|saved_destination|saved_destination_identity|saved_lock_identity|saved_stage_identity|publish_active_leaf)=' |
    /usr/bin/grep -Ev '=ambient-export-sentinel$' >/dev/null; then
  exit 96
fi
if [[ "${MNEMONIC_HELPER_FAULT:-}" == late-output-replacement &&
      -n "${MNEMONIC_HELPER_OUTPUT_LATE_PATH:-}" &&
      -s "${MNEMONIC_HELPER_OUTPUT_LATE_PATH}" &&
      ! -L "${MNEMONIC_HELPER_OUTPUT_LATE_PATH}" &&
      ! -e "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER:?}" ]]; then
  /bin/rm -f -- "${MNEMONIC_HELPER_OUTPUT_LATE_PATH}"
  case "${MNEMONIC_HELPER_OUTPUT_REPLACEMENT:?}" in
    symlink)
      /bin/ln -s -- "${MNEMONIC_HELPER_OUTPUT_OUTSIDE:?}" \
        "${MNEMONIC_HELPER_OUTPUT_LATE_PATH}"
      ;;
    hardlink)
      /bin/ln -- "${MNEMONIC_HELPER_OUTPUT_OUTSIDE:?}" \
        "${MNEMONIC_HELPER_OUTPUT_LATE_PATH}"
      ;;
    fifo) mkfifo -- "${MNEMONIC_HELPER_OUTPUT_LATE_PATH}" ;;
    *) exit 64 ;;
  esac
  : > "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER}"
fi
exec "${MNEMONIC_HELPER_REAL_HASH:?}" "$@"
EOF_FAULT_HASH
chmod 0700 "${FAULT_BIN}/ln" "${FAULT_BIN}/rm" "${FAULT_BIN}/stat" \
  "${FAULT_BIN}/${MNEMONIC_HELPER_HASH_NAME}"

jq -nS --arg type PaymentVerificationKeyShelley_ed25519 '
  {
    cborHex: ("f" * 64),
    description: "outside sentinel must remain byte-for-byte unchanged",
    type: $type
  }
' > "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}"
chmod 0640 "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}"
cp -- "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}" \
  "${MNEMONIC_HELPER_OUTPUT_SNAPSHOT}"
chmod 0600 "${MNEMONIC_HELPER_OUTPUT_SNAPSHOT}"
MNEMONIC_HELPER_OUTPUT_OUTSIDE_IDENTITY="$(
  file_identity_links "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}"
)"
[[ "${MNEMONIC_HELPER_OUTPUT_OUTSIDE_IDENTITY}" == *$'\t1' ]] ||
  fail 'outside output sentinel did not start as a single-link inode'

# shellcheck source=/dev/null
builtin source "${MEMBER_SOURCE}"

PRODUCTION_TYPE_CAPTURE_COUNT=0
PRODUCTION_SOURCE_LINE_NUMBER=0
PUBLISH_ACTIVE_RECORD_COUNT=0
PUBLISH_ACTIVE_RECORD_LINE=0
PUBLISH_LINK_CALL_LINE=0
PUBLISH_ROLLBACK_ENABLE_COUNT=0
PUBLISH_ROLLBACK_FD_GATE_COUNT=0
PUBLISH_RETRY_STATE_COUNT=0
CALLER_RESERVED_CASE_LINE=0
CALLER_RESERVED_RULE_LINE=0
CALLER_EXISTENCE_RULE_LINE=0
CALLER_NAMEREF_RULE_LINE=0
CALLER_ATTRIBUTE_READ_LINE=0
CALLER_ATTRIBUTE_POLICY_LINE=0
CALLER_PHRASE_UNEXPORT_LINE=0
PRIVATE_UNEXPORT_IN_PROGRESS=N
PRIVATE_UNEXPORT_PROGRAM=
MNEMONIC_CORE_IN_PROGRESS=N
MNEMONIC_CORE_LOCAL_PREFIX_VIOLATIONS=0
while IFS= builtin read -r PRODUCTION_SOURCE_LINE; do
  PRODUCTION_SOURCE_LINE_NUMBER=$((PRODUCTION_SOURCE_LINE_NUMBER + 1))
  if [[ "${PRODUCTION_SOURCE_LINE}" == \
      '_cntools_compatibility_wallet_mnemonic_run() {' ]]; then
    MNEMONIC_CORE_IN_PROGRESS=Y
  elif [[ "${PRODUCTION_SOURCE_LINE}" == \
      '# Command     : createMnemonicWallet' ]]; then
    MNEMONIC_CORE_IN_PROGRESS=N
  fi
  if [[ "${MNEMONIC_CORE_IN_PROGRESS}" == Y &&
        "${PRODUCTION_SOURCE_LINE}" =~ ^[[:space:]]*(builtin[[:space:]]+)?local[[:space:]] &&
        ! "${PRODUCTION_SOURCE_LINE}" =~ local[[:space:]]+(-[aA][[:space:]]+)?(_wmh_|LC_ALL) ]]; then
    MNEMONIC_CORE_LOCAL_PREFIX_VIOLATIONS=$((MNEMONIC_CORE_LOCAL_PREFIX_VIOLATIONS + 1))
  fi
  if [[ "${PRODUCTION_SOURCE_LINE}" == \
      *'builtin export -n _wmh_value _wmh_cleanup_marker_value _wmh_phrase'* ]]; then
    PRIVATE_UNEXPORT_IN_PROGRESS=Y
  fi
  if [[ "${PRIVATE_UNEXPORT_IN_PROGRESS}" == Y ]]; then
    PRIVATE_UNEXPORT_PROGRAM+=" ${PRODUCTION_SOURCE_LINE}"
    [[ "${PRODUCTION_SOURCE_LINE}" != *'_wmh_phrase_was_exported || return 70'* ]] ||
      PRIVATE_UNEXPORT_IN_PROGRESS=N
  fi
  [[ "${PRODUCTION_SOURCE_LINE}" != '    case "${_wmh_name}" in' ]] ||
    CALLER_RESERVED_CASE_LINE=${PRODUCTION_SOURCE_LINE_NUMBER}
  [[ "${PRODUCTION_SOURCE_LINE}" != '      _wmh_*|LC_ALL) return 64 ;;' ]] ||
    CALLER_RESERVED_RULE_LINE=${PRODUCTION_SOURCE_LINE_NUMBER}
  [[ "${PRODUCTION_SOURCE_LINE}" != *'-v "${_wmh_name}" ]] || return 64'* ]] ||
    CALLER_EXISTENCE_RULE_LINE=${PRODUCTION_SOURCE_LINE_NUMBER}
  [[ "${PRODUCTION_SOURCE_LINE}" != '    [[ ! -R "${_wmh_name}" ]] || return 64' ]] ||
    CALLER_NAMEREF_RULE_LINE=${PRODUCTION_SOURCE_LINE_NUMBER}
  [[ "${PRODUCTION_SOURCE_LINE}" != '    _wmh_value="${!_wmh_name@a}"' ]] ||
    CALLER_ATTRIBUTE_READ_LINE=${PRODUCTION_SOURCE_LINE_NUMBER}
  [[ "${PRODUCTION_SOURCE_LINE}" != \
      '    [[ -z "${_wmh_value}" || "${_wmh_value}" == x ]] || return 64' ]] ||
    CALLER_ATTRIBUTE_POLICY_LINE=${PRODUCTION_SOURCE_LINE_NUMBER}
  [[ "${PRODUCTION_SOURCE_LINE}" != \
      '  builtin export -n "${_wmh_phrase_name}" || return 70' ]] ||
    CALLER_PHRASE_UNEXPORT_LINE=${PRODUCTION_SOURCE_LINE_NUMBER}
  [[ "${PRODUCTION_SOURCE_LINE}" != *'$(builtin type -t '* &&
     "${PRODUCTION_SOURCE_LINE}" != *'$(builtin type -P '* ]] ||
    PRODUCTION_TYPE_CAPTURE_COUNT=$((PRODUCTION_TYPE_CAPTURE_COUNT + 1))
  if [[ "${PRODUCTION_SOURCE_LINE}" == *'_wmh_publish_active_leaf="${_wmh_leaf}"'* ]]; then
    PUBLISH_ACTIVE_RECORD_COUNT=$((PUBLISH_ACTIVE_RECORD_COUNT + 1))
    PUBLISH_ACTIVE_RECORD_LINE=${PRODUCTION_SOURCE_LINE_NUMBER}
  fi
  [[ "${PRODUCTION_SOURCE_LINE}" != *'"${_wmh_tools[ln]}" -- "${_wmh_stage}/${_wmh_leaf}"'* ]] ||
    PUBLISH_LINK_CALL_LINE=${PRODUCTION_SOURCE_LINE_NUMBER}
  [[ "${PRODUCTION_SOURCE_LINE}" != *'_wmh_publish_rollback_active=Y'* ]] ||
    PUBLISH_ROLLBACK_ENABLE_COUNT=$((PUBLISH_ROLLBACK_ENABLE_COUNT + 1))
  [[ "${PRODUCTION_SOURCE_LINE}" != *'"${_wmh_publish_rollback_active:-N}" == Y'* ]] ||
    PUBLISH_ROLLBACK_FD_GATE_COUNT=$((PUBLISH_ROLLBACK_FD_GATE_COUNT + 1))
  [[ "${PRODUCTION_SOURCE_LINE}" != *'_wmh_publish_retry_state=Y'* ]] ||
    PUBLISH_RETRY_STATE_COUNT=$((PUBLISH_RETRY_STATE_COUNT + 1))
done < "${MEMBER_SOURCE}"
(( PRODUCTION_TYPE_CAPTURE_COUNT == 0 )) ||
  fail 'production tool resolution must not fork through builtin type'
(( PUBLISH_ACTIVE_RECORD_COUNT == 1 &&
   PUBLISH_ACTIVE_RECORD_LINE > 0 &&
   PUBLISH_LINK_CALL_LINE > PUBLISH_ACTIVE_RECORD_LINE &&
   PUBLISH_ROLLBACK_ENABLE_COUNT == 1 &&
   PUBLISH_ROLLBACK_FD_GATE_COUNT == 1 &&
   PUBLISH_RETRY_STATE_COUNT == 1 )) ||
  fail 'publish rollback journal/gate is not uniquely bounded before link creation'
(( MNEMONIC_CORE_LOCAL_PREFIX_VIOLATIONS == 0 &&
   CALLER_RESERVED_CASE_LINE > 0 &&
   CALLER_RESERVED_RULE_LINE > CALLER_RESERVED_CASE_LINE &&
   CALLER_EXISTENCE_RULE_LINE > CALLER_RESERVED_RULE_LINE &&
   CALLER_NAMEREF_RULE_LINE > CALLER_EXISTENCE_RULE_LINE &&
   CALLER_ATTRIBUTE_READ_LINE > CALLER_NAMEREF_RULE_LINE &&
   CALLER_ATTRIBUTE_POLICY_LINE > CALLER_ATTRIBUTE_READ_LINE &&
   CALLER_PHRASE_UNEXPORT_LINE > CALLER_ATTRIBUTE_POLICY_LINE )) ||
  fail 'caller-slot namespace/attribute validation is incomplete or late'
for PRIVATE_UNEXPORT_NAME in \
    _wmh_root _wmh_root_identity _wmh_destination \
    _wmh_phase_lock _wmh_phase_lock_identity _wmh_phase_lock_token \
    _wmh_phase_lock_seen_token _wmh_phase_lock_extra \
    _wmh_phase_lock_snapshot _wmh_phase_lock_first_snapshot \
    _wmh_phase_lock_pid _wmh_phase_lock_root_device \
    _wmh_phase_lock_saved_umask _wmh_lock _wmh_lock_identity \
    _wmh_stage _wmh_stage_identity _wmh_state _wmh_inventory _wmh_ack \
    _wmh_cleanup_marker _wmh_saved_root _wmh_saved_root_identity \
    _wmh_saved_destination _wmh_saved_destination_identity \
    _wmh_saved_lock_identity _wmh_saved_stage_identity \
    _wmh_publish_active_leaf; do
  [[ "${PRIVATE_UNEXPORT_PROGRAM}" == *"${PRIVATE_UNEXPORT_NAME}"* ]] ||
    fail "private capability unexport is missing: ${PRIVATE_UNEXPORT_NAME}"
done
grep -Fq 'local mnemonic_compatibility_state="" _wmh_legacy_status=0' \
    "${MEMBER_SOURCE}" &&
  ! grep -Fq '_wmh_legacy_state' "${MEMBER_SOURCE}" ||
  fail 'legacy adapter still uses a reserved phase-local slot name'

# Every phase call is captured without changing its caller-visible status or
# streams. Unexpected failures therefore retain the exact phase diagnostics,
# status, caller slots, vectors, tree metadata, open descriptors, jobs, and
# process snapshot through fail()'s automatic evidence preservation.
"${TEST_REAL_MKDIR}" -m 0700 -- "${PHASE_CAPTURE_DIR}"
for TEST_JOBS_FILE in stress-jobs-before.list stress-jobs-after.list \
    capture-jobs-before.list capture-jobs-after.list; do
  : > "${TEST_ROOT}/${TEST_JOBS_FILE}"
done
"${TEST_REAL_CHMOD}" 0600 \
  "${TEST_ROOT}/stress-jobs-before.list" \
  "${TEST_ROOT}/stress-jobs-after.list" \
  "${TEST_ROOT}/capture-jobs-before.list" \
  "${TEST_ROOT}/capture-jobs-after.list"
# TEST_CAPTURE_BOUND_LITERAL_BEGIN
        _wmh_capture_worker_program=
        IFS= builtin read -r -d '' _wmh_capture_worker_program <<'GUILD_CNTOOLS_CAPTURE_WORKER' || true
          local _wmh_capture_value="" _wmh_capture_chunk=""
          local _wmh_capture_read_fd="" _wmh_capture_output_write_fd=""
          local _wmh_capture_input_read_fd="" _wmh_capture_input_write_fd=""
          local _wmh_capture_input_keeper_fd=""
          local _wmh_capture_output_keeper_fd=""
          local _wmh_capture_read_fd_number=""
          local _wmh_capture_output_write_fd_number=""
          local _wmh_capture_input_read_fd_number=""
          local _wmh_capture_input_write_fd_number=""
          local _wmh_capture_input_keeper_fd_number=""
          local _wmh_capture_output_keeper_fd_number=""
          local _wmh_capture_fixed_fd_serial=0
          local -A _wmh_capture_fixed_fd_owned=()
          local _wmh_capture_input_pipe="${_wmh_lock}/.capture-input.pipe"
          local _wmh_capture_output_pipe="${_wmh_lock}/.capture-output.pipe"
          local _wmh_capture_pid="" _wmh_capture_bad=N
          local _wmh_capture_read_status=0 _wmh_capture_wait_status=0
          local _wmh_capture_remaining=0 _wmh_capture_timeout_ticks=0
          local _wmh_capture_monitor_was_on=N
          builtin export -n _wmh_capture_value _wmh_capture_chunk ||
            return 70
          if [[ -n "${_wmh_capture_input_name}" ]]; then
            builtin export -n "${_wmh_capture_input_name}" || return 70
          fi
          __guild_cntools_wallet_capture_fixed_fd_acquire() {
            local _wmh_cfd_mode="${1:-}" _wmh_cfd_path="${2:-}"
            local _wmh_cfd_token_name="${3:-}" _wmh_cfd_number_name="${4:-}"
            local _wmh_cfd_fd=0 _wmh_cfd_token=""


            [[ "${_wmh_cfd_mode}" =~ ^(ro|wo|rw)$ &&
               "${_wmh_cfd_path}" == /* &&
               "${_wmh_cfd_token_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
               "${_wmh_cfd_number_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
               "${_wmh_signal_pending}" == N ]] || return 1
            for ((_wmh_cfd_fd=64; _wmh_cfd_fd<=79; _wmh_cfd_fd++)); do
              [[ ! -e "/dev/fd/${_wmh_cfd_fd}" &&
                 -z "${_wmh_capture_fixed_fd_owned[${_wmh_cfd_fd}]+set}" ]] ||
                continue
              case "${_wmh_cfd_mode}:${_wmh_cfd_fd}" in
                ro:64) ex''ec 64< "${_wmh_cfd_path}" ;;
                ro:65) ex''ec 65< "${_wmh_cfd_path}" ;;
                ro:66) ex''ec 66< "${_wmh_cfd_path}" ;;
                ro:67) ex''ec 67< "${_wmh_cfd_path}" ;;
                ro:68) ex''ec 68< "${_wmh_cfd_path}" ;;
                ro:69) ex''ec 69< "${_wmh_cfd_path}" ;;
                ro:70) ex''ec 70< "${_wmh_cfd_path}" ;;
                ro:71) ex''ec 71< "${_wmh_cfd_path}" ;;
                ro:72) ex''ec 72< "${_wmh_cfd_path}" ;;
                ro:73) ex''ec 73< "${_wmh_cfd_path}" ;;
                ro:74) ex''ec 74< "${_wmh_cfd_path}" ;;
                ro:75) ex''ec 75< "${_wmh_cfd_path}" ;;
                ro:76) ex''ec 76< "${_wmh_cfd_path}" ;;
                ro:77) ex''ec 77< "${_wmh_cfd_path}" ;;
                ro:78) ex''ec 78< "${_wmh_cfd_path}" ;;
                ro:79) ex''ec 79< "${_wmh_cfd_path}" ;;
                wo:64) ex''ec 64> "${_wmh_cfd_path}" ;;
                wo:65) ex''ec 65> "${_wmh_cfd_path}" ;;
                wo:66) ex''ec 66> "${_wmh_cfd_path}" ;;
                wo:67) ex''ec 67> "${_wmh_cfd_path}" ;;
                wo:68) ex''ec 68> "${_wmh_cfd_path}" ;;
                wo:69) ex''ec 69> "${_wmh_cfd_path}" ;;
                wo:70) ex''ec 70> "${_wmh_cfd_path}" ;;
                wo:71) ex''ec 71> "${_wmh_cfd_path}" ;;
                wo:72) ex''ec 72> "${_wmh_cfd_path}" ;;
                wo:73) ex''ec 73> "${_wmh_cfd_path}" ;;
                wo:74) ex''ec 74> "${_wmh_cfd_path}" ;;
                wo:75) ex''ec 75> "${_wmh_cfd_path}" ;;
                wo:76) ex''ec 76> "${_wmh_cfd_path}" ;;
                wo:77) ex''ec 77> "${_wmh_cfd_path}" ;;
                wo:78) ex''ec 78> "${_wmh_cfd_path}" ;;
                wo:79) ex''ec 79> "${_wmh_cfd_path}" ;;
                rw:64) ex''ec 64<> "${_wmh_cfd_path}" ;;
                rw:65) ex''ec 65<> "${_wmh_cfd_path}" ;;
                rw:66) ex''ec 66<> "${_wmh_cfd_path}" ;;
                rw:67) ex''ec 67<> "${_wmh_cfd_path}" ;;
                rw:68) ex''ec 68<> "${_wmh_cfd_path}" ;;
                rw:69) ex''ec 69<> "${_wmh_cfd_path}" ;;
                rw:70) ex''ec 70<> "${_wmh_cfd_path}" ;;
                rw:71) ex''ec 71<> "${_wmh_cfd_path}" ;;
                rw:72) ex''ec 72<> "${_wmh_cfd_path}" ;;
                rw:73) ex''ec 73<> "${_wmh_cfd_path}" ;;
                rw:74) ex''ec 74<> "${_wmh_cfd_path}" ;;
                rw:75) ex''ec 75<> "${_wmh_cfd_path}" ;;
                rw:76) ex''ec 76<> "${_wmh_cfd_path}" ;;
                rw:77) ex''ec 77<> "${_wmh_cfd_path}" ;;
                rw:78) ex''ec 78<> "${_wmh_cfd_path}" ;;
                rw:79) ex''ec 79<> "${_wmh_cfd_path}" ;;
                *) return 1 ;;
              esac || return 1
              _wmh_capture_fixed_fd_serial=$((_wmh_capture_fixed_fd_serial + 1))
              _wmh_cfd_token="wmhcfd:${BASHPID}:${_wmh_capture_fixed_fd_serial}:${_wmh_cfd_fd}"
              _wmh_capture_fixed_fd_owned["${_wmh_cfd_fd}"]="${_wmh_cfd_token}"
              if [[ ! -e "/dev/fd/${_wmh_cfd_fd}" ]]; then
                __guild_cntools_wallet_capture_fixed_fd_close \
                  "${_wmh_cfd_token}" >/dev/null 2>&1 || true
                return 1
              fi
              builtin printf -v "${_wmh_cfd_token_name}" '%s' \
                "${_wmh_cfd_token}"
              builtin printf -v "${_wmh_cfd_number_name}" '%s' \
                "${_wmh_cfd_fd}"
              return 0
            done
            return 1
          }
          __guild_cntools_wallet_capture_fixed_fd_close() {
            local _wmh_cfd_token="${1:-}" _wmh_cfd_pid=""
            local _wmh_cfd_serial="" _wmh_cfd_fd=""


            [[ "${_wmh_cfd_token}" =~ \
                 ^wmhcfd:([1-9][0-9]*):([1-9][0-9]*):(6[4-9]|7[0-9])$ ]] ||
              return 1
            _wmh_cfd_pid="${BASH_REMATCH[1]}"
            _wmh_cfd_serial="${BASH_REMATCH[2]}"
            _wmh_cfd_fd="${BASH_REMATCH[3]}"
            [[ "${_wmh_capture_fixed_fd_owned[${_wmh_cfd_fd}]:-}" == \
                 "wmhcfd:${_wmh_cfd_pid}:${_wmh_cfd_serial}:${_wmh_cfd_fd}" ]] ||
              return 1
            case "${_wmh_cfd_fd}" in
              64) ex''ec 64>&- ;; 65) ex''ec 65>&- ;;
              66) ex''ec 66>&- ;; 67) ex''ec 67>&- ;;
              68) ex''ec 68>&- ;; 69) ex''ec 69>&- ;;
              70) ex''ec 70>&- ;; 71) ex''ec 71>&- ;;
              72) ex''ec 72>&- ;; 73) ex''ec 73>&- ;;
              74) ex''ec 74>&- ;; 75) ex''ec 75>&- ;;
              76) ex''ec 76>&- ;; 77) ex''ec 77>&- ;;
              78) ex''ec 78>&- ;; 79) ex''ec 79>&- ;;
              *) return 1 ;;
            esac || return 1
            [[ ! -e "/dev/fd/${_wmh_cfd_fd}" ]] || return 1
            builtin unset \
              "_wmh_capture_fixed_fd_owned[${_wmh_cfd_fd}]"
          }
          __guild_cntools_wallet_capture_interrupt() {
            _wmh_signal_pending=Y
            [[ ! -p "${_wmh_capture_input_pipe}" ||
               -L "${_wmh_capture_input_pipe}" ]] ||
              "${_wmh_tools[rm]}" -f -- "${_wmh_capture_input_pipe}" || true
            [[ ! -p "${_wmh_capture_output_pipe}" ||
               -L "${_wmh_capture_output_pipe}" ]] ||
              "${_wmh_tools[rm]}" -f -- "${_wmh_capture_output_pipe}" || true
            if [[ "${_wmh_capture_pid}" =~ ^[1-9][0-9]*$ ]]; then
              builtin kill -TERM -- "-${_wmh_capture_pid}" \
                2>/dev/null || true
              builtin kill -TERM "${_wmh_capture_pid}" 2>/dev/null || true
              builtin kill -KILL -- "-${_wmh_capture_pid}" \
                2>/dev/null || true
              builtin kill -KILL "${_wmh_capture_pid}" 2>/dev/null || true
            fi
          }
          builtin trap '__guild_cntools_wallet_capture_interrupt' HUP INT TERM


          [[ "${_wmh_capture_max}" =~ ^[1-9][0-9]*$ &&
             "${_wmh_capture_max}" -le 65536 &&
             ( -z "${_wmh_capture_input_name}" ||
               "${_wmh_capture_input_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ) &&
             $# -gt 0 ]] || return 1
          [[ ! -e "${_wmh_capture_input_pipe}" &&
             ! -L "${_wmh_capture_input_pipe}" &&
             ! -e "${_wmh_capture_output_pipe}" &&
             ! -L "${_wmh_capture_output_pipe}" ]] || return 70
          if ! "${_wmh_tools[mkfifo]}" -m 0600 -- \
              "${_wmh_capture_input_pipe}" ||
             ! "${_wmh_tools[mkfifo]}" -m 0600 -- \
              "${_wmh_capture_output_pipe}" ||
             [[ ! -p "${_wmh_capture_input_pipe}" ||
                -L "${_wmh_capture_input_pipe}" ||
                ! -p "${_wmh_capture_output_pipe}" ||
                -L "${_wmh_capture_output_pipe}" ]] ||
             ! __guild_cntools_wallet_capture_fixed_fd_acquire rw \
                "${_wmh_capture_input_pipe}" \
                _wmh_capture_input_keeper_fd \
                _wmh_capture_input_keeper_fd_number ||
             ! __guild_cntools_wallet_capture_fixed_fd_acquire rw \
                "${_wmh_capture_output_pipe}" \
                _wmh_capture_output_keeper_fd \
                _wmh_capture_output_keeper_fd_number ||
             ! __guild_cntools_wallet_capture_fixed_fd_acquire ro \
                "${_wmh_capture_input_pipe}" \
                _wmh_capture_input_read_fd \
                _wmh_capture_input_read_fd_number ||
             ! __guild_cntools_wallet_capture_fixed_fd_acquire wo \
                "${_wmh_capture_input_pipe}" \
                _wmh_capture_input_write_fd \
                _wmh_capture_input_write_fd_number ||
             ! __guild_cntools_wallet_capture_fixed_fd_acquire ro \
                "${_wmh_capture_output_pipe}" _wmh_capture_read_fd \
                _wmh_capture_read_fd_number ||
             ! __guild_cntools_wallet_capture_fixed_fd_acquire wo \
                "${_wmh_capture_output_pipe}" \
                _wmh_capture_output_write_fd \
                _wmh_capture_output_write_fd_number; then
            [[ -z "${_wmh_capture_input_read_fd}" ]] ||
              __guild_cntools_wallet_capture_fixed_fd_close \
                "${_wmh_capture_input_read_fd}" >/dev/null 2>&1 || true
            [[ -z "${_wmh_capture_input_write_fd}" ]] ||
              __guild_cntools_wallet_capture_fixed_fd_close \
                "${_wmh_capture_input_write_fd}" >/dev/null 2>&1 || true
            [[ -z "${_wmh_capture_read_fd}" ]] ||
              __guild_cntools_wallet_capture_fixed_fd_close \
                "${_wmh_capture_read_fd}" >/dev/null 2>&1 || true
            [[ -z "${_wmh_capture_output_write_fd}" ]] ||
              __guild_cntools_wallet_capture_fixed_fd_close \
                "${_wmh_capture_output_write_fd}" >/dev/null 2>&1 || true
            [[ -z "${_wmh_capture_input_keeper_fd}" ]] ||
              __guild_cntools_wallet_capture_fixed_fd_close \
                "${_wmh_capture_input_keeper_fd}" >/dev/null 2>&1 || true
            [[ -z "${_wmh_capture_output_keeper_fd}" ]] ||
              __guild_cntools_wallet_capture_fixed_fd_close \
                "${_wmh_capture_output_keeper_fd}" >/dev/null 2>&1 || true
            [[ ! -p "${_wmh_capture_input_pipe}" ||
               -L "${_wmh_capture_input_pipe}" ]] ||
              "${_wmh_tools[rm]}" -f -- "${_wmh_capture_input_pipe}" || true
            [[ ! -p "${_wmh_capture_output_pipe}" ||
               -L "${_wmh_capture_output_pipe}" ]] ||
              "${_wmh_tools[rm]}" -f -- "${_wmh_capture_output_pipe}" || true
            return 70
          fi
          if ! "${_wmh_tools[rm]}" -f -- "${_wmh_capture_input_pipe}" \
              "${_wmh_capture_output_pipe}" ||
             [[ -e "${_wmh_capture_input_pipe}" ||
                -L "${_wmh_capture_input_pipe}" ||
                -e "${_wmh_capture_output_pipe}" ||
                -L "${_wmh_capture_output_pipe}" ]]; then
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_input_read_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_input_write_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_read_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_output_write_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_input_keeper_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_output_keeper_fd}" >/dev/null 2>&1 || true
            [[ ! -p "${_wmh_capture_input_pipe}" ||
               -L "${_wmh_capture_input_pipe}" ]] ||
              "${_wmh_tools[rm]}" -f -- "${_wmh_capture_input_pipe}" || true
            [[ ! -p "${_wmh_capture_output_pipe}" ||
               -L "${_wmh_capture_output_pipe}" ]] ||
              "${_wmh_tools[rm]}" -f -- "${_wmh_capture_output_pipe}" || true
            return 70
          fi
          __guild_cntools_wallet_capture_fixed_fd_close \
            "${_wmh_capture_input_keeper_fd}" || return 70
          __guild_cntools_wallet_capture_fixed_fd_close \
            "${_wmh_capture_output_keeper_fd}" || return 70
          [[ $- != *m* ]] || _wmh_capture_monitor_was_on=Y
          # A temporary monitor-mode launch gives the exec'd tool a private
          # process group. The background subshell execs into the tool, so
          # a faulty tool and any pipe-holding descendants can be terminated
          # and the direct child reaped without touching the caller's group.
          if ! builtin set -m; then
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_input_read_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_input_write_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_read_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_output_write_fd}" >/dev/null 2>&1 || true
            return 70
          fi
          (
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_input_write_fd}" || builtin exit 70
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_read_fd}" || builtin exit 70
            builtin exec -- "$@" \
              <&"${_wmh_capture_input_read_fd_number}" \
              >&"${_wmh_capture_output_write_fd_number}" 2>&1
          ) &
          _wmh_capture_pid=$!
          __guild_cntools_wallet_capture_fixed_fd_close \
            "${_wmh_capture_input_read_fd}" || _wmh_capture_bad=Y
          __guild_cntools_wallet_capture_fixed_fd_close \
            "${_wmh_capture_output_write_fd}" || _wmh_capture_bad=Y
          if [[ -n "${_wmh_capture_input_name}" ]]; then
            builtin printf '%s\n' "${!_wmh_capture_input_name}" \
              >&"${_wmh_capture_input_write_fd_number}" ||
              _wmh_capture_bad=Y
          fi
          __guild_cntools_wallet_capture_fixed_fd_close \
            "${_wmh_capture_input_write_fd}" || _wmh_capture_bad=Y
          while [[ "${_wmh_capture_bad}" == N &&
                   "${_wmh_signal_pending}" == N ]]; do
            _wmh_capture_remaining=$((_wmh_capture_max + 1 -
              ${#_wmh_capture_value}))
            (( _wmh_capture_remaining > 0 )) || {
              _wmh_capture_bad=Y
              break
            }
            _wmh_capture_chunk=
            _wmh_capture_read_status=0
            IFS= builtin read -r -d '' -n "${_wmh_capture_remaining}" \
              -t 1 _wmh_capture_chunk \
              <&"${_wmh_capture_read_fd_number}" ||
              _wmh_capture_read_status=$?
            _wmh_capture_value+="${_wmh_capture_chunk}"
            if (( _wmh_capture_read_status == 0 )); then
              _wmh_capture_bad=Y
              break
            fi
            (( ${#_wmh_capture_value} <= _wmh_capture_max )) || {
              _wmh_capture_bad=Y
              break
            }
            if (( _wmh_capture_read_status == 1 )); then
              break
            elif (( _wmh_capture_read_status > 128 )); then
              _wmh_capture_timeout_ticks=$((_wmh_capture_timeout_ticks + 1))
              (( _wmh_capture_timeout_ticks < 10 )) || {
                _wmh_capture_bad=Y
                break
              }
            else
              _wmh_capture_bad=Y
              break
            fi
          done
          __guild_cntools_wallet_capture_fixed_fd_close \
            "${_wmh_capture_read_fd}" || _wmh_capture_bad=Y
          if [[ "${_wmh_signal_pending}" == Y ||
                "${_wmh_capture_bad}" == Y ]]; then
            _wmh_capture_bad=Y
            builtin kill -TERM -- "-${_wmh_capture_pid}" \
              2>/dev/null || true
            builtin kill -TERM "${_wmh_capture_pid}" 2>/dev/null || true
            builtin kill -KILL -- "-${_wmh_capture_pid}" \
              2>/dev/null || true
            builtin kill -KILL "${_wmh_capture_pid}" 2>/dev/null || true
          fi
          while :; do
            builtin wait "${_wmh_capture_pid}" 2>/dev/null
            _wmh_capture_wait_status=$?
            builtin kill -0 "${_wmh_capture_pid}" 2>/dev/null || break
            builtin kill -KILL -- "-${_wmh_capture_pid}" \
              2>/dev/null || true
            builtin kill -KILL "${_wmh_capture_pid}" 2>/dev/null || true
          done
          [[ "${_wmh_capture_monitor_was_on}" == Y ]] || builtin set +m
          [[ "${_wmh_capture_bad}" == N &&
             "${_wmh_signal_pending}" == N ]] || return 70
          (( _wmh_capture_wait_status == 0 )) || return 1
          while [[ "${_wmh_capture_value}" == *$'\n' ]]; do
            _wmh_capture_value="${_wmh_capture_value%$'\n'}"
          done
          (( ${#_wmh_capture_fixed_fd_owned[@]} == 0 )) || return 70
          builtin trap - HUP INT TERM
          builtin unset -f __guild_cntools_wallet_capture_interrupt \
            __guild_cntools_wallet_capture_fixed_fd_acquire \
            __guild_cntools_wallet_capture_fixed_fd_close
          builtin printf '%s' "${_wmh_capture_value}"
GUILD_CNTOOLS_CAPTURE_WORKER
        _test_cntools_wallet_capture_bound() {
          local _wmh_capture_max="${1:-}" _wmh_capture_result_name="${2:-}"
          local _wmh_capture_input_name="${3:-}"
          shift 3 || return 1
          local _wmh_capture_outer_value="" _wmh_capture_outer_status=0


          builtin export -n _wmh_capture_outer_value || return 70

          [[ "${_wmh_capture_max}" =~ ^[1-9][0-9]*$ &&
             "${_wmh_capture_max}" -le 65536 &&
             "${_wmh_capture_result_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
             ( -z "${_wmh_capture_input_name}" ||
               "${_wmh_capture_input_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ) &&
             $# -gt 0 ]] || return 1
          if _wmh_capture_outer_value="$(
          (
            builtin eval "${_wmh_capture_worker_program}"
          ) 2>/dev/null
          )"; then
            _wmh_capture_outer_status=0
          else
            _wmh_capture_outer_status=$?
          fi
          [[ "${_wmh_signal_pending}" == N ]] || return 70
          (( _wmh_capture_outer_status == 0 )) || {
            (( _wmh_capture_outer_status == 70 )) && return 70
            return 1
          }
          builtin printf -v "${_wmh_capture_result_name}" '%s' \
            "${_wmh_capture_outer_value}"
        }
# TEST_CAPTURE_BOUND_LITERAL_END

CAPTURE_LITERAL_SOURCE="${TEST_ROOT}/capture-helper.literal.sh"
CAPTURE_PRODUCTION_SOURCE="${TEST_ROOT}/capture-helper.production.sh"
sed -n '/^# TEST_CAPTURE_BOUND_LITERAL_BEGIN$/,/^# TEST_CAPTURE_BOUND_LITERAL_END$/p' \
  "${BASH_SOURCE[0]}" | sed '1d;$d' > "${CAPTURE_LITERAL_SOURCE}"
sed -n \
  '/^        _wmh_capture_worker_program=$/,/^        __guild_cntools_wallet_ccli_capture_bound() {$/p' \
  "${MEMBER_SOURCE}" | sed \
    '$d;s/__guild_cntools_wallet_capture_bound/_test_cntools_wallet_capture_bound/' \
    > "${CAPTURE_PRODUCTION_SOURCE}"
cmp -s -- "${CAPTURE_LITERAL_SOURCE}" "${CAPTURE_PRODUCTION_SOURCE}" || {
  diff -u -- "${CAPTURE_PRODUCTION_SOURCE}" "${CAPTURE_LITERAL_SOURCE}" \
    >&2 || true
  fail 'test-local capture helper literal diverged from production'
}


CAPTURE_QUOTED_WORKER_COUNT=0
CAPTURE_CONSTANT_EVAL_COUNT=0
CAPTURE_NESTED_SUPERVISOR_COUNT=0
while IFS= builtin read -r CAPTURE_LITERAL_LINE; do
  [[ "${CAPTURE_LITERAL_LINE}" != "        IFS= builtin read -r -d '' _wmh_capture_worker_program <<'GUILD_CNTOOLS_CAPTURE_WORKER' || true" ]] ||
    CAPTURE_QUOTED_WORKER_COUNT=$((CAPTURE_QUOTED_WORKER_COUNT + 1))
  [[ "${CAPTURE_LITERAL_LINE}" != '            builtin eval "${_wmh_capture_worker_program}"' ]] ||
    CAPTURE_CONSTANT_EVAL_COUNT=$((CAPTURE_CONSTANT_EVAL_COUNT + 1))
  [[ "${CAPTURE_LITERAL_LINE}" != '          ) 2>/dev/null' ]] ||
    CAPTURE_NESTED_SUPERVISOR_COUNT=$((CAPTURE_NESTED_SUPERVISOR_COUNT + 1))
done < "${CAPTURE_LITERAL_SOURCE}"
(( CAPTURE_QUOTED_WORKER_COUNT == 1 &&
   CAPTURE_CONSTANT_EVAL_COUNT == 1 &&
   CAPTURE_NESTED_SUPERVISOR_COUNT == 1 )) ||
  fail 'capture worker must be one quoted constant in a nested quiet supervisor'
AUTH_HELPER_QUOTED_PROGRAM_COUNT=0
AUTH_HELPER_CONSTANT_EVAL_COUNT=0
while IFS= builtin read -r AUTH_HELPER_SOURCE_LINE; do
  [[ "${AUTH_HELPER_SOURCE_LINE}" != "        IFS= builtin read -r -d '' _wmh_auth_helper_program <<'GUILD_CNTOOLS_AUTH_HELPERS' || true" ]] ||
    AUTH_HELPER_QUOTED_PROGRAM_COUNT=$((AUTH_HELPER_QUOTED_PROGRAM_COUNT + 1))
  [[ "${AUTH_HELPER_SOURCE_LINE}" != '        if ! builtin eval "${_wmh_auth_helper_program}"; then' ]] ||
    AUTH_HELPER_CONSTANT_EVAL_COUNT=$((AUTH_HELPER_CONSTANT_EVAL_COUNT + 1))
done < "${MEMBER_SOURCE}"
(( AUTH_HELPER_QUOTED_PROGRAM_COUNT == 1 &&
   AUTH_HELPER_CONSTANT_EVAL_COUNT == 1 )) ||
  fail 'phase helpers must be one quoted constant evaluated without interpolation'
_test_snapshot_open_fds() {
  local _test_fd_result_name="${1:-}" _test_fd_result="" _test_fd=0

  [[ "${_test_fd_result_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  for ((_test_fd=0; _test_fd<256; _test_fd++)); do
    if [[ -e "/dev/fd/${_test_fd}" ]]; then
      _test_fd_result+="${_test_fd},"
    fi
  done
  builtin printf -v "${_test_fd_result_name}" '%s' "${_test_fd_result}"
}
_test_snapshot_running_jobs() {
  local _test_jobs_result_name="${1:-}" _test_jobs_file="${2:-}"
  local _test_jobs_result="" _test_jobs_line=""

  [[ "${_test_jobs_result_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_test_jobs_file}" == "${TEST_ROOT}/"* &&
     "${_test_jobs_file#"${TEST_ROOT}/"}" != */* &&
     -f "${_test_jobs_file}" && ! -L "${_test_jobs_file}" ]] || return 1
  : > "${_test_jobs_file}" || return 1
  builtin jobs -pr > "${_test_jobs_file}" 2>/dev/null || true
  while IFS= builtin read -r _test_jobs_line; do
    [[ -z "${_test_jobs_result}" ]] || _test_jobs_result+=$'\n'
    _test_jobs_result+="${_test_jobs_line}"
  done < "${_test_jobs_file}"
  builtin printf -v "${_test_jobs_result_name}" '%s' "${_test_jobs_result}"
}
_test_count_lines() {
  local _test_count_result_name="${1:-}" _test_count_path="${2:-}"
  local _test_count_value=0 _test_count_line=""

  [[ "${_test_count_result_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_test_count_path}" == "${TEST_ROOT}/"* &&
     -f "${_test_count_path}" && ! -L "${_test_count_path}" ]] || return 1
  while IFS= builtin read -r _test_count_line; do
    _test_count_value=$((_test_count_value + 1))
  done < "${_test_count_path}"
  builtin printf -v "${_test_count_result_name}" '%s' \
    "${_test_count_value}"
}
builtin shopt -s expand_aliases
builtin alias \
  _test_cntools_compatibility_wallet_mnemonic_run=_cntools_compatibility_wallet_mnemonic_run

WALLET_FOLDER="${WALLET_ROOT}"
wallet_name=fixture_wallet
acct_idx=7
key_idx=9
NETWORK_IDENTIFIER='--testnet-magic 42'
NWMAGIC=42
CCLI="${FAKE_BIN}/cardano-cli"
WALLET_DERIVATION_PATH_FILENAME=derivation.path
WALLET_PAY_SK_FILENAME=payment.skey
WALLET_PAY_VK_FILENAME=payment.vkey
WALLET_STAKE_SK_FILENAME=stake.skey
WALLET_STAKE_VK_FILENAME=stake.vkey
WALLET_GOV_DREP_SK_FILENAME=drep.skey
WALLET_GOV_DREP_VK_FILENAME=drep.vkey
WALLET_GOV_CC_COLD_SK_FILENAME=cc-cold.skey
WALLET_GOV_CC_COLD_VK_FILENAME=cc-cold.vkey
WALLET_GOV_CC_HOT_SK_FILENAME=cc-hot.skey
WALLET_GOV_CC_HOT_VK_FILENAME=cc-hot.vkey
WALLET_MULTISIG_PREFIX=ms-
WALLET_BASE_ADDR_FILENAME=base.addr
WALLET_PAY_ADDR_FILENAME=payment.addr
WALLET_STAKE_ADDR_FILENAME=reward.addr
WALLET_PAY_CRED_FILENAME=payment.cred
WALLET_STAKE_CRED_FILENAME=stake.cred
export VECTOR_LOG
MNEMONIC_HELPER_SIGNAL_PID="${BASHPID}"
export MNEMONIC_HELPER_SIGNAL_PID
PATH="${FAULT_BIN}:${FAKE_BIN}:${PATH}"
export PATH
MNEMONIC_HELPER_FAULT=
export MNEMONIC_HELPER_FAULT

phrase=
state=
base=
payment=
reward=

_test_reserved_slot_contract() {
  local _test_phase_spec="" _test_phase="" _test_slot_count=0
  local _test_slot_index=0 _test_status=0 _test_target=""
  local _test_vectors_before=0 _test_vectors_after=0
  local _test_fds_before="" _test_fds_after=""
  local _test_jobs_before="" _test_jobs_after=""
  local _test_options_before="$-" _test_traps_before=""
  local -a _test_args=()

  _test_count_lines _test_vectors_before "${VECTOR_LOG}" || return 1
  _test_snapshot_open_fds _test_fds_before || return 1
  _test_snapshot_running_jobs _test_jobs_before \
    "${TEST_ROOT}/stress-jobs-before.list" || return 1
  _test_traps_before="$(builtin trap -p HUP INT TERM DEBUG)"
  for _test_phase_spec in prepare:5 acknowledge:2 publish:5 abort:2 legacy:5; do
    _test_phase="${_test_phase_spec%%:*}"
    _test_slot_count="${_test_phase_spec#*:}"
    for ((_test_slot_index=1;
         _test_slot_index<=_test_slot_count;
         _test_slot_index++)); do
      (
        local slot_phrase="" slot_state="" slot_base="" slot_pay=""
        local slot_reward="" _wmh_phrase=caller-reserved-sentinel
        local -a slot_args=()

        wallet_name=reserved_slot_wallet
        if (( _test_slot_count == 5 )); then
          slot_args=("${_test_phase}" slot_phrase slot_state slot_base \
            slot_pay slot_reward)
        else
          slot_args=("${_test_phase}" slot_phrase slot_state)
        fi
        slot_args[_test_slot_index]=_wmh_phrase
        : > "${PHASE_STDOUT}"
        : > "${PHASE_STDERR}"
        set +e
        _test_cntools_compatibility_wallet_mnemonic_run \
          "${slot_args[@]}" > "${PHASE_STDOUT}" 2> "${PHASE_STDERR}"
        _test_status=$?
        set -e
        [[ "${_test_status}" == 64 &&
           "${_wmh_phrase}" == caller-reserved-sentinel &&
           -z "${slot_phrase}${slot_state}${slot_base}${slot_pay}${slot_reward}" &&
           ! -s "${PHASE_STDOUT}" && ! -s "${PHASE_STDERR}" &&
           ! -e "${WALLET_ROOT}/.cntools-wallet-mnemonic.phase.lock" &&
           ! -e "${WALLET_ROOT}/.reserved_slot_wallet.cntools-wallet-mnemonic.lock" &&
           ! -e "${WALLET_ROOT}/reserved_slot_wallet" ]]
      ) || {
        builtin printf 'reserved-slot matrix failed: phase=%s slot=%s\n' \
          "${_test_phase}" "${_test_slot_index}" >&2
        return 1
      }
    done
  done

  # Cover every private namespace shape, including locals defined only in the
  # constant helper and capture-worker programs, plus the sole non-prefixed
  # core local. Variable and function namespaces remain deliberately separate.
  for _test_target in _wmh_auth_path _wmh_capture_pid; do
    (
      local slot_state="" slot_base="" slot_pay="" slot_reward=""
      builtin printf -v "${_test_target}" '%s' caller-reserved-sentinel
      set +e
      _test_cntools_compatibility_wallet_mnemonic_run prepare \
        "${_test_target}" slot_state slot_base slot_pay slot_reward \
        >/dev/null 2>&1
      _test_status=$?
      set -e
      [[ "${_test_status}" == 64 &&
         "${!_test_target}" == caller-reserved-sentinel &&
         -z "${slot_state}${slot_base}${slot_pay}${slot_reward}" ]]
    ) || {
      builtin printf 'reserved namespace target failed: %s\n' \
        "${_test_target}" >&2
      return 1
    }
  done
  (
    local slot_state="" slot_base="" slot_pay="" slot_reward=""
    local -a _wmh_names=(caller array sentinel)
    set +e
    _test_cntools_compatibility_wallet_mnemonic_run prepare \
      _wmh_names slot_state slot_base slot_pay slot_reward >/dev/null 2>&1
    _test_status=$?
    set -e
    [[ "${_test_status}" == 64 &&
       "${_wmh_names[*]}" == 'caller array sentinel' ]]
  ) || {
    builtin printf 'reserved indexed-array target failed\n' >&2
    return 1
  }
  (
    local slot_state="" slot_base="" slot_pay="" slot_reward=""
    local -A _wmh_tools=([caller]=sentinel)
    set +e
    _test_cntools_compatibility_wallet_mnemonic_run prepare \
      _wmh_tools slot_state slot_base slot_pay slot_reward >/dev/null 2>&1
    _test_status=$?
    set -e
    [[ "${_test_status}" == 64 && "${_wmh_tools[caller]}" == sentinel ]]
  ) || {
    builtin printf 'reserved associative-array target failed\n' >&2
    return 1
  }
  (
    local slot_state="" slot_base="" slot_pay="" slot_reward=""
    local LC_ALL=C
    set +e
    _test_cntools_compatibility_wallet_mnemonic_run prepare \
      LC_ALL slot_state slot_base slot_pay slot_reward >/dev/null 2>&1
    _test_status=$?
    set -e
    [[ "${_test_status}" == 64 && "${LC_ALL}" == C ]]
  ) || {
    builtin printf 'reserved LC_ALL target failed\n' >&2
    return 1
  }

  for _test_target in readonly integer lowercase uppercase indexed \
      associative nameref; do
    (
      local slot_state="" slot_base="" slot_pay="" slot_reward=""
      local attribute_target=nameref-sentinel
      local attribute_name=""
      case "${_test_target}" in
        readonly)
          local -r readonly_slot=attribute-sentinel
          attribute_name=readonly_slot
          ;;
        integer)
          local -i integer_slot=7
          attribute_name=integer_slot
          ;;
        lowercase)
          local -l lowercase_slot=ATTRIBUTE-SENTINEL
          attribute_name=lowercase_slot
          ;;
        uppercase)
          local -u uppercase_slot=attribute-sentinel
          attribute_name=uppercase_slot
          ;;
        indexed)
          local -a indexed_slot=(attribute sentinel)
          attribute_name=indexed_slot
          ;;
        associative)
          local -A associative_slot=([attribute]=sentinel)
          attribute_name=associative_slot
          ;;
        nameref)
          local -n nameref_slot=attribute_target
          attribute_name=nameref_slot
          ;;
        *) return 64 ;;
      esac
      set +e
      _test_cntools_compatibility_wallet_mnemonic_run prepare \
        "${attribute_name}" slot_state slot_base slot_pay slot_reward \
        >/dev/null 2>&1
      _test_status=$?
      set -e
      [[ "${_test_status}" == 64 &&
         -z "${slot_state}${slot_base}${slot_pay}${slot_reward}" ]]
    ) || {
      builtin printf 'writable-scalar attribute target failed: %s\n' \
        "${_test_target}" >&2
      return 1
    }
  done

  _test_count_lines _test_vectors_after "${VECTOR_LOG}" || return 1
  _test_snapshot_open_fds _test_fds_after || return 1
  _test_snapshot_running_jobs _test_jobs_after \
    "${TEST_ROOT}/stress-jobs-after.list" || return 1
  [[ "${_test_vectors_after}" == "${_test_vectors_before}" &&
     "${_test_fds_after}" == "${_test_fds_before}" &&
     "${_test_jobs_after}" == "${_test_jobs_before}" &&
     "$-" == "${_test_options_before}" &&
     "$(builtin trap -p HUP INT TERM DEBUG)" == "${_test_traps_before}" ]] || {
    builtin printf 'reserved-slot parent-state restoration failed\n' >&2
    return 1
  }
}

_test_reserved_slot_contract ||
  fail 'reserved caller-slot or writable-scalar contract failed'
if [[ "${CNTOOLS_MNEMONIC_HELPER_FOCUS:-}" == reserved-slot ]]; then
  printf 'CNTools mnemonic helper reserved-slot focus passed\n'
  exit 0
fi
if [[ "${CNTOOLS_MNEMONIC_HELPER_FOCUS:-}" == ambient-export ]]; then
  wallet_name=ambient_export_focus_wallet
  ambient_focus_phrase='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
  ambient_focus_state=
  ambient_focus_base=
  ambient_focus_payment=
  ambient_focus_reward=
  ambient_focus_names=(
    _wmh_root _wmh_root_identity _wmh_destination
    _wmh_phase_lock _wmh_phase_lock_identity _wmh_phase_lock_token
    _wmh_phase_lock_seen_token _wmh_phase_lock_extra
    _wmh_phase_lock_snapshot _wmh_phase_lock_first_snapshot
    _wmh_phase_lock_pid _wmh_phase_lock_root_device
    _wmh_phase_lock_saved_umask _wmh_lock _wmh_lock_identity
    _wmh_stage _wmh_stage_identity _wmh_state _wmh_inventory _wmh_ack
    _wmh_cleanup_marker _wmh_saved_root _wmh_saved_root_identity
    _wmh_saved_destination _wmh_saved_destination_identity
    _wmh_saved_lock_identity _wmh_saved_stage_identity
    _wmh_publish_active_leaf
  )
  builtin export ambient_focus_phrase
  for ambient_focus_name in "${ambient_focus_names[@]}"; do
    builtin printf -v "${ambient_focus_name}" '%s' ambient-export-sentinel
    builtin export "${ambient_focus_name}"
  done
  : > "${PHASE_STDOUT}"
  : > "${PHASE_STDERR}"
  _test_cntools_compatibility_wallet_mnemonic_run prepare \
    ambient_focus_phrase ambient_focus_state ambient_focus_base \
    ambient_focus_payment ambient_focus_reward \
    > "${PHASE_STDOUT}" 2> "${PHASE_STDERR}" ||
    fail 'ambient-export focus prepare failed'
  [[ "${ambient_focus_phrase@a}" != *x* &&
     -f "${ambient_focus_state}" &&
     ! -s "${PHASE_STDOUT}" && ! -s "${PHASE_STDERR}" ]] ||
    fail 'ambient-export focus phrase/state/streams changed'
  for ambient_focus_name in "${ambient_focus_names[@]}"; do
    [[ "${!ambient_focus_name}" == ambient-export-sentinel &&
       "${!ambient_focus_name@a}" == *x* ]] ||
      fail "ambient-export caller state changed: ${ambient_focus_name}"
    builtin unset "${ambient_focus_name}"
  done
  _test_cntools_compatibility_wallet_mnemonic_run abort \
    ambient_focus_phrase ambient_focus_state ||
    fail 'ambient-export focus abort failed'
  _test_count_lines ambient_focus_vectors "${VECTOR_LOG}" ||
    fail 'ambient-export focus could not count tool vectors'
  [[ -z "${ambient_focus_phrase}${ambient_focus_state}" &&
     "${ambient_focus_phrase@a}" != *x* &&
     "${ambient_focus_vectors}" == 41 &&
     ! -e "${WALLET_ROOT}/${wallet_name}" &&
     ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" &&
     ! -e "${WALLET_ROOT}/.cntools-wallet-mnemonic.phase.lock" ]] ||
    fail 'ambient-export focus cleanup changed'
  builtin unset ambient_focus_phrase ambient_focus_state ambient_focus_base \
    ambient_focus_payment ambient_focus_reward
  ambient_focus_names=()
  printf 'CNTools mnemonic helper ambient-export focus passed\n'
  exit 0
fi
if [[ "${CNTOOLS_MNEMONIC_HELPER_FOCUS:-}" == legacy-adapter ]]; then
  getCustomDerivationPath() {
    acct_idx=7
    key_idx=9
    return 0
  }
  waitToProceed() {
    return 0
  }
  wallet_name=legacy_adapter_focus_wallet
  "${TEST_REAL_MKDIR}" -m 0700 -- "${WALLET_ROOT}/${wallet_name}"
  mnemonic='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
  words=()
  : > "${PHASE_STDOUT}"
  : > "${PHASE_STDERR}"
  set +e
  createMnemonicWallet > "${PHASE_STDOUT}" 2> "${PHASE_STDERR}"
  legacy_adapter_status=$?
  set -e
  _test_count_lines legacy_adapter_vectors "${VECTOR_LOG}" ||
    fail 'legacy-adapter focus could not count tool vectors'
  [[ "${legacy_adapter_status}" == 0 &&
     -z "${mnemonic+x}" && -z "${words+x}" &&
     "${legacy_adapter_vectors}" == 41 &&
     -d "${WALLET_ROOT}/${wallet_name}" &&
     ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" &&
     ! -e "${WALLET_ROOT}/.cntools-wallet-mnemonic.phase.lock" &&
     ! -s "${PHASE_STDOUT}" && ! -s "${PHASE_STDERR}" ]] ||
    fail 'trusted legacy-adapter state slot or cleanup changed'
  printf 'CNTools mnemonic helper legacy-adapter focus passed\n'
  exit 0
fi

_test_publish_signal_rollback() {
  local signal_case="${1:-}" expected_public="${2:-absent}"
  local wallet_name="signal_publish_${signal_case//-/_}_wallet"
  local phrase="" state="" base="" payment="" reward=""
  local saved_phrase="" saved_state="" state_snapshot=""
  local state_identity="" state_identity_after=""
  local signal_status=0 signal_seen=N stage_count=0 public_count=0
  local fds_before="" fds_after="" jobs_before="" jobs_after=""
  local options_before="$-" options_after="" traps_before="" traps_after=""
  local phase_traps_before=""
  local destination="${WALLET_ROOT}/${wallet_name}"
  local phase_lock="${WALLET_ROOT}/.cntools-wallet-mnemonic.phase.lock"
  local public_leaf="${destination}/derivation.path"

  traps_before="$(builtin trap -p HUP INT TERM)"
  builtin trap 'signal_seen=Y' TERM
  phase_traps_before="$(builtin trap -p HUP INT TERM)"
  MNEMONIC_HELPER_FAULT=
  _test_cntools_compatibility_wallet_mnemonic_run prepare \
    phrase state base payment reward || return 1
  _test_cntools_compatibility_wallet_mnemonic_run acknowledge phrase state ||
    return 1
  saved_phrase="${phrase}"
  saved_state="${state}"
  state_identity="$(file_identity_links "${state}")" || return 1
  state_snapshot="${TEST_ROOT}/${wallet_name}.state.snapshot"
  /bin/cp -- "${state}" "${state_snapshot}" || return 1
  /bin/chmod 0600 "${state_snapshot}" || return 1
  _test_snapshot_open_fds fds_before || return 1
  _test_snapshot_running_jobs jobs_before \
    "${TEST_ROOT}/stress-jobs-before.list" || return 1
  : > "${PHASE_STDOUT}"
  : > "${PHASE_STDERR}"

  MNEMONIC_HELPER_FAULT="signal-publish-${signal_case}"
  set +e
  _test_cntools_compatibility_wallet_mnemonic_run publish \
    phrase state base payment reward > "${PHASE_STDOUT}" 2> "${PHASE_STDERR}"
  signal_status=$?
  set -e
  MNEMONIC_HELPER_FAULT=

  _test_snapshot_open_fds fds_after || return 1
  _test_snapshot_running_jobs jobs_after \
    "${TEST_ROOT}/stress-jobs-after.list" || return 1
  options_after="$-"
  traps_after="$(builtin trap -p HUP INT TERM)"
  state_identity_after="$(file_identity_links "${state}")" || return 1
  stage_count="$(find "${saved_state%/state}/stage" -mindepth 1 \
    -maxdepth 1 -type f -print | wc -l | tr -d '[:space:]')"
  public_count=0
  [[ ! -d "${destination}" ]] || public_count="$(find "${destination}" \
    -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')"

  if ! [[ "${signal_status}" == 70 && "${signal_seen}" == N &&
     "${phrase}" == "${saved_phrase}" && "${state}" == "${saved_state}" &&
     -f "${state}" && ! -L "${state}" &&
     -f "${saved_state%/state}/inventory" &&
     -f "${saved_state%/state}/acknowledged" &&
     -f "${saved_state%/state}/cleanup-authority" &&
     "${stage_count}" == 24 &&
     -z "${base}${payment}${reward}" &&
     ! -e "${phase_lock}" && ! -L "${phase_lock}" &&
     ! -s "${PHASE_STDOUT}" && ! -s "${PHASE_STDERR}" &&
     "${fds_after}" == "${fds_before}" &&
     "${jobs_after}" == "${jobs_before}" &&
     "${options_after}" == "${options_before}" &&
     "${traps_after}" == "${phase_traps_before}" &&
     "${state_identity_after}" == "${state_identity}" ]]; then
    return 1
  fi

  # The state copy has a different inode by construction; byte equality is
  # the intended oracle, while the live state pathname must retain its own
  # authenticated identity throughout the phase.
  /usr/bin/cmp -s -- "${state}" "${state_snapshot}" || return 1
  case "${expected_public}" in
    absent)
      [[ "${public_count}" == 0 && ! -e "${destination}" &&
         ! -L "${destination}" ]] || return 1
      ;;
    authentic)
      [[ "${public_count}" == 1 && -f "${public_leaf}" &&
         ! -L "${public_leaf}" ]] || return 1
      ;;
    replacement)
      [[ "${public_count}" == 1 && -L "${public_leaf}" ]] || return 1
      /usr/bin/cmp -s -- "${public_leaf}" \
        "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}" || return 1
      /bin/rm -- "${public_leaf}" || return 1
      ;;
    *) return 64 ;;
  esac
  builtin trap - TERM
  [[ -z "${traps_before}" ]] || builtin eval "${traps_before}"
  _test_cntools_compatibility_wallet_mnemonic_run abort phrase state || return 1
  [[ -z "${phrase}${state}" && ! -e "${destination}" &&
     ! -L "${destination}" &&
     ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" &&
     ! -L "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" &&
     ! -e "${phase_lock}" && ! -L "${phase_lock}" ]] || return 1
  /bin/rm -f -- "${state_snapshot}"
}

if [[ "${CNTOOLS_MNEMONIC_HELPER_FOCUS:-}" == publish-signal ]]; then
  for signal_case_spec in first:absent middle:absent last:absent \
      unlink-failure:authentic race:replacement; do
    signal_case="${signal_case_spec%%:*}"
    signal_expected="${signal_case_spec#*:}"
    _test_publish_signal_rollback "${signal_case}" "${signal_expected}" ||
      fail "focused publish-signal rollback failed: ${signal_case}"
  done
  printf 'CNTools mnemonic helper publish-signal focus passed\n'
  exit 0
fi

RESOLVER_ORACLE_ROOT="${TEST_ROOT}/resolver-oracles"
RESOLVER_ORDER_FIRST="${RESOLVER_ORACLE_ROOT}/order-first"
RESOLVER_ORDER_SECOND="${RESOLVER_ORACLE_ROOT}/order-second"
RESOLVER_EMPTY_ENTRY="${RESOLVER_ORACLE_ROOT}/empty-entry"
"${TEST_REAL_MKDIR}" -m 0700 -- "${RESOLVER_ORACLE_ROOT}" \
  "${RESOLVER_ORDER_FIRST}" "${RESOLVER_ORDER_SECOND}" \
  "${RESOLVER_EMPTY_ENTRY}"
for RESOLVER_TOOL_PATH in \
    "${RESOLVER_ORDER_FIRST}/mkdir" \
    "${RESOLVER_ORDER_SECOND}/mkdir" \
    "${RESOLVER_EMPTY_ENTRY}/mkdir"; do
  RESOLVER_TOOL_LABEL="${RESOLVER_TOOL_PATH%/mkdir}"
  RESOLVER_TOOL_LABEL="${RESOLVER_TOOL_LABEL##*/}"
  sed "s/@LABEL@/${RESOLVER_TOOL_LABEL}/" > "${RESOLVER_TOOL_PATH}" <<'EOF_RESOLVER_TOOL'
#!/usr/bin/env bash
builtin printf '%s\n' '@LABEL@' > "${MNEMONIC_HELPER_RESOLVER_MARKER:?}"
builtin exit 66
EOF_RESOLVER_TOOL
  "${TEST_REAL_CHMOD}" 0700 "${RESOLVER_TOOL_PATH}"
done

MNEMONIC_HELPER_RESOLVER_MARKER="${RESOLVER_ORACLE_ROOT}/order.marker"
export MNEMONIC_HELPER_RESOLVER_MARKER
(
  wallet_name=resolver_order_wallet
  phrase=
  state=
  base=
  payment=
  reward=
  PATH="${RESOLVER_ORDER_FIRST}:${RESOLVER_ORDER_SECOND}:${PATH}"
  set +e
  _cntools_compatibility_wallet_mnemonic_run prepare \
    phrase state base payment reward >/dev/null 2>&1
  resolver_status=$?
  set -e
  [[ "${resolver_status}" == 70 && -z "${phrase}${state}" &&
     ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]]
) || fail 'PATH resolver did not bind the first ordinary executable candidate'
[[ "$(< "${MNEMONIC_HELPER_RESOLVER_MARKER}")" == order-first ]] ||
  fail 'PATH resolver changed exact candidate order'

MNEMONIC_HELPER_RESOLVER_MARKER="${RESOLVER_ORACLE_ROOT}/empty.marker"
(
  builtin cd -- "${RESOLVER_EMPTY_ENTRY}"
  wallet_name=resolver_empty_wallet
  phrase=
  state=
  base=
  payment=
  reward=
  PATH=":${PATH}"
  set +e
  _cntools_compatibility_wallet_mnemonic_run prepare \
    phrase state base payment reward >/dev/null 2>&1
  resolver_status=$?
  set -e
  [[ "${resolver_status}" == 70 && -z "${phrase}${state}" &&
     ! -e "${MNEMONIC_HELPER_RESOLVER_MARKER}" &&
     ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]]
) || fail 'empty PATH entry did not fail the absolute-path resolver rule'

_test_tool_resolver_shadow_oracle() {
  local shadow_kind="${1:-}"
  local shadow_marker="${RESOLVER_ORACLE_ROOT}/shadow-${shadow_kind}.marker"

  MNEMONIC_HELPER_RESOLVER_MARKER="${shadow_marker}"
  export MNEMONIC_HELPER_RESOLVER_MARKER
  (
    wallet_name="resolver_shadow_${shadow_kind//-/_}"
    phrase=
    state=
    base=
    payment=
    reward=
    case "${shadow_kind}" in
      mkdir-function)
        mkdir() { builtin printf intercepted > "${shadow_marker}"; }
        ;;
      mkdir-alias)
        builtin alias mkdir='builtin printf intercepted > "${MNEMONIC_HELPER_RESOLVER_MARKER}"'
        ;;
      sha256sum-function)
        sha256sum() { builtin printf intercepted > "${shadow_marker}"; }
        ;;
      cardano-address-function)
        cardano-address() { builtin printf intercepted > "${shadow_marker}"; }
        ;;
      cardano-cli-alias)
        CCLI=cardano-cli
        builtin alias cardano-cli='builtin printf intercepted > "${MNEMONIC_HELPER_RESOLVER_MARKER}"'
        ;;
      *) return 64 ;;
    esac
    set +e
    _cntools_compatibility_wallet_mnemonic_run prepare \
      phrase state base payment reward >/dev/null 2>&1
    resolver_status=$?
    set -e
    [[ "${resolver_status}" == 70 && -z "${phrase}${state}" &&
       ! -e "${shadow_marker}" &&
       ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]]
  )
}
for RESOLVER_SHADOW_KIND in mkdir-function mkdir-alias \
    sha256sum-function cardano-address-function cardano-cli-alias; do
  _test_tool_resolver_shadow_oracle "${RESOLVER_SHADOW_KIND}" ||
    fail "tool resolver ambient shadow oracle failed: ${RESOLVER_SHADOW_KIND}"
done

(
  builtin enable -n type
  wallet_name=resolver_disabled_type_wallet
  phrase=
  state=
  base=
  payment=
  reward=
  VECTOR_LOG="${RESOLVER_ORACLE_ROOT}/disabled-type.vectors"
  export VECTOR_LOG
  MNEMONIC_HELPER_SIGNAL_PID="${BASHPID}"
  export MNEMONIC_HELPER_SIGNAL_PID
  _cntools_compatibility_wallet_mnemonic_run prepare \
    phrase state base payment reward >/dev/null 2>&1
  _cntools_compatibility_wallet_mnemonic_run abort phrase state \
    >/dev/null 2>&1
  [[ -z "${phrase}${state}" &&
     ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]]
) || fail 'tool resolver still depends on the type builtin'

_test_helper_shadow_oracle() {
  local shadow_kind="${1:-}"
  local shadow_marker="${TEST_ROOT}/helper-shadow-${shadow_kind}"

  HOME="${TEST_ROOT}/helper-shadow-home" TMPDIR="${TEST_ROOT}" \
    BASH_ENV=/dev/null ENV=/dev/null \
    "${BASH}" --noprofile --norc -c '
      set -uo pipefail
      source_file=$1
      shadow_kind=$2
      shadow_marker=$3
      shadow_alias=
      shadow_status=0
      phrase=sentinel
      state=
      builtin export phrase
      builtin source "${source_file}"
      case "${shadow_kind}" in
        exec-function)
          exec() { builtin printf intercepted > "${shadow_marker}"; }
          ;;
        command-function)
          command() { builtin printf intercepted > "${shadow_marker}"; }
          ;;
        exec-disabled|command-disabled)
          builtin enable -n "${shadow_kind%-disabled}"
          ;;
        exec-alias|command-alias)
          builtin shopt -s expand_aliases
          builtin printf -v shadow_alias \
            "builtin printf intercepted > %q" "${shadow_marker}"
          builtin alias "${shadow_kind%-alias}=${shadow_alias}"
          ;;
        *) builtin exit 64 ;;
      esac
      set +e
      _cntools_compatibility_wallet_mnemonic_run abort phrase state \
        >/dev/null 2>&1
      shadow_status=$?
      set -e
      [[ "${shadow_status}" == 70 && ! -e "${shadow_marker}" &&
         "${phrase}" == sentinel && "${phrase@a}" != *x* &&
         -z "${state}" ]]
    ' bash "${MEMBER_SOURCE}" "${shadow_kind}" "${shadow_marker}"
}
for helper_shadow_kind in exec-function command-function exec-alias \
    command-alias exec-disabled command-disabled; do
  _test_helper_shadow_oracle "${helper_shadow_kind}" ||
    fail "helper ambient shadow oracle failed: ${helper_shadow_kind}"
done

# Preoccupied or tampered global phase locks are never removed or bypassed.
# Run these before the ordinary fixture so no derivation vector can be
# mistaken for a failed lock attempt.
PHASE_LOCK_PATH="${WALLET_ROOT}/.cntools-wallet-mnemonic.phase.lock"
IFS=$'\t' builtin read -r PHASE_LOCK_ROOT_DEVICE PHASE_LOCK_ROOT_INODE \
  PHASE_LOCK_ROOT_LINKS <<< "$(file_identity_links "${WALLET_ROOT}")"
[[ "${PHASE_LOCK_ROOT_DEVICE}" =~ ^[0-9]+$ &&
   "${PHASE_LOCK_ROOT_INODE}" =~ ^[0-9]+$ ]] ||
  fail 'phase-lock root identity unavailable'
_test_phase_lock_rejected() {
  local case_name="${1:-}" vectors_before=0 vectors_after=0 status=0
  wallet_name="phase_lock_${case_name}_wallet"
  phrase='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
  state=
  base=
  payment=
  reward=
  _test_count_lines vectors_before "${VECTOR_LOG}" || return 1
  set +e
  _test_cntools_compatibility_wallet_mnemonic_run prepare \
    phrase state base payment reward >/dev/null 2>&1
  status=$?
  set -e
  _test_count_lines vectors_after "${VECTOR_LOG}" || return 1
  [[ "${status}" == 70 && "${vectors_after}" == "${vectors_before}" &&
     -z "${phrase}${state}${base}${payment}${reward}" &&
     ! -e "${WALLET_ROOT}/${wallet_name}" &&
     ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]]
}

builtin printf 'wmhphase|99999999|%s|%s|0|1|1\n' \
  "${PHASE_LOCK_ROOT_DEVICE}" "${PHASE_LOCK_ROOT_INODE}" \
  > "${PHASE_LOCK_PATH}"
chmod 0600 "${PHASE_LOCK_PATH}"
PHASE_LOCK_STALE_IDENTITY="$(file_identity_links "${PHASE_LOCK_PATH}")"
_test_phase_lock_rejected stale ||
  fail 'stale phase lock did not fail closed before tool launch'
[[ -f "${PHASE_LOCK_PATH}" && ! -L "${PHASE_LOCK_PATH}" &&
   "$(file_identity_links "${PHASE_LOCK_PATH}")" == \
     "${PHASE_LOCK_STALE_IDENTITY}" ]] ||
  fail 'stale phase lock was removed or replaced'
/bin/rm -- "${PHASE_LOCK_PATH}"

builtin printf 'phase lock symlink sentinel\n' \
  > "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
chmod 0600 "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
/bin/ln -s -- "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}" \
  "${PHASE_LOCK_PATH}"
_test_phase_lock_rejected symlink ||
  fail 'symlink phase lock did not fail closed before tool launch'
[[ -L "${PHASE_LOCK_PATH}" &&
   "$(< "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}")" == \
     'phase lock symlink sentinel' ]] ||
  fail 'symlink phase-lock target was changed'
/bin/rm -- "${PHASE_LOCK_PATH}" "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"

builtin printf 'wmhphase|99999999|%s|%s|0|2|2\n' \
  "${PHASE_LOCK_ROOT_DEVICE}" "${PHASE_LOCK_ROOT_INODE}" \
  > "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
chmod 0600 "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
/bin/ln -- "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}" "${PHASE_LOCK_PATH}"
_test_phase_lock_rejected hardlink ||
  fail 'preexisting hard-link phase lock did not fail closed'
[[ "$(file_identity_links "${PHASE_LOCK_PATH}")" == *$'\t2' &&
   "$(file_identity_links "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}")" == \
     *$'\t2' ]] ||
  fail 'hard-link phase-lock evidence was removed or replaced'
/bin/rm -- "${PHASE_LOCK_PATH}" "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"

/bin/rm -f -- "${MNEMONIC_HELPER_FAULT_MARKER}" \
  "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
MNEMONIC_HELPER_FAULT=phase-lock-injected-hardlink
export MNEMONIC_HELPER_FAULT
_test_phase_lock_rejected injected_hardlink ||
  fail 'injected phase-lock hard link did not fail closed'
MNEMONIC_HELPER_FAULT=
[[ -e "${MNEMONIC_HELPER_FAULT_MARKER}" &&
   "$(file_identity_links "${PHASE_LOCK_PATH}")" == *$'\t2' &&
   "$(file_identity_links "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}")" == \
     *$'\t2' ]] ||
  fail 'injected phase-lock hard link was accepted or destroyed'
/bin/rm -- "${PHASE_LOCK_PATH}" "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}" \
  "${MNEMONIC_HELPER_FAULT_MARKER}"

# Deterministically pause a waiter after it has read a live holder token but
# before kill -0.  The holder then authenticates/unlinks its own lock, exits,
# and is reaped.  The waiter must use only its bounded grace to re-enter the
# normal authentication loop.  Replacement variants prove that retry grants
# neither removal nor cleanup authority over a new pathname.
PHASE_LOCK_DEAD_HOLDER_SOURCE="${TEST_ROOT}/phase-lock-dead-holder.sh"
cat > "${PHASE_LOCK_DEAD_HOLDER_SOURCE}" <<'EOF_PHASE_LOCK_DEAD_HOLDER'
#!/usr/bin/env bash
set -euo pipefail
lock_path=$1
ready_path=$2
root_device=$3
root_inode=$4
cleanup_holder() {
  builtin trap - TERM
  /bin/rm -- "${lock_path}"
  builtin exit 0
}
builtin trap cleanup_holder TERM
builtin umask 077
builtin printf 'wmhphase|%s|%s|%s|0|7|11\n' "${BASHPID}" \
  "${root_device}" "${root_inode}" > "${lock_path}"
builtin printf '%s\n' "${BASHPID}" > "${ready_path}"
while :; do :; done
EOF_PHASE_LOCK_DEAD_HOLDER
chmod 0600 "${PHASE_LOCK_DEAD_HOLDER_SOURCE}"

_test_phase_lock_dead_holder_debug() {
  local _test_prior_status=$?
  local _test_replacement_identity=""
  if [[ "${PHASE_LOCK_DEAD_HOLDER_STATE:-}" == armed &&
        "${BASH_COMMAND}" == \
          'builtin kill -0 "${_wmh_phase_lock_pid}" 2> /dev/null' ]]; then
    builtin trap - DEBUG
    builtin kill -TERM "${PHASE_LOCK_DEAD_HOLDER_PID}" || return 1
    builtin wait "${PHASE_LOCK_DEAD_HOLDER_PID}" || return 1
    [[ ! -e "${PHASE_LOCK_PATH}" && ! -L "${PHASE_LOCK_PATH}" ]] ||
      return 1
    case "${PHASE_LOCK_DEAD_HOLDER_REPLACEMENT}" in
      absent) ;;
      regular)
        builtin printf '%s\n' unsafe-replacement-sentinel \
          > "${PHASE_LOCK_PATH}"
        chmod 0600 "${PHASE_LOCK_PATH}"
        ;;
      symlink)
        builtin printf '%s\n' unsafe-symlink-sentinel \
          > "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
        chmod 0600 "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
        /bin/ln -s -- "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}" \
          "${PHASE_LOCK_PATH}"
        ;;
      hardlink)
        builtin printf 'wmhphase|99999999|%s|%s|0|13|17\n' \
          "${PHASE_LOCK_ROOT_DEVICE}" "${PHASE_LOCK_ROOT_INODE}" \
          > "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
        chmod 0600 "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
        /bin/ln -- "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}" \
          "${PHASE_LOCK_PATH}"
        ;;
      *) return 64 ;;
    esac
    if [[ "${PHASE_LOCK_DEAD_HOLDER_REPLACEMENT}" != absent ]]; then
      _test_replacement_identity="$(file_identity_links \
        "${PHASE_LOCK_PATH}")" || return 1
      builtin printf -v PHASE_LOCK_DEAD_HOLDER_REPLACEMENT_IDENTITY \
        '%s' "${_test_replacement_identity}"
    fi
    PHASE_LOCK_DEAD_HOLDER_STATE=reaped
    builtin trap _test_phase_lock_dead_holder_debug DEBUG
  fi
  return "${_test_prior_status}"
}

PHASE_LOCK_DEAD_HOLDER_DEBUG_BEFORE="$(builtin trap -p DEBUG)"
PHASE_LOCK_DEAD_HOLDER_FUNCTRACE_WAS_ON=N
[[ "$-" != *T* ]] || PHASE_LOCK_DEAD_HOLDER_FUNCTRACE_WAS_ON=Y
for PHASE_LOCK_DEAD_HOLDER_REPLACEMENT in absent regular symlink hardlink; do
  PHASE_LOCK_DEAD_HOLDER_READY="${TEST_ROOT}/phase-lock-dead-holder.ready"
  PHASE_LOCK_DEAD_HOLDER_STDOUT="${TEST_ROOT}/phase-lock-dead-holder.stdout"
  PHASE_LOCK_DEAD_HOLDER_STDERR="${TEST_ROOT}/phase-lock-dead-holder.stderr"
  /bin/rm -f -- "${PHASE_LOCK_DEAD_HOLDER_READY}" \
    "${PHASE_LOCK_DEAD_HOLDER_STDOUT}" \
    "${PHASE_LOCK_DEAD_HOLDER_STDERR}" \
    "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
  "${BASH}" --noprofile --norc "${PHASE_LOCK_DEAD_HOLDER_SOURCE}" \
    "${PHASE_LOCK_PATH}" "${PHASE_LOCK_DEAD_HOLDER_READY}" \
    "${PHASE_LOCK_ROOT_DEVICE}" "${PHASE_LOCK_ROOT_INODE}" \
    > "${PHASE_LOCK_DEAD_HOLDER_STDOUT}" \
    2> "${PHASE_LOCK_DEAD_HOLDER_STDERR}" &
  PHASE_LOCK_DEAD_HOLDER_PID=$!
  PHASE_LOCK_DEAD_HOLDER_READY_PID=""
  for ((PHASE_LOCK_DEAD_HOLDER_INDEX=0;
       PHASE_LOCK_DEAD_HOLDER_INDEX<1000000;
       PHASE_LOCK_DEAD_HOLDER_INDEX++)); do
    [[ ! -s "${PHASE_LOCK_DEAD_HOLDER_READY}" ]] || break
    :
  done
  [[ -s "${PHASE_LOCK_DEAD_HOLDER_READY}" ]] &&
    IFS= builtin read -r PHASE_LOCK_DEAD_HOLDER_READY_PID \
      < "${PHASE_LOCK_DEAD_HOLDER_READY}"
  [[ "${PHASE_LOCK_DEAD_HOLDER_READY_PID}" == \
       "${PHASE_LOCK_DEAD_HOLDER_PID}" &&
     -f "${PHASE_LOCK_PATH}" && ! -L "${PHASE_LOCK_PATH}" ]] ||
    fail 'dead-holder oracle did not establish an authenticated live lock'

  wallet_name="phase_lock_dead_holder_${PHASE_LOCK_DEAD_HOLDER_REPLACEMENT}_wallet"
  phrase='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
  state=
  base=
  payment=
  reward=
  PHASE_LOCK_DEAD_HOLDER_STATE=armed
  PHASE_LOCK_DEAD_HOLDER_REPLACEMENT_IDENTITY=""
  : > "${PHASE_STDOUT}"
  : > "${PHASE_STDERR}"
  builtin set -T
  builtin trap _test_phase_lock_dead_holder_debug DEBUG
  PHASE_LOCK_DEAD_HOLDER_STATUS=0
  set +e
  _test_cntools_compatibility_wallet_mnemonic_run prepare \
    phrase state base payment reward \
    > "${PHASE_STDOUT}" 2> "${PHASE_STDERR}"
  PHASE_LOCK_DEAD_HOLDER_STATUS=$?
  set -e
  builtin trap - DEBUG
  [[ "${PHASE_LOCK_DEAD_HOLDER_FUNCTRACE_WAS_ON}" == Y ]] ||
    builtin set +T
  [[ -z "${PHASE_LOCK_DEAD_HOLDER_DEBUG_BEFORE}" ]] ||
    builtin eval "${PHASE_LOCK_DEAD_HOLDER_DEBUG_BEFORE}"

  [[ "${PHASE_LOCK_DEAD_HOLDER_STATE}" == reaped &&
     ! -s "${PHASE_LOCK_DEAD_HOLDER_STDOUT}" &&
     ! -s "${PHASE_LOCK_DEAD_HOLDER_STDERR}" &&
     ! -s "${PHASE_STDOUT}" && ! -s "${PHASE_STDERR}" ]] ||
    fail "dead-holder hook/streams changed: ${PHASE_LOCK_DEAD_HOLDER_REPLACEMENT}"
  if [[ "${PHASE_LOCK_DEAD_HOLDER_REPLACEMENT}" == absent ]]; then
    [[ "${PHASE_LOCK_DEAD_HOLDER_STATUS}" == 0 &&
       -n "${phrase}" && -n "${state}" && -f "${state}" &&
       -z "${base}${payment}${reward}" &&
       ! -e "${PHASE_LOCK_PATH}" && ! -L "${PHASE_LOCK_PATH}" ]] ||
      fail 'unlinked/reaped phase-lock holder was not retried safely'
    _test_cntools_compatibility_wallet_mnemonic_run abort phrase state \
      > "${PHASE_STDOUT}" 2> "${PHASE_STDERR}" ||
      fail 'dead-holder retry cleanup failed'
    [[ -z "${phrase}${state}${base}${payment}${reward}" ]] ||
      fail 'dead-holder retry retained caller state'
  else
    [[ "${PHASE_LOCK_DEAD_HOLDER_STATUS}" == 70 &&
       -z "${phrase}${state}${base}${payment}${reward}" &&
       "$(file_identity_links "${PHASE_LOCK_PATH}")" == \
         "${PHASE_LOCK_DEAD_HOLDER_REPLACEMENT_IDENTITY}" &&
       ! -e "${WALLET_ROOT}/${wallet_name}" &&
       ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
      fail "dead-holder replacement was not preserved: ${PHASE_LOCK_DEAD_HOLDER_REPLACEMENT}"
    /bin/rm -- "${PHASE_LOCK_PATH}"
    [[ "${PHASE_LOCK_DEAD_HOLDER_REPLACEMENT}" == regular ]] ||
      /bin/rm -- "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
  fi
done
builtin unset -f _test_phase_lock_dead_holder_debug
/bin/rm -f -- "${PHASE_LOCK_DEAD_HOLDER_READY}" \
  "${PHASE_LOCK_DEAD_HOLDER_STDOUT}" \
  "${PHASE_LOCK_DEAD_HOLDER_STDERR}"

if [[ "${CNTOOLS_MNEMONIC_HELPER_FOCUS:-}" == dead-holder ]]; then
  printf 'CNTools mnemonic helper dead-holder focus passed\n'
  exit 0
fi

# Preserve the dead-holder probe's complete tool evidence independently, then
# give the existing handoff probe its original authenticated empty baseline.
# The focused exit above intentionally retains the original shared log.
PHASE_LOCK_DEAD_HOLDER_VECTOR_SNAPSHOT="${TEST_ROOT}/phase-lock-dead-holder.vectors"
/bin/cp -- "${VECTOR_LOG}" "${PHASE_LOCK_DEAD_HOLDER_VECTOR_SNAPSHOT}" ||
  fail 'could not preserve dead-holder vectors'
/bin/chmod 0600 "${PHASE_LOCK_DEAD_HOLDER_VECTOR_SNAPSHOT}" ||
  fail 'could not protect dead-holder vectors'
_test_count_lines PHASE_LOCK_DEAD_HOLDER_VECTOR_COUNT \
  "${PHASE_LOCK_DEAD_HOLDER_VECTOR_SNAPSHOT}" ||
  fail 'could not count dead-holder vectors'
[[ "${PHASE_LOCK_DEAD_HOLDER_VECTOR_COUNT}" == 41 ]] ||
  fail 'dead-holder vector count changed'
: > "${VECTOR_LOG}"
/bin/chmod 0600 "${VECTOR_LOG}"

# Exercise the earlier structural TOCTOU independently: the outer existence
# test observes a valid holder, then the holder unlinks/exits/is reaped before
# the inner -f/-L/-O guard runs.  A vanished lock must retry; persistent
# replacement evidence must remain untouched and fail within the same grace.
_test_phase_lock_structural_debug() {
  local _test_prior_status=$?
  local _test_replacement_identity=""
  if [[ "${PHASE_LOCK_STRUCTURAL_STATE:-}" == armed &&
        "${BASH_COMMAND}" == *'! -f "${_wmh_phase_lock}"'* &&
        "${BASH_COMMAND}" == *'! -O "${_wmh_phase_lock}"'* ]]; then
    builtin trap - DEBUG
    builtin kill -TERM "${PHASE_LOCK_STRUCTURAL_PID}" || return 1
    builtin wait "${PHASE_LOCK_STRUCTURAL_PID}" || return 1
    [[ ! -e "${PHASE_LOCK_PATH}" && ! -L "${PHASE_LOCK_PATH}" ]] ||
      return 1
    case "${PHASE_LOCK_STRUCTURAL_REPLACEMENT}" in
      absent) ;;
      regular)
        builtin printf '%s\n' structural-regular-sentinel \
          > "${PHASE_LOCK_PATH}"
        chmod 0600 "${PHASE_LOCK_PATH}"
        ;;
      symlink)
        builtin printf '%s\n' structural-symlink-sentinel \
          > "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
        chmod 0600 "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
        /bin/ln -s -- "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}" \
          "${PHASE_LOCK_PATH}"
        ;;
      hardlink)
        builtin printf 'wmhphase|99999999|%s|%s|0|19|23\n' \
          "${PHASE_LOCK_ROOT_DEVICE}" "${PHASE_LOCK_ROOT_INODE}" \
          > "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
        chmod 0600 "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
        /bin/ln -- "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}" \
          "${PHASE_LOCK_PATH}"
        ;;
      *) return 64 ;;
    esac
    if [[ "${PHASE_LOCK_STRUCTURAL_REPLACEMENT}" != absent ]]; then
      _test_replacement_identity="$(file_identity_links \
        "${PHASE_LOCK_PATH}")" || return 1
      builtin printf -v PHASE_LOCK_STRUCTURAL_REPLACEMENT_IDENTITY \
        '%s' "${_test_replacement_identity}"
    fi
    PHASE_LOCK_STRUCTURAL_STATE=reaped
    builtin trap _test_phase_lock_structural_debug DEBUG
  fi
  return "${_test_prior_status}"
}

_test_snapshot_open_fds PHASE_LOCK_STRUCTURAL_FDS_BEFORE ||
  fail 'could not snapshot descriptors before structural handoff'
_test_snapshot_running_jobs PHASE_LOCK_STRUCTURAL_JOBS_BEFORE \
  "${TEST_ROOT}/stress-jobs-before.list" ||
  fail 'could not snapshot jobs before structural handoff'
PHASE_LOCK_STRUCTURAL_OPTIONS_BEFORE="$-"
PHASE_LOCK_STRUCTURAL_DEBUG_BEFORE="$(builtin trap -p DEBUG)"
PHASE_LOCK_STRUCTURAL_FUNCTRACE_WAS_ON=N
[[ "$-" != *T* ]] || PHASE_LOCK_STRUCTURAL_FUNCTRACE_WAS_ON=Y
for PHASE_LOCK_STRUCTURAL_REPLACEMENT in absent regular symlink hardlink; do
  PHASE_LOCK_STRUCTURAL_READY="${TEST_ROOT}/phase-lock-structural.ready"
  PHASE_LOCK_STRUCTURAL_STDOUT="${TEST_ROOT}/phase-lock-structural.stdout"
  PHASE_LOCK_STRUCTURAL_STDERR="${TEST_ROOT}/phase-lock-structural.stderr"
  /bin/rm -f -- "${PHASE_LOCK_STRUCTURAL_READY}" \
    "${PHASE_LOCK_STRUCTURAL_STDOUT}" \
    "${PHASE_LOCK_STRUCTURAL_STDERR}" \
    "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
  "${BASH}" --noprofile --norc "${PHASE_LOCK_DEAD_HOLDER_SOURCE}" \
    "${PHASE_LOCK_PATH}" "${PHASE_LOCK_STRUCTURAL_READY}" \
    "${PHASE_LOCK_ROOT_DEVICE}" "${PHASE_LOCK_ROOT_INODE}" \
    > "${PHASE_LOCK_STRUCTURAL_STDOUT}" \
    2> "${PHASE_LOCK_STRUCTURAL_STDERR}" &
  PHASE_LOCK_STRUCTURAL_PID=$!
  PHASE_LOCK_STRUCTURAL_READY_PID=""
  for ((PHASE_LOCK_STRUCTURAL_INDEX=0;
       PHASE_LOCK_STRUCTURAL_INDEX<1000000;
       PHASE_LOCK_STRUCTURAL_INDEX++)); do
    [[ ! -s "${PHASE_LOCK_STRUCTURAL_READY}" ]] || break
    :
  done
  [[ -s "${PHASE_LOCK_STRUCTURAL_READY}" ]] &&
    IFS= builtin read -r PHASE_LOCK_STRUCTURAL_READY_PID \
      < "${PHASE_LOCK_STRUCTURAL_READY}"
  [[ "${PHASE_LOCK_STRUCTURAL_READY_PID}" == \
       "${PHASE_LOCK_STRUCTURAL_PID}" &&
     -f "${PHASE_LOCK_PATH}" && ! -L "${PHASE_LOCK_PATH}" ]] ||
    fail 'structural oracle did not establish an authenticated live lock'

  wallet_name="phase_lock_structural_${PHASE_LOCK_STRUCTURAL_REPLACEMENT}_wallet"
  phrase='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
  state=
  base=
  payment=
  reward=
  PHASE_LOCK_STRUCTURAL_STATE=armed
  PHASE_LOCK_STRUCTURAL_REPLACEMENT_IDENTITY=""
  : > "${PHASE_STDOUT}"
  : > "${PHASE_STDERR}"
  builtin set -T
  builtin trap _test_phase_lock_structural_debug DEBUG
  PHASE_LOCK_STRUCTURAL_STATUS=0
  set +e
  _test_cntools_compatibility_wallet_mnemonic_run prepare \
    phrase state base payment reward \
    > "${PHASE_STDOUT}" 2> "${PHASE_STDERR}"
  PHASE_LOCK_STRUCTURAL_STATUS=$?
  set -e
  builtin trap - DEBUG
  [[ "${PHASE_LOCK_STRUCTURAL_FUNCTRACE_WAS_ON}" == Y ]] ||
    builtin set +T
  [[ -z "${PHASE_LOCK_STRUCTURAL_DEBUG_BEFORE}" ]] ||
    builtin eval "${PHASE_LOCK_STRUCTURAL_DEBUG_BEFORE}"

  [[ "${PHASE_LOCK_STRUCTURAL_STATE}" == reaped &&
     ! -s "${PHASE_LOCK_STRUCTURAL_STDOUT}" &&
     ! -s "${PHASE_LOCK_STRUCTURAL_STDERR}" &&
     ! -s "${PHASE_STDOUT}" && ! -s "${PHASE_STDERR}" ]] ||
    fail "structural hook/streams changed: ${PHASE_LOCK_STRUCTURAL_REPLACEMENT}"
  if [[ "${PHASE_LOCK_STRUCTURAL_REPLACEMENT}" == absent ]]; then
    [[ "${PHASE_LOCK_STRUCTURAL_STATUS}" == 0 &&
       -n "${phrase}" && -n "${state}" && -f "${state}" &&
       -z "${base}${payment}${reward}" &&
       ! -e "${PHASE_LOCK_PATH}" && ! -L "${PHASE_LOCK_PATH}" ]] ||
      fail 'vanished structural phase lock was not retried safely'
    _test_cntools_compatibility_wallet_mnemonic_run abort phrase state \
      > "${PHASE_STDOUT}" 2> "${PHASE_STDERR}" ||
      fail 'structural handoff cleanup failed'
    [[ -z "${phrase}${state}${base}${payment}${reward}" ]] ||
      fail 'structural handoff retained caller state'
  else
    [[ "${PHASE_LOCK_STRUCTURAL_STATUS}" == 70 &&
       -z "${phrase}${state}${base}${payment}${reward}" &&
       "$(file_identity_links "${PHASE_LOCK_PATH}")" == \
         "${PHASE_LOCK_STRUCTURAL_REPLACEMENT_IDENTITY}" &&
       ! -e "${WALLET_ROOT}/${wallet_name}" &&
       ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
      fail "structural replacement was not preserved: ${PHASE_LOCK_STRUCTURAL_REPLACEMENT}"
    /bin/rm -- "${PHASE_LOCK_PATH}"
    [[ "${PHASE_LOCK_STRUCTURAL_REPLACEMENT}" == regular ]] ||
      /bin/rm -- "${MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE}"
  fi
done
builtin unset -f _test_phase_lock_structural_debug
/bin/rm -f -- "${PHASE_LOCK_STRUCTURAL_READY}" \
  "${PHASE_LOCK_STRUCTURAL_STDOUT}" \
  "${PHASE_LOCK_STRUCTURAL_STDERR}"
_test_snapshot_open_fds PHASE_LOCK_STRUCTURAL_FDS_AFTER ||
  fail 'could not snapshot descriptors after structural handoff'
_test_snapshot_running_jobs PHASE_LOCK_STRUCTURAL_JOBS_AFTER \
  "${TEST_ROOT}/stress-jobs-after.list" ||
  fail 'could not snapshot jobs after structural handoff'
[[ "${PHASE_LOCK_STRUCTURAL_FDS_AFTER}" == \
     "${PHASE_LOCK_STRUCTURAL_FDS_BEFORE}" &&
   "${PHASE_LOCK_STRUCTURAL_JOBS_AFTER}" == \
     "${PHASE_LOCK_STRUCTURAL_JOBS_BEFORE}" &&
   "$-" == "${PHASE_LOCK_STRUCTURAL_OPTIONS_BEFORE}" &&
   "$(builtin trap -p DEBUG)" == "${PHASE_LOCK_STRUCTURAL_DEBUG_BEFORE}" ]] ||
  fail 'structural handoff changed descriptors, jobs, options, or traps'

# A non-privileged test cannot portably create a foreign-owned inode inside
# its private wallet root.  Freeze the exact owner predicate against a known
# foreign-owned path (or create one when running as root) and prove that the
# read-only identity is preserved; full-path replacement cases above exercise
# the same bounded structural branch without requiring elevated privileges.
PHASE_LOCK_WRONG_OWNER_PATH=/
PHASE_LOCK_WRONG_OWNER_CREATED=N
if (( EUID == 0 )); then
  PHASE_LOCK_WRONG_OWNER_PATH="${TEST_ROOT}/phase-lock.wrong-owner"
  builtin printf '%s\n' wrong-owner-sentinel \
    > "${PHASE_LOCK_WRONG_OWNER_PATH}"
  chmod 0600 "${PHASE_LOCK_WRONG_OWNER_PATH}"
  chown 1 "${PHASE_LOCK_WRONG_OWNER_PATH}"
  PHASE_LOCK_WRONG_OWNER_CREATED=Y
fi
PHASE_LOCK_WRONG_OWNER_IDENTITY="$(file_identity_links \
  "${PHASE_LOCK_WRONG_OWNER_PATH}")"
[[ -e "${PHASE_LOCK_WRONG_OWNER_PATH}" &&
   ! -O "${PHASE_LOCK_WRONG_OWNER_PATH}" &&
   "$(file_identity_links "${PHASE_LOCK_WRONG_OWNER_PATH}")" == \
     "${PHASE_LOCK_WRONG_OWNER_IDENTITY}" ]] ||
  fail 'wrong-owner structural predicate or identity preservation changed'
[[ "${PHASE_LOCK_WRONG_OWNER_CREATED}" == N ]] ||
  /bin/rm -- "${PHASE_LOCK_WRONG_OWNER_PATH}"

if [[ "${CNTOOLS_MNEMONIC_HELPER_FOCUS:-}" == structural-handoff ]]; then
  printf 'CNTools mnemonic helper structural-handoff focus passed\n'
  exit 0
fi

PHASE_LOCK_STRUCTURAL_VECTOR_SNAPSHOT="${TEST_ROOT}/phase-lock-structural.vectors"
/bin/cp -- "${VECTOR_LOG}" "${PHASE_LOCK_STRUCTURAL_VECTOR_SNAPSHOT}" ||
  fail 'could not preserve structural-handoff vectors'
/bin/chmod 0600 "${PHASE_LOCK_STRUCTURAL_VECTOR_SNAPSHOT}" ||
  fail 'could not protect structural-handoff vectors'
_test_count_lines PHASE_LOCK_STRUCTURAL_VECTOR_COUNT \
  "${PHASE_LOCK_STRUCTURAL_VECTOR_SNAPSHOT}" ||
  fail 'could not count structural-handoff vectors'
[[ "${PHASE_LOCK_STRUCTURAL_VECTOR_COUNT}" == 41 ]] ||
  fail 'structural-handoff vector count changed'
: > "${VECTOR_LOG}"
/bin/chmod 0600 "${VECTOR_LOG}"

# Deterministically model the narrow successor handoff: after the waiter sees
# no path, a successor wins its noclobber create; before the failed creator can
# recheck the pathname, that successor releases. The failed creator must retry
# inside the existing bound, then acquire normally without weakening any lock
# authentication or leaking caller shell state.
_test_phase_lock_handoff_debug() {
  local prior_status=$?
  case "${PHASE_LOCK_HANDOFF_STATE:-}" in
    armed)
      if [[ "${BASH_COMMAND}" == *'_wmh_phase_lock_token'* &&
            "${BASH_COMMAND}" == *'> "${_wmh_phase_lock}"'* ]]; then
        builtin set +C
        builtin printf '%s\n' successor-handoff > "${PHASE_LOCK_PATH}"
        builtin set -C
        PHASE_LOCK_HANDOFF_STATE=created
        PHASE_LOCK_HANDOFF_CREATE_COUNT=$((PHASE_LOCK_HANDOFF_CREATE_COUNT + 1))
      fi
      ;;
    created)
      # This is the DEBUG boundary before the failed redirection's status is
      # recorded. Return its incoming status after removing only the synthetic
      # successor path, so the production assignment still receives failure.
      builtin trap - DEBUG
      /bin/rm -- "${PHASE_LOCK_PATH}"
      PHASE_LOCK_HANDOFF_STATE=released
      PHASE_LOCK_HANDOFF_RELEASE_COUNT=$((PHASE_LOCK_HANDOFF_RELEASE_COUNT + 1))
      builtin trap _test_phase_lock_handoff_debug DEBUG
      ;;
  esac
  return "${prior_status}"
}
_test_snapshot_open_fds phase_lock_handoff_fds_before ||
  fail 'could not snapshot descriptors before phase-lock handoff'
_test_snapshot_running_jobs phase_lock_handoff_jobs_before \
  "${TEST_ROOT}/stress-jobs-before.list" ||
  fail 'could not snapshot jobs before phase-lock handoff'
phase_lock_handoff_options_before="$-"
phase_lock_handoff_debug_before="$(builtin trap -p DEBUG)"
PHASE_LOCK_HANDOFF_STATE=armed
PHASE_LOCK_HANDOFF_CREATE_COUNT=0
PHASE_LOCK_HANDOFF_RELEASE_COUNT=0
wallet_name=phase_lock_handoff_wallet
phrase='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
state=
base=
payment=
reward=
: > "${PHASE_STDOUT}"
: > "${PHASE_STDERR}"
phase_lock_handoff_functrace_was_on=N
[[ "$-" != *T* ]] || phase_lock_handoff_functrace_was_on=Y
builtin set -T
builtin trap _test_phase_lock_handoff_debug DEBUG
phase_lock_handoff_status=0
set +e
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward > "${PHASE_STDOUT}" 2> "${PHASE_STDERR}"
phase_lock_handoff_status=$?
set -e
builtin trap - DEBUG
[[ "${phase_lock_handoff_functrace_was_on}" == Y ]] || builtin set +T
[[ -z "${phase_lock_handoff_debug_before}" ]] ||
  builtin eval "${phase_lock_handoff_debug_before}"
[[ "${phase_lock_handoff_status}" == 0 &&
   "${PHASE_LOCK_HANDOFF_STATE}" == released &&
   "${PHASE_LOCK_HANDOFF_CREATE_COUNT}" == 1 &&
   "${PHASE_LOCK_HANDOFF_RELEASE_COUNT}" == 1 &&
   -n "${phrase}" && -n "${state}" && -f "${state}" &&
   -z "${base}${payment}${reward}" &&
   ! -e "${PHASE_LOCK_PATH}" && ! -L "${PHASE_LOCK_PATH}" &&
   ! -s "${PHASE_STDOUT}" && ! -s "${PHASE_STDERR}" ]] ||
  fail 'phase-lock successor handoff race was not retried safely'
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state \
  > "${PHASE_STDOUT}" 2> "${PHASE_STDERR}" ||
  fail 'phase-lock handoff cleanup failed'
_test_snapshot_open_fds phase_lock_handoff_fds_after ||
  fail 'could not snapshot descriptors after phase-lock handoff'
_test_snapshot_running_jobs phase_lock_handoff_jobs_after \
  "${TEST_ROOT}/stress-jobs-after.list" ||
  fail 'could not snapshot jobs after phase-lock handoff'
[[ -z "${phrase}${state}${base}${payment}${reward}" &&
   ! -e "${WALLET_ROOT}/${wallet_name}" &&
   ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" &&
   ! -e "${PHASE_LOCK_PATH}" && ! -L "${PHASE_LOCK_PATH}" &&
   ! -s "${PHASE_STDOUT}" && ! -s "${PHASE_STDERR}" &&
   "${phase_lock_handoff_fds_after}" == "${phase_lock_handoff_fds_before}" &&
   "${phase_lock_handoff_jobs_after}" == "${phase_lock_handoff_jobs_before}" &&
   "$-" == "${phase_lock_handoff_options_before}" &&
   "$(builtin trap -p DEBUG)" == "${phase_lock_handoff_debug_before}" ]] ||
  fail 'phase-lock handoff changed cleanup, descriptors, jobs, options, or traps'
builtin unset -f _test_phase_lock_handoff_debug

if [[ "${CNTOOLS_MNEMONIC_HELPER_FOCUS:-}" == phase-lock-handoff ]]; then
  printf 'CNTools mnemonic helper phase-lock handoff focus passed\n'
  exit 0
fi

# Preserve the handoff probe's complete tool evidence independently, then
# start the fixture's frozen vector baseline from an authenticated empty log.
# The focused exit above intentionally retains the original shared log.
PHASE_LOCK_HANDOFF_VECTOR_SNAPSHOT="${TEST_ROOT}/phase-lock-handoff.vectors"
/bin/cp -- "${VECTOR_LOG}" "${PHASE_LOCK_HANDOFF_VECTOR_SNAPSHOT}" ||
  fail 'could not preserve phase-lock handoff vectors'
/bin/chmod 0600 "${PHASE_LOCK_HANDOFF_VECTOR_SNAPSHOT}" ||
  fail 'could not protect phase-lock handoff vectors'
_test_count_lines phase_lock_handoff_vector_count \
  "${PHASE_LOCK_HANDOFF_VECTOR_SNAPSHOT}" ||
  fail 'could not count phase-lock handoff vectors'
[[ "${phase_lock_handoff_vector_count}" == 41 ]] ||
  fail 'phase-lock handoff vector count changed'
: > "${VECTOR_LOG}"
/bin/chmod 0600 "${VECTOR_LOG}"

if [[ "${CNTOOLS_MNEMONIC_HELPER_FOCUS:-}" != fixture-ccli ]]; then
  builtin printf 'wmhphase|%s|%s|%s|%s|3|3\n' "${BASHPID}" \
    "${PHASE_LOCK_ROOT_DEVICE}" "${PHASE_LOCK_ROOT_INODE}" "${SECONDS}" \
    > "${PHASE_LOCK_PATH}"
  chmod 0600 "${PHASE_LOCK_PATH}"
  phase_lock_traps_before="$(builtin trap -p HUP INT TERM)"
  phase_lock_live_started=${SECONDS}
  _test_phase_lock_rejected live ||
    fail 'live phase-lock waiter did not fail closed at its bound'
  phase_lock_live_elapsed=$((SECONDS - phase_lock_live_started))
  [[ -f "${PHASE_LOCK_PATH}" && ! -L "${PHASE_LOCK_PATH}" &&
     "$(builtin trap -p HUP INT TERM)" == "${phase_lock_traps_before}" &&
     "${phase_lock_live_elapsed}" -ge 30 &&
     "${phase_lock_live_elapsed}" -le 40 ]] ||
    fail 'live phase lock, timeout bound, or caller traps changed while waiting'
  /bin/rm -- "${PHASE_LOCK_PATH}"
fi
builtin unset -f _test_phase_lock_rejected
wallet_name=fixture_wallet
phrase=
state=
trap_before="$(trap -p HUP INT TERM)"
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward > "${PHASE_STDOUT}" 2> "${PHASE_STDERR}" ||
  fail 'prepare phase failed'
[[ "$(trap -p HUP INT TERM)" == "${trap_before}" ]] ||
  fail 'prepare did not restore caller traps'
[[ -n "${phrase}" && -n "${state}" && -z "${base}${payment}${reward}" ]] ||
  fail 'prepare output-variable contract changed'
[[ ! -e "${WALLET_ROOT}/${wallet_name}" &&
   -f "${state}" && "$(file_mode "${state}")" == 600 ]] ||
  fail 'prepare mutated target or exposed unsafe state'
[[ ! -s "${PHASE_STDOUT}" && ! -s "${PHASE_STDERR}" ]] ||
  fail 'prepare wrote unexpected streams'
grep -Fq -- "${phrase}" "${VECTOR_LOG}" &&
  fail 'mnemonic leaked to tool argv log'
grep -Eq 'root_xsk_|child_xsk_' "${VECTOR_LOG}" &&
  fail 'derived secret leaked to tool argv log'
find "${WALLET_ROOT}" -print | grep -Eq 'root_xsk_|child_xsk_' &&
  fail 'derived secret leaked to a filename'

_test_cntools_compatibility_wallet_mnemonic_run acknowledge phrase state ||
  fail 'acknowledge phase failed'
_test_cntools_compatibility_wallet_mnemonic_run publish \
  phrase state base payment reward ||
  fail 'publish phase failed'
[[ -z "${phrase}${state}" && "${base}" == addr_test1* &&
   "${payment}" == addr_test1* && "${reward}" == stake_test1* ]] ||
  fail 'publish output/secret clearing contract changed'
[[ "${base}" == addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq &&
   "${payment}" == addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq &&
   "${reward}" == stake_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq ]] ||
  fail 'published address golden vectors changed'
[[ -d "${WALLET_ROOT}/${wallet_name}" &&
   ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
  fail 'publish destination/cleanup contract changed'
leaf_count="$(find "${WALLET_ROOT}/${wallet_name}" -mindepth 1 -maxdepth 1 \
  -type f | wc -l | tr -d '[:space:]')"
[[ "${leaf_count}" == 24 ]] || fail 'published wallet inventory changed'
PUBLISHED_FILE_LIST="${TEST_ROOT}/published-files.list"
find "${WALLET_ROOT}/${wallet_name}" -mindepth 1 -maxdepth 1 \
  -type f -print0 > "${PUBLISHED_FILE_LIST}"
chmod 0600 "${PUBLISHED_FILE_LIST}"
while IFS= read -r -d '' published_file; do
  [[ "$(file_mode "${published_file}")" == 600 ]] ||
    fail 'published wallet file mode changed'
done < "${PUBLISHED_FILE_LIST}"
rm -f -- "${PUBLISHED_FILE_LIST}"

# CCLI must consume only authenticated, inherited read descriptors. Key
# conversion and every pathname output were deliberately removed because
# writable /dev/fd reopens are unavailable on macOS. These seven exact vectors
# freeze the long-established file-input interface and stdout-only output.
sed -E -n \
  '/^cardano-cli/ { s#/dev/fd/[0-9]+#<fd>#g; p; }' \
  "${VECTOR_LOG}" > "${ACTUAL_CCLI_VECTORS}"
{
  printf '%s\n' $'cardano-cli\taddress\tbuild\t--payment-verification-key-file\t<fd>\t--stake-verification-key-file\t<fd>\t--testnet-magic\t42'
  printf '%s\n' $'cardano-cli\taddress\tbuild\t--payment-verification-key-file\t<fd>\t--testnet-magic\t42'
  printf '%s\n' $'cardano-cli\tstake-address\tbuild\t--stake-verification-key-file\t<fd>\t--testnet-magic\t42'
  printf '%s\n' $'cardano-cli\taddress\tkey-hash\t--payment-verification-key-file\t<fd>'
  printf '%s\n' $'cardano-cli\tstake-address\tkey-hash\t--stake-verification-key-file\t<fd>'
  printf '%s\n' $'cardano-cli\taddress\tkey-hash\t--payment-verification-key-file\t<fd>'
  printf '%s\n' $'cardano-cli\tstake-address\tkey-hash\t--stake-verification-key-file\t<fd>'
} > "${EXPECTED_CCLI_VECTORS}"
cmp -s -- "${ACTUAL_CCLI_VECTORS}" "${EXPECTED_CCLI_VECTORS}" || {
  diff -u -- "${EXPECTED_CCLI_VECTORS}" "${ACTUAL_CCLI_VECTORS}" >&2 || true
  fail 'descriptor-only CCLI invocation vectors changed'
}

if [[ "${CNTOOLS_MNEMONIC_HELPER_FOCUS:-}" == fixture-ccli ]]; then
  printf 'CNTools mnemonic helper fixture CCLI focus passed\n'
  exit 0
fi

# The envelopes constructed without cardano-cli are frozen byte for byte to
# the cardano-api TextEnvelope shape: exact field order, indentation, CBOR
# length prefixes, key bytes, type, description, and trailing newline.
GOLDEN_SIGNING_CBOR='5880aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
GOLDEN_VKEY_CBOR='5820bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
assert_cardano_cli_nonextended_vector() {
  local extended_cbor="$1" expected_cbor="$2"
  local actual_cbor=""
  [[ "${extended_cbor}" =~ ^5840[0-9a-f]{128}$ &&
     "${expected_cbor}" =~ ^5820[0-9a-f]{64}$ ]] ||
    fail 'invalid frozen cardano-cli non-extended vector'
  actual_cbor="5820${extended_cbor:4:64}"
  [[ "${actual_cbor}" == "${expected_cbor}" ]] ||
    fail 'cardano-cli non-extended key conversion rule changed'
}
# Frozen from cardano-cli's upstream non-extended-key goldens. Together with
# the complete fixture envelopes below, these prove that direct construction
# applies the same 64-byte extended -> first-32-byte ordinary key conversion.
assert_cardano_cli_nonextended_vector \
  '5840a6f7741bb5559f899e99312f425f52e66b0ff25e4da66523e6dc1c5b21d52c0450f7a870e38d988c3c57ce9e6e35662c5c379f7247cbe574cfa82550a3f0c181' \
  '5820a6f7741bb5559f899e99312f425f52e66b0ff25e4da66523e6dc1c5b21d52c04'
assert_cardano_cli_nonextended_vector \
  '58400f205175c0a47cba409c328f066e31ea4e81ef211f539c12b64b4b14e1d87188a54f03c3edad073428f37dbdad714b7c07371ca19fe66c72d41fda23a81d8309' \
  '58200f205175c0a47cba409c328f066e31ea4e81ef211f539c12b64b4b14e1d87188'
assert_cardano_cli_nonextended_vector \
  '5840b0cd9e6e3e274f4f38f55ef274af123cf4600ac0c58294399b7e076175262553dde8b75f847f2b7e61a8748627292a06d739c8ba8e78ac83e666030d1093fb3e' \
  '5820b0cd9e6e3e274f4f38f55ef274af123cf4600ac0c58294399b7e076175262553'
assert_cardano_cli_nonextended_vector \
  '58400a9d35aa5299580a67b1e43a3a4b6d43ef29c94e56c51ce4c17e9a53c1d0f39aa7f68837c38ef680b2dc8f047581707a32f6fcade23d4e02177d389002484798' \
  '58200a9d35aa5299580a67b1e43a3a4b6d43ef29c94e56c51ce4c17e9a53c1d0f39a'
assert_cardano_cli_nonextended_vector \
  '5840f010c4332699c6ea1e43b427919860277169382d43d2969b28a110cfa08d955c4f178f20955541ce918a6a1352c32536f22677008f9f918d109663e4d2bdc084' \
  '5820f010c4332699c6ea1e43b427919860277169382d43d2969b28a110cfa08d955c'
assert_signing_envelope_golden() {
  local leaf="$1" envelope_type="$2"
  builtin printf \
    '{\n  "type": "%s",\n  "description": "CNTools mnemonic signing key",\n  "cborHex": "%s"\n}\n' \
    "${envelope_type}" "${GOLDEN_SIGNING_CBOR}" > "${EXPECTED_KEY_ENVELOPE}"
  cmp -s -- "${WALLET_ROOT}/fixture_wallet/${leaf}" \
    "${EXPECTED_KEY_ENVELOPE}" ||
    fail "signing-key golden envelope changed: ${leaf}"
}
assert_vkey_envelope_golden() {
  local leaf="$1" envelope_type="$2" description="$3"
  builtin printf \
    '{\n    "type": "%s",\n    "description": "%s",\n    "cborHex": "%s"\n}\n' \
    "${envelope_type}" "${description}" "${GOLDEN_VKEY_CBOR}" \
    > "${EXPECTED_KEY_ENVELOPE}"
  cmp -s -- "${WALLET_ROOT}/fixture_wallet/${leaf}" \
    "${EXPECTED_KEY_ENVELOPE}" ||
    fail "verification-key golden envelope changed: ${leaf}"
}

assert_signing_envelope_golden payment.skey \
  PaymentExtendedSigningKeyShelley_ed25519_bip32
assert_signing_envelope_golden stake.skey \
  StakeExtendedSigningKeyShelley_ed25519_bip32
assert_signing_envelope_golden drep.skey DRepExtendedSigningKey_ed25519_bip32
assert_signing_envelope_golden cc-cold.skey \
  ConstitutionalCommitteeColdExtendedSigningKey_ed25519_bip32
assert_signing_envelope_golden cc-hot.skey \
  ConstitutionalCommitteeHotExtendedSigningKey_ed25519_bip32
assert_signing_envelope_golden ms-payment.skey \
  PaymentExtendedSigningKeyShelley_ed25519_bip32
assert_signing_envelope_golden ms-stake.skey \
  StakeExtendedSigningKeyShelley_ed25519_bip32
assert_signing_envelope_golden ms-drep.skey \
  DRepExtendedSigningKey_ed25519_bip32

assert_vkey_envelope_golden payment.vkey PaymentVerificationKeyShelley_ed25519 \
  'Payment Verification Key'
assert_vkey_envelope_golden stake.vkey StakeVerificationKeyShelley_ed25519 \
  'Stake Verification Key'
assert_vkey_envelope_golden drep.vkey DRepVerificationKey_ed25519 \
  'Delegated Representative Verification Key'
assert_vkey_envelope_golden cc-cold.vkey \
  ConstitutionalCommitteeColdVerificationKey_ed25519 \
  'Constitutional Committee Cold Verification Key'
assert_vkey_envelope_golden cc-hot.vkey \
  ConstitutionalCommitteeHotVerificationKey_ed25519 \
  'Constitutional Committee Hot Verification Key'
assert_vkey_envelope_golden ms-payment.vkey \
  PaymentVerificationKeyShelley_ed25519 'Payment Verification Key'
assert_vkey_envelope_golden ms-stake.vkey \
  StakeVerificationKeyShelley_ed25519 'Stake Verification Key'
assert_vkey_envelope_golden ms-drep.vkey DRepVerificationKey_ed25519 \
  'Delegated Representative Verification Key'
find "${WALLET_ROOT}/fixture_wallet" -name '.*.evkey' -print -quit |
  grep -q . && fail 'obsolete extended-key scratch leaf was published'
grep -Eq 'command\.(out|err)' "${MEMBER_SOURCE}" &&
  fail 'obsolete pathname command capture remains in the helper'
grep -Eq '(^|[[:space:];(])coproc([[:space:]]|$)' "${MEMBER_SOURCE}" &&
  fail 'coprocess bookkeeping remains in the helper capture boundary'
grep -Eq '(command|builtin)[[:space:]]+exec[[:space:]]+\{' \
    "${MEMBER_SOURCE}" &&
  fail 'wrapped dynamic exec redirection remains in the helper'
grep -Fq "ex''ec {" "${MEMBER_SOURCE}" &&
  fail 'persistent Bash dynamic-FD redirection remains in production'
grep -Fq '__guild_cntools_wallet_descriptor_authenticate' \
    "${MEMBER_SOURCE}" ||
  fail 'authenticated fixed-descriptor lifecycle helper is missing'
grep -Fq "\$'%u\\t%Lp\\t%l\\t%z\\t%d\\t%i' <&\"\${_wmh_fd}\"" \
    "${MEMBER_SOURCE}" ||
  fail 'BSD descriptor identity authentication is missing'
grep -Fq '"${_wmh_fd_expected}"' "${MEMBER_SOURCE}" ||
  fail 'opened descriptor identity comparison is missing'
grep -Eq 'eval.*(_wmh_fixed|_wmh_cfd|fixed_fd)' "${MEMBER_SOURCE}" &&
  fail 'fixed-FD paths or ownership data reached eval'
for fixed_fd_oracle in {64..79}; do
  grep -Fq "ro:${fixed_fd_oracle}) ex''ec ${fixed_fd_oracle}<" \
    "${MEMBER_SOURCE}" ||
    fail "fixed-FD read arm missing: ${fixed_fd_oracle}"
  grep -Fq "wo:${fixed_fd_oracle}) ex''ec ${fixed_fd_oracle}>" \
    "${MEMBER_SOURCE}" ||
    fail "fixed-FD write arm missing: ${fixed_fd_oracle}"
  grep -Fq "rw:${fixed_fd_oracle}) ex''ec ${fixed_fd_oracle}<>" \
    "${MEMBER_SOURCE}" ||
    fail "fixed-FD read/write arm missing: ${fixed_fd_oracle}"
  grep -Fq "${fixed_fd_oracle}) ex''ec ${fixed_fd_oracle}>&-" \
    "${MEMBER_SOURCE}" ||
    fail "fixed-FD close arm missing: ${fixed_fd_oracle}"
done
grep -Fq 'wmhfd:${BASHPID}:' "${MEMBER_SOURCE}" &&
  grep -Fq 'wmhcfd:${BASHPID}:' "${MEMBER_SOURCE}" ||
  fail 'fixed-FD ownership tokens are missing'
grep -Fq '(( _wmh_count >= 8 )) || _wmh_status=70' "${MEMBER_SOURCE}" ||
  fail 'fixed-FD capacity is not proven before derivation tool launch'
grep -Fq '__guild_cntools_wallet_fixed_fd_acquire rw /dev/null' \
    "${MEMBER_SOURCE}" ||
  fail 'fixed-FD soft-limit capacity probe is missing'
PHASE_LOCK_WAITER_SOURCE="${TEST_ROOT}/phase-lock-waiter.production.sh"
sed -n \
  '/^      if \[\[ -e "${_wmh_phase_lock}"/,/^      _wmh_phase_lock_token=/p' \
  "${MEMBER_SOURCE}" > "${PHASE_LOCK_WAITER_SOURCE}"
[[ -s "${PHASE_LOCK_WAITER_SOURCE}" ]] ||
  fail 'phase-lock builtin waiter source is missing'
grep -Eq '\$\(|_wmh_tools|/dev/fd|builtin[[:space:]]+jobs|builtin[[:space:]]+wait' \
    "${PHASE_LOCK_WAITER_SOURCE}" &&
  fail 'phase-lock waiter launches children or inspects descriptors/jobs'
grep -Fq 'builtin kill -0 "${_wmh_phase_lock_pid}"' \
    "${PHASE_LOCK_WAITER_SOURCE}" ||
  fail 'phase-lock live-owner check is missing'
PHASE_LOCK_INVALID_GRACE_COUNT=0
while IFS= builtin read -r PHASE_LOCK_WAITER_LINE; do
  [[ "${PHASE_LOCK_WAITER_LINE}" != \
      *'SECONDS - _wmh_phase_lock_invalid_since >= 2'* ]] ||
    PHASE_LOCK_INVALID_GRACE_COUNT=$((PHASE_LOCK_INVALID_GRACE_COUNT + 1))
done < "${PHASE_LOCK_WAITER_SOURCE}"
(( PHASE_LOCK_INVALID_GRACE_COUNT == 3 )) &&
  grep -Fq 'The holder can unlink its authenticated lock' \
    "${PHASE_LOCK_WAITER_SOURCE}" &&
  grep -Fq 'before these structural tests' \
    "${PHASE_LOCK_WAITER_SOURCE}" ||
  fail 'structural, dead-holder, and invalid-token grace are not identically bounded'
grep -Fq '_wmh_phase_lock_deadline=$((SECONDS + 30))' \
    "${MEMBER_SOURCE}" &&
  grep -Fq '2>/dev/null > "${_wmh_phase_lock}"' \
    "${MEMBER_SOURCE}" &&
  grep -Fq '"${_wmh_mode}" == 600 && "${_wmh_links}" == 1' \
    "${MEMBER_SOURCE}" &&
  grep -Fq '"${_wmh_device}" == "${_wmh_root_identity%%:*}"' \
    "${MEMBER_SOURCE}" ||
  fail 'phase-lock bound, atomic creation, or strict authentication is missing'
grep -Fq '"${_wmh_tools[rm]}" -- "${_wmh_phase_lock}"' \
    "${MEMBER_SOURCE}" &&
  grep -Fq 'a legitimate successor may already own a new' \
    "${MEMBER_SOURCE}" ||
  fail 'successor-safe authenticated phase-lock release is missing'
grep -Fq '_wmh_phrase="${!_wmh_phrase_name}"' "${MEMBER_SOURCE}" &&
  grep -Fq 'if (( _wmh_status == 0 )) && [[ "${_wmh_phase_lock_acquired}" == Y ]]' \
    "${MEMBER_SOURCE}" ||
  fail 'caller secrets can be copied before phase-lock acquisition'
unset -f assert_cardano_cli_nonextended_vector \
  assert_signing_envelope_golden assert_vkey_envelope_golden

# Bash locals inherit hostile ambient export attributes. Poison every private
# secret-bearing name and export the caller's imported phrase; the fake
# derivation/hash tools reject even the presence of those environment names.
# A phrase-bearing result is intentionally returned unexported, while the
# caller's unrelated ambient globals retain their original values/attributes.
wallet_name=environment_secrecy_wallet
# Clear the prior fixture outputs as well as the distinct hostile-call slots
# so preserved evidence cannot mistake stale public addresses for inputs.
base=
payment=
reward=
environment_phrase='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
environment_state=
environment_base=
environment_payment=
environment_reward=
environment_private_names=(
  _wmh_value _wmh_cleanup_marker_value _wmh_phrase _wmh_phrase_sha
  _wmh_saved_phrase_sha _wmh_inventory_sha _wmh_saved_inventory_sha
  _wmh_key _wmh_expected_key _wmh_digest _wmh_live_digest _wmh_captured
  _wmh_read_value _wmh_capture_outer_value _wmh_capture_value
  _wmh_capture_chunk _wmh_auth_helper_program _wmh_rest
  _wmh_word _wmh_root_prv _wmh_hex _wmh_es_key _wmh_xprv _wmh_xpub
  _wmh_root _wmh_root_identity _wmh_destination
  _wmh_phase_lock _wmh_phase_lock_identity _wmh_phase_lock_token
  _wmh_phase_lock_seen_token _wmh_phase_lock_extra
  _wmh_phase_lock_snapshot _wmh_phase_lock_first_snapshot
  _wmh_phase_lock_pid _wmh_phase_lock_root_device
  _wmh_phase_lock_saved_umask _wmh_lock _wmh_lock_identity
  _wmh_stage _wmh_stage_identity _wmh_state _wmh_inventory _wmh_ack
  _wmh_cleanup_marker _wmh_saved_root _wmh_saved_root_identity
  _wmh_saved_destination _wmh_saved_destination_identity
  _wmh_saved_lock_identity _wmh_saved_stage_identity
  _wmh_publish_active_leaf
)
builtin export environment_phrase
for environment_private_name in "${environment_private_names[@]}"; do
  builtin printf -v "${environment_private_name}" '%s' \
    ambient-export-sentinel
  builtin export "${environment_private_name}"
done
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  environment_phrase environment_state environment_base \
  environment_payment environment_reward ||
  fail 'hostile exported mnemonic/private-local prepare failed'
[[ "${environment_phrase}" == \
     'alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean' &&
   "${environment_phrase@a}" != *x* && -f "${environment_state}" ]] ||
  fail 'secret-bearing phrase result retained an export attribute or state changed'
for environment_private_name in "${environment_private_names[@]}"; do
  [[ "${!environment_private_name}" == \
       ambient-export-sentinel &&
     "${!environment_private_name@a}" == *x* ]] ||
    fail "private ambient export state changed: ${environment_private_name}"
  builtin unset "${environment_private_name}"
done
_test_cntools_compatibility_wallet_mnemonic_run abort \
  environment_phrase environment_state ||
  fail 'hostile exported mnemonic cleanup failed'
[[ -z "${environment_phrase}${environment_state}" &&
   "${environment_phrase@a}" != *x* &&
   ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
  fail 'security export override or hostile environment cleanup changed'
environment_empty_phrase=
environment_empty_state=
builtin export environment_empty_phrase
_test_cntools_compatibility_wallet_mnemonic_run abort \
  environment_empty_phrase environment_empty_state ||
  fail 'empty exported phrase abort failed'
[[ -z "${environment_empty_phrase}${environment_empty_state}" &&
   "${environment_empty_phrase@a}" == *x* ]] ||
  fail 'empty phrase slot did not restore its caller export attribute'
builtin unset environment_phrase environment_empty_phrase \
  environment_state environment_empty_state environment_base \
  environment_payment environment_reward
environment_private_names=()

wallet_name=abort_wallet
phrase='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'import prepare phase failed'
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state ||
  fail 'abort phase failed'
[[ -z "${phrase}${state}" && ! -e "${WALLET_ROOT}/${wallet_name}" &&
   ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
  fail 'abort cleanup/secret clearing contract changed'
for capture_worker_symbol in __guild_cntools_wallet_capture_worker \
    __guild_cntools_wallet_capture_interrupt \
    __guild_cntools_wallet_capture_fixed_fd_acquire \
    __guild_cntools_wallet_capture_fixed_fd_close \
    __guild_cntools_wallet_fixed_fd_acquire \
    __guild_cntools_wallet_fixed_fd_resolve \
    __guild_cntools_wallet_fixed_fd_close; do
  ! builtin declare -F "${capture_worker_symbol}" >/dev/null 2>&1 ||
    fail "capture worker symbol escaped its command-substitution boundary: ${capture_worker_symbol}"
done

# Caller-owned literal bank descriptors must be skipped byte-for-byte, while
# the remaining thirteen slots still cover the proven maximum of two CCLI
# inputs plus six anonymous capture-pipe ends.
FIXED_FD_CALLER_ROOT="${TEST_ROOT}/fixed-fd-caller"
"${TEST_REAL_MKDIR}" -m 0700 -- "${FIXED_FD_CALLER_ROOT}"
builtin printf '%s\n' caller-read > "${FIXED_FD_CALLER_ROOT}/read"
: > "${FIXED_FD_CALLER_ROOT}/write"
builtin printf '%s\n' caller-read-write > \
  "${FIXED_FD_CALLER_ROOT}/read-write"
"${TEST_REAL_CHMOD}" 0600 "${FIXED_FD_CALLER_ROOT}/read" \
  "${FIXED_FD_CALLER_ROOT}/write" \
  "${FIXED_FD_CALLER_ROOT}/read-write"
[[ ! -e /dev/fd/64 && ! -e /dev/fd/65 && ! -e /dev/fd/66 ]] ||
  fail 'fixed-FD caller-preservation oracle requires free slots 64-66'
ex''ec 64< "${FIXED_FD_CALLER_ROOT}/read"
ex''ec 65> "${FIXED_FD_CALLER_ROOT}/write"
ex''ec 66<> "${FIXED_FD_CALLER_ROOT}/read-write"
_test_count_lines fixed_fd_vectors_before "${VECTOR_LOG}" ||
  fail 'could not count vectors before fixed-FD caller oracle'
wallet_name=fixed_fd_caller_wallet
phrase='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'prepare failed with caller-owned fixed bank descriptors'
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state ||
  fail 'abort failed with caller-owned fixed bank descriptors'
[[ -e /dev/fd/64 && -e /dev/fd/65 && -e /dev/fd/66 ]] ||
  fail 'caller-owned fixed bank descriptor was closed'
IFS= builtin read -r fixed_fd_read_value <&64
IFS= builtin read -r fixed_fd_read_write_value <&66
builtin printf '%s\n' caller-write >&65
ex''ec 64<&-
ex''ec 65>&-
ex''ec 66>&-
IFS= builtin read -r fixed_fd_written_value < \
  "${FIXED_FD_CALLER_ROOT}/write"
_test_count_lines fixed_fd_vectors_after "${VECTOR_LOG}" ||
  fail 'could not count vectors after fixed-FD caller oracle'
[[ "${fixed_fd_read_value}" == caller-read &&
   "${fixed_fd_read_write_value}" == caller-read-write &&
   "${fixed_fd_written_value}" == caller-write &&
   $((fixed_fd_vectors_after - fixed_fd_vectors_before)) == 41 &&
   -z "${phrase}${state}" &&
   ! -e "${WALLET_ROOT}/${wallet_name}" &&
   ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
  fail 'caller-owned fixed bank descriptors were not preserved exactly'

# Exhaustion must stop in the anonymous capture worker before even the first
# fake tool exec or secret stdin write, and must not replace any caller FD.
(
  ex''ec 64<> /dev/null
  ex''ec 65<> /dev/null
  ex''ec 66<> /dev/null
  ex''ec 67<> /dev/null
  ex''ec 68<> /dev/null
  ex''ec 69<> /dev/null
  ex''ec 70<> /dev/null
  ex''ec 71<> /dev/null
  ex''ec 72<> /dev/null
  ex''ec 73<> /dev/null
  ex''ec 74<> /dev/null
  ex''ec 75<> /dev/null
  ex''ec 76<> /dev/null
  ex''ec 77<> /dev/null
  ex''ec 78<> /dev/null
  ex''ec 79<> /dev/null
  _test_count_lines fixed_fd_exhaust_vectors_before "${VECTOR_LOG}" ||
    builtin exit 91
  wallet_name=fixed_fd_exhaustion_wallet
  phrase='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
  state=
  base=
  payment=
  reward=
  fixed_fd_exhaust_status=0
  _test_cntools_compatibility_wallet_mnemonic_run prepare \
    phrase state base payment reward || fixed_fd_exhaust_status=$?
  _test_count_lines fixed_fd_exhaust_vectors_after "${VECTOR_LOG}" ||
    builtin exit 92
  for fixed_fd_exhaust_slot in {64..79}; do
    [[ -e "/dev/fd/${fixed_fd_exhaust_slot}" ]] || builtin exit 93
  done
  [[ "${fixed_fd_exhaust_status}" == 70 &&
     "${fixed_fd_exhaust_vectors_after}" == \
       "${fixed_fd_exhaust_vectors_before}" &&
     -z "${phrase}${state}${base}${payment}${reward}" &&
     ! -e "${WALLET_ROOT}/${wallet_name}" &&
     ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]]
) || fail 'fixed-FD bank exhaustion launched a tool or leaked caller state'
[[ "$(builtin type -t exec 2>/dev/null || true)" == builtin &&
   "$(builtin type -t command 2>/dev/null || true)" == builtin ]] ||
  fail 'descriptor dispatch builtin state changed before stress'

# Repeated ordinary prepare/abort calls must restore the full parent shell
# state and Bash's dynamic-descriptor allocator, both serially and when
# independent wallet transactions run concurrently.
_test_snapshot_open_fds stress_fds_before ||
  fail 'could not snapshot descriptors before prepare/abort stress'
_test_snapshot_running_jobs stress_jobs_before \
  "${TEST_ROOT}/stress-jobs-before.list" ||
  fail 'could not snapshot jobs before prepare/abort stress'
stress_options_before="$-"
ex''ec {stress_probe_fd}</dev/null
stress_probe_baseline="${stress_probe_fd}"
ex''ec {stress_probe_fd}<&-
for ((stress_round=0; stress_round<3; stress_round++)); do
  wallet_name="serial_stress_${stress_round}"
  phrase='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
  state=
  base=
  payment=
  reward=
  _test_cntools_compatibility_wallet_mnemonic_run prepare \
    phrase state base payment reward ||
    fail "serial stress prepare ${stress_round} failed"
  _test_cntools_compatibility_wallet_mnemonic_run abort phrase state ||
    fail "serial stress abort ${stress_round} failed"
  [[ -z "${phrase}${state}" &&
     ! -e "${WALLET_ROOT}/${wallet_name}" &&
     ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
    fail "serial stress cleanup ${stress_round} changed"
  ex''ec {stress_probe_fd}</dev/null
  [[ "${stress_probe_fd}" == "${stress_probe_baseline}" ]] ||
    fail "serial stress descriptor allocator advanced at ${stress_round}"
  ex''ec {stress_probe_fd}<&-
done
STRESS_CHILD="${TEST_ROOT}/concurrent-stress-child.sh"
cat > "${STRESS_CHILD}" <<'EOF_CONCURRENT_STRESS_CHILD'
#!/usr/bin/env bash
set -euo pipefail
member_source=$1
wallet_root=$2
fake_bin=$3
fault_bin=$4
child_root=$5
child_round=$6
real_stat=$7
real_hash=$8
outside_file=$9
base_path=${10}

snapshot_fds() {
  local result_name=$1 result='' fd=0
  for ((fd=0; fd<256; fd++)); do
    [[ ! -e "/dev/fd/${fd}" ]] || result+="${fd},"
  done
  builtin printf -v "${result_name}" '%s' "${result}"
}

VECTOR_LOG="${child_root}/vectors"
MNEMONIC_HELPER_REAL_STAT="${real_stat}"
MNEMONIC_HELPER_REAL_HASH="${real_hash}"
MNEMONIC_HELPER_FAULT_MARKER="${child_root}/fault.marker"
MNEMONIC_HELPER_OUTPUT_OUTSIDE="${outside_file}"
MNEMONIC_HELPER_OUTPUT_FAULT_MARKER="${child_root}/output-fault.marker"
MNEMONIC_HELPER_OUTPUT_TARGET=
MNEMONIC_HELPER_OUTPUT_REPLACEMENT=
MNEMONIC_HELPER_OUTPUT_LATE_PATH=
MNEMONIC_HELPER_CAPTURE_PID_FILE="${child_root}/capture.pid"
MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE="${child_root}/descendant.pid"
MNEMONIC_HELPER_CAPTURE_DESCENDANT_HANDSHAKE_FILE="${child_root}/descendant.handshake"
MNEMONIC_HELPER_CAPTURE_DESCENDANT_SURVIVOR_FILE="${child_root}/descendant.survivor"
MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE="${child_root}/phase-lock.outside"
MNEMONIC_HELPER_PHASE_GUARD_DIR="${wallet_root}/.mnemonic-phase-tool.guard"
export VECTOR_LOG MNEMONIC_HELPER_REAL_STAT MNEMONIC_HELPER_REAL_HASH
export MNEMONIC_HELPER_FAULT_MARKER MNEMONIC_HELPER_OUTPUT_OUTSIDE
export MNEMONIC_HELPER_OUTPUT_FAULT_MARKER MNEMONIC_HELPER_OUTPUT_TARGET
export MNEMONIC_HELPER_OUTPUT_REPLACEMENT MNEMONIC_HELPER_OUTPUT_LATE_PATH
export MNEMONIC_HELPER_CAPTURE_PID_FILE
export MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE
export MNEMONIC_HELPER_CAPTURE_DESCENDANT_HANDSHAKE_FILE
export MNEMONIC_HELPER_CAPTURE_DESCENDANT_SURVIVOR_FILE
export MNEMONIC_HELPER_PHASE_LOCK_OUTSIDE MNEMONIC_HELPER_PHASE_GUARD_DIR
PATH="${fault_bin}:${fake_bin}:${base_path}"
export PATH
: > "${VECTOR_LOG}"
/bin/chmod 0600 "${VECTOR_LOG}"

WALLET_FOLDER="${wallet_root}"
wallet_name="concurrent_stress_${child_round}"
acct_idx=7
key_idx=9
NETWORK_IDENTIFIER='--testnet-magic 42'
NWMAGIC=42
CCLI="${fake_bin}/cardano-cli"
WALLET_DERIVATION_PATH_FILENAME=derivation.path
WALLET_PAY_SK_FILENAME=payment.skey
WALLET_PAY_VK_FILENAME=payment.vkey
WALLET_STAKE_SK_FILENAME=stake.skey
WALLET_STAKE_VK_FILENAME=stake.vkey
WALLET_GOV_DREP_SK_FILENAME=drep.skey
WALLET_GOV_DREP_VK_FILENAME=drep.vkey
WALLET_GOV_CC_COLD_SK_FILENAME=cc-cold.skey
WALLET_GOV_CC_COLD_VK_FILENAME=cc-cold.vkey
WALLET_GOV_CC_HOT_SK_FILENAME=cc-hot.skey
WALLET_GOV_CC_HOT_VK_FILENAME=cc-hot.vkey
WALLET_MULTISIG_PREFIX=ms-
WALLET_BASE_ADDR_FILENAME=base.addr
WALLET_PAY_ADDR_FILENAME=payment.addr
WALLET_STAKE_ADDR_FILENAME=reward.addr
WALLET_PAY_CRED_FILENAME=payment.cred
WALLET_STAKE_CRED_FILENAME=stake.cred
MNEMONIC_HELPER_SIGNAL_PID="${BASHPID}"
export MNEMONIC_HELPER_SIGNAL_PID

# shellcheck source=/dev/null
builtin source "${member_source}"
phrase='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
state=
base=
payment=
reward=
snapshot_fds fds_before
flags_before=$-
builtin trap -p HUP INT TERM > "${child_root}/traps.before"
builtin jobs -pr > "${child_root}/jobs.before" 2>/dev/null || true

_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward
[[ -n "${phrase}" && -n "${state}" && -f "${state}" &&
   -z "${base}${payment}${reward}" ]]
_cntools_compatibility_wallet_mnemonic_run abort phrase state
[[ -z "${phrase}${state}${base}${payment}${reward}" &&
   ! -e "${wallet_root}/${wallet_name}" &&
   ! -e "${wallet_root}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]]

snapshot_fds fds_after
flags_after=$-
builtin trap -p HUP INT TERM > "${child_root}/traps.after"
builtin jobs -pr > "${child_root}/jobs.after" 2>/dev/null || true
[[ "${fds_after}" == "${fds_before}" && "${flags_after}" == "${flags_before}" ]]
/usr/bin/cmp -s -- "${child_root}/traps.before" "${child_root}/traps.after"
/usr/bin/cmp -s -- "${child_root}/jobs.before" "${child_root}/jobs.after"
vector_count=0
while IFS= builtin read -r vector_line; do
  vector_count=$((vector_count + 1))
done < "${VECTOR_LOG}"
(( vector_count == 41 ))
EOF_CONCURRENT_STRESS_CHILD
chmod 0600 "${STRESS_CHILD}"

stress_pids=()
stress_stdouts=()
stress_stderrs=()
stress_child_roots=()
for ((stress_round=0; stress_round<3; stress_round++)); do
  stress_child_roots+=("${TEST_ROOT}/concurrent-stress-${stress_round}")
  stress_stdouts+=("${TEST_ROOT}/concurrent-stress-${stress_round}.stdout")
  stress_stderrs+=("${TEST_ROOT}/concurrent-stress-${stress_round}.stderr")
  "${TEST_REAL_MKDIR}" -m 0700 -- \
    "${stress_child_roots[${stress_round}]}"
  "${BASH}" --noprofile --norc "${STRESS_CHILD}" \
    "${MEMBER_SOURCE}" "${WALLET_ROOT}" "${FAKE_BIN}" "${FAULT_BIN}" \
    "${stress_child_roots[${stress_round}]}" "${stress_round}" \
    "${MNEMONIC_HELPER_REAL_STAT}" "${MNEMONIC_HELPER_REAL_HASH}" \
    "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}" "${PATH}" \
    > "${stress_stdouts[${stress_round}]}" \
    2> "${stress_stderrs[${stress_round}]}" &
  stress_pids+=("$!")
done
stress_failed=N
for ((stress_round=0; stress_round<${#stress_pids[@]}; stress_round++)); do
  stress_pid="${stress_pids[${stress_round}]}"
  if builtin wait "${stress_pid}"; then
    stress_status=0
  else
    stress_status=$?
    stress_failed=Y
  fi
  if [[ "${stress_status}" != 0 ||
        -s "${stress_stdouts[${stress_round}]}" ||
        -s "${stress_stderrs[${stress_round}]}" ]]; then
    builtin printf 'concurrent stress round=%s pid=%s status=%s\n' \
      "${stress_round}" "${stress_pid}" "${stress_status}" >&2
    sed 's/^/stdout: /' "${stress_stdouts[${stress_round}]}" >&2 || true
    sed 's/^/stderr: /' "${stress_stderrs[${stress_round}]}" >&2 || true
    stress_failed=Y
  fi
done
[[ "${stress_failed}" == N ]] || fail 'concurrent prepare/abort stress failed'
[[ ! -e "${WALLET_ROOT}/.cntools-wallet-mnemonic.phase.lock" &&
   ! -e "${WALLET_ROOT}/.mnemonic-phase-tool.guard" ]] ||
  fail 'serialized stress retained its phase lock or overlap guard'
_test_snapshot_open_fds stress_fds_after ||
  fail 'could not snapshot descriptors after prepare/abort stress'
_test_snapshot_running_jobs stress_jobs_after \
  "${TEST_ROOT}/stress-jobs-after.list" ||
  fail 'could not snapshot jobs after prepare/abort stress'
stress_options_after="$-"
ex''ec {stress_probe_fd}</dev/null
stress_probe_final="${stress_probe_fd}"
ex''ec {stress_probe_fd}<&-
[[ "${stress_fds_after}" == "${stress_fds_before}" &&
   "${stress_jobs_after}" == "${stress_jobs_before}" &&
   "${stress_options_after}" == "${stress_options_before}" &&
   "${stress_probe_final}" == "${stress_probe_baseline}" ]] ||
  fail 'prepare/abort stress leaked descriptors, jobs, or shell options'

wallet_name=no_ack_wallet
phrase=
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'no-ack prepare phase failed'
set +e
_test_cntools_compatibility_wallet_mnemonic_run publish \
  phrase state base payment reward >/dev/null 2>&1
publish_status=$?
set -e
[[ "${publish_status}" == 70 && -z "${phrase}${state}" &&
   ! -e "${WALLET_ROOT}/${wallet_name}" &&
   ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
  fail 'publish-without-ack did not fail closed'

# Empty abort is independent of all ambient configuration and tool lookup.
saved_path="${PATH}"
saved_wallet_root="${WALLET_FOLDER}"
PATH=/definitely/unavailable
WALLET_FOLDER=
phrase='secret must clear'
state=
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state ||
  fail 'empty-state abort was not idempotent'
[[ -z "${phrase}${state}" ]] || fail 'empty-state abort retained caller data'
PATH="${saved_path}"
WALLET_FOLDER="${saved_wallet_root}"

# An exact hard link created by ln followed by a nonzero status is reconciled
# for both acknowledgement and publication.
wallet_name=ack_error_wallet
phrase=
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'ack-error prepare failed'
MNEMONIC_HELPER_FAULT=ack-ln-error
export MNEMONIC_HELPER_FAULT
_test_cntools_compatibility_wallet_mnemonic_run acknowledge phrase state ||
  fail 'created-but-error acknowledgement was not reconciled'
MNEMONIC_HELPER_FAULT=
_test_cntools_compatibility_wallet_mnemonic_run publish \
  phrase state base payment reward ||
  fail 'publish after reconciled acknowledgement failed'

wallet_name=publish_error_wallet
phrase=
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'publish-error prepare failed'
_test_cntools_compatibility_wallet_mnemonic_run acknowledge phrase state ||
  fail 'publish-error acknowledgement failed'
MNEMONIC_HELPER_FAULT=publish-ln-error
_test_cntools_compatibility_wallet_mnemonic_run publish \
  phrase state base payment reward ||
  fail 'created-but-error publication was not reconciled'
MNEMONIC_HELPER_FAULT=

# A link that is created successfully but fails its immediate verification is
# recorded before verification and removed by authenticated rollback.
wallet_name=post_link_verify_wallet
phrase=
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'post-link-verification prepare failed'
_test_cntools_compatibility_wallet_mnemonic_run acknowledge phrase state ||
  fail 'post-link-verification acknowledge failed'
/bin/rm -f -- "${MNEMONIC_HELPER_FAULT_MARKER}"
MNEMONIC_HELPER_FAULT=post-link-verify
set +e
_test_cntools_compatibility_wallet_mnemonic_run publish \
  phrase state base payment reward >/dev/null 2>&1
publish_status=$?
set -e
MNEMONIC_HELPER_FAULT=
[[ "${publish_status}" == 70 && -z "${phrase}${state}" &&
   ! -e "${WALLET_ROOT}/post_link_verify_wallet" &&
   ! -e "${WALLET_ROOT}/.post_link_verify_wallet.cntools-wallet-mnemonic.lock" ]] ||
  fail 'post-create verification failure left an untracked publication'
/bin/rm -f -- "${MNEMONIC_HELPER_FAULT_MARKER}"

# Rollback into an already-existing empty destination must distrust a
# zero-return unlink until the destination and staged inode inventories are
# reauthenticated. A later abort can safely retry the exact public hard link.
wallet_name=existing_noop_wallet
mkdir -m 0700 -- "${WALLET_ROOT}/${wallet_name}"
phrase=
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'existing-destination no-op prepare failed'
_test_cntools_compatibility_wallet_mnemonic_run acknowledge phrase state ||
  fail 'existing-destination no-op acknowledge failed'
saved_phrase="${phrase}"
saved_state="${state}"
/bin/rm -f -- "${MNEMONIC_HELPER_FAULT_MARKER}"
MNEMONIC_HELPER_FAULT=existing-rollback-noop
set +e
_test_cntools_compatibility_wallet_mnemonic_run publish \
  phrase state base payment reward >/dev/null 2>&1
publish_status=$?
set -e
[[ "${publish_status}" == 70 && "${phrase}" == "${saved_phrase}" &&
   "${state}" == "${saved_state}" && -f "${state}" &&
   -d "${state%/state}/stage" &&
   -f "${state%/state}/stage/derivation.path" &&
   -f "${WALLET_ROOT}/${wallet_name}/derivation.path" ]] ||
  fail 'zero-return public unlink destroyed private retry authority'
phrase=
MNEMONIC_HELPER_FAULT=
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state ||
  fail 'existing-destination no-op abort retry failed'
remaining="$(find "${WALLET_ROOT}/${wallet_name}" \
  -mindepth 1 -maxdepth 1 -print -quit)"
[[ -z "${phrase}${state}${remaining}" &&
   -d "${WALLET_ROOT}/${wallet_name}" &&
   ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
  fail 'existing-destination no-op retry did not restore exact inventory'
/bin/rm -f -- "${MNEMONIC_HELPER_FAULT_MARKER}"

# A concurrent rename can make the attempted pathname disappear while the
# authenticated hard link remains under an unknown leaf. Publish and abort
# both retain authority until the exact expected pathname can be restored.
wallet_name=existing_rename_wallet
mkdir -m 0700 -- "${WALLET_ROOT}/${wallet_name}"
phrase=
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'existing-destination rename prepare failed'
_test_cntools_compatibility_wallet_mnemonic_run acknowledge phrase state ||
  fail 'existing-destination rename acknowledge failed'
saved_phrase="${phrase}"
saved_state="${state}"
/bin/rm -f -- "${MNEMONIC_HELPER_FAULT_MARKER}"
MNEMONIC_HELPER_FAULT=existing-rollback-rename
set +e
_test_cntools_compatibility_wallet_mnemonic_run publish \
  phrase state base payment reward >/dev/null 2>&1
publish_status=$?
set -e
unknown_leaf="${WALLET_ROOT}/${wallet_name}/derivation.path.unknown"
[[ "${publish_status}" == 70 && "${phrase}" == "${saved_phrase}" &&
   "${state}" == "${saved_state}" && -f "${state}" &&
   ! -e "${WALLET_ROOT}/${wallet_name}/derivation.path" &&
   -f "${unknown_leaf}" &&
   "${unknown_leaf}" -ef "${state%/state}/stage/derivation.path" ]] ||
  fail 'renamed public hard link destroyed private retry authority'
phrase=
MNEMONIC_HELPER_FAULT=
set +e
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state \
  >/dev/null 2>&1
abort_status=$?
set -e
[[ "${abort_status}" == 70 && "${state}" == "${saved_state}" &&
   -f "${state}" && -d "${state%/state}/stage" &&
   -f "${unknown_leaf}" ]] ||
  fail 'unknown public leaf did not retain authenticated abort authority'
/bin/mv -- "${unknown_leaf}" \
  "${WALLET_ROOT}/${wallet_name}/derivation.path"
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state ||
  fail 'restored public leaf abort retry failed'
remaining="$(find "${WALLET_ROOT}/${wallet_name}" \
  -mindepth 1 -maxdepth 1 -print -quit)"
[[ -z "${phrase}${state}${remaining}" &&
   -d "${WALLET_ROOT}/${wallet_name}" &&
   ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
  fail 'restored public leaf retry did not restore exact inventory'
/bin/rm -f -- "${MNEMONIC_HELPER_FAULT_MARKER}"

# A persistent post-link verification failure also defeats the in-call
# rollback. Abort must reconstruct that exact public hard link from the private
# inode/digest inventory and remove it before destroying retry authority.
wallet_name=persistent_recovery_wallet
phrase=
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'persistent-publication prepare failed'
_test_cntools_compatibility_wallet_mnemonic_run acknowledge phrase state ||
  fail 'persistent-publication acknowledge failed'
saved_phrase="${phrase}"
saved_state="${state}"
MNEMONIC_HELPER_FAULT=persistent-post-link
set +e
_test_cntools_compatibility_wallet_mnemonic_run publish \
  phrase state base payment reward >/dev/null 2>&1
publish_status=$?
set -e
[[ "${publish_status}" == 70 && "${phrase}" == "${saved_phrase}" &&
   "${state}" == "${saved_state}" && -f "${state}" &&
   -f "${WALLET_ROOT}/${wallet_name}/derivation.path" &&
   -f "${state%/state}/stage/derivation.path" ]] ||
  fail 'persistent publication failure did not preserve reconciliation authority'
phrase=
MNEMONIC_HELPER_FAULT=
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state ||
  fail 'persistent publication abort reconciliation failed'
[[ -z "${phrase}${state}" &&
   ! -e "${WALLET_ROOT}/${wallet_name}" &&
   ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
  fail 'abort left a reconstructed public hard link or private authority'

# If the reconstructed public hard link cannot be removed, abort must leave
# both sides and the authenticated state intact. A later retry can then finish
# without trusting a missing stage pathname or deleting an unrelated target.
wallet_name=persistent_retain_wallet
phrase=
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'retained-authority prepare failed'
_test_cntools_compatibility_wallet_mnemonic_run acknowledge phrase state ||
  fail 'retained-authority acknowledge failed'
MNEMONIC_HELPER_FAULT=persistent-post-link
set +e
_test_cntools_compatibility_wallet_mnemonic_run publish \
  phrase state base payment reward >/dev/null 2>&1
publish_status=$?
set -e
[[ "${publish_status}" == 70 && -n "${phrase}" && -f "${state}" &&
   -f "${WALLET_ROOT}/${wallet_name}/derivation.path" ]] ||
  fail 'retained-authority publication setup changed'
phrase=
saved_state="${state}"
MNEMONIC_HELPER_FAULT=abort-public-rm
set +e
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state \
  >/dev/null 2>&1
abort_status=$?
set -e
[[ "${abort_status}" == 70 && -z "${phrase}" &&
   "${state}" == "${saved_state}" && -f "${state}" &&
   -d "${state%/state}/stage" &&
   -f "${state%/state}/stage/derivation.path" &&
   -f "${WALLET_ROOT}/${wallet_name}/derivation.path" ]] ||
  fail 'failed public reconciliation destroyed retry authority'
MNEMONIC_HELPER_FAULT=
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state ||
  fail 'retained-authority abort retry failed'
[[ -z "${phrase}${state}" &&
   ! -e "${WALLET_ROOT}/${wallet_name}" &&
   ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
  fail 'retained-authority retry did not finish exact cleanup'

# Abort retains authority on a partial cleanup and can resume with the phrase
# already cleared by its caller.
wallet_name=abort_retry_wallet
phrase=
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'abort-retry prepare failed'
saved_phrase="${phrase}"
saved_state="${state}"
MNEMONIC_HELPER_FAULT=abort-rm
set +e
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state
abort_status=$?
set -e
[[ "${abort_status}" == 70 && "${phrase}" == "${saved_phrase}" &&
   "${state}" == "${saved_state}" && -f "${state}" ]] ||
  fail 'partial abort cleanup destroyed retry authority'
phrase=
MNEMONIC_HELPER_FAULT=
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state ||
  fail 'authenticated abort retry failed'
[[ -z "${phrase}${state}" &&
   ! -e "${WALLET_ROOT}/.abort_retry_wallet.cntools-wallet-mnemonic.lock" ]] ||
  fail 'abort retry did not finish contained cleanup'

# The cleanup authority remains outside the secret-bearing stage. If cleanup
# fails after the stage directory is gone, abort can reauthenticate and finish.
wallet_name=abort_after_stage_wallet
phrase=
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'post-stage abort prepare failed'
_test_cntools_compatibility_wallet_mnemonic_run acknowledge phrase state ||
  fail 'post-stage abort acknowledge failed'
saved_phrase="${phrase}"
saved_state="${state}"
lock_dir="${state%/state}"
/bin/rm -f -- "${MNEMONIC_HELPER_FAULT_MARKER}"
MNEMONIC_HELPER_FAULT=abort-after-stage-rm
set +e
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state
abort_status=$?
set -e
[[ "${abort_status}" == 70 && "${phrase}" == "${saved_phrase}" &&
   "${state}" == "${saved_state}" && ! -e "${lock_dir}/stage" &&
   -f "${lock_dir}/state" && -f "${lock_dir}/inventory" &&
   -f "${lock_dir}/cleanup-authority" && -f "${lock_dir}/acknowledged" ]] ||
  fail 'post-stage abort failure destroyed resumable authority'
phrase=
MNEMONIC_HELPER_FAULT=
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state ||
  fail 'post-stage authenticated abort retry failed'
[[ -z "${phrase}${state}" && ! -e "${lock_dir}" ]] ||
  fail 'post-stage abort retry did not finish contained cleanup'
/bin/rm -f -- "${MNEMONIC_HELPER_FAULT_MARKER}"

# Swapping the private stage prevents traversal and preserves the authentic
# state token until the original inode is restored.
wallet_name=stage_swap_wallet
phrase=
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'stage-swap prepare failed'
lock_dir="${state%/state}"
mv -- "${lock_dir}/stage" "${lock_dir}/stage.saved"
mkdir -m 0700 -- "${lock_dir}/stage"
saved_phrase="${phrase}"
saved_state="${state}"
set +e
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state
abort_status=$?
set -e
[[ "${abort_status}" == 70 && "${phrase}" == "${saved_phrase}" &&
   "${state}" == "${saved_state}" &&
   -d "${lock_dir}/stage.saved" ]] ||
  fail 'stage swap was traversed or destroyed retry authority'
rmdir -- "${lock_dir}/stage"
mv -- "${lock_dir}/stage.saved" "${lock_dir}/stage"
_test_cntools_compatibility_wallet_mnemonic_run abort phrase state ||
  fail 'stage-swap recovery abort failed'

# Private leaf mutation is caught before any destination write.
wallet_name=leaf_tamper_wallet
phrase=
state=
base=
payment=
reward=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'leaf-tamper prepare failed'
_test_cntools_compatibility_wallet_mnemonic_run acknowledge phrase state ||
  fail 'leaf-tamper acknowledgement failed'
printf 'tamper\n' >> "${state%/state}/stage/payment.skey"
set +e
_test_cntools_compatibility_wallet_mnemonic_run publish \
  phrase state base payment reward >/dev/null 2>&1
publish_status=$?
set -e
[[ "${publish_status}" == 70 &&
   ! -e "${WALLET_ROOT}/leaf_tamper_wallet" ]] ||
  fail 'prepublish leaf tamper was not rejected before target mutation'

# CCLI receives only fresh shell-bound read descriptors. Deterministically
# replace the staged pathname after both inputs are authenticated and opened
# but before the fake CLI consumes its /dev/fd argument. The authentic
# descriptor must remain usable, postvalidation must reject the pathname swap,
# and no outside inode may be changed.
for output_fault in ccli-input-symlink ccli-input-hardlink \
    ccli-input-special; do
  /bin/rm -f -- "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER}"
  chmod 0640 "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}"
  wallet_name="${output_fault//-/_}_wallet"
  MNEMONIC_HELPER_OUTPUT_LATE_PATH="${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock/stage/payment.vkey"
  phrase=
  state=
  base=
  payment=
  reward=
  MNEMONIC_HELPER_FAULT="${output_fault}"
  set +e
  _test_cntools_compatibility_wallet_mnemonic_run prepare \
    phrase state base payment reward >/dev/null 2>&1
  output_status=$?
  set -e
  MNEMONIC_HELPER_FAULT=
  MNEMONIC_HELPER_OUTPUT_LATE_PATH=
  [[ "${output_status}" == 70 && -z "${phrase}${state}" &&
     ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" &&
     "$(file_mode "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}")" == 640 ]] ||
    fail "${output_fault} escaped containment or changed outside mode"
  cmp -s -- "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}" \
    "${MNEMONIC_HELPER_OUTPUT_SNAPSHOT}" ||
    fail "${output_fault} changed outside content"
  [[ "$(file_identity_links "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}")" == \
     "${MNEMONIC_HELPER_OUTPUT_OUTSIDE_IDENTITY}" ]] ||
    fail "${output_fault} replaced or retained a link to the outside inode"
done

# Replace each output class after authentication while its bound consumer is
# active. Descriptor authentication and named-path postchecks must reject
# symlinks, hard links, and a late FIFO without blocking or escaping the root.
run_late_output_replacement_case() {
  local target_leaf="$1" replacement="$2" wallet="$3"
  local status_file="${TEST_ROOT}/${wallet}.status" late_path=""
  local helper_pid="" writer_pid="" wait_index=0 output_status=""
  /bin/rm -f -- "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER}" \
    "${status_file}"
  chmod 0640 "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}"
  MNEMONIC_HELPER_OUTPUT_TARGET="${target_leaf}"
  MNEMONIC_HELPER_OUTPUT_REPLACEMENT="${replacement}"
  MNEMONIC_HELPER_OUTPUT_LATE_PATH="${WALLET_ROOT}/.${wallet}.cntools-wallet-mnemonic.lock/stage/${target_leaf}"
  (
    set +e
    wallet_name="${wallet}"
    phrase=
    state=
    base=
    payment=
    reward=
    MNEMONIC_HELPER_FAULT=late-output-replacement
    _test_cntools_compatibility_wallet_mnemonic_run prepare \
      phrase state base payment reward >/dev/null 2>&1
    printf '%s\n' "$?" > "${status_file}"
  ) &
  helper_pid=$!
  for ((wait_index=0; wait_index<400; wait_index++)); do
    [[ ! -e "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER}" ]] || break
    /bin/sleep 0.025
  done
  [[ -e "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER}" ]] || {
    kill -TERM "${helper_pid}" 2>/dev/null || true
    wait "${helper_pid}" 2>/dev/null || true
    fail "late ${replacement} replacement was not reached for ${target_leaf}"
  }
  for ((wait_index=0; wait_index<200; wait_index++)); do
    [[ ! -f "${status_file}" ]] || break
    /bin/sleep 0.025
  done
  if [[ ! -f "${status_file}" ]]; then
    late_path="${WALLET_ROOT}/.${wallet}.cntools-wallet-mnemonic.lock/stage/${target_leaf}"
    if [[ -p "${late_path}" ]]; then
      (builtin printf '{}\n' > "${late_path}") &
      writer_pid=$!
    else
      kill -TERM "${helper_pid}" 2>/dev/null || true
    fi
    wait "${helper_pid}" 2>/dev/null || true
    [[ -z "${writer_pid}" ]] || wait "${writer_pid}" || true
    fail "late ${replacement} replacement blocked for ${target_leaf}"
  fi
  wait "${helper_pid}"
  IFS= read -r output_status < "${status_file}"
  [[ "${output_status}" == 70 &&
     ! -e "${WALLET_ROOT}/.${wallet}.cntools-wallet-mnemonic.lock" ]] ||
    fail "late ${replacement} replacement escaped containment for ${target_leaf}"
  [[ "$(file_mode "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}")" == 640 ]] ||
    fail "late ${replacement} replacement changed outside mode for ${target_leaf}"
  cmp -s -- "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}" \
    "${MNEMONIC_HELPER_OUTPUT_SNAPSHOT}" ||
    fail "late ${replacement} replacement changed outside content for ${target_leaf}"
  [[ "$(file_identity_links "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}")" == \
     "${MNEMONIC_HELPER_OUTPUT_OUTSIDE_IDENTITY}" ]] ||
    fail "late ${replacement} replacement changed outside inode for ${target_leaf}"
  /bin/rm -f -- "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER}" \
    "${status_file}"
}

run_late_output_replacement_case payment.skey symlink late_signing_wallet
run_late_output_replacement_case stake.skey fifo late_stake_signing_wallet
run_late_output_replacement_case payment.vkey hardlink late_vkey_wallet
run_late_output_replacement_case base.addr fifo late_address_wallet
run_late_output_replacement_case payment.cred symlink late_credential_wallet

MNEMONIC_HELPER_OUTPUT_TARGET=
MNEMONIC_HELPER_OUTPUT_REPLACEMENT=
MNEMONIC_HELPER_OUTPUT_LATE_PATH=

# Replacing a CCLI input pathname with a FIFO after its descriptor is held must
# never block. Run in a child with a strict deadline so a regression cannot
# hang the contract lane.
/bin/rm -f -- "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER}"
fifo_status_file="${TEST_ROOT}/fifo-output.status"
fifo_wallet_name=fifo_output_wallet
fifo_path="${WALLET_ROOT}/.${fifo_wallet_name}.cntools-wallet-mnemonic.lock/stage/payment.vkey"
MNEMONIC_HELPER_OUTPUT_LATE_PATH="${fifo_path}"
(
  set +e
  wallet_name="${fifo_wallet_name}"
  phrase=
  state=
  base=
  payment=
  reward=
  MNEMONIC_HELPER_FAULT=ccli-input-fifo
  _test_cntools_compatibility_wallet_mnemonic_run prepare \
    phrase state base payment reward >/dev/null 2>&1
  printf '%s\n' "$?" > "${fifo_status_file}"
) &
fifo_helper_pid=$!
for ((fifo_wait=0; fifo_wait<400; fifo_wait++)); do
  [[ ! -e "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER}" ]] || break
  /bin/sleep 0.025
done
[[ -e "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER}" ]] || {
  kill -TERM "${fifo_helper_pid}" 2>/dev/null || true
  wait "${fifo_helper_pid}" 2>/dev/null || true
  fail 'FIFO output fault was not reached'
}
for ((fifo_wait=0; fifo_wait<80; fifo_wait++)); do
  [[ ! -f "${fifo_status_file}" ]] || break
  /bin/sleep 0.025
done
if [[ ! -f "${fifo_status_file}" ]]; then
  fifo_writer_pid=
  if [[ -p "${fifo_path}" ]]; then
    (builtin printf '{}\n' > "${fifo_path}") &
    fifo_writer_pid=$!
  fi
  wait "${fifo_helper_pid}" 2>/dev/null || true
  [[ -z "${fifo_writer_pid}" ]] || wait "${fifo_writer_pid}" || true
  fail 'FIFO output caused a blocking schema read'
fi
wait "${fifo_helper_pid}"
IFS= read -r output_status < "${fifo_status_file}"
MNEMONIC_HELPER_FAULT=
MNEMONIC_HELPER_OUTPUT_LATE_PATH=
[[ "${output_status}" == 70 &&
   ! -e "${WALLET_ROOT}/.${fifo_wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
  fail 'FIFO output was accepted or left private state'
[[ "$(file_mode "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}")" == 640 ]] ||
  fail 'FIFO output changed outside mode'
cmp -s -- "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}" \
  "${MNEMONIC_HELPER_OUTPUT_SNAPSHOT}" ||
  fail 'FIFO output changed outside content'
[[ "$(file_identity_links "${MNEMONIC_HELPER_OUTPUT_OUTSIDE}")" == \
   "${MNEMONIC_HELPER_OUTPUT_OUTSIDE_IDENTITY}" ]] ||
  fail 'FIFO output changed outside inode'
/bin/rm -f -- "${MNEMONIC_HELPER_OUTPUT_FAULT_MARKER}" \
  "${fifo_status_file}"

# Exercise the anonymous capture boundary directly so byte limits, process
# containment, reap behavior, and descriptor restoration cannot be masked by
# a later CCLI schema rejection.
_wmh_lock="${TEST_ROOT}/capture-direct-transaction"
"${TEST_REAL_MKDIR}" -m 0700 -- "${_wmh_lock}"
declare -A _wmh_tools=(
  [mkfifo]="$(builtin type -P mkfifo)"
  [rm]="${TEST_REAL_RM}"
)
CAPTURE_DIRECT_STATUS=0
CAPTURE_DIRECT_RESULT=
_wmh_signal_pending=N
_test_capture_direct() {
  local capture_mode="${1:-}" capture_expected="${2:-}"
  local capture_command="${3:-${FAKE_BIN}/capture-writer}"
  local capture_status=0 capture_result=""
  local capture_fds_before="" capture_fds_after=""
  local capture_jobs_before="" capture_jobs_after=""
  local capture_options_before="$-" capture_options_after=""

  _test_snapshot_open_fds capture_fds_before || return 1
  _test_snapshot_running_jobs capture_jobs_before \
    "${TEST_ROOT}/capture-jobs-before.list" || return 1
  if _test_cntools_wallet_capture_bound 512 capture_result '' \
      "${capture_command}" "${capture_mode}"; then
    capture_status=0
  else
    capture_status=$?
  fi
  capture_options_after="$-"
  _test_snapshot_open_fds capture_fds_after || return 1
  _test_snapshot_running_jobs capture_jobs_after \
    "${TEST_ROOT}/capture-jobs-after.list" || return 1
  [[ "${capture_status}" == "${capture_expected}" &&
     "${capture_fds_after}" == "${capture_fds_before}" &&
     "${capture_jobs_after}" == "${capture_jobs_before}" &&
     "${capture_options_after}" == "${capture_options_before}" ]] || {
    builtin printf 'capture=%s status=%s expected=%s fds=%s/%s jobs=%q/%q options=%s/%s\n' \
      "${capture_mode}" "${capture_status}" "${capture_expected}" \
      "${capture_fds_before}" "${capture_fds_after}" \
      "${capture_jobs_before}" "${capture_jobs_after}" \
      "${capture_options_before}" "${capture_options_after}" >&2
    return 1
  }
  CAPTURE_DIRECT_STATUS="${capture_status}"
  CAPTURE_DIRECT_RESULT="${capture_result}"
}
_test_capture_pid_dead() {
  local pid_file="${1:-}" captured_pid="" attempt=0

  [[ -s "${pid_file}" ]] || return 1
  IFS= builtin read -r captured_pid < "${pid_file}"
  [[ "${captured_pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  for ((attempt=0; attempt<200; attempt++)); do
    builtin kill -0 "${captured_pid}" 2>/dev/null || return 0
    /bin/sleep 0.025
  done
  return 1
}

# Static names are safe only inside an empty authenticated transaction lock.
# Refuse an existing FIFO or symlink before any tool launch, and do not remove
# the unexpected object under caller authority.
"${_wmh_tools[mkfifo]}" -m 0600 -- "${_wmh_lock}/.capture-input.pipe"
_test_capture_direct delayed 70 ||
  fail 'capture accepted or mutated a pre-existing input FIFO'
[[ -p "${_wmh_lock}/.capture-input.pipe" ]] ||
  fail 'capture removed a pre-existing input FIFO'
/bin/rm -f -- "${_wmh_lock}/.capture-input.pipe"
/bin/ln -s -- /dev/null "${_wmh_lock}/.capture-output.pipe"
_test_capture_direct delayed 70 ||
  fail 'capture accepted or mutated a pre-existing output symlink'
[[ -L "${_wmh_lock}/.capture-output.pipe" ]] ||
  fail 'capture removed a pre-existing output symlink'
/bin/rm -f -- "${_wmh_lock}/.capture-output.pipe"

_test_capture_direct max-minus-one 0 ||
  fail 'capture max-1 boundary or descriptor restoration failed'
[[ ${#CAPTURE_DIRECT_RESULT} == 511 ]] ||
  fail 'capture max-1 byte count changed'
_test_capture_direct max 0 ||
  fail 'capture max boundary or descriptor restoration failed'
[[ ${#CAPTURE_DIRECT_RESULT} == 512 ]] ||
  fail 'capture max byte count changed'
for direct_capture_case in nul max-plus-one; do
  _test_capture_direct "${direct_capture_case}" 70 ||
    fail "capture ${direct_capture_case} rejection or cleanup failed"
done
_test_capture_direct delayed 0 ||
  fail 'delayed capture writer failed or leaked resources'
[[ "${CAPTURE_DIRECT_RESULT}" == delayed-value ]] ||
  fail 'delayed capture writer bytes changed'
_test_capture_direct nonzero 1 ||
  fail 'capture nonzero status parity or cleanup failed'
_test_capture_direct launch-failure 1 "${FAKE_BIN}/missing-capture-writer" ||
  fail 'capture launch failure status or cleanup failed'

/bin/rm -f -- "${MNEMONIC_HELPER_CAPTURE_PID_FILE}" \
  "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE}" \
  "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_HANDSHAKE_FILE}"
_test_capture_direct hung 70 ||
  fail 'hung capture writer was not bounded and cleaned'
_test_capture_pid_dead "${MNEMONIC_HELPER_CAPTURE_PID_FILE}" ||
  fail 'hung capture writer survived kill/reap cleanup'
/bin/rm -f -- "${MNEMONIC_HELPER_CAPTURE_PID_FILE}" \
  "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE}" \
  "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_HANDSHAKE_FILE}" \
  "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_SURVIVOR_FILE}"
_test_capture_direct descendant-held 70 ||
  fail 'descendant-held capture pipe was not bounded and cleaned'
_test_capture_pid_dead "${MNEMONIC_HELPER_CAPTURE_PID_FILE}" ||
  fail 'descendant-held capture parent was not reaped'
cmp -s -- "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE}" \
  "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_HANDSHAKE_FILE}" ||
  fail 'descendant-held capture handshake did not bind the inherited pipe to the launched child'
IFS= builtin read -r descendant_capture_pid \
  < "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE}"
builtin kill -USR1 "${descendant_capture_pid}" 2>/dev/null || true
for ((capture_attempt=0; capture_attempt<20; capture_attempt++)); do
  [[ ! -e "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_SURVIVOR_FILE}" ]] || break
  /bin/sleep 0.025
done
[[ ! -e "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_SURVIVOR_FILE}" ]] ||
  fail 'descendant-held capture child remained executable after group cleanup'
_test_capture_pid_dead "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE}" ||
  fail 'descendant-held capture child did not eventually disappear'

/bin/rm -f -- "${MNEMONIC_HELPER_CAPTURE_PID_FILE}"
_wmh_signal_pending=N
_test_capture_direct worker-signal 70 ||
  fail 'interrupted capture worker did not clean its private process group'
[[ "${_wmh_signal_pending}" == N ]] ||
  fail 'capture worker signal escaped to the calling shell'
_test_capture_pid_dead "${MNEMONIC_HELPER_CAPTURE_PID_FILE}" ||
  fail 'capture writer survived worker interruption cleanup'

capture_saved_term="$(builtin trap -p TERM || true)"
_wmh_signal_pending=N
builtin trap '_wmh_signal_pending=Y' TERM
/bin/rm -f -- "${MNEMONIC_HELPER_CAPTURE_PID_FILE}"
_test_capture_direct signal 70 ||
  fail 'signalled capture writer status or cleanup failed'
[[ "${_wmh_signal_pending}" == Y ]] ||
  fail 'capture signal was not observed by the bounded reader'
_test_capture_pid_dead "${MNEMONIC_HELPER_CAPTURE_PID_FILE}" ||
  fail 'signalled capture writer survived kill/reap cleanup'
if [[ -n "${capture_saved_term}" ]]; then
  builtin eval "${capture_saved_term}"
else
  builtin trap - TERM
fi
_wmh_signal_pending=N
/bin/rm -f -- "${MNEMONIC_HELPER_CAPTURE_PID_FILE}" \
  "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_PID_FILE}" \
  "${MNEMONIC_HELPER_CAPTURE_DESCENDANT_HANDSHAKE_FILE}"

# A failed anonymous-pipe unlink must stop before the derivation tool is
# launched or secret stdin is written. The injected rm failure occurs once so
# the worker can remove its authenticated FIFOs on its fail-closed path.
wallet_name=capture_unlink_failure_wallet
phrase='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
state=
base=
payment=
reward=
/bin/rm -f -- "${MNEMONIC_HELPER_FAULT_MARKER}"
capture_unlink_vectors_before="$(wc -l < "${VECTOR_LOG}" | tr -d '[:space:]')"
MNEMONIC_HELPER_FAULT=capture-unlink-failure
set +e
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward >/dev/null 2>&1
capture_status=$?
set -e
MNEMONIC_HELPER_FAULT=
capture_unlink_vectors_after="$(wc -l < "${VECTOR_LOG}" | tr -d '[:space:]')"
[[ "${capture_status}" == 70 &&
   -e "${MNEMONIC_HELPER_FAULT_MARKER}" &&
   "${capture_unlink_vectors_after}" == "${capture_unlink_vectors_before}" &&
   -z "${phrase}${state}${base}${payment}${reward}" &&
   ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
  fail 'capture FIFO unlink failure launched a tool, leaked state, or survived cleanup'
/bin/rm -f -- "${MNEMONIC_HELPER_FAULT_MARKER}"

# Successful diagnostics and overlong stdout share the same anonymous capture
# pipe. Both must be rejected as invariant failures without a pathname scratch
# file. A real CCLI nonzero remains the legacy handled-failure status 1.
for capture_fault in ccli-capture-stderr ccli-capture-overflow; do
  wallet_name="${capture_fault//-/_}_wallet"
  phrase=
  state=
  base=
  payment=
  reward=
  MNEMONIC_HELPER_FAULT="${capture_fault}"
  set +e
  _test_cntools_compatibility_wallet_mnemonic_run prepare \
    phrase state base payment reward >/dev/null 2>&1
  capture_status=$?
  set -e
  MNEMONIC_HELPER_FAULT=
  [[ "${capture_status}" == 70 && -z "${phrase}${state}" &&
     ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
    fail "${capture_fault} was accepted or left private state"
done

wallet_name=ccli_command_failure_wallet
phrase=
state=
base=
payment=
reward=
MNEMONIC_HELPER_FAULT=ccli-command-failure
set +e
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward >/dev/null 2>&1
command_failure_status=$?
set -e
MNEMONIC_HELPER_FAULT=
[[ "${command_failure_status}" == 1 && -z "${phrase}${state}" &&
   ! -e "${WALLET_ROOT}/.${wallet_name}.cntools-wallet-mnemonic.lock" ]] ||
  fail 'CCLI nonzero failure/status parity changed'

# Signals are deferred inside each helper phase; caller traps never run
# reentrantly. Precommit signals roll back, while a postcommit signal returns
# success only after exposing the complete committed output state.
signal_seen=N
trap 'signal_seen=Y' TERM
wallet_name=signal_prepare_wallet
phrase=
state=
base=
payment=
reward=
MNEMONIC_HELPER_FAULT=signal-prepare
set +e
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward >/dev/null 2>&1
signal_status=$?
set -e
[[ "${signal_status}" == 70 && "${signal_seen}" == N &&
   -z "${phrase}${state}" && ! -e "${WALLET_ROOT}/signal_prepare_wallet" ]] ||
  fail "prepare signal contract: status=${signal_status} seen=${signal_seen} phrase=${#phrase} state=${state:-empty} target=$([[ -e \"${WALLET_ROOT}/signal_prepare_wallet\" ]] && printf yes || printf no)"

wallet_name=signal_ack_wallet
phrase=
state=
base=
payment=
reward=
MNEMONIC_HELPER_FAULT=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'signal-ack prepare failed'
MNEMONIC_HELPER_FAULT=signal-ack
set +e
_test_cntools_compatibility_wallet_mnemonic_run acknowledge \
  phrase state >/dev/null 2>&1
signal_status=$?
set -e
[[ "${signal_status}" == 70 && "${signal_seen}" == N &&
   -z "${phrase}${state}" ]] ||
  fail 'acknowledge signal was not deferred and rolled back'

for signal_case_spec in first:absent middle:absent last:absent \
    unlink-failure:authentic race:replacement; do
  signal_case="${signal_case_spec%%:*}"
  signal_expected="${signal_case_spec#*:}"
  _test_publish_signal_rollback "${signal_case}" "${signal_expected}" ||
    fail "publish precommit signal rollback failed: ${signal_case}"
done

wallet_name=signal_postcommit_wallet
phrase=
state=
base=
payment=
reward=
MNEMONIC_HELPER_FAULT=
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward ||
  fail 'postcommit-signal prepare failed'
_test_cntools_compatibility_wallet_mnemonic_run acknowledge phrase state ||
  fail 'postcommit-signal acknowledgement failed'
MNEMONIC_HELPER_FAULT=signal-postcommit
_test_cntools_compatibility_wallet_mnemonic_run publish \
  phrase state base payment reward >/dev/null 2> "${PHASE_STDERR}" ||
  fail 'postcommit signal incorrectly implied rollback'
[[ "${signal_seen}" == N && -z "${phrase}${state}" &&
   -n "${base}" && -n "${payment}" && -n "${reward}" &&
   -d "${WALLET_ROOT}/signal_postcommit_wallet" ]] ||
  fail 'postcommit signal exposed a mixed commit state'
grep -Fqx 'WARNING: mnemonic wallet committed after an interrupt.' \
  "${PHASE_STDERR}" || fail 'postcommit signal warning changed'
MNEMONIC_HELPER_FAULT=
trap - TERM

# The legacy wrapper suppresses an inherited xtrace setting before its first
# mnemonic expansion, then restores the caller setting after clearing imported
# phrase/word slots.
getCustomDerivationPath() {
  acct_idx=7
  key_idx=9
  return 0
}
waitToProceed() {
  return 0
}
wallet_name=xtrace_wallet
mkdir -m 0700 -- "${WALLET_ROOT}/${wallet_name}"
mnemonic='alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean'
words=()
xtrace_log="${TEST_ROOT}/legacy-xtrace.log"
exec 8> "${xtrace_log}"
BASH_XTRACEFD=8
set -x
createMnemonicWallet
legacy_status=$?
set +x
unset BASH_XTRACEFD
exec 8>&-
[[ "${legacy_status}" == 0 && -z "${mnemonic+x}" &&
   -z "${words+x}" && -d "${WALLET_ROOT}/${wallet_name}" ]] ||
  fail 'legacy xtrace wrapper changed successful import behavior'
grep -Fq 'legacy_status=0' "${xtrace_log}" ||
  fail 'legacy wrapper did not restore caller xtrace'
if grep -Fq 'alpha bravo cactus delta ember fable gamma hotel ivory joker karma lemon mango nectar ocean' \
     "${xtrace_log}" ||
   grep -Eq 'root_xsk_|child_xsk_|alpha|ocean' "${xtrace_log}"; then
  fail 'legacy wrapper leaked mnemonic or derived secrets to xtrace'
fi

# Operator-owned tools must be single-link, non-writable, physically contained
# executables. These failures occur before a lock or target is created.
wallet_name=unsafe_tool_wallet
phrase=
state=
base=
payment=
reward=
ln -- "${FAKE_BIN}/cardano-address" "${FAULT_BIN}/cardano-address"
set +e
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward >/dev/null 2>&1
tool_status=$?
set -e
/bin/rm -f -- "${FAULT_BIN}/cardano-address"
[[ "${tool_status}" == 70 &&
   ! -e "${WALLET_ROOT}/.unsafe_tool_wallet.cntools-wallet-mnemonic.lock" ]] ||
  fail 'hard-linked operator tool was accepted'

unsafe_parent="${TEST_ROOT}/unsafe-tool-parent"
ln -s -- "${FAKE_BIN}" "${unsafe_parent}"
CCLI="${unsafe_parent}/cardano-cli"
set +e
_test_cntools_compatibility_wallet_mnemonic_run prepare \
  phrase state base payment reward >/dev/null 2>&1
tool_status=$?
set -e
CCLI="${FAKE_BIN}/cardano-cli"
[[ "${tool_status}" == 70 &&
   ! -e "${WALLET_ROOT}/.unsafe_tool_wallet.cntools-wallet-mnemonic.lock" ]] ||
  fail 'tool beneath symlink ancestry was accepted'

printf 'CNTools mnemonic helper contract passed\n'
