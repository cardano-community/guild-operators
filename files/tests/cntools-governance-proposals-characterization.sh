#!/usr/bin/env bash
# Characterize the public compatibility route and the extracted
# vote.governance.proposals action.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2086,SC2154,SC2206,SC2329

if [[ "${1:-}" == --governance-proposals-direct-fake ]]; then
  fake_command="${2:-}"
  shift 2 || exit 98
  if [[ "${fake_command}" == jq ]]; then
    if [[ "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO:-}" == \
          direct-jq-late-fault && "$*" == *'.ownVotes[]'* ]]; then
      exit 88
    fi
    exec "${CNTOOLS_GOVERNANCE_PROPOSALS_REAL_JQ:?}" "$@"
  fi
  fake_input=""
  if [[ "${fake_command}" == bech32 ]]; then
    IFS= read -r fake_input || true
  fi
  printf '%s' "${fake_command}" >> "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_VECTOR_LOG:?}"
  printf '\t%q' "$@" >> "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_VECTOR_LOG}"
  [[ "${fake_command}" == bech32 ]] &&
    printf '\tstdin=%q' "${fake_input}" >> "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_VECTOR_LOG}"
  printf '\n' >> "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_VECTOR_LOG}"
  case "${fake_command}" in
    bech32)
      fake_prefix="${1:-}"
      case "${fake_prefix}:${fake_input}" in
        :drep1fixture) printf '%s\n' "${CNTOOLS_GOVERNANCE_PROPOSALS_DREP_HASH:?}" ;;
        gov_action:"${CNTOOLS_GOVERNANCE_PROPOSALS_TX_A}00") printf 'gov_action1aaa\n' ;;
        gov_action:"${CNTOOLS_GOVERNANCE_PROPOSALS_TX_B}01") printf 'gov_action1ccc\n' ;;
        gov_action:"${CNTOOLS_GOVERNANCE_PROPOSALS_TX_C}02") printf 'gov_action1ddd\n' ;;
        :gov_action1aaa) printf '%s00\n' "${CNTOOLS_GOVERNANCE_PROPOSALS_TX_A:?}" ;;
        :gov_action1ccc) printf '%s01\n' "${CNTOOLS_GOVERNANCE_PROPOSALS_TX_B:?}" ;;
        :gov_action1ddd) printf '%s02\n' "${CNTOOLS_GOVERNANCE_PROPOSALS_TX_C:?}" ;;
        *) printf 'unsafe raw bech32 failure\n' >&2; exit 96 ;;
      esac
      ;;
    cardano-cli)
      fake_joined="$*"
      case "${fake_joined}" in
        latest\ governance\ drep\ id\ --drep-verification-key-file\ *)
          printf 'drep1fixture\n'
          ;;
        latest\ governance\ committee\ key-hash\ --verification-key-file\ *cc-hot.vkey)
          printf '%s\n' "${CNTOOLS_GOVERNANCE_PROPOSALS_CC_HOT_HASH:?}"
          ;;
        latest\ stake-pool\ id\ --cold-verification-key-file\ *\ --output-format\ hex)
          printf '%s\n' "${CNTOOLS_GOVERNANCE_PROPOSALS_POOL_HASH:?}"
          ;;
        latest\ query\ gov-state\ --testnet-magic\ 42)
          case "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO:?}" in
            direct-local-empty) printf '{"proposals":{}}\n' ;;
            direct-local-malformed) printf '{"proposals":{"unsafe":null}}\n' ;;
            *)
              jq -n --arg tx "${CNTOOLS_GOVERNANCE_PROPOSALS_TX_A:?}" \
                --arg drep "keyHash-${CNTOOLS_GOVERNANCE_PROPOSALS_DREP_HASH:?}" \
                --arg pool "${CNTOOLS_GOVERNANCE_PROPOSALS_POOL_HASH:?}" \
                --arg cc "${CNTOOLS_GOVERNANCE_PROPOSALS_CC_HOT_HASH:?}" \
                --arg url "${CNTOOLS_GOVERNANCE_PROPOSALS_METADATA_URL:?}" \
                --arg hash "${CNTOOLS_GOVERNANCE_PROPOSALS_META_HASH:?}" '
                  {constitution:{anchor:null},proposals:{fixture:{
                    actionId:{txId:$tx,govActionIx:0},proposedIn:45,expiresAfter:60,
                    proposalProcedure:{anchor:{url:$url,dataHash:$hash},
                      govAction:{tag:"NoConfidence",contents:[null,{}]}},
                    dRepVotes:{($drep):"VoteYes"},
                    stakePoolVotes:{($pool):"VoteNo"},
                    committeeVotes:{($cc):"Abstain"}
                  }}}
                '
              ;;
          esac
          ;;
        latest\ query\ committee-state\ --testnet-magic\ 42)
          printf '%s\n' '{"threshold":{"numerator":2,"denominator":3},"committee":{"fixture":{"hotCredsAuthStatus":{"tag":"MemberAuthorized"}}}}'
          ;;
        latest\ query\ drep-stake-distribution\ --all-dreps\ --testnet-magic\ 42)
          if [[ "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO}" == direct-local-zero-power ]]; then
            printf '%s\n' '{"drep-alwaysAbstain":0,"drep-alwaysNoConfidence":0}'
          else
            printf '{"drep-alwaysAbstain":1000000,"drep-alwaysNoConfidence":2000000,"drep-keyHash-%s":7000000}\n' \
              "${CNTOOLS_GOVERNANCE_PROPOSALS_DREP_HASH:?}"
          fi
          ;;
        latest\ query\ drep-state\ --all-dreps\ --testnet-magic\ 42)
          printf '[[{"keyHash":"%s"},{"expiry":100}]]\n' \
            "${CNTOOLS_GOVERNANCE_PROPOSALS_DREP_HASH:?}"
          ;;
        latest\ query\ spo-stake-distribution\ --all-spos\ --testnet-magic\ 42)
          if [[ "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO}" == direct-local-zero-power ]]; then
            printf '%s\n' '{}'
          else
            printf '{"stake1fixture":["%s",10000000,"drep-keyHash-%s"],"stake2fixture":["eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",2000000,"drep-alwaysNoConfidence"]}\n' \
              "${CNTOOLS_GOVERNANCE_PROPOSALS_POOL_HASH:?}" \
              "${CNTOOLS_GOVERNANCE_PROPOSALS_DREP_HASH:?}"
          fi
          ;;
        hash\ anchor-data\ --file-text\ *)
          if [[ "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO}" == direct-detail-hash-mismatch ]]; then
            printf '%064d\n' 0
          else
            printf '%s\n' "${CNTOOLS_GOVERNANCE_PROPOSALS_META_HASH:?}"
          fi
          ;;
        *) printf 'unsafe raw cardano-cli failure: %s\n' "${fake_joined}" >&2; exit 96 ;;
      esac
      ;;
    curl)
      fake_previous=""; fake_output=""; fake_url=""
      for fake_argument in "$@"; do
        [[ "${fake_previous}" == --output ]] && fake_output="${fake_argument}"
        [[ "${fake_previous}" == --url ]] && fake_url="${fake_argument}"
        fake_previous="${fake_argument}"
      done
      [[ -n "${fake_output}" && -n "${fake_url}" ]] || exit 95
      case "${fake_url}" in
        *'proposal_list?select=count()'*)
          case "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO:?}" in
            direct-light-count-error) exit 28 ;;
            direct-light-empty) printf '[{"count":0}]\n' > "${fake_output}" ;;
            direct-light-count-mismatch) printf '[{"count":2}]\n' > "${fake_output}" ;;
            direct-light-pagination) printf '[{"count":3}]\n' > "${fake_output}" ;;
            *) printf '[{"count":1}]\n' > "${fake_output}" ;;
          esac
          ;;
        */committee_info)
          printf '[{"quorum_numerator":2,"quorum_denominator":3}]\n' > "${fake_output}"
          ;;
        *'proposal_list?select=block_time'*)
          case "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO:?}" in
            direct-light-malformed-list) printf '[{"block_time":"bad"}]\n' > "${fake_output}" ;;
            direct-light-oversized-list)
              awk 'BEGIN { printf "[\""; for (i=0;i<1100000;i++) printf "x"; print "\"]" }' > "${fake_output}"
              ;;
            *)
              jq -n \
                --arg txa "${CNTOOLS_GOVERNANCE_PROPOSALS_TX_A:?}" \
                --arg txb "${CNTOOLS_GOVERNANCE_PROPOSALS_TX_B:?}" \
                --arg txc "${CNTOOLS_GOVERNANCE_PROPOSALS_TX_C:?}" \
                --arg url "${CNTOOLS_GOVERNANCE_PROPOSALS_METADATA_URL:?}" '
                  def row($time;$id;$tx;$index;$type): {
                    block_time:$time,proposal_id:$id,proposal_tx_hash:$tx,
                    proposal_index:$index,proposal_type:$type,proposed_epoch:(45-$index),
                    expiration:(61-$index),meta_url:($url+"/"+$id),param_proposal:{}
                  };
                  if env.CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO == "direct-light-pagination"
                  then [row(300;"proposal-a";$txa;0;"ParameterChange"),
                    row(200;"proposal-b";$txb;1;"TreasuryWithdrawals"),
                    row(100;"proposal-c";$txc;2;"NoConfidence")]
                  elif env.CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO == "direct-light-count-mismatch"
                  then [row(300;"proposal-a";$txa;0;"InfoAction")]
                  else [row(300;"proposal-a";$txa;0;"InfoAction")] end
                ' > "${fake_output}"
              ;;
          esac
          ;;
        *proposal_voting_summary*)
          if [[ "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO}" == direct-light-malformed-summary ]]; then
            printf '[{"drep_yes_votes_cast":"bad"}]\n' > "${fake_output}"
          else
            printf '%s\n' '[{"drep_yes_votes_cast":1,"drep_yes_vote_power":6000000,"drep_yes_pct":60,"drep_no_votes_cast":2,"drep_no_vote_power":4000000,"drep_no_pct":40,"pool_yes_votes_cast":3,"pool_yes_vote_power":7000000,"pool_yes_pct":70,"pool_no_votes_cast":1,"pool_no_vote_power":3000000,"pool_no_pct":30,"committee_yes_votes_cast":1,"committee_yes_pct":66.67,"committee_no_votes_cast":1,"committee_no_pct":33.33}]' > "${fake_output}"
          fi
          ;;
        *proposal_votes*)
          if [[ "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO}" == direct-light-malformed-votes ]]; then
            printf '[{"voter_role":"DRep","voter_hex":"../../unsafe","vote":"Yes"}]\n' > "${fake_output}"
          else
            printf '[{"voter_role":"DRep","voter_hex":"%s","vote":"Yes"},{"voter_role":"ConstitutionalCommittee","voter_hex":"%s","vote":"No"},{"voter_role":"SPO","voter_hex":"%s","vote":"Abstain"}]\n' \
              "${CNTOOLS_GOVERNANCE_PROPOSALS_DREP_HASH:?}" \
              "${CNTOOLS_GOVERNANCE_PROPOSALS_CC_HOT_HASH:?}" \
              "${CNTOOLS_GOVERNANCE_PROPOSALS_POOL_HASH:?}" > "${fake_output}"
          fi
          ;;
        *'proposal_list?proposal_tx_hash=eq.'*)
          case "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO:?}" in
            direct-detail-not-found) printf '[]\n' > "${fake_output}" ;;
            direct-detail-unsafe-url)
              printf '[{"expiration":61,"meta_hash":"%s","meta_url":"https://metadata.example.test/\\\\033[31mOWNED","param_proposal":{},"proposal_index":0,"proposal_tx_hash":"%s","proposal_type":"InfoAction","proposed_epoch":45}]\n' \
                "${CNTOOLS_GOVERNANCE_PROPOSALS_META_HASH:?}" \
                "${CNTOOLS_GOVERNANCE_PROPOSALS_TX_A:?}" > "${fake_output}"
              ;;
            *)
              printf '[{"expiration":61,"meta_hash":"%s","meta_url":"%s","param_proposal":{},"proposal_index":0,"proposal_tx_hash":"%s","proposal_type":"InfoAction","proposed_epoch":45}]\n' \
                "${CNTOOLS_GOVERNANCE_PROPOSALS_META_HASH:?}" \
                "${CNTOOLS_GOVERNANCE_PROPOSALS_METADATA_URL:?}" \
                "${CNTOOLS_GOVERNANCE_PROPOSALS_TX_A:?}" > "${fake_output}"
              ;;
          esac
          ;;
        "${CNTOOLS_GOVERNANCE_PROPOSALS_METADATA_URL}"*)
          case "${CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO:?}" in
            direct-detail-malformed-metadata) printf '{ malformed\n' > "${fake_output}" ;;
            direct-detail-oversized-metadata)
              awk 'BEGIN { for (i=0;i<300000;i++) printf "x" }' > "${fake_output}"
              ;;
            *) printf '{"title":"Fixture proposal metadata"}\n' > "${fake_output}" ;;
          esac
          ;;
        *) printf 'unsafe raw curl URL: %s\n' "${fake_url}" >&2; exit 96 ;;
      esac
      ;;
    *) exit 98 ;;
  esac
  exit 0
