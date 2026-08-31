#!/usr/bin/env bash
# shellcheck disable=SC1090

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools number tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
NUMBER_LIBRARY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/number.sh"

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

assert_status() {
  local expected="$1"
  local context="$2"
  local actual=0
  shift 2

  if "$@"; then
    actual=0
  else
    actual=$?
  fi
  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected status ${expected}, got ${actual}"
}

[[ -f "${NUMBER_LIBRARY}" && ! -L "${NUMBER_LIBRARY}" ]] ||
  fail "number library is missing or unsafe"
bash -n "${NUMBER_LIBRARY}" || fail "number library has invalid Bash syntax"

# shellcheck source=/dev/null
. "${NUMBER_LIBRARY}"

normalized=""
cntools_number_normalize_into normalized "0"
assert_eq "${normalized}" "0" "zero normalization"
cntools_number_normalize_into normalized "000000"
assert_eq "${normalized}" "0" "leading zero normalization"
cntools_number_normalize_into normalized "+000123"
assert_eq "${normalized}" "123" "positive sign normalization"
cntools_number_normalize_into normalized "-000123.4500"
assert_eq "${normalized}" "-123.4500" "signed decimal normalization"
cntools_number_normalize_into normalized ".500"
assert_eq "${normalized}" "0.500" "leading-decimal normalization"
cntools_number_normalize_into normalized "-.500"
assert_eq "${normalized}" "-0.500" "signed leading-decimal normalization"
cntools_number_normalize_into normalized "-000.000"
assert_eq "${normalized}" "0.000" "negative zero normalization"
cntools_number_normalize_into normalized "1,234,567.8900"
assert_eq "${normalized}" "1234567.8900" "grouped decimal normalization"

huge_input="1234567890123456789012345678901234567890.0012300"
huge_formatted="1,234,567,890,123,456,789,012,345,678,901,234,567,890.0012300"
cntools_number_format_into formatted "${huge_input}"
assert_eq "${formatted}" "${huge_formatted}" \
  "arbitrarily large decimal formatting"
cntools_number_normalize_into normalized "${huge_formatted}"
assert_eq "${normalized}" "${huge_input}" \
  "arbitrarily large grouped decimal normalization"

cntools_number_format_into formatted "999"
assert_eq "${formatted}" "999" "sub-thousand formatting"
cntools_number_format_into formatted "1000"
assert_eq "${formatted}" "1,000" "thousand formatting"
cntools_number_format_into formatted "-001234567.0500"
assert_eq "${formatted}" "-1,234,567.0500" \
  "signed decimal formatting"
cntools_number_format_into formatted "+1,234.50"
assert_eq "${formatted}" "1,234.50" "canonical grouped formatting"
formatted="001234.500"
cntools_number_format_into formatted "${formatted}"
assert_eq "${formatted}" "1,234.500" "in-place formatting"
normalized="1,234.500"
cntools_number_normalize_into normalized "${normalized}"
assert_eq "${normalized}" "1234.500" "in-place normalization"
assert_eq "$(cntools_number_format "1234567.89")" "1,234,567.89" \
  "format output wrapper"
assert_eq "$(cntools_number_normalize "1,234,567.89")" "1234567.89" \
  "normalize output wrapper"

valid_inputs=(
  "0"
  "0001"
  "+123"
  "-123"
  ".25"
  "-.25"
  "1,000"
  "12,345,678.900"
)
for input in "${valid_inputs[@]}"; do
  assert_status 0 "valid numeric input: ${input}" \
    cntools_number_is_valid "${input}"
done

invalid_inputs=(
  ""
  "+"
  "-"
  "."
  "1."
  " 1"
  "1 "
  "1 000"
  ",123"
  "123,"
  "0,123"
  "01,234"
  "1,23"
  "1,2345"
  "1,,234"
  "1234,567"
  "1,234.5,6"
  "1.2.3"
  "1e3"
  "NaN"
  "--1"
)
for input in "${invalid_inputs[@]}"; do
  assert_status 1 "invalid numeric input: ${input}" \
    cntools_number_is_valid "${input}"
done

formatted="unchanged"
assert_status 1 "invalid input status" \
  cntools_number_format_into formatted "12,34"
assert_eq "${formatted}" "" "invalid input clears output"
assert_status 2 "invalid output variable status" \
  cntools_number_format_into "1invalid" "1000"
assert_status 2 "missing input argument status" \
  cntools_number_format_into formatted
assert_status 2 "extra input argument status" \
  cntools_number_format_into formatted "1000" "unexpected"
assert_status 2 "printing wrapper argument status" \
  cntools_number_format "1000" "unexpected"

printf 'CNTools number tests passed\n'
