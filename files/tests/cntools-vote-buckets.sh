#!/usr/bin/env bash
# CNTools proposal voting power: the default-vote buckets of Koios
# proposal_voting_summary (stake delegated to Always abstain and Always no
# confidence, pools that did not vote with their reward account delegated to
# one of them), shown only for roles that vote on the action and only for the
# fields Koios returned; and Pool Show's default vote from Koios pool_info
# reward_addr_delegated_drep (#1838). Koios is a stub and every ID is made up.
# shellcheck disable=SC2034 # Library state is set here and read by the libraries.
set -uo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'cntools vote buckets tests skipped: Bash 5+ required\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { printf 'cntools vote buckets tests skipped: jq is not installed\n'; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
LIB="${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-vote-buckets.XXXXXX")" || exit 1
trap 'rm -rf "${WORK}"' EXIT
failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }
expect() { [[ "$1" == *"$2"* ]] || fail "$3: '$2' not in: $1"; }
refuse() { [[ "$1" != *"$2"* ]] || fail "$3: '$2' in: $1"; }

for library in number governance-voting-stats pool-ui; do
  # shellcheck source=/dev/null
  source "${LIB}/${library}.sh" || { printf 'FAIL: cannot load %s\n' "${library}" >&2; exit 1; }
done
# The UI is stubbed: rows are printed as plain lines.
cntools_log() { :; }
cntools_table_pair() { printf 'ROW %s | %s | %s\n' "$1" "$2" "${3:-}"; }
cntools_transaction_log() { :; }
cntools_transaction_temp_file() { printf -v "$1" '%s' "$(mktemp "${WORK}/tmp.XXXXXX")"; }
# Koios answers with the file named by KOIOS_REPLY.
KOIOS_REPLY=''
cntools_wallet_query_http() { cp "${KOIOS_REPLY}" "$3"; }

ID=gov_action1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
record() { jq -cn --arg id "${ID}" --arg type "$1" --argjson contents "${2:-null}" '{id:$id,type:$type,action:{tag:$type,contents:$contents}}'; }
# A proposal_voting_summary record as Koios returns it; FIELDS (JSON) replaces
# or removes (null) fields.
summary() {
  jq -cn --arg type "$1" --argjson fields "${2:-{\}}" '[{
    proposal_type:$type, epoch_no:600,
    drep_yes_votes_cast:120, drep_active_yes_vote_power:"9000000000000", drep_yes_vote_power:"9000000000000", drep_yes_pct:60.5,
    drep_no_votes_cast:30, drep_active_no_vote_power:"2000000000000", drep_no_vote_power:"5000000000000", drep_no_pct:39.5,
    drep_abstain_votes_cast:4, drep_active_abstain_vote_power:"100000000000",
    drep_always_no_confidence_vote_power:"3000000000000", drep_always_abstain_vote_power:"7500000000000",
    pool_yes_votes_cast:300, pool_active_yes_vote_power:"4000000000000000", pool_yes_vote_power:"4000000000000000", pool_yes_pct:30,
    pool_no_votes_cast:20, pool_active_no_vote_power:"500000000000000", pool_no_vote_power:"9000000000000000", pool_no_pct:70,
    pool_abstain_votes_cast:5, pool_active_abstain_vote_power:"100000000000000",
    pool_passive_always_abstain_votes_assigned:42, pool_passive_always_abstain_vote_power:"1500000000000000",
    pool_passive_always_no_confidence_votes_assigned:1, pool_passive_always_no_confidence_vote_power:"250000000000",
    committee_yes_votes_cast:5, committee_yes_pct:71.43, committee_no_votes_cast:2, committee_no_pct:28.57, committee_abstain_votes_cast:0
  } * $fields | with_entries(select(.value != null))]'
}
# Rows of PROPOSAL with Koios answering SUMMARY.
rows() {
  printf '%s\n' "$2" > "${WORK}/summary.json"; KOIOS_REPLY="${WORK}/summary.json"
  CNTOOLS_VOTING_STATS=()
  cntools_voting_stats_collect "$1" || fail "statistics of $1 were not collected"
  cntools_voting_stats_rows "$1" page
}
CNTOOLS_MODE=online CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://koios.invalid/api/v1

