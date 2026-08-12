#!/usr/bin/env bash
# Validate the Stage 1 CNTools configuration parser and legacy-header
# migration as inert data handling. This does not assert that production
# CNTools consumes cntools.conf; the modular runtime remains shadow-only.
# shellcheck disable=SC1090,SC2034,SC2178
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools configuration contract tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

LC_ALL=C
export LC_ALL

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CONFIG_IMPL="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/config.sh"
CONFIG_EXAMPLE="${REPO_ROOT}/scripts/common-helper-scripts/cntools.conf.example"
LEGACY_CNTOOLS="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-config.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
LOG_DIR_FIXTURE="${TEST_ROOT}/node/logs"
FIXTURE_ROOT="${TEST_ROOT}/fixtures"
INVALID_ROOT="${TEST_ROOT}/invalid"

cleanup() {
  chmod -R u+rwX "${TEST_ROOT}" >/dev/null 2>&1 || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'CNTools configuration contract test failed: %s\n' "$1" >&2
  exit 1
}

for required_command in chmod cmp cp find grep id ln mktemp od readlink \
  rm sort stat wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
if ! command -v sha256sum >/dev/null 2>&1 &&
   ! command -v shasum >/dev/null 2>&1; then
  fail "a SHA-256 command is unavailable"
fi

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="$3"

  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_absent() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected path exists: $1"
}

assert_map_value() {
  local map_name="$1"
  local key="$2"
  local expected="$3"
  local context="$4"
  local -n map_ref="${map_name}"

  [[ -n "${map_ref[${key}]+set}" ]] ||
    fail "${context}: ${key} is absent"
  assert_eq "${map_ref[${key}]}" "${expected}" "${context}: ${key}"
}

assert_map_absent() {
  local map_name="$1"
  local key="$2"
  local context="$3"
  local -n map_ref="${map_name}"

  [[ -z "${map_ref[${key}]+set}" ]] ||
    fail "${context}: ${key} was unexpectedly present"
}

assert_map_size() {
  local map_name="$1"
  local expected="$2"
  local context="$3"
  local -n map_ref="${map_name}"

  assert_eq "${#map_ref[@]}" "${expected}" "${context}: map size"
}

expect_failure() {
  local context="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    fail "${context} unexpectedly succeeded"
  fi
}

sha256_file() {
  local file="$1"
  local digest=""

  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum -- "${file}")" || return 1
  else
    digest="$(shasum -a 256 -- "${file}")" || return 1
  fi
  printf '%s\n' "${digest%% *}"
}

stat_metadata() {
  local path="$1"

  if stat -c $'%u\t%a\t%h' "${path}" >/dev/null 2>&1; then
    stat -c $'%u\t%a\t%h' "${path}"
  else
    stat -f $'%u\t%Lp\t%l' "${path}"
  fi
}

snapshot_tree() {
  local root="$1"
  local output="$2"
  local path="" relative="" metadata=""

  : > "${output}"
  while IFS= read -r path; do
    relative="${path#"${root}"/}"
    if [[ -L "${path}" ]]; then
      printf 'link\t%s\t%s\n' "${relative}" "$(readlink "${path}")"
    elif [[ -d "${path}" ]]; then
      metadata="$(stat_metadata "${path}")" || return 1
      printf 'directory\t%s\t%s\n' "${relative}" "${metadata}"
    elif [[ -f "${path}" ]]; then
      metadata="$(stat_metadata "${path}")" || return 1
      printf 'file\t%s\t%s\t%s\n' "${relative}" "${metadata}" \
        "$(sha256_file "${path}")"
    else
      return 1
    fi
  done < <(find "${root}" -mindepth 1 -print | sort) >> "${output}"
}

write_lines() {
  local file="$1"
  shift

  printf '%s\n' "$@" > "${file}"
}

assert_parse_rejected() {
  local name="$1"
  shift
  local file="${INVALID_ROOT}/parse-${name}.conf"
  local -A rejected_records=()

  write_lines "${file}" "$@"
  expect_failure "canonical configuration ${name}" \
    cntools_config_parse "${file}" rejected_records
}

assert_migration_rejected() {
  local name="$1"
  shift
  local file="${INVALID_ROOT}/legacy-${name}.sh"
  local -A rejected_records=()

  write_lines "${file}" "$@"
  expect_failure "legacy migration ${name}" \
    cntools_config_migrate_legacy_header \
      "${file}" rejected_records "${LOG_DIR_FIXTURE}"
}

