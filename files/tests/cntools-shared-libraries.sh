#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools shared-library tests skipped: Bash 4.4+ required\n'
  exit 0
fi
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

encoded='' decoded='' size='' fee=200000
cntools_bech32_encode_into encoded 5390a565142243e65861eab069760bdee6eeba48f578f76f57f3c9d8 addr_test
cntools_bech32_decode_into decoded "${encoded}" addr_test
[[ "${decoded}" == 5390a565142243e65861eab069760bdee6eeba48f578f76f57f3c9d8 ]] || fail 'Bech32 round trip'
if cntools_bech32_decode_into decoded "${encoded}" stake_test; then fail 'wrong HRP accepted'; fi
if cntools_bech32_decode_into decoded "${encoded%?}q" addr_test; then fail 'bad checksum accepted'; fi
if cntools_bech32_encode_into encoded 0 addr_test; then fail 'partial byte accepted'; fi

for boundary in '0:1' '23:1' '24:2' '255:2' '256:3' '65535:3' '65536:5' '4294967295:5' '4294967296:9' '18446744073709551615:9'; do
  cntools_transaction_cbor_uint_size_into size "${boundary%:*}"
  [[ "${size}" == "${boundary#*:}" ]] || fail "CBOR boundary ${boundary}"
done
if cntools_transaction_cbor_uint_size_into size 18446744073709551616; then fail 'CBOR uint overflow accepted'; fi
policy=0123456789abcdef0123456789abcdef0123456789abcdef01234567
cntools_transaction_value_size_into size "address+1000000 + 1 ${policy}.aa + 1 ${policy}.aa"
[[ "${size}" == 41 ]] || fail 'duplicate assets were not combined'
cntools_transaction_value_size_into size "address+1000000 + 1 ${policy}.aa + 1 ${policy}.bb"
[[ "${size}" == 44 ]] || fail 'policy key was not shared'
CNTOOLS_CHANGE_OUTPUT_TYPES=('Token change' 'ADA liquidity 10%')
CNTOOLS_TRANSACTION_BALANCE_CHANGE_CAP=''
cntools_transaction_balance_fee_update fee 180000
[[ "${fee}" == 180000 && "${CNTOOLS_TRANSACTION_BALANCE_REBUILD}" == Y && "${CNTOOLS_TRANSACTION_BALANCE_CHANGE_CAP}" == 1 ]] || fail 'downward exact-fee convergence'
cntools_transaction_balance_fee_update fee 180000
[[ "${CNTOOLS_TRANSACTION_BALANCE_REBUILD}" == N ]] || fail 'stable exact fee'

# A hardware-normalized body can have a different size than its raw body.
# This regression uses a larger final fee and an initially larger fee; the
# exact convergence must work both ways without pricing the raw representation.
(
  CNTOOLS_TRANSACTION_ERROR='' CNTOOLS_TRANSACTION_BODY_FILE=''
  CNTOOLS_CHANGE_OUTPUT_TYPES=()
  hardware_builds=0 hardware_fee=250000 hardware_package=''
  cntools_transaction_calculate_min_fee_into() {
    [[ "$2" == /fixture/hardware-final ]] || fail 'raw body was priced before hardware normalization'
    printf -v "$1" '%s' 200000
  }
  prepare_hardware_body() { hardware_builds=$((hardware_builds+1)); printf -v "$1" '%s' /fixture/raw; }
  cntools_transaction_package_create_staged_into() { printf -v "$1" '%s' /fixture/package; }
  cntools_transaction_package_load() { CNTOOLS_TRANSACTION_BODY_FILE=/fixture/hardware-final; }
  cntools_transaction_plan_witness_count() { printf '1\n'; }
  cntools_transaction_set_error() { fail "$1"; }
  cntools_transaction_log() { :; }
  # No filesystem or CLI calls in this focused engine-contract test.
  jq() { case "$2" in *maxTxSize*) printf '16384\n' ;; *cborHex*) printf '100\n' ;; *) fail 'unexpected engine query' ;; esac; }
  for hardware_fee in 250000 100000; do
    hardware_builds=0
    cntools_transaction_balance_into hardware_package hardware_fee /fixture/protocol prepare_hardware_body
    [[ "${hardware_fee}" == 200000 && "${hardware_package}" == /fixture/package && "${hardware_builds}" == 2 ]] || fail 'hardware exact-fee convergence'
  done
)

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/cntools-shared.XXXXXXXX")"
fixture_root="$(cd "${fixture_root}" && pwd -P)"
trap 'rm -rf -- "${fixture_root}"' EXIT
mkdir "${fixture_root}/parent" "${fixture_root}/parent/leaf"
chmod 0700 "${fixture_root}/parent" "${fixture_root}/parent/leaf"
cntools_filesystem_directory_ancestry_safe "${fixture_root}/parent/leaf" || fail 'private ancestry rejected'
chmod 0777 "${fixture_root}/parent"
if cntools_filesystem_directory_ancestry_safe "${fixture_root}/parent/leaf"; then fail 'non-sticky shared ancestor accepted'; fi
chmod 1777 "${fixture_root}/parent"
cntools_filesystem_directory_ancestry_safe "${fixture_root}/parent/leaf" || fail 'sticky shared ancestor rejected'
ln -s "${fixture_root}/parent" "${fixture_root}/linked"
if cntools_filesystem_path_components_safe "${fixture_root}/linked/leaf"; then fail 'symlink ancestor accepted'; fi

formatted=''
cntools_number_format_units_into formatted 9007199254740993 6
[[ "${formatted}" == 9,007,199,254.740993 ]] || fail 'large scaled quantity rounded'
cntools_number_format_units_into formatted 1 255
[[ ${#formatted} == 257 && "${formatted}" == 0.*1 ]] || fail 'bounded token metadata scale'
if cntools_number_format_units_into formatted 1 256; then fail 'unbounded metadata scale accepted'; fi

records="$(printf '%s' '{"count":9007199254740993,"message":"hello\nworld\u001fvalue"}' | cntools_json_scalar_records)"
[[ "${records}" == *$'count\x1f9007199254740993'* && "${records}" == *$'message\x1fhello world value'* ]] || fail 'lossless/safe scalar records'
printf 'CNTools shared-library regression tests passed\n'