fi
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools governance-proposals characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
ENV_LIBRARY="${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library"
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f"
GOVERNANCE_QUERY_SOURCE="${LEGACY_ROOT}/030-governance-query.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/vote/governance/proposals/action.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/vote/governance/proposals"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-governance-proposals.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
REAL_JQ="$(command -v jq 2>/dev/null || true)"

KOIOS_FIXTURE='https://koios.example.test/api/v1'
METADATA_FIXTURE='https://metadata.example.test/proposal.json'
DREP_HASH='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
CC_COLD_HASH='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
CC_HOT_HASH='cccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
POOL_HEX='dddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
META_HASH='eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
TX_A='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
TX_B='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
TX_C='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'

cleanup_test() {
  if [[ "${CNTOOLS_GOVERNANCE_PROPOSALS_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools governance-proposals test root preserved: %s\n' \
      "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools governance-proposals characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk base64 basename bc cat cmp find grep jq readlink \
    sed sort stat tail tr wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
if command -v sha256sum >/dev/null 2>&1; then
  HASH_COMMAND=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  HASH_COMMAND=shasum
else
  fail 'sha256sum or shasum is required'
fi

proposal_csv_header() {
  printf '%s\n' 'block_time,ratified_epoch,enacted_epoch,dropped_epoch,expired_epoch,proposal_id,proposal_tx_hash,proposal_index,proposal_type,proposed_epoch,expiration,meta_url,param_proposal'
}

proposal_csv_row() {
  case "$1" in
    a)
      printf '300,,,,,proposal-a,%s,0,ParameterChange,45,61,%s,"{""max_block_size"":1}"\n' \
        "${TX_A}" "${METADATA_FIXTURE}/a"
      ;;
    b)
      printf '200,,,,,proposal-b,%s,1,TreasuryWithdrawals,44,59,%s/b,{}\n' \
        "${TX_B}" "${METADATA_FIXTURE}"
      ;;
    c)
      printf '100,,,,,proposal-c,%s,2,NoConfidence,43,58,%s/c,{}\n' \
        "${TX_C}" "${METADATA_FIXTURE}"
      ;;
    malformed)
      printf 'malformed\n'
      ;;
    oversized)
      printf '300,,,,,proposal-a,%s,0,InfoAction,45,61,https://metadata.example.test/' \
        "${TX_A}"
      awk 'BEGIN { for (i = 0; i < 32768; i++) printf "x" }'
      printf ',{}\n'
      ;;
    *) return 1 ;;
  esac
}

emit_light_proposal_list() {
  proposal_csv_header
  case "${CNTOOLS_GOVERNANCE_PROPOSALS_SCENARIO:?}" in
    light-full-pagination) proposal_csv_row a; proposal_csv_row b; proposal_csv_row c ;;
    light-malformed-api) proposal_csv_row malformed ;;
    light-oversized-api) proposal_csv_row oversized ;;
    *) proposal_csv_row a ;;
  esac
}

