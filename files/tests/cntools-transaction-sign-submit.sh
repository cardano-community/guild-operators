#!/usr/bin/env bash
# Focused CNTools transaction signing and submission acceptance tests.
# shellcheck disable=SC1090,SC2016,SC2034,SC2153,SC2154,SC2317,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools transaction sign/submit tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TRANSACTION_LIBRARY="${CNTOOLS_ROOT}/lib/transaction.sh"
SIGN_LIBRARY="${CNTOOLS_ROOT}/lib/transaction-sign.sh"
SUBMIT_LIBRARY="${CNTOOLS_ROOT}/lib/transaction-submit.sh"
CNODE_RELEASE="${REPO_ROOT}/files/node-implementations/cnode/release.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-sign-submit.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
CNTOOLS_TMP_DIR="${TEST_ROOT}/tmp"
OUTPUT_ROOT="${TEST_ROOT}/output"
FAKE_CLI="${TEST_ROOT}/cardano-cli"
FAKE_HWCLI="${TEST_ROOT}/cardano-hw-cli"
CLI_TRACE="${TEST_ROOT}/cardano-cli.trace"
HWCLI_TRACE="${TEST_ROOT}/cardano-hw-cli.trace"
API_TRACE="${TEST_ROOT}/koios.trace"
LOG_TRACE="${TEST_ROOT}/cntools.log"

TESTED_CARDANO_CLI_VERSION="11.0.0.0"
TESTED_HWCLI_VERSION="1.19.1"
TESTED_HWCLI_X64_URL="https://github.com/vacuumlabs/cardano-hw-cli/releases/download/v1.19.1/cardano-hw-cli-1.19.1_linux-x64.tar.gz"
TESTED_HWCLI_X64_SHA256="089349ebcfe2a465e301faaf077fa094f6db859e92aab56f256f325295b76474"
TESTED_HWCLI_ARM64_URL="https://github.com/vacuumlabs/cardano-hw-cli/releases/download/v1.19.1/cardano-hw-cli-1.19.1_linux-arm64.tar.gz"
TESTED_HWCLI_ARM64_SHA256="b980200f7c96c2c950ea6f0a79ed81280afd1c037ee3d71c4b8855a4ffad686b"
KEY_A="$(printf '11%.0s' {1..32})"
KEY_B="$(printf '22%.0s' {1..32})"
KEY_C="$(printf '33%.0s' {1..32})"
FAKE_SIGNATURE="$(printf '55%.0s' {1..64})"
CHAIN_CODE="$(printf 'cc%.0s' {1..32})"
CREDENTIAL_A="${KEY_A:0:56}"
CREDENTIAL_B="${KEY_B:0:56}"
CREDENTIAL_C="${KEY_C:0:56}"
WRONG_CREDENTIAL="$(printf '99%.0s' {1..28})"
TX_ID="$(printf 'aa%.0s' {1..32})"
OTHER_TX_ID="$(printf 'bb%.0s' {1..32})"

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

assert_file_absent() {
  [[ ! -e "$1" && ! -L "$1" ]] ||
    fail "${2:-unexpected output exists}: $1"
}

assert_file_unchanged() {
  cmp -s -- "$1" "$2" || fail "${3:-input file changed}"
}

assert_no_transaction_debris() {
  local debris=""

  debris="$(find "${TEST_ROOT}" -name '.cntools-transaction-*' -print -quit)"
  [[ -z "${debris}" ]] ||
    fail "transaction temporary artifact remained after cleanup: ${debris}"
}

write_cli_key() {
  local output_file="$1"
  local public_key="$2"

  jq -n --arg public "${public_key}" '
    {
      type: "PaymentSigningKeyShelley_ed25519",
      description: "CNTools signing fixture",
      cborHex: "5820aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      fakePublic: $public
    }
  ' > "${output_file}" || fail "could not write CLI signing fixture"
  chmod 0600 "${output_file}"
}

write_hardware_key() {
  local output_file="$1"
  local public_key="$2"
  local path="$3"

  jq -n --arg public "${public_key}" --arg chain "${CHAIN_CODE}" \
    --arg path "${path}" '
    {
      type: "PaymentHWSigningFileShelley_ed25519",
      description: "CNTools hardware fixture",
      path: $path,
      cborXPubKeyHex: ("5840" + $public + $chain)
    }
  ' > "${output_file}" || fail "could not write hardware signing fixture"
  chmod 0600 "${output_file}"
}

write_package() {
  local output_file="$1"
  local network="$2"
  local signer_kind="$3"
  local hardware_group="${4:-}"
  local include_change="${5:-N}"
  local magic="2"
  local group_json="null"
  local required='[]'
  local changes='[]'

  case "${network}" in
    mainnet) magic="null" ;;
    guild) magic="141" ;;
    preprod) magic="1" ;;
    preview) magic="2" ;;
    *) fail "unsupported package fixture network: ${network}" ;;
  esac
  [[ -z "${hardware_group}" ]] ||
    group_json="$(jq -Rn --arg group "${hardware_group}" '$group')"
  required="$(jq -cn \
    --arg key_a "${KEY_A}" --arg key_b "${KEY_B}" \
    --arg credential_a "${CREDENTIAL_A}" \
    --arg credential_b "${CREDENTIAL_B}" \
    --arg kind "${signer_kind}" --argjson group "${group_json}" '
    [
      {
        keyId: $key_a, credential: $credential_a,
        labels: ["Payment A"], roles: ["spending"],
        preferredKind: $kind, hardwareGroup: $group
      },
      {
        keyId: $key_b, credential: $credential_b,
        labels: ["Payment B"], roles: ["spending"],
        preferredKind: $kind, hardwareGroup: $group
      }
    ]
  ')" || fail "could not create signer fixture"
  if [[ "${include_change}" == "Y" ]]; then
    changes="$(jq -cn --arg key "${KEY_C}" \
      --arg group "${hardware_group}" '
      [{keyId: $key, labels: ["Change"], hardwareGroup: $group}]
    ')" || fail "could not create change-key fixture"
  fi
  jq -n \
    --arg schema "org.cardano-community.cntools.transaction" \
    --arg network "${network}" --argjson magic "${magic}" \
    --arg tx_id "${TX_ID}" --argjson required "${required}" \
    --argjson changes "${changes}" '
    {
      schema: $schema,
      schemaVersion: 1,
      createdAt: "2026-09-03T00:00:00Z",
      network: {name: $network, magic: $magic},
      intent: {
        kind: "Test transfer",
        description: "Signing and submission fixture",
        summary: {amount: 1000000, unit: "lovelace"}
      },
      validity: {invalidBefore: null, invalidHereafter: null},
      transaction: {
        id: $tx_id,
        hardwarePrepared: false,
        body: {
          type: "TxBody ConwayEra",
          description: "Unsigned transaction fixture",
          cborHex: "aa00",
          fakeRequired: [$required[].credential],
          fakeWitnesses: []
        }
      },
      signing: {
        assurance: "exact",
        required: $required,
        changeKeys: $changes,
        nativeScripts: [],
        witnesses: []
      },
      signedTransaction: null
    }
  ' > "${output_file}" || fail "could not write transaction package fixture"
  chmod 0600 "${output_file}"
}

