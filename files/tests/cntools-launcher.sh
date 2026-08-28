#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
LAUNCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-launcher.XXXXXX")"
INSTALL_ROOT="${TEST_ROOT}/installed node"
SCRIPTS_DIR="${INSTALL_ROOT}/scripts"
APP_DIR="${SCRIPTS_DIR}/cntools"
LAUNCHER="${SCRIPTS_DIR}/cntools.sh"
CALLER_DIR="${TEST_ROOT}/caller"
CAPTURE_DIR="${TEST_ROOT}/capture"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local value="$1"
  local expected="$2"
  local context="$3"

  [[ "${value}" == *"${expected}"* ]] ||
    fail "${context}: expected '${expected}' in '${value}'"
}

run_rejected() {
  local launcher="$1"
  local expected="$2"
  local context="$3"
  local expect_recovery="${4:-Y}"
  local launcher_parent=""
  local output=""

  if output="$(cd "${CALLER_DIR}" && "${launcher}" 2>&1)"; then
    fail "${context} was accepted"
  fi
  assert_contains "${output}" "${expected}" "${context}"
  if [[ "${expect_recovery}" == "Y" ]]; then
    launcher_parent="$(cd "$(dirname "${launcher}")" && pwd -P)"
    assert_contains "${output}" \
      "re-run ${launcher_parent}/guild-deploy.sh" \
      "${context} recovery guidance"
  fi
}

write_main() {
  local destination="$1"

  mkdir -p "$(dirname "${destination}")"
  cat > "${destination}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "${LAUNCH_CAPTURE}/pid"
pwd -P > "${LAUNCH_CAPTURE}/cwd"
printf '%s\0' "$@" > "${LAUNCH_CAPTURE}/argv"
printf 'invoked\n' > "${LAUNCH_CAPTURE}/invoked"
exit "${LAUNCH_EXIT_STATUS:-0}"
EOF
  chmod 0755 "${destination}"
}

mkdir -p "${APP_DIR}" "${CALLER_DIR}" "${CAPTURE_DIR}"
cp -- "${LAUNCHER_SOURCE}" "${LAUNCHER}"
chmod 0755 "${LAUNCHER}"
write_main "${APP_DIR}/cntools_main.sh"
SCRIPTS_PHYSICAL="$(cd "${SCRIPTS_DIR}" && pwd -P)"

source_output="$(
  bash -c '
    source "$1"
    source_status=$?
    printf "source-status=%s\n" "${source_status}"
  ' _ "${LAUNCHER}" 2>&1
)"
assert_contains "${source_output}" "must be executed, not sourced" \
  "sourced launcher rejection"
assert_contains "${source_output}" "source-status=1" \
  "sourced launcher return status"

HOSTILE_ROOT="${TEST_ROOT}/hostile-root"
mkdir -p "${HOSTILE_ROOT}"
cat > "${HOSTILE_ROOT}/cntools_main.sh" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
chmod 0755 "${HOSTILE_ROOT}/cntools_main.sh"