mkdir -p -- "${LOG_DIR_FIXTURE}" "${FIXTURE_ROOT}/legacy" "${INVALID_ROOT}"

[[ -f "${CONFIG_IMPL}" && ! -L "${CONFIG_IMPL}" ]] ||
  fail "configuration implementation is missing or unsafe: ${CONFIG_IMPL}"
[[ -f "${CONFIG_EXAMPLE}" && ! -L "${CONFIG_EXAMPLE}" ]] ||
  fail "packaged configuration example is missing or unsafe: ${CONFIG_EXAMPLE}"
[[ -f "${LEGACY_CNTOOLS}" && ! -L "${LEGACY_CNTOOLS}" ]] ||
  fail "legacy CNTools launcher is missing or unsafe: ${LEGACY_CNTOOLS}"

# Sourcing must only define the documented API. It must not print, exit, read
# an obsolete configuration file, or create files in the caller's directory.
definition_before="${TEST_ROOT}/definition-before.tsv"
definition_after="${TEST_ROOT}/definition-after.tsv"
snapshot_tree "${FIXTURE_ROOT}" "${definition_before}" ||
  fail "could not snapshot the definition-only fixture"
source_output="$({
  cd "${FIXTURE_ROOT}"
  # shellcheck source=/dev/null
  . "${CONFIG_IMPL}"
  for function_name in \
    cntools_config_parse \
    cntools_config_parse_data \
    cntools_config_defaults \
    cntools_config_resolve \
    cntools_config_load_runtime \
    cntools_config_migrate_legacy_header; do
    declare -F "${function_name}" >/dev/null || exit 97
  done
} 2>&1)" || fail "configuration implementation is not definition-only"
[[ -z "${source_output}" ]] ||
  fail "sourcing configuration implementation produced output: ${source_output}"
snapshot_tree "${FIXTURE_ROOT}" "${definition_after}" ||
  fail "could not resnapshot the definition-only fixture"
cmp -s "${definition_before}" "${definition_after}" ||
  fail "sourcing configuration implementation changed caller files"

# shellcheck source=/dev/null
. "${CONFIG_IMPL}"

# The packaged example is schema-valid data, not a shell fragment. Its only
# active value is the version; resolution supplies every documented default.
declare -A example_records=() example_resolved=()
cntools_config_parse "${CONFIG_EXAMPLE}" example_records ||
  fail "packaged configuration example did not parse"
assert_map_size example_records 1 "packaged example"
assert_map_value example_records CNTOOLS_CONFIG_VERSION 1 "packaged example"
cntools_config_resolve example_records example_resolved "${LOG_DIR_FIXTURE}" ||
  fail "packaged configuration example did not resolve"
assert_map_size example_resolved 15 "resolved packaged example"
assert_map_value example_resolved CNTOOLS_CONFIG_VERSION 1 "defaults"
assert_map_value example_resolved TIMEOUT_NO_OF_SLOTS 600 "defaults"
assert_map_value example_resolved CNTOOLS_LOG \
  "${LOG_DIR_FIXTURE}/cntools-history.log" "defaults"
assert_map_value example_resolved CHECK_KES true "defaults"
assert_map_value example_resolved KES_ALERT_PERIOD 172800 "defaults"
assert_map_value example_resolved KES_WARNING_PERIOD 604800 "defaults"
assert_map_value example_resolved TX_TTL 3600 "defaults"
assert_map_value example_resolved WALLET_SELECTION_FILTER_LIMIT 10 "defaults"
assert_map_value example_resolved ENABLE_CHATTR true "defaults"
assert_map_value example_resolved ENABLE_DIALOG false "defaults"
assert_map_value example_resolved ENABLE_ADVANCED false "defaults"
assert_map_value example_resolved CURRENCY off "defaults"
assert_map_value example_resolved CNTOOLS_MODE local "defaults"
assert_map_value example_resolved CATALYST_API \
  https://api.projectcatalyst.io/api/v1 "defaults"
assert_map_value example_resolved EXPLORER_TX \
  https://adastat.net/transactions/__tx_id__ "defaults"

declare -A explicit_records=(
  [CNTOOLS_CONFIG_VERSION]=1
  [TIMEOUT_NO_OF_SLOTS]=901
  [CHECK_KES]=false
  [ENABLE_DIALOG]=true
  [CURRENCY]=sek
  [CNTOOLS_MODE]=light
)
declare -A explicit_resolved=()
cntools_config_resolve explicit_records explicit_resolved "${LOG_DIR_FIXTURE}" ||
  fail "valid explicit configuration did not resolve"