for required_command in \
  awk bash cat chmod cmp cp date find grep head jq ln mktemp openssl rm rmdir \
  sed sort stat tail wc xxd; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required test command is unavailable: ${required_command}"
done

for required_file in \
  "${TRANSACTION_LIBRARY}" "${SIGN_LIBRARY}" "${SUBMIT_LIBRARY}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" &&
     -s "${required_file}" ]] ||
    fail "required transaction source is missing or unsafe: ${required_file}"
done

bash -n "${TRANSACTION_LIBRARY}" "${SIGN_LIBRARY}" "${SUBMIT_LIBRARY}" ||
  fail "transaction sign/submit sources have invalid Bash syntax"
for implementation in cnode dingo; do
  assert_eq \
    "$(jq -er '.companions["cardano-cli"].version' \
      "${REPO_ROOT}/files/node-implementations/${implementation}/release.json")" \
    "${TESTED_CARDANO_CLI_VERSION}" \
    "${implementation} Cardano CLI pin; review transaction command fixtures"
done
jq -e '.tools["cardano-hw-cli"] |
  . == {
    version: $version,
    artifacts: {
      "linux-x86_64": {url: $x64_url, sha256: $x64_sha256},
      "linux-aarch64": {url: $arm64_url, sha256: $arm64_sha256}
    }
  }' \
  --arg version "${TESTED_HWCLI_VERSION}" \
  --arg x64_url "${TESTED_HWCLI_X64_URL}" \
  --arg x64_sha256 "${TESTED_HWCLI_X64_SHA256}" \
  --arg arm64_url "${TESTED_HWCLI_ARM64_URL}" \
  --arg arm64_sha256 "${TESTED_HWCLI_ARM64_SHA256}" \
  "${REPO_ROOT}/files/node-implementations/common/release.json" >/dev/null ||
  fail "cardano-hw-cli deployment contract changed; review hardware fixtures"

mkdir -p "${CNTOOLS_TMP_DIR}" "${OUTPUT_ROOT}"
chmod 0700 "${TEST_ROOT}" "${CNTOOLS_TMP_DIR}" "${OUTPUT_ROOT}"
: > "${CLI_TRACE}"
: > "${HWCLI_TRACE}"
: > "${API_TRACE}"
: > "${LOG_TRACE}"
chmod 0600 "${CLI_TRACE}" "${HWCLI_TRACE}" "${API_TRACE}" "${LOG_TRACE}"

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

jq -cn --args '$ARGS.positional' -- "$@" >> "${FAKE_CLI_TRACE}"
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
  latest/transaction/txid)
    if [[ "${FAKE_CLI_SCENARIO:-success}" == "normalization-change" &&
          " $* " == *" --tx-file "* ]]; then
      printf '%s\n' "${FAKE_OTHER_TX_ID}"
    else
      printf '%s\n' "${FAKE_TX_ID}"
    fi
    ;;
  debug/transaction/view)
    transaction_file="$(arg_value --tx-body-file "$@" 2>/dev/null ||
      arg_value --tx-file "$@")"
    jq '
      {
        "validity range": {"lower bound": null, "upper bound": null},
        "required signers (payment key hashes needed for scripts)":
          (.fakeRequired // null),
        "reference inputs": [],
        scripts: [],
        witnesses:
          (if .fakeByron == true then
             [{"bootstrap witness": "fixture bootstrap witness"}]
           else [(.fakeWitnesses // [])[] |
             {
               key: ("VKey (VerKeyEd25519DSIGN \"" + .keyId + "\")"),
               signature: ("SignedDSIGN (SigEd25519DSIGN \"" +
                 .signature + "\")")
             }]
           end)
      }
    ' "${transaction_file}"
    ;;
  latest/transaction/witness)
    signing_file="$(arg_value --signing-key-file "$@")"
    output_file="$(arg_value --out-file "$@")"
    public_key="$(jq -er '.fakePublic' "${signing_file}")"
    if [[ "${FAKE_CLI_SCENARIO:-success}" == "wrong-witness" ]]; then
      public_key="${FAKE_WRONG_KEY}"
    fi
    jq -n --arg public "${public_key}" \
      --arg signature "${FAKE_WITNESS_SIGNATURE}" '
      {type: "TxWitness ConwayEra", description: "Fixture witness",
       cborHex: "aa01", fakePublic: $public, fakeSignature: $signature}
    ' > "${output_file}"
    ;;
  latest/transaction/assemble)
    body_file="$(arg_value --tx-body-file "$@")"
    output_file="$(arg_value --out-file "$@")"
    witnesses='[]'
    while (( $# > 0 )); do
      if [[ "$1" == "--witness-file" ]]; then
        public_key="$(jq -er '.fakePublic' "$2")"
        signature="$(jq -er '.fakeSignature' "$2")"
        witnesses="$(jq -cn --argjson current "${witnesses}" \
          --arg public "${public_key}" --arg signature "${signature}" \
          '$current + [{keyId: $public, signature: $signature}]')"
        shift 2
      else
        shift
      fi
    done
    jq --argjson witnesses "${witnesses}" '
      .type = "Tx ConwayEra" |
      .description = "Canonical assembled fixture" |
      .fakeWitnesses = $witnesses
    ' "${body_file}" > "${output_file}"
    ;;
  latest/transaction/submit)
    if [[ "${FAKE_CLI_SCENARIO:-success}" == "submit-error" ]]; then
      exit 9
    fi
    exit 0
    ;;
  *)
    printf 'unsupported fake cardano-cli command: %s\n' "${command_path}" >&2
    exit 92
    ;;
