#!/usr/bin/env bash
# Exercise the CNTools transaction contracts with the pinned release binaries.
# This is intentionally node-free and needs no hardware wallet.
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="$3"

  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

kernel="$(uname -s)"
machine="$(uname -m)"
if [[ "${kernel}" != "Linux" || "${machine}" != "x86_64" ]]; then
  printf 'SKIP: pinned CNTools transaction smoke test requires Linux x86_64.\n'
  exit 0
fi

(( BASH_VERSINFO[0] >= 4 )) ||
  fail "Bash 4 or newer is required"

for required_command in \
  awk chmod cmp curl dirname jq mkdir mktemp mv rm sha256sum tar tr uname; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
RELEASE_FILE="${REPO_ROOT}/files/node-implementations/cnode/release.json"
COMMON_RELEASE_FILE="${REPO_ROOT}/files/node-implementations/common/release.json"
CACHE_ROOT="${CNTOOLS_PINNED_TEST_CACHE:-${TMPDIR:-/tmp}/guild-operators-cntools-pinned-cache}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-transaction-pinned.XXXXXX")"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT HUP INT TERM

[[ -f "${RELEASE_FILE}" && ! -L "${RELEASE_FILE}" ]] ||
  fail "cnode release metadata is missing or unsafe"
[[ -f "${COMMON_RELEASE_FILE}" && ! -L "${COMMON_RELEASE_FILE}" ]] ||
  fail "common Guild tool metadata is missing or unsafe"