assert_map_size explicit_resolved 15 "explicit resolution"
assert_map_value explicit_resolved TIMEOUT_NO_OF_SLOTS 901 "explicit resolution"
assert_map_value explicit_resolved CHECK_KES false "explicit resolution"
assert_map_value explicit_resolved ENABLE_DIALOG true "explicit resolution"
assert_map_value explicit_resolved CURRENCY sek "explicit resolution"
assert_map_value explicit_resolved CNTOOLS_MODE light "explicit resolution"
assert_map_value explicit_resolved TX_TTL 3600 "explicit default fallback"

# Canonical runtime loading additionally enforces ownership, mode 0600, and a
# single hard link before parsing or applying defaults.
runtime_config="${FIXTURE_ROOT}/cntools.conf"
write_lines "${runtime_config}" \
  'CNTOOLS_CONFIG_VERSION=1' \
  'TIMEOUT_NO_OF_SLOTS=777' \
  'ENABLE_ADVANCED=true' \
  'CNTOOLS_MODE=offline'
chmod 0600 "${runtime_config}"
declare -A runtime_resolved=()
cntools_config_load_runtime "${runtime_config}" runtime_resolved \
  "${LOG_DIR_FIXTURE}" "$(id -u)" ||
  fail "valid owner/mode/single-link runtime configuration did not load"
assert_map_size runtime_resolved 15 "runtime resolution"
assert_map_value runtime_resolved TIMEOUT_NO_OF_SLOTS 777 "runtime resolution"
assert_map_value runtime_resolved ENABLE_ADVANCED true "runtime resolution"
assert_map_value runtime_resolved CNTOOLS_MODE offline "runtime resolution"

wrong_uid="$(( $(id -u) + 1 ))"
expect_failure "runtime configuration with wrong owner expectation" \
  cntools_config_load_runtime "${runtime_config}" runtime_resolved \
    "${LOG_DIR_FIXTURE}" "${wrong_uid}"
chmod 0640 "${runtime_config}"
expect_failure "runtime configuration with mode 0640" \
  cntools_config_load_runtime "${runtime_config}" runtime_resolved \
    "${LOG_DIR_FIXTURE}" "$(id -u)"
chmod 0600 "${runtime_config}"
ln -s "${runtime_config}" "${FIXTURE_ROOT}/cntools-symlink.conf"
expect_failure "runtime configuration symbolic link" \
  cntools_config_load_runtime "${FIXTURE_ROOT}/cntools-symlink.conf" \
    runtime_resolved "${LOG_DIR_FIXTURE}" "$(id -u)"
ln "${runtime_config}" "${FIXTURE_ROOT}/cntools-hardlink.conf"
expect_failure "runtime configuration with multiple hard links" \
  cntools_config_load_runtime "${runtime_config}" runtime_resolved \
    "${LOG_DIR_FIXTURE}" "$(id -u)"
rm -f -- "${FIXTURE_ROOT}/cntools-hardlink.conf"
cntools_config_load_runtime "${runtime_config}" runtime_resolved \
  "${LOG_DIR_FIXTURE}" "$(id -u)" ||
  fail "runtime configuration did not recover after removing hard link"

# Canonical syntax is deliberately narrower than shell assignment syntax.
assert_parse_rejected unknown-key \
  'CNTOOLS_CONFIG_VERSION=1' 'UNKNOWN_SETTING=value'
assert_parse_rejected duplicate-key \
  'CNTOOLS_CONFIG_VERSION=1' 'CNTOOLS_MODE=local' 'CNTOOLS_MODE=offline'
assert_parse_rejected quoted-value \
  'CNTOOLS_CONFIG_VERSION=1' 'CNTOOLS_MODE="local"'
assert_parse_rejected parameter-expansion \
  'CNTOOLS_CONFIG_VERSION=1' 'CNTOOLS_LOG=${LOG_DIR}/history.log'
assert_parse_rejected shell-operator \
  'CNTOOLS_CONFIG_VERSION=1' 'CHECK_KES=true;touch'
assert_parse_rejected inline-comment \
  'CNTOOLS_CONFIG_VERSION=1' 'CHECK_KES=true # not canonical'
assert_parse_rejected whitespace-around-assignment \
  'CNTOOLS_CONFIG_VERSION=1' 'CNTOOLS_MODE = local'
assert_parse_rejected missing-value \
  'CNTOOLS_CONFIG_VERSION=1' 'CNTOOLS_MODE='