esac
FAKE_CLI_EOF
chmod 0700 "${FAKE_CLI}"

cat > "${FAKE_HWCLI}" <<'FAKE_HWCLI_EOF'
#!/usr/bin/env bash
set -euo pipefail

jq -cn --args '$ARGS.positional' -- "$@" >> "${FAKE_HWCLI_TRACE}"
case "${1:-}/${2:-}" in
  version/)
    printf 'Cardano HW CLI Tool version %s\n' \
      "${FAKE_HWCLI_VERSION:-1.19.1}"
    ;;
  device/version)
    printf 'Ledger fixture ready\n'
    ;;
  transaction/validate)
    ;;
  transaction/witness)
    sources=()
    outputs=()
    while (( $# > 0 )); do
      case "$1" in
        --hw-signing-file)
          sources+=("$2")
          shift 2
          ;;
        --out-file)
          outputs+=("$2")
          shift 2
          ;;
        *) shift ;;
      esac
    done
    (( ${#sources[@]} > 0 && ${#sources[@]} == ${#outputs[@]} )) || exit 91
    for (( index = 0; index < ${#sources[@]}; index++ )); do
      public_key="$(jq -er '.cborXPubKeyHex | ascii_downcase' \
        "${sources[index]}")"
      public_key="${public_key:4:64}"
      jq -n --arg public "${public_key}" \
        --arg signature "${FAKE_WITNESS_SIGNATURE}" '
        {type: "TxWitness ConwayEra", description: "Hardware fixture witness",
         cborHex: "aa02", fakePublic: $public, fakeSignature: $signature}
      ' > "${outputs[index]}"
    done
    ;;
  *)
    printf 'unsupported fake cardano-hw-cli command: %s/%s\n' \
      "${1:-}" "${2:-}" >&2
    exit 92
    ;;
esac
FAKE_HWCLI_EOF
chmod 0700 "${FAKE_HWCLI}"

export FAKE_CLI_TRACE="${CLI_TRACE}"
export FAKE_HWCLI_TRACE="${HWCLI_TRACE}"
export FAKE_TX_ID="${TX_ID}"
export FAKE_OTHER_TX_ID="${OTHER_TX_ID}"
export FAKE_WRONG_KEY="${KEY_B}"
export FAKE_WITNESS_SIGNATURE="${FAKE_SIGNATURE}"
export FAKE_CLI_SCENARIO="success"
export FAKE_CLI_VERSION="${TESTED_CARDANO_CLI_VERSION}"
export FAKE_HWCLI_VERSION="${TESTED_HWCLI_VERSION}"

# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/log.sh"
# shellcheck source=/dev/null
. "${TRANSACTION_LIBRARY}"
# shellcheck source=/dev/null
. "${SIGN_LIBRARY}"
# shellcheck source=/dev/null
. "${SUBMIT_LIBRARY}"

CNTOOLS_ACTION_ID="transaction/sign-submit-test"
CNTOOLS_LOG="${LOG_TRACE}"
CNTOOLS_CLI="${FAKE_CLI}"
CNTOOLS_CLI_TIMEOUT="3"
CNTOOLS_TRANSACTION_TIMEOUT="3"
CNTOOLS_TRANSACTION_HARDWARE_TIMEOUT="3"
CNTOOLS_TIMEOUT_BIN=""
CNTOOLS_NETWORK="preview"
CNTOOLS_MODE="local"
CNTOOLS_BACKEND="cnode"
CNTOOLS_LOCAL_CLI_CAPABLE="true"
CNTOOLS_SOCKET="${TEST_ROOT}/node.socket"
CNTOOLS_KOIOS_ENABLED="Y"
CNTOOLS_KOIOS_API="https://preview.koios.rest/api/v1"
CNTOOLS_KOIOS_TOKEN=""
CNTOOLS_HWCLI="${FAKE_HWCLI}"
CNTOOLS_TRANSACTION_SUBMIT_XXD="$(type -P xxd)"

cntools_log() {
  printf '%s\t%s\t%s\n' \
    "${1:-INFO}" "${CNTOOLS_ACTION_ID:-session}" "${2:-}" >> "${LOG_TRACE}"
}

cntools_startup_resolve_command() {
  [[ "${1:-}" == "${FAKE_HWCLI}" ]] || return 1
  printf '%s\n' "${FAKE_HWCLI}"
}

test_http_secret_path_ancestry() {
  local original_tmp_dir="${CNTOOLS_TMP_DIR}"
  local original_token="${CNTOOLS_KOIOS_TOKEN}"
  local replaceable_ancestor="${TEST_ROOT}/replaceable-http-ancestor"
  local protected_but_replaceable="${replaceable_ancestor}/private-leaf"
  local secret_file=""

  mkdir -p "${protected_but_replaceable}"
  chmod 0777 "${replaceable_ancestor}"
  chmod 0700 "${protected_but_replaceable}"
  CNTOOLS_TMP_DIR="${protected_but_replaceable}"
  CNTOOLS_KOIOS_TOKEN="secret-path-safety-test"
  if cntools_http_secret_file_create secret_file; then
    fail "HTTP bearer file below a replaceable ancestor was accepted"
  fi
  [[ -z "${secret_file}" ]] ||
    fail "rejected HTTP bearer staging returned a secret path"
  CNTOOLS_TMP_DIR="${original_tmp_dir}"
  CNTOOLS_KOIOS_TOKEN="${original_token}"
}

test_cli_partial_complete_and_tampering() {
  local package="${TEST_ROOT}/cli.package.json"
  local snapshot="${TEST_ROOT}/cli.package.snapshot.json"
  local partial="${OUTPUT_ROOT}/cli.partial.json"
  local complete="${OUTPUT_ROOT}/cli.complete.json"
  local duplicate="${OUTPUT_ROOT}/cli.duplicate.json"
  local wrong_output="${OUTPUT_ROOT}/cli.wrong.json"
  local tampered_witness="${TEST_ROOT}/cli.tampered-witness.json"
  local tampered_signature="${TEST_ROOT}/cli.tampered-signature.json"
  local tampered_credential="${TEST_ROOT}/cli.tampered-credential.json"
  local tampered_signed="${TEST_ROOT}/cli.tampered-signed.json"
  local key_a="${TEST_ROOT}/payment-a.skey"
  local key_b="${TEST_ROOT}/payment-b.skey"
  local -a signers=()
  local -a changes=()

  write_package "${package}" preview cli
  cp -- "${package}" "${snapshot}"
  chmod 0600 "${snapshot}"
  write_cli_key "${key_a}" "${KEY_A}"
  write_cli_key "${key_b}" "${KEY_B}"

  signers=("${key_a}")
  cntools_transaction_sign_package \
    "${package}" "${partial}" signers changes ||
    fail "first CLI signature failed: ${CNTOOLS_TRANSACTION_ERROR}"
  assert_file_unchanged "${package}" "${snapshot}" \
    "partial signing changed its input package"
  assert_eq "$(jq -r '.signing.witnesses | length' "${partial}")" 1 \
    "partial witness count"
  assert_eq "$(jq -r '.signedTransaction == null' "${partial}")" true \
    "partial package completion state"
  assert_eq "${CNTOOLS_TRANSACTION_SIGN_ADDED}" 1 \
    "partial signature accounting"
  assert_eq "${CNTOOLS_TRANSACTION_SIGN_COMPLETE}" N \
    "partial foundation state"

  signers=("${key_b}")
  cp -- "${partial}" "${TEST_ROOT}/cli.partial.snapshot.json"
  cntools_transaction_sign_package \
    "${partial}" "${complete}" signers changes ||
    fail "second CLI signature failed: ${CNTOOLS_TRANSACTION_ERROR}"
  assert_file_unchanged "${partial}" "${TEST_ROOT}/cli.partial.snapshot.json" \
    "completion signing changed its input package"
  jq -e --arg first "${KEY_A}" --arg second "${KEY_B}" '
    .signedTransaction != null and
    ([.signing.witnesses[].keyId] | sort) == ([$first, $second] | sort)
  ' "${complete}" >/dev/null ||
    fail "complete CLI package does not contain both authenticated witnesses"
  assert_eq "${CNTOOLS_TRANSACTION_SIGN_COMPLETE}" Y \
    "complete foundation state"

  signers=("${key_a}" "${key_a}")
  cntools_transaction_sign_package \
    "${package}" "${duplicate}" signers changes ||
    fail "duplicate-source signing failed: ${CNTOOLS_TRANSACTION_ERROR}"
  assert_eq "$(jq -r '.signing.witnesses | length' "${duplicate}")" 1 \
    "duplicate signer source was not deduplicated"

  export FAKE_CLI_SCENARIO="wrong-witness"
  signers=("${key_a}")
  if cntools_transaction_sign_package \
      "${package}" "${wrong_output}" signers changes; then
    fail "CLI witness produced by the wrong key was accepted"
  fi
  export FAKE_CLI_SCENARIO="success"
  assert_file_absent "${wrong_output}" "wrong-key witness output was published"
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "does not match" \
    "wrong-key witness diagnostic"

  jq --arg wrong "${KEY_B}" '
    .signing.witnesses[0].witness.fakePublic = $wrong
  ' "${partial}" > "${tampered_witness}"
  chmod 0600 "${tampered_witness}"
  if cntools_transaction_package_load "${tampered_witness}"; then
    fail "witness whose recorded keyId does not match its signature was accepted"
  fi

  jq --arg signature "$(printf '66%.0s' {1..64})" '
    .signing.witnesses[0].witness.fakeSignature = $signature
  ' "${partial}" > "${tampered_signature}"
  chmod 0600 "${tampered_signature}"
  if cntools_transaction_package_load "${tampered_signature}"; then
    fail "cryptographically invalid recorded witness was accepted"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "invalid witness" \
    "invalid recorded witness diagnostic"

  jq --arg wrong "${WRONG_CREDENTIAL}" '
    .signing.required[0].credential = $wrong
  ' "${package}" > "${tampered_credential}"
  chmod 0600 "${tampered_credential}"
  if cntools_transaction_package_load "${tampered_credential}"; then
    fail "signer keyId/credential inconsistency was accepted"
  fi

  jq '.signedTransaction.cborHex = "aa04"' \
    "${complete}" > "${tampered_signed}"
  chmod 0600 "${tampered_signed}"
  if cntools_transaction_package_load "${tampered_signed}"; then
    fail "signedTransaction differing from canonical assembly was accepted"
  fi
}

test_signing_guards_and_non_overwrite() {
  local package="${TEST_ROOT}/guard.package.json"
  local snapshot="${TEST_ROOT}/guard.package.snapshot.json"
  local mismatch_output="${OUTPUT_ROOT}/network-mismatch.json"
  local protected_output="${OUTPUT_ROOT}/protected.json"
  local key_a="${TEST_ROOT}/guard-a.skey"
  local -a signers=()
  local -a changes=()

  write_package "${package}" preview cli
  cp -- "${package}" "${snapshot}"
  write_cli_key "${key_a}" "${KEY_A}"
  signers=("${key_a}")

  CNTOOLS_NETWORK="preprod"
  if cntools_transaction_sign_package \
      "${package}" "${mismatch_output}" signers changes; then
    fail "preview package was signed while configured for preprod"
  fi
  CNTOOLS_NETWORK="preview"
  assert_file_absent "${mismatch_output}" "network-mismatch output was published"
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "targets preview" \
    "network mismatch diagnostic"

  printf 'preserve-output\n' > "${protected_output}"
  chmod 0600 "${protected_output}"
  if cntools_transaction_sign_package \
      "${package}" "${protected_output}" signers changes; then
    fail "signing overwrote an existing output file"
  fi
  assert_eq "$(< "${protected_output}")" preserve-output \
    "protected output contents"
  assert_file_unchanged "${package}" "${snapshot}" \
    "failed signing guard changed its input package"
}

test_hardware_group_atomicity_and_change_reference() {
  local package="${TEST_ROOT}/hardware.package.json"
  local prepared_package=""
  local snapshot="${TEST_ROOT}/hardware.package.snapshot.json"
  local partial_output="${OUTPUT_ROOT}/hardware-partial.json"
  local missing_change_output="${OUTPUT_ROOT}/hardware-no-change.json"
  local complete_output="${OUTPUT_ROOT}/hardware-complete.json"
  local key_a="${TEST_ROOT}/ledger-a.hwsfile"
  local key_b="${TEST_ROOT}/ledger-b.hwsfile"
  local change_key="${TEST_ROOT}/ledger-change.hwsfile"
  local witness_calls=0
  local witness_trace=""
  local -a signers=()
  local -a changes=()

  write_package "${package}" preview hardware ledger-main Y
  write_hardware_key "${key_a}" "${KEY_A}" "1852H/1815H/0H/0/0"
  write_hardware_key "${key_b}" "${KEY_B}" "1852H/1815H/0H/0/1"
  write_hardware_key "${change_key}" "${KEY_C}" "1852H/1815H/0H/1/0"
  CNTOOLS_TRANSACTION_HWCLI=""
  CNTOOLS_TRANSACTION_HWCLI_VERSION=""
  : > "${HWCLI_TRACE}"
  cntools_transaction_package_prepare_hardware_into \
    prepared_package "${package}" ||
    fail "hardware package preparation failed: ${CNTOOLS_TRANSACTION_ERROR}"
  package="${prepared_package}"
  cp -- "${package}" "${snapshot}"
  chmod 0600 "${snapshot}"

  signers=("${key_a}")
  changes=("${change_key}")
  if cntools_transaction_sign_package \
      "${package}" "${partial_output}" signers changes; then
    fail "partial hardware group was witnessed"
  fi
  assert_file_absent "${partial_output}" "partial hardware output was published"
  witness_calls="$(jq -s '[.[] | select(.[0:2] == ["transaction", "witness"])] | length' \
    "${HWCLI_TRACE}")"
  assert_eq "${witness_calls}" 0 \
    "hardware command ran before the group was complete"

  signers=("${key_a}" "${key_b}")
  changes=()
  if cntools_transaction_sign_package \
      "${package}" "${missing_change_output}" signers changes; then
    fail "hardware group without its planned change reference was witnessed"
  fi
  assert_file_absent "${missing_change_output}" \
    "missing-change hardware output was published"
  witness_calls="$(jq -s '[.[] | select(.[0:2] == ["transaction", "witness"])] | length' \
    "${HWCLI_TRACE}")"
  assert_eq "${witness_calls}" 0 \
    "hardware command ran without its change reference"

  signers=("${key_a}" "${key_b}")
  changes=("${change_key}")
  cntools_transaction_sign_package \
    "${package}" "${complete_output}" signers changes ||
    fail "complete hardware signing group failed: ${CNTOOLS_TRANSACTION_ERROR}"
  assert_file_unchanged "${package}" "${snapshot}" \
    "hardware signing changed its input package"
  jq -e '.transaction.hardwarePrepared == true and
    (.signing.witnesses | length) == 2 and .signedTransaction != null' \
    "${complete_output}" >/dev/null ||
    fail "hardware package was not completed atomically"
  witness_calls="$(jq -s '[.[] | select(.[0:2] == ["transaction", "witness"])] | length' \
    "${HWCLI_TRACE}")"
  assert_eq "${witness_calls}" 1 "hardware session count"
  witness_trace="$(jq -sc '[.[] | select(.[0:2] == ["transaction", "witness"])][0]' \
    "${HWCLI_TRACE}")"
  jq -e --arg first "${key_a}" --arg second "${key_b}" \
    --arg change "${change_key}" '
    ([range(0; length) as $i |
      select(.[$i] == "--hw-signing-file") | .[$i + 1]] | sort) ==
      ([$first, $second] | sort) and
    ([range(0; length) as $i |
      select(.[$i] == "--change-output-key-file") | .[$i + 1]]) == [$change]
  ' <<< "${witness_trace}" >/dev/null ||
    fail "hardware batch did not receive all signers and the separate change reference"
}

test_hardware_cli_exact_version_contract() {
  local version=""

  for version in 1.19.0 1.20.0 1.19.1-beta.1; do
    FAKE_HWCLI_VERSION="${version}"
    export FAKE_HWCLI_VERSION
    CNTOOLS_TRANSACTION_HWCLI=""
    CNTOOLS_TRANSACTION_HWCLI_VERSION=""
    if cntools_transaction_require_hwcli; then
      fail "unsupported cardano-hw-cli ${version} was accepted"
    fi
    assert_contains "${CNTOOLS_TRANSACTION_ERROR}" \
      "exactly ${TESTED_HWCLI_VERSION} is required" \
      "cardano-hw-cli exact-version diagnostic (${version})"
  done

  FAKE_HWCLI_VERSION="${TESTED_HWCLI_VERSION}"
  export FAKE_HWCLI_VERSION
  CNTOOLS_TRANSACTION_HWCLI=""
  CNTOOLS_TRANSACTION_HWCLI_VERSION=""
  cntools_transaction_require_hwcli ||
    fail "pinned cardano-hw-cli was rejected: ${CNTOOLS_TRANSACTION_ERROR}"
  assert_eq "${CNTOOLS_TRANSACTION_HWCLI_VERSION}" \
    "${TESTED_HWCLI_VERSION}" "pinned cardano-hw-cli version"
}

test_mixed_signing_hardware_normalization_guard() {
  local package="${TEST_ROOT}/mixed.package.json"
  local mixed_stage="${TEST_ROOT}/mixed.package.stage.json"
  local partial="${OUTPUT_ROOT}/mixed.partial.json"
  local partial_snapshot="${TEST_ROOT}/mixed.partial.snapshot.json"
  local prepared_partial=""
  local unsafe_prepared=""
  local complete="${OUTPUT_ROOT}/mixed.complete.json"
  local rejected="${OUTPUT_ROOT}/mixed.rejected.json"
  local cli_key="${TEST_ROOT}/mixed-a.skey"
  local hardware_key="${TEST_ROOT}/mixed-b.hwsfile"
  local witness_calls_before=0
  local witness_calls_after=0
  local -a signers=()
  local -a changes=()

  write_package "${package}" preview cli
  jq '
    .signing.required[1].preferredKind = "hardware" |
    .signing.required[1].hardwareGroup = "ledger-mixed"
  ' "${package}" > "${mixed_stage}"
  mv -- "${mixed_stage}" "${package}"
  chmod 0600 "${package}"
  write_cli_key "${cli_key}" "${KEY_A}"
  write_hardware_key \
    "${hardware_key}" "${KEY_B}" "1852H/1815H/0H/0/1"

  export FAKE_CLI_SCENARIO="success"
  signers=("${cli_key}")
  cntools_transaction_sign_package \
    "${package}" "${partial}" signers changes ||
    fail "CLI half of mixed signing failed: ${CNTOOLS_TRANSACTION_ERROR}"
  cp -- "${partial}" "${partial_snapshot}"
  chmod 0600 "${partial_snapshot}"

  signers=("${hardware_key}")
  if cntools_transaction_sign_package \
      "${partial}" "${rejected}" signers changes; then
    fail "unprepared hardware package was signed"
  fi
  assert_file_absent "${rejected}" \
    "unprepared hardware signing published an output"
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" \
    "prepared and reviewed" "unprepared hardware diagnostic"

  cntools_transaction_package_prepare_hardware_into \
    prepared_partial "${partial}" ||
    fail "ID-preserving hardware normalization was rejected: ${CNTOOLS_TRANSACTION_ERROR}"
  cntools_transaction_sign_package \
    "${prepared_partial}" "${complete}" signers changes ||
    fail "prepared mixed hardware signing failed: ${CNTOOLS_TRANSACTION_ERROR}"
  jq -e '.signedTransaction != null and
    ([.signing.witnesses[].kind] | sort) == ["cli", "hardware"]' \
    "${complete}" >/dev/null ||
    fail "mixed CLI/hardware signing did not produce a complete package"
  assert_file_unchanged "${partial}" "${partial_snapshot}" \
    "successful mixed signing changed its partial input"

  witness_calls_before="$(jq -s \
    '[.[] | select(.[0:2] == ["transaction", "witness"])] | length' \
    "${HWCLI_TRACE}")"
  export FAKE_CLI_SCENARIO="normalization-change"
  if cntools_transaction_package_prepare_hardware_into \
      unsafe_prepared "${partial}"; then
    fail "hardware normalization changed an already-witnessed transaction ID"
  fi
  [[ -z "${unsafe_prepared}" ]] ||
    fail "unsafe hardware normalization returned a prepared package"
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" \
    "already has witnesses" "normalization-change diagnostic"
  witness_calls_after="$(jq -s \
    '[.[] | select(.[0:2] == ["transaction", "witness"])] | length' \
    "${HWCLI_TRACE}")"
  assert_eq "${witness_calls_after}" "${witness_calls_before}" \
    "hardware witness command ran after transaction ID changed"
  assert_file_unchanged "${partial}" "${partial_snapshot}" \
    "rejected mixed signing changed its partial input"
  export FAKE_CLI_SCENARIO="success"
}

cntools_api_request() {
  local method="${1:-}"
  local endpoint="${2:-}"
  local output_file="${3:-}"
  local header_file=""
  shift 3 2>/dev/null || return 2

  jq -cn --args '$ARGS.positional' -- \
    "${method}" "${endpoint}" "${output_file}" "$@" >> "${API_TRACE}"
  while (( $# > 0 )); do
    if [[ "$1" == "--dump-header" ]]; then
      header_file="$2"
      shift 2
    else
      shift
    fi
  done
  [[ -n "${header_file}" ]] || return 2
  case "${FAKE_API_SCENARIO:-success}" in
    success)
      printf 'HTTP/1.1 202 Accepted\r\n\r\n' > "${header_file}"
      jq -n --arg id "${TX_ID}" '$id' > "${output_file}"
      ;;
    mismatch)
      printf 'HTTP/1.1 202 Accepted\r\n\r\n' > "${header_file}"
      jq -n --arg id "${OTHER_TX_ID}" '$id' > "${output_file}"
      ;;
    http-error)
      printf 'HTTP/1.1 500 Internal Server Error\r\n\r\n' > "${header_file}"
      printf '{"error":"fixture rejection"}\n' > "${output_file}"
      ;;
    reflected-secret)
      printf 'HTTP/1.1 500 Internal Server Error\r\n\r\n' > "${header_file}"
      printf '{"error":"Authorization: Bearer %s"}\n' \
        "${CNTOOLS_KOIOS_TOKEN}" > "${output_file}"
      return 22
      ;;
    transfer-after-202)
      printf 'HTTP/1.1 202 Accepted\r\n\r\n' > "${header_file}"
      printf '{"error":"truncated response"}\n' > "${output_file}"
      return 56
      ;;
    *) return 2 ;;
  esac
}

test_submission_backends_and_integrity() {
  local complete="${OUTPUT_ROOT}/cli.complete.json"
  local complete_snapshot="${TEST_ROOT}/cli.complete.snapshot.json"
  local signed="${TEST_ROOT}/signed.json"
  local signed_snapshot="${TEST_ROOT}/signed.snapshot.json"
  local invalid_signed="${TEST_ROOT}/signed.invalid-witness.json"
  local zero_vkey_external="${TEST_ROOT}/external.zero-vkey.json"
  local bootstrap_external="${TEST_ROOT}/external.bootstrap.json"
  local koios_source="${TEST_ROOT}/signed.koios-source.json"
  local expected_raw="${TEST_ROOT}/signed.expected.cbor"
  local expected_digest=""
  local mutated_digest=""
  local provenance_record=""
  local cli_before=0
  local api_before=0
  local api_trace=""

  cp -- "${complete}" "${complete_snapshot}"
  chmod 0600 "${complete_snapshot}"
  jq '.signedTransaction' "${complete}" > "${signed}"
  chmod 0600 "${signed}"
  cp -- "${signed}" "${signed_snapshot}"
  chmod 0600 "${signed_snapshot}"
  cp -- "${signed}" "${koios_source}"
  chmod 0600 "${koios_source}"
  jq '.fakeWitnesses = []' "${signed}" > "${zero_vkey_external}"
  chmod 0600 "${zero_vkey_external}"
  jq '.fakeByron = true' "${zero_vkey_external}" > "${bootstrap_external}"
  chmod 0600 "${bootstrap_external}"

  cli_before="$(wc -l < "${CLI_TRACE}")"
  api_before="$(wc -l < "${API_TRACE}")"
  CNTOOLS_MODE="offline"
  if cntools_transaction_submit "${signed}"; then
    fail "offline CNTools submitted a transaction"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "unavailable in offline mode" \
    "offline submission diagnostic"
  assert_eq "$(wc -l < "${CLI_TRACE}")" "${cli_before}" \
    "offline submission invoked Cardano CLI"
  assert_eq "$(wc -l < "${API_TRACE}")" "${api_before}" \
    "offline submission invoked Koios"
  assert_file_unchanged "${signed}" "${signed_snapshot}" \
    "offline submission changed its input"

  cntools_transaction_submit_local_ready() { return 1; }
  CNTOOLS_MODE="light"
  CNTOOLS_NETWORK="preprod"
  api_before="$(wc -l < "${API_TRACE}")"
  if cntools_transaction_submit "${complete}"; then
    fail "preview package was submitted while configured for preprod"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "targets preview" \
    "submission network-mismatch diagnostic"
  assert_eq "$(wc -l < "${API_TRACE}")" "${api_before}" \
    "network-mismatched package reached Koios"
  CNTOOLS_NETWORK="preview"

  cntools_transaction_submit_reset
  cntools_transaction_package_reset_loaded
  cntools_transaction_submit_input_prepare "${zero_vkey_external}" ||
    fail "external envelope with no VKey witnesses was not admitted for backend validation: ${CNTOOLS_TRANSACTION_ERROR}"
  assert_eq "${CNTOOLS_TRANSACTION_SUBMIT_INPUT_KIND}" external-envelope \
    "external-envelope input kind"
  assert_eq "${CNTOOLS_TRANSACTION_SUBMIT_COMPLETENESS}" unverified \
    "external-envelope completeness assurance"
  assert_eq "${CNTOOLS_TRANSACTION_SUBMIT_VKEY_WITNESS_COUNT}" 0 \
    "external-envelope VKey witness count"
  cntools_transaction_submit_reset
  cntools_transaction_package_reset_loaded
  if cntools_transaction_submit_input_prepare "${bootstrap_external}"; then
    fail "external envelope with an unsupported bootstrap witness was accepted"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "Byron/bootstrap" \
    "unsupported bootstrap witness diagnostic"

  jq --arg signature "$(printf '66%.0s' {1..64})" \
    '.fakeWitnesses[0].signature = $signature' \
    "${signed}" > "${invalid_signed}"
  chmod 0600 "${invalid_signed}"
  cntools_transaction_submit_local_ready() { return 1; }
  CNTOOLS_MODE="light"
  api_before="$(wc -l < "${API_TRACE}")"
  if cntools_transaction_submit "${invalid_signed}"; then
    fail "raw signed envelope with an invalid VKey witness was accepted"
  fi
  assert_eq "$(wc -l < "${API_TRACE}")" "${api_before}" \
    "invalid raw-envelope witness reached Koios"

  cntools_transaction_submit_local_ready() { return 0; }
  CNTOOLS_MODE="local"
  export FAKE_CLI_SCENARIO="success"
  cntools_transaction_submit "${complete}" ||
    fail "local package submission failed: ${CNTOOLS_TRANSACTION_ERROR}"
  assert_eq "${CNTOOLS_TRANSACTION_SUBMIT_BACKEND}" local \
    "local submission backend"
  assert_eq "${CNTOOLS_TRANSACTION_SUBMIT_ID}" "${TX_ID}" \
    "local submitted transaction ID"
  jq -e --arg socket "${CNTOOLS_SOCKET}" '
    select(.[0:3] == ["latest", "transaction", "submit"]) |
    index("--testnet-magic") != null and
    .[index("--testnet-magic") + 1] == "2" and
    index("--socket-path") != null and
    .[index("--socket-path") + 1] == $socket and
    index("--tx-file") != null
  ' "${CLI_TRACE}" >/dev/null ||
    fail "local submission did not use the pinned CLI/network/socket contract"
  assert_file_unchanged "${complete}" "${complete_snapshot}" \
    "local submission changed its package"

  export FAKE_CLI_SCENARIO="submit-error"
  if cntools_transaction_submit "${complete}"; then
    fail "failed local submission was reported as accepted"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "outcome may be unknown" \
    "ambiguous local submission diagnostic"
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "${TX_ID}" \
    "ambiguous local submission transaction ID"
  assert_file_unchanged "${complete}" "${complete_snapshot}" \
    "failed local submission changed its package"

  cntools_transaction_submit_local_ready() { return 1; }
  CNTOOLS_MODE="light"
  : > "${API_TRACE}"
  export FAKE_API_SCENARIO="success"
  cntools_transaction_submit "${koios_source}" ||
    fail "Koios HTTP 202 submission failed: ${CNTOOLS_TRANSACTION_ERROR}"
  assert_eq "${CNTOOLS_TRANSACTION_SUBMIT_BACKEND}" koios \
    "Koios submission backend"
  assert_eq "${CNTOOLS_TRANSACTION_SUBMIT_HTTP_STATUS}" 202 \
    "Koios HTTP status"
  api_trace="$(tail -n 1 "${API_TRACE}")"
  jq -e --arg endpoint "${CNTOOLS_KOIOS_API}/submittx" '
    .[0] == "POST" and .[1] == $endpoint and
    index("content-type: application/cbor") != null and
    index("--data-binary") != null and
    (.[index("--data-binary") + 1] | startswith("@/"))
  ' <<< "${api_trace}" >/dev/null ||
    fail "Koios submission did not send exact CBOR to the expected endpoint"
  jq -er '.cborHex' "${koios_source}" | xxd -r -p > "${expected_raw}"
  cntools_transaction_submit_sha256_into expected_digest "${expected_raw}" ||
    fail "could not calculate expected Koios provenance digest"
  assert_eq "${CNTOOLS_TRANSACTION_SUBMIT_CBOR_SHA256}" \
    "${expected_digest}" "Koios submitted-CBOR provenance digest"
  provenance_record="$(grep -F "Submission provenance:" \
    "${LOG_TRACE}" | tail -n 1)"
  assert_contains "${provenance_record}" \
    "transaction_id=${TX_ID}" "Koios provenance transaction ID"
  assert_contains "${provenance_record}" \
    "signed_cbor_sha256=${expected_digest}" "Koios provenance digest log"
  grep -F "Mutable artifact replay source; verify" \
    "${LOG_TRACE}" | tail -n 1 | grep -F "${koios_source}" >/dev/null ||
    fail "Koios mutable replay source was not labelled and recorded"
  if grep -F "Mutable artifact replay source; verify" \
      "${LOG_TRACE}" | tail -n 1 |
      grep -F '.cntools-transaction-submit-cbor.' >/dev/null; then
    fail "Koios artifact replay depends on an erased raw-CBOR temporary file"
  fi
  jq '.cborHex = "aa99"' "${koios_source}" > "${koios_source}.next"
  mv -- "${koios_source}.next" "${koios_source}"
  chmod 0600 "${koios_source}"
  jq -er '.cborHex' "${koios_source}" | xxd -r -p > "${expected_raw}"
  cntools_transaction_submit_sha256_into mutated_digest "${expected_raw}" ||
    fail "could not calculate mutated replay-source digest"
  [[ "${mutated_digest}" != "${expected_digest}" ]] ||
    fail "replay-source mutation did not change its CBOR digest"
  assert_contains "${provenance_record}" \
    "signed_cbor_sha256=${expected_digest}" \
    "durable Koios provenance changed with its mutable source"

  export FAKE_API_SCENARIO="mismatch"
  if cntools_transaction_submit "${signed}"; then
    fail "Koios response with a mismatched transaction ID was accepted"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "expected ${TX_ID}" \
    "Koios mismatched-ID diagnostic"

  export FAKE_API_SCENARIO="http-error"
  if cntools_transaction_submit "${signed}"; then
    fail "Koios HTTP error was accepted"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "HTTP 500" \
    "Koios HTTP-error diagnostic"
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "${TX_ID}" \
    "Koios HTTP-error transaction ID"

  CNTOOLS_KOIOS_TOKEN="koios-secret-that-must-not-reach-the-log"
  export FAKE_API_SCENARIO="reflected-secret"
  if cntools_transaction_submit "${signed}"; then
    fail "Koios response reflecting its bearer token was accepted"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" \
    "sensitive HTTP response detail redacted" \
    "reflected Koios credential diagnostic"
  if [[ "${CNTOOLS_TRANSACTION_ERROR}" == *"${CNTOOLS_KOIOS_TOKEN}"* ]] ||
     grep -F -- "${CNTOOLS_KOIOS_TOKEN}" "${LOG_TRACE}" >/dev/null; then
    fail "reflected Koios credential reached an error or persistent log"
  fi
  CNTOOLS_KOIOS_TOKEN=""

  export FAKE_API_SCENARIO="transfer-after-202"
  if cntools_transaction_submit "${signed}"; then
    fail "failed Koios transfer after HTTP 202 was reported as success"
  fi
  assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "outcome is unknown" \
    "ambiguous Koios transfer diagnostic"
  assert_file_unchanged "${signed}" "${signed_snapshot}" \
    "Koios submission changed its input envelope"
}

# The synthetic cardano-cli exercises orchestration; the foundation suite
# separately validates a real pinned cardano-cli witness with OpenSSL.
cntools_transaction_witness_signature_valid() {
  [[ "${1:-}" =~ ^[0-9a-f]{64}$ &&
     "${2:-}" =~ ^[0-9a-f]{64}$ &&
     "${3:-}" == "${FAKE_SIGNATURE}" ]]
}

test_http_secret_path_ancestry
test_cli_partial_complete_and_tampering
test_signing_guards_and_non_overwrite
test_hardware_cli_exact_version_contract
test_hardware_group_atomicity_and_change_reference
test_mixed_signing_hardware_normalization_guard
test_submission_backends_and_integrity

cntools_transaction_cleanup
cntools_http_temp_files_cleanup
cntools_http_secret_files_cleanup
assert_no_transaction_debris

printf 'CNTools transaction sign/submit tests passed\n'
