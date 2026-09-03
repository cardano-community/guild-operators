#!/usr/bin/env bash
# Shared CNTools transaction foundation acceptance tests.
# shellcheck disable=SC1090,SC2034,SC2153,SC2154,SC2317,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools transaction foundation tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TRANSACTION_LIBRARY="${CNTOOLS_ROOT}/lib/transaction.sh"
BUILD_LIBRARY="${CNTOOLS_ROOT}/lib/transaction-build.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-transaction.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
CNTOOLS_TMP_DIR="${TEST_ROOT}/tmp"
OUTPUT_ROOT="${TEST_ROOT}/output"
FAKE_CLI="${TEST_ROOT}/cardano-cli"
CLI_TRACE="${TEST_ROOT}/cardano-cli.trace"
LOG_TRACE="${TEST_ROOT}/cntools.log"

TESTED_CARDANO_CLI_VERSION="11.0.0.0"
KEY_A="$(printf '11%.0s' {1..32})"
KEY_B="$(printf '22%.0s' {1..32})"
KEY_C="$(printf '33%.0s' {1..32})"
KEY_D="$(printf '44%.0s' {1..32})"
FAKE_SIGNATURE="$(printf '55%.0s' {1..64})"
CREDENTIAL_A="${KEY_A:0:56}"
CREDENTIAL_B="${KEY_B:0:56}"
CREDENTIAL_C="${KEY_C:0:56}"
WRONG_CREDENTIAL="$(printf '99%.0s' {1..28})"
SCRIPT_HASH="$(printf 'ab%.0s' {1..28})"
REFERENCE_TX_ID="$(printf 'dd%.0s' {1..32})"
REFERENCE_TX_ID_UPPER="$(printf 'DD%.0s' {1..32})"
REFERENCE_INPUT="${REFERENCE_TX_ID}#0"
REFERENCE_INPUT_OTHER="${REFERENCE_TX_ID}#1"
TX_ID_A="$(printf 'aa%.0s' {1..32})"
TX_ID_B="$(printf 'bb%.0s' {1..32})"
TX_ID_C="$(printf 'cc%.0s' {1..32})"
BASE_VIEW="${TEST_ROOT}/base-view.json"
PLAN_VIEW="${TEST_ROOT}/plan-view.json"
NATIVE_VIEW="${TEST_ROOT}/native-view.json"

cleanup_test() {
  chmod -R u+rwx -- "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

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

assert_contains() {
  local actual="$1"
  local expected="$2"
  local context="${3:-text is missing}"

  [[ "${actual}" == *"${expected}"* ]] ||
    fail "${context}: '${expected}' was not found"
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  local context="${3:-file text is missing}"

  grep -F -- "${expected}" "${file}" >/dev/null ||
    fail "${context}: '${expected}' was not found in ${file}"
}

file_mode() {
  local path="$1"
  local mode=""

  if mode="$(stat -c '%a' -- "${path}" 2>/dev/null)"; then
    printf '%s\n' "${mode}"
  else
    stat -f '%Lp' "${path}"
  fi
}

assert_pinned_cardano_cli_versions() {
  local implementation=""
  local manifest=""
  local pinned_version=""

  for implementation in cnode dingo; do
    manifest="${REPO_ROOT}/files/node-implementations/${implementation}/release.json"
    pinned_version="$(
      jq -er '.companions["cardano-cli"].version' "${manifest}"
    )" || fail "${implementation} does not pin its cardano-cli companion"
    [[ "${pinned_version}" == "${TESTED_CARDANO_CLI_VERSION}" ]] ||
      fail "${implementation} pins cardano-cli ${pinned_version}; review the transaction fixtures tested against ${TESTED_CARDANO_CLI_VERSION}"
  done
}

assert_trace_option_once() {
  local trace_json="$1"
  local option="$2"
  local value="$3"
  local context="${4:-CLI option}"

  jq -e --arg option "${option}" --arg value "${value}" '
    ([range(0; length) as $index |
      select(.[$index] == $option and .[$index + 1] == $value)] |
      length) == 1
  ' <<< "${trace_json}" >/dev/null ||
    fail "${context} was not passed exactly once as ${option} ${value}"
}

assert_trace_flag_once() {
  local trace_json="$1"
  local flag="$2"
  local context="${3:-CLI flag}"

  jq -e --arg flag "${flag}" '
    ([.[] | select(. == $flag)] | length) == 1
  ' <<< "${trace_json}" >/dev/null ||
    fail "${context} was not passed exactly once: ${flag}"
}

assert_trace_absent() {
  local trace_json="$1"
  local argument="$2"
  local context="${3:-unexpected CLI argument}"

  jq -e --arg argument "${argument}" 'index($argument) == null' \
    <<< "${trace_json}" >/dev/null ||
    fail "${context} was passed: ${argument}"
}

last_cli_trace() {
  tail -n 1 "${CLI_TRACE}"
}

write_body() {
  local output_file="$1"
  local cbor_hex="$2"
  local view_file="$3"

  jq -n --arg cbor "${cbor_hex}" --slurpfile view "${view_file}" '
    {
      type: "Tx ConwayEra",
      description: "Fake cardano-cli 11 transaction body",
      cborHex: $cbor,
      fakeView: $view[0]
    }
  ' > "${output_file}" || fail "could not write fake transaction body"
  chmod 0600 "${output_file}"
}

write_verification_key() {
  local output_file="$1"
  local key_id="$2"

  jq -n --arg cbor "5820${key_id}" '
    {
      type: "PaymentVerificationKeyShelley_ed25519",
      description: "Payment Verification Key",
      cborHex: $cbor
    }
  ' > "${output_file}" || fail "could not write verification key fixture"
  chmod 0600 "${output_file}"
}

write_signing_key() {
  local output_file="$1"
  local public_key="$2"

  jq -n --arg public "${public_key}" '
    {
      type: "PaymentSigningKeyShelley_ed25519",
      description: "Payment Signing Key",
      cborHex: "5820aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      fakePublic: $public
    }
  ' > "${output_file}" || fail "could not write signing key fixture"
  chmod 0600 "${output_file}"
}

assert_no_transaction_debris() {
  local debris=""

  debris="$(find "${TEST_ROOT}" -name '.cntools-transaction-*' -print -quit)"
  [[ -z "${debris}" ]] ||
    fail "transaction temporary artifact remained after cleanup: ${debris}"
}

for required_command in \
  awk bash cat chmod cmp cp date find grep head jq ln mktemp mv openssl \
  rm rmdir sleep sort stat tail wc xxd; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

for required_file in "${TRANSACTION_LIBRARY}" "${BUILD_LIBRARY}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" && -s "${required_file}" ]] ||
    fail "required CNTools source is missing or unsafe: ${required_file}"
done

bash -n "${TRANSACTION_LIBRARY}" "${BUILD_LIBRARY}" ||
  fail "transaction foundation sources have invalid Bash syntax"
assert_pinned_cardano_cli_versions

mkdir -p "${CNTOOLS_TMP_DIR}" "${OUTPUT_ROOT}"
chmod 0700 "${TEST_ROOT}" "${CNTOOLS_TMP_DIR}" "${OUTPUT_ROOT}"
: > "${CLI_TRACE}"
: > "${LOG_TRACE}"
chmod 0600 "${CLI_TRACE}" "${LOG_TRACE}"

jq -n '
  {
    "validity range": {"lower bound": null, "upper bound": null},
    "required signers (payment key hashes needed for scripts)": null,
    "reference inputs": null,
    scripts: [],
    witnesses: []
  }
' > "${BASE_VIEW}"
jq -n --arg credential_a "${CREDENTIAL_A}" \
  --arg credential_b "${CREDENTIAL_B}" '
  {
    "validity range": {"lower bound": 100, "upper bound": 200},
    "required signers (payment key hashes needed for scripts)":
      [$credential_a, $credential_b],
    "reference inputs": [],
    scripts: [],
    witnesses: []
  }
