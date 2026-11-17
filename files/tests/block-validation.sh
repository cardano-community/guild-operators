#!/usr/bin/env bash
# shellcheck disable=SC2034 # many variables are read by the functions loaded from the scripts
# Block validation for cardano-node (cncli.sh validate) and Amaru
# (amaru-leaderlog.sh validate): which status each kind of led slot gets, and
# the block details both write to the shared blocklog database.
set -o pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'block validation tests skipped: Bash 5+ required\n'
  exit 0
fi
for required_command in b2sum jq sqlite3; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    printf 'block validation tests skipped: %s is not installed\n' "${required_command}"
    exit 0
  fi
done
if ! date -u -d @0 +%s >/dev/null 2>&1; then
  printf 'block validation tests skipped: GNU date is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-block-validation.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT
failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# load_functions <file> <name>...: define the named top-level functions of a script.
load_functions() {
  local file="$1" name
  shift
  for name in "$@"; do
    eval "$(awk -v name="${name}" '$0 ~ "^"name"\\(\\) \\{" {f=1} f {print} f && /^}$/ {exit}' "${file}")"
    declare -F "${name}" >/dev/null || { printf 'FAIL: %s has no function %s\n' "${file}" "${name}" >&2; exit 1; }
  done
}

# The block log section of the common env library, and its slot helpers.
eval "$(awk '/^BLOCKLOG_DETAIL_COLUMNS=/,/^# Description : Calculate expected interval/' \
  "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library")"
load_functions "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library" \
  getEpochFromSlot getSlotInEpochFromSlot getDateFromSlot

# Preview's genesis: one-second slots from the Shelley start.
SHELLEY_TRANS_EPOCH=0
BYRON_EPOCH_LENGTH=4320
BYRON_SLOT_LENGTH=20000
SLOT_LENGTH=1
EPOCH_LENGTH=86400
SHELLEY_GENESIS_START_SEC=1666656000
KOIOS_API=''
KOIOS_API_HEADERS=()

# slot_time <slot> <ms>: the trace timestamp that many ms into the slot
slot_unix() { printf '%s.%06d' $(( SHELLEY_GENESIS_START_SEC + $1 )) $(( $2 * 1000 )); }
slot_iso() { printf '%s.%03d000000Z' "$(date -u -d "@$(( SHELLEY_GENESIS_START_SEC + $1 ))" +%FT%T)" "$2"; }

# The node's journal is a fixture file in "journalctl -o short-unix" format.
JOURNAL="${TEST_ROOT}/journal"
blocklogJournalWindow() {
  awk -v from="$2" -v to="$3" '{ split($1, t, "."); if (t[1] >= from && t[1] <= to) print }' "${JOURNAL}"
}

detail() {
  sqlite3 "${BLOCKLOG_DB}" "SELECT $1 FROM blockdetail WHERE slot = $2;"
}
status_of() {
  sqlite3 "${BLOCKLOG_DB}" "SELECT status FROM blocklog WHERE slot = $1;"
}
new_blocklog() {
  BLOCKLOG_DIR="${TEST_ROOT}/$1"
  BLOCKLOG_DB="${BLOCKLOG_DIR}/blocklog.db"
  blocklogCreateDB >/dev/null || { printf 'FAIL: blocklog database not created\n' >&2; exit 1; }
}
add_leader_slot() { # slot status
  sqlite3 "${BLOCKLOG_DB}" "INSERT INTO blocklog (slot, at, epoch, slot_in_epoch, status) VALUES ($1, '$(getDateFromSlot "$1" '%(%FT%T+00:00)T' UTC)', 0, $1, '${2:-leader}');"
}

#############################################################################
# Schema
#############################################################################

new_blocklog schema
assert_eq "$(sqlite3 "${BLOCKLOG_DB}" 'PRAGMA user_version;')" "2" "new database schema"
BLOCKLOG_DB="${BLOCKLOG_DIR}/v1.db"
sqlite3 "${BLOCKLOG_DB}" "CREATE TABLE blocklog (id INTEGER PRIMARY KEY, slot INTEGER, at TEXT, epoch INTEGER, block INTEGER, slot_in_epoch INTEGER, hash TEXT, size INTEGER, status TEXT);
  CREATE TABLE epochdata (id INTEGER PRIMARY KEY, epoch INTEGER, active_stake TEXT, total_active_stake TEXT);
  INSERT INTO blocklog (slot, status) VALUES (7, 'confirmed'); PRAGMA user_version = 1;"
blocklogCreateDB >/dev/null
assert_eq "$(sqlite3 "${BLOCKLOG_DB}" 'PRAGMA user_version;')|$(sqlite3 "${BLOCKLOG_DB}" 'SELECT status FROM blocklog;')" \
  "2|confirmed" "upgrade from schema 1 keeps the block log"
assert_eq "$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM pragma_table_info('blockdetail');")" "26" "blockdetail columns"