expected_args=(
  "simple"
  "two words"
  '*?[brackets]'
  ""
  "--"
  "-n"
  $'line one\nline two'
)
printf '%s\0' "${expected_args[@]}" > "${TEST_ROOT}/expected-argv"
rm -f -- "${CAPTURE_DIR}"/*
pushd "${CALLER_DIR}" >/dev/null
CNTOOLS_ROOT="${HOSTILE_ROOT}" \
LAUNCH_CAPTURE="${CAPTURE_DIR}" \
LAUNCH_EXIT_STATUS=37 \
  "${LAUNCHER}" "${expected_args[@]}" &
launcher_pid=$!
popd >/dev/null
if wait "${launcher_pid}"; then
  launcher_status=0
else
  launcher_status=$?
fi
[[ "${launcher_status}" = "37" ]] ||
  fail "launcher did not preserve the main entrypoint status"
[[ "$(< "${CAPTURE_DIR}/pid")" = "${launcher_pid}" ]] ||
  fail "launcher did not exec the main entrypoint in place"
[[ "$(< "${CAPTURE_DIR}/cwd")" = "${SCRIPTS_PHYSICAL}" ]] ||
  fail "launcher did not enter its stable physical scripts directory"
cmp -s "${CAPTURE_DIR}/argv" "${TEST_ROOT}/expected-argv" ||
  fail "launcher did not preserve the exact argument vector"
[[ -f "${CAPTURE_DIR}/invoked" ]] ||
  fail "launcher followed hostile CNTOOLS_ROOT instead of its own location"

rm -f -- "${CAPTURE_DIR}"/*
inside_output="$(
  cd "${APP_DIR}"
  "${LAUNCHER}" 2>&1
)" || true
assert_contains "${inside_output}" "inside the managed CNTools directory" \
  "application-root cwd rejection"
assert_contains "${inside_output}" "change to ${SCRIPTS_PHYSICAL}" \
  "application-root cwd guidance"
[[ ! -e "${CAPTURE_DIR}/invoked" ]] ||
  fail "launcher invoked CNTools from inside the managed application root"

mkdir -p "${APP_DIR}/modules/nested"
rm -f -- "${CAPTURE_DIR}"/*
nested_output="$(
  cd "${APP_DIR}/modules/nested"
  "${LAUNCHER}" 2>&1
)" || true
assert_contains "${nested_output}" "inside the managed CNTools directory" \
  "application-descendant cwd rejection"
[[ ! -e "${CAPTURE_DIR}/invoked" ]] ||
  fail "launcher invoked CNTools from inside a managed application descendant"

ln -s -- "${APP_DIR}/modules/nested" "${TEST_ROOT}/linked-cwd"
linked_output="$(
  cd "${TEST_ROOT}/linked-cwd"
  "${LAUNCHER}" 2>&1
)" || true
assert_contains "${linked_output}" "inside the managed CNTools directory" \
  "physical symlink cwd rejection"

INVALID_ROOT="${TEST_ROOT}/invalid installs"
mkdir -p "${INVALID_ROOT}"
command -v mkfifo >/dev/null 2>&1 ||
  fail "mkfifo is required for special-file launcher validation"

missing_scripts="${INVALID_ROOT}/missing/scripts"
mkdir -p "${missing_scripts}/cntools"
cp -- "${LAUNCHER_SOURCE}" "${missing_scripts}/cntools.sh"
chmod 0755 "${missing_scripts}/cntools.sh"
run_rejected "${missing_scripts}/cntools.sh" \
  "application entrypoint is missing or unsafe" "missing main entrypoint"

empty_scripts="${INVALID_ROOT}/empty/scripts"
mkdir -p "${empty_scripts}/cntools"
cp -- "${LAUNCHER_SOURCE}" "${empty_scripts}/cntools.sh"
: > "${empty_scripts}/cntools/cntools_main.sh"
chmod 0755 "${empty_scripts}/cntools.sh" \
  "${empty_scripts}/cntools/cntools_main.sh"
run_rejected "${empty_scripts}/cntools.sh" \
  "application entrypoint is missing or unsafe" "empty main entrypoint"

symlink_main_scripts="${INVALID_ROOT}/symlink-main/scripts"
mkdir -p "${symlink_main_scripts}/cntools" "${symlink_main_scripts}/real"
cp -- "${LAUNCHER_SOURCE}" "${symlink_main_scripts}/cntools.sh"
write_main "${symlink_main_scripts}/real/cntools_main.sh"
ln -s -- "${symlink_main_scripts}/real/cntools_main.sh" \
  "${symlink_main_scripts}/cntools/cntools_main.sh"
chmod 0755 "${symlink_main_scripts}/cntools.sh"
run_rejected "${symlink_main_scripts}/cntools.sh" \
  "application entrypoint is missing or unsafe" "symlink main entrypoint"

directory_main_scripts="${INVALID_ROOT}/directory-main/scripts"
mkdir -p "${directory_main_scripts}/cntools/cntools_main.sh"
cp -- "${LAUNCHER_SOURCE}" "${directory_main_scripts}/cntools.sh"
chmod 0755 "${directory_main_scripts}/cntools.sh"
run_rejected "${directory_main_scripts}/cntools.sh" \
  "application entrypoint is missing or unsafe" "directory main entrypoint"

nonexec_scripts="${INVALID_ROOT}/nonexec/scripts"
mkdir -p "${nonexec_scripts}/cntools"
cp -- "${LAUNCHER_SOURCE}" "${nonexec_scripts}/cntools.sh"
write_main "${nonexec_scripts}/cntools/cntools_main.sh"
chmod 0644 "${nonexec_scripts}/cntools/cntools_main.sh"
chmod 0755 "${nonexec_scripts}/cntools.sh"
run_rejected "${nonexec_scripts}/cntools.sh" \
  "application entrypoint is missing or unsafe" "non-executable main entrypoint"

fifo_scripts="${INVALID_ROOT}/fifo-main/scripts"
mkdir -p "${fifo_scripts}/cntools"
cp -- "${LAUNCHER_SOURCE}" "${fifo_scripts}/cntools.sh"
mkfifo "${fifo_scripts}/cntools/cntools_main.sh"
chmod 0755 "${fifo_scripts}/cntools.sh"
run_rejected "${fifo_scripts}/cntools.sh" \
  "application entrypoint is missing or unsafe" "FIFO main entrypoint"

symlink_app_scripts="${INVALID_ROOT}/symlink-app/scripts"
mkdir -p "${symlink_app_scripts}/real-cntools"
cp -- "${LAUNCHER_SOURCE}" "${symlink_app_scripts}/cntools.sh"
write_main "${symlink_app_scripts}/real-cntools/cntools_main.sh"
ln -s -- "${symlink_app_scripts}/real-cntools" \
  "${symlink_app_scripts}/cntools"
chmod 0755 "${symlink_app_scripts}/cntools.sh"
run_rejected "${symlink_app_scripts}/cntools.sh" \
  "managed application directory is missing or unsafe" \
  "symlink managed application directory"

symlink_launcher="${TEST_ROOT}/cntools-link"
ln -s -- "${LAUNCHER}" "${symlink_launcher}"
run_rejected "${symlink_launcher}" "launcher must not be a symbolic link" \
  "symlink public launcher" N

printf 'CNTools launcher tests passed\n'
