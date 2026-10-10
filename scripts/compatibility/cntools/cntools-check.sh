#!/usr/bin/env bash
# Standalone, non-submitting CNTools external-interface compatibility checks.
# shellcheck disable=SC1090,SC1091,SC2034
set +x
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools compatibility checks require Bash 4.4 or newer.\n' >&2
  exit 2
fi
set -uo pipefail
umask 077
CK_HOME="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
CK_REPO="$(cd -- "${CK_HOME}/../../.." && pwd -P)"
CK_SOURCE="${CK_REPO}/scripts/common-helper-scripts/cntools"
CK_SUITES=cli
CK_CLI="$(type -P cardano-cli || true)"
CK_HWCLI="$(type -P cardano-hw-cli || true)"
CK_SOCKET='' CK_KOIOS='' CK_METRICS='' CK_NODE='' CK_FIXTURES=''
CK_NETWORK=preview CK_MAGIC=2 CK_REPORT='' CK_TIMEOUT=30 CK_DELAY=1
CK_TOKEN="${KOIOS_API_TOKEN:-}"
export -n CK_TOKEN KOIOS_API_TOKEN 2>/dev/null || true
unset KOIOS_API_TOKEN
CK_WORK='' CK_PASSED=0 CK_FAILED=0 CK_BLOCKED=0 CK_SKIPPED=0
CK_COLOR=N
[[ ! -t 1 || -n "${NO_COLOR:-}" ]] || CK_COLOR=Y
usage() {
  printf '%s\n' 'Usage: cntools-check.sh [options]' \
    '  --suite cli,node,koios,tools,coverage  Groups to run (default: cli)' \
    '  --suite all                         All groups; missing inputs are reported' \
    '  --cli PATH                          Candidate cardano-cli executable' \
    '  --hw-cli PATH                       Candidate cardano-hw-cli executable' \
    '  --source-root PATH                  CNTools source tree to check' \
    '  --socket PATH                       Existing node socket (read-only queries)' \
    '  --node PATH                         Optional node executable for version reporting' \
    '  --network mainnet|preview|preprod|guild' \
    '  --testnet-magic N                    Override testnet magic' \
    '  --koios HTTPS_URL                   Koios API base, including /api/v1' \
    '  --metrics URL                       Explicit node metrics URL' \
    '  --fixtures PATH                     Public lookup identities in JSON' \
    '  --report-dir PATH                   New directory for reports (never overwritten)' \
    '  --timeout SECONDS                   Command/request timeout (default: 30)' \
    '  --delay SECONDS                     Delay before API calls (default: 1)' \
    '  --help' '' \
    'No transactions are submitted. No env file is sourced. No real keys are loaded.' \
    'Use KOIOS_API_TOKEN for authentication; it is removed from child environments.'
}
die() { printf 'CNTools compatibility: %s\n' "$*" >&2; exit 2; }
while (( $# )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --suite|--cli|--hw-cli|--source-root|--socket|--node|--network|--testnet-magic|--koios|--metrics|--fixtures|--report-dir|--timeout|--delay)
      (( $# >= 2 )) || die "Missing value for $1"
      case "$1" in
        --suite) CK_SUITES="$2" ;; --cli) CK_CLI="$2" ;; --source-root) CK_SOURCE="$2" ;;
        --hw-cli) CK_HWCLI="$2" ;;
        --socket) CK_SOCKET="$2" ;; --node) CK_NODE="$2" ;; --network) CK_NETWORK="$2" ;;
        --testnet-magic) CK_MAGIC="$2"; CK_MAGIC_OVERRIDE=Y ;; --koios) CK_KOIOS="${2%/}" ;;
        --metrics) CK_METRICS="$2" ;; --fixtures) CK_FIXTURES="$2" ;; --report-dir) CK_REPORT="$2" ;;
        --timeout) CK_TIMEOUT="$2" ;; --delay) CK_DELAY="$2" ;;
      esac
      shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ "$CK_TIMEOUT" =~ ^[1-9][0-9]{0,2}$ && "$CK_DELAY" =~ ^[0-9]{1,2}$ ]] || die 'Invalid timeout/delay'
case "$CK_NETWORK" in mainnet) ;; preview) [[ "${CK_MAGIC_OVERRIDE:-}" == Y ]] || CK_MAGIC=2 ;;
  preprod) [[ "${CK_MAGIC_OVERRIDE:-}" == Y ]] || CK_MAGIC=1 ;;
  guild) [[ "${CK_MAGIC_OVERRIDE:-}" == Y ]] || CK_MAGIC=141 ;; *) die 'Unknown network' ;; esac