emit_summary() {
  printf '%s\n' 'drep_yes_votes_cast,drep_yes_vote_power,drep_yes_pct,drep_no_votes_cast,drep_no_vote_power,drep_no_pct,pool_yes_votes_cast,pool_yes_vote_power,pool_yes_pct,pool_no_votes_cast,pool_no_vote_power,pool_no_pct,committee_yes_votes_cast,committee_yes_pct,committee_no_votes_cast,committee_no_pct'
  case "$1" in
    proposal-a) printf '%s\n' '1,6000000,60.0,2,4000000,40.0,3,7000000,70.0,1,3000000,30.0,1,66.67,1,33.33' ;;
    proposal-b) printf '%s\n' '2,8000000,80.0,1,2000000,20.0,0,0,0.0,4,10000000,100.0,2,100.0,0,0.0' ;;
    proposal-c) printf '%s\n' '4,9000000,90.0,1,1000000,10.0,2,5500000,55.0,2,4500000,45.0,0,0.0,1,100.0' ;;
    *) printf '%s\n' '0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0' ;;
  esac
}

emit_votes() {
  printf '%s\n' 'voter_role,voter_hex,vote'
  case "$1" in
    proposal-a)
      printf 'DRep,%s,Yes\nConstitutionalCommittee,%s,No\nSPO,%s,Abstain\n' \
        "${DREP_HASH}" "${CC_HOT_HASH}" "${POOL_HEX}"
      ;;
    proposal-b)
      printf 'DRep,%s,No\nConstitutionalCommittee,%s,Yes\nSPO,%s,Yes\n' \
        "${DREP_HASH}" "${CC_HOT_HASH}" "${POOL_HEX}"
      ;;
    proposal-c)
      printf 'DRep,%s,Abstain\nConstitutionalCommittee,%s,Abstain\nSPO,%s,No\n' \
        "${DREP_HASH}" "${CC_HOT_HASH}" "${POOL_HEX}"
      ;;
  esac
}

emit_local_gov_state() {
  if [[ "${CNTOOLS_GOVERNANCE_PROPOSALS_SCENARIO:?}" == local-empty ]]; then
    printf '%s\n' '{"proposals":{}}'
    return 0
  fi
  jq -n \
    --arg tx "${TX_A}" --arg drep "keyHash-${DREP_HASH}" \
    --arg pool "${POOL_HEX}" --arg cc "${CC_HOT_HASH}" \
    --arg url "${METADATA_FIXTURE}/local" '
      {
        proposals: {
          fixture: {
            actionId: {txId: $tx, govActionIx: 0},
            proposedIn: 45,
            expiresAfter: 60,
            proposalProcedure: {
              anchor: {url: $url, dataHash: ""},
              govAction: {
                tag: "ParameterChange",
                contents: [null, {maxBlockBodySize: 65536}]
              }
            },
            dRepVotes: {($drep): "VoteYes"},
            stakePoolVotes: {($pool): "VoteNo"},
            committeeVotes: {($cc): "VoteYes"}
          }
        }
      }
    '
}

log_vector() {
  local command_name="$1"
  shift
  printf '%s' "${command_name}" >> "${VECTOR_LOG:?}"
  printf '\t%q' "$@" >> "${VECTOR_LOG}"
  printf '\n' >> "${VECTOR_LOG}"
}

cardano-cli() {
  local joined="$*" output_format=N

  log_vector cardano-cli "$@"
  case "${joined}" in
    latest\ governance\ drep\ id\ --drep-verification-key-file\ *)
      printf 'drep1fixture\n'
      ;;
    latest\ governance\ committee\ key-hash\ --verification-key-file\ *cc-cold.vkey)
      printf '%s\n' "${CC_COLD_HASH}"
      ;;
    latest\ governance\ committee\ key-hash\ --verification-key-file\ *cc-hot.vkey)
      printf '%s\n' "${CC_HOT_HASH}"
      ;;
    latest\ stake-pool\ id\ --cold-verification-key-file\ *)
      [[ "${joined}" == *'--output-format hex'* ]] && output_format=Y
      [[ "${output_format}" == Y ]] && printf '%s\n' "${POOL_HEX}" ||
        printf 'pool1fixture\n'
      ;;
    latest\ query\ gov-state\ *) emit_local_gov_state ;;
    latest\ query\ committee-state\ *)
      printf '%s\n' '{"threshold":{"numerator":2,"denominator":3},"committee":{"fixture":{"hotCredsAuthStatus":{"tag":"MemberAuthorized"}}}}'
      ;;
    latest\ query\ drep-stake-distribution\ --all-dreps\ *)
      printf '{"drep-alwaysAbstain":1000000,"drep-alwaysNoConfidence":2000000,"drep-keyHash-%s":7000000}\n' \
        "${DREP_HASH}"
      ;;
    latest\ query\ drep-state\ --all-dreps\ *)
      printf '[[{"keyHash":"%s"},{"expiry":100}]]\n' "${DREP_HASH}"
      ;;
    latest\ query\ spo-stake-distribution\ --all-spos\ *)
      printf '{"stake1fixture":["%s",10000000,"drep-keyHash-%s"]}\n' \
        "${POOL_HEX}" "${DREP_HASH}"
      ;;
    hash\ anchor-data\ --file-text\ *)
      if [[ "${CNTOOLS_GOVERNANCE_PROPOSALS_SCENARIO}" == detail-hash-mismatch ]]; then
        printf 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\n'
      else
        printf '%s\n' "${META_HASH}"
      fi
      ;;
    *) printf 'unexpected cardano-cli vector: %s\n' "${joined}" >&2; return 96 ;;
  esac
}

bech32() {
  local prefix="${1:-}" input=""

  IFS= read -r input || true
  log_vector bech32 "${prefix}" "${input}"
  case "${prefix}:${input}" in
    :drep1fixture) printf '%s\n' "${DREP_HASH}" ;;
    drep:"22${DREP_HASH}") printf 'drep1fixture129\n' ;;
    cc_cold:"${CC_COLD_HASH}") printf 'cc_cold1fixture\n' ;;
    :cc_cold1fixture) printf '%s\n' "${CC_COLD_HASH}" ;;
    cc_cold:"12${CC_COLD_HASH}") printf 'cc_cold1fixture129\n' ;;
    cc_hot:"${CC_HOT_HASH}") printf 'cc_hot1fixture\n' ;;
    :cc_hot1fixture) printf '%s\n' "${CC_HOT_HASH}" ;;
    cc_hot:"02${CC_HOT_HASH}") printf 'cc_hot1fixture129\n' ;;
    gov_action:"${TX_A}00") printf 'gov_action1aaa\n' ;;
    gov_action:"${TX_B}01") printf 'gov_action1bbb\n' ;;
    gov_action:"${TX_C}02") printf 'gov_action1ccc\n' ;;
    :gov_action1aaa) printf '%s00\n' "${TX_A}" ;;
    gov_action:*) printf 'gov_action1legacy\n' ;;
    *) printf 'unexpected bech32 vector: %s:%s\n' "${prefix}" "${input}" >&2; return 96 ;;
  esac
}