# ── NoConfidence: DReps and SPOs vote, the committee does not ────────────────
out="$(rows "$(record NoConfidence)" "$(summary NoConfidence)")"
expect "${out}" "ROW DRep · Always abstain | 7,500,000 ADA voting power · counted as Abstain | number" "no confidence: DRep always abstain"
expect "${out}" "ROW DRep · Always no confidence | 3,000,000 ADA voting power · counted as Yes | number" "no confidence: DRep always no confidence"
expect "${out}" "ROW SPO · Passive always abstain | 42 pools not voted · 1,500,000,000 ADA voting power · counted as Abstain | number" "no confidence: SPO passive always abstain"
expect "${out}" "ROW SPO · Passive always no confidence | 1 pool not voted · 250,000 ADA voting power · counted as Yes | number" "no confidence: SPO passive always no confidence"
refuse "${out}" "Committee ·" "no confidence: committee rows"
# The buckets follow their role's yes/no/abstain rows.
order="$(grep '^ROW [A-Za-z]* · ' <<< "${out}" | cut -d '|' -f 1 | sed 's/^ROW //; s/ $//' | paste -sd ',' -)"
assert_eq "${order}" "DRep · Yes,DRep · No,DRep · Abstain,DRep · Always abstain,DRep · Always no confidence,SPO · Yes,SPO · No,SPO · Abstain,SPO · Passive always abstain,SPO · Passive always no confidence" "no confidence: row order"

# ── HardForkInitiation: a pool that did not vote counts as No ────────────────
out="$(rows "$(record HardForkInitiation '[null,{"major":11,"minor":0}]')" "$(summary HardForkInitiation)")"
expect "${out}" "ROW SPO · Passive always abstain | 42 pools not voted · 1,500,000,000 ADA voting power · counted as No | number" "hard fork: SPO passive always abstain"
expect "${out}" "ROW SPO · Passive always no confidence | 1 pool not voted · 250,000 ADA voting power · counted as No | number" "hard fork: SPO passive always no confidence"
expect "${out}" "ROW DRep · Always abstain | 7,500,000 ADA voting power · counted as Abstain | number" "hard fork: DRep always abstain"
expect "${out}" "ROW DRep · Always no confidence | 3,000,000 ADA voting power · counted as No | number" "hard fork: DRep always no confidence"
expect "${out}" "ROW Committee · Yes | 5 votes · 71.43 % | number" "hard fork: committee row"
refuse "${out}" "Committee · Always" "hard fork: committee buckets"

# ── InfoAction: everyone votes, Always no confidence counts as No ────────────
out="$(rows "$(record InfoAction)" "$(summary InfoAction)")"
expect "${out}" "ROW SPO · Passive always abstain | 42 pools not voted · 1,500,000,000 ADA voting power · counted as Abstain | number" "info: SPO passive always abstain"
expect "${out}" "ROW SPO · Passive always no confidence | 1 pool not voted · 250,000 ADA voting power · counted as No | number" "info: SPO passive always no confidence"

# ── TreasuryWithdrawals: no SPO vote, so no SPO buckets ──────────────────────
out="$(rows "$(record TreasuryWithdrawals)" "$(summary TreasuryWithdrawals)")"
expect "${out}" "ROW DRep · Always abstain | 7,500,000 ADA voting power · counted as Abstain | number" "treasury: DRep always abstain"
expect "${out}" "ROW DRep · Always no confidence | 3,000,000 ADA voting power · counted as No | number" "treasury: DRep always no confidence"
refuse "${out}" "SPO ·" "treasury: SPO rows"

# ── ParameterChange: SPO buckets only for a security parameter ───────────────
out="$(rows "$(record ParameterChange '[null,{"maxTxSize":16384}]')" "$(summary ParameterChange)")"
expect "${out}" "ROW SPO · Passive always abstain | 42 pools not voted" "security parameter: SPO passive always abstain"
out="$(rows "$(record ParameterChange '[null,{"dRepActivity":20}]')" "$(summary ParameterChange)")"
refuse "${out}" "SPO ·" "governance parameter: SPO rows"
expect "${out}" "ROW DRep · Always abstain |" "governance parameter: DRep always abstain"