if [[ ! "$CK_MAGIC" =~ ^[0-9]{1,10}$ ]] || (( 10#$CK_MAGIC > 4294967295 )); then die 'Invalid testnet magic'; fi
[[ -z "$CK_KOIOS" || "$CK_KOIOS" =~ ^https://[^[:space:]\?#@]+$ ]] || die 'Koios must be an HTTPS base URL without embedded credentials/query'
[[ -z "$CK_METRICS" || "$CK_METRICS" =~ ^https?://[^[:space:]@]+$ ]] || die 'Invalid metrics URL'
for tool in jq awk sed mktemp mkdir chmod rm date curl cp grep cmp sleep od tr wc sort cat; do type -P "$tool" >/dev/null || die "Missing prerequisite: $tool"; done
[[ -d "$CK_SOURCE/lib" && -f "$CK_SOURCE/core/log.sh" ]] || die 'Invalid CNTools source root'
if [[ -n "$CK_FIXTURES" ]]; then
  [[ -f "$CK_FIXTURES" && ! -L "$CK_FIXTURES" ]] || die 'Fixtures must be a regular JSON file'
  jq -e --arg network "$CK_NETWORK" 'type=="object" and .network==$network and
    ((keys-["network","address","stake_address","payment_credential","pool_id","drep_id","tx_hash","asset","proposal_id"])|length)==0 and
    all(to_entries[]; .value|type=="string")' "$CK_FIXTURES" >/dev/null || die 'Fixtures must contain only documented public string fields and the selected network'
fi
[[ "$CK_SUITES" != all ]] || CK_SUITES=cli,node,koios,tools,coverage
[[ "$CK_SUITES" =~ ^(cli|node|koios|tools|coverage)(,(cli|node|koios|tools|coverage))*$ ]] || die 'Invalid suite list'
IFS=, read -r -a CK_GROUPS <<< "$CK_SUITES"
declare -A CK_SELECTED=()
for group in "${CK_GROUPS[@]}"; do
  [[ "$group" =~ ^(cli|node|koios|tools|coverage)$ ]] || die "Unknown suite: $group"
  [[ -z "${CK_SELECTED[$group]:-}" ]] || die "Duplicate suite: $group"
  CK_SELECTED[$group]=Y
done
if [[ -n "$CK_REPORT" ]]; then
  [[ "$CK_REPORT" = /* && ! -e "$CK_REPORT" && ! -L "$CK_REPORT" ]] || die 'Report directory must be a new absolute path'
  mkdir -- "$CK_REPORT" || die 'Cannot create report directory'
else
  CK_REPORT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-compat-report.XXXXXX")" || die 'Cannot create report directory'
fi
CK_REPORT="$(cd -- "$CK_REPORT" && pwd -P)"
chmod 0700 "$CK_REPORT" || die 'Cannot protect report directory'
# Keep this path short enough for GPG-agent Unix socket limits.
CK_WORK="$(mktemp -d /tmp/cntools-check.XXXXXX)" || die 'Cannot create private workspace'
CK_WORK="$(cd -- "$CK_WORK" && pwd -P)"
cleanup() { [[ -z "$CK_WORK" || ! -d "$CK_WORK" ]] || rm -rf -- "$CK_WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Source functions only, never the launcher, env, menus or action entrypoints.
for library in number filesystem bech32 json wallet-query wallet-query-local asset-cache asset-metadata wallet-query-koios utxo pool-query drep-query drep-id governance-proposal wallet-history message-crypto key-crypto; do
  . "$CK_SOURCE/lib/$library.sh" || die "Cannot load CNTools parser library: $library"
done
. "$CK_SOURCE/core/log.sh" || die 'Cannot load bounded command executor'
. "$CK_SOURCE/core/health.sh" || die 'Cannot load metrics parser'
for library in report cli node koios tools hardware coverage; do . "$CK_HOME/lib/$library.sh" || die "Cannot load check library: $library"; done
if [[ -n "$CK_FIXTURES" ]]; then ck_validate_fixtures || die 'Invalid public lookup fixtures'; fi
# The normal bounded command executor is reused with a report-only logger.
cntools_log() { printf '[%s] %s\n' "$1" "$2" >> "$CK_CASE_DIR/commands.log"; }
CK_NET=(--testnet-magic "$CK_MAGIC")
[[ "$CK_NETWORK" != mainnet ]] || CK_NET=(--mainnet)
CK_COMMIT="$(git -C "$CK_REPO" rev-parse HEAD 2>/dev/null || printf unknown)"
CK_STARTED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'CNTools compatibility checker\nNetwork: %s · Source: %s\nReports: %s\n' "$CK_NETWORK" "$CK_SOURCE" "$CK_REPORT"
for group in "${CK_GROUPS[@]}"; do
  printf '\n%s\n' "$(ck_group_title "$group")"
  "ck_suite_$group"
done
ck_finish