curl() {
  local joined="$*" url="${!#}" output_file="" previous="" argument=""

  log_vector curl "$@"
  for argument in "$@"; do
    [[ "${previous}" == -o ]] && output_file="${argument}"
    previous="${argument}"
  done
  case "${joined}" in
    *'proposal_list?select=count()'*)
      case "${CNTOOLS_GOVERNANCE_PROPOSALS_SCENARIO:?}" in
        light-count-error) printf 'raw count transport failure\n' >&2; return 28 ;;
        light-empty) printf 'count\n0\n' ;;
        *)
          case "${CNTOOLS_GOVERNANCE_PROPOSALS_SCENARIO}" in
            light-full-pagination|detail-*) printf 'count\n3\n' ;;
            *) printf 'count\n1\n' ;;
          esac
          ;;
      esac
      ;;
    *'proposal_list?select=block_time'*)
      [[ "${CNTOOLS_GOVERNANCE_PROPOSALS_SCENARIO}" == light-list-error ]] &&
        return 28
      emit_light_proposal_list
      ;;
    *'proposal_voting_summary?'*)
      case "${joined}" in
        *proposal-a*) emit_summary proposal-a ;;
        *proposal-b*) emit_summary proposal-b ;;
        *proposal-c*) emit_summary proposal-c ;;
        *) emit_summary malformed ;;
      esac
      ;;
    *'proposal_votes?'*)
      case "${joined}" in
        *proposal-a*) emit_votes proposal-a ;;
        *proposal-b*) emit_votes proposal-b ;;
        *proposal-c*) emit_votes proposal-c ;;
        *) printf '%s\n' 'voter_role,voter_hex,vote' ;;
      esac
      ;;
    *'/committee_info'*)
      printf '%s\n' '[{"quorum_numerator":2,"quorum_denominator":3}]'
      ;;
    *'proposal_list?proposal_tx_hash='*)
      case "${CNTOOLS_GOVERNANCE_PROPOSALS_SCENARIO}" in
        detail-not-found) printf '%s\n' '[]' ;;
        detail-invalid-url)
          printf '[{"meta_url":"file:///unsafe","meta_hash":"%s","proposal_type":"InfoAction","fixture":"invalid-url"}]\n' "${META_HASH}"
          ;;
        *)
          printf '[{"meta_url":"%s","meta_hash":"%s","proposal_type":"InfoAction","fixture":"detail"}]\n' \
            "${METADATA_FIXTURE}" "${META_HASH}"
          ;;
      esac
      ;;
    *"${METADATA_FIXTURE}"*)
      [[ -n "${output_file}" ]] || return 97
      case "${CNTOOLS_GOVERNANCE_PROPOSALS_SCENARIO}" in
        detail-malformed-metadata) printf '{ malformed metadata\n' > "${output_file}" ;;
        detail-oversized-metadata)
          awk 'BEGIN { for (i = 0; i < 32768; i++) printf "m" }' > "${output_file}"
          ;;
        *) printf '%s\n' '{"title":"Fixture proposal metadata"}' > "${output_file}" ;;
      esac
      ;;
    *) printf 'unexpected curl vector: %s\n' "${url}" >&2; return 96 ;;
  esac
}

# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=../../scripts/common-helper-scripts/lib/env.library
. "${ENV_LIBRARY}"
# shellcheck source=/dev/null
. "${GOVERNANCE_QUERY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"

write_governance_proposals_fake_commands() {
  local command_name=""

  mkdir -p -- "${FAKE_BIN}"
  for command_name in cardano-cli bech32 curl jq; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'exec "${CNTOOLS_GOVERNANCE_PROPOSALS_TEST_SCRIPT:?}" --governance-proposals-direct-fake "${0##*/}" "$@"' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

# Public cases traverse the shipped menus and exact compatibility call site.
# This adapter substitutes only the installed-generation authority layer, then
# runs the shipped dispatcher and extracted action in private test storage.
cntools_compatibility_dispatch_action() (
  local action_id="${1:-}" direct_scenario="" private_root=""
  local context_file="" result_file="" action_status=0

  [[ "${action_id}" == vote.governance.proposals && $# == 1 ]] || return 70
  case "${CNTOOLS_GOVERNANCE_PROPOSALS_SCENARIO:?}" in
    light-count-error) direct_scenario=direct-light-count-error ;;
    light-empty) direct_scenario=direct-light-empty ;;
    local-empty) direct_scenario=direct-local-empty ;;
    offline-positive) direct_scenario=direct-offline ;;
    light-list-error|light-malformed-api) direct_scenario=direct-light-malformed-list ;;
    light-full-pagination) direct_scenario=direct-light-pagination ;;
    local-full) direct_scenario=direct-local-full ;;
    detail-invalid-input) direct_scenario=direct-detail-invalid-input ;;
    detail-not-found) direct_scenario=direct-detail-not-found ;;
    detail-cip-success) direct_scenario=direct-light-single-detail ;;
    detail-invalid-url) direct_scenario=direct-detail-unsafe-url ;;
    detail-hash-mismatch) direct_scenario=direct-detail-hash-mismatch ;;
    detail-malformed-metadata) direct_scenario=direct-detail-malformed-metadata ;;
    detail-oversized-metadata) direct_scenario=direct-detail-oversized-metadata ;;
    light-oversized-api) direct_scenario=direct-light-oversized-list ;;
    *) return 70 ;;
  esac
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  umask 077
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/governance-proposals-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  write_context "${context_file}" "${CNTOOLS_MODE}" "${NODE_HOME}" || return 70
  export CNTOOLS_GOVERNANCE_PROPOSALS_TEST_SCRIPT="${REPO_ROOT}/files/tests/cntools-governance-proposals-characterization.sh"
  export CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO="${direct_scenario}"
  export CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_VECTOR_LOG="${VECTOR_LOG}"
  export CNTOOLS_GOVERNANCE_PROPOSALS_DREP_HASH="${DREP_HASH}"
  export CNTOOLS_GOVERNANCE_PROPOSALS_CC_HOT_HASH="${CC_HOT_HASH}"
  export CNTOOLS_GOVERNANCE_PROPOSALS_POOL_HASH="${POOL_HEX}"
  export CNTOOLS_GOVERNANCE_PROPOSALS_META_HASH="${META_HASH}"
  export CNTOOLS_GOVERNANCE_PROPOSALS_METADATA_URL="${METADATA_FIXTURE}"
  export CNTOOLS_GOVERNANCE_PROPOSALS_TX_A="${TX_A}"
  export CNTOOLS_GOVERNANCE_PROPOSALS_TX_B="${TX_B}"
  export CNTOOLS_GOVERNANCE_PROPOSALS_TX_C="${TX_C}"
  export CNTOOLS_GOVERNANCE_PROPOSALS_REAL_JQ="${REAL_JQ}"
  unset -f cardano-cli bech32 curl wget git ssh nc
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    action_status=0
  else
    action_status=$?
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || action_status=70
  rm -f -- "${result_file}" "${context_file}" >/dev/null 2>&1 ||
    action_status=70
  rmdir -- "${private_root}" >/dev/null 2>&1 || action_status=70
  return "${action_status}"
)

write_governance_proposals_fake_commands

println() {
  local level="${1:-}"
  shift || true
  case "${level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@" ;;
    *) printf '%b\n' "${level}" "$@" ;;
  esac
}

clear() { printf 'terminal:clear\n' >> "${EVENT_LOG:?}"; }
tput() { printf 'terminal:tput:%s\n' "$*" >> "${EVENT_LOG:?}"; }
getEpoch() { printf '50\n'; }
timeUntilNextEpoch() { printf '100\n'; }
getSlotTipRef() { printf '1000\n'; }
slotInterval() { printf '20\n'; }
timeLeft() { printf '00:01:40'; }
getPriceInfo() { price_now=""; }
getNodeMetrics() { slotnum=1000; }
updateProtocolParams() { :; }

date() {
  case "${1:-}" in
    +%Y%m%d%H%M%S) printf '20260102030405\n' ;;
    *) command date "$@" ;;
  esac
}

waitToProceed() {
  WAIT_COUNT=$((WAIT_COUNT + 1))
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CNTOOLS_GOVERNANCE_PROPOSALS_SCENARIO:-}" == detail-not-found &&
        "${WAIT_COUNT}" -ge 4 ]]; then
    fail 'detail not-found state repeated instead of returning to the page'
  fi
  return 0
}

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}" option="" index=0

  [[ -n "${choice}" ]] || fail 'menu choice queue was exhausted'
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s\n' "${choice}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "menu choice was unavailable: ${choice}"
}

getAnswerAnyCust() {
  local output_variable="${1:-}" answer="${ANSWERS[ANSWER_CURSOR]:-}"

  ANSWER_CURSOR=$((ANSWER_CURSOR + 1))
  printf 'answer:%q\n' "${answer}" >> "${EVENT_LOG:?}"
  printf -v "${output_variable}" '%s' "${answer}"
}

myExit() {
  local status="${1:-0}" message="${2:-}"

  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'menu traversal did not consume every choice'
  exit "${status}"
}

