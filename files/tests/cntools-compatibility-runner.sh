#!/usr/bin/env bash
# Freeze the Stage 4 compatibility-subshell and action-outcome contract while
# public production action execution remains disabled. Focus selectors keep the
# transport, security, isolation, and final integration checkpoints bounded.
#
# Security model: the compatibility subshell isolates parent shell state for
# authenticated project action code. It is not a same-UID malicious-code
# sandbox and does not promise filesystem, network, or process-tree rollback.
# Stage 4 inherits the legacy compatibility functions/globals. Stage 5 owns the
# future clean-child environment allowlist.
# shellcheck disable=SC1090
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools compatibility runner tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

LC_ALL=C
export LC_ALL

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
REGISTRY_SOURCE="${CNTOOLS_ROOT}/core/registry.sh"
CONTEXT_SOURCE="${CNTOOLS_ROOT}/core/context.sh"
RESULT_SOURCE="${CNTOOLS_ROOT}/core/result.sh"
DISPATCHER_SOURCE="${CNTOOLS_ROOT}/core/dispatcher.sh"
BOOTSTRAP_SOURCE="${CNTOOLS_ROOT}/core/bootstrap.sh"
BASE_ACTION_METADATA="${CNTOOLS_ROOT}/modules/root/advanced/asset/list/module.json"
MODULES_ROOT="${CNTOOLS_ROOT}/modules/root"
ACTIVE_ACTION_LEDGER="${REPO_ROOT}/files/tests/fixtures/cntools-stage4-active-actions.tsv"
ACTIVE_ACTION_LEDGER_HEADER='# Stage 4 active action payload path and expected SHA-256.'
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-compat.XXXXXX")"
TEST_ROOT="$(cd -P -- "${TEST_ROOT}" && pwd -P)"
FIXTURE_ROOT="${TEST_ROOT}/fixtures"
FOCUS="${CNTOOLS_STAGE4_COMPAT_FOCUS:-all}"
CALL_STATUS=0
declare -A STAGE4_ACTIVE_ACTIONS=()

cleanup() {
  chmod -R u+rwX "${TEST_ROOT}" >/dev/null 2>&1 || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'CNTools compatibility runner test failed: %s\n' "$1" >&2
  exit 1
}

for required_command in bash chmod cmp cp dirname find grep head jq ln mkdir \
  mktemp mv rm sed sort stat tr wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

for required_source in \
  "${REGISTRY_SOURCE}" \
  "${CONTEXT_SOURCE}" \
  "${RESULT_SOURCE}" \
  "${DISPATCHER_SOURCE}" \
  "${BOOTSTRAP_SOURCE}" \
  "${BASE_ACTION_METADATA}" \
  "${ACTIVE_ACTION_LEDGER}"; do
  [[ -f "${required_source}" && ! -L "${required_source}" ]] ||
    fail "required source is missing or unsafe: ${required_source}"
done