# ── Fields Koios did not return (an older instance) ──────────────────────────
out="$(rows "$(record NoConfidence)" "$(summary NoConfidence '{"drep_always_abstain_vote_power":null,"pool_passive_always_no_confidence_votes_assigned":null,"pool_passive_always_no_confidence_vote_power":null}')")"
refuse "${out}" "DRep · Always abstain" "missing DRep always abstain"
expect "${out}" "ROW DRep · Always no confidence | 3,000,000 ADA voting power · counted as Yes | number" "DRep always no confidence kept"
refuse "${out}" "SPO · Passive always no confidence" "missing SPO passive always no confidence"
expect "${out}" "ROW SPO · Passive always abstain | 42 pools not voted" "SPO passive always abstain kept"
# Only the count, or only the power.
out="$(rows "$(record NoConfidence)" "$(summary NoConfidence '{"pool_passive_always_abstain_vote_power":null,"pool_passive_always_no_confidence_votes_assigned":null}')")"
expect "${out}" "ROW SPO · Passive always abstain | 42 pools not voted · counted as Abstain | number" "count without power"
expect "${out}" "ROW SPO · Passive always no confidence | 250,000 ADA voting power · counted as Yes | number" "power without count"
# Zero is a value Koios returned.
out="$(rows "$(record NoConfidence)" "$(summary NoConfidence '{"pool_passive_always_abstain_votes_assigned":0,"pool_passive_always_abstain_vote_power":"0"}')")"
expect "${out}" "ROW SPO · Passive always abstain | 0 pools not voted · 0 ADA voting power · counted as Abstain | number" "empty bucket"

# ── An invalid count rejects the whole summary ───────────────────────────────
for bad in '"42"' '-1' '1.5'; do
  out="$(rows "$(record NoConfidence)" "$(summary NoConfidence "{\"pool_passive_always_abstain_votes_assigned\":${bad}}")")"
  refuse "${out}" "SPO ·" "assigned count ${bad}"
done

# ── Pool Show: the default vote from the reward account's DRep delegation ────
pool() { cntools_pool_settings_rows "$1" koios | grep -E '^ROW (Reward DRep delegation|Default vote) '; }
base='{"pledge":"1000000","fixed_cost":"170000000","margin":0.01,"reward_addr":"stake1uxqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"}'
DREP=drep1ygqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
out="$(pool "$(jq -c '. + {reward_addr_delegated_drep:"drep_always_abstain"}' <<< "${base}")")"
assert_eq "${out}" $'ROW Reward DRep delegation | drep_always_abstain | identifier\nROW Default vote | Abstain if the pool does not vote · No on a hard fork | value' "always abstain"
out="$(pool "$(jq -c '. + {reward_addr_delegated_drep:"drep_always_no_confidence"}' <<< "${base}")")"
assert_eq "${out}" $'ROW Reward DRep delegation | drep_always_no_confidence | identifier\nROW Default vote | Yes on no confidence if the pool does not vote · No on other actions | value' "always no confidence"
out="$(pool "$(jq -c --arg drep "${DREP}" '. + {reward_addr_delegated_drep:$drep}' <<< "${base}")")"
assert_eq "${out}" $"ROW Reward DRep delegation | ${DREP} | identifier"$'\nROW Default vote | No if the pool does not vote · the DRep does not vote for the pool | value' "DRep"
out="$(pool "$(jq -c '. + {reward_addr_delegated_drep:null}' <<< "${base}")")"
assert_eq "${out}" 'ROW Default vote | No if the pool does not vote | value' "not delegated"
out="$(pool "${base}")"
assert_eq "${out}" '' "Koios without the field"
# The local node's pool state has no delegation: no default vote row.
out="$(cntools_pool_settings_rows '{"spsPledge":1000000,"spsCost":170000000,"spsMargin":0.01}' local | grep -c 'Default vote')"
assert_eq "${out}" 0 "local pool state"

if (( failures > 0 )); then
  printf '%s cntools vote buckets check(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'cntools vote buckets tests passed\n'
