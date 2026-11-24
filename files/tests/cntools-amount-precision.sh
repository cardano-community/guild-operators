#!/usr/bin/env bash
# CNTools amount display: ADA and token amounts drop trailing zeros unless
# Settings → Decimals asks for full precision; tokens use their registered
# decimals, NFTs stay whole, unknown decimals are said, and typed token
# amounts are read with the token's decimals. Functions are loaded from the
# libraries; every asset ID is made up.
# shellcheck disable=SC2034 # Library state is set here and read by the libraries.
set -o pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'cntools amount precision tests skipped: Bash 5+ required\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { printf 'cntools amount precision tests skipped: jq is not installed\n'; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CNTOOLS_ROOT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
LIB="${CNTOOLS_ROOT_SOURCE}/lib"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-precision.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT
# The settings file's path is checked component by component; macOS's
# temporary directory sits behind a symbolic link.
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

cntools_log() { :; }
# shellcheck source=/dev/null
for library in number filesystem asset-metadata asset; do
  . "${LIB}/${library}.sh" || { printf 'FAIL: cannot load %s\n' "${library}" >&2; exit 1; }
done
cntools_wallet_log() { :; }
decimals='' kind='' value='' role='' hint='' units='' trimmed=''

# ── ADA ──────────────────────────────────────────────────────────────────────
for case in "340000000|340 ADA|340.000000 ADA" "340050000|340.05 ADA|340.050000 ADA" "0|0 ADA|0.000000 ADA" \
            "1|0.000001 ADA|0.000001 ADA" "422102545673|422,102.545673 ADA|422,102.545673 ADA" \
            "6000000000|6,000 ADA|6,000.000000 ADA" "100|0.0001 ADA|0.000100 ADA"; do
  IFS='|' read -r lovelace trimmed full <<< "${case}"
  CNTOOLS_AMOUNT_PRECISION=''
  assert_eq "$(cntools_number_format_lovelace "${lovelace}")" "${trimmed}" "${lovelace} lovelace, trimmed by default"
  CNTOOLS_AMOUNT_PRECISION=trim
  assert_eq "$(cntools_number_format_lovelace "${lovelace}")" "${trimmed}" "${lovelace} lovelace, trimmed"
  CNTOOLS_AMOUNT_PRECISION=full
  assert_eq "$(cntools_number_format_lovelace "${lovelace}")" "${full}" "${lovelace} lovelace, full precision"
done
CNTOOLS_AMOUNT_PRECISION=''
assert_eq "$(cntools_number_format_lovelace_compact 1500000000000000)" 1.5B "compact billions"
assert_eq "$(cntools_number_format_lovelace_compact 2000000)" 2 "compact whole ADA"
assert_eq "$(cntools_number_format_units 340050000 6) ADA" "340.05 ADA" "a fee row built from the units formatter"
assert_eq "$(cntools_number_format_units 1200 0)" 1,200 "no decimals"
assert_eq "$(cntools_number_format 1000.500)" 1,000.500 "plain numbers are never trimmed"
cntools_number_trim_into trimmed "-1,000.0100"; assert_eq "${trimmed}" -1,000.01 "a negative change keeps its sign"

# ── tokens ───────────────────────────────────────────────────────────────────
policy="$(printf 'ab%.0s' {1..28})"
FT6="${policy}.546f6b656e" FT0="${policy}.57686f6c65" REG="${policy}.526567" NFT="${policy}.4e4654"
CIP222="${policy}.000de1404e4654" CIP333="${policy}.0014df10465400" UNKNOWN="${policy}.556e6b" HUGE="${policy}.48756765"
CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES=(["${FT6}"]=45000000000000 ["${FT0}"]=1000 ["${REG}"]=500 ["${NFT}"]=1 ["${HUGE}"]=9)
CNTOOLS_WALLET_ASSET_METADATA_DECIMALS=(["${FT6}"]=6 ["${FT0}"]=0 ["${HUGE}"]=30)
CNTOOLS_WALLET_ASSET_METADATA_SOURCES=(["${REG}"]='Token Registry' ["${NFT}"]='CIP-25 (721)')
for case in "${FT6}|6" "${FT0}|0" "${REG}|0" "${NFT}|0" "${CIP222}|0" "${CIP333}|" "${UNKNOWN}|" "${HUGE}|30"; do
  cntools_asset_decimals_into decimals "${case%%|*}"
  assert_eq "${decimals}" "${case#*|}" "decimals of ${case%%|*}"
done
cntools_asset_kind_into kind "${NFT}"; assert_eq "${kind}" NFT "an NFT by total supply"
cntools_asset_kind_into kind "${CIP222}"; assert_eq "${kind}" NFT "a CIP-68 (222) user token"
cntools_asset_kind_into kind "${FT6}"; assert_eq "${kind}" FT "a fungible token by total supply"
cntools_asset_kind_into kind "${UNKNOWN}"; assert_eq "${kind}" "" "an asset without Koios metadata"