assert_parse_rejected lowercase-key \
  'CNTOOLS_CONFIG_VERSION=1' 'cntools_mode=local'
assert_parse_rejected version-not-first \
  'CNTOOLS_MODE=local' 'CNTOOLS_CONFIG_VERSION=1'
assert_parse_rejected unsupported-version \
  'CNTOOLS_CONFIG_VERSION=2'
assert_parse_rejected malformed-integer \
  'CNTOOLS_CONFIG_VERSION=1' 'TX_TTL=03600'
assert_parse_rejected malformed-boolean \
  'CNTOOLS_CONFIG_VERSION=1' 'ENABLE_DIALOG=TRUE'
assert_parse_rejected malformed-mode \
  'CNTOOLS_CONFIG_VERSION=1' 'CNTOOLS_MODE=remote'
assert_parse_rejected insecure-api-url \
  'CNTOOLS_CONFIG_VERSION=1' 'CATALYST_API=http://example.org/api'
assert_parse_rejected malformed-api-url \
  'CNTOOLS_CONFIG_VERSION=1' 'CATALYST_API=https://-example.org/api'
assert_parse_rejected missing-transaction-marker \
  'CNTOOLS_CONFIG_VERSION=1' 'EXPLORER_TX=https://example.org/transactions/id'
assert_parse_rejected duplicate-transaction-marker \
  'CNTOOLS_CONFIG_VERSION=1' \
  'EXPLORER_TX=https://example.org/__tx_id__/transactions/__tx_id__'

cr_config="${INVALID_ROOT}/parse-carriage-return.conf"
printf 'CNTOOLS_CONFIG_VERSION=1\r\n' > "${cr_config}"
declare -A invalid_records=()
expect_failure "canonical configuration with carriage return" \
  cntools_config_parse "${cr_config}" invalid_records
nul_config="${INVALID_ROOT}/parse-nul.conf"
printf 'CNTOOLS_CONFIG_VERSION=1\0CNTOOLS_MODE=local\n' > "${nul_config}"
expect_failure "canonical configuration with NUL byte" \
  cntools_config_parse "${nul_config}" invalid_records

declare -A invalid_relationship=(
  [CNTOOLS_CONFIG_VERSION]=1
  [KES_ALERT_PERIOD]=21
  [KES_WARNING_PERIOD]=20
)
expect_failure "KES alert period above warning period" \
  cntools_config_resolve invalid_relationship invalid_records \
    "${LOG_DIR_FIXTURE}"
declare -A invalid_log_path=(
  [CNTOOLS_CONFIG_VERSION]=1
  [CNTOOLS_LOG]="${TEST_ROOT}/outside/cntools.log"
)
expect_failure "CNTOOLS_LOG outside LOG_DIR" \
  cntools_config_resolve invalid_log_path invalid_records "${LOG_DIR_FIXTURE}"

# The checked-in legacy launcher currently has no active overrides. Automatic
# migration must ignore ambient variables and an obsolete sibling
# cntools.config file rather than source either one.
legacy_copy="${FIXTURE_ROOT}/legacy/cntools.sh"
obsolete_config="${FIXTURE_ROOT}/legacy/cntools.config"
obsolete_marker="${FIXTURE_ROOT}/legacy/obsolete-config-executed"
cp -- "${LEGACY_CNTOOLS}" "${legacy_copy}"
write_lines "${obsolete_config}" \
  'CNTOOLS_MODE=offline' \
  'CURRENCY=usd' \
  "touch ${obsolete_marker}"
CNTOOLS_CONFIG_VERSION=999
TIMEOUT_NO_OF_SLOTS=42
CNTOOLS_LOG=/ambient/cntools.log
CHECK_KES=false
CURRENCY=eur
CNTOOLS_MODE=offline
declare -A current_migration=()
cntools_config_migrate_legacy_header \
  "${legacy_copy}" current_migration "${LOG_DIR_FIXTURE}" ||
  fail "current legacy CNTools header was not eligible for migration"
assert_map_size current_migration 1 "current legacy migration"
assert_map_value current_migration CNTOOLS_CONFIG_VERSION 1 \
  "current legacy migration"
assert_map_absent current_migration CNTOOLS_MODE \
  "ambient CNTOOLS_MODE isolation"
assert_map_absent current_migration CURRENCY \
  "obsolete cntools.config isolation"
assert_absent "${obsolete_marker}"