prepare_identity_fixtures() {
  local wallet_root="$1" pool_root="$2"

  mkdir -p -- "${wallet_root}/a-wallet" "${pool_root}/a-pool"
  printf '%s\n' '{"type":"DRepVerificationKey_ed25519"}' \
    > "${wallet_root}/a-wallet/drep.vkey"
  printf '%s\n' '{"type":"ConstitutionalCommitteeColdVerificationKey_ed25519"}' \
    > "${wallet_root}/a-wallet/cc-cold.vkey"
  printf '%s\n' '{"type":"ConstitutionalCommitteeHotVerificationKey_ed25519"}' \
    > "${wallet_root}/a-wallet/cc-hot.vkey"
  printf '%s\n' '{"type":"StakePoolVerificationKey_ed25519"}' \
    > "${pool_root}/a-pool/cold.vkey"
}

case_count() {
  case "$1" in
    light-empty|local-empty) printf '0\n' ;;
    light-full-pagination|detail-*) printf '3\n' ;;
    *) printf '1\n' ;;
  esac
}

case_mode() {
  case "$1" in
    local-*|offline-*) [[ "$1" == offline-* ]] && printf 'OFFLINE\n' || printf 'LOCAL\n' ;;
    *) printf 'LIGHT\n' ;;
  esac
}

case_keys() {
  case "$1" in
    light-full-pagination) printf 'npr' ;;
    detail-invalid-input) printf 'dr' ;;
    detail-*) printf 'dr' ;;
    *) : ;;
  esac
}

prepare_answers() {
  ANSWERS=()
  case "$1" in
    detail-invalid-input) ANSWERS=('not-an-action' '') ;;
    detail-*) ANSWERS=('gov_action1aaa') ;;
  esac
}

assert_mutation_contract() {
  local scenario="$1" runtime_root="$2" before="$3" after="$4"

  : "${runtime_root}"
  assert_files_equal "${after}" "${before}" \
    "${scenario} public compatibility route mutated persistent state"
}

assert_semantics() {
  local scenario="$1" stdout_file="$2" stderr_file="$3"
  local event_log="$4" vector_log="$5"

  [[ ! -s "${stderr_file}" ]] ||
    fail "${scenario} wrote unexpected normalized stderr"
  grep -Fq ' >> VOTE >> GOVERNANCE >> LIST PROPOSALS' "${stdout_file}" ||
    fail "${scenario} did not reach the public proposal action"
  case "${scenario}" in
    light-count-error)
      grep -Fq 'Failed to grab list of proposals!' "${stdout_file}" || fail "${scenario} count failure output changed"
      ;;
    light-empty|local-empty)
      grep -Fq 'No active proposals to vote on!' "${stdout_file}" || fail "${scenario} empty output changed"
      ;;
    offline-positive)
      grep -Fq 'proposal queries are unavailable' "${stdout_file}" ||
        fail "${scenario} offline diagnostic changed"
      ;;
    light-list-error|light-malformed-api|light-oversized-api)
      grep -Fq 'Failed to grab list of proposals!' "${stdout_file}" ||
        fail "${scenario} all-or-nothing failure output changed"
      ;;
    light-full-pagination)
      [[ "$(grep -c 'Action ID     : ' "${stdout_file}")" == 5 ]] || fail 'pagination/cursor rendering count changed'
      grep -Fq 'You voted Yes with DRep wallet a-wallet' "${stdout_file}" || fail 'own DRep vote match changed'
      grep -Fq 'You voted Abstain with pool a-pool' "${stdout_file}" || fail 'own SPO vote match changed'
      grep -Fq 'You voted No with committee wallet a-wallet' "${stdout_file}" || fail 'own committee vote match changed'
      ;;
    local-full)
      grep -Fq "${TX_A}#0" "${stdout_file}" || fail 'LOCAL proposal ID changed'
      grep -Fq 'NoConfidence' "${stdout_file}" || fail 'LOCAL proposal type changed'
      ;;
    detail-invalid-input)
      grep -Fq 'ERROR: invalid action id!' "${stdout_file}" || fail 'detail validation output changed'
      ;;
    detail-not-found)
      [[ "$(grep -c 'ERROR: governance action id not found!' \
        "${stdout_file}")" == 1 ]] ||
        fail 'detail not-found state was not reset'
      ;;
    detail-invalid-url)
      grep -Fq 'WARN: invalid governance action proposal anchor url or content' "${stdout_file}" || fail 'invalid metadata URL warning changed'
      ;;
    detail-hash-mismatch)
      grep -Fq 'WARN: invalid governance action proposal anchor hash' "${stdout_file}" || fail 'metadata hash warning changed'
      ;;
    detail-malformed-metadata|detail-oversized-metadata)
      grep -Fq 'WARN: invalid governance action proposal anchor url or content' \
        "${stdout_file}" || fail "${scenario} bounded metadata rejection changed"
      [[ "$(wc -c < "${stdout_file}")" -lt 32768 ]] ||
        fail "${scenario} reflected an unbounded metadata response"
      ;;
  esac
  [[ "$(grep -c '^menu:' "${event_log}")" == 6 ]] ||
    fail "${scenario} public navigation changed"
  [[ "$(grep -c '^action:compatibility-dispatch$' "${event_log}")" == 1 ]] ||
    fail "${scenario} public compatibility route was not singular"
  grep -Fq 'exit:0:CNTools closed!' "${event_log}" ||
    fail "${scenario} did not return through the public menus"
  if grep -Eq 'OWNED|unsafe raw|\.\./|malformed' \
      "${stdout_file}" "${stderr_file}"; then
    fail "${scenario} reflected unsafe response data"
  fi
  case "$(case_mode "${scenario}")" in
    LIGHT) grep -Fq $'curl\t' "${vector_log}" || fail "${scenario} did not use Koios" ;;
    LOCAL) grep -Fq $'cardano-cli\tlatest\tquery\tgov-state' "${vector_log}" || fail "${scenario} count query vector changed" ;;
    OFFLINE) [[ ! -s "${vector_log}" ]] || fail "${scenario} invoked an offline query" ;;
  esac
}