' > "${PLAN_VIEW}"
jq -n --arg script_hash "${SCRIPT_HASH}" \
  --arg credential "${CREDENTIAL_A}" '
  {
    "validity range": {"lower bound": 100, "upper bound": 200},
    "required signers (payment key hashes needed for scripts)": [$credential],
    "reference inputs": [],
    scripts: [{
      "script hash": $script_hash,
      "script data": {type: "native", script: "all [...]"}
    }],
    witnesses: []
  }
' > "${NATIVE_VIEW}"
chmod 0600 "${BASE_VIEW}" "${PLAN_VIEW}" "${NATIVE_VIEW}"

cat > "${FAKE_CLI}" <<'FAKE_CLI_EOF'
#!/usr/bin/env bash
set -euo pipefail

arg_value() {
  local requested="$1"
  shift
  while (( $# > 0 )); do
    if [[ "$1" == "${requested}" ]]; then
      (( $# >= 2 )) || exit 90
      printf '%s\n' "$2"
      return 0
    fi
    shift
  done
  return 1
}

transaction_id_for_cbor() {
  case "$1" in
    aa00|aa00ff) printf '%s\n' "${FAKE_TX_ID_A}" ;;
    aa01) printf '%s\n' "${FAKE_TX_ID_B}" ;;
    *) printf '%s\n' "${FAKE_TX_ID_C}" ;;
  esac
}

jq -cn --args '$ARGS.positional' -- "$@" >> "${FAKE_CLI_TRACE}"
if [[ -n "${FAKE_MUTATE_FILE:-}" && -n "${FAKE_MUTATE_MARKER:-}" &&
      ! -e "${FAKE_MUTATE_MARKER}" ]]; then
  jq '.signedTransaction.cborHex = "aa00ff"' \
    "${FAKE_MUTATE_FILE}" > "${FAKE_MUTATE_FILE}.next"
  mv "${FAKE_MUTATE_FILE}.next" "${FAKE_MUTATE_FILE}"
  : > "${FAKE_MUTATE_MARKER}"
fi
command_path="${1:-}/${2:-}/${3:-}"

case "${command_path}" in
  version//)
    printf 'cardano-cli %s - linux-x86_64\n' \
      "${FAKE_CLI_VERSION:-11.0.0.0}"
    ;;
  key/verification-key/*)
    signing_file="$(arg_value --signing-key-file "$@")"
    output_file="$(arg_value --verification-key-file "$@")"
    public_key="$(jq -er '.fakePublic' "${signing_file}")"
    jq -n --arg cbor "5820${public_key}" '
      {type: "PaymentVerificationKeyShelley_ed25519",
       description: "Payment Verification Key", cborHex: $cbor}
    ' > "${output_file}"
    ;;
  latest/stake-address/key-hash)
    public_key="$(arg_value --stake-verification-key "$@")"
    [[ "${public_key}" =~ ^[0-9a-f]{64}$ ]] || exit 91
    printf '%s\n' "${public_key:0:56}"
    ;;
  latest/transaction/policyid)
    script_file="$(arg_value --script-file "$@")"
    jq -e 'type == "object"' "${script_file}" >/dev/null
    printf '%s\n' "${FAKE_SCRIPT_HASH}"
    ;;
  latest/transaction/build|latest/transaction/build-estimate|latest/transaction/build-raw)
    output_file="$(arg_value --out-file "$@")"
    jq -n --arg cbor "${FAKE_BUILD_CBOR}" \
      --slurpfile view "${FAKE_BUILD_VIEW_FILE}" '
      {type: "Tx ConwayEra",
       description: "Fake cardano-cli 11 transaction body",
       cborHex: $cbor, fakeView: $view[0]}
    ' > "${output_file}"
    ;;
  latest/transaction/calculate-min-fee)
    printf '170000 Lovelace\n'
    ;;
  latest/transaction/txid)
    transaction_file="$(arg_value --tx-body-file "$@" 2>/dev/null ||
      arg_value --tx-file "$@")"
    cbor_hex="$(jq -er '.cborHex | ascii_downcase' "${transaction_file}")"
    transaction_id_for_cbor "${cbor_hex}"
    ;;
  debug/transaction/view)
    transaction_file="$(arg_value --tx-body-file "$@" 2>/dev/null ||
      arg_value --tx-file "$@")"
    jq -e '.fakeView' "${transaction_file}"
    ;;
  latest/transaction/assemble)
    body_file="$(arg_value --tx-body-file "$@")"
    output_file="$(arg_value --out-file "$@")"
    witnesses='[]'
    arguments=("$@")
    for (( index = 0; index < ${#arguments[@]}; index++ )); do
      [[ "${arguments[index]}" == "--witness-file" ]] || continue
      (( index + 1 < ${#arguments[@]} )) || exit 93
      witness_key="$(jq -er '.fakeKey' "${arguments[index + 1]}")"
      witnesses="$(jq -c --arg key "${witness_key}" \
        --arg signature "${FAKE_WITNESS_SIGNATURE}" '
        . + [{
          key: ("VKey (VerKeyEd25519DSIGN \"" + $key + "\")"),
          signature: ("SignedDSIGN (SigEd25519DSIGN \"" +
            $signature + "\")")
        }]
      ' <<< "${witnesses}")"
    done
    jq --argjson witnesses "${witnesses}" '
      .type = "Tx ConwayEra" |
      .description = "Fake assembled cardano-cli 11 transaction" |
      .fakeView.witnesses = $witnesses
    ' "${body_file}" > "${output_file}"
    ;;
  *)
    printf 'unsupported fake cardano-cli command: %s\n' "${command_path}" >&2
    exit 92
    ;;
esac
FAKE_CLI_EOF
chmod 0700 "${FAKE_CLI}"

export FAKE_CLI_TRACE="${CLI_TRACE}"
export FAKE_SCRIPT_HASH="${SCRIPT_HASH}"
export FAKE_WITNESS_SIGNATURE="${FAKE_SIGNATURE}"
export FAKE_TX_ID_A="${TX_ID_A}"
export FAKE_TX_ID_B="${TX_ID_B}"
export FAKE_TX_ID_C="${TX_ID_C}"
export FAKE_BUILD_CBOR="aa00"
export FAKE_BUILD_VIEW_FILE="${BASE_VIEW}"
export FAKE_CLI_VERSION="${TESTED_CARDANO_CLI_VERSION}"

# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/log.sh"
# shellcheck source=/dev/null
. "${TRANSACTION_LIBRARY}"
# shellcheck source=/dev/null
. "${BUILD_LIBRARY}"

CNTOOLS_ACTION_ID="transaction/foundation-test"
CNTOOLS_CLI="${FAKE_CLI}"
CNTOOLS_CLI_TIMEOUT="3"
CNTOOLS_TRANSACTION_TIMEOUT="3"
CNTOOLS_TIMEOUT_BIN=""
CNTOOLS_NETWORK="preview"
CNTOOLS_MODE="local"
CNTOOLS_LOCAL_CLI_CAPABLE="true"
CNTOOLS_SOCKET="${TEST_ROOT}/node.socket"

cntools_log() {
  printf '%s\t%s\t%s\n' \
    "${1:-INFO}" "${CNTOOLS_ACTION_ID:-session}" "${2:-}" >> "${LOG_TRACE}"
}

test_cli_version_contract() {
  local trace_before=0

  CNTOOLS_TRANSACTION_VALIDATED_CLI_PATH=""
  CNTOOLS_TRANSACTION_VALIDATED_CLI_VERSION=""
  export FAKE_CLI_VERSION="10.1.1.0"
  if cntools_transaction_require_cli; then
    fail "an unpinned Cardano CLI version was accepted"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" \
    "requires Cardano CLI ${TESTED_CARDANO_CLI_VERSION}" \
    "unpinned Cardano CLI diagnostic"

  CNTOOLS_TRANSACTION_VALIDATED_CLI_PATH=""
  CNTOOLS_TRANSACTION_VALIDATED_CLI_VERSION=""
  export FAKE_CLI_VERSION="${TESTED_CARDANO_CLI_VERSION}-rc1"
  if cntools_transaction_require_cli; then
    fail "a Cardano CLI prerelease was accepted as the pinned version"
  fi

  CNTOOLS_TRANSACTION_VALIDATED_CLI_PATH=""
  CNTOOLS_TRANSACTION_VALIDATED_CLI_VERSION=""
  export FAKE_CLI_VERSION="${TESTED_CARDANO_CLI_VERSION}"
  cntools_transaction_require_cli ||
    fail "the pinned Cardano CLI version was rejected"
  assert_eq "${CNTOOLS_TRANSACTION_VALIDATED_CLI_PATH}" "${FAKE_CLI}" \
    "validated Cardano CLI path"
  assert_eq "${CNTOOLS_TRANSACTION_VALIDATED_CLI_VERSION}" \
    "${TESTED_CARDANO_CLI_VERSION}" "validated Cardano CLI version"
  trace_before="$(wc -l < "${CLI_TRACE}")"
  cntools_transaction_require_cli ||
    fail "the cached Cardano CLI contract was rejected"
  assert_eq "$(wc -l < "${CLI_TRACE}")" "${trace_before}" \
    "cached Cardano CLI validation invocation count"
}

test_signer_plan_invariants() {
  local verification_a="${TEST_ROOT}/payment-a.vkey"
  local source_a="${TEST_ROOT}/payment-a.skey"
  local source_b="${TEST_ROOT}/payment-b.skey"
  local before=""

  cntools_transaction_plan_reset "Signer test" "Signer invariants" exact
  cntools_transaction_plan_add_public_signer \
    "Payment" required-signer "${KEY_A}" "" cli "" ||
    fail "first public signer was rejected"
  cntools_transaction_plan_add_public_signer \
    "Owner" spending "${KEY_A}" "${CREDENTIAL_A}" either "" ||
    fail "duplicate signer metadata could not be merged"
  jq -e --arg key "${KEY_A}" '
    length == 1 and .[0].keyId == $key and
    .[0].credential == ($key[0:56]) and
    .[0].preferredKind == "either" and
    .[0].labels == ["Owner", "Payment"] and
    .[0].roles == ["required-signer", "spending"]
  ' <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}" >/dev/null ||
    fail "duplicate signer registration did not merge deterministically"

  before="${CNTOOLS_TRANSACTION_PLAN_REQUIRED}"
  if cntools_transaction_plan_add_public_signer \
      "Mismatch" spending "${KEY_B}" "${WRONG_CREDENTIAL}" cli ""; then
    fail "signer with a mismatched credential hash was accepted"
  fi
  assert_eq "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}" "${before}" \
    "credential mismatch mutated the signer plan"

  cntools_transaction_plan_add_public_signer \
    "Ledger payment" spending "${KEY_B}" "" hardware ledger-main ||
    fail "hardware signer group was rejected"
  cntools_transaction_plan_add_public_change_key \
    "Ledger change" "${KEY_C}" ledger-main ||
    fail "change key in the signer's hardware session was rejected"
  jq -e --arg key "${KEY_C}" '
    length == 1 and .[0].keyId == $key and
    .[0].hardwareGroup == "ledger-main"
  ' <<< "${CNTOOLS_TRANSACTION_PLAN_CHANGE_KEYS}" >/dev/null ||
    fail "hardware change-key group was not recorded"
  if cntools_transaction_plan_add_public_change_key \
      "Wrong device" "${KEY_C}" ledger-other; then
    fail "change key outside every signer hardware session was accepted"
  fi
  cntools_transaction_plan_add_public_signer \
    "Ledger backup" spending "${KEY_D}" "" hardware ledger-other ||
    fail "second hardware signer group was rejected"
  before="${CNTOOLS_TRANSACTION_PLAN_CHANGE_KEYS}"
  if cntools_transaction_plan_add_public_change_key \
      "Conflicting change" "${KEY_C}" ledger-other; then
    fail "one change key was accepted in conflicting hardware groups"
  fi
  assert_eq "${CNTOOLS_TRANSACTION_PLAN_CHANGE_KEYS}" "${before}" \
    "change-key group conflict mutated the change-key plan"
  assert_eq "$(cntools_transaction_plan_witness_count)" 3 \
    "deduplicated signer witness count"
  before="${CNTOOLS_TRANSACTION_PLAN_REQUIRED}"
  if cntools_transaction_plan_add_public_signer \
      "Ledger duplicate" spending "${KEY_B}" "" hardware ledger-other; then
    fail "one public key was accepted in conflicting hardware groups"
  fi
  assert_eq "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}" "${before}" \
    "hardware-group conflict mutated the signer plan"

  write_verification_key "${verification_a}" "${KEY_A}"
  write_signing_key "${source_a}" "${KEY_A}"
  write_signing_key "${source_b}" "${KEY_B}"
  cntools_transaction_plan_reset "Source test" "Source identity" exact
  if cntools_transaction_plan_add_signer \
      "Payment" spending "${verification_a}" "${source_b}" "" ""; then
    fail "a signing source mismatched to its verification key was accepted"
  fi
  cntools_transaction_plan_add_signer \
    "Payment" spending "${verification_a}" "${source_a}" "" "" ||
    fail "a matching CLI signing source was rejected"
  assert_eq "${CNTOOLS_TRANSACTION_RUNTIME_SOURCES[${KEY_A}]}" \
    "${source_a}" "runtime signing source registration"
}

test_native_script_and_validity_invariants() {
  local script_file="${TEST_ROOT}/native.script"
  local invalid_script="${TEST_ROOT}/invalid-native.script"
  local body_file="${TEST_ROOT}/native.body"
  local tampered_body="${TEST_ROOT}/native-tampered.body"
  local package_file="${OUTPUT_ROOT}/native.package.json"
  local tampered_package="${TEST_ROOT}/native-package-tampered.json"
  local reference_view="${TEST_ROOT}/reference-view.json"
  local reference_extra_view="${TEST_ROOT}/reference-extra-view.json"
  local reference_missing_view="${TEST_ROOT}/reference-missing-view.json"
  local reference_body="${TEST_ROOT}/reference.body"
  local reference_extra_body="${TEST_ROOT}/reference-extra.body"
  local reference_missing_body="${TEST_ROOT}/reference-missing.body"
  local reference_package="${OUTPUT_ROOT}/reference.package.json"
  local false_exact_package="${TEST_ROOT}/reference-false-exact.json"
  local stripped_reference_package="${TEST_ROOT}/reference-stripped.json"
  local missing_reference_package="${TEST_ROOT}/reference-missing-input.json"
  local invalid_reference_package="${TEST_ROOT}/reference-invalid-input.json"

  cntools_transaction_plan_reset "Native test" "Native script" exact
  cntools_transaction_plan_set_validity 100 200 ||
    fail "valid transaction interval was rejected"
  cntools_transaction_plan_add_public_signer \
    "Native signer" native-script "${KEY_A}" "" cli "" ||
    fail "native-script signer was rejected"
  jq -n --arg credential "${CREDENTIAL_A}" '
    {type: "all", scripts: [
      {type: "sig", keyHash: $credential},
      {type: "after", slot: 100},
      {type: "before", slot: 200}
    ]}
  ' > "${script_file}"
  chmod 0600 "${script_file}"
  cntools_transaction_plan_add_native_script \
    "Policy" mint "${script_file}" "${KEY_A}" ||
    fail "satisfied embedded native script was rejected"
  jq -e --arg hash "${SCRIPT_HASH}" --arg key "${KEY_A}" '
    length == 1 and .[0].scriptHash == $hash and
    .[0].source == "embedded" and .[0].purpose == "mint" and
    .[0].referenceInput == null and
    .[0].selectedKeyIds == [$key]
  ' <<< "${CNTOOLS_TRANSACTION_PLAN_NATIVE_SCRIPTS}" >/dev/null ||
    fail "native-script plan metadata is incomplete"

  write_body "${body_file}" aa01 "${NATIVE_VIEW}"
  cntools_transaction_body_matches_plan "${body_file}" ||
    fail "body matching the native-script plan was rejected"
  cntools_transaction_package_create "${body_file}" "${package_file}" ||
    fail "native-script transaction package could not be created"
  jq -e --arg hash "${SCRIPT_HASH}" '
    (.signedTransaction == null) and
    ((.signing.nativeScripts | length) == 1) and
    .signing.nativeScripts[0].scriptHash == $hash
  ' "${package_file}" >/dev/null ||
    fail "native-script package metadata is incomplete"
  jq '.signing.nativeScripts[0].scriptHash =
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' \
    "${package_file}" > "${tampered_package}"
  chmod 0600 "${tampered_package}"
  if cntools_transaction_package_load "${tampered_package}" >/dev/null 2>&1; then
    fail "package with a substituted native-script hash was accepted"
  fi
  jq '.fakeView."validity range"."upper bound" = 201' \
    "${body_file}" > "${tampered_body}"
  chmod 0600 "${tampered_body}"
  if cntools_transaction_body_matches_plan "${tampered_body}"; then
    fail "body with a mismatched validity interval was accepted"
  fi

  jq '.extra = true' "${script_file}" > "${invalid_script}"
  chmod 0600 "${invalid_script}"
  if cntools_transaction_native_script_valid "${invalid_script}"; then
    fail "native script with an unknown field was accepted"
  fi
  if cntools_transaction_plan_set_validity 200 200; then
    fail "empty transaction validity interval was accepted"
  fi

  cntools_transaction_plan_reset "Unsatisfied" "Missing validity" exact
  cntools_transaction_plan_add_public_signer \
    "Native signer" native-script "${KEY_A}" "" cli "" ||
    fail "native signer setup failed"
  if cntools_transaction_plan_add_native_script \
      "Policy" mint "${script_file}" "${KEY_A}"; then
    fail "time-locked native script without matching validity was accepted"
  fi

  cntools_transaction_plan_reset "Reference" "Manual assurance" exact
  cntools_transaction_plan_set_validity 100 200
  cntools_transaction_plan_add_public_signer \
    "Native signer" native-script "${KEY_A}" "" cli ""
  cntools_transaction_reference_input_valid \
    "${REFERENCE_TX_ID}#4294967295" ||
    fail "maximum uint32 reference output index was rejected"
  if cntools_transaction_reference_input_valid \
      "${REFERENCE_TX_ID_UPPER}#0"; then
    fail "non-canonical uppercase reference transaction ID was accepted"
  fi
  if cntools_transaction_plan_add_native_reference_script \
      "Reference policy" mint "${script_file}" \
      "${REFERENCE_TX_ID}#00" "${KEY_A}"; then
    fail "reference script accepted a non-canonical output index"
  fi
  if cntools_transaction_plan_add_native_reference_script \
      "Reference policy" mint "${script_file}" \
      "${REFERENCE_TX_ID}#4294967296" "${KEY_A}"; then
    fail "reference script accepted an output index larger than uint32"
  fi
  cntools_transaction_plan_add_native_reference_script \
    "Reference policy" mint "${script_file}" \
    "${REFERENCE_INPUT}" "${KEY_A}" ||
    fail "satisfied native reference script was rejected"
  assert_eq "${CNTOOLS_TRANSACTION_PLAN_ASSURANCE}" manual \
    "reference-script assurance"
  jq -e --arg reference_input "${REFERENCE_INPUT}" '
    length == 1 and .[0].source == "reference" and
    .[0].referenceInput == $reference_input
  ' <<< "${CNTOOLS_TRANSACTION_PLAN_NATIVE_SCRIPTS}" >/dev/null ||
    fail "native reference-script input was not recorded in the signer plan"
  jq '.scripts = [] | ."reference inputs" = []' \
    "${NATIVE_VIEW}" > "${reference_missing_view}"
  chmod 0600 "${reference_missing_view}"
  write_body \
    "${reference_missing_body}" aa02 "${reference_missing_view}"
  if cntools_transaction_body_matches_plan "${reference_missing_body}"; then
    fail "reference-script plan accepted a body missing its reference input"
  fi
  jq --arg reference_input "${REFERENCE_INPUT}" '
    .scripts = [] | ."reference inputs" = [$reference_input]
  ' "${NATIVE_VIEW}" > "${reference_view}"
  jq --arg reference_input "${REFERENCE_INPUT}" \
    --arg extra_input "${REFERENCE_INPUT_OTHER}" '
    .scripts = [] | ."reference inputs" = [$reference_input, $extra_input]
  ' "${NATIVE_VIEW}" > "${reference_extra_view}"
  chmod 0600 "${reference_view}" "${reference_extra_view}"
  write_body "${reference_body}" aa02 "${reference_view}"
  write_body "${reference_extra_body}" aa02 "${reference_extra_view}"
  cntools_transaction_body_matches_plan "${reference_extra_body}" ||
    fail "additional non-script reference inputs were incorrectly rejected"
  cntools_transaction_package_create \
    "${reference_body}" "${reference_package}" ||
    fail "reference-script package could not be created"
  jq -e --arg reference_input "${REFERENCE_INPUT}" '
    .signing.nativeScripts[0].referenceInput == $reference_input
  ' "${reference_package}" >/dev/null ||
    fail "reference-script input was not preserved in the package"
  jq --arg reference_input "${REFERENCE_INPUT_OTHER}" '
    .signing.nativeScripts[0].referenceInput = $reference_input
  ' "${reference_package}" > "${missing_reference_package}"
  chmod 0600 "${missing_reference_package}"
  cntools_transaction_package_structure_valid "${missing_reference_package}" ||
    fail "alternate canonical reference-input fixture failed schema validation"
  if cntools_transaction_package_load \
      "${missing_reference_package}" >/dev/null 2>&1; then
    fail "package with a reference input absent from its body was accepted"
  fi
  jq '.signing.nativeScripts[0].referenceInput = null' \
    "${reference_package}" > "${invalid_reference_package}"
  chmod 0600 "${invalid_reference_package}"
  if cntools_transaction_package_structure_valid \
      "${invalid_reference_package}"; then
    fail "reference-script package without a reference input passed schema validation"
  fi
  jq '.signing.assurance = "exact"' \
    "${reference_package}" > "${false_exact_package}"
  chmod 0600 "${false_exact_package}"
  if cntools_transaction_package_structure_valid "${false_exact_package}"; then
    fail "reference-script package was allowed to claim exact assurance"
  fi
  jq '.signing.nativeScripts = [] | .signing.assurance = "exact"' \
    "${reference_package}" > "${stripped_reference_package}"
  chmod 0600 "${stripped_reference_package}"
  cntools_transaction_package_structure_valid "${stripped_reference_package}" ||
    fail "stripped reference-input fixture failed schema validation"
  if cntools_transaction_package_load \
      "${stripped_reference_package}" >/dev/null 2>&1; then
    fail "reference-input transaction accepted after manual assurance metadata was stripped"
  fi
}

test_witness_identity_binding() {
  local body_file="${TEST_ROOT}/witness.body"
  local witness_file="${TEST_ROOT}/payment.witness"

  write_body "${body_file}" aa00 "${BASE_VIEW}"
  jq -n --arg key "${KEY_A}" '
    {
      type: "TxWitness ConwayEra",
      description: "Fake key witness",
      cborHex: "00",
      fakeKey: $key
    }
  ' > "${witness_file}"
  chmod 0600 "${witness_file}"
  cntools_transaction_witness_matches_key \
    "${body_file}" "${witness_file}" "${KEY_A}" ||
    fail "witness matching its expected public key was rejected"
  if cntools_transaction_witness_matches_key \
      "${body_file}" "${witness_file}" "${KEY_B}"; then
    fail "witness was accepted for a different public key"
  fi
}

test_builder_contracts() {
  local output_file="${OUTPUT_ROOT}/build.body"
  local estimate_file="${OUTPUT_ROOT}/estimate.body"
  local raw_file="${OUTPUT_ROOT}/raw.body"
  local protocol_file="${TEST_ROOT}/protocol.json"
  local protected_file="${OUTPUT_ROOT}/protected.body"
  local trace_json=""
  local forbidden=""
  local minimum_fee=""
  local oversized_argument=""

  cntools_transaction_plan_reset "Build test" "Owned arguments" exact
  cntools_transaction_plan_set_validity 100 200
  cntools_transaction_plan_add_public_signer \
    "Required signer" required-signer "${KEY_A}" "" cli ""
  cntools_transaction_plan_add_public_signer \
    "Input signer" spending "${KEY_B}" "" cli ""
  export FAKE_BUILD_CBOR="aa00"
  export FAKE_BUILD_VIEW_FILE="${PLAN_VIEW}"

  # A real socket is unnecessary for a deterministic CLI fixture. The build
  # contract below still verifies that the configured absolute socket is owned
  # by the foundation and forwarded exactly once.
  cntools_transaction_local_backend_ready() { return 0; }
  : > "${CLI_TRACE}"
  cntools_transaction_build_body build "${output_file}" -- \
    --tx-in 'deadbeef#0' --tx-out 'addr_test1+1000000' ||
    fail "pinned auto-balanced builder contract failed"
  trace_json="$(last_cli_trace)"
  jq -e '.[0:3] == ["latest", "transaction", "build"]' \
    <<< "${trace_json}" >/dev/null || fail "wrong auto-balanced CLI command"
  assert_trace_option_once "${trace_json}" --required-signer-hash \
    "${CREDENTIAL_A}" "required signer"
  assert_trace_option_once "${trace_json}" --required-signer-hash \
    "${CREDENTIAL_B}" "input signer binding"
  assert_trace_option_once "${trace_json}" --invalid-before 100 \
    "lower validity bound"
  assert_trace_option_once "${trace_json}" --invalid-hereafter 200 \
    "upper validity bound"
  assert_trace_option_once "${trace_json}" --witness-override 2 \
    "auto-balanced witness count"
  assert_trace_option_once "${trace_json}" --socket-path \
    "${CNTOOLS_SOCKET}" "local node socket"
  assert_trace_option_once "${trace_json}" --testnet-magic 2 \
    "preview network"
  assert_trace_option_once "${trace_json}" --tx-in 'deadbeef#0' \
    "caller transaction input"
  assert_trace_option_once "${trace_json}" --tx-out \
    'addr_test1+1000000' "caller transaction output"
  assert_trace_flag_once "${trace_json}" --out-file \
    "foundation output option"
  jq -e --arg root "${OUTPUT_ROOT}/.cntools-transaction-build-body." '
    [range(0; length) as $index |
      select(.[$index] == "--out-file") | .[$index + 1]] as $outputs |
    ($outputs | length) == 1 and ($outputs[0] | startswith($root))
  ' <<< "${trace_json}" >/dev/null ||
    fail "builder did not stage output privately beside its destination"
  assert_trace_flag_once "${trace_json}" --out-canonical-cbor \
    "canonical CBOR flag"
  assert_trace_absent "${trace_json}" --shelley-key-witnesses \
    "estimate-only witness option"
  assert_eq "$(file_mode "${output_file}")" 600 "built body mode"

  cntools_transaction_build_body build-estimate "${estimate_file}" -- \
    --tx-in 'deadbeef#0' --tx-out 'addr_test1+1000000' ||
    fail "pinned build-estimate contract failed"
  trace_json="$(last_cli_trace)"
  assert_trace_option_once "${trace_json}" --shelley-key-witnesses 2 \
    "estimated Shelley witness count"
  assert_trace_option_once "${trace_json}" --byron-key-witnesses 0 \
    "estimated Byron witness count"
  assert_trace_option_once "${trace_json}" --required-signer-hash \
    "${CREDENTIAL_A}" "estimated required signer"
  assert_trace_option_once "${trace_json}" --required-signer-hash \
    "${CREDENTIAL_B}" "estimated input signer binding"
  assert_trace_flag_once "${trace_json}" --out-canonical-cbor \
    "estimated canonical CBOR flag"
  assert_trace_absent "${trace_json}" --socket-path \
    "live-only socket option"
  assert_trace_absent "${trace_json}" --testnet-magic \
    "live-only network option"

  cntools_transaction_build_body build-raw "${raw_file}" -- \
    --tx-in 'deadbeef#0' --tx-out 'addr_test1+1000000' --fee 170000 ||
    fail "pinned build-raw contract failed"
  trace_json="$(last_cli_trace)"
  assert_trace_absent "${trace_json}" --witness-override \
    "balanced-builder witness option"
  assert_trace_absent "${trace_json}" --shelley-key-witnesses \
    "estimate-builder witness option"
  assert_trace_absent "${trace_json}" --socket-path \
    "live-only socket option"
  assert_trace_option_once "${trace_json}" --required-signer-hash \
    "${CREDENTIAL_A}" "raw required signer"
  assert_trace_option_once "${trace_json}" --required-signer-hash \
    "${CREDENTIAL_B}" "raw input signer binding"
  assert_trace_option_once "${trace_json}" --invalid-before 100 \
    "raw lower validity bound"
  assert_trace_option_once "${trace_json}" --invalid-hereafter 200 \
    "raw upper validity bound"
  assert_trace_flag_once "${trace_json}" --out-canonical-cbor \
    "raw canonical CBOR flag"

  printf '{"txFeeFixed":155381,"txFeePerByte":44}\n' > "${protocol_file}"
  chmod 0600 "${protocol_file}"
  cntools_transaction_calculate_min_fee_into minimum_fee \
    "${raw_file}" 1 2 "${protocol_file}" 123 ||
    fail "pinned minimum-fee command contract failed"
  assert_eq "${minimum_fee}" 170000 "minimum-fee result"
  trace_json="$(last_cli_trace)"
  jq -e '.[0:3] == ["latest", "transaction", "calculate-min-fee"]' \
    <<< "${trace_json}" >/dev/null || fail "wrong minimum-fee CLI command"
  assert_trace_option_once "${trace_json}" --tx-in-count 1 \
    "minimum-fee input count"
  assert_trace_option_once "${trace_json}" --tx-out-count 2 \
    "minimum-fee output count"
  assert_trace_option_once "${trace_json}" --witness-count 2 \
    "minimum-fee witness count"
  assert_trace_option_once "${trace_json}" --byron-witness-count 0 \
    "minimum-fee Byron witness count"
  assert_trace_option_once "${trace_json}" --reference-script-size 123 \
    "minimum-fee reference-script size"
  assert_trace_option_once "${trace_json}" --protocol-params-file \
    "${protocol_file}" "minimum-fee protocol parameters"
  assert_trace_flag_once "${trace_json}" --output-text \
    "minimum-fee text output"

  for forbidden in \
    --out-file --out-file=bad --out-canonical-cbor \
    --socket-path --socket-path=bad --mainnet --testnet-magic \
    --testnet-magic=2 --witness-override --witness-override=2 \
    --shelley-key-witnesses --shelley-key-witnesses=2 \
    --byron-key-witnesses --byron-key-witnesses=0 \
    --invalid-before --invalid-before=100 \
    --lower-bound --lower-bound=100 \
    --invalid-hereafter --invalid-hereafter=200 \
    --upper-bound --upper-bound=200 --ttl --ttl=200 \
    --tx-body-file --tx-body-file=bad \
    --calculate-plutus-script-cost --calculate-plutus-script-cost=bad \
    --required-signer --required-signer=bad \
    --required-signer-hash --required-signer-hash=bad; do
    if cntools_transaction_build_arguments_safe build "${forbidden}" filler; then
      fail "caller was allowed to override foundation option ${forbidden}"
    fi
  done

  for forbidden in $'--tx-out\taddr_test1+1000000' \
    $'--tx-out\baddr_test1+1000000' \
    $'--tx-out\177addr_test1+1000000'; do
    if cntools_transaction_build_arguments_safe build "${forbidden}" filler; then
      fail "caller argument containing a control character was accepted"
    fi
  done

  printf -v oversized_argument '%*s' \
    "$((CNTOOLS_TRANSACTION_MAX_ARGUMENT_BYTES + 1))" ''
  if cntools_transaction_build_arguments_safe \
      build --tx-out "${oversized_argument}"; then
    fail "an argument larger than the safe CLI invocation limit was accepted"
  fi

  printf 'preserve-me\n' > "${protected_file}"
  if cntools_transaction_build_body build "${protected_file}" -- \
      --tx-in 'deadbeef#0' --tx-out 'addr_test1+1000000'; then
    fail "builder overwrote an existing output path"
  fi
  assert_eq "$(< "${protected_file}")" preserve-me \
    "no-clobber body output"
}

test_package_schema_and_tamper_rejection() {
  local body_file="${TEST_ROOT}/zero.body"
  local package_file="${OUTPUT_ROOT}/zero.package.json"
  local large_padding_file="${TEST_ROOT}/large-padding.txt"
  local large_body_file="${TEST_ROOT}/large.body"
  local large_package_file="${OUTPUT_ROOT}/large.package.json"
  local signer_body="${TEST_ROOT}/signer.body"
  local signer_package="${OUTPUT_ROOT}/signer.package.json"
  local wrong_credential_package="${TEST_ROOT}/wrong-credential.json"
  local removed_signer_package="${TEST_ROOT}/removed-signer.json"
  local mutable_package="${TEST_ROOT}/mutable.package.json"
  local mutation_marker="${TEST_ROOT}/mutable.triggered"
  local protected_file="${OUTPUT_ROOT}/protected.package.json"
  local mutation=""
  local context=""
  local tampered_file=""

  write_body "${body_file}" aa00 "${BASE_VIEW}"
  cntools_transaction_plan_reset "Keyless test" "Zero witnesses" exact
  cntools_transaction_plan_set_summary \
    '{"operation":"fixture","amount":1000000}' ||
    fail "valid intent summary was rejected"
  cntools_transaction_package_create "${body_file}" "${package_file}" ||
    fail "zero-witness package creation failed: ${CNTOOLS_TRANSACTION_ERROR}"
  assert_eq "$(file_mode "${package_file}")" 600 "package mode"
  cntools_transaction_package_structure_valid "${package_file}" ||
    fail "generated package failed structural validation"
  cntools_transaction_package_load "${package_file}" ||
    fail "generated package failed semantic validation"
  assert_eq "${CNTOOLS_TRANSACTION_COMPLETE}" Y \
    "zero-witness package completion"
  assert_eq "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" 0 \
    "zero-witness required count"
  assert_eq "${CNTOOLS_TRANSACTION_WITNESS_COUNT}" 0 \
    "zero-witness recorded count"
  assert_eq "${CNTOOLS_TRANSACTION_ID}" "${TX_ID_A}" \
    "zero-witness transaction ID"
  jq -e --arg schema "${CNTOOLS_TRANSACTION_SCHEMA}" '
    .schema == $schema and .schemaVersion == 1 and
    .network == {name: "preview", magic: 2} and
    .transaction.id == $ENV.FAKE_TX_ID_A and
    .transaction.hardwarePrepared == false and
    .signing.required == [] and .signing.changeKeys == [] and
    .signing.nativeScripts == [] and .signing.witnesses == [] and
    .signedTransaction != null
  ' "${package_file}" >/dev/null ||
    fail "generated package does not satisfy the portable schema"

  # Keep transaction bodies and intent data file-backed. Linux limits any one
  # command-line argument to roughly 128 KiB even when ARG_MAX is much larger;
  # metadata and scripts can legitimately push a transaction beyond that.
  awk 'BEGIN { for (i = 0; i < 196608; i++) printf "x" }' \
    > "${large_padding_file}" || fail "could not create large-body fixture"
  jq --rawfile padding "${large_padding_file}" \
    '.largePadding = $padding' "${body_file}" > "${large_body_file}" ||
    fail "could not create large transaction body"
  chmod 0600 "${large_padding_file}" "${large_body_file}"
  cntools_transaction_package_create \
    "${large_body_file}" "${large_package_file}" ||
    fail "large transaction package creation failed: ${CNTOOLS_TRANSACTION_ERROR}"
  jq -e '
    (.transaction.body.largePadding | length) == 196608 and
    (.signedTransaction.largePadding | length) == 196608
  ' "${large_package_file}" >/dev/null ||
    fail "large transaction data was not preserved through packaging and assembly"

  while IFS=$'\t' read -r mutation context; do
    tampered_file="${TEST_ROOT}/tampered-${context}.json"
    jq "${mutation}" "${package_file}" > "${tampered_file}"
    chmod 0600 "${tampered_file}"
    if cntools_transaction_package_load "${tampered_file}" >/dev/null 2>&1; then
      fail "tampered package was accepted: ${context}"
    fi
  done <<'TAMPER_CASES'
.transaction.id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"	id
.transaction.body.cborHex = "aa02"	body
.signedTransaction.cborHex = "aa02"	signed
.signedTransaction.cborHex = "aa00ff"	signed-canonical
.validity.invalidBefore = 1	validity
.intent.summary.bad = "\n"	summary
.unexpected = true	unknown-field
TAMPER_CASES

  write_body "${signer_body}" aa00 "${PLAN_VIEW}"
  cntools_transaction_plan_reset "Signer package" "Credential binding" exact
  cntools_transaction_plan_set_validity 100 200 ||
    fail "signer-package validity setup failed"
  cntools_transaction_plan_add_public_signer \
    "Input owner" spending "${KEY_A}" "" cli "" ||
    fail "signer-package plan setup failed"
  cntools_transaction_plan_add_public_signer \
    "Second input owner" spending "${KEY_B}" "" cli "" ||
    fail "second signer-package plan setup failed"
  cntools_transaction_package_create "${signer_body}" "${signer_package}" ||
    fail "incomplete signer package creation failed"
  jq --arg credential "${CREDENTIAL_C}" \
    '.signing.required[0].credential = $credential' \
    "${signer_package}" > "${wrong_credential_package}"
  chmod 0600 "${wrong_credential_package}"
  cntools_transaction_package_structure_valid "${wrong_credential_package}" ||
    fail "wrong-credential fixture should pass structural validation"
  if cntools_transaction_package_load \
      "${wrong_credential_package}" >/dev/null 2>&1; then
    fail "package keyId was accepted with a different derived credential"
  fi
  jq 'del(.signing.required[1])' \
    "${signer_package}" > "${removed_signer_package}"
  chmod 0600 "${removed_signer_package}"
  cntools_transaction_package_structure_valid "${removed_signer_package}" ||
    fail "removed-signer fixture should pass structural validation"
  if cntools_transaction_package_load \
      "${removed_signer_package}" >/dev/null 2>&1; then
    fail "package accepted a signer plan missing a body-bound credential"
  fi

  cp "${package_file}" "${mutable_package}"
  chmod 0600 "${mutable_package}"
  export FAKE_MUTATE_FILE="${mutable_package}"
  export FAKE_MUTATE_MARKER="${mutation_marker}"
  cntools_transaction_package_load "${mutable_package}" ||
    fail "stable package snapshot was affected by a mid-load source mutation"
  unset FAKE_MUTATE_FILE FAKE_MUTATE_MARKER
  [[ -f "${mutation_marker}" ]] ||
    fail "mutable package fixture did not trigger during semantic validation"
  jq -e '.signedTransaction.cborHex == "aa00ff"' \
    "${mutable_package}" >/dev/null ||
    fail "mutable package source did not change during the snapshot test"
  assert_eq "${CNTOOLS_TRANSACTION_ID}" "${TX_ID_A}" \
    "snapshot-backed package transaction ID"

  printf 'preserve-package\n' > "${protected_file}"
  if cntools_transaction_package_create "${body_file}" "${protected_file}"; then
    fail "package publication overwrote an existing output path"
  fi
  assert_eq "$(< "${protected_file}")" preserve-package \
    "no-clobber package output"

  tampered_file="${TEST_ROOT}/malformed-envelope.json"
  printf '%s\n' \
    '{"type":"Tx ConwayEra","description":"bad","cborHex":"abc"}' \
    > "${tampered_file}"
  chmod 0600 "${tampered_file}"
  if cntools_transaction_envelope_kind_into context "${tampered_file}"; then
    fail "odd-length transaction CBOR was accepted"
  fi
}

test_hardware_group_package_invariants() {
  local source_package="${OUTPUT_ROOT}/zero.package.json"
  local partial_package="${TEST_ROOT}/partial-hardware.json"
  local premature_signed_package="${TEST_ROOT}/premature-signed-hardware.json"
  local complete_package="${TEST_ROOT}/complete-hardware.json"
  local unassembled_package="${TEST_ROOT}/unassembled-hardware.json"
  local wrong_kind_package="${TEST_ROOT}/wrong-kind-hardware.json"
  local created_at="2026-01-01T00:00:00Z"

  jq --arg key_a "${KEY_A}" --arg key_b "${KEY_B}" \
    --arg credential_a "${CREDENTIAL_A}" \
    --arg credential_b "${CREDENTIAL_B}" \
    --arg created_at "${created_at}" '
    .signedTransaction = null |
    .signing.required = [
      {keyId: $key_a, credential: $credential_a,
       hardwareGroup: "ledger-main", labels: ["Payment"],
       roles: ["spending"], preferredKind: "hardware"},
      {keyId: $key_b, credential: $credential_b,
       hardwareGroup: "ledger-main", labels: ["Stake"],
       roles: ["certificate"], preferredKind: "hardware"}
    ] |
    .transaction.body.fakeView[
      "required signers (payment key hashes needed for scripts)"
    ] = [$credential_a, $credential_b] |
    .signing.witnesses = [{
      createdAt: $created_at, keyId: $key_a, kind: "hardware",
      witness: {type: "TxWitness ConwayEra", description: "fixture",
                cborHex: "00", fakeKey: $key_a}
    }]
  ' "${source_package}" > "${partial_package}"
  chmod 0600 "${partial_package}"
  cntools_transaction_package_structure_valid "${partial_package}" ||
    fail "partial hardware fixture failed base schema validation"
  if cntools_transaction_package_hardware_groups_valid "${partial_package}"; then
    fail "partially witnessed hardware session was accepted"
  fi

  jq --arg key_a "${KEY_A}" --arg key_b "${KEY_B}" \
    --arg created_at "${created_at}" '
    .signing.witnesses += [{
      createdAt: $created_at, keyId: $key_b, kind: "hardware",
      witness: {type: "TxWitness ConwayEra", description: "fixture",
                cborHex: "01", fakeKey: $key_b}
    }] |
    .signedTransaction = (.transaction.body |
      .description = "Fake assembled cardano-cli 11 transaction" |
      .fakeView.witnesses = [
        {
          key: ("VKey (VerKeyEd25519DSIGN \"" + $key_a + "\")"),
          signature: ("SignedDSIGN (SigEd25519DSIGN \"" +
            $ENV.FAKE_WITNESS_SIGNATURE + "\")")
        },
        {
          key: ("VKey (VerKeyEd25519DSIGN \"" + $key_b + "\")"),
          signature: ("SignedDSIGN (SigEd25519DSIGN \"" +
            $ENV.FAKE_WITNESS_SIGNATURE + "\")")
        }
      ])
  ' "${partial_package}" > "${complete_package}"
  chmod 0600 "${complete_package}"
  cntools_transaction_package_hardware_groups_valid "${complete_package}" ||
    fail "complete hardware signing session was rejected"
  cntools_transaction_package_load "${complete_package}" ||
    fail "complete hardware package failed semantic validation"
  assert_eq "${CNTOOLS_TRANSACTION_COMPLETE}" Y \
    "complete hardware package state"

  jq '.signedTransaction = null' \
    "${complete_package}" > "${unassembled_package}"
  chmod 0600 "${unassembled_package}"
  if cntools_transaction_package_structure_valid "${unassembled_package}"; then
    fail "fully witnessed package without a signed transaction was accepted"
  fi
  cntools_transaction_package_structure_valid "${unassembled_package}" Y ||
    fail "internal pending-assembly state was rejected structurally"
  cntools_transaction_package_load "${unassembled_package}" Y ||
    fail "internal pending-assembly state was rejected semantically"
  assert_eq "${CNTOOLS_TRANSACTION_COMPLETE}" N \
    "pending-assembly package completion state"

  jq --slurpfile complete "${complete_package}" \
    '.signedTransaction = $complete[0].signedTransaction' \
    "${partial_package}" > "${premature_signed_package}"
  chmod 0600 "${premature_signed_package}"
  if cntools_transaction_package_structure_valid \
      "${premature_signed_package}"; then
    fail "signed transaction was accepted before every witness was present"
  fi

  jq '.signing.witnesses[0].kind = "cli"' \
    "${complete_package}" > "${wrong_kind_package}"
  chmod 0600 "${wrong_kind_package}"
  if cntools_transaction_package_structure_valid "${wrong_kind_package}"; then
    fail "witness kind conflicting with signer requirement was accepted"
  fi
}

test_pinned_witness_signature_verification() {
  local transaction_id="edef927af962664ed7a02bedfa913c7f1cd271494871c25ee7de66e941d83c79"
  local public_key="8e090717d4c91437d3b8c467acc850197485913efdbfb48114a4d6cf0ca2dc02"
  local signature="28230d2507267600d17c7f062d9f3184f4686af570c31e2f9ed652d339d776dcd72fccf30dd17bc077d2615845bbad64fd6ddffdba5b2874651d0c3533e10d0b"
  local invalid_signature=""
  local witnesses=""
  local decoded=""
  local view=""
  local old_openssl="${TEST_ROOT}/openssl-1.1"
  local fallback_bin="${TEST_ROOT}/openssl-fallback-bin"
  local fallback_openssl3="${TEST_ROOT}/openssl-fallback-bin/openssl3"
  local real_openssl=""
  local real_xxd=""
  local original_path="${PATH}"

  real_openssl="$(type -P openssl 2>/dev/null || true)"
  real_xxd="$(type -P xxd 2>/dev/null || true)"
  [[ "${real_openssl}" = /* && "${real_xxd}" = /* ]] ||
    fail "OpenSSL 3 and xxd are required for witness verification tests"
  CNTOOLS_TRANSACTION_OPENSSL="${real_openssl}"
  CNTOOLS_TRANSACTION_XXD="${real_xxd}"
  witnesses="$(jq -cn --arg key "${public_key}" --arg sig "${signature}" \
    '[{keyId: $key, signature: $sig}]')"
  view="$(jq -cn --arg key "${public_key}" --arg sig "${signature}" '
    {witnesses: [{
      key: ("VKey (VerKeyEd25519DSIGN \"" + $key + "\")"),
      signature: ("SignedDSIGN (SigEd25519DSIGN \"" + $sig + "\")")
    }]}
  ')"
  cntools_transaction_view_witnesses_into decoded "${view}" ||
    fail "pinned cardano-cli witness view format was not parsed"
  assert_eq "${decoded}" "${witnesses}" \
    "pinned witness key/signature extraction"
  cntools_transaction_witness_signatures_valid \
    "${transaction_id}" "${witnesses}" ||
    fail "official pinned cardano-cli witness was not cryptographically valid: ${CNTOOLS_TRANSACTION_ERROR}"

  invalid_signature="f${signature:1}"
  witnesses="$(jq -cn --arg key "${public_key}" \
    --arg sig "${invalid_signature}" '[{keyId: $key, signature: $sig}]')"
  if cntools_transaction_witness_signatures_valid \
      "${transaction_id}" "${witnesses}"; then
    fail "mutated Ed25519 witness signature was accepted"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "invalid Ed25519 signature" \
    "invalid witness signature diagnostic"

  CNTOOLS_TRANSACTION_OPENSSL="${TEST_ROOT}/missing-openssl"
  CNTOOLS_TRANSACTION_XXD="${TEST_ROOT}/missing-xxd"
  cntools_transaction_witness_signatures_valid "${transaction_id}" '[]' ||
    fail "zero-witness validation incorrectly required cryptographic tools"
  if cntools_transaction_witness_signatures_valid \
      "${transaction_id}" "${witnesses}"; then
    fail "witness validation proceeded without OpenSSL and xxd"
  fi

  cat > "${old_openssl}" <<'OLD_OPENSSL_EOF'
#!/usr/bin/env bash
printf 'OpenSSL 1.1.1w  11 Sep 2023\n'
OLD_OPENSSL_EOF
  chmod 0700 "${old_openssl}"
  CNTOOLS_TRANSACTION_OPENSSL="${old_openssl}"
  CNTOOLS_TRANSACTION_XXD="${real_xxd}"
  if cntools_transaction_witness_signatures_valid \
      "${transaction_id}" "${witnesses}"; then
    fail "OpenSSL 1.1.1 was accepted for Ed25519 witness validation"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "OpenSSL 3 or newer" \
    "old OpenSSL diagnostic"

  mkdir -p "${fallback_bin}"
  chmod 0700 "${fallback_bin}"
  cp -- "${old_openssl}" "${fallback_bin}/openssl"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' \
    "${real_openssl}" > "${fallback_openssl3}"
  chmod 0700 "${fallback_bin}/openssl" "${fallback_openssl3}"
  CNTOOLS_TRANSACTION_OPENSSL=""
  CNTOOLS_TRANSACTION_XXD="${real_xxd}"
  PATH="${fallback_bin}:${original_path}"
  cntools_transaction_require_signature_tools ||
    fail "openssl3 was not selected when generic openssl was older than 3"
  assert_eq "${CNTOOLS_TRANSACTION_OPENSSL}" "${fallback_openssl3}" \
    "openssl3 runtime fallback"
  PATH="${original_path}"
  CNTOOLS_TRANSACTION_OPENSSL="${real_openssl}"
  CNTOOLS_TRANSACTION_XXD="${real_xxd}"
  cntools_transaction_clear_error
}

test_pinned_witness_signature_verification

# The remaining foundation tests use a deliberately synthetic cardano-cli.
# Keep those fixtures focused on orchestration after the real pinned witness
# above has exercised the production OpenSSL verifier.
cntools_transaction_witness_signature_valid() {
  [[ "${1:-}" =~ ^[0-9a-f]{64}$ &&
     "${2:-}" =~ ^[0-9a-f]{64}$ &&
     "${3:-}" == "${FAKE_SIGNATURE}" ]]
}

test_secure_workspace_snapshot_and_publication() {
  local original_tmp_dir="${CNTOOLS_TMP_DIR}"
  local safe_base="${TEST_ROOT}/secure-transaction-base"
  local unsafe_base="${TEST_ROOT}/shared-transaction-base"
  local replaceable_ancestor="${TEST_ROOT}/replaceable-ancestor"
  local protected_but_replaceable="${replaceable_ancestor}/private-leaf"
  local safe_output="${TEST_ROOT}/secure-output"
  local unsafe_output="${TEST_ROOT}/shared-output"
  local source_file="${TEST_ROOT}/snapshot-source.json"
  local temporary_file=""
  local action_directory=""
  local snapshot_file=""
  local stage_file=""
  local output_file=""
  local shared_private_file="${unsafe_output}/replaceable.skey"
  local normalized=""

  cntools_transaction_cleanup
  mkdir -p "${safe_base}" "${unsafe_base}" \
    "${safe_output}" "${unsafe_output}" "${protected_but_replaceable}"
  chmod 0700 "${safe_base}" "${safe_output}"
  chmod 0770 "${unsafe_base}" "${unsafe_output}"
  chmod 0777 "${replaceable_ancestor}"
  chmod 0700 "${protected_but_replaceable}"

  CNTOOLS_TMP_DIR="${safe_base}"
  cntools_transaction_temp_file temporary_file workspace-check ||
    fail "private per-action transaction workspace could not be created"
  action_directory="${CNTOOLS_TRANSACTION_TEMP_DIR}"
  assert_eq "$(file_mode "${action_directory}")" 700 \
    "per-action transaction workspace mode"
  assert_eq "$(file_mode "${temporary_file}")" 600 \
    "per-action transaction artifact mode"
  cntools_transaction_cleanup
  [[ ! -e "${action_directory}" ]] ||
    fail "private per-action transaction workspace survived cleanup"

  CNTOOLS_TMP_DIR="${unsafe_base}"
  if cntools_transaction_temp_file temporary_file unsafe-base; then
    fail "group-writable transaction temporary base was accepted"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" \
    "protected from group or public writes" \
    "unsafe transaction temporary-base diagnostic"

  CNTOOLS_TMP_DIR="${protected_but_replaceable}"
  if cntools_transaction_temp_file temporary_file replaceable-ancestor; then
    fail "private transaction directory below a replaceable ancestor was accepted"
  fi

  printf '{"type":"PaymentSigningKeyShelley_ed25519","cborHex":"00"}\n' \
    > "${shared_private_file}"
  chmod 0600 "${shared_private_file}"
  if cntools_transaction_private_file_safe "${shared_private_file}"; then
    fail "private signing source in a group-writable directory was accepted"
  fi
  if cntools_transaction_source_kind_into \
      normalized "${shared_private_file}"; then
    fail "signer discovery accepted a key from a replaceable shared directory"
  fi

  CNTOOLS_TMP_DIR="${safe_base}"
  printf 'abc' > "${source_file}"
  chmod 0600 "${source_file}"
  head() {
    printf '123456'
  }
  if cntools_transaction_snapshot_into \
      snapshot_file "${source_file}" 5 raced-snapshot; then
    fail "post-copy size validation accepted a raced oversized snapshot"
  fi
  unset -f head
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "changed, became oversized" \
    "raced snapshot diagnostic"

  cntools_transaction_temp_file stage_file unsafe-publication ||
    fail "could not stage unsafe-directory publication fixture"
  printf 'preserve me\n' > "${stage_file}"
  if cntools_transaction_publish \
      "${stage_file}" "${unsafe_output}/transaction.json"; then
    fail "group-writable transaction output directory was accepted"
  fi
  [[ ! -e "${unsafe_output}/transaction.json" ]] ||
    fail "unsafe output directory received a transaction artifact"

  cntools_transaction_temp_file stage_file fallback-publication ||
    fail "could not stage fallback publication fixture"
  printf 'offline package\n' > "${stage_file}"
  output_file="${safe_output}/offline-package.json"
  ln() { return 1; }
  cntools_transaction_publish "${stage_file}" "${output_file}" || {
    unset -f ln
    fail "exclusive-copy publication fallback failed"
  }
  unset -f ln
  assert_eq "$(< "${output_file}")" "offline package" \
    "exclusive-copy publication contents"
  assert_eq "$(file_mode "${output_file}")" 600 \
    "exclusive-copy publication mode"

  cntools_transaction_temp_file stage_file no-clobber-race ||
    fail "could not stage no-clobber race fixture"
  printf 'CNTools package\n' > "${stage_file}"
  output_file="${safe_output}/concurrent-package.json"
  ln() {
    printf 'concurrent writer\n' > "${3}"
    chmod 0600 "${3}"
    return 1
  }
  if cntools_transaction_publish "${stage_file}" "${output_file}"; then
    unset -f ln
    fail "publication replaced an output that appeared concurrently"
  fi
  unset -f ln
  assert_eq "$(< "${output_file}")" "concurrent writer" \
    "concurrent output preservation"

  if cntools_transaction_input_path_into \
      normalized "${safe_output}/bad"$'\t'"input.json"; then
    fail "control character was accepted in a transaction input path"
  fi
  if cntools_transaction_output_path_safe \
      "${safe_output}/bad"$'\b'"output.json"; then
    fail "control character was accepted in a transaction output path"
  fi

  cntools_transaction_cleanup
  CNTOOLS_TMP_DIR="${original_tmp_dir}"
}

test_cli_version_contract
test_signer_plan_invariants
test_native_script_and_validity_invariants
test_witness_identity_binding
test_builder_contracts
test_package_schema_and_tamper_rejection
test_hardware_group_package_invariants
test_secure_workspace_snapshot_and_publication

TRANSACTION_TEMP_FIXTURE=""
cntools_transaction_temp_file TRANSACTION_TEMP_FIXTURE permission-check ||
  fail "private transaction temporary file could not be created"
assert_eq "$(file_mode "${TRANSACTION_TEMP_FIXTURE}")" 600 \
  "transaction temporary-file mode"
cntools_transaction_cleanup
[[ ! -e "${TRANSACTION_TEMP_FIXTURE}" ]] ||
  fail "tracked transaction temporary file survived cleanup"
assert_no_transaction_debris
assert_file_contains "${LOG_TRACE}" "signer registered" \
  "transaction plan operations were not logged"

printf 'CNTools transaction foundation tests passed\n'