# Supported legacy values may be plain or simply quoted. Case normalization is
# limited to mode/currency, and ${LOG_DIR}/... is recognized textually only for
# CNTOOLS_LOG. Code after the legacy boundary is never inspected or executed.
custom_legacy="${FIXTURE_ROOT}/legacy/custom-cntools.sh"
post_boundary_marker="${FIXTURE_ROOT}/legacy/post-boundary-executed"
write_lines "${custom_legacy}" \
  '#!/usr/bin/env bash' \
  '# Safe operator overrides.' \
  'TIMEOUT_NO_OF_SLOTS=901 # plain literal with legacy comment' \
  'CNTOOLS_LOG="${LOG_DIR}/custom/cntools.log"' \
  "CHECK_KES='false'" \
  'KES_ALERT_PERIOD=10' \
  'KES_WARNING_PERIOD="20"' \
  "CURRENCY='USD'" \
  'CNTOOLS_MODE="LIGHT"' \
  '# Do NOT modify code below' \
  "touch ${post_boundary_marker}"
declare -A custom_migration=()
cntools_config_migrate_legacy_header \
  "${custom_legacy}" custom_migration "${LOG_DIR_FIXTURE}" ||
  fail "safe custom legacy header did not migrate"
assert_map_size custom_migration 8 "custom legacy migration"
assert_map_value custom_migration CNTOOLS_CONFIG_VERSION 1 \
  "custom legacy migration"
assert_map_value custom_migration TIMEOUT_NO_OF_SLOTS 901 \
  "plain legacy literal"
assert_map_value custom_migration CNTOOLS_LOG \
  "${LOG_DIR_FIXTURE}/custom/cntools.log" 'literal ${LOG_DIR} migration'
assert_map_value custom_migration CHECK_KES false "single-quoted legacy literal"
assert_map_value custom_migration KES_ALERT_PERIOD 10 "legacy alert period"
assert_map_value custom_migration KES_WARNING_PERIOD 20 "quoted warning period"
assert_map_value custom_migration CURRENCY usd "uppercase currency normalization"
assert_map_value custom_migration CNTOOLS_MODE light "uppercase mode normalization"
assert_absent "${post_boundary_marker}"

expansion_marker="${TEST_ROOT}/legacy-expansion-executed"
assert_migration_rejected active-code \
  '#!/usr/bin/env bash' 'echo unsafe' '# Do NOT modify code below'
assert_migration_rejected unknown-assignment \
  '#!/usr/bin/env bash' 'UNKNOWN_SETTING=value' '# Do NOT modify code below'
assert_migration_rejected duplicate-assignment \
  '#!/usr/bin/env bash' 'CNTOOLS_MODE=local' 'CNTOOLS_MODE=offline' \
  '# Do NOT modify code below'
assert_migration_rejected missing-boundary \
  '#!/usr/bin/env bash' 'CNTOOLS_MODE=local'
assert_migration_rejected command-expansion \
  '#!/usr/bin/env bash' \
  "CNTOOLS_MODE=\"\$(touch ${expansion_marker})\"" \
  '# Do NOT modify code below'
assert_migration_rejected parameter-expansion \
  '#!/usr/bin/env bash' 'CURRENCY="${MIGRATION_CURRENCY}"' \
  '# Do NOT modify code below'
assert_absent "${expansion_marker}"

# Exercise representative successful read paths against a stable fixture and
# compare content, metadata, links, and directory inventory before/after.
read_only_before="${TEST_ROOT}/read-only-before.tsv"
read_only_after="${TEST_ROOT}/read-only-after.tsv"
snapshot_tree "${FIXTURE_ROOT}" "${read_only_before}" ||
  fail "could not snapshot read-only contract fixture"
declare -A no_write_parse=() no_write_runtime=() no_write_migration=()
cntools_config_parse "${runtime_config}" no_write_parse ||
  fail "read-only parse proof failed"
cntools_config_load_runtime "${runtime_config}" no_write_runtime \
  "${LOG_DIR_FIXTURE}" "$(id -u)" || fail "read-only runtime proof failed"
cntools_config_migrate_legacy_header \
  "${legacy_copy}" no_write_migration "${LOG_DIR_FIXTURE}" ||
  fail "read-only migration proof failed"
snapshot_tree "${FIXTURE_ROOT}" "${read_only_after}" ||
  fail "could not resnapshot read-only contract fixture"
cmp -s "${read_only_before}" "${read_only_after}" ||
  fail "configuration APIs wrote to or changed their input tree"
assert_absent "${obsolete_marker}"
assert_absent "${post_boundary_marker}"
assert_absent "${expansion_marker}"

printf 'CNTools configuration contract tests passed\n'