expected_stream_hash() {
  # Each value freezes stdout, then terminal/wait/navigation events, then
  # normalized external argv, separated by tabs.
  case "$1" in
    light-count-error) printf '%s\n' $'d073b0d93111ed9dd5fadf77c93845586f1b4627e1f223922934f64494e08296\tacc2fc1ba52854cbbcbfd28fadc5ddc2aa1ae97e32eb6c836806a64926135716\t53b7bf8a1f7c9eddbf8025970219ffca83604b9ac1a19962a625d0ade18d1c3e' ;;
    light-empty) printf '%s\n' $'32190156a5dab6d1e7c70832f77334adb593243ee3c3f157b3389433e08d8768\tbe4f7bd08122de6aaff4be3c9970afd604a5dbd31165f08dae7415f43bad0d7a\t53b7bf8a1f7c9eddbf8025970219ffca83604b9ac1a19962a625d0ade18d1c3e' ;;
    local-empty) printf '%s\n' $'3e88433acb24856198f3a7570bdf965f8a831ba9ad02582d6ff5172916f7bae6\tbe4f7bd08122de6aaff4be3c9970afd604a5dbd31165f08dae7415f43bad0d7a\t640b3d347a6fb787a1f6fbd9a827dfa1267672300a8ce858ed75bea080cf3691' ;;
    offline-positive) printf '%s\n' $'bea178ceec610d3c43a7d5a883fa0b9e959157295962371e8fb861524d1bf584\t9d89c52159d7bf152270702306f23056606058c1090deb104087061f191e204b\t640b3d347a6fb787a1f6fbd9a827dfa1267672300a8ce858ed75bea080cf3691' ;;
    light-list-error) printf '%s\n' $'c4d45a9ce56149e97a554780091db71b915f4938c4fe783dacc4fe74e6a38b5c\t9d89c52159d7bf152270702306f23056606058c1090deb104087061f191e204b\t1e42355cd808475cbe95ae2369bb640e8662638696dcfef3db1aab3c3166835c' ;;
    light-full-pagination) printf '%s\n' $'0621e3fdad62cbc58b012c8cebafea5cf1b3dd465b982ea49496da8a9d2685c4\td017266890fb437fb6f1dbac768a58612a44d4ea31742897d86951cafd31f2a8\ta4b289e0ff4b02e1d80e13152848acf5a026bdf3d820aafa85ada18d844ea31a' ;;
    local-full) printf '%s\n' $'33c793f62947fa7b4cff3395ace0d44e209d160a7d9898991ec7219d9403d53c\t4b3d152bb0ef10584600c0dbac98214f1cfddc9c39a6fed230fc466dd65c77c4\t71127e7d30609f99ef718e9515dd2b869b235e327bc2751225b6de57ef4fb12d' ;;
    detail-invalid-input) printf '%s\n' $'6887ea149d205bcfc2fcaaf61d43a5c466d64956874775e3b136f405dcd90dd0\te76a88d92396027980451bcf0439a9cc8c76099082fa192a7d2cedddf82957ba\t1163578641ad13706dd2cc589486d59a8b106df66072e449120d10a51d17e97f' ;;
    detail-not-found) printf '%s\n' $'f1fdfa21b16e0e63ceacc7f70d207cf583dc64591941b293dc536886c7b43cd8\t96469a8392197d2e216eef249231f792177c28edc64f3dcc1f8ed55503b68947\t1f150b334ba33163aa9d7a18795cce4227ca34b31d356d1f99ef9c8c6d55e8f0' ;;
    detail-cip-success) printf '%s\n' $'9934d61ac01d4a2fe52724697bd85db18c43449fe0bf7402a40981d3dc707dab\tae8e1ffcf3964b75e425863a0410374c3d29810990994a2599a34f063b2bcc26\t78fc09c6dfd788829ac638775238bd1bc74140fc7d2e645e51886d079d54f6a2' ;;
    detail-invalid-url) printf '%s\n' $'177af58a0a22457daace868f850612d5024ad3723c4ff55230a0887d67e56954\t21c97b2da3ac7fa0590232cfe71fd690173db70378a0980695e2d9de77b210d1\tbd0c9db3d7d7317fb0ff66a8d3d4ca76fcfee30fa5887ccc1de3854a4ddc43e9' ;;
    detail-hash-mismatch) printf '%s\n' $'38e928fcd8dabb77ed708f8e07d51ef5c81fe7dcaf21d29986b4c6bea2be20bd\t21c97b2da3ac7fa0590232cfe71fd690173db70378a0980695e2d9de77b210d1\t78fc09c6dfd788829ac638775238bd1bc74140fc7d2e645e51886d079d54f6a2' ;;
    detail-malformed-metadata) printf '%s\n' $'dad704439ed007f17b219e25a015328072c00362b6e4f5c479aa96f6e7b81267\tae8e1ffcf3964b75e425863a0410374c3d29810990994a2599a34f063b2bcc26\t78fc09c6dfd788829ac638775238bd1bc74140fc7d2e645e51886d079d54f6a2' ;;
    detail-oversized-metadata) printf '%s\n' $'b6153d1cbb65ac00ebbb8d6d6683e400f592a8c95c945459662e2b22322d7145\tae8e1ffcf3964b75e425863a0410374c3d29810990994a2599a34f063b2bcc26\t78fc09c6dfd788829ac638775238bd1bc74140fc7d2e645e51886d079d54f6a2' ;;
    light-malformed-api) printf '%s\n' $'060fef60a1787a60d1216ad0cbc1e268b1b44f1a100205dc2c70c7a27c5d945a\t34b560acd652de7bbe2263c165e136c85b763caa7f869d387312418e4f9d46a4\t6d8579daa165aab53dcd21c288cc207ebaebaf53c078a7df7356da33c24b51b8' ;;
    light-oversized-api) printf '%s\n' $'c28e602c61f8d1e74e3a4706eac7f4a68510474a7c6786903b67fa9bbf6b7b34\tfa5daad365c7912b6b87933ee359a4eaf15044e365c0160dc6edc33bb69ae817\t80b963562ec10b810c9cd55c3c06e9e6636a0722f544cd979810cf25b24a5d2a' ;;
    *) return 1 ;;
  esac
}

run_case() {
  local scenario="$1" mode="" count="" keys=""
  local case_root="${TEST_ROOT}/cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local capture_root="${case_root}/capture"
  local stdout_file="${capture_root}/stdout"
  local stderr_file="${capture_root}/stderr"
  local event_log="${capture_root}/events"
  local vector_log="${capture_root}/vectors"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local key_file="${capture_root}/keys"
  local status=0 expected_record="" expected_stdout_hash=""
  local expected_event_hash="" expected_vector_hash=""
  local actual_stdout_hash="" actual_event_hash="" actual_vector_hash=""

  mode="$(case_mode "${scenario}")"
  count="$(case_count "${scenario}")"
  keys="$(case_keys "${scenario}")"
  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${runtime_root}/wallet" "${runtime_root}/pool" "${capture_root}"
  prepare_identity_fixtures "${runtime_root}/wallet" "${runtime_root}/pool"
  printf '%s' "${keys}" > "${key_file}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot ${scenario} before traversal"
  : > "${event_log}"; : > "${vector_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C TZ=UTC
    PATH="${FAKE_BIN}:${BASE_PATH}"
    export PATH
    CNTOOLS_GOVERNANCE_PROPOSALS_SCENARIO="${scenario}"
    export CNTOOLS_GOVERNANCE_PROPOSALS_SCENARIO
    VECTOR_LOG="${vector_log}"
    export VECTOR_LOG
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    CCLI=cardano-cli
    NETWORK_IDENTIFIER='--testnet-magic 42'
    NWMAGIC=42
    KOIOS_API=$([[ "${mode}" == LIGHT ]] && printf '%s' "${KOIOS_FIXTURE}" || printf '')
    KOIOS_API_HEADERS=()
    CURL_TIMEOUT=10
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=characterized
    NETWORK_NAME=Preview
    ADVANCED_MODE=false
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    PROT_VERSION=10.1
    PROT_PARAMS='{"dRepVotingThresholds":{"committeeNoConfidence":0.51,"committeeNormal":0.52,"hardForkInitiation":0.53,"motionNoConfidence":0.54,"ppEconomicGroup":0.55,"ppGovGroup":0.56,"ppNetworkGroup":0.57,"ppTechnicalGroup":0.58,"treasuryWithdrawal":0.59,"updateToConstitution":0.60},"poolVotingThresholds":{"committeeNoConfidence":0.61,"committeeNormal":0.62,"hardForkInitiation":0.63,"motionNoConfidence":0.64,"ppSecurityGroup":0.65}}'
    WALLET_GOV_DREP_VK_FILENAME=drep.vkey
    WALLET_GOV_DREP_SK_FILENAME=drep.skey
    WALLET_GOV_DREP_SCRIPT_FILENAME=drep.script
    WALLET_GOV_DREP_ID_FILENAME=drep.id
    WALLET_GOV_CC_COLD_VK_FILENAME=cc-cold.vkey
    WALLET_GOV_CC_COLD_SK_FILENAME=cc-cold.skey
    WALLET_GOV_CC_COLD_ID_FILENAME=cc-cold.id
    WALLET_GOV_CC_HOT_VK_FILENAME=cc-hot.vkey
    WALLET_GOV_CC_HOT_SK_FILENAME=cc-hot.skey
    WALLET_GOV_CC_HOT_ID_FILENAME=cc-hot.id
    WALLET_GOV_HW_DREP_SK_FILENAME=drep.hw
    WALLET_GOV_HW_CC_COLD_SK_FILENAME=cc-cold.hw
    WALLET_GOV_HW_CC_HOT_SK_FILENAME=cc-hot.hw
    WALLET_MULTISIG_PREFIX=multisig-
    POOL_ID_FILENAME=pool.id
    POOL_COLDKEY_VK_FILENAME=cold.vkey
    export CNTOOLS_GOVERNANCE_PROPOSALS_TEST_SCRIPT="${REPO_ROOT}/files/tests/cntools-governance-proposals-characterization.sh"
    export CNTOOLS_GOVERNANCE_PROPOSALS_REAL_JQ="${REAL_JQ}"
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC="" BOLD="" ICON_CHECK='CHECK' ICON_CROSS='CROSS'
    price_now="" slotnum=1000
    EVENT_LOG="${event_log}"
    WAIT_COUNT=0
    CHOICES=(v g l b h q)
    CHOICE_CURSOR=0
    ANSWER_CURSOR=0
    prepare_answers "${scenario}"
    if [[ "${mode}" != LIGHT ]]; then
      # getActiveGovActionCount reads this via the fake gov-state query.
      : "${count}"
    fi
    main
    exit 99
  ) < "${key_file}" > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"

  sed "s#${runtime_root}#<runtime>#g" "${vector_log}" \
    > "${vector_log}.normalized"
  mv -f -- "${vector_log}.normalized" "${vector_log}"
  assert_semantics "${scenario}" "${stdout_file}" "${stderr_file}" \
    "${event_log}" "${vector_log}"
  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot ${scenario} after traversal"
  assert_mutation_contract "${scenario}" "${runtime_root}" \
    "${before_snapshot}" "${after_snapshot}"

  actual_stdout_hash="$(file_hash "${stdout_file}")"
  actual_event_hash="$(file_hash "${event_log}")"
  actual_vector_hash="$(file_hash "${vector_log}")"
  : "${actual_stdout_hash}" "${actual_event_hash}" "${actual_vector_hash}"
}

