#!/usr/bin/env bash
# shellcheck disable=SC2034
ck_group_title() {
  case "$1" in cli) printf 'Cardano CLI · Disposable artifacts and transactions' ;;
    node) printf 'Cardano node · Read-only queries' ;; koios) printf 'Koios · Read-only API contracts' ;;
    tools) printf 'Companion tools' ;; coverage) printf 'External interface coverage' ;; esac
}
ck_note() { printf '%s\n' "$*"; }
ck_skip() { printf '%s\n' "$*"; return 77; }
ck_block() { printf '%s\n' "$*"; return 78; }
ck_assert() {
  local file="$1" expression="$2" description="$3"
  if ! jq -e "$expression" "$file" >/dev/null 2>> "$CK_CASE_DIR/assertions.log"; then
    if [[ "$file" != "$CK_CASE_DIR/"* && "$file" != *.skey && "${CK_SECRET:-N}" != Y && -f "$file" ]]; then
      cp "$file" "$CK_CASE_DIR/failed-contract.json" || return 1
      file="$CK_CASE_DIR/failed-contract.json"
    fi
    printf 'Output contract failed: %s\nExpected: %s\nResponse: %s\n' "$description" "$expression" "$file"
    return 1
  fi
}
ck_require_file() { [[ -s "$1" ]] || { printf 'Required fixture/artifact unavailable: %s\n' "$1"; return 78; }; }
ck_envelope() { ck_assert "$1" 'type=="object" and (.type|type=="string") and (.cborHex|type=="string" and test("^([0-9a-fA-F]{2})+$"))' 'Cardano text envelope'; }
ck_exec() {
  local out="$1" sensitive="$2" mask='' status=0; shift 2
  local errors="$CK_WORK/stderr-$BASHPID"
  CK_COMMAND_SEQUENCE=$((CK_COMMAND_SEQUENCE+1))
  printf -v mask '%*s' "$#" ''; mask="${mask// /0}"
  cntools_run_command_timeout "$CK_TIMEOUT" "$mask" -- "$@" > "$out" 2> "$errors" || status=$?
  if [[ "$sensitive" != Y ]]; then
    cp -- "$out" "$CK_CASE_DIR/stdout-$CK_COMMAND_SEQUENCE.log" || return 1
    cp -- "$errors" "$CK_CASE_DIR/stderr-$CK_COMMAND_SEQUENCE.log" || return 1
  fi
  if (( status != 0 )); then
    printf 'Command failed (status %s)%s\n' "$status" "$([[ "$status" == 124 ]] && printf ' — timeout')"
    printf 'Command: '; printf '%q ' "$@"; printf '\n'
    if [[ "$sensitive" == Y ]]; then printf 'Secret-bearing output suppressed.\n'
    else sed -n '1,8p' "$errors"; fi
  fi
  return "$status"
}
ck_cli() { [[ -n "$CK_CLI" && -x "$CK_CLI" ]] || ck_block 'Supply --cli with an executable Cardano CLI' || return $?; ck_exec "$1" "${CK_SECRET:-N}" "$CK_CLI" "${@:2}"; }
ck_run() {
  local id="$1" label="$2" level="$3" status=0 result=passed glyph='✓' color=32 duration=0 detail=''
  shift 3
  CK_CASE_DIR="$CK_REPORT/$id"
  [[ ! -e "$CK_CASE_DIR" ]] || { printf 'Duplicate check: %s\n' "$id"; CK_FAILED=$((CK_FAILED+1)); return; }
  mkdir -- "$CK_CASE_DIR" || { printf 'Cannot create check report directory: %s\n' "$CK_CASE_DIR" >&2; exit 2; }
  CK_COMMAND_SEQUENCE=0
  duration=$SECONDS
  ( trap - EXIT; "$@" ) > "$CK_CASE_DIR/details.log" 2>&1 || status=$?
  duration=$((SECONDS-duration))
  case "$status" in
    0) CK_PASSED=$((CK_PASSED+1)) ;;
    77) CK_SKIPPED=$((CK_SKIPPED+1)); result=not_exercised; glyph='–'; color=33 ;;
    78) CK_BLOCKED=$((CK_BLOCKED+1)); result=blocked; glyph='!'; color=33 ;;
    *) CK_FAILED=$((CK_FAILED+1)); result=failed; glyph='✗'; color=31 ;;
  esac
  if [[ "$CK_COLOR" == Y ]]; then printf '  \033[%sm%s\033[0m %s [%s]\n' "$color" "$glyph" "$label" "$level"
  else printf '  %s %s [%s]\n' "$glyph" "$label" "$level"; fi
  if (( status != 0 )); then sed -n '1,10s/^/      /p' "$CK_CASE_DIR/details.log"; fi
  if (( status != 0 && status != 77 && status != 78 )) && [[ ! -s "$CK_CASE_DIR/details.log" ]]; then
    printf 'Check returned status %s without diagnostics; inspect commands.log and stdout/stderr artifacts.\n' "$status" > "$CK_CASE_DIR/details.log"
    printf '      Check returned status %s; inspect %s\n' "$status" "$CK_CASE_DIR"
  fi
  detail="$(sed -n '1,12p' "$CK_CASE_DIR/details.log")"
  jq -cn --arg id "$id" --arg label "$label" --arg level "$level" --arg result "$result" \
    --arg details "$detail" --arg path "$CK_CASE_DIR" --argjson seconds "$duration" --argjson status "$status" \
    '{id:$id,label:$label,level:$level,result:$result,exitStatus:$status,seconds:$seconds,details:$details,artifacts:$path}' >> "$CK_REPORT/results.jsonl" || { printf 'Cannot save check result\n' >&2; exit 2; }
}
ck_fixture() { [[ -n "$CK_FIXTURES" ]] || return 1; jq -er --arg k "$1" '.[$k]|select(type=="string" and length>0)' "$CK_FIXTURES"; }
ck_lookup() {
  local value=''; value="$(ck_fixture "$1" 2>/dev/null)" || { printf 'Fixture %s is required for non-empty coverage; provide --fixtures.\n' "$1"; return 77; }
  [[ "$value" =~ $2 ]] || { printf 'Fixture %s has an invalid format.\n' "$1"; return 1; }
  printf '%s' "$value"
}
ck_validate_fixtures() {
  local field='' value='' pattern=''
  for field in address stake_address payment_credential pool_id drep_id tx_hash asset proposal_id; do
    value="$(ck_fixture "$field" 2>/dev/null)" || continue
    case "$field" in
      address) pattern='^addr(_test)?1[0-9a-z]+$' ;;
      stake_address) pattern='^stake(_test)?1[0-9a-z]+$' ;;
      payment_credential) pattern='^[0-9a-f]{56}$' ;;
      pool_id) pattern='^pool1[0-9a-z]+$' ;; drep_id) pattern='^drep1[0-9a-z]+$' ;;
      tx_hash) pattern='^[0-9a-f]{64}$' ;; asset) pattern='^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$' ;;
      proposal_id) pattern='^gov_action1[0-9a-z]+$' ;;
    esac
    [[ "$value" =~ $pattern ]] || { printf 'Invalid fixture field: %s\n' "$field" >&2; return 1; }
  done
}
ck_finish() {
  local exit_status=0
  (( CK_BLOCKED == 0 )) || exit_status=2
  (( CK_FAILED == 0 )) || exit_status=1
  local executed=0 syntax=0
  executed="$(jq -s '[.[]|select(.result=="passed" and .level=="executed")]|length' "$CK_REPORT/results.jsonl")"
  syntax="$(jq -s '[.[]|select(.result=="passed" and .level=="syntax")]|length' "$CK_REPORT/results.jsonl")"
  jq -s --arg started "$CK_STARTED" --arg source "$CK_SOURCE" --arg commit "$CK_COMMIT" --arg network "$CK_NETWORK" \
    --arg cli "$CK_CLI" --arg hardwareCli "$CK_HWCLI" --arg koios "$CK_KOIOS" --arg suites "$CK_SUITES" --argjson exitStatus "$exit_status" \
    '{started:$started,source:$source,repositoryCommit:$commit,network:$network,cli:$cli,hardwareCli:$hardwareCli,koios:$koios,suites:($suites|split(",")),exitStatus:$exitStatus,
      counts:{passed:([.[]|select(.result=="passed")]|length),failed:([.[]|select(.result=="failed")]|length),blocked:([.[]|select(.result=="blocked")]|length),notExercised:([.[]|select(.result=="not_exercised")]|length)},checks:.}' \
    "$CK_REPORT/results.jsonl" > "$CK_REPORT/report.json" || { printf 'Cannot save final report\n' >&2; exit 2; }
  printf '\nResult: %s passed · %s failed · %s blocked · %s not exercised\nReport: %s/report.json\n' "$CK_PASSED" "$CK_FAILED" "$CK_BLOCKED" "$CK_SKIPPED" "$CK_REPORT"
  printf 'Pass coverage: %s executed · %s syntax-only (discovery checks are not execution coverage).\n' "$executed" "$syntax"
  printf 'No live transaction submission was attempted. Read individual coverage levels; skips are not passes.\n'
  exit "$exit_status"
}