#############################################################################
# cardano-node: cncli.sh validate
#############################################################################

load_functions "${REPO_ROOT}/scripts/cnode-helper-scripts/cncli.sh" \
  cncliChainRows cncliChainRow cncliPoolOf cncliForgeRecord cncliArrivals cncliSaveDetail validateBlock

hash_of() { printf '%s%063x' "$1" "$2"; }  # family (a final chain, b ours, c other pools, d fork), height
OUR_VRF="$(printf 'e%.0s' {1..64})"
OUR_VKEY="$(printf '7%.0s' {1..64})"
other_vkey() { printf '%063x%x' 0 "$1"; }
OTHER_VRF="$(printf '5%.0s' {1..64})"
CNCLI_DB="${TEST_ROOT}/cncli.db"
sqlite3 "${CNCLI_DB}" "CREATE TABLE chain (id INTEGER PRIMARY KEY AUTOINCREMENT, block_number INTEGER, slot_number INTEGER,
  hash TEXT, prev_hash TEXT, node_vkey TEXT, node_vrf_vkey TEXT, leader_vrf_0 TEXT, block_size INTEGER, orphaned INTEGER DEFAULT 0);"

# The final chain from height 100 to 140, one block every 10 slots, except
# where a case below needs another slot or our block.
declare -A final_slot=([106]=1063 [107]=1068 [108]=1077 [109]=1082 [139]=4800 [140]=4900)
declare -A final_hash=()
sql="BEGIN;"
for (( height = 100; height <= 140; height++ )); do
  slot="${final_slot[${height}]:-$(( 1000 + (height - 100) * 10 ))}"
  family=a; vkey="$(other_vkey $(( height % 5 )))"; vrf="${OTHER_VRF}"
  if (( height == 103 || height == 139 )); then family=b; vkey="${OUR_VKEY}"; vrf="${OUR_VRF}"; fi
  final_hash[${height}]="$(hash_of "${family}" "${height}")"
  sql+="INSERT INTO chain (block_number, slot_number, hash, prev_hash, node_vkey, node_vrf_vkey, leader_vrf_0, block_size)
    VALUES (${height}, ${slot}, '${final_hash[${height}]}', '${final_hash[$((height - 1))]:-$(hash_of a 99)}', '${vkey}', '${vrf}', '$(printf '%064x' $(( height * 7 )))', 1000);"
done
# Orphaned blocks: ours lost a slot battle at 1050 (h105), a height battle at
# 1060 (h106, the winner came 3 s later) and at 1070 (h107, the winner came
# 2 s earlier), and was built on a fork at 1080 (h109 on d108).
orphan() { # height slot hash prev vkey vrf_vkey leader_vrf
  sql+="INSERT INTO chain (block_number, slot_number, hash, prev_hash, node_vkey, node_vrf_vkey, leader_vrf_0, block_size, orphaned)
    VALUES ($1, $2, '$3', '$4', '$5', '$6', '$7', 900, 1);"
}
orphan 105 1050 "$(hash_of b 105)" "${final_hash[104]}" "${OUR_VKEY}" "${OUR_VRF}" "$(printf 'f%.0s' {1..64})"
orphan 106 1060 "$(hash_of b 106)" "${final_hash[105]}" "${OUR_VKEY}" "${OUR_VRF}" "$(printf '1%.0s' {1..64})"
orphan 107 1070 "$(hash_of b 107)" "${final_hash[106]}" "${OUR_VKEY}" "${OUR_VRF}" "$(printf '1%.0s' {1..64})"
orphan 108 1078 "$(hash_of d 108)" "${final_hash[107]}" "$(other_vkey 9)" "${OTHER_VRF}" "$(printf '2%.0s' {1..64})"
orphan 109 1080 "$(hash_of b 109)" "$(hash_of d 108)" "${OUR_VKEY}" "${OUR_VRF}" "$(printf '1%.0s' {1..64})"
sqlite3 "${CNCLI_DB}" "${sql} COMMIT;"