run_case light-count-error
run_case light-empty
run_case local-empty
run_case offline-positive
run_case light-list-error
run_case light-full-pagination
run_case local-full
run_case detail-invalid-input
run_case detail-not-found
run_case detail-cip-success
run_case detail-invalid-url
run_case detail-hash-mismatch
run_case detail-malformed-metadata
run_case detail-oversized-metadata
run_case light-malformed-api
run_case light-oversized-api

direct_keys() {
  case "$1" in
    direct-light-single-detail|direct-detail-not-found|direct-detail-unsafe-url|\
      direct-detail-hash-mismatch|direct-detail-malformed-metadata|\
      direct-detail-oversized-metadata|direct-detail-invalid-input)
      printf 'dr'
      ;;
    direct-light-pagination) printf 'npr' ;;
    direct-local-full|direct-local-zero-power) printf 'r' ;;
    *) : ;;
  esac
}

prepare_direct_answers() {
  ANSWERS=()
  case "$1" in
    direct-detail-invalid-input) ANSWERS=("${TX_A}#00") ;;
    direct-light-single-detail) ANSWERS=(gov_action1aaa) ;;
    direct-detail-*) ANSWERS=("${TX_A}#0") ;;
  esac
}

assert_direct_semantics() {
  local scenario="$1" stdout_file="$2" stderr_file="$3"
  local event_log="$4" vector_log="$5" status="$6"

  grep -Fq ' >> VOTE >> GOVERNANCE >> LIST PROPOSALS' "${stdout_file}" ||
    fail "${scenario} did not render the proposal header"
  if [[ "${status}" == 70 ]]; then
    grep -Fq 'CNTools governance-proposals action failed validation.' \
      "${stderr_file}" || fail "${scenario} validation diagnostic changed"
    return 0
  fi
  [[ ! -s "${stderr_file}" ]] ||
    fail "${scenario} reflected unexpected stderr"
  case "${scenario}" in
    direct-offline)
      grep -Fq 'proposal queries are unavailable' "${stdout_file}" ||
        fail 'offline diagnostic changed'
      [[ ! -s "${vector_log}" ]] || fail 'offline action invoked an external query'
      ;;
    direct-light-empty|direct-local-empty)
      grep -Fq 'No active proposals to vote on!' "${stdout_file}" ||
        fail "${scenario} empty display changed"
      ;;
    direct-light-count-error|direct-light-count-mismatch|\
      direct-light-malformed-list|direct-light-oversized-list|\
      direct-light-malformed-summary|direct-light-malformed-votes|\
      direct-local-malformed)
      grep -Fq 'Failed to grab list of proposals!' "${stdout_file}" ||
        fail "${scenario} all-or-nothing failure changed"
      if grep -Eq 'unsafe raw|\.\./|malformed' "${stdout_file}" "${stderr_file}"; then
        fail "${scenario} reflected untrusted response text"
      fi
      ;;
    direct-light-pagination)
      [[ "$(grep -c 'Action ID     :' "${stdout_file}")" -eq 5 ]] ||
        fail 'deterministic page traversal changed'
      grep -Fq 'You voted Yes with DRep wallet a-wallet' "${stdout_file}" ||
        fail 'DRep vote aggregation was lost across pages'
      grep -Fq 'You voted Abstain with pool a-pool' "${stdout_file}" ||
        fail 'SPO vote aggregation was lost across pages'
      grep -Fq 'You voted No with committee wallet a-wallet' "${stdout_file}" ||
        fail 'committee vote aggregation was lost across pages'
      ;;
    direct-light-single-detail)
      grep -Fq 'Page 1 of 1' "${stdout_file}" ||
        fail 'single-page proposal display changed'
      grep -Fq 'Governance Action Details' "${stdout_file}" ||
        fail 'single-page Details remains unreachable'
      grep -Fq 'Fixture proposal metadata' "${stdout_file}" ||
        fail 'valid proposal metadata was not displayed'
      ;;
    direct-detail-not-found)
      [[ "$(grep -c 'governance action id not found' "${stdout_file}")" -eq 1 ]] ||
        fail 'not-found detail state was not reset after one outcome'
      ;;
    direct-detail-invalid-input)
      grep -Fq 'ERROR: invalid action id!' "${stdout_file}" ||
        fail 'canonical action-index validation changed'
      ;;
    direct-detail-unsafe-url|direct-detail-malformed-metadata|\
      direct-detail-oversized-metadata)
      grep -Fq 'invalid governance action proposal anchor url or content' \
        "${stdout_file}" || fail "${scenario} anchor rejection changed"
      ;;
    direct-detail-hash-mismatch)
      grep -Fq 'invalid governance action proposal anchor hash' \
        "${stdout_file}" || fail 'anchor hash mismatch display changed'
      ;;
    direct-local-full)
      grep -Fq "${TX_A}#0" "${stdout_file}" ||
        fail 'LOCAL proposal action ID changed'
      grep -Fq 'NoConfidence' "${stdout_file}" ||
        fail 'LOCAL proposal type changed'
      grep -Fq 'You voted Yes with DRep wallet a-wallet' "${stdout_file}" ||
        fail 'LOCAL own DRep vote was not derived in memory'
      grep -Fq '| DRep          : 1 @ 9 VP' "${stdout_file}" ||
        fail 'always-no-confidence DRep vote power was not counted'
      grep -Fq '| SPO           : 0 @ 2 VP' "${stdout_file}" ||
        fail 'always-no-confidence SPO vote power was not counted'
      ;;
    direct-local-zero-power)
      grep -Fq '0%' "${stdout_file}" ||
        fail 'zero-vote-power display did not avoid division by zero'
      ;;
  esac
  [[ "$(grep -c '^terminal:tput:sc$' "${event_log}" || true)" == \
     "$(grep -c '^terminal:tput:rc$' "${event_log}" || true)" ]] ||
    fail "${scenario} left the terminal cursor unrestored"
  if grep -Fq 'OWNED' "${stdout_file}" || grep -Fq 'OWNED' "${stderr_file}" ||
     LC_ALL=C grep -q $'\033' "${stdout_file}" "${stderr_file}"; then
    fail "${scenario} reflected unsafe terminal data"
  fi
}

assert_direct_vectors() {
  local scenario="$1" vector_log="$2" curl_line=""

  while IFS= read -r curl_line; do
    [[ "${curl_line}" == curl$'\t'* ]] || continue
    [[ "${curl_line}" == *$'\t--disable\t--silent\t--location\t--max-redirs\t3'* &&
       "${curl_line}" == *$'\t--proto\t=https'* &&
       "${curl_line}" == *$'\t--proto-redir\t=https'* &&
       "${curl_line}" == *$'\t--output\t'* &&
       "${curl_line}" == *$'\t--url\thttps://'* ]] ||
      fail "${scenario} secure curl vector changed: ${curl_line}"
  done < "${vector_log}"
  if grep -Eq $'(^|\t)(-sSL|-X|--config)(\t|$)' "${vector_log}"; then
    fail "${scenario} used an unsafe legacy curl option"
  fi
}

