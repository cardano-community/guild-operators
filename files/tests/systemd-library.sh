#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/guild-systemd-library-test.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "${TEST_DIR}/bin" "${TEST_DIR}/units"
SYSTEMCTL_LOG="${TEST_DIR}/systemctl.log"
export SYSTEMCTL_LOG

# The single quotes intentionally defer expansion to the fake executable.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "${SYSTEMCTL_LOG:?}"' \
  'if [[ "${1:-}" == "disable" && "${3:-}" == "${SYSTEMCTL_FAIL_DISABLE_UNIT:-}" ]]; then exit 42; fi' \
  > "${TEST_DIR}/bin/systemctl"
chmod +x "${TEST_DIR}/bin/systemctl"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "sudo must not be called in the no-root test\n" >&2' \
  'exit 99' \
  > "${TEST_DIR}/bin/sudo"
chmod +x "${TEST_DIR}/bin/sudo"

export PATH="${TEST_DIR}/bin:${PATH}"
export SYSTEMD_UNIT_DIR="${TEST_DIR}/units"
export SYSTEMCTL_BIN="${TEST_DIR}/bin/systemctl"
export SUDO="N"

# shellcheck disable=SC1091
. "${REPO_ROOT}/scripts/common-helper-scripts/lib/systemd.library"

unit_name="guild-test.service"
unit_content=$'[Unit]\nDescription=Guild systemd helper test\n\n[Service]\nType=oneshot\nExecStart=/usr/bin/true'
owner_token="/opt/cardano/cnode/scripts/test-launcher.sh"
other_owner_token="/srv/cardano/cnode/scripts/test-launcher.sh"

systemd_install_unit "${unit_name}" "${unit_content}" "${owner_token}"
[[ -f "${SYSTEMD_UNIT_DIR}/${unit_name}" ]] || fail "unit was not installed"
grep -q '^Description=Guild systemd helper test$' "${SYSTEMD_UNIT_DIR}/${unit_name}" ||
  fail "installed unit content differs"
grep -Fqx "# X-Guild-Operators-Owner: ${owner_token}" \
  "${SYSTEMD_UNIT_DIR}/${unit_name}" ||
  fail "installed unit omitted its deployment-specific owner marker"

owned_content="$(cat "${SYSTEMD_UNIT_DIR}/${unit_name}")"
if systemd_install_unit \
  "${unit_name}" "${unit_content}" "${other_owner_token}" 2>/dev/null; then
  fail "same-name unit from another Guild deployment was overwritten"
fi
if systemd_remove_units \
  --owner-token "${other_owner_token}" "${unit_name}" 2>/dev/null; then
  fail "same-name unit from another Guild deployment was removed"
fi
[[ "$(cat "${SYSTEMD_UNIT_DIR}/${unit_name}")" == "${owned_content}" ]] ||
  fail "cross-deployment ownership rejection changed the unit"

systemd_daemon_reload
systemd_enable_units "${unit_name}"
systemd_status_units "${unit_name}"

grep -q '^daemon-reload$' "${SYSTEMCTL_LOG}" || fail "daemon-reload was not requested"
grep -q "^enable ${unit_name}$" "${SYSTEMCTL_LOG}" || fail "unit was not enabled"
grep -q "^--no-pager status ${unit_name}$" "${SYSTEMCTL_LOG}" || fail "unit status was not requested"

systemd_remove_units --owner-token "${owner_token}" "${unit_name}"
[[ ! -e "${SYSTEMD_UNIT_DIR}/${unit_name}" ]] || fail "unit was not removed"
grep -q "^disable --now ${unit_name}$" "${SYSTEMCTL_LOG}" || fail "unit was not disabled and stopped"

systemctl_before="$(cat "${SYSTEMCTL_LOG}")"
systemd_remove_units --owner-token "${owner_token}" "${unit_name}"
[[ "$(cat "${SYSTEMCTL_LOG}")" == "${systemctl_before}" ]] ||
  fail "missing expected unit caused an unverified same-name systemd mutation"

printf '%s\n' \
  '[Unit]' \
  'Description=Unrelated administrator service' \
  '[Service]' \
  'ExecStart=/usr/bin/sleep infinity' \
  > "${SYSTEMD_UNIT_DIR}/${unit_name}"
unmanaged_content="$(cat "${SYSTEMD_UNIT_DIR}/${unit_name}")"
if systemd_install_unit \
  "${unit_name}" "${unit_content}" "${owner_token}" 2>/dev/null; then
  fail "unmanaged unit was overwritten"
fi
if systemd_remove_units \
  --owner-token "${owner_token}" "${unit_name}" 2>/dev/null; then
  fail "unmanaged unit was removed"
fi
[[ "$(cat "${SYSTEMD_UNIT_DIR}/${unit_name}")" == "${unmanaged_content}" ]] ||
  fail "unmanaged unit content changed"

legacy_token="/opt/cardano/cnode/scripts/cnode.sh"
printf '%s\n' \
  '[Unit]' \
  'Description=Legacy Guild service' \
  '[Service]' \
  "ExecStart=/bin/bash -l -c \"exec ${legacy_token}\"" \
  > "${SYSTEMD_UNIT_DIR}/${unit_name}"
systemd_remove_units \
  --owner-token "${owner_token}" \
  --legacy-token "${legacy_token}" \
  "${unit_name}"
[[ ! -e "${SYSTEMD_UNIT_DIR}/${unit_name}" ]] ||
  fail "recognized legacy Guild unit was not removed"

systemd_install_unit "${unit_name}" "${unit_content}" "${owner_token}"
export SYSTEMCTL_FAIL_DISABLE_UNIT="${unit_name}"
if systemd_remove_units \
  --owner-token "${owner_token}" "${unit_name}" 2>/dev/null; then
  fail "unit removal ignored a stop/disable failure"
fi
[[ -f "${SYSTEMD_UNIT_DIR}/${unit_name}" ]] ||
  fail "unit file was deleted after stop/disable failed"
unset SYSTEMCTL_FAIL_DISABLE_UNIT
systemd_remove_units --owner-token "${owner_token}" "${unit_name}"

if systemd_install_unit \
  "../../escape.service" "invalid" "${owner_token}" 2>/dev/null; then
  fail "path traversal unit name was accepted"
fi
if systemd_install_unit \
  "missing-suffix" "invalid" "${owner_token}" 2>/dev/null; then
  fail "unsupported unit type was accepted"
fi
if systemd_install_unit \
  "missing-owner.service" "invalid" "" 2>/dev/null; then
  fail "missing owner token was accepted"
fi

printf 'systemd.library tests passed\n'