# The node's journal: what it logged when it led a slot, and when it fetched
# the competing blocks. Slot 1095 was forged on h109 but CNCLI never saw it.
cnode_line() { printf '%s ai-playground cnode[42]: {"at":"%s","ns":"%s","data":%s,"sev":"Info","host":"ai-playground"}\n' "$(slot_unix "$1" "$2")" "$(slot_iso "$1" "$2")" "$3" "$4"; }
{
  cnode_line 1060 150 Forge.Loop.ForgedBlock "{\"block\":\"$(hash_of b 106)\",\"blockNo\":106,\"blockPrev\":\"${final_hash[105]}\",\"kind\":\"TraceForgedBlock\",\"slot\":1060}"
  cnode_line 1063 420 ChainSync.Client.DownloadedHeader "{\"block\":\"${final_hash[106]}\",\"blockNo\":106,\"kind\":\"DownloadedHeader\",\"peer\":{\"connectionId\":\"1.2.3.4:3001 5.6.7.8:3001\"},\"slot\":1063}"
  cnode_line 1063 480 ChainSync.Client.DownloadedHeader "{\"block\":\"${final_hash[106]}\",\"blockNo\":106,\"kind\":\"DownloadedHeader\",\"peer\":{\"connectionId\":\"1.2.3.4:3001 5.6.7.9:3001\"},\"slot\":1063}"
  cnode_line 1063 900 BlockFetch.Client.CompletedBlockFetch "{\"block\":\"${final_hash[106]}\",\"delay\":0.9004,\"kind\":\"CompletedBlockFetch\",\"size\":900}"
  cnode_line 1063 950 BlockFetch.Client.CompletedBlockFetch "{\"block\":\"${final_hash[106]}\",\"delay\":0.95,\"kind\":\"CompletedBlockFetch\",\"size\":900}"
  cnode_line 1068 2600 BlockFetch.Client.CompletedBlockFetch "{\"block\":\"${final_hash[107]}\",\"delay\":2.6,\"kind\":\"CompletedBlockFetch\",\"size\":900}"
  cnode_line 1070 120 Forge.Loop.ForgedBlock "{\"block\":\"$(hash_of b 107)\",\"blockNo\":107,\"blockPrev\":\"${final_hash[106]}\",\"kind\":\"TraceForgedBlock\",\"slot\":1070}"
  cnode_line 1090 2 Forge.Loop.NodeIsLeader '{"kind":"TraceNodeIsLeader","slot":1090}'
  cnode_line 1090 3 Forge.Loop.NodeCannotForge '{"kind":"TraceNodeCannotForge","reason":"no KES key","slot":1090}'
  cnode_line 1095 90 Forge.Loop.ForgedBlock "{\"block\":\"$(hash_of b 110)\",\"blockNo\":110,\"blockPrev\":\"${final_hash[109]}\",\"kind\":\"TraceForgedBlock\",\"slot\":1095}"
  cnode_line 1095 91 Forge.Loop.AdoptedBlock "{\"blockHash\":\"$(hash_of b 110)\",\"blockSize\":3,\"kind\":\"TraceAdoptedBlock\",\"slot\":1095}"
  cnode_line 1100 400 BlockFetch.Client.CompletedBlockFetch "{\"block\":\"${final_hash[110]}\",\"delay\":0.4,\"kind\":\"CompletedBlockFetch\",\"size\":900}"
  cnode_line 4800 50 Forge.Loop.ForgedBlock "{\"block\":\"${final_hash[139]}\",\"blockNo\":139,\"blockPrev\":\"${final_hash[138]}\",\"kind\":\"TraceForgedBlock\",\"slot\":4800}"
} > "${JOURNAL}"