run_direct_wrong_arity() {
  local case_root="${TEST_ROOT}/direct-cases/wrong-arity" status=0

  mkdir -p -- "${case_root}"
  if (
    # shellcheck source=/dev/null
    . "${ACTION_SOURCE}"
    cntools_action_main only-one-argument
  ) > "${case_root}/stdout" 2> "${case_root}/stderr"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == 64 && ! -s "${case_root}/stdout" &&
     ! -s "${case_root}/stderr" ]] || fail 'direct wrong-arity contract changed'
}

run_direct_case() {
  local scenario="$1" mode="$2" expected_status="${3:-0}"
  local case_root="${TEST_ROOT}/direct-cases/${scenario}"
  local runtime_root="${case_root}/runtime" capture_root="${case_root}/capture"
  local private_root="${runtime_root}/tmp/private"
  local context_file="${private_root}/context.json"
  local result_file="${private_root}/result.json"
  local stdout_file="${capture_root}/stdout" stderr_file="${capture_root}/stderr"
  local event_log="${capture_root}/events" vector_log="${capture_root}/vectors"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local key_file="${capture_root}/keys" status=0

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${runtime_root}/wallet" "${runtime_root}/pool" "${capture_root}"
  prepare_identity_fixtures "${runtime_root}/wallet" "${runtime_root}/pool"
  printf '%s' "$(direct_keys "${scenario}")" > "${key_file}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot direct ${scenario} before dispatch"
  mkdir -p -- "${private_root}"
  chmod 0700 "${private_root}"
  write_context "${context_file}" "${mode}" "${runtime_root}/home"
  : > "${event_log}"; : > "${vector_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C TZ=UTC
    unset -f cardano-cli bech32 curl wget git ssh nc
    PATH="${FAKE_BIN}:${BASE_PATH}"
    export PATH
    export CNTOOLS_GOVERNANCE_PROPOSALS_TEST_SCRIPT="${REPO_ROOT}/files/tests/cntools-governance-proposals-characterization.sh"
    export CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_SCENARIO="${scenario}"
    export CNTOOLS_GOVERNANCE_PROPOSALS_DIRECT_VECTOR_LOG="${vector_log}"
    export CNTOOLS_GOVERNANCE_PROPOSALS_DREP_HASH="${DREP_HASH}"
    export CNTOOLS_GOVERNANCE_PROPOSALS_CC_HOT_HASH="${CC_HOT_HASH}"
    export CNTOOLS_GOVERNANCE_PROPOSALS_POOL_HASH="${POOL_HEX}"
    export CNTOOLS_GOVERNANCE_PROPOSALS_META_HASH="${META_HASH}"
    export CNTOOLS_GOVERNANCE_PROPOSALS_METADATA_URL="${METADATA_FIXTURE}"
    export CNTOOLS_GOVERNANCE_PROPOSALS_TX_A="${TX_A}"
    export CNTOOLS_GOVERNANCE_PROPOSALS_TX_B="${TX_B}"
    export CNTOOLS_GOVERNANCE_PROPOSALS_TX_C="${TX_C}"
    export CNTOOLS_GOVERNANCE_PROPOSALS_REAL_JQ="${REAL_JQ}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    CCLI=cardano-cli
    NWMAGIC=42
    CNTOOLS_MODE="${mode}"
    CURL_TIMEOUT=10
    KOIOS_API="${KOIOS_FIXTURE}"
    KOIOS_API_HEADERS=(-H 'Authorization: fixture')
    [[ "${scenario}" == direct-unsafe-api ]] && KOIOS_API='https://koios.example.test/api?unsafe=1'
    [[ "${scenario}" == direct-unsafe-header ]] && KOIOS_API_HEADERS=(--config /tmp/unsafe)
    PROT_VERSION=10.1
    PROT_PARAMS='{"dRepVotingThresholds":{"committeeNormal":0.52,"hardForkInitiation":0.53,"motionNoConfidence":0.54,"ppEconomicGroup":0.55,"ppGovGroup":0.56,"ppNetworkGroup":0.57,"ppTechnicalGroup":0.58,"treasuryWithdrawal":0.59,"updateToConstitution":0.60},"poolVotingThresholds":{"committeeNormal":0.62,"hardForkInitiation":0.63,"motionNoConfidence":0.64,"ppSecurityGroup":0.65}}'
    WALLET_GOV_DREP_VK_FILENAME=drep.vkey
    WALLET_GOV_CC_HOT_VK_FILENAME=cc-hot.vkey
    POOL_COLDKEY_VK_FILENAME=cold.vkey
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC="" BOLD="" ICON_CHECK=CHECK ICON_CROSS=CROSS
    EVENT_LOG="${event_log}"
    WAIT_COUNT=0
    ANSWER_CURSOR=0
    prepare_direct_answers "${scenario}"
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"
  ) < "${key_file}" > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "direct ${scenario} returned ${status}, expected ${expected_status}"
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] ||
    fail "direct ${scenario} unexpectedly produced a result"
  assert_direct_semantics "${scenario}" "${stdout_file}" "${stderr_file}" \
    "${event_log}" "${vector_log}" "${status}"
  assert_direct_vectors "${scenario}" "${vector_log}"
  rm -f -- "${context_file}"
  rmdir -- "${private_root}" ||
    fail "direct ${scenario} retained private response state"
  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot direct ${scenario} after dispatch"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "direct ${scenario} zero persistent mutation"
}

run_direct_wrong_arity
run_direct_case direct-offline OFFLINE
run_direct_case direct-light-empty LIGHT
run_direct_case direct-local-empty LOCAL
run_direct_case direct-light-count-error LIGHT
run_direct_case direct-light-count-mismatch LIGHT
run_direct_case direct-light-malformed-list LIGHT
run_direct_case direct-light-oversized-list LIGHT
run_direct_case direct-light-malformed-summary LIGHT
run_direct_case direct-light-malformed-votes LIGHT
run_direct_case direct-light-pagination LIGHT
run_direct_case direct-jq-late-fault LIGHT 70
run_direct_case direct-light-single-detail LIGHT
run_direct_case direct-detail-invalid-input LIGHT
run_direct_case direct-detail-not-found LIGHT
run_direct_case direct-detail-unsafe-url LIGHT
run_direct_case direct-detail-hash-mismatch LIGHT
run_direct_case direct-detail-malformed-metadata LIGHT
run_direct_case direct-detail-oversized-metadata LIGHT
run_direct_case direct-local-full LOCAL
run_direct_case direct-local-zero-power LOCAL
run_direct_case direct-local-malformed LOCAL
run_direct_case direct-unsafe-api LIGHT 70
run_direct_case direct-unsafe-header LIGHT 70

proposal_arm="${TEST_ROOT}/proposal-arm"
expected_proposal_arm="${TEST_ROOT}/expected-proposal-arm"
awk '
  /^[[:space:]]+list-proposals\)/ { capture = 1 }
  capture && /^[[:space:]]+vote\)/ { exit }
  capture { print }
' "${CNTOOLS_SCRIPT}" > "${proposal_arm}"
printf '%s\n' \
  '                  list-proposals)' \
  '                    cntools_compatibility_dispatch_action vote.governance.proposals' \
  '                    action_status=$?' \
  '                    case "${action_status}" in' \
  '                      0) continue ;;' \
  '                      20|21) break 2 ;;' \
  '                      22) myExit ;;' \
  '                      *) waitToProceed; continue ;;' \
  '                    esac' \
  '                    ;; ###################################################################' \
  > "${expected_proposal_arm}"
assert_files_equal "${proposal_arm}" "${expected_proposal_arm}" \
  'public governance-proposals arm is not exactly one compatibility call/outcome map'
[[ "$(grep -c 'cntools_compatibility_dispatch_action vote\.governance\.proposals' \
  "${CNTOOLS_SCRIPT}" || true)" == 1 ]] ||
  fail 'public governance-proposals compatibility call count changed'
if grep -Fq ' >> VOTE >> GOVERNANCE >> LIST PROPOSALS' "${CNTOOLS_SCRIPT}"; then
  fail 'inline governance-proposals body remains in the public controller'
fi

printf 'CNTools governance-proposals characterization passed (16 public compatibility + 23 direct hardened cases)\n'