amount() { cntools_asset_amount_into value "$1" "$2" role; printf '%s|%s' "${value}" "${role}"; }
assert_eq "$(amount "${FT6}" 1500000)" "1.5|number" "a 6-decimal token, trimmed"
assert_eq "$(amount "${FT6}" 2000000)" "2|number" "a whole 6-decimal amount"
assert_eq "$(CNTOOLS_AMOUNT_PRECISION=full amount "${FT6}" 1500000)" "1.500000|number" "a 6-decimal token, full precision"
assert_eq "$(amount "${FT0}" 1234)" "1,234|number" "a token without decimals"
assert_eq "$(amount "${REG}" 77)" "77|number" "a registered token without a decimals field"
assert_eq "$(amount "${NFT}" 1)" "1|number" "an NFT"
assert_eq "$(amount "${UNKNOWN}" 1500000)" "1,500,000 · decimals unknown|warning" "unknown decimals are said"
assert_eq "$(amount "${FT6}" x)" "Unavailable|muted" "an unavailable quantity"
cntools_asset_number_into value "${UNKNOWN}" 1500000; assert_eq "${value}" 1,500,000 "a narrow column omits the note"
cntools_asset_any_decimals_unknown "${FT6}" "${NFT}" && fail "every decimal count is known"
cntools_asset_any_decimals_unknown "${FT6}" "${UNKNOWN}" || fail "one asset has unknown decimals"

for case in "${FT6}|up to 6 decimals" "${FT0}|whole units" "${NFT}|whole units" "${UNKNOWN}|smallest units, decimals unknown" \
            "${HUGE}|smallest units, decimals unknown"; do
  cntools_asset_input_hint_into hint "${case%%|*}"
  assert_eq "${hint}" "${case#*|}" "input hint of ${case%%|*}"
done
for case in "${FT6}|1.5|1500000" "${FT6}|1,000.25|1000250000" "${FT6}|0.000001|1" "${FT6}|1.0000001|" \
            "${FT0}|12|12" "${FT0}|1.5|" "${UNKNOWN}|1500000|1500000" "${UNKNOWN}|1.5|" "${HUGE}|9|9"; do
  IFS='|' read -r id entered expected <<< "${case}"
  units=''; cntools_asset_units_into units "${id}" "${entered}" || units=''
  assert_eq "${units}" "${expected}" "typed ${entered} of ${id}"
done

# ── Settings → Decimals ──────────────────────────────────────────────────────
CNTOOLS_ROOT="${TEST_ROOT}/cntools"; mkdir -p "${CNTOOLS_ROOT}"
# shellcheck source=/dev/null
for f in theme settings; do . "${CNTOOLS_ROOT_SOURCE}/core/${f}.sh" || { printf 'FAIL: cannot load %s\n' "${f}" >&2; exit 1; }; done
CNTOOLS_AMOUNT_PRECISION=''
cntools_settings_init
[[ "${CNTOOLS_SETTINGS_FILE}" == "${TEST_ROOT}/cntools/.state/"* ]] || {
  printf 'FAIL: the settings file is not in the test folder: %s\n' "${CNTOOLS_SETTINGS_FILE:-unset}" >&2; exit 1; }
assert_eq "$(cntools_amount_precision_name)" Trimmed "trimmed until chosen"
assert_eq "$(cntools_settings_json | jq -c '.interaction | has("amountPrecision")')" false "nothing saved until chosen"
cntools_amount_precision_save full || fail "save full precision"
assert_eq "$(jq -r .interaction.amountPrecision "${CNTOOLS_SETTINGS_FILE}")" full "full precision saved"
CNTOOLS_AMOUNT_PRECISION=''
cntools_settings_reload || fail "reload settings"
assert_eq "${CNTOOLS_AMOUNT_PRECISION}" full "full precision loaded"
assert_eq "$(cntools_number_format_lovelace 340000000)" "340.000000 ADA" "the loaded setting applies"
cntools_amount_precision_save trim || fail "save trimmed"
cntools_settings_reload || fail "reload settings"
assert_eq "$(cntools_number_format_lovelace 340000000)" "340 ADA" "trimmed again"
jq '.interaction.amountPrecision = "rounded"' "${CNTOOLS_SETTINGS_FILE}" > "${TEST_ROOT}/bad.json"
cp "${TEST_ROOT}/bad.json" "${CNTOOLS_SETTINGS_FILE}"
cntools_settings_file_valid "${CNTOOLS_SETTINGS_FILE}" && fail "an unknown precision is accepted"
cntools_amount_precision_save rounded && fail "an unknown precision is saved"

if (( failures > 0 )); then
  printf 'cntools amount precision tests: %d failure(s)\n' "${failures}" >&2
  exit 1
fi
printf 'cntools amount precision tests passed\n'