jq -e '
  .schemaVersion == 1 and .implementation == "cnode" and
  (.companions["cardano-cli"].version |
    type == "string" and test("^[0-9]+(\\.[0-9]+){3}$")) and
  (.companions["cardano-cli"].artifacts["linux-x86_64"] |
    (.url | type == "string" and startswith("https://")) and
    (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
' "${RELEASE_FILE}" >/dev/null ||
  fail "cnode release metadata does not contain a safe pinned x86_64 Cardano CLI"
jq -e '
  .schemaVersion == 1 and .scope == "guild-tools" and
  (.tools["cardano-hw-cli"].version |
    type == "string" and test("^[0-9]+(\\.[0-9]+){2}$")) and
  (.tools["cardano-hw-cli"].artifacts["linux-x86_64"] |
    (.url | type == "string" and startswith("https://")) and
    (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
' "${COMMON_RELEASE_FILE}" >/dev/null ||
  fail "common Guild tool metadata does not contain a safe pinned x86_64 hardware CLI"

CLI_VERSION="$(jq -er '.companions["cardano-cli"].version' "${RELEASE_FILE}")"
CLI_URL="$(jq -er '.companions["cardano-cli"].artifacts["linux-x86_64"].url' "${RELEASE_FILE}")"
CLI_SHA256="$(jq -er '.companions["cardano-cli"].artifacts["linux-x86_64"].sha256' "${RELEASE_FILE}")"
HWCLI_VERSION="$(jq -er '.tools["cardano-hw-cli"].version' "${COMMON_RELEASE_FILE}")"
HWCLI_URL="$(jq -er '.tools["cardano-hw-cli"].artifacts["linux-x86_64"].url' "${COMMON_RELEASE_FILE}")"
HWCLI_SHA256="$(jq -er '.tools["cardano-hw-cli"].artifacts["linux-x86_64"].sha256' "${COMMON_RELEASE_FILE}")"

[[ -n "${CACHE_ROOT}" && "${CACHE_ROOT}" != "/" && ! -L "${CACHE_ROOT}" ]] ||
  fail "pinned-tool cache path is unsafe"
mkdir -p -- "${CACHE_ROOT}"
chmod 0700 "${CACHE_ROOT}"

sha256_into() {
  local output_name="$1"
  local file="$2"
  local value=""

  value="$(sha256sum -- "${file}" | awk 'NR == 1 {print tolower($1)}')" ||
    return 1
  [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf -v "${output_name}" '%s' "${value}"
}

fetch_pinned_archive() {
  local output_name="$1"
  local label="$2"
  local url="$3"
  local expected_sha256="$4"
  local archive="${CACHE_ROOT}/${label}-${expected_sha256}.tar.gz"
  local temporary=""
  local actual_sha256=""

  if [[ -f "${archive}" && ! -L "${archive}" ]]; then
    sha256_into actual_sha256 "${archive}" || actual_sha256=""
  fi
  if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
    if [[ -e "${archive}" || -L "${archive}" ]]; then
      rm -f -- "${archive}" ||
        fail "could not discard an invalid cached ${label} archive"
    fi
    temporary="$(mktemp "${TEST_ROOT}/.${label}.download.XXXXXX")"
    printf 'Downloading pinned %s release...\n' "${label}"
    if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --fail --location --silent --show-error \
        --connect-timeout 20 --max-time 600 \
        --retry 3 --retry-delay 2 \
        --output "${temporary}" "${url}"; then
      rm -f -- "${temporary}"
      fail "could not download pinned ${label} release"
    fi
    sha256_into actual_sha256 "${temporary}" || actual_sha256=""
    if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
      rm -f -- "${temporary}"
      fail "checksum verification failed for pinned ${label} release"
    fi
    chmod 0600 "${temporary}"
    mv -f -- "${temporary}" "${archive}"
  else
    printf 'Using cached pinned %s release.\n' "${label}"
  fi

  # Recheck the final cache object on every run, including immediately after
  # download. Only this verified archive is ever extracted or executed.
  [[ -f "${archive}" && ! -L "${archive}" ]] ||
    fail "cached ${label} archive is unsafe"
  sha256_into actual_sha256 "${archive}" || actual_sha256=""
  [[ "${actual_sha256}" == "${expected_sha256}" ]] ||
    fail "cached ${label} archive no longer matches its release checksum"
  printf -v "${output_name}" '%s' "${archive}"
}

CLI_ARCHIVE=""
HWCLI_ARCHIVE=""
fetch_pinned_archive CLI_ARCHIVE cardano-cli "${CLI_URL}" "${CLI_SHA256}"
fetch_pinned_archive HWCLI_ARCHIVE cardano-hw-cli \
  "${HWCLI_URL}" "${HWCLI_SHA256}"

CLI_ROOT="${TEST_ROOT}/cardano-cli"
HWCLI_ROOT="${TEST_ROOT}/cardano-hw-cli"
mkdir -m 0700 -- "${CLI_ROOT}" "${HWCLI_ROOT}"
tar -xzf "${CLI_ARCHIVE}" -C "${CLI_ROOT}" ||
  fail "could not extract pinned cardano-cli release"
tar -xzf "${HWCLI_ARCHIVE}" -C "${HWCLI_ROOT}" ||
  fail "could not extract pinned cardano-hw-cli release"

CLI="${CLI_ROOT}/cardano-cli-x86_64-linux"
HWCLI="${HWCLI_ROOT}/cardano-hw-cli/cardano-hw-cli"
[[ -f "${CLI}" && ! -L "${CLI}" ]] ||
  fail "pinned cardano-cli archive has an unexpected layout"
[[ -f "${HWCLI}" && ! -L "${HWCLI}" ]] ||
  fail "pinned cardano-hw-cli archive has an unexpected layout"
chmod 0700 "${CLI}" "${HWCLI}"

CLI_VERSION_OUTPUT="$("${CLI}" version 2>&1)" ||
  fail "pinned cardano-cli could not be started"
CLI_VERSION_PATTERN="^cardano-cli[[:space:]]+${CLI_VERSION//./\\.}([[:space:]]|$)"
[[ "${CLI_VERSION_OUTPUT}" =~ ${CLI_VERSION_PATTERN} ]] ||
  fail "cardano-cli output does not report pinned version ${CLI_VERSION}"
"${CLI}" latest transaction calculate-min-required-utxo --help \
  >/dev/null 2>&1 ||
  fail "pinned cardano-cli does not expose minimum-UTxO calculation"
"${CLI}" latest transaction build-estimate --help >/dev/null 2>&1 ||
  fail "pinned cardano-cli does not expose the node-free transaction builder"

HWCLI_VERSION_OUTPUT="$("${HWCLI}" version 2>&1)" ||
  fail "pinned cardano-hw-cli could not be started"
HWCLI_VERSION_PATTERN="Cardano[[:space:]]+HW[[:space:]]+CLI[[:space:]]+Tool[[:space:]]+version[[:space:]]+v?${HWCLI_VERSION//./\\.}([[:space:]]|$)"
[[ "${HWCLI_VERSION_OUTPUT}" =~ ${HWCLI_VERSION_PATTERN} ]] ||
  fail "cardano-hw-cli output does not report pinned version ${HWCLI_VERSION}"

GENERATED_SKEY="${TEST_ROOT}/generated.skey"
GENERATED_VKEY="${TEST_ROOT}/generated.vkey"
GENERATED_DERIVED_VKEY="${TEST_ROOT}/generated-derived.vkey"
GENERATED_STAKE_SKEY="${TEST_ROOT}/generated-stake.skey"
GENERATED_STAKE_VKEY="${TEST_ROOT}/generated-stake.vkey"
REGISTRATION_CERTIFICATE="${TEST_ROOT}/stake-registration.cert"
DEREGISTRATION_CERTIFICATE="${TEST_ROOT}/stake-deregistration.cert"
"${CLI}" address key-gen \
  --verification-key-file "${GENERATED_VKEY}" \
  --signing-key-file "${GENERATED_SKEY}" ||
  fail "pinned cardano-cli address key generation failed"
jq -e '
  .type == "PaymentSigningKeyShelley_ed25519" and
  (.cborHex | type == "string" and test("^5820[0-9a-f]{64}$"))
' "${GENERATED_SKEY}" >/dev/null ||
  fail "generated payment signing key has an unexpected envelope"
jq -e '
  .type == "PaymentVerificationKeyShelley_ed25519" and
  (.cborHex | type == "string" and test("^5820[0-9a-f]{64}$"))
' "${GENERATED_VKEY}" >/dev/null ||
  fail "generated payment verification key has an unexpected envelope"
"${CLI}" key verification-key \
  --signing-key-file "${GENERATED_SKEY}" \
  --verification-key-file "${GENERATED_DERIVED_VKEY}" ||
  fail "pinned cardano-cli verification-key derivation failed"
assert_eq \
  "$(jq -er '.cborHex' "${GENERATED_DERIVED_VKEY}")" \
  "$(jq -er '.cborHex' "${GENERATED_VKEY}")" \
  "generated payment key pair"

"${CLI}" latest stake-address key-gen \
  --verification-key-file "${GENERATED_STAKE_VKEY}" \
  --signing-key-file "${GENERATED_STAKE_SKEY}" ||
  fail "pinned cardano-cli stake key generation failed"
"${CLI}" latest stake-address registration-certificate \
  --stake-verification-key-file "${GENERATED_STAKE_VKEY}" \
  --key-reg-deposit-amt 2000000 \
  --out-file "${REGISTRATION_CERTIFICATE}" ||
  fail "pinned cardano-cli stake registration certificate failed"
jq -e '
  (.type | type == "string" and length > 0) and
  (.description | type == "string") and
  (.cborHex | type == "string" and test("^([0-9a-fA-F]{2})+$"))
' "${REGISTRATION_CERTIFICATE}" >/dev/null ||
  fail "stake registration certificate has an unexpected envelope"
"${CLI}" latest stake-address deregistration-certificate \
  --stake-verification-key-file "${GENERATED_STAKE_VKEY}" \
  --key-reg-deposit-amt 2000000 \
  --out-file "${DEREGISTRATION_CERTIFICATE}" ||
  fail "pinned cardano-cli stake de-registration certificate failed"
jq -e '
  (.type | type == "string" and length > 0) and
  (.description | type == "string") and
  (.cborHex | type == "string" and test("^([0-9a-fA-F]{2})+$"))
' "${DEREGISTRATION_CERTIFICATE}" >/dev/null ||
  fail "stake de-registration certificate has an unexpected envelope"

# A fixed, publicly known test seed makes the transaction body reproducible.
# It must never be used with real funds.
DETERMINISTIC_SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
SIGNING_KEY="${TEST_ROOT}/deterministic.skey"
VERIFICATION_KEY="${TEST_ROOT}/deterministic.vkey"
ADDRESS_FILE="${TEST_ROOT}/deterministic.addr"
NATIVE_SCRIPT="${TEST_ROOT}/mint.script"
BODY_A="${TEST_ROOT}/transaction-a.body"
BODY_B="${TEST_ROOT}/transaction-b.body"
BODY_VIEW="${TEST_ROOT}/transaction-body.view.json"
WITNESS="${TEST_ROOT}/transaction.witness"
SIGNED="${TEST_ROOT}/transaction.signed"
SIGNED_VIEW="${TEST_ROOT}/transaction-signed.view.json"
TRANSFORMED="${TEST_ROOT}/transaction-hardware.body"
TRANSFORMED_VIEW="${TEST_ROOT}/transaction-hardware.view.json"
MALFORMED="${TEST_ROOT}/malformed.body"

jq -n --arg seed "${DETERMINISTIC_SEED}" '
  {
    type: "PaymentSigningKeyShelley_ed25519",
    description: "CNTools pinned smoke-test payment signing key",
    cborHex: ("5820" + $seed)
  }
' > "${SIGNING_KEY}"
chmod 0600 "${SIGNING_KEY}"
"${CLI}" key verification-key \
  --signing-key-file "${SIGNING_KEY}" \
  --verification-key-file "${VERIFICATION_KEY}" ||
  fail "could not derive the deterministic verification key"
PUBLIC_KEY="$(jq -er '
  select(
    .type == "PaymentVerificationKeyShelley_ed25519" and
    (.cborHex | test("^5820[0-9a-f]{64}$"))
  ) |
  .cborHex[4:]
' "${VERIFICATION_KEY}")"
[[ "${PUBLIC_KEY}" =~ ^[0-9a-f]{64}$ ]] ||
  fail "deterministic public key has an unexpected format"

PAYMENT_KEY_HASH="$("${CLI}" address key-hash \
  --payment-verification-key-file "${VERIFICATION_KEY}" | tr -d '[:space:]')" ||
  fail "could not calculate the deterministic payment key hash"
[[ "${PAYMENT_KEY_HASH}" =~ ^[0-9a-f]{56}$ ]] ||
  fail "payment key hash has an unexpected format"
"${CLI}" address build \
  --payment-verification-key-file "${VERIFICATION_KEY}" \
  --testnet-magic 42 \
  --out-file "${ADDRESS_FILE}" ||
  fail "could not build the deterministic test address"
ADDRESS="$(tr -d '[:space:]' < "${ADDRESS_FILE}")"
[[ "${ADDRESS}" == addr_test1* ]] ||
  fail "deterministic test address has an unexpected format"

jq -n --arg key_hash "${PAYMENT_KEY_HASH}" '
  {type: "all", scripts: [{type: "sig", keyHash: $key_hash}]}
' > "${NATIVE_SCRIPT}"
POLICY_ID="$("${CLI}" latest transaction policyid \
  --script-file "${NATIVE_SCRIPT}" | tr -d '[:space:]')" ||
  fail "could not calculate the native-script policy ID"
[[ "${POLICY_ID}" =~ ^[0-9a-f]{56}$ ]] ||
  fail "native-script policy ID has an unexpected format"
assert_eq \
  "$("${CLI}" latest transaction policyid --script-file "${NATIVE_SCRIPT}" | tr -d '[:space:]')" \
  "${POLICY_ID}" "native-script policy ID stability"

TX_INPUT="1111111111111111111111111111111111111111111111111111111111111111#0"
REFERENCE_INPUT="2222222222222222222222222222222222222222222222222222222222222222#1"
ASSET_NAME="74657374"
TX_OUTPUT="${ADDRESS}+2000000+1 ${POLICY_ID}.${ASSET_NAME}"
MINT_VALUE="1 ${POLICY_ID}.${ASSET_NAME}"

build_body() {
  local output_file="$1"

  "${CLI}" latest transaction build-raw \
    --tx-in "${TX_INPUT}" \
    --read-only-tx-in-reference "${REFERENCE_INPUT}" \
    --required-signer-hash "${PAYMENT_KEY_HASH}" \
    --tx-out "${TX_OUTPUT}" \
    --mint "${MINT_VALUE}" \
    --mint-script-file "${NATIVE_SCRIPT}" \
    --invalid-before 100 \
    --invalid-hereafter 200 \
    --fee 170000 \
    --out-canonical-cbor \
    --out-file "${output_file}"
}

build_body "${BODY_A}" || fail "first node-free transaction build failed"
build_body "${BODY_B}" || fail "second node-free transaction build failed"
jq -e '
  .type == "Tx ConwayEra" and
  (.cborHex | type == "string" and test("^[0-9a-f]+$") and
    (length % 2 == 0))
' "${BODY_A}" >/dev/null ||
  fail "built transaction body has an unexpected text envelope"
assert_eq "$(jq -er '.cborHex' "${BODY_A}")" \
  "$(jq -er '.cborHex' "${BODY_B}")" \
  "canonical build-raw output"

TX_ID="$("${CLI}" latest transaction txid \
  --tx-body-file "${BODY_A}" --output-text | tr -d '[:space:]')" ||
  fail "could not calculate the transaction ID"
[[ "${TX_ID}" =~ ^[0-9a-f]{64}$ ]] ||
  fail "transaction ID has an unexpected format"
assert_eq \
  "$("${CLI}" latest transaction txid --tx-body-file "${BODY_B}" \
    --output-text | tr -d '[:space:]')" \
  "${TX_ID}" "deterministic transaction ID"

"${CLI}" debug transaction view --output-json \
  --tx-body-file "${BODY_A}" > "${BODY_VIEW}" ||
  fail "could not decode the transaction body"
jq -e --arg required "${PAYMENT_KEY_HASH}" \
  --arg policy "${POLICY_ID}" --arg reference "${REFERENCE_INPUT}" '
  .era == "Conway" and
  ((."validity range"."lower bound" | tostring) == "100") and
  ((."validity range"."upper bound" | tostring) == "200") and
  (."required signers (payment key hashes needed for scripts)" |
    type == "array" and map(ascii_downcase) == [$required]) and
  (."reference inputs" |
    type == "array" and map(ascii_downcase) == [$reference]) and
  (.scripts | type == "array" and length == 1) and
  (.scripts[0]."script hash" | ascii_downcase) == $policy and
  .scripts[0]."script data".type == "native" and
  (.witnesses | type == "array" and length == 0)
' "${BODY_VIEW}" >/dev/null ||
  fail "cardano-cli debug view no longer matches the CNTools body contract"

"${CLI}" latest transaction witness \
  --tx-body-file "${BODY_A}" \
  --signing-key-file "${SIGNING_KEY}" \
  --testnet-magic 42 \
  --out-file "${WITNESS}" ||
  fail "transaction witness creation failed"
jq -e '
  .type == "TxWitness ConwayEra" and
  (.cborHex | type == "string" and test("^[0-9a-f]+$") and
    (length % 2 == 0))
' "${WITNESS}" >/dev/null ||
  fail "transaction witness has an unexpected text envelope"

"${CLI}" latest transaction assemble \
  --tx-body-file "${BODY_A}" \
  --witness-file "${WITNESS}" \
  --out-canonical-cbor \
  --out-file "${SIGNED}" ||
  fail "transaction assembly failed"
jq -e '.type == "Tx ConwayEra"' "${SIGNED}" >/dev/null ||
  fail "assembled transaction has an unexpected text envelope"
assert_eq \
  "$("${CLI}" latest transaction txid --tx-file "${SIGNED}" \
    --output-text | tr -d '[:space:]')" \
  "${TX_ID}" "assembled transaction ID"
"${CLI}" debug transaction view --output-json \
  --tx-file "${SIGNED}" > "${SIGNED_VIEW}" ||
  fail "could not decode the assembled transaction"
jq -e --arg key "${PUBLIC_KEY}" '
  (.witnesses | type == "array" and length == 1) and
  .witnesses[0].key ==
    ("VKey (VerKeyEd25519DSIGN \"" + $key + "\")") and
  (.witnesses[0].signature |
    test("^SignedDSIGN \\(SigEd25519DSIGN \\\"[0-9a-f]{128}\\\"\\)$"))
' "${SIGNED_VIEW}" >/dev/null ||
  fail "signed debug view no longer matches the CNTools witness contract"

# Validation and transformation are pure operations in cardano-hw-cli. They
# exercise hardware-wallet compatibility without discovering or using a device.
set +e
"${HWCLI}" transaction validate --tx-file "${BODY_A}"
HW_VALIDATE_STATUS=$?
set -e
case "${HW_VALIDATE_STATUS}" in
  0|3) ;;
  1) fail "cardano-hw-cli could not parse the pinned cardano-cli body" ;;
  2) fail "the smoke transaction violates a non-fixable hardware-wallet restriction" ;;
  *) fail "cardano-hw-cli validate returned undocumented status ${HW_VALIDATE_STATUS}" ;;
esac

"${HWCLI}" transaction transform \
  --tx-file "${BODY_A}" \
  --out-file "${TRANSFORMED}" ||
  fail "cardano-hw-cli transaction transformation failed"
[[ -s "${TRANSFORMED}" && ! -L "${TRANSFORMED}" ]] ||
  fail "cardano-hw-cli did not write a transformed transaction body"
set +e
"${HWCLI}" transaction validate --tx-file "${TRANSFORMED}"
HW_TRANSFORMED_STATUS=$?
set -e
assert_eq "${HW_TRANSFORMED_STATUS}" 0 \
  "transformed hardware transaction validation status"
"${CLI}" debug transaction view --output-json \
  --tx-body-file "${TRANSFORMED}" > "${TRANSFORMED_VIEW}" ||
  fail "cardano-cli could not decode the hardware-transformed body"
cmp -s \
  <(jq -S . "${BODY_VIEW}") \
  <(jq -S . "${TRANSFORMED_VIEW}") ||
  fail "hardware transformation changed transaction semantics"

jq -n '{not: "a Cardano transaction"}' > "${MALFORMED}"
set +e
"${HWCLI}" transaction validate --tx-file "${MALFORMED}" >/dev/null 2>&1
HW_MALFORMED_STATUS=$?
set -e
assert_eq "${HW_MALFORMED_STATUS}" 1 \
  "malformed hardware transaction validation status"

printf 'CNTools pinned transaction binary tests passed (cardano-cli %s, cardano-hw-cli %s).\n' \
  "${CLI_VERSION}" "${HWCLI_VERSION}"
