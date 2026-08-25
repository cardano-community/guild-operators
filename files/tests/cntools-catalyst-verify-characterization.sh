#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools Catalyst verification characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/vote/catalyst/verify/action.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/vote/catalyst/verify"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-catalyst-verify.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
REAL_JQ="$(command -v jq 2>/dev/null || true)"
REAL_HEAD="$(command -v head 2>/dev/null || true)"
REAL_TR="$(command -v tr 2>/dev/null || true)"
REAL_STAT="$(command -v stat 2>/dev/null || true)"

VOTE_KEY_HEX="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NON_HEX_KEY="zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
DELEGATOR_ONE="0x1111111111111111111111111111111111111111111111111111111111111111"
DELEGATOR_TWO="0x2222222222222222222222222222222222222222222222222222222222222222"
DELEGATOR_THREE="0x3333333333333333333333333333333333333333333333333333333333333333"
CATALYST_API_FIXTURE="https://catalyst.example.test/api"

cleanup_test() {
  if [[ "${CNTOOLS_CATALYST_VERIFY_PRESERVE_TEST_ROOT:-N}" == "Y" ]]; then
    printf 'CNTools Catalyst verification test root preserved: %s\n' \
      "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools Catalyst verification characterization failed: %s\n' \
    "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk cmp cut find grep head jq readlink sort stat wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
[[ -n "${REAL_JQ}" ]] || fail 'jq is required'
[[ -n "${REAL_HEAD}" && -n "${REAL_TR}" && -n "${REAL_STAT}" ]] ||
  fail 'head, stat, and tr are required'
if command -v sha256sum >/dev/null 2>&1; then
  HASH_COMMAND="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_COMMAND="shasum"
else
  fail 'sha256sum or shasum is required'
fi

write_fake_commands() {
  local command_name

  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target=""' \
    'for argument in "$@"; do target="${argument}"; done' \
    'if [[ "${CNTOOLS_CATALYST_SCENARIO:-}" == "wallet-malformed-json" &&' \
    '      "${target}" == */wallet/registered/catalyst.vkey ]]; then' \
    '  printf '\''jq: parse error: malformed Catalyst key fixture\n'\'' >&2' \
    '  exit 4' \
    'fi' \
    'exec "${CNTOOLS_CATALYST_REAL_JQ:?}" "$@"' \
    > "${FAKE_BIN}/jq"
  chmod 0755 "${FAKE_BIN}/jq"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'output="" previous="" url=""' \
    'printf '\''curl'\'' >> "${CNTOOLS_CATALYST_VECTOR_LOG:?}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  if [[ "${previous}" == "--output" ]]; then' \
    '    output="${argument}"; normalized="<private-response>"' \
    '  elif [[ "${previous}" == "--url" ]]; then' \
    '    url="${argument}"' \
    '  fi' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${CNTOOLS_CATALYST_VECTOR_LOG:?}"' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_CATALYST_VECTOR_LOG:?}"' \
    '[[ -n "${output}" && -f "${output}" && ! -L "${output}" ]] || exit 98' \
    '[[ "${output%/*}" == "${CNTOOLS_CATALYST_EXPECTED_RESPONSE_PARENT:?}" ]] || exit 98' \
    'if mode="$("${CNTOOLS_CATALYST_REAL_STAT:?}" -f '\''%Lp'\'' "${output}" 2>/dev/null)"; then :' \
    'else mode="$("${CNTOOLS_CATALYST_REAL_STAT:?}" -c '\''%a'\'' -- "${output}" 2>/dev/null)" || exit 98; fi' \
    '[[ "${mode#0}" == "600" ]] || exit 98' \
    'case "${CNTOOLS_CATALYST_SCENARIO:?}" in' \
    '  wallet-success-mixed-delegators)' \
    '    case "${url}" in' \
    '      */registration/voter/*)' \
    '        printf '\''{"last_updated":"2024-01-02T03:04:05Z","final":false,"voter_info":{"voting_power":2500000,"delegations_count":3,"delegator_addresses":["%s","%s","%s"]}}\n'\'' "${CNTOOLS_CATALYST_DELEGATOR_ONE:?}" "${CNTOOLS_CATALYST_DELEGATOR_TWO:?}" "${CNTOOLS_CATALYST_DELEGATOR_THREE:?}" > "${output}"' \
    '        ;;' \
    '      */registration/delegations/0x1111111111111111111111111111111111111111111111111111111111111111)' \
    '        printf '\''{"reward_address":"addr1reward-one","reward_payable":true,"raw_power":1250000}\n'\'' > "${output}"' \
    '        ;;' \
    '      */registration/delegations/0x2222222222222222222222222222222222222222222222222222222222222222)' \
    '        printf '\''{"reward_address":"addr1reward-two","reward_payable":false,"raw_power":500000}\n'\'' > "${output}"' \
    '        ;;' \
    '      */registration/delegations/0x3333333333333333333333333333333333333333333333333333333333333333)' \
    '        printf '\''curl: (28) fixture delegation timeout\n'\'' >&2' \
    '        exit 28' \
    '        ;;' \
    '      *) printf '\''unexpected success-case URL: %s\n'\'' "${url}" >&2; exit 96 ;;' \
    '    esac' \
    '    ;;' \
    '  public-voter-transport-failure)' \
    '    printf '\''curl: (28) fixture voter timeout\n'\'' >&2' \
    '    exit 28' \
    '    ;;' \
    '  public-safe-not-found)' \
    '    printf '\''{"error":"Voter not found"}\n'\'' > "${output}"' \
    '    ;;' \
    '  public-voter-oversized)' \
    '    "${CNTOOLS_CATALYST_REAL_HEAD:?}" -c 262145 /dev/zero | "${CNTOOLS_CATALYST_REAL_TR:?}" '\''\\000'\'' x > "${output}"' \
    '    ;;' \
    '  public-voter-curl-size-status)' \
    '    exit 63' \
    '    ;;' \
    '  public-voter-invalid-json)' \
    '    printf '\''{ malformed voter response\n'\'' > "${output}"' \
    '    ;;' \
    '  public-voter-unsafe-error)' \
    '    printf '\''{"error":"unsafe\\\\diagnostic"}\n'\'' > "${output}"' \
    '    ;;' \
    '  public-voter-invalid-timestamp)' \
    '    printf '\''{"last_updated":"2024-02-31T03:04:05Z","final":true,"voter_info":{"voting_power":1,"delegations_count":0,"delegator_addresses":[]}}\n'\'' > "${output}"' \
    '    ;;' \
    '  public-voter-duplicate-delegators)' \
    '    printf '\''{"last_updated":"2024-01-02T03:04:05Z","final":true,"voter_info":{"voting_power":1,"delegations_count":2,"delegator_addresses":["%s","%s"]}}\n'\'' "${CNTOOLS_CATALYST_DELEGATOR_ONE:?}" "${CNTOOLS_CATALYST_DELEGATOR_ONE:?}" > "${output}"' \
    '    ;;' \
    '  public-voter-too-many-delegators)' \
    '    "${CNTOOLS_CATALYST_REAL_JQ:?}" -nc '\''[range(0;101) | "0x" + (tostring | ltrimstr("") | ("0" * (64-length)) + .)] as $keys | {last_updated:"2024-01-02T03:04:05Z",final:true,voter_info:{voting_power:1,delegations_count:101,delegator_addresses:$keys}}'\'' > "${output}"' \
    '    ;;' \
    '  public-voter-count-mismatch)' \
    '    printf '\''{"last_updated":"2024-01-02T03:04:05Z","final":true,"voter_info":{"voting_power":1,"delegations_count":2,"delegator_addresses":["%s"]}}\n'\'' "${CNTOOLS_CATALYST_DELEGATOR_ONE:?}" > "${output}"' \
    '    ;;' \
    '  public-voter-invalid-delegator-key)' \
    '    printf '\''{"last_updated":"2024-01-02T03:04:05Z","final":true,"voter_info":{"voting_power":1,"delegations_count":1,"delegator_addresses":["0xunsafe"]}}\n'\'' > "${output}"' \
    '    ;;' \
    '  public-voter-unbounded-power)' \
    '    printf '\''{"last_updated":"2024-01-02T03:04:05Z","final":true,"voter_info":{"voting_power":45000000000000001,"delegations_count":0,"delegator_addresses":[]}}\n'\'' > "${output}"' \
    '    ;;' \
    '  public-delegation-invalid-json|public-delegation-oversized|public-delegation-unsafe-address|public-delegation-unbounded-power|public-ccli-failure|public-unsafe-stake-address)' \
    '    case "${url}" in' \
    '      */registration/voter/*)' \
    '        printf '\''{"last_updated":"2024-01-02T03:04:05Z","final":true,"voter_info":{"voting_power":1250000,"delegations_count":1,"delegator_addresses":["%s"]}}\n'\'' "${CNTOOLS_CATALYST_DELEGATOR_ONE:?}" > "${output}"' \
    '        ;;' \
    '      */registration/delegations/*)' \
    '        if [[ "${CNTOOLS_CATALYST_SCENARIO}" == "public-delegation-invalid-json" ]]; then' \
    '          printf '\''{ malformed delegation response\n'\'' > "${output}"' \
    '        elif [[ "${CNTOOLS_CATALYST_SCENARIO}" == "public-delegation-oversized" ]]; then' \
    '          "${CNTOOLS_CATALYST_REAL_HEAD:?}" -c 65537 /dev/zero | "${CNTOOLS_CATALYST_REAL_TR:?}" '\''\\000'\'' x > "${output}"' \
    '        elif [[ "${CNTOOLS_CATALYST_SCENARIO}" == "public-delegation-unsafe-address" ]]; then' \
    '          printf '\''{"reward_address":"../../unsafe","reward_payable":true,"raw_power":1}\n'\'' > "${output}"' \
    '        elif [[ "${CNTOOLS_CATALYST_SCENARIO}" == "public-delegation-unbounded-power" ]]; then' \
    '          printf '\''{"reward_address":"addr1safe","reward_payable":true,"raw_power":45000000000000001}\n'\'' > "${output}"' \
    '        else' \
    '          exit 96' \
    '        fi' \
    '        ;;' \
    '      *) exit 96 ;;' \
    '    esac' \
    '    ;;' \
    '  *) printf '\''unexpected curl scenario: %s\n'\'' "${CNTOOLS_CATALYST_SCENARIO}" >&2; exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/curl"
  chmod 0755 "${FAKE_BIN}/curl"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''cardano-cli'\'' >> "${CNTOOLS_CATALYST_VECTOR_LOG:?}"' \
    'printf '\''\t%s'\'' "$@" >> "${CNTOOLS_CATALYST_VECTOR_LOG:?}"' \
    'printf '\''\n'\'' >> "${CNTOOLS_CATALYST_VECTOR_LOG:?}"' \
    'case "${CNTOOLS_CATALYST_SCENARIO:?}" in' \
    '  wallet-success-mixed-delegators|public-delegation-invalid-json|public-delegation-oversized|public-delegation-unsafe-address|public-delegation-unbounded-power) ;;' \
    '  public-ccli-failure) printf '\''unsafe raw CCLI failure\n'\'' >&2; exit 9 ;;' \
    '  public-unsafe-stake-address) printf '\''Stake1UNSAFE OUTPUT\n'\''; exit 0 ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    '[[ "$#" == 6 && "$1" == "latest" && "$2" == "stake-address" &&' \
    '   "$3" == "build" && "$4" == "--stake-verification-key" &&' \
    '   "$6" == "--mainnet" ]] || exit 96' \
    'case "$5" in' \
    '  1111111111111111111111111111111111111111111111111111111111111111) printf '\''stake1fixtureone\n'\'' ;;' \
    '  2222222222222222222222222222222222222222222222222222222222222222) printf '\''stake1fixturetwo\n'\'' ;;' \
    '  3333333333333333333333333333333333333333333333333333333333333333) printf '\''stake1fixturethree\n'\'' ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/cardano-cli"
  chmod 0755 "${FAKE_BIN}/cardano-cli"

  for command_name in wget git ssh nc date; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_CATALYST_BLOCKED_LOG:?}"' \
      'printf '\''\t%s'\'' "$@" >> "${CNTOOLS_CATALYST_BLOCKED_LOG:?}"' \
      'printf '\''\n'\'' >> "${CNTOOLS_CATALYST_BLOCKED_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

prepare_wallet_fixture() {
  local wallet_root="$1"
  local scenario="$2"

  if [[ "${scenario}" == "wallet-symlink-directory" ]]; then
    mkdir -p -- "${wallet_root}/symlink-target"
    printf '{"cborHex":"5820%s"}\n' "${VOTE_KEY_HEX}" \
      > "${wallet_root}/symlink-target/catalyst.vkey"
    ln -s -- "${wallet_root}/symlink-target" "${wallet_root}/registered"
    return 0
  fi
  mkdir -p -- "${wallet_root}/registered"
  case "${scenario}" in
    wallet-malformed-json)
      printf '{ malformed Catalyst key fixture\n' \
        > "${wallet_root}/registered/catalyst.vkey"
      if "${REAL_JQ}" -e . \
          "${wallet_root}/registered/catalyst.vkey" >/dev/null 2>&1; then
        fail 'malformed Catalyst key fixture unexpectedly parsed as JSON'
      fi
      ;;
    wallet-symlink-key)
      printf '{"cborHex":"5820%s"}\n' "${VOTE_KEY_HEX}" \
        > "${wallet_root}/symlink-target.vkey"
      ln -s -- "${wallet_root}/symlink-target.vkey" \
        "${wallet_root}/registered/catalyst.vkey"
      ;;
    wallet-oversized-key)
      printf '{"cborHex":"5820%s","padding":"' "${VOTE_KEY_HEX}" \
        > "${wallet_root}/registered/catalyst.vkey"
      "${REAL_HEAD}" -c 16384 /dev/zero | "${REAL_TR}" '\000' x \
        >> "${wallet_root}/registered/catalyst.vkey"
      printf '"}\n' >> "${wallet_root}/registered/catalyst.vkey"
      ;;
    *)
      printf '{"cborHex":"5820%s"}\n' "${VOTE_KEY_HEX}" \
        > "${wallet_root}/registered/catalyst.vkey"
      ;;
  esac

  if [[ "${scenario}" == "wallet-success-mixed-delegators" ]]; then
    mkdir -p -- "${wallet_root}/alice"
    printf '%s\n' "${DELEGATOR_ONE#0x}" \
      > "${wallet_root}/alice/stake.vkey"
  fi
}

write_header() {
  local output_file="$1"

  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> VOTE >> CATALYST >> VERIFY' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    > "${output_file}"
}

write_expected_stdout() {
  local scenario="$1"
  local output_file="$2"

  : > "${output_file}"
  [[ "${scenario}" != "unsafe-api-config" ]] || return 0
  write_header "${output_file}"
  case "${scenario}" in
    offline-refusal)
      printf '%s\n' \
        '' \
        'ERROR: CNTools started in offline mode, option not available!' \
        >> "${output_file}"
      ;;
    light-nonmainnet-refusal)
      printf '%s\n' \
        '' \
        'ERROR: Catalyst registration verification only available for Mainnet at this time!' \
        >> "${output_file}"
      ;;
    public-short-key|public-nonhex64)
      printf '%s\n' \
        'Select wallet or enter vote public key?' \
        '' \
        'ERROR: invalid pub key, expected 64 characters! Supply public key in hex format without prefix (5820 or 0x)' \
        >> "${output_file}"
      ;;
    wallet-selection-failed|wallet-selection-cancel)
      printf '%s\n' \
        'Select wallet or enter vote public key?' \
        '' \
        'Select a Catalyst registered wallet' \
        >> "${output_file}"
      ;;
    wallet-malformed-json|wallet-symlink-key|wallet-symlink-directory|\
      wallet-oversized-key|wallet-unsafe-name)
      printf '%s\n' \
        'Select wallet or enter vote public key?' \
        '' \
        'Select a Catalyst registered wallet' \
        '' \
        'ERROR: selected wallet has an invalid Catalyst verification key file!' \
        >> "${output_file}"
      ;;
    public-voter-transport-failure)
      printf '%s\n' \
        'Select wallet or enter vote public key?' \
        '' \
        'ERROR: failure during Catalyst verification query!' \
        >> "${output_file}"
      ;;
    public-safe-not-found)
      printf '%s\n' \
        'Select wallet or enter vote public key?' \
        '' \
        'Status:           Voter not found' \
        >> "${output_file}"
      ;;
    public-voter-oversized|public-voter-curl-size-status)
      printf '%s\n' \
        'Select wallet or enter vote public key?' \
        '' \
        'ERROR: Catalyst verification response exceeded the 262144-byte safety limit!' \
        >> "${output_file}"
      ;;
    public-voter-invalid-json|public-voter-unsafe-error|\
      public-voter-invalid-timestamp|public-voter-duplicate-delegators|\
      public-voter-too-many-delegators|public-voter-count-mismatch|\
      public-voter-invalid-delegator-key|public-voter-unbounded-power)
      printf '%s\n' \
        'Select wallet or enter vote public key?' \
        '' \
        'ERROR: Catalyst verification service returned an invalid response!' \
        >> "${output_file}"
      ;;
    wallet-success-mixed-delegators)
      printf '%s\n' \
        'Select wallet or enter vote public key?' \
        '' \
        'Select a Catalyst registered wallet' \
        '' \
        'Status:           registered' \
        'Last updated:     2024-01-02 03:04:05 UTC' \
        'Is Finalized:     false' \
        'Voting power:     2.5' \
        'Delegation count: 3' \
        '' \
        'Delegator list:' \
        '' \
        'Wallet:           alice' \
        'Stake address:    stake1fixtureone' \
        'Reward address:   addr1reward-one' \
        'Reward payable:   true' \
        'Raw power:        1.25' \
        '' \
        'Stake address:    stake1fixturetwo' \
        'Reward address:   addr1reward-two' \
        'Reward payable:   false' \
        'Raw power:        0.5' \
        '' \
        'Stake address:    stake1fixturethree' \
        'ERROR: failure during Catalyst delegation query!' \
        >> "${output_file}"
      ;;
    public-delegation-invalid-json|public-delegation-oversized|\
      public-delegation-unsafe-address|public-delegation-unbounded-power|\
      public-ccli-failure|public-unsafe-stake-address)
      printf '%s\n' \
        'Select wallet or enter vote public key?' \
        '' \
        'Status:           registered' \
        'Last updated:     2024-01-02 03:04:05 UTC' \
        'Is Finalized:     true' \
        'Voting power:     1.25' \
        'Delegation count: 1' \
        '' \
        'Delegator list:' \
        '' \
        >> "${output_file}"
      case "${scenario}" in
        public-delegation-invalid-json|public-delegation-unsafe-address|\
          public-delegation-unbounded-power)
          printf '%s\n' \
            'Stake address:    stake1fixtureone' \
            'ERROR: Catalyst delegation service returned an invalid response!' \
            >> "${output_file}"
          ;;
        public-delegation-oversized)
          printf '%s\n' \
            'Stake address:    stake1fixtureone' \
            'ERROR: Catalyst delegation response exceeded the 65536-byte safety limit!' \
            >> "${output_file}"
          ;;
        public-ccli-failure|public-unsafe-stake-address)
          printf '%s\n' \
            'ERROR: failure during Catalyst stake address construction!' \
            >> "${output_file}"
          ;;
      esac
      ;;
    *) fail "unknown expected-stdout scenario: ${scenario}" ;;
  esac
}

write_expected_stderr() {
  local scenario="$1"
  local output_file="$2"

  : > "${output_file}"
  if [[ "${scenario}" == "unsafe-api-config" ]]; then
    printf '%s\n' \
      'CNTools Catalyst verification action failed validation.' \
      > "${output_file}"
  fi
}

append_runtime_events() {
  local mode="$1"
  local output_file="$2"

  case "${mode}" in
    LOCAL)
      printf '%s\n' \
        'runtime:getNodeMetrics' \
        'runtime:getPriceInfo' \
        'runtime:updateProtocolParams' \
        >> "${output_file}"
      ;;
    LIGHT)
      printf '%s\n' \
        'runtime:getPriceInfo' \
        'runtime:updateProtocolParams' \
        >> "${output_file}"
      ;;
    OFFLINE) ;;
    *) fail "unknown runtime mode: ${mode}" ;;
  esac
}

write_expected_events() {
  local scenario="$1"
  local mode="$2"
  local input_choice="$3"
  local select_status="$4"
  local public_input="$5"
  local output_file="$6"

  : > "${output_file}"
  append_runtime_events "${mode}" "${output_file}"
  printf '%s\n' \
    'menu:main:v' \
    'menu:vote:c' \
    'menu:catalyst:v' \
    'action:compatibility-dispatch:vote.catalyst.verify' \
    >> "${output_file}"
  case "${scenario}" in
    offline-refusal|light-nonmainnet-refusal|unsafe-api-config) ;;
    *)
      printf 'menu:verify:%s\n' "${input_choice}" >> "${output_file}"
      if [[ "${input_choice}" == "w" ]]; then
        printf 'action:selectWallet:none:catalyst.vkey:%s\n' \
          "${select_status}" >> "${output_file}"
      else
        printf 'action:answer:vote_key_hex:%s\n' "${public_input}" \
          >> "${output_file}"
      fi
      ;;
  esac
  if [[ "${scenario}" == "wallet-selection-cancel" ]]; then
    printf 'action:return-without-wait\n' >> "${output_file}"
  else
    printf 'action:waitToProceed\n' >> "${output_file}"
  fi
  printf 'menu:catalyst:h\n' >> "${output_file}"
  append_runtime_events "${mode}" "${output_file}"
  printf '%s\n' \
    'menu:main:q' \
    'exit:0:CNTools closed!' \
    >> "${output_file}"
}

write_curl_vector() {
  local output_file="$1"
  local url="$2"
  local limit="$3"

  printf '%b\n' \
    "curl\t--disable\t--silent\t--location\t--max-redirs\t3\t--proto\t=https\t--proto-redir\t=https\t--max-time\t20\t--fail\t--max-filesize\t${limit}\t--header\tAccept: application/json\t--output\t<private-response>\t--url\t${url}" \
    >> "${output_file}"
}

write_expected_vectors() {
  local scenario="$1"
  local output_file="$2"
  local voter_key="${VOTE_KEY_HEX}"
  local delegator=""

  : > "${output_file}"
  case "${scenario}" in
    wallet-success-mixed-delegators)
      write_curl_vector "${output_file}" \
        "${CATALYST_API_FIXTURE}/registration/voter/0x${voter_key}?with_delegators=true" \
        262144
      for delegator in \
          "${DELEGATOR_ONE}" "${DELEGATOR_TWO}" "${DELEGATOR_THREE}"; do
        printf 'cardano-cli\tlatest\tstake-address\tbuild\t--stake-verification-key\t%s\t--mainnet\n' \
          "${delegator#0x}" >> "${output_file}"
        write_curl_vector "${output_file}" \
          "${CATALYST_API_FIXTURE}/registration/delegations/${delegator}" \
          65536
      done
      ;;
    public-voter-transport-failure|public-safe-not-found|\
      public-voter-oversized|public-voter-curl-size-status|\
      public-voter-invalid-json|public-voter-unsafe-error|\
      public-voter-invalid-timestamp|public-voter-duplicate-delegators|\
      public-voter-too-many-delegators|public-voter-count-mismatch|\
      public-voter-invalid-delegator-key|public-voter-unbounded-power)
      write_curl_vector "${output_file}" \
        "${CATALYST_API_FIXTURE}/registration/voter/0x${VOTE_KEY_HEX}?with_delegators=true" \
        262144
      ;;
    public-delegation-invalid-json|public-delegation-oversized|\
      public-delegation-unsafe-address|public-delegation-unbounded-power|\
      public-ccli-failure|public-unsafe-stake-address)
      write_curl_vector "${output_file}" \
        "${CATALYST_API_FIXTURE}/registration/voter/0x${VOTE_KEY_HEX}?with_delegators=true" \
        262144
      printf 'cardano-cli\tlatest\tstake-address\tbuild\t--stake-verification-key\t%s\t--mainnet\n' \
        "${DELEGATOR_ONE#0x}" >> "${output_file}"
      case "${scenario}" in
        public-delegation-invalid-json|public-delegation-oversized|\
          public-delegation-unsafe-address|public-delegation-unbounded-power)
          write_curl_vector "${output_file}" \
            "${CATALYST_API_FIXTURE}/registration/delegations/${DELEGATOR_ONE}" \
            65536
          ;;
      esac
      ;;
    offline-refusal|light-nonmainnet-refusal|public-short-key|\
      public-nonhex64|wallet-selection-failed|wallet-selection-cancel|\
      wallet-malformed-json|wallet-symlink-key|wallet-symlink-directory|\
      wallet-oversized-key|wallet-unsafe-name|unsafe-api-config) ;;
    *) fail "unknown expected-vector scenario: ${scenario}" ;;
  esac
}

extract_action_output() {
  local full_output="$1"
  local action_output="$2"
  local begin_count=0 end_count=0

  begin_count="$(grep -c '^__CNTOOLS_CATALYST_VERIFY_BEGIN__$' \
    "${full_output}" || true)"
  end_count="$(grep -c '^__CNTOOLS_CATALYST_VERIFY_END__$' \
    "${full_output}" || true)"
  [[ "${begin_count}" == "1" && "${end_count}" == "1" ]] ||
    fail 'action output markers were missing or duplicated'
  awk '
    $0 == "__CNTOOLS_CATALYST_VERIFY_BEGIN__" { capture = 1; next }
    $0 == "__CNTOOLS_CATALYST_VERIFY_END__" { capture = 0; exit }
    capture { print }
  ' "${full_output}" > "${action_output}"
}

# Source the public controller and the production compatibility framework.
# Public cases substitute only installed-generation authority; both public and
# direct cases still run the authenticated action through the real dispatcher.
# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
PRODUCTION_COMPATIBILITY_BRIDGE_DEFINITION="$(
  declare -f cntools_compatibility_dispatch_action
)" || fail 'could not preserve the production compatibility bridge'
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"

write_catalyst_context() {
  local target="$1"
  local mode="$2"
  local node_home="$3"
  local network="$4"

  "${REAL_JQ}" -nS --arg mode "${mode,,}" \
    --arg node_home "${node_home}" --arg network "${network}" '
      {
        advanced: true,
        apiVersion: 1,
        capabilities: ["forging", "local-cli", "metrics", "n2c"],
        features: ["advanced"],
        generationVersion: "13.5.7",
        mode: $mode,
        nodeHome: $node_home,
        nodeImplementation: "cnode",
        nodeNetwork: $network,
        schemaVersion: 1
      }
    ' > "${target}"
  chmod 0400 "${target}"
}

cntools_compatibility_dispatch_action() (
  local action_id="${1:-}"
  local private_root="" context_file="" result_file="" status=0
  local snapshot_directory="" tmp_mode="" network="preview"

  [[ "${action_id}" == "vote.catalyst.verify" && $# -eq 1 ]] || return 70
  printf 'action:compatibility-dispatch:%s\n' "${action_id}" \
    >> "${EVENT_LOG:?}"
  [[ "${NWMAGIC}" == "764824073" ]] && network="mainnet"
  umask 077
  tmp_mode="$(file_mode "${TMP_DIR}")" || return 70
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/catalyst-verify-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${TMP_DIR}" "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  snapshot_directory="${private_root}/action"
  mkdir -- "${snapshot_directory}" || return 70
  cp -- "${ACTION_DIRECTORY}/module.json" \
    "${snapshot_directory}/module.json" || return 70
  cp -- "${ACTION_DIRECTORY}/action.sh" \
    "${snapshot_directory}/action.sh" || return 70
  chmod 0700 "${snapshot_directory}" || return 70
  chmod 0400 "${snapshot_directory}/module.json" \
    "${snapshot_directory}/action.sh" || return 70
  write_catalyst_context "${context_file}" "${CNTOOLS_MODE}" \
    "${NODE_HOME}" "${network}"
  export CNTOOLS_CATALYST_EXPECTED_RESPONSE_PARENT="${private_root}"
  if cntools_dispatcher_run_action "${snapshot_directory}" \
      "${context_file}" "${result_file}"; then
    status=0
  else
    status=$?
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || status=70
  rm -f -- "${result_file}" "${context_file}" \
    "${snapshot_directory}/module.json" "${snapshot_directory}/action.sh"
  rmdir -- "${snapshot_directory}" || status=70
  rmdir -- "${private_root}" || status=70
  chmod "${tmp_mode}" "${TMP_DIR}" || status=70
  return "${status}"
)

# Output-only historical println semantics. ACTION/LOG records are intentionally
# omitted because exact executed argv are captured at the fake process boundary.
println() {
  local log_level="${1:-}"
  shift || true
  case "${log_level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@" ;;
    *) printf '%b\n' "${log_level}" "$@" ;;
  esac
}

clear() {
  if [[ "${CAPTURE_ACTIVE:-N}" == "Y" ]]; then
    if [[ "${ACTION_CLEAR_PENDING:-N}" == "Y" ]]; then
      ACTION_CLEAR_PENDING="N"
    else
      printf 'action:return-without-wait\n' >> "${EVENT_LOG:?}"
      printf '__CNTOOLS_CATALYST_VERIFY_END__\n'
      CAPTURE_ACTIVE="N"
    fi
  fi
}

getEpoch() { printf '0\n'; }
timeUntilNextEpoch() { printf '0\n'; }
timeLeft() { printf '00:00:00'; }
slotInterval() { printf '20\n'; }
getSlotTipRef() { printf '100\n'; }

formatLovelace() {
  case "${1:-}" in
    2500000) printf '2.5' ;;
    1250000) printf '1.25' ;;
    500000) printf '0.5' ;;
    *) fail "unexpected lovelace value: ${1:-<empty>}" ;;
  esac
}

getNodeMetrics() {
  printf 'runtime:getNodeMetrics\n' >> "${EVENT_LOG:?}"
  slotnum=100
}

getPriceInfo() {
  printf 'runtime:getPriceInfo\n' >> "${EVENT_LOG:?}"
  price_now=""
}

updateProtocolParams() {
  printf 'runtime:updateProtocolParams\n' >> "${EVENT_LOG:?}"
}

selectWallet() {
  printf 'action:selectWallet:%s:%s:%s\n' \
    "${1:-}" "${2:-}" "${SELECT_WALLET_STATUS:?}" >> "${EVENT_LOG:?}"
  if [[ "${CNTOOLS_CATALYST_SCENARIO:-}" == "wallet-unsafe-name" ]]; then
    wallet_name="../escape"
  else
    wallet_name="registered"
  fi
  if [[ "${SELECT_WALLET_STATUS}" == "2" &&
        "${CAPTURE_ACTIVE:-N}" == "Y" ]]; then
    printf 'action:return-without-wait\n' >> "${EVENT_LOG:?}"
    printf '__CNTOOLS_CATALYST_VERIFY_END__\n'
    CAPTURE_ACTIVE="N"
  fi
  return "${SELECT_WALLET_STATUS}"
}

getAnswerAnyCust() {
  local variable_name="${1:-}"
  shift || true

  [[ "${variable_name}" == "vote_key_hex" && "$*" == "Enter public key" ]] ||
    fail "unexpected Catalyst input request: ${variable_name}:$*"
  printf -v "${variable_name}" '%s' "${PUBLIC_KEY_INPUT}"
  printf 'action:answer:%s:%s\n' "${variable_name}" "${PUBLIC_KEY_INPUT}" \
    >> "${EVENT_LOG:?}"
}

select_opt() {
  local cursor="${CHOICE_CURSOR:-0}" choice=""
  local menu="" option="" index=0

  if [[ -n "${CHOICE_CURSOR_FILE:-}" ]]; then
    IFS= read -r cursor < "${CHOICE_CURSOR_FILE}" ||
      fail 'could not read the shared menu cursor'
  fi
  choice="${CHOICES[cursor]:-}"

  case "${1:-}" in
    '[w] Wallet') menu="main" ;;
    '[g] Governance') menu="vote" ;;
    '[r] Registration') menu="catalyst" ;;
    '[w] Wallet'*) menu="verify" ;;
    *) fail "unexpected legacy menu: ${1:-<empty>}" ;;
  esac
  # The main and verify menus share the same first label. The second label
  # distinguishes public-key selection from the root Funds entry.
  if [[ "${1:-}" == '[w] Wallet' && "${2:-}" == '[p] Vote public key' ]]; then
    menu="verify"
  fi
  [[ -n "${choice}" ]] || fail "legacy menu ${menu} exhausted scripted choices"
  CHOICE_CURSOR=$((cursor + 1))
  if [[ -n "${CHOICE_CURSOR_FILE:-}" ]]; then
    printf '%s\n' "${CHOICE_CURSOR}" > "${CHOICE_CURSOR_FILE}"
  fi
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  if [[ "${menu}:${choice}" == "catalyst:h" &&
        "${CAPTURE_ACTIVE:-N}" == "Y" ]]; then
    CAPTURE_ACTIVE="N"
    ACTION_CLEAR_PENDING="N"
  fi
  index=0
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == "catalyst:v" ]]; then
        CAPTURE_ACTIVE="Y"
        ACTION_CLEAR_PENDING="Y"
        printf '__CNTOOLS_CATALYST_VERIFY_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was absent from legacy menu ${menu}"
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == "Y" ]]; then
    printf '__CNTOOLS_CATALYST_VERIFY_END__\n'
    CAPTURE_ACTIVE="N"
  fi
  return 0
}

myExit() {
  local status="${1:-0}"
  local message="${2:-}"
  local final_cursor="${CHOICE_CURSOR:-0}"

  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  if [[ -n "${CHOICE_CURSOR_FILE:-}" ]]; then
    IFS= read -r final_cursor < "${CHOICE_CURSOR_FILE}" ||
      fail 'could not read the final shared menu cursor'
  fi
  [[ "${final_cursor}" == "${#CHOICES[@]}" ]] ||
    fail 'legacy traversal did not consume every scripted menu choice'
  exit "${status}"
}

configure_case() {
  local scenario="$1"

  CASE_MODE="LIGHT"
  CASE_NWMAGIC="764824073"
  CASE_INPUT_CHOICE="p"
  CASE_SELECT_STATUS=0
  CASE_PUBLIC_INPUT="${VOTE_KEY_HEX}"
  CASE_API="${CATALYST_API_FIXTURE}"
  case "${scenario}" in
    offline-refusal) CASE_MODE="OFFLINE" ;;
    light-nonmainnet-refusal) CASE_NWMAGIC="1" ;;
    public-short-key) CASE_PUBLIC_INPUT="abcd" ;;
    public-nonhex64) CASE_PUBLIC_INPUT="${NON_HEX_KEY}" ;;
    wallet-selection-failed)
      CASE_MODE="LOCAL"; CASE_INPUT_CHOICE="w"; CASE_SELECT_STATUS=1
      ;;
    wallet-selection-cancel)
      CASE_MODE="LOCAL"; CASE_INPUT_CHOICE="w"; CASE_SELECT_STATUS=2
      ;;
    wallet-success-mixed-delegators)
      CASE_MODE="LOCAL"; CASE_INPUT_CHOICE="w"
      ;;
    wallet-malformed-json|wallet-symlink-key|wallet-symlink-directory|\
      wallet-oversized-key|wallet-unsafe-name)
      CASE_INPUT_CHOICE="w"
      ;;
    unsafe-api-config)
      CASE_API='https://catalyst.example.test/api?unsafe=1'
      ;;
    public-voter-transport-failure|public-safe-not-found|\
      public-voter-oversized|public-voter-curl-size-status|\
      public-voter-invalid-json|public-voter-unsafe-error|\
      public-voter-invalid-timestamp|public-voter-duplicate-delegators|\
      public-voter-too-many-delegators|public-voter-count-mismatch|\
      public-voter-invalid-delegator-key|public-voter-unbounded-power|\
      public-delegation-invalid-json|public-delegation-oversized|\
      public-delegation-unsafe-address|public-delegation-unbounded-power|\
      public-ccli-failure|\
      public-unsafe-stake-address)
      ;;
    *) fail "unknown run scenario: ${scenario}" ;;
  esac
}

run_public_case() {
  local scenario="$1"
  local case_root="${TEST_ROOT}/public-cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local vector_log="${capture_root}/vectors"
  local expected_vectors="${capture_root}/expected.vectors"
  local blocked_log="${capture_root}/blocked-network"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local choice_cursor_file="${capture_root}/choice.cursor"
  local mode="" nwmagic="" input_choice="" select_status=0
  local public_input="" catalyst_api="" status=0

  configure_case "${scenario}"
  mode="${CASE_MODE}"
  nwmagic="${CASE_NWMAGIC}"
  input_choice="${CASE_INPUT_CHOICE}"
  select_status="${CASE_SELECT_STATUS}"
  public_input="${CASE_PUBLIC_INPUT}"
  catalyst_api="${CASE_API}"

  mkdir -p -- \
    "${runtime_root}/tmp" \
    "${runtime_root}/wallet" \
    "${runtime_root}/pool" \
    "${runtime_root}/home" \
    "${capture_root}"
  if [[ "${input_choice}" == "w" ]]; then
    prepare_wallet_fixture "${runtime_root}/wallet" "${scenario}"
  fi
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot ${scenario} before traversal"
  : > "${event_log}"
  : > "${vector_log}"
  : > "${blocked_log}"
  printf '0\n' > "${choice_cursor_file}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C
    export TZ=UTC
    export CNTOOLS_CATALYST_SCENARIO="${scenario}"
    export CNTOOLS_CATALYST_REAL_JQ="${REAL_JQ}"
    export CNTOOLS_CATALYST_REAL_HEAD="${REAL_HEAD}"
    export CNTOOLS_CATALYST_REAL_TR="${REAL_TR}"
    export CNTOOLS_CATALYST_REAL_STAT="${REAL_STAT}"
    export CNTOOLS_CATALYST_VECTOR_LOG="${vector_log}"
    export CNTOOLS_CATALYST_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_CATALYST_DELEGATOR_ONE="${DELEGATOR_ONE}"
    export CNTOOLS_CATALYST_DELEGATOR_TWO="${DELEGATOR_TWO}"
    export CNTOOLS_CATALYST_DELEGATOR_THREE="${DELEGATOR_THREE}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    WALLET_CATALYST_VK_FILENAME="catalyst.vkey"
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION="characterized"
    NETWORK_NAME=$([[ "${nwmagic}" == "764824073" ]] && \
      printf 'Mainnet' || printf 'Preview')
    NWMAGIC="${nwmagic}"
    NETWORK_IDENTIFIER="--mainnet"
    CATALYST_API="${catalyst_api}"
    CURL_TIMEOUT=20
    CCLI="cardano-cli"
    ADVANCED_MODE="false"
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    price_now=""
    slotnum=100
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_ACTIVE="N"
    ACTION_CLEAR_PENDING="N"
    SELECT_WALLET_STATUS="${select_status}"
    PUBLIC_KEY_INPUT="${public_input}"
    CHOICE_CURSOR_FILE="${choice_cursor_file}"
    if [[ "${scenario}" == "offline-refusal" ||
          "${scenario}" == "light-nonmainnet-refusal" ||
          "${scenario}" == "unsafe-api-config" ]]; then
      CHOICES=(v c v h q)
    else
      CHOICES=(v c v "${input_choice}" h q)
    fi
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "0" ]] ||
    fail "public ${scenario} traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_stdout}"
  write_expected_stdout "${scenario}" "${expected_stdout}"
  write_expected_stderr "${scenario}" "${expected_stderr}"
  write_expected_events "${scenario}" "${mode}" "${input_choice}" \
    "${select_status}" "${public_input}" "${expected_events}"
  write_expected_vectors "${scenario}" "${expected_vectors}"
  assert_files_equal "${action_stdout}" "${expected_stdout}" \
    "public ${scenario} action stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "public ${scenario} action stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "public ${scenario} navigation and wait events"
  assert_files_equal "${vector_log}" "${expected_vectors}" \
    "public ${scenario} process vectors"
  [[ ! -s "${blocked_log}" ]] ||
    fail "public ${scenario} attempted a blocked command: $(< "${blocked_log}")"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot public ${scenario} after traversal"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "public ${scenario} persistent tree"
}

write_expected_direct_events() {
  local scenario="$1"
  local input_choice="$2"
  local select_status="$3"
  local public_input="$4"
  local output_file="$5"

  : > "${output_file}"
  case "${scenario}" in
    offline-refusal|light-nonmainnet-refusal|unsafe-api-config) ;;
    *)
      printf 'menu:verify:%s\n' "${input_choice}" >> "${output_file}"
      if [[ "${input_choice}" == "w" ]]; then
        printf 'action:selectWallet:none:catalyst.vkey:%s\n' \
          "${select_status}" >> "${output_file}"
      else
        printf 'action:answer:vote_key_hex:%s\n' "${public_input}" \
          >> "${output_file}"
      fi
      ;;
  esac
  case "${scenario}" in
    wallet-selection-cancel|unsafe-api-config) ;;
    *) printf 'action:waitToProceed\n' >> "${output_file}" ;;
  esac
}

run_direct_case() {
  local scenario="$1"
  local case_root="${TEST_ROOT}/direct-cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local capture_root="${case_root}/capture"
  local stdout_file="${capture_root}/stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local vector_log="${capture_root}/vectors"
  local expected_vectors="${capture_root}/expected.vectors"
  local blocked_log="${capture_root}/blocked-network"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local choice_cursor_file="${capture_root}/choice.cursor"
  local mode="" nwmagic="" network="mainnet" input_choice=""
  local select_status=0 public_input="" catalyst_api="" status=0
  local expected_status=0

  configure_case "${scenario}"
  mode="${CASE_MODE}"
  nwmagic="${CASE_NWMAGIC}"
  input_choice="${CASE_INPUT_CHOICE}"
  select_status="${CASE_SELECT_STATUS}"
  public_input="${CASE_PUBLIC_INPUT}"
  catalyst_api="${CASE_API}"
  [[ "${nwmagic}" == "764824073" ]] || network="preview"
  [[ "${scenario}" != "unsafe-api-config" ]] || expected_status=70

  mkdir -p -- \
    "${runtime_root}/tmp" \
    "${runtime_root}/wallet" \
    "${runtime_root}/pool" \
    "${runtime_root}/home" \
    "${capture_root}"
  if [[ "${input_choice}" == "w" ]]; then
    prepare_wallet_fixture "${runtime_root}/wallet" "${scenario}"
  fi
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot direct ${scenario} before dispatch"
  : > "${event_log}"
  : > "${vector_log}"
  : > "${blocked_log}"
  printf '0\n' > "${choice_cursor_file}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C
    export TZ=UTC
    export CNTOOLS_CATALYST_SCENARIO="${scenario}"
    export CNTOOLS_CATALYST_REAL_JQ="${REAL_JQ}"
    export CNTOOLS_CATALYST_REAL_HEAD="${REAL_HEAD}"
    export CNTOOLS_CATALYST_REAL_TR="${REAL_TR}"
    export CNTOOLS_CATALYST_REAL_STAT="${REAL_STAT}"
    export CNTOOLS_CATALYST_VECTOR_LOG="${vector_log}"
    export CNTOOLS_CATALYST_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_CATALYST_DELEGATOR_ONE="${DELEGATOR_ONE}"
    export CNTOOLS_CATALYST_DELEGATOR_TWO="${DELEGATOR_TWO}"
    export CNTOOLS_CATALYST_DELEGATOR_THREE="${DELEGATOR_THREE}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    WALLET_CATALYST_VK_FILENAME="catalyst.vkey"
    CNTOOLS_MODE="${mode}"
    NWMAGIC="${nwmagic}"
    CATALYST_API="${catalyst_api}"
    CURL_TIMEOUT=20
    CCLI="cardano-cli"
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_ACTIVE="N"
    ACTION_CLEAR_PENDING="N"
    SELECT_WALLET_STATUS="${select_status}"
    PUBLIC_KEY_INPUT="${public_input}"
    CHOICES=("${input_choice}")
    CHOICE_CURSOR=0
    CHOICE_CURSOR_FILE="${choice_cursor_file}"
    private_root="$(mktemp -d \
      "${runtime_root}/tmp/catalyst-direct.XXXXXXXX")" || exit 98
    chmod 0700 "${runtime_root}/tmp" "${private_root}" || exit 98
    context_file="${private_root}/context.json"
    result_file="${private_root}/result.json"
    write_catalyst_context "${context_file}" "${mode}" \
      "${runtime_root}/home" "${network}"
    export CNTOOLS_CATALYST_EXPECTED_RESPONSE_PARENT="${private_root}"
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"
    action_status=$?
    [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || action_status=70
    rm -f -- "${result_file}" "${context_file}"
    rmdir -- "${private_root}" || action_status=70
    chmod 0755 "${runtime_root}/tmp" || action_status=70
    exit "${action_status}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "direct ${scenario} returned ${status}, expected ${expected_status}"

  write_expected_stdout "${scenario}" "${expected_stdout}"
  write_expected_stderr "${scenario}" "${expected_stderr}"
  write_expected_direct_events "${scenario}" "${input_choice}" \
    "${select_status}" "${public_input}" "${expected_events}"
  write_expected_vectors "${scenario}" "${expected_vectors}"
  assert_files_equal "${stdout_file}" "${expected_stdout}" \
    "direct ${scenario} action stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "direct ${scenario} action stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "direct ${scenario} wait events"
  assert_files_equal "${vector_log}" "${expected_vectors}" \
    "direct ${scenario} process vectors"
  [[ ! -s "${blocked_log}" ]] ||
    fail "direct ${scenario} attempted a blocked command: $(< "${blocked_log}")"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot direct ${scenario} after dispatch"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "direct ${scenario} persistent tree"
}

write_fake_commands
PATH="${FAKE_BIN}:${BASE_PATH}"
export PATH CNTOOLS_CATALYST_REAL_JQ="${REAL_JQ}"

CATALYST_CASES=(
  offline-refusal
  light-nonmainnet-refusal
  public-short-key
  public-nonhex64
  wallet-selection-failed
  wallet-selection-cancel
  wallet-malformed-json
  wallet-symlink-key
  wallet-symlink-directory
  wallet-oversized-key
  wallet-unsafe-name
  wallet-success-mixed-delegators
  public-safe-not-found
  public-voter-transport-failure
  public-voter-oversized
  public-voter-curl-size-status
  public-voter-invalid-json
  public-voter-unsafe-error
  public-voter-invalid-timestamp
  public-voter-duplicate-delegators
  public-voter-too-many-delegators
  public-voter-count-mismatch
  public-voter-invalid-delegator-key
  public-voter-unbounded-power
  public-delegation-invalid-json
  public-delegation-oversized
  public-delegation-unsafe-address
  public-delegation-unbounded-power
  public-ccli-failure
  public-unsafe-stake-address
  unsafe-api-config
)
for catalyst_case in "${CATALYST_CASES[@]}"; do
  run_public_case "${catalyst_case}"
  run_direct_case "${catalyst_case}"
done

# Wrong arity is a silent action contract failure, distinct from an internal
# validation failure after a well-formed two-path invocation.
arity_root="${TEST_ROOT}/wrong-arity"
mkdir -p -- "${arity_root}/private" "${arity_root}/node"
chmod 0700 "${arity_root}/private"
write_catalyst_context "${arity_root}/private/context.json" LIGHT \
  "${arity_root}/node" mainnet
if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
    "${arity_root}/private/context.json" \
    "${arity_root}/private/result.json" unexpected \
    > "${arity_root}/stdout" 2> "${arity_root}/stderr"; then
  arity_status=0
else
  arity_status=$?
fi
[[ "${arity_status}" == "64" ]] ||
  fail "wrong-arity dispatch returned ${arity_status}, expected 64"
[[ ! -s "${arity_root}/stdout" && ! -s "${arity_root}/stderr" ]] ||
  fail 'wrong-arity dispatch was not stream-silent'
[[ ! -e "${arity_root}/private/result.json" &&
   ! -L "${arity_root}/private/result.json" ]] ||
  fail 'wrong-arity dispatch unexpectedly produced a result'

# Guard the extraction boundary: exactly one public generic call remains, the
# complete implementation lives in the authenticated action, and offline mode
# reaches the action so it can preserve the characterized refusal and wait.
[[ "$(grep -c '^[[:space:]]*catalyst_verify)' "${CNTOOLS_SCRIPT}" || true)" == "1" ]] ||
  fail 'legacy Catalyst verification arm is missing or duplicated'
legacy_arm="${TEST_ROOT}/legacy-catalyst-verify.arm"
awk '
  /^[[:space:]]*catalyst_verify\)/ { capture = 1 }
  capture { print }
  capture && /^[[:space:]]*;;[[:space:]]*#+/ { exit }
' "${CNTOOLS_SCRIPT}" > "${legacy_arm}"
[[ "$(grep -Fc 'cntools_compatibility_dispatch_action vote.catalyst.verify' \
      "${legacy_arm}" || true)" == "1" ]] ||
  fail 'legacy Catalyst verification arm does not contain exactly one generic call'
if grep -Eq 'curl|registration/voter|selectWallet|getAnswerAnyCust|date -d' \
    "${legacy_arm}"; then
  fail 'legacy Catalyst verification arm retains extracted implementation bytes'
fi
for required_mapping in \
    '0) continue ;;' \
    '20|21) break 2 ;;' \
    '22) myExit ;;' \
    '*) waitToProceed; continue ;;'; do
  grep -Fq "${required_mapping}" "${legacy_arm}" ||
    fail "legacy Catalyst outcome mapping is missing: ${required_mapping}"
done
if grep -Fq 'CNTools action execution is inactive in Stage 3 shadow mode.' \
    "${ACTION_SOURCE}"; then
  fail 'Catalyst verification action remains inert'
fi
"${REAL_JQ}" -e '
  .executionRequirements.modes == ["local", "light", "offline"]
' "${ACTION_DIRECTORY}/module.json" >/dev/null ||
  fail 'Catalyst verification offline execution requirement is not enabled'
grep -Fq 'vote.catalyst.verify)' \
  <(printf '%s\n' "${PRODUCTION_COMPATIBILITY_BRIDGE_DEFINITION}") ||
  fail 'production compatibility bridge no longer admits Catalyst verification'

printf 'CNTools Catalyst verification characterization passed (%s public + %s direct cases)\n' \
  "${#CATALYST_CASES[@]}" "${#CATALYST_CASES[@]}"