new_blocklog cnode
for slot in 1030 1050 1060 1070 1080 1090 1095 1120 4800 4950; do add_leader_slot "${slot}"; done
pool_vrf_vkey_cbox_hex="${OUR_VRF}"
CNCLI_JOURNAL=Y
CNCLI_NODE_UNIT=cnode
CONFIRM_SLOT_CNT=600
CONFIRM_BLOCK_CNT=15
slotnum=5000
blocknum=140
run_cncli() {
  local block_epoch block_slot block_status block_hash
  while IFS='|' read -r block_epoch block_slot block_status block_hash; do
    [[ ${1:-} != reset || ${block_status} == invalid ]] || block_status=leader
    validateBlock
  done < <(sqlite3 "${BLOCKLOG_DB}" "SELECT epoch, slot, status, hash FROM blocklog ORDER BY slot;")
}
cncli_output="$(run_cncli 2>&1)"

assert_eq "$(status_of 1030)|$(detail "reason,block,prev_slot,next_slot,winner_hash" 1030)" \
  "confirmed||103|1020|1040|" "cnode: our block on the chain"
assert_eq "$(status_of 1050)|$(detail "reason,winner_slot,winner_vrf < vrf" 1050)" \
  "stolen|slot_battle|1050|1" "cnode: slot battle, the winner had the lower VRF"
assert_eq "$(status_of 1060)|$(detail "reason,block,forge_ms,winner_slot,winner_ms,prev_slot,next_slot" 1060)" \
  "heightbattle|height_battle|106|150|1063|420|1050|1068" "cnode: height battle won by a block 3 s later, its header first"
assert_eq "$(status_of 1070)|$(detail "reason,forge_ms,winner_slot,winner_ms" 1070)" \
  "heightbattle|height_battle|120|1068|2600" "cnode: height battle won by a block fetched 0.6 s into our slot, no header logged"
assert_eq "$(status_of 1080)|$(detail "reason,parent,winner_slot" 1080)" \
  "ghosted|fork|$(hash_of d 108)|1082" "cnode: built on a block that lost a fork"
assert_eq "$(status_of 1090)|$(detail "reason,prev_slot,next_slot,hash" 1090)" \
  "missed|NodeCannotForge|1082|1100|" "cnode: missed with the node's reason"
assert_eq "$(status_of 1095)|$(sqlite3 "${BLOCKLOG_DB}" 'SELECT block, hash FROM blocklog WHERE slot = 1095;')|$(detail "reason,forge_ms,winner_slot,winner_ms" 1095)" \
  "heightbattle|110|$(hash_of b 110)|height_battle|90|1100|400" "cnode: forged, never seen by CNCLI, lost a height battle"
assert_eq "$(status_of 1120)|$(detail "reason,winner_slot,hash" 1120)" \
  "stolen|slot_battle|1120|" "cnode: another pool's block in our slot, ours not forged"
assert_eq "$(status_of 4800)|$(detail "hash,forge_ms" 4800)" \
  "adopted|${final_hash[139]}|50" "cnode: recent block adopted, its forge time kept"
assert_eq "$(status_of 4950)" "leader" "cnode: a recent slot without a block waits"
[[ "${cncli_output}" == *"HEIGHT BATTLE: Leader for slot '1060'"* ]] || fail "cnode: no height battle message: ${cncli_output}"

# A later re-validation, after the journal has rotated, keeps the times it showed.
: > "${JOURNAL}"
run_cncli reset >/dev/null 2>&1
assert_eq "$(status_of 1060)|$(detail "forge_ms,winner_ms" 1060)" "heightbattle|150|420" "cnode: re-validation keeps journal times"
assert_eq "$(status_of 1095)|$(detail "hash,winner_ms" 1095)" "heightbattle|$(hash_of b 110)|400" \
  "cnode: re-validation keeps a block CNCLI never saw"
assert_eq "$(status_of 1090)|$(detail "reason" 1090)" "missed|NodeCannotForge" "cnode: re-validation keeps the missed reason"

#############################################################################
# Amaru: amaru-leaderlog.sh validate
#############################################################################

load_functions "${REPO_ROOT}/scripts/amaru-helper-scripts/amaru-leaderlog.sh" \
  amaruField amaruLoadBestChain amaruBlockState amaruKoiosBlocks amaruForgeRecord amaruArrivals \
  amaruChainAt amaruChainAround amaruSaveDetail amaruSetStatus amaruValidateSlot amaruValidateRows

