#!/usr/bin/env bash
# Prove that the temporary Stage 2 compatibility split is byte-for-byte and
# source-time compatible with the frozen CNTools 13.5.7 monolith. This suite is
# intentionally independent of the deployment and payload validators.
# shellcheck disable=SC1090,SC1091,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools library split contract tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

LC_ALL=C
export LC_ALL

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
FACADE_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools.library"
FUNCTION_FIXTURE="${REPO_ROOT}/files/tests/fixtures/cntools-library-functions.txt"
BUNDLE_ID="15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f"
BUNDLE_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/${BUNDLE_ID}"
LOGICAL_BODY_SIZE=278034
LOGICAL_BODY_SHA256="c9c900b9f14399d024dea9b5b10184ebbdebdaed7d8cba1c246d69ca37971408"
MONOLITH_SIZE=278228
MONOLITH_SHA256="92e800f58948a570da401bef431d6e2449f25b337138f242ab3eeb48b0cf162b"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-split.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"

MEMBERS=(
  010-common-dialog.sh
  020-terminal-selection-security.sh
  030-governance-query.sh
  040-address-wallet-query.sh
  050-wallet-create-registration.sh
  060-wallet-actions.sh
  070-pool-actions.sh
  080-metadata-assets.sh
  090-governance-actions.sh
  100-transaction-hardware-price.sh
)
MEMBER_LINES=(344 727 740 768 584 414 527 406 521 445)
MEMBER_SIZES=(14532 31976 46236 38284 34499 18393 27577 17503 22753 22300)
MEMBER_HASHES=(
  5408355794fa187dbac5af7b66b956ab84216fd91ee4b6ec8bbe420b05fea8a7
  bb6f10e533f45cb90577e32d0d7a57ca86fe0c97d950938911be8eecec4a1460
  9e9179c73ccdd945c6ed6b7921038b7f6bc7679c4609af86565f7ad99ff8d519
  b23fdfec65fd7e991a3e46d2bef1d5c9ed09102e345cac7f3f5b75c761957df0
  a1fba108e3e9d3e8c388c54bd3a95332ee4444e61519330dd65347f4cfbe9b53
  73f150b684713b6c64211ff8c900a6deedb90a4aa15afde85dae44b8af220db5
  689a52e0e8f18a30984cebda6ef29dd929b66fb4cdba7ff03f673debb6e25257
  1444e366a79483bdcd538b59e01f8a623e3c6b4bf4fe58f5deaedc53ec247c80
  91fd56011304f4528851f8cd3b241ca63393440a51faa5c5380a22081a146ec8
  237b3847db52432ff523c36c5ca7bcb08b437f8b8978389259789a70fee5071f
)