stage4_action_path_valid() {
  local path="${1:-}"
  local component=""
  local -a components=()

  [[ "${path}" == cntools/modules/root/*/action.sh &&
     "${path}" != *//* && "${path}" != *\\* &&
     ! "${path}" =~ [[:cntrl:]] &&
     "${path}" =~ ^[A-Za-z0-9._/+@:-]+$ ]] || return 1
  IFS='/' read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != "." &&
       "${component}" != ".." ]] || return 1
  done
}

load_stage4_active_actions() {
  local header="" line="" path="" expected_hash="" extra=""
  local previous_path=""

  IFS= read -r header < "${ACTIVE_ACTION_LEDGER}" || return 1
  [[ "${header}" == "${ACTIVE_ACTION_LEDGER_HEADER}" ]] || return 1
  STAGE4_ACTIVE_ACTIONS=()
  while IFS= read -r line; do
    IFS=$'\t' read -r path expected_hash extra <<< "${line}"
    [[ "${line}" == "${path}"$'\t'"${expected_hash}" &&
       -z "${extra}" && "${expected_hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
    stage4_action_path_valid "${path}" || return 1
    [[ -z "${previous_path}" || "${previous_path}" < "${path}" ]] || return 1
    [[ -z "${STAGE4_ACTIVE_ACTIONS[${path}]+set}" ]] || return 1
    [[ -f "${REPO_ROOT}/scripts/common-helper-scripts/${path}" &&
       ! -L "${REPO_ROOT}/scripts/common-helper-scripts/${path}" ]] || return 1
    STAGE4_ACTIVE_ACTIONS["${path}"]="Y"
    previous_path="${path}"
  done < <(sed -n '2,$p' "${ACTIVE_ACTION_LEDGER}")
}

stage4_inactive_action_directory() {
  local action_file="" relative_path="" payload_path=""

  while IFS= read -r -d '' action_file; do
    relative_path="${action_file#"${CNTOOLS_ROOT}/"}"
    payload_path="cntools/${relative_path}"
    if [[ -z "${STAGE4_ACTIVE_ACTIONS[${payload_path}]+set}" ]]; then
      builtin printf '%s\n' "${action_file%/action.sh}"
      return 0
    fi
  done < <(find "${MODULES_ROOT}" -type f -name action.sh -print0 | sort -z)
  return 1
}

load_stage4_active_actions ||
  fail 'Stage 4 active-action ledger is malformed or unsafe'

mkdir -p -- "${FIXTURE_ROOT}"
chmod 700 "${TEST_ROOT}" "${FIXTURE_ROOT}"

# shellcheck source=/dev/null
source "${REGISTRY_SOURCE}"
# shellcheck source=/dev/null
source "${CONTEXT_SOURCE}"
# shellcheck source=/dev/null
source "${RESULT_SOURCE}"
# shellcheck source=/dev/null
source "${DISPATCHER_SOURCE}"

capture_call() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2

  : > "${stdout_file}"
  : > "${stderr_file}"
  set +e
  "$@" > "${stdout_file}" 2> "${stderr_file}"
  CALL_STATUS=$?
  set -e
}

assert_status() {
  local expected="$1"
  local context="$2"

  [[ "${CALL_STATUS}" -eq "${expected}" ]] ||
    fail "${context}: expected status ${expected}, got ${CALL_STATUS}"
}

assert_empty_file() {
  local target="$1"
  local context="$2"

  [[ ! -s "${target}" ]] || fail "${context}: expected empty output"
}

assert_file_text() {
  local target="$1"
  local expected="$2"
  local context="$3"
  local expected_file="${TEST_ROOT}/expected.$$.${RANDOM}"

  builtin printf '%s' "${expected}" > "${expected_file}"
  cmp -s -- "${expected_file}" "${target}" ||
    fail "${context}: output bytes changed"
  rm -f -- "${expected_file}"
}

assert_absent() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected path exists: $1"
}

write_context() {
  local target="$1"
  local mode="${2:-local}"

  jq -nS --arg mode "${mode}" '
    {
      schemaVersion: 1,
      apiVersion: 1,
      generationVersion: "13.5.7",
      mode: $mode,
      advanced: true,
      nodeImplementation: "cnode",
      nodeNetwork: "mainnet",
      nodeHome: "/srv/cardano",
      features: ["advanced", "blocklog"],
      capabilities: ["forging", "local-cli", "metrics", "n2c"]
    }
  ' > "${target}"
  chmod 400 "${target}"
}

write_module() {
  local action_directory="$1"
  local filter="${2:-.}"
  local staged="${action_directory}/module.json.stage"

  mkdir -p -- "${action_directory}"
  jq -S "${filter}" "${BASE_ACTION_METADATA}" > "${staged}"
  mv -f -- "${staged}" "${action_directory}/module.json"
  chmod 444 "${action_directory}/module.json"
}

write_probe_action() {
  local target="$1"
  local source_sentinel="$2"
  local main_sentinel="$3"

  {
    builtin printf '%s\n' '#!/usr/bin/env bash'
    builtin printf "builtin printf 'source\\n' >> %q\n" "${source_sentinel}"
    builtin printf '%s\n' 'cntools_action_main() {'
    builtin printf "  builtin printf 'main\\n' >> %q\n" "${main_sentinel}"
    builtin printf '%s\n' '  return 0' '}'
  } > "${target}"
  chmod 444 "${target}"
}

write_success_action() {
  local target="$1"
  local source_log="$2"
  local main_log="$3"

  {
    builtin printf '%s\n' '#!/usr/bin/env bash'
    builtin printf "builtin printf 'source\\n' >> %q\n" "${source_log}"
    builtin printf '%s\n' \
      'cntools_action_main() {' \
      '  local context_file="${1:-}"' \
      '  local result_file="${2:-}"' \
      '  local arguments_file="${3:-}"' \
      '  shift 3 || return 64'
    builtin printf "  builtin printf 'main\\n' >> %q\n" "${main_log}"
    builtin printf '%s\n' \
      '  [[ "${CNTOOLS_COMPAT_VALUE:-}" == "visible" ]] || return 91' \
      '  [[ "$(cntools_compat_probe)" == "compat-function" ]] || return 92' \
      '  builtin printf '\''%s\0'\'' "${context_file}" "${result_file}" "$@" > "${arguments_file}"' \
      '  umask 077' \
      '  builtin printf '\''%s\n'\'' '\''{'\'' '\''  "data": {'\'' '\''    "ok": true'\'' '\''  },'\'' '\''  "schemaVersion": 1'\'' '\''}'\'' > "${result_file}"' \
      '  chmod 600 "${result_file}"' \
      '  builtin printf '\''synthetic-stdout'\''' \
      '  builtin printf '\''synthetic-stderr'\'' >&2' \
      '  return 0' \
      '}'
  } > "${target}"
  chmod 444 "${target}"
}

write_status_action() {
  local target="$1"

  {
    builtin printf '%s\n' '#!/usr/bin/env bash' \
      'cntools_action_main() {' \
      '  local context_file="${1:-}" result_file="${2:-}" status="${3:-}"' \
      '  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64' \
      '  builtin printf '\''stdout:%s'\'' "${status}"' \
      '  builtin printf '\''stderr:%s'\'' "${status}" >&2' \
      '  return "${status}"' \
      '}'
  } > "${target}"
  chmod 444 "${target}"
}

write_result_copy_action() {
  local target="$1"

  {
    builtin printf '%s\n' '#!/usr/bin/env bash' \
      'cntools_action_main() {' \
      '  local context_file="${1:-}" result_file="${2:-}" source_file="${3:-}"' \
      '  [[ -n "${context_file}" && -n "${result_file}" && -n "${source_file}" ]] || return 64' \
      '  cp -- "${source_file}" "${result_file}" || return 71' \
      '  chmod 600 "${result_file}" || return 72' \
      '  return 0' \
      '}'
  } > "${target}"
  chmod 444 "${target}"
}

write_isolation_action() {
  local target="$1"

  {
    builtin printf '%s\n' '#!/usr/bin/env bash' \
      'cntools_action_main() {' \
      '  local context_file="${1:-}" result_file="${2:-}"' \
      '  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64' \
      '  CNTOOLS_PARENT_SCALAR="child"' \
      '  CNTOOLS_PARENT_INDEXED=(child)' \
      '  CNTOOLS_PARENT_ASSOC=([child]="value")' \
      '  unset CNTOOLS_PARENT_EXPORTED' \
      '  export CNTOOLS_CHILD_EXPORTED="child"' \
      '  BASH_ENV="child-bash-env"' \
      '  ENV="child-env"' \
      '  CNTOOLS_ACTION_DIRECTORY="child-action"' \
      '  CNTOOLS_CONTEXT_FILE="child-context"' \
      '  CNTOOLS_RESULT_FILE="child-result"' \
      '  unset -f cntools_parent_function' \
      '  cntools_child_function() { :; }' \
      '  unalias cntools_parent_alias 2>/dev/null || true' \
      '  alias cntools_child_alias='\''true'\''' \
      '  set +e +u +f' \
      '  set +o pipefail' \
      '  shopt -s nullglob dotglob' \
      '  IFS=:' \
      '  set -- child positional state' \
      '  trap '\'' :'\'' HUP INT TERM EXIT ERR DEBUG' \
      '  cd / || return 73' \
      '  umask 000' \
      '  exec 8>&-' \
      '  exec 9>"${result_file}.fd9"' \
      '  return 0' \
      '}'
  } > "${target}"
  chmod 444 "${target}"
}

write_postprocess_isolation_action() {
  local target="$1"

  {
    builtin printf '%s\n' '#!/usr/bin/env bash' \
      'cntools_action_main() {' \
      '  local context_file="${1:-}" result_file="${2:-}"' \
      '  [[ -n "${context_file}" && -n "${result_file}" ]] || builtin exit 64' \
      '  cntools_result_validate() { builtin return 0; }' \
      '  rm_path="/action/replaced/runner/tool"' \
      '  action_status=0' \
      '  IFS=:' \
      '  set +e +u +f' \
      '  set +o pipefail' \
      '  shopt -s nullglob dotglob' \
      "  trap ':' HUP INT TERM EXIT ERR DEBUG RETURN" \
      '  umask 077' \
      "  builtin printf '%s\\n' '{\"data\":{},\"schemaVersion\":1}' > \"\${result_file}\"" \
      '  builtin exit 22' \
      '}'
  } > "${target}"
  chmod 444 "${target}"
}

write_valid_result() {
  local target="$1"
  local nested="${2:-N}"

  if [[ "${nested}" == "Y" ]]; then
    jq -nS '{schemaVersion: 1, data: {items: [{id: "one"}], count: 1}}' > "${target}"
  else
    jq -nS '{schemaVersion: 1, data: {}}' > "${target}"
  fi
  chmod 600 "${target}"
}

run_outcome_contract() {
  local stdout_file="${TEST_ROOT}/outcome.stdout"
  local stderr_file="${TEST_ROOT}/outcome.stderr"
  local input="" expected_output="" expected_status=""

  while IFS='|' read -r input expected_output expected_status; do
    capture_call "${stdout_file}" "${stderr_file}" cntools_result_outcome "${input}"
    assert_status "${expected_status}" "outcome ${input}"
    assert_file_text "${stdout_file}" "${expected_output}"$'\n' "outcome ${input} stdout"
    assert_empty_file "${stderr_file}" "outcome ${input} stderr"
  done <<'EOF'
0|completed|0
20|home|0
21|refresh|0
22|exit|0
1|failure|1
2|failure|1
19|failure|1
23|failure|1
64|failure|1
69|failure|1
126|failure|1
127|failure|1
130|failure|1
255|failure|1
EOF

  for input in -1 text ' 20 ' 256 999999999999999999999; do
    capture_call "${stdout_file}" "${stderr_file}" cntools_result_outcome "${input}"
    assert_status 2 "invalid outcome ${input}"
    assert_empty_file "${stdout_file}" "invalid outcome ${input} stdout"
    assert_empty_file "${stderr_file}" "invalid outcome ${input} stderr"
  done

  capture_call "${stdout_file}" "${stderr_file}" cntools_result_outcome
  assert_status 2 'missing outcome'
  assert_empty_file "${stdout_file}" 'missing outcome stdout'
  assert_empty_file "${stderr_file}" 'missing outcome stderr'
}

run_existing_result_shape_contract() {
  local result_root="${FIXTURE_ROOT}/results"
  local stdout_file="${TEST_ROOT}/result.stdout"
  local stderr_file="${TEST_ROOT}/result.stderr"
  local result_file=""

  mkdir -p -- "${result_root}"
  chmod 700 "${result_root}"

  for result_file in valid nested; do
    write_valid_result "${result_root}/${result_file}.json" "$([[ "${result_file}" == nested ]] && printf Y || printf N)"
    capture_call "${stdout_file}" "${stderr_file}" \
      cntools_result_validate "${result_root}/${result_file}.json"
    assert_status 0 "${result_file} result"
    assert_empty_file "${stdout_file}" "${result_file} result stdout"
    assert_empty_file "${stderr_file}" "${result_file} result stderr"
  done

  builtin printf '%s\n' '{' > "${result_root}/malformed.json"
  builtin printf '%s\n' '{"schemaVersion":2,"data":{}}' > "${result_root}/wrong-schema.json"
  builtin printf '%s\n' '{"schemaVersion":1,"data":[],"extra":true}' > "${result_root}/wrong-shape.json"
  chmod 600 "${result_root}/"*.json
  mkdir "${result_root}/directory.json"
  ln -s -- "${result_root}/valid.json" "${result_root}/symlink.json"

  for result_file in malformed wrong-schema wrong-shape missing directory symlink; do
    capture_call "${stdout_file}" "${stderr_file}" \
      cntools_result_validate "${result_root}/${result_file}.json"
    [[ "${CALL_STATUS}" -ne 0 ]] || fail "${result_file} result unexpectedly validated"
    assert_empty_file "${stdout_file}" "${result_file} result stdout"
    assert_empty_file "${stderr_file}" "${result_file} result stderr"
  done
}

run_checked_in_inactivity_contract() {
  local context_file="$1"
  local stdout_file="${TEST_ROOT}/inert.stdout"
  local stderr_file="${TEST_ROOT}/inert.stderr"
  local result_file="${TEST_ROOT}/inert-result.json"
  local action_file="" action_directory="" direct_count=0
  local dispatcher_message='CNTools modular action execution is inactive during Stage 3 shadow mode.'
  local stub_message='CNTools action execution is inactive in Stage 3 shadow mode.'

  while IFS= read -r -d '' action_file; do
    direct_count=$((direct_count + 1))
    capture_call "${stdout_file}" "${stderr_file}" "${BASH}" "${action_file}"
    assert_status 64 "direct action ${action_file}"
    assert_empty_file "${stdout_file}" "direct action ${action_file} stdout"
    assert_file_text "${stderr_file}" \
      $'CNTools actions are launched by the dispatcher, not directly.\n' \
      "direct action ${action_file} stderr"
  done < <(find "${MODULES_ROOT}" -type f -name action.sh -print0 | sort -z)
  [[ "${direct_count}" -eq 54 ]] || fail "expected 54 guarded actions, found ${direct_count}"

  action_directory="$(stage4_inactive_action_directory)" ||
    fail 'no ledger-confirmed inactive action is available for probing'
  capture_call "${stdout_file}" "${stderr_file}" cntools_dispatcher_run_action \
    "${action_directory}" "${context_file}" "${result_file}"
  assert_status 69 'checked-in action remains inactive'
  assert_empty_file "${stdout_file}" 'checked-in inactive action stdout'
  if ! grep -Fqx -- "${dispatcher_message}" "${stderr_file}" &&
     ! grep -Fqx -- "${stub_message}" "${stderr_file}"; then
    fail 'checked-in inactive action diagnostic changed'
  fi
  assert_absent "${result_file}"
}

run_first_future_action_contract() {
  local context_file="$1"
  local action_directory="${FIXTURE_ROOT}/success-action"
  local source_log="${TEST_ROOT}/success.source"
  local main_log="${TEST_ROOT}/success.main"
  local arguments_file="${TEST_ROOT}/success.arguments"
  local expected_arguments="${TEST_ROOT}/success.arguments.expected"
  local result_file="${TEST_ROOT}/success.result.json"
  local stdout_file="${TEST_ROOT}/success.stdout"
  local stderr_file="${TEST_ROOT}/success.stderr"
  local bash_env_file="${TEST_ROOT}/hostile-bash-env"
  local bash_env_sentinel="${TEST_ROOT}/hostile-bash-env.executed"
  local source_shadow_sentinel="${TEST_ROOT}/hostile-source.executed"

  write_module "${action_directory}"
  write_success_action "${action_directory}/action.sh" "${source_log}" "${main_log}"
  builtin printf 'builtin printf hostile > %q\n' "${bash_env_sentinel}" > "${bash_env_file}"
  chmod 444 "${bash_env_file}"

  CNTOOLS_COMPAT_VALUE=visible
  cntools_compat_probe() { builtin printf 'compat-function\n'; }
  cntools_action_main() {
    builtin printf hostile > "${TEST_ROOT}/inherited-main.executed"
    return 99
  }
  source() {
    builtin printf hostile > "${source_shadow_sentinel}"
    return 98
  }
  export BASH_ENV="${bash_env_file}"
  export ENV="${bash_env_file}"
  export CNTOOLS_ACTION_DIRECTORY="${TEST_ROOT}/ambient-action"
  export CNTOOLS_CONTEXT_FILE="${TEST_ROOT}/ambient-context"
  export CNTOOLS_RESULT_FILE="${TEST_ROOT}/ambient-result"

  capture_call "${stdout_file}" "${stderr_file}" cntools_dispatcher_run_action \
    "${action_directory}" "${context_file}" "${result_file}" \
    "${arguments_file}" '' 'two words' '*' '--' $'line one\nline two'

  unset BASH_ENV ENV CNTOOLS_ACTION_DIRECTORY CNTOOLS_CONTEXT_FILE \
    CNTOOLS_RESULT_FILE
  unset -f source cntools_action_main cntools_compat_probe
  unset CNTOOLS_COMPAT_VALUE

  if [[ "${CALL_STATUS}" -eq 69 ]] &&
     grep -Fqx -- \
       'CNTools modular action execution is inactive during Stage 3 shadow mode.' \
       "${stderr_file}"; then
    assert_empty_file "${stdout_file}" 'unimplemented compatibility runner stdout'
    assert_absent "${source_log}"
    assert_absent "${main_log}"
    assert_absent "${result_file}"
    assert_absent "${bash_env_sentinel}"
    assert_absent "${source_shadow_sentinel}"
    fail 'compatibility execution is not implemented (shadow dispatcher returned 69)'
  fi

  assert_status 0 'synthetic compatibility action'
  assert_file_text "${stdout_file}" 'synthetic-stdout' 'synthetic action stdout'
  assert_file_text "${stderr_file}" 'synthetic-stderr' 'synthetic action stderr'
  assert_file_text "${source_log}" $'source\n' 'synthetic source count'
  assert_file_text "${main_log}" $'main\n' 'synthetic main count'
  assert_absent "${TEST_ROOT}/inherited-main.executed"
  assert_absent "${bash_env_sentinel}"
  assert_absent "${source_shadow_sentinel}"
  assert_absent "${TEST_ROOT}/ambient-action"
  assert_absent "${TEST_ROOT}/ambient-context"
  assert_absent "${TEST_ROOT}/ambient-result"

  builtin printf '%s\0' "${context_file}" "${result_file}" '' 'two words' '*' \
    '--' $'line one\nline two' > "${expected_arguments}"
  cmp -s -- "${expected_arguments}" "${arguments_file}" ||
    fail 'context, result, or action arguments changed in transit'
  cntools_result_validate "${result_file}" || fail 'synthetic result was not valid'
}

run_status_and_stream_contract() {
  local context_file="$1"
  local action_directory="${FIXTURE_ROOT}/status-action"
  local stdout_file="${TEST_ROOT}/status.stdout"
  local stderr_file="${TEST_ROOT}/status.stderr"
  local result_file="" status=""

  write_module "${action_directory}"
  write_status_action "${action_directory}/action.sh"

  for status in 0 20 21 22 1 19 23 64 69 126 127 130 255; do
    result_file="${TEST_ROOT}/status-${status}.result.json"
    capture_call "${stdout_file}" "${stderr_file}" cntools_dispatcher_run_action \
      "${action_directory}" "${context_file}" "${result_file}" "${status}"
    assert_status "${status}" "raw action status ${status}"
    assert_file_text "${stdout_file}" "stdout:${status}" "status ${status} stdout"
    assert_file_text "${stderr_file}" "stderr:${status}" "status ${status} stderr"
    assert_absent "${result_file}"
  done
}

run_result_security_contract() {
  local context_file="$1"
  local result_root="${FIXTURE_ROOT}/secure-results"
  local action_directory="${FIXTURE_ROOT}/result-action"
  local stdout_file="${TEST_ROOT}/secure-result.stdout"
  local stderr_file="${TEST_ROOT}/secure-result.stderr"
  local valid="${result_root}/valid.json"
  local candidate="${result_root}/candidate.json"
  local item=""

  mkdir -p -- "${result_root}"
  chmod 700 "${result_root}"
  write_module "${action_directory}"
  write_result_copy_action "${action_directory}/action.sh"
  write_valid_result "${valid}" Y

  # The optional structured result is trusted only in canonical, private form.
  cntools_result_validate "${valid}" || fail 'canonical private result was rejected'

  builtin printf '%s\n' '{"data":{},"schemaVersion":1}' > "${result_root}/noncanonical.json"
  builtin printf '%s\n' '{"data":{},"schemaVersion":1,"schemaVersion":1}' > "${result_root}/duplicate.json"
  cp -- "${valid}" "${result_root}/unsafe-mode.json"
  chmod 644 "${result_root}/unsafe-mode.json"
  ln -- "${valid}" "${result_root}/hardlink.json"
  ln -s -- "${valid}" "${result_root}/symlink.json"
  mkdir "${result_root}/unsafe-parent"
  chmod 755 "${result_root}/unsafe-parent"
  cp -- "${valid}" "${result_root}/unsafe-parent/result.json"
  chmod 600 "${result_root}/unsafe-parent/result.json"
  mkdir "${result_root}/real-parent"
  chmod 700 "${result_root}/real-parent"
  cp -- "${valid}" "${result_root}/real-parent/result.json"
  chmod 600 "${result_root}/real-parent/result.json"
  ln -s -- "${result_root}/real-parent" "${result_root}/linked-parent"
  {
    builtin printf '%s\n' '{' '  "data": {'
    builtin printf '%s' '    "payload": "'
    head -c 1048577 /dev/zero | tr '\0' a
    builtin printf '%s\n' '"' '  },' '  "schemaVersion": 1' '}'
  } > "${result_root}/oversized.json"
  chmod 600 "${result_root}/noncanonical.json" "${result_root}/duplicate.json" \
    "${result_root}/symlink.json" "${result_root}/oversized.json" 2>/dev/null || true

  for item in noncanonical duplicate unsafe-mode hardlink symlink oversized; do
    if cntools_result_validate "${result_root}/${item}.json" >/dev/null 2>&1; then
      fail "unsafe ${item} result validated"
    fi
  done
  if cntools_result_validate "${result_root}/linked-parent/result.json" >/dev/null 2>&1; then
    fail 'result beneath a symlink ancestor validated'
  fi
  if cntools_result_validate "${result_root}/unsafe-parent/result.json" >/dev/null 2>&1; then
    fail 'result beneath a nonprivate parent validated'
  fi

  cp -- "${result_root}/noncanonical.json" "${result_root}/action-input.json"
  chmod 600 "${result_root}/action-input.json"
  capture_call "${stdout_file}" "${stderr_file}" cntools_dispatcher_run_action \
    "${action_directory}" "${context_file}" "${candidate}" \
    "${result_root}/action-input.json"
  assert_status 70 'unsafe action result'
  assert_empty_file "${stdout_file}" 'unsafe action result stdout'
  assert_file_text "${stderr_file}" \
    $'CNTools compatibility action produced an unsafe result.\n' \
    'unsafe action result stderr'
  assert_absent "${candidate}"
}

assert_validation_failure() {
  local action_directory="$1"
  local context_file="$2"
  local result_file="$3"
  local source_sentinel="$4"
  local main_sentinel="$5"
  local secret="stage4-secret-sentinel"
  local stdout_file="${TEST_ROOT}/validation.stdout"
  local stderr_file="${TEST_ROOT}/validation.stderr"

  capture_call "${stdout_file}" "${stderr_file}" cntools_dispatcher_run_action \
    "${action_directory}" "${context_file}" "${result_file}" "${secret}"
  assert_status 70 "validation failure ${action_directory}"
  assert_empty_file "${stdout_file}" "validation failure ${action_directory} stdout"
  assert_file_text "${stderr_file}" \
    $'CNTools compatibility action failed validation.\n' \
    "validation failure ${action_directory} stderr"
  grep -Fq -- "${secret}" "${stderr_file}" &&
    fail 'validation diagnostic disclosed an action argument'
  [[ -z "${source_sentinel}" ]] || assert_absent "${source_sentinel}"
  [[ -z "${main_sentinel}" ]] || assert_absent "${main_sentinel}"
}

run_fail_before_source_contract() {
  local valid_context="$1"
  local invalid_root="${FIXTURE_ROOT}/invalid"
  local valid_action="${invalid_root}/valid"
  local source_sentinel="${TEST_ROOT}/invalid.source"
  local main_sentinel="${TEST_ROOT}/invalid.main"
  local result_file="${TEST_ROOT}/invalid.result.json"
  local invalid_context="${invalid_root}/invalid-context.json"
  local offline_context="${invalid_root}/offline-context.json"
  local action_directory=""

  mkdir -p -- "${invalid_root}"
  chmod 700 "${invalid_root}"
  write_module "${valid_action}"
  write_probe_action "${valid_action}/action.sh" "${source_sentinel}" "${main_sentinel}"

  assert_validation_failure "" "${valid_context}" "${result_file}" "" ""
  assert_validation_failure "relative-action" "${valid_context}" "${result_file}" "" ""
  assert_validation_failure "${invalid_root}/missing" "${valid_context}" "${result_file}" "" ""
  assert_validation_failure "${valid_action}" "" "${result_file}" \
    "${source_sentinel}" "${main_sentinel}"
  assert_validation_failure "${valid_action}" 'relative-context.json' "${result_file}" \
    "${source_sentinel}" "${main_sentinel}"
  cp -- "${valid_context}" "${invalid_root}/relative-context.json"
  chmod 400 "${invalid_root}/relative-context.json"
  (
    cd "${invalid_root}"
    assert_validation_failure "${valid_action}" 'relative-context.json' \
      "${result_file}" "${source_sentinel}" "${main_sentinel}"
  )
  assert_validation_failure "${valid_action}" "${valid_context}" "" \
    "${source_sentinel}" "${main_sentinel}"

  ln -s -- "${valid_action}" "${invalid_root}/linked-action"
  assert_validation_failure "${invalid_root}/linked-action" "${valid_context}" \
    "${result_file}" "${source_sentinel}" "${main_sentinel}"

  action_directory="${invalid_root}/linked-entrypoint"
  write_module "${action_directory}"
  ln -s -- "${valid_action}/action.sh" "${action_directory}/action.sh"
  assert_validation_failure "${action_directory}" "${valid_context}" "${result_file}" \
    "${source_sentinel}" "${main_sentinel}"

  action_directory="${invalid_root}/missing-entrypoint"
  write_module "${action_directory}"
  assert_validation_failure "${action_directory}" "${valid_context}" "${result_file}" "" ""

  action_directory="${invalid_root}/malformed-metadata"
  write_module "${action_directory}"
  chmod 644 "${action_directory}/module.json"
  builtin printf '%s\n' '{' > "${action_directory}/module.json"
  chmod 444 "${action_directory}/module.json"
  write_probe_action "${action_directory}/action.sh" "${source_sentinel}" "${main_sentinel}"
  assert_validation_failure "${action_directory}" "${valid_context}" "${result_file}" \
    "${source_sentinel}" "${main_sentinel}"

  action_directory="${invalid_root}/wrong-api"
  write_module "${action_directory}" '.runtime.apiVersion = 2'
  write_probe_action "${action_directory}/action.sh" "${source_sentinel}" "${main_sentinel}"
  assert_validation_failure "${action_directory}" "${valid_context}" "${result_file}" \
    "${source_sentinel}" "${main_sentinel}"

  action_directory="${invalid_root}/missing-main"
  write_module "${action_directory}"
  builtin printf '%s\n' '#!/usr/bin/env bash' \
    "builtin printf source > $(builtin printf '%q' "${source_sentinel}")" \
    'different_main() { :; }' > "${action_directory}/action.sh"
  chmod 444 "${action_directory}/action.sh"
  assert_validation_failure "${action_directory}" "${valid_context}" "${result_file}" \
    "${source_sentinel}" "${main_sentinel}"

  action_directory="${invalid_root}/syntax-error"
  write_module "${action_directory}"
  builtin printf '%s\n' '#!/usr/bin/env bash' \
    "builtin printf source > $(builtin printf '%q' "${source_sentinel}")" \
    'cntools_action_main() {' '  if true; then' '}' > "${action_directory}/action.sh"
  chmod 444 "${action_directory}/action.sh"
  assert_validation_failure "${action_directory}" "${valid_context}" "${result_file}" \
    "${source_sentinel}" "${main_sentinel}"

  builtin printf '%s\n' '{"schemaVersion":1}' > "${invalid_context}"
  chmod 400 "${invalid_context}"
  assert_validation_failure "${valid_action}" "${invalid_context}" "${result_file}" \
    "${source_sentinel}" "${main_sentinel}"
  ln -s -- "${valid_context}" "${invalid_root}/linked-context.json"
  assert_validation_failure "${valid_action}" "${invalid_root}/linked-context.json" \
    "${result_file}" "${source_sentinel}" "${main_sentinel}"
  mkdir "${invalid_root}/real-context-parent"
  cp -- "${valid_context}" "${invalid_root}/real-context-parent/context.json"
  chmod 400 "${invalid_root}/real-context-parent/context.json"
  ln -s -- "${invalid_root}/real-context-parent" "${invalid_root}/linked-context-parent"
  assert_validation_failure "${valid_action}" \
    "${invalid_root}/linked-context-parent/context.json" "${result_file}" \
    "${source_sentinel}" "${main_sentinel}"

  action_directory="${invalid_root}/local-only"
  write_module "${action_directory}" '.executionRequirements.modes = ["local"]'
  write_probe_action "${action_directory}/action.sh" "${source_sentinel}" "${main_sentinel}"
  write_context "${offline_context}" offline
  assert_validation_failure "${action_directory}" "${offline_context}" "${result_file}" \
    "${source_sentinel}" "${main_sentinel}"

  write_valid_result "${invalid_root}/preexisting-result.json"
  assert_validation_failure "${valid_action}" "${valid_context}" \
    "${invalid_root}/preexisting-result.json" "${source_sentinel}" "${main_sentinel}"
  ln -s -- "${invalid_root}/preexisting-result.json" \
    "${invalid_root}/preexisting-result-link.json"
  assert_validation_failure "${valid_action}" "${valid_context}" \
    "${invalid_root}/preexisting-result-link.json" "${source_sentinel}" "${main_sentinel}"
  assert_validation_failure "${valid_action}" "${valid_context}" \
    'relative-result.json' "${source_sentinel}" "${main_sentinel}"
  mkdir "${invalid_root}/real-result-parent"
  ln -s -- "${invalid_root}/real-result-parent" "${invalid_root}/linked-result-parent"
  assert_validation_failure "${valid_action}" "${valid_context}" \
    "${invalid_root}/linked-result-parent/result.json" \
    "${source_sentinel}" "${main_sentinel}"
  mkdir "${invalid_root}/nonprivate-result-parent"
  chmod 755 "${invalid_root}/nonprivate-result-parent"
  assert_validation_failure "${valid_action}" "${valid_context}" \
    "${invalid_root}/nonprivate-result-parent/result.json" \
    "${source_sentinel}" "${main_sentinel}"
}

run_source_failure_contract() {
  local context_file="$1"
  local action_directory="${FIXTURE_ROOT}/source-failure"
  local source_sentinel="${TEST_ROOT}/source-failure.source"
  local main_sentinel="${TEST_ROOT}/source-failure.main"
  local stdout_file="${TEST_ROOT}/source-failure.stdout"
  local stderr_file="${TEST_ROOT}/source-failure.stderr"
  local result_file="${TEST_ROOT}/source-failure.result.json"

  write_module "${action_directory}"
  {
    builtin printf '%s\n' '#!/usr/bin/env bash'
    builtin printf "builtin printf 'source\\n' >> %q\n" "${source_sentinel}"
    builtin printf '%s\n' 'cntools_action_main() {'
    builtin printf "  builtin printf 'main\\n' >> %q\n" "${main_sentinel}"
    builtin printf '%s\n' '  return 0' '}' 'return 77'
  } > "${action_directory}/action.sh"
  chmod 444 "${action_directory}/action.sh"

  capture_call "${stdout_file}" "${stderr_file}" cntools_dispatcher_run_action \
    "${action_directory}" "${context_file}" "${result_file}"
  assert_status 70 'action source failure'
  assert_empty_file "${stdout_file}" 'action source failure stdout'
  assert_file_text "${stderr_file}" \
    $'CNTools compatibility action could not be loaded.\n' \
    'action source failure stderr'
  assert_file_text "${source_sentinel}" $'source\n' 'source failure source count'
  assert_absent "${main_sentinel}"
  assert_absent "${result_file}"
}

run_parent_isolation_contract() (
  set -euo pipefail

  local context_file="$1"
  local action_directory="${FIXTURE_ROOT}/isolation-action"
  local result_file="${TEST_ROOT}/isolation.result.json"
  local stdout_file="${TEST_ROOT}/isolation.stdout"
  local stderr_file="${TEST_ROOT}/isolation.stderr"
  local before_root="${TEST_ROOT}/isolation.before"
  local after_root="${TEST_ROOT}/isolation.after"
  local fd8_file="${TEST_ROOT}/isolation.fd8"
  local source_shadow_sentinel="${TEST_ROOT}/isolation.source-shadow"
  local postprocess_action="${FIXTURE_ROOT}/postprocess-isolation-action"
  local postprocess_result="${TEST_ROOT}/postprocess-isolation.result.json"
  local postprocess_stdout="${TEST_ROOT}/postprocess-isolation.stdout"
  local postprocess_stderr="${TEST_ROOT}/postprocess-isolation.stderr"

  write_module "${action_directory}"
  write_isolation_action "${action_directory}/action.sh"
  write_module "${postprocess_action}"
  write_postprocess_isolation_action "${postprocess_action}/action.sh"

  CNTOOLS_PARENT_SCALAR=parent
  CNTOOLS_PARENT_INDEXED=(parent one)
  declare -A CNTOOLS_PARENT_ASSOC=([parent]=one)
  export CNTOOLS_PARENT_EXPORTED=parent
  export BASH_ENV="${TEST_ROOT}/parent-bash-env"
  export ENV="${TEST_ROOT}/parent-env"
  export CNTOOLS_ACTION_DIRECTORY="${TEST_ROOT}/parent-action"
  export CNTOOLS_CONTEXT_FILE="${TEST_ROOT}/parent-context"
  export CNTOOLS_RESULT_FILE="${TEST_ROOT}/parent-result"
  cntools_parent_function() { builtin printf 'parent\n'; }
  cntools_action_main() { return 99; }
  source() {
    builtin printf hostile > "${source_shadow_sentinel}"
    return 98
  }
  shopt -s expand_aliases
  alias cntools_parent_alias='true'
  set -- 'parent one' '' '*'
  IFS=$' \t\n|'
  set -f
  shopt -s extglob
  trap ':' HUP INT TERM ERR DEBUG
  umask 027
  exec 8> "${fd8_file}"
  exec 9>&-

  mkdir -p -- "${before_root}" "${after_root}"
  declare -p CNTOOLS_PARENT_SCALAR CNTOOLS_PARENT_INDEXED CNTOOLS_PARENT_ASSOC \
    CNTOOLS_PARENT_EXPORTED BASH_ENV ENV CNTOOLS_ACTION_DIRECTORY \
    CNTOOLS_CONTEXT_FILE CNTOOLS_RESULT_FILE > "${before_root}/variables"
  declare -f cntools_parent_function cntools_action_main source > "${before_root}/functions"
  alias -p > "${before_root}/aliases"
  set +o > "${before_root}/set"
  shopt -p > "${before_root}/shopt"
  trap -p HUP INT TERM EXIT ERR DEBUG > "${before_root}/traps"
  builtin printf '%q\n' "${IFS}" > "${before_root}/ifs"
  builtin printf '%q\0' "$@" > "${before_root}/positionals"
  pwd -P > "${before_root}/pwd"
  umask > "${before_root}/umask"

  if cntools_dispatcher_run_action "${action_directory}" "${context_file}" \
      "${result_file}" > "${stdout_file}" 2> "${stderr_file}"; then
    CALL_STATUS=0
  else
    CALL_STATUS=$?
  fi
  assert_status 0 'parent isolation action'
  assert_empty_file "${stdout_file}" 'parent isolation stdout'
  assert_empty_file "${stderr_file}" 'parent isolation stderr'
  assert_absent "${source_shadow_sentinel}"

  if cntools_dispatcher_run_action "${postprocess_action}" "${context_file}" \
      "${postprocess_result}" > "${postprocess_stdout}" 2> "${postprocess_stderr}"; then
    CALL_STATUS=0
  else
    CALL_STATUS=$?
  fi
  assert_status 70 'post-processing isolation action'
  assert_empty_file "${postprocess_stdout}" 'post-processing isolation stdout'
  assert_file_text "${postprocess_stderr}" \
    $'CNTools compatibility action produced an unsafe result.\n' \
    'post-processing isolation stderr'
  assert_absent "${postprocess_result}"

  declare -p CNTOOLS_PARENT_SCALAR CNTOOLS_PARENT_INDEXED CNTOOLS_PARENT_ASSOC \
    CNTOOLS_PARENT_EXPORTED BASH_ENV ENV CNTOOLS_ACTION_DIRECTORY \
    CNTOOLS_CONTEXT_FILE CNTOOLS_RESULT_FILE > "${after_root}/variables"
  declare -f cntools_parent_function cntools_action_main source > "${after_root}/functions"
  alias -p > "${after_root}/aliases"
  set +o > "${after_root}/set"
  shopt -p > "${after_root}/shopt"
  trap -p HUP INT TERM EXIT ERR DEBUG > "${after_root}/traps"
  builtin printf '%q\n' "${IFS}" > "${after_root}/ifs"
  builtin printf '%q\0' "$@" > "${after_root}/positionals"
  pwd -P > "${after_root}/pwd"
  umask > "${after_root}/umask"

  for item in variables functions aliases set shopt traps ifs positionals pwd umask; do
    cmp -s -- "${before_root}/${item}" "${after_root}/${item}" ||
      fail "parent ${item} leaked across compatibility subshell"
  done
  [[ -z "${CNTOOLS_CHILD_EXPORTED+x}" ]] || fail 'child export leaked to parent'
  ! declare -F cntools_child_function >/dev/null 2>&1 || fail 'child function leaked to parent'
  ! alias cntools_child_alias >/dev/null 2>&1 || fail 'child alias leaked to parent'
  builtin printf 'parent-fd-open\n' >&8
  if (exec 2>/dev/null; : >&9); then fail 'child file descriptor leaked to parent'; fi
  assert_file_text "${fd8_file}" $'parent-fd-open\n' 'parent file descriptor'
)

CONTEXT_FILE="${FIXTURE_ROOT}/context.json"
write_context "${CONTEXT_FILE}" local

if grep -Fq 'cntools_dispatcher_run_action' "${BOOTSTRAP_SOURCE}"; then
  fail 'public modular bootstrap can reach compatibility action execution'
fi

case "${FOCUS}" in
  current)
    run_outcome_contract
    run_existing_result_shape_contract
    run_checked_in_inactivity_contract "${CONTEXT_FILE}"
    printf 'CNTools Stage 4 current safety contracts passed\n'
    ;;
  transport)
    run_first_future_action_contract "${CONTEXT_FILE}"
    run_status_and_stream_contract "${CONTEXT_FILE}"
    printf 'CNTools Stage 4 runner transport contracts passed\n'
    ;;
  security)
    run_result_security_contract "${CONTEXT_FILE}"
    run_fail_before_source_contract "${CONTEXT_FILE}"
    run_source_failure_contract "${CONTEXT_FILE}"
    printf 'CNTools Stage 4 runner security contracts passed\n'
    ;;
  isolation)
    run_parent_isolation_contract "${CONTEXT_FILE}"
    printf 'CNTools Stage 4 runner isolation contracts passed\n'
    ;;
  all)
    run_outcome_contract
    run_existing_result_shape_contract
    run_checked_in_inactivity_contract "${CONTEXT_FILE}"
    run_first_future_action_contract "${CONTEXT_FILE}"
    # The default suite becomes a workflow gate only after every focus is green.
    run_status_and_stream_contract "${CONTEXT_FILE}"
    run_result_security_contract "${CONTEXT_FILE}"
    run_fail_before_source_contract "${CONTEXT_FILE}"
    run_source_failure_contract "${CONTEXT_FILE}"
    run_parent_isolation_contract "${CONTEXT_FILE}"
    printf 'CNTools Stage 4 compatibility runner tests passed\n'
    ;;
  *)
    fail "unknown CNTOOLS_STAGE4_COMPAT_FOCUS: ${FOCUS}"
    ;;
esac