pool_of() { printf 'pool1%049dq%s' 0 "$1"; }   # a well-formed bech32 pool id per letter
OUR_POOL="$(pool_of p)"
# The best chain from 200 to 240, one block every 10 slots, except where a
# case needs another slot or our block.
declare -A a_slot=([206]=2063 [208]=2077 [209]=2082) a_hash=() a_pool=()
for (( height = 200; height <= 240; height++ )); do
  a_slot[${height}]="${a_slot[${height}]:-$(( 2000 + (height - 200) * 10 ))}"
  a_hash[${height}]="$(hash_of a "${height}")"
  a_pool[${height}]="$(pool_of "$(printf '%x' $(( height % 5 + 2 )))")"
done
a_hash[203]="$(hash_of b 203)"; a_pool[203]="${OUR_POOL}"
# chain_line <slot> <hash> <height> <yes|no>
chain_line() { printf '%s.%s(%s) height=%s block=yes valid=valid best-chain=%s\n' "$1" "$2" "$3" "$3" "$4"; }
amaruChain() {
  local height
  case "$1" in
    best-chain)
      printf 'Anchor:           %s\nBest tip (stored): %s.%s(240)\nBest chain length: 41\n' "${a_hash[200]}" "${a_slot[240]}" "${a_hash[240]}" ;;
    ancestors)
      case "$2" in
        "${a_hash[240]}") for (( height = 240; height >= 200; height-- )); do chain_line "${a_slot[${height}]}" "${a_hash[${height}]}" "${height}" yes; done ;;
        "$(hash_of b 206)") chain_line 2060 "$2" 206 no; chain_line "${a_slot[205]}" "${a_hash[205]}" 205 yes ;;
        "$(hash_of b 209)") chain_line 2080 "$2" 209 no; chain_line 2078 "$(hash_of d 208)" 208 no ;;
        "$(hash_of b 212)") chain_line 2120 "$2" 212 no; chain_line "${a_slot[211]}" "${a_hash[211]}" 211 yes ;;
        *) return 1 ;;
      esac ;;
  esac
}
# Koios: block_info and blocks name the pool of each block, pool_info the ticker.
curl() {
  local url="${*: -1}" payload='' argument previous=''
  for argument in "$@"; do [[ ${previous} == -d ]] && payload="${argument}"; previous="${argument}"; done
  case "${url}" in
    */block_info*)
      jq -c --argjson blocks "${KOIOS_BLOCKS}" '._block_hashes as $h | [$blocks[] | select(.hash | IN($h[]))]' <<< "${payload}" ;;
    */pool_info*)
      jq -c '[._pool_bech32_ids[] | {pool_id_bech32: ., meta_json: {ticker: ("T" + .[-1:])}}]' <<< "${payload}" ;;
    *) printf '[]\n' ;;
  esac
}
KOIOS_API="https://koios.invalid/api/v1"
KOIOS_BLOCKS="$(for (( height = 200; height <= 240; height++ )); do
  printf '{"hash":"%s","abs_slot":%s,"block_height":%s,"pool":"%s"}\n' "${a_hash[${height}]}" "${a_slot[${height}]}" "${height}" "${a_pool[${height}]}"
done | jq -sc .)"

amaru_line() { printf '%s ai-playground amaru[7]: %s  %s %s\n' "$(slot_unix "$1" "$2")" "$(slot_iso "$1" "$2" | sed 's/000000Z$/000Z/')" "$3" "$4"; }
{
  amaru_line 2030 120 INFO "amaru::consensus::forge: forged slot=2030 header_hash=\"${a_hash[203]}\" parent=\"${a_hash[202]}\""
  amaru_line 2060 140 INFO "amaru::consensus::forge: forged slot=2060 header_hash=\"$(hash_of b 206)\" parent=\"${a_hash[205]}\""
  amaru_line 2063 300 INFO "amaru::blockperf: header.announced peer=\"1.2.3.4:3001\" header_hash=\"${a_hash[206]}\" rank=1 slot_latency_ms=300"
  amaru_line 2063 700 INFO "amaru::blockperf: block.received peer=\"1.2.3.4:3001\" header_hash=\"${a_hash[206]}\" rank=1 slot_latency_ms=700 fetch_latency_ms=200"
  amaru_line 2040 450 INFO "amaru::blockperf: block.received peer=\"1.2.3.4:3001\" header_hash=\"${a_hash[204]}\" rank=1 slot_latency_ms=450 fetch_latency_ms=200"
  amaru_line 2063 760 INFO "amaru::blockperf: block.received peer=\"1.2.3.5:3001\" header_hash=\"${a_hash[206]}\" rank=2 slot_latency_ms=760 fetch_latency_ms=210"
  amaru_line 2080 130 INFO "amaru::consensus::forge: forged slot=2080 header_hash=\"$(hash_of b 209)\" parent=\"$(hash_of d 208)\""
  amaru_line 2090 1500 WARN "amaru::consensus::forge: missed_slot slot=2090 reason=woke_late"
  amaru_line 2120 110 INFO "amaru::consensus::forge: forged slot=2120 header_hash=\"$(hash_of b 212)\" parent=\"${a_hash[211]}\""
  amaru_line 2150 100 ERROR "amaru::consensus::forge: forge_failed slot=2150 step=store_header error=\"disk full\""
  amaru_line 2450 80 INFO "amaru::consensus::forge: forged slot=2450 header_hash=\"$(hash_of b 245)\" parent=\"${a_hash[240]}\""
} > "${JOURNAL}"