cleanup() {
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'CNTools library split contract test failed: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" context="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

for required_command in awk cat cksum cmp comm cp diff find grep ln mkdir mv \
  readlink rm sed sort stat tail wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
if ! command -v sha256sum >/dev/null 2>&1 &&
   ! command -v shasum >/dev/null 2>&1; then
  fail "a SHA-256 command is unavailable"
fi

sha256_file() {
  local digest=""

  [[ -f "$1" && ! -L "$1" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum -- "$1")" || return 1
  else
    digest="$(shasum -a 256 -- "$1")" || return 1
  fi
  printf '%s\n' "${digest%% *}"
}

file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

marker_count() {
  local marker="$1" source_file="$2"
  awk -v marker="${marker}" '$0 == marker { count++ } END { print count + 0 }' \
    "${source_file}"
}

extract_between_markers() {
  local source_file="$1" begin_marker="$2" end_marker="$3"

  assert_eq "$(marker_count "${begin_marker}" "${source_file}")" 1 \
    "${begin_marker} marker count"
  assert_eq "$(marker_count "${end_marker}" "${source_file}")" 1 \
    "${end_marker} marker count"
  awk -v begin_marker="${begin_marker}" -v end_marker="${end_marker}" '
    $0 == begin_marker { inside=1; next }
    $0 == end_marker { inside=0; next }
    inside { print }
  ' "${source_file}"
}

reconstruct_logical_body() {
  local facade="$1" bundle="$2" output="$3" member=""
  local prefix_begin="# __CNTOOLS_LEGACY_LOGICAL_PREFIX_BEGIN__"
  local prefix_end="# __CNTOOLS_LEGACY_LOGICAL_PREFIX_END__"

  assert_eq "$(marker_count "${prefix_begin}" "${facade}")" 1 \
    "logical-prefix begin marker count"
  {
    # Original line 6 immediately precedes the injected prefix marker.
    awk -v marker="${prefix_begin}" '$0 == marker { print previous } { previous=$0 }' \
      "${facade}"
    extract_between_markers "${facade}" "${prefix_begin}" "${prefix_end}"
    extract_between_markers "${facade}" \
      "# __CNTOOLS_LEGACY_LOGICAL_INITIALIZATION_BEGIN__" \
      "# __CNTOOLS_LEGACY_LOGICAL_INITIALIZATION_END__"
    cat -- "${bundle}/${MEMBERS[0]}"
    extract_between_markers "${facade}" \
      "# __CNTOOLS_LEGACY_LOGICAL_INTERSTITIAL_BEGIN__" \
      "# __CNTOOLS_LEGACY_LOGICAL_INTERSTITIAL_END__"
    for member in "${MEMBERS[@]:1}"; do
      cat -- "${bundle}/${member}"
    done
  } > "${output}"
}

emit_bundle_identity_stream() {
  local bundle="$1" index=0 member="" member_path=""

  printf 'cntools-legacy-bundle-v1\n'
  printf 'facade\tcntools.library\n'
  printf 'logical-body\t%s\t%s\n' \
    "${LOGICAL_BODY_SIZE}" "${LOGICAL_BODY_SHA256}"
  for index in "${!MEMBERS[@]}"; do
    member="${MEMBERS[index]}"
    member_path="${bundle}/${member}"
    printf 'member\t%s\t0444\t%s\t%s\n' "${member}" \
      "$(file_size "${member_path}")" "$(sha256_file "${member_path}")"
  done
}

bundle_identity() {
  local bundle="$1" identity_stream="${TEST_ROOT}/identity-stream.$$.txt"

  emit_bundle_identity_stream "${bundle}" > "${identity_stream}"
  sha256_file "${identity_stream}"
}

assert_definition_only_member() {
  local member_path="$1" output="${TEST_ROOT}/definition-only.$$.out"

  if ! HOME="${TEST_ROOT}/definition-home" "${BASH}" --noprofile --norc -c '
    set -e
    member=$1
    mkdir -p "$HOME"
    set -f
    shopt -s nullglob
    IFS=$'"'"' \t\n:'"'"'
    set -- alpha "two words" ""
    trap : USR1
    before_pwd= before_ifs= before_options= before_shopt= before_traps=
    before_args= before_umask= before_variables=
    before_pwd=$PWD
    before_ifs=$(printf %q "$IFS")
    before_options=$(set +o)
    before_shopt=$(shopt -p)
    before_traps=$(trap -p)
    before_args=$(printf "%q " "$@")
    before_umask=$(umask)
    before_variables=$(compgen -A variable | LC_ALL=C sort)
    . "$member"
    test "$PWD" = "$before_pwd"
    test "$(printf %q "$IFS")" = "$before_ifs"
    test "$(set +o)" = "$before_options"
    test "$(shopt -p)" = "$before_shopt"
    test "$(trap -p)" = "$before_traps"
    test "$(printf "%q " "$@")" = "$before_args"
    test "$(umask)" = "$before_umask"
    test "$(compgen -A variable | LC_ALL=C sort)" = "$before_variables"
    test -z "$(find "$HOME" -mindepth 1 -print -quit)"
  ' cntools-definition-only "${member_path}" > "${output}" 2>&1; then
    sed -n '1,40p' "${output}" >&2
    fail "member is not definition-only: ${member_path##*/}"
  fi
  [[ ! -s "${output}" ]] || fail "member produced source-time output: ${member_path##*/}"
}

stage_runtime_fixture() {
  local scripts_dir="$1" destination=""

  destination="${scripts_dir}/cntools/libs/legacy/${BUNDLE_ID}"

  mkdir -p -- "${scripts_dir}/cntools/libs/legacy"
  cp -- "${FACADE_SOURCE}" "${scripts_dir}/cntools.library"
  cp -R -- "${BUNDLE_SOURCE}" "${destination}"
  chmod 0444 "${destination}"/*.sh
  chmod 0555 "${scripts_dir}/cntools" "${scripts_dir}/cntools/libs" \
    "${scripts_dir}/cntools/libs/legacy" "${destination}"
}

run_facade_inventory_probe() {
  local facade="$1" runtime_root="$2" working_directory="$3" output="$4"

  env -i PATH="${PATH}" HOME="${runtime_root}/home" \
    "${BASH}" --noprofile --norc -c '
      set -eo pipefail
      set +u
      facade=$1
      runtime=$2
      working_directory=$3
      TMP_DIR="${runtime}/tmp"
      WALLET_FOLDER="${runtime}/wallet"
      POOL_FOLDER="${runtime}/pool"
      ASSET_FOLDER="${runtime}/asset"
      LOG_DIR="${runtime}/logs"
      CNTOOLS_MODE=offline
      NETWORK_NAME=Preview
      ADVANCED_MODE=false
      ENABLE_ADVANCED=false
      ENABLE_CHATTR=false
      FG_BLUE=blue
      FG_GREEN=green
      FG_GRAY=gray
      FG_RED=red
      NC=none
      mkdir -p "$HOME" "$LOG_DIR"
      logln() { printf "preexisting-logln-sentinel\n"; }
      set -f
      shopt -s nullglob
      IFS=$'"'"' \t\n:'"'"'
      set -- alpha "two words" ""
      trap : USR1
      umask 027
      cd "$working_directory"
      before_pwd=$PWD
      before_ifs=$(printf %q "$IFS")
      before_options=$(set +o)
      before_shopt=$(shopt -p)
      before_traps=$(trap -p)
      before_aliases=$(alias -p)
      before_args=$(printf "%q " "$@")
      before_umask=$(umask)
      builtin source "$facade"
      test "$PWD" = "$before_pwd"
      test "$(printf %q "$IFS")" = "$before_ifs"
      test "$(set +o)" = "$before_options"
      test "$(shopt -p)" = "$before_shopt"
      test "$(trap -p)" = "$before_traps"
      test "$(alias -p)" = "$before_aliases"
      test "$(printf "%q " "$@")" = "$before_args"
      test "$(umask)" = "$before_umask"
      test "${TMP_DIR}" = "${runtime}/tmp/cntools"
      test "${CNTOOLS_VERSION}" = 13.5.7
      test "${CNTOOLS_MODE}" = OFFLINE
      ! declare -F __guild_cntools_legacy_bundle_15b90fa1 >/dev/null
      ! declare -f logln | grep -q preexisting-logln-sentinel
      declare -F | awk "{print \$3}" | LC_ALL=C sort
      builtin source "$facade"
      test "${TMP_DIR}" = "${runtime}/tmp/cntools/cntools"
      ! declare -F __guild_cntools_legacy_bundle_15b90fa1 >/dev/null
    ' cntools-facade-probe "${facade}" "${runtime_root}" \
      "${working_directory}" > "${output}"
}

normalize_probe_root() {
  local probe_root="$1" source_file="$2" output_file="$3"

  awk -v needle="${probe_root}" '
    function replace_literal(value, target, replacement, position) {
      while ((position = index(value, target)) != 0) {
        value = substr(value, 1, position - 1) replacement \
          substr(value, position + length(target))
      }
      return value
    }
    { print replace_literal($0, needle, "<PROBE_ROOT>") }
  ' "${source_file}" > "${output_file}"
}

run_source_state_probe() {
  local probe_root="$1" output="$2" raw_output="" facade=""

  raw_output="${output}.raw"
  facade="${probe_root}/scripts/cntools.library"

  mkdir -p "${probe_root}/cwd" "${probe_root}/runtime/home" \
    "${probe_root}/runtime/logs"
  env -i PATH="${PATH}" HOME="${probe_root}/runtime/home" \
    PROBE_FACADE="${facade}" PROBE_ROOT="${probe_root}" \
    "${BASH}" --noprofile --norc -c '
      set +e
      set +u
      set -o pipefail
      set -f
      shopt -s nullglob expand_aliases
      alias probe_alias="printf probe-alias"
      IFS=$'"'"' \t\n:'"'"'
      set -- alpha "two words" ""
      trap : USR1
      umask 027
      cd "${PROBE_ROOT}/cwd" || exit 90

      TMP_DIR="${PROBE_ROOT}/runtime/tmp"
      WALLET_FOLDER="${PROBE_ROOT}/runtime/wallet"
      POOL_FOLDER="${PROBE_ROOT}/runtime/pool"
      ASSET_FOLDER="${PROBE_ROOT}/runtime/asset"
      LOG_DIR="${PROBE_ROOT}/runtime/logs"
      CNTOOLS_MODE=offline
      NETWORK_NAME=Preview
      ADVANCED_MODE=false
      ENABLE_ADVANCED=false
      ENABLE_CHATTR=false
      FG_BLUE=blue
      FG_GREEN=green
      FG_GRAY=gray
      FG_RED=red
      NC=none
      PROBE_EXPORTED=exported-sentinel
      export PROBE_EXPORTED
      readonly PROBE_READONLY=readonly-sentinel
      logln() { printf "preexisting-logln-sentinel\n"; }

      probe_before_pwd= probe_before_ifs= probe_before_options=
      probe_before_shopt= probe_before_traps= probe_before_aliases=
      probe_before_args= probe_before_umask= probe_before_variable_names=
      probe_after_variable_names= probe_new_variable_names= probe_name=
      probe_first_status= probe_second_status= probe_first_tmp=
      probe_first_stdout="${PROBE_ROOT}/runtime/first.stdout"
      probe_first_stderr="${PROBE_ROOT}/runtime/first.stderr"
      probe_second_stdout="${PROBE_ROOT}/runtime/second.stdout"
      probe_second_stderr="${PROBE_ROOT}/runtime/second.stderr"

      probe_before_pwd=$PWD
      probe_before_ifs=$(printf %q "$IFS")
      probe_before_options=$(set +o)
      probe_before_shopt=$(shopt -p)
      probe_before_traps=$(trap -p)
      probe_before_aliases=$(alias -p)
      probe_before_args=$(printf "%q " "$@")
      probe_before_umask=$(umask)
      probe_before_variable_names=$(compgen -A variable | LC_ALL=C sort)

      builtin source "${PROBE_FACADE}" >"${probe_first_stdout}" \
        2>"${probe_first_stderr}"
      probe_first_status=$?
      test "$PWD" = "$probe_before_pwd" || exit 91
      test "$(printf %q "$IFS")" = "$probe_before_ifs" || exit 92
      test "$(set +o)" = "$probe_before_options" || exit 93
      test "$(shopt -p)" = "$probe_before_shopt" || exit 94
      test "$(trap -p)" = "$probe_before_traps" || exit 95
      test "$(alias -p)" = "$probe_before_aliases" || exit 96
      test "$(printf "%q " "$@")" = "$probe_before_args" || exit 97
      test "$(umask)" = "$probe_before_umask" || exit 98
      test "$probe_first_status" -eq 0 || exit 99
      test ! -s "$probe_first_stdout" && test ! -s "$probe_first_stderr" || exit 100
      probe_first_tmp=$TMP_DIR

      builtin source "${PROBE_FACADE}" >"${probe_second_stdout}" \
        2>"${probe_second_stderr}"
      probe_second_status=$?
      test "$PWD" = "$probe_before_pwd" || exit 101
      test "$(printf %q "$IFS")" = "$probe_before_ifs" || exit 102
      test "$(set +o)" = "$probe_before_options" || exit 103
      test "$(shopt -p)" = "$probe_before_shopt" || exit 104
      test "$(trap -p)" = "$probe_before_traps" || exit 105
      test "$(alias -p)" = "$probe_before_aliases" || exit 106
      test "$(printf "%q " "$@")" = "$probe_before_args" || exit 107
      test "$(umask)" = "$probe_before_umask" || exit 108
      test "$probe_second_status" -eq 0 || exit 109
      test ! -s "$probe_second_stdout" && test ! -s "$probe_second_stderr" || exit 110
      test "$probe_first_tmp" = "${PROBE_ROOT}/runtime/tmp/cntools" || exit 111
      test "$TMP_DIR" = "${PROBE_ROOT}/runtime/tmp/cntools/cntools" || exit 112
      ! declare -F __guild_cntools_legacy_bundle_15b90fa1 >/dev/null || exit 113
      ! declare -f logln | grep -q preexisting-logln-sentinel || exit 114

      probe_after_variable_names=$(compgen -A variable | LC_ALL=C sort)
      probe_new_variable_names=$(comm -13 \
        <(printf "%s\n" "$probe_before_variable_names") \
        <(printf "%s\n" "$probe_after_variable_names"))

      printf "first-status=%s stdout=%s stderr=%s\n" \
        "$probe_first_status" "$(wc -c < "$probe_first_stdout")" \
        "$(wc -c < "$probe_first_stderr")"
      printf "second-status=%s stdout=%s stderr=%s\n" \
        "$probe_second_status" "$(wc -c < "$probe_second_stdout")" \
        "$(wc -c < "$probe_second_stderr")"
      printf "process-state=unchanged\n"
      printf "new-globals-begin\n"
      while IFS= read -r probe_name; do
        test -n "$probe_name" || continue
        declare -p "$probe_name"
      done <<< "$probe_new_variable_names"
      printf "new-globals-end\n"
      printf "tracked-globals-begin\n"
      for probe_name in TMP_DIR WALLET_FOLDER POOL_FOLDER ASSET_FOLDER LOG_DIR \
        CNTOOLS_MODE NETWORK_NAME ADVANCED_MODE ENABLE_ADVANCED ENABLE_CHATTR \
        FG_BLUE FG_GREEN FG_GRAY FG_RED NC PROBE_EXPORTED PROBE_READONLY; do
        declare -p "$probe_name"
      done
      printf "tracked-globals-end\n"
      printf "exports-begin\n"
      export -p
      printf "exports-end\n"
      printf "readonly-begin\n"
      readonly -p
      printf "readonly-end\n"
      printf "functions-begin\n"
      while IFS= read -r probe_name; do
        declare -f "$probe_name"
      done < <(declare -F | awk "{print \$3}" | LC_ALL=C sort)
      printf "functions-end\n"
      printf "filesystem-begin\n"
      (
        cd "${PROBE_ROOT}/runtime" || exit 115
        while IFS= read -r probe_name; do
          if test -d "$probe_name"; then
            printf "directory %s\n" "$probe_name"
          elif test -f "$probe_name"; then
            printf "file %s %s\n" "$probe_name" "$(wc -c < "$probe_name")"
          else
            printf "other %s\n" "$probe_name"
          fi
        done < <(find . -mindepth 1 -print | LC_ALL=C sort)
      )
      printf "filesystem-end\n"
    ' > "${raw_output}" || {
      sed -n '1,80p' "${raw_output}" >&2
      fail "source-state probe failed for ${facade}"
    }
  normalize_probe_root "${probe_root}" "${raw_output}" "${output}"
}

snapshot_tree() {
  local root="$1" output="$2" entry=""

  (
    cd "${root}"
    while IFS= read -r entry; do
      if [[ -L "${entry}" ]]; then
        printf 'symlink %s -> %s\n' "${entry}" "$(readlink "${entry}")"
      elif [[ -d "${entry}" ]]; then
        printf 'directory %s\n' "${entry}"
      elif [[ -f "${entry}" ]]; then
        cksum "${entry}"
      else
        printf 'other %s\n' "${entry}"
      fi
    done < <(find . -mindepth 1 -print | LC_ALL=C sort)
  ) > "${output}"
}

run_early_failure_probe() {
  local node_home="$1" expected_error="$2" output_prefix="$3"

  env -i PATH="${PATH}" HOME="${node_home}/home" NODE_HOME="${node_home}" \
    "${BASH}" --noprofile --norc -c '
      set +e
      set +u
      set -o pipefail
      set -f
      shopt -s nullglob expand_aliases
      alias probe_alias="printf probe-alias"
      IFS=$'"'"' \t\n:'"'"'
      facade=$1
      runtime=$2
      stdout_file=$3
      stderr_file=$4
      set -- alpha "two words" ""
      trap : USR1
      umask 027
      TMP_DIR="${runtime}/tmp"
      WALLET_FOLDER="${runtime}/wallet"
      POOL_FOLDER="${runtime}/pool"
      ASSET_FOLDER="${runtime}/asset"
      LOG_DIR="${runtime}/logs"
      CNTOOLS_MODE=offline
      NETWORK_NAME=Preview
      ADVANCED_MODE=false
      ENABLE_ADVANCED=false
      ENABLE_CHATTR=false
      FG_BLUE=blue
      FG_GREEN=green
      FG_GRAY=gray
      FG_RED=red
      NC=none
      before_tmp=$TMP_DIR
      before_variable_names= after_variable_names= source_status=
      before_pwd=$PWD
      before_ifs=$(printf %q "$IFS")
      before_options=$(set +o)
      before_shopt=$(shopt -p)
      before_traps=$(trap -p)
      before_aliases=$(alias -p)
      before_args=$(printf "%q " "$@")
      before_umask=$(umask)
      before_variable_names=$(compgen -A variable | LC_ALL=C sort)
      builtin source "$facade" >"$stdout_file" 2>"$stderr_file"
      source_status=$?
      after_variable_names=$(compgen -A variable | LC_ALL=C sort)
      test "$source_status" -ne 0 || exit 80
      test "$TMP_DIR" = "$before_tmp" || exit 81
      test "$PWD" = "$before_pwd" || exit 82
      test "$(printf %q "$IFS")" = "$before_ifs" || exit 83
      test "$(set +o)" = "$before_options" || exit 84
      test "$(shopt -p)" = "$before_shopt" || exit 85
      test "$(trap -p)" = "$before_traps" || exit 86
      test "$(alias -p)" = "$before_aliases" || exit 87
      test "$(printf "%q " "$@")" = "$before_args" || exit 88
      test "$(umask)" = "$before_umask" || exit 89
      test "$after_variable_names" = "$before_variable_names" || exit 97
      test ! -s "$stdout_file" || exit 90
      ! declare -p CNTOOLS_MAJOR_VERSION >/dev/null 2>&1 || exit 91
      ! declare -p ESC >/dev/null 2>&1 || exit 92
      ! declare -F logln >/dev/null || exit 93
      ! declare -F __guild_cntools_legacy_bundle_15b90fa1 >/dev/null || exit 94
      test ! -e "${runtime}/tmp" && test ! -e "${runtime}/wallet" || exit 95
      test ! -e "${runtime}/pool" && test ! -e "${runtime}/asset" || exit 96
      printf "%s\n" "$source_status"
    ' cntools-early-failure "${node_home}/scripts/cntools.library" \
      "${node_home}/runtime" "${output_prefix}.stdout" \
      "${output_prefix}.stderr" > "${output_prefix}.status" ||
    fail "early-failure probe changed caller state for ${expected_error}"
  grep -Fq "${expected_error}" "${output_prefix}.stderr" || {
    sed -n '1,20p' "${output_prefix}.stderr" >&2
    fail "early-failure probe did not report ${expected_error}"
  }
}

assert_failed_fixture_unchanged() {
  local node_home="$1" expected_error="$2" case_name="$3"
  local before="${TEST_ROOT}/${case_name}.before" after="${TEST_ROOT}/${case_name}.after"

  snapshot_tree "${node_home}" "${before}"
  run_early_failure_probe "${node_home}" "${expected_error}" \
    "${TEST_ROOT}/${case_name}"
  snapshot_tree "${node_home}" "${after}"
  diff -u "${before}" "${after}" ||
    fail "failed source mutated the ${case_name} fixture"
}

run_loader_collision_probe() {
  local node_home="$1" output="${TEST_ROOT}/loader-collision"

  env -i PATH="${PATH}" HOME="${node_home}/home" NODE_HOME="${node_home}" \
    "${BASH}" --noprofile --norc -c '
      set +e
      set +u
      facade="${NODE_HOME}/scripts/cntools.library"
      TMP_DIR="${NODE_HOME}/runtime/tmp"
      WALLET_FOLDER="${NODE_HOME}/runtime/wallet"
      POOL_FOLDER="${NODE_HOME}/runtime/pool"
      ASSET_FOLDER="${NODE_HOME}/runtime/asset"
      LOG_DIR="${NODE_HOME}/runtime/logs"
      __guild_cntools_legacy_bundle_15b90fa1() {
        printf "preexisting-loader-sentinel\n"
      }
      before_function=$(declare -f __guild_cntools_legacy_bundle_15b90fa1)
      builtin source "$facade" >"$1.stdout" 2>"$1.stderr"
      source_status=$?
      after_function=$(declare -f __guild_cntools_legacy_bundle_15b90fa1)
      test "$source_status" -ne 0 || exit 70
      test "$before_function" = "$after_function" || exit 71
      test ! -s "$1.stdout" || exit 72
      ! declare -p CNTOOLS_MAJOR_VERSION >/dev/null 2>&1 || exit 73
      ! declare -p ESC >/dev/null 2>&1 || exit 74
      test ! -e "$TMP_DIR" && test ! -e "$WALLET_FOLDER" || exit 75
    ' cntools-loader-collision "${output}" ||
    fail "loader-name collision did not fail before preserving caller state"
  grep -Fq 'collides with an existing caller function' "${output}.stderr" ||
    fail "loader-name collision did not produce the expected diagnostic"
}

run_missing_middle_propagation_probe() {
  local node_home="$1" output="${TEST_ROOT}/missing-middle"

  set +e
  env -i PATH="${PATH}" HOME="${node_home}/home" NODE_HOME="${node_home}" \
    "${BASH}" --noprofile --norc -c '
      set -e
      set +u
      TMP_DIR="${NODE_HOME}/runtime/tmp"
      WALLET_FOLDER="${NODE_HOME}/runtime/wallet"
      POOL_FOLDER="${NODE_HOME}/runtime/pool"
      ASSET_FOLDER="${NODE_HOME}/runtime/asset"
      LOG_DIR="${NODE_HOME}/runtime/logs"
      CNTOOLS_MODE=offline NETWORK_NAME=Preview
      ADVANCED_MODE=false ENABLE_ADVANCED=false ENABLE_CHATTR=false
      FG_BLUE=blue FG_GREEN=green FG_GRAY=gray FG_RED=red NC=none
      myExit() { printf "myExit:%s\n" "$1"; return 42; }
      . "${NODE_HOME}/scripts/cntools.library" || myExit "$?"
      printf "main-launched\n" > "$1"
    ' cntools-missing-middle "${output}.main" > "${output}.stdout" \
      2> "${output}.stderr"
  missing_status=$?
  set -e
  assert_eq "${missing_status}" 42 "missing-middle propagated status"
  grep -Fq 'myExit:1' "${output}.stdout" ||
    fail "missing-middle failure did not reach the caller's myExit"
  [[ ! -e "${output}.main" ]] || fail "main launched after a missing member"
  [[ ! -e "${node_home}/runtime/tmp" &&
     ! -e "${node_home}/runtime/wallet" ]] ||
    fail "missing-middle failure partially initialized CNTools"
}

run_hostile_alias_probe() {
  local node_home="$1" sentinel="${TEST_ROOT}/hostile-alias.called"
  local alias_status=0

  set +e
  env -i PATH="${PATH}" HOME="${node_home}/home" NODE_HOME="${node_home}" \
    PROBE_SENTINEL="${sentinel}" \
    "${BASH}" --noprofile --norc -c '
      set +e
      set -o pipefail
      set +u
      dirname() { printf "dirname\n" >> "$PROBE_SENTINEL"; return 71; }
      find() { printf "find\n" >> "$PROBE_SENTINEL"; return 72; }
      stat() { printf "stat\n" >> "$PROBE_SENTINEL"; return 73; }
      wc() { printf "wc\n" >> "$PROBE_SENTINEL"; return 74; }
      tr() { printf "tr\n" >> "$PROBE_SENTINEL"; return 75; }
      sha256sum() { printf "sha256sum\n" >> "$PROBE_SENTINEL"; return 76; }
      shasum() { printf "shasum\n" >> "$PROBE_SENTINEL"; return 77; }
      shopt -s expand_aliases
      alias .="false #"
      alias source="false #"
      alias dirname="false #"
      alias find="false #"
      alias stat="false #"
      alias wc="false #"
      alias tr="false #"
      alias sha256sum="false #"
      alias shasum="false #"
      alias return="false #"
      TMP_DIR="${NODE_HOME}/runtime/tmp"
      WALLET_FOLDER="${NODE_HOME}/runtime/wallet"
      POOL_FOLDER="${NODE_HOME}/runtime/pool"
      ASSET_FOLDER="${NODE_HOME}/runtime/asset"
      LOG_DIR="${NODE_HOME}/runtime/logs"
      CNTOOLS_MODE=offline NETWORK_NAME=Preview
      ADVANCED_MODE=false ENABLE_ADVANCED=false ENABLE_CHATTR=false
      FG_BLUE=blue FG_GREEN=green FG_GRAY=gray FG_RED=red NC=none
      mkdir -p "$HOME" "$LOG_DIR"
      IFS=$'"'"' \t\n:'"'"'
      before_ifs=$(printf %q "$IFS")
      before_aliases=$(alias -p)
      builtin source "${NODE_HOME}/scripts/cntools.library"
      test "$?" -eq 0 || exit 81
      test "$(printf %q "$IFS")" = "$before_ifs" || exit 82
      test "$(alias -p)" = "$before_aliases" || exit 83
      test "$CNTOOLS_VERSION" = 13.5.7 || exit 84
      test ! -e "$PROBE_SENTINEL" || exit 85
    ' > "${TEST_ROOT}/hostile-alias.stdout" \
      2> "${TEST_ROOT}/hostile-alias.stderr"
  alias_status=$?
  set -e
  if (( alias_status != 0 )); then
    printf 'hostile-alias probe status: %s\n' "${alias_status}" >&2
    sed -n '1,40p' "${TEST_ROOT}/hostile-alias.stdout" >&2
    sed -n '1,40p' "${TEST_ROOT}/hostile-alias.stderr" >&2
    fail "facade was not immune to hostile aliases/functions"
  fi
  [[ ! -s "${TEST_ROOT}/hostile-alias.stdout" &&
     ! -s "${TEST_ROOT}/hostile-alias.stderr" ]] ||
    fail "hostile-alias source probe produced output"
}

make_same_size_sentinel_tamper() {
  local member_path="$1" replacement='printf command-hijack > "${PROBE_SENTINEL}"'
  local original_size="" tampered_size="" temporary="${TEST_ROOT}/same-size-tamper.$$"

  original_size="$(file_size "${member_path}")"
  awk -v replacement="${replacement}" '
    !replaced && /^#/ && length($0) >= length(replacement) {
      printf "%s", replacement
      for (i = length(replacement); i < length($0); i++)
        printf " "
      printf "\n"
      replaced=1
      next
    }
    { print }
    END { if (!replaced) exit 42 }
  ' "${member_path}" > "${temporary}" ||
    fail "could not construct the same-size command-collision tamper"
  tampered_size="$(file_size "${temporary}")"
  assert_eq "${tampered_size}" "${original_size}" \
    "command-collision tamper size"
  "${BASH}" -n "${temporary}" ||
    fail "same-size command-collision tamper does not parse"
  cp "${temporary}" "${member_path}"
  rm "${temporary}"
}

run_hostile_command_collision_probe() {
  local node_home="$1" member_path="$2" expected_hash="$3"
  local output="${TEST_ROOT}/hostile-command"
  local source_status=0

  set +e
  env -i PATH="${PATH}" HOME="${node_home}/home" NODE_HOME="${node_home}" \
    PROBE_SENTINEL="${output}.tampered-member-executed" \
    TAMPERED_MEMBER="${member_path}" EXPECTED_MEMBER_HASH="${expected_hash}" \
    "${BASH}" --noprofile --norc -c '
      set +e
      set +u
      command() {
        local candidate=""
        case "$1" in
          sha256sum|shasum)
            candidate="${!#}"
            if [[ "$candidate" == "$TAMPERED_MEMBER" ]]; then
              printf "%s  %s\n" "$EXPECTED_MEMBER_HASH" "$candidate"
              return 0
            fi
            ;;
        esac
        builtin command "$@"
      }
      TMP_DIR="${NODE_HOME}/runtime/tmp"
      WALLET_FOLDER="${NODE_HOME}/runtime/wallet"
      POOL_FOLDER="${NODE_HOME}/runtime/pool"
      ASSET_FOLDER="${NODE_HOME}/runtime/asset"
      LOG_DIR="${NODE_HOME}/runtime/logs"
      CNTOOLS_MODE=offline NETWORK_NAME=Preview
      ADVANCED_MODE=false ENABLE_ADVANCED=false ENABLE_CHATTR=false
      FG_BLUE=blue FG_GREEN=green FG_GRAY=gray FG_RED=red NC=none
      before_tmp=$TMP_DIR
      builtin source "${NODE_HOME}/scripts/cntools.library" > "$1.stdout" \
        2> "$1.stderr"
      source_status=$?
      test "$source_status" -ne 0 || exit 81
      test "$TMP_DIR" = "$before_tmp" || exit 82
      test ! -e "$PROBE_SENTINEL" || exit 83
      ! declare -p CNTOOLS_MAJOR_VERSION >/dev/null 2>&1 || exit 84
      ! declare -p ESC >/dev/null 2>&1 || exit 85
      ! declare -F logln >/dev/null || exit 86
      test ! -e "${NODE_HOME}/runtime/tmp" || exit 87
    ' cntools-hostile-command "${output}"
  source_status=$?
  set -e
  if (( source_status != 0 )); then
    printf 'hostile-command probe status: %s\n' "${source_status}" >&2
    sed -n '1,40p' "${output}.stdout" >&2
    sed -n '1,40p' "${output}.stderr" >&2
    fail "utility-name command function bypassed facade integrity validation"
  fi
  [[ ! -s "${output}.stdout" ]] ||
    fail "hostile-command rejection produced stdout"
  grep -Fq 'member failed integrity validation' "${output}.stderr" ||
    fail "hostile-command rejection did not report member integrity failure"
}

[[ -f "${FACADE_SOURCE}" && ! -L "${FACADE_SOURCE}" ]] ||
  fail "compatibility facade is missing or unsafe"
[[ -d "${BUNDLE_SOURCE}" && ! -L "${BUNDLE_SOURCE}" ]] ||
  fail "content-addressed bundle is missing or unsafe"
[[ -f "${FUNCTION_FIXTURE}" && ! -L "${FUNCTION_FIXTURE}" ]] ||
  fail "legacy function fixture is missing or unsafe"

actual_inventory="${TEST_ROOT}/bundle-inventory.actual"
printf '%s\n' "${MEMBERS[@]}" > "${TEST_ROOT}/bundle-inventory.expected"
find "${BUNDLE_SOURCE}" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; |
  LC_ALL=C sort > "${actual_inventory}"
diff -u "${TEST_ROOT}/bundle-inventory.expected" "${actual_inventory}" ||
  fail "bundle inventory is not the exact ordered ten-member contract"
[[ -z "$(find "${BUNDLE_SOURCE}" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] ||
  fail "bundle contains a non-regular entry"

for index in "${!MEMBERS[@]}"; do
  member_path="${BUNDLE_SOURCE}/${MEMBERS[index]}"
  assert_eq "$(awk 'END { print NR }' "${member_path}")" \
    "${MEMBER_LINES[index]}" "${MEMBERS[index]} line count"
  assert_eq "$(file_size "${member_path}")" "${MEMBER_SIZES[index]}" \
    "${MEMBERS[index]} size"
  assert_eq "$(sha256_file "${member_path}")" "${MEMBER_HASHES[index]}" \
    "${MEMBERS[index]} SHA-256"
  "${BASH}" -n "${member_path}" || fail "member does not parse: ${MEMBERS[index]}"
  assert_definition_only_member "${member_path}"
done

identity_stream="${TEST_ROOT}/identity-stream.txt"
emit_bundle_identity_stream "${BUNDLE_SOURCE}" > "${identity_stream}"
assert_eq "$(sha256_file "${identity_stream}")" "${BUNDLE_ID}" \
  "canonical bundle identity"

# Moving a complete final line across the 010/020 boundary preserves the raw
# concatenated bytes, but must produce a different content-addressed identity.
boundary_bundle="${TEST_ROOT}/boundary-bundle"
mkdir -p -- "${boundary_bundle}"
for member in "${MEMBERS[@]}"; do cp -- "${BUNDLE_SOURCE}/${member}" "${boundary_bundle}/${member}"; done
sed '$d' "${BUNDLE_SOURCE}/${MEMBERS[0]}" > "${boundary_bundle}/${MEMBERS[0]}"
{
  tail -n 1 "${BUNDLE_SOURCE}/${MEMBERS[0]}"
  cat -- "${BUNDLE_SOURCE}/${MEMBERS[1]}"
} > "${boundary_bundle}/${MEMBERS[1]}"
cat -- "${BUNDLE_SOURCE}/${MEMBERS[0]}" "${BUNDLE_SOURCE}/${MEMBERS[1]}" > \
  "${TEST_ROOT}/boundary-original"
cat -- "${boundary_bundle}/${MEMBERS[0]}" "${boundary_bundle}/${MEMBERS[1]}" > \
  "${TEST_ROOT}/boundary-shifted"
cmp -s "${TEST_ROOT}/boundary-original" "${TEST_ROOT}/boundary-shifted" ||
  fail "boundary adversary did not preserve concatenated bytes"
[[ "$(bundle_identity "${boundary_bundle}")" != "${BUNDLE_ID}" ]] ||
  fail "bundle identity does not bind member boundaries"

logical_body="${TEST_ROOT}/cntools.logical-body"
monolith="${TEST_ROOT}/cntools.library.monolith"
reconstruct_logical_body "${FACADE_SOURCE}" "${BUNDLE_SOURCE}" "${logical_body}"
assert_eq "$(file_size "${logical_body}")" "${LOGICAL_BODY_SIZE}" \
  "reconstructed logical-body size"
assert_eq "$(sha256_file "${logical_body}")" "${LOGICAL_BODY_SHA256}" \
  "reconstructed logical-body SHA-256"
{
  sed -n '1,5p' "${FACADE_SOURCE}"
  cat -- "${logical_body}"
} > "${monolith}"
assert_eq "$(file_size "${monolith}")" "${MONOLITH_SIZE}" \
  "reconstructed monolith size"
assert_eq "$(sha256_file "${monolith}")" "${MONOLITH_SHA256}" \
  "reconstructed monolith SHA-256"
"${BASH}" -n "${monolith}" || fail "reconstructed monolith does not parse"
mkdir -p "${TEST_ROOT}/arbitrary-cwd"

for journal_kind in file directory symlink broken-symlink; do
  journal_node="${TEST_ROOT}/journal-${journal_kind}"
  stage_runtime_fixture "${journal_node}/scripts"
  case "${journal_kind}" in
    file) : > "${journal_node}/.guild-deploy-transaction" ;;
    directory) mkdir "${journal_node}/.guild-deploy-transaction" ;;
    symlink) ln -s "${journal_node}/scripts" \
      "${journal_node}/.guild-deploy-transaction" ;;
    broken-symlink) ln -s "${journal_node}/missing-journal-target" \
      "${journal_node}/.guild-deploy-transaction" ;;
  esac
  assert_failed_fixture_unchanged "${journal_node}" "deployment journal" \
    "journal-${journal_kind}"
done

alias_node="${TEST_ROOT}/hostile-alias-node"
stage_runtime_fixture "${alias_node}/scripts"
run_hostile_alias_probe "${alias_node}"

command_collision_node="${TEST_ROOT}/hostile-command-node"
stage_runtime_fixture "${command_collision_node}/scripts"
command_collision_member="${command_collision_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}/${MEMBERS[0]}"
chmod 0644 "${command_collision_member}"
make_same_size_sentinel_tamper "${command_collision_member}"
chmod 0444 "${command_collision_member}"
assert_eq "$(file_size "${command_collision_member}")" "${MEMBER_SIZES[0]}" \
  "hostile-command member size"
[[ "$(sha256_file "${command_collision_member}")" != "${MEMBER_HASHES[0]}" ]] ||
  fail "hostile-command member tamper did not change its digest"
run_hostile_command_collision_probe "${command_collision_node}" \
  "${command_collision_member}" "${MEMBER_HASHES[0]}"

collision_node="${TEST_ROOT}/loader-collision-node"
stage_runtime_fixture "${collision_node}/scripts"
run_loader_collision_probe "${collision_node}"

for unsafe_parent in cntools cntools/libs cntools/libs/legacy; do
  case_name="unsafe-parent-${unsafe_parent//\//-}"
  unsafe_node="${TEST_ROOT}/${case_name}"
  stage_runtime_fixture "${unsafe_node}/scripts"
  chmod 0775 "${unsafe_node}/scripts/${unsafe_parent}"
  assert_failed_fixture_unchanged "${unsafe_node}" "writable by peers" \
    "${case_name}"
done

wrong_bundle_mode_node="${TEST_ROOT}/wrong-bundle-mode"
stage_runtime_fixture "${wrong_bundle_mode_node}/scripts"
chmod 0755 "${wrong_bundle_mode_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}"
assert_failed_fixture_unchanged "${wrong_bundle_mode_node}" \
  "bundle directory has invalid mode" "wrong-bundle-mode"

wrong_member_mode_node="${TEST_ROOT}/wrong-member-mode"
stage_runtime_fixture "${wrong_member_mode_node}/scripts"
chmod 0644 "${wrong_member_mode_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}/${MEMBERS[4]}"
assert_failed_fixture_unchanged "${wrong_member_mode_node}" \
  "member failed integrity validation" "wrong-member-mode"

tampered_member_node="${TEST_ROOT}/tampered-member"
stage_runtime_fixture "${tampered_member_node}/scripts"
chmod 0644 "${tampered_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}/${MEMBERS[5]}"
printf '# tampered\n' >> \
  "${tampered_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}/${MEMBERS[5]}"
chmod 0444 "${tampered_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}/${MEMBERS[5]}"
assert_failed_fixture_unchanged "${tampered_member_node}" \
  "member failed integrity validation" "tampered-member"

missing_member_node="${TEST_ROOT}/missing-member"
stage_runtime_fixture "${missing_member_node}/scripts"
chmod 0755 "${missing_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}"
rm "${missing_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}/${MEMBERS[5]}"
chmod 0555 "${missing_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}"
assert_failed_fixture_unchanged "${missing_member_node}" \
  "member is missing or unsafe" "missing-member"
run_missing_middle_propagation_probe "${missing_member_node}"

extra_member_node="${TEST_ROOT}/extra-member"
stage_runtime_fixture "${extra_member_node}/scripts"
chmod 0755 "${extra_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}"
printf '# extra\n' > \
  "${extra_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}/999-extra.sh"
chmod 0444 "${extra_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}/999-extra.sh"
chmod 0555 "${extra_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}"
assert_failed_fixture_unchanged "${extra_member_node}" \
  "unknown member" "extra-member"

symlink_member_node="${TEST_ROOT}/symlink-member"
stage_runtime_fixture "${symlink_member_node}/scripts"
chmod 0755 "${symlink_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}"
rm "${symlink_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}/${MEMBERS[6]}"
ln -s "${BUNDLE_SOURCE}/${MEMBERS[6]}" \
  "${symlink_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}/${MEMBERS[6]}"
chmod 0555 "${symlink_member_node}/scripts/cntools/libs/legacy/${BUNDLE_ID}"
assert_failed_fixture_unchanged "${symlink_member_node}" \
  "member is missing or unsafe" "symlink-member"

custom_header_node="${TEST_ROOT}/custom-header-node"
stage_runtime_fixture "${custom_header_node}/scripts"
awk 'NR == 2 { print "# Local operator merge-header customization."; next } { print }' \
  "${custom_header_node}/scripts/cntools.library" > \
  "${custom_header_node}/scripts/cntools.library.custom"
mv "${custom_header_node}/scripts/cntools.library.custom" \
  "${custom_header_node}/scripts/cntools.library"
run_facade_inventory_probe "${custom_header_node}/scripts/cntools.library" \
  "${custom_header_node}/runtime" "${TEST_ROOT}/arbitrary-cwd" \
  "${TEST_ROOT}/custom-header-functions.actual"
diff -u "${FUNCTION_FIXTURE}" "${TEST_ROOT}/custom-header-functions.actual" ||
  fail "operator merge-header customization changed the pinned bundle API"

oracle_probe_root="${TEST_ROOT}/oracle-probe"
candidate_probe_root="${TEST_ROOT}/candidate-probe"
mkdir -p "${oracle_probe_root}/scripts"
cp "${monolith}" "${oracle_probe_root}/scripts/cntools.library"
stage_runtime_fixture "${candidate_probe_root}/scripts"
run_source_state_probe "${oracle_probe_root}" \
  "${TEST_ROOT}/oracle-source-state"
run_source_state_probe "${candidate_probe_root}" \
  "${TEST_ROOT}/candidate-source-state"
diff -u "${TEST_ROOT}/oracle-source-state" \
  "${TEST_ROOT}/candidate-source-state" ||
  fail "facade source-time state differs from the frozen monolith"

runtime_scripts="${TEST_ROOT}/installed/scripts"
stage_runtime_fixture "${runtime_scripts}"
run_facade_inventory_probe "${runtime_scripts}/cntools.library" \
  "${TEST_ROOT}/runtime" "${TEST_ROOT}/arbitrary-cwd" \
  "${TEST_ROOT}/facade-functions.actual"
diff -u "${FUNCTION_FIXTURE}" "${TEST_ROOT}/facade-functions.actual" ||
  fail "facade changed the exact 121-function inventory"

# A fresh Git checkout uses ordinary 0755 directories and 0644 files. The
# facade must still be directly sourceable for development; strict 0555/0444
# enforcement applies only to installed public/generation copies.
run_facade_inventory_probe "${FACADE_SOURCE}" "${TEST_ROOT}/repo-runtime" \
  "${TEST_ROOT}/arbitrary-cwd" "${TEST_ROOT}/repo-functions.actual"
diff -u "${FUNCTION_FIXTURE}" "${TEST_ROOT}/repo-functions.actual" ||
  fail "fresh-checkout facade changed the exact 121-function inventory"

printf 'CNTools library split contract tests passed (10 members, 121 functions, %s)\n' \
  "${BUNDLE_ID}"