new_blocklog amaru
for slot in 2030 2060 2080 2090 2120 2150 2175 2450; do add_leader_slot "${slot}"; done
AMARU_NODE_UNIT=amaru
LEADERLOG_AMARU_DB_CHAIN=/nonexistent
CONFIRM_SLOT_CNT=100
slotnum=2500
amaru_output="$(amaruValidateRows "1" 2>&1)"

assert_eq "$(status_of 2030)|$(sqlite3 "${BLOCKLOG_DB}" 'SELECT block FROM blocklog WHERE slot = 2030;')|$(detail "forge_ms,prev_slot,prev_ticker,next_slot,next_ms,winner_hash" 2030)" \
  "confirmed|203|120|2020|T4|2040|450|" "amaru: our block on the chain, the next block's body time without a header"
assert_eq "$(status_of 2060)|$(detail "reason,block,forge_ms,winner_slot,winner_pool,winner_ticker,winner_ms" 2060)" \
  "heightbattle|height_battle|206|140|2063|${a_pool[206]}|T3|300" "amaru: height battle with the winner's pool and header arrival"
assert_eq "$(status_of 2080)|$(detail "reason,winner_slot" 2080)" "ghosted|fork|2082" "amaru: built on a block that lost a fork"
assert_eq "$(status_of 2090)|$(detail "reason,prev_slot,next_slot" 2090)" "missed|woke_late|2082|2100" "amaru: missed with Amaru's reason"
assert_eq "$(status_of 2120)|$(detail "reason,winner_slot,winner_pool" 2120)" \
  "stolen|slot_battle|2120|${a_pool[212]}" "amaru: slot battle"
assert_eq "$(status_of 2150)|$(detail "reason" 2150)" "invalid|store_header" "amaru: forging failed"
assert_eq "$(status_of 2175)|$(detail "reason" 2175)" "missed|" "amaru: no forge record at all"
assert_eq "$(status_of 2450)|$(detail "hash,forge_ms" 2450)" "adopted|$(hash_of b 245)|80" "amaru: recent block forged, waiting"
[[ "${amaru_output}" == *"HEIGHT BATTLE: Leader for slot '2060'"* ]] || fail "amaru: no height battle message: ${amaru_output}"

: > "${JOURNAL}"
amaruValidateRows "1" reset >/dev/null 2>&1
assert_eq "$(status_of 2060)|$(detail "forge_ms,winner_ms" 2060)" "heightbattle|140|300" "amaru: re-validation keeps journal times"
assert_eq "$(status_of 2090)|$(detail "reason" 2090)" "missed|woke_late" "amaru: re-validation keeps the missed reason"

# The field reader takes text and JSON traces.
value=''
amaruField value header_hash 'forged slot=5 header_hash="abc" parent=def'
assert_eq "${value}" "abc" "text trace field"
amaruField value parent 'forged slot=5 header_hash="abc" parent=def'
assert_eq "${value}" "def" "unquoted text trace field"
amaruField value slot '{"fields":{"message":"forged","slot":5,"header_hash":"abc"}}'
assert_eq "${value}" "5" "JSON trace field"
amaruField value slot 'block.received slot_latency_ms=700'
assert_eq "${value}" "" "a field name inside another is no match"

if (( failures > 0 )); then
  printf '%s block validation checks failed\n' "${failures}" >&2
  exit 1
fi
printf 'block validation tests passed\n'
