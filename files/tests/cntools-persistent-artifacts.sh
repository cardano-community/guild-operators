#!/usr/bin/env bash
# Characterize CNTools persistent artifacts without keys, a node, or a network.
# shellcheck disable=SC1090,SC2016,SC2034,SC2154,SC2329
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools persistent-artifact tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MANIFEST="${REPO_ROOT}/files/tests/fixtures/cntools-persistent-artifacts.json"
ENV_LIBRARY="${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library"
CNTOOLS_LIBRARY="${REPO_ROOT}/scripts/common-helper-scripts/cntools.library"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
CNODE_ADAPTER="${REPO_ROOT}/scripts/cnode-helper-scripts/cnode.adapter"
CNCLI_SCRIPT="${REPO_ROOT}/scripts/cnode-helper-scripts/cncli.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-artifacts.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
BASE_PATH="${PATH}"
FAKE_BIN="${TEST_ROOT}/fake-bin"
UNEXPECTED_COMMAND_LOG="${TEST_ROOT}/unexpected-commands.log"

cleanup_test() {
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
  local context="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_file_exists() {
  local path="$1"
  local context="$2"
  [[ -f "${path}" ]] || fail "${context}: missing file ${path}"
}

assert_literal_matches() {
  local file="$1"
  local needle="$2"
  local minimum_matches="$3"
  local context="$4"
  local matches

  matches="$(grep -F -c -- "${needle}" "${file}" || true)"
  [[ "${matches}" =~ ^[0-9]+$ ]] ||
    fail "${context}: grep returned a non-numeric count"
  (( matches >= minimum_matches )) ||
    fail "${context}: expected at least ${minimum_matches} match(es) for '${needle}', found ${matches}"
}

assert_json_array_file() {
  local actual_file="$1"
  local jq_filter="$2"
  local context="$3"
  local differences

  if ! differences="$(
    diff -u \
      <(jq -r "${jq_filter}[]" "${MANIFEST}" | LC_ALL=C sort) \
      <(LC_ALL=C sort "${actual_file}")
  )"; then
    fail "${context}:\n${differences}"
  fi
}

assert_json_array_file_ordered() {
  local actual_file="$1"
  local jq_filter="$2"
  local context="$3"
  local differences

  if ! differences="$(
    diff -u \
      <(jq -r "${jq_filter}[]" "${MANIFEST}") \
      "${actual_file}"
  )"; then
    fail "${context}:\n${differences}"
  fi
}

file_mode() {
  local path="$1"
  local mode

  if mode="$(stat -c '%a' "${path}" 2>/dev/null)"; then
    printf '%s\n' "${mode}"
  else
    stat -f '%Lp' "${path}"
  fi
}

extract_function() {
  local function_name="$1"
  local source_file="$2"

  awk -v signature="${function_name}() {" '
    $0 == signature { emitting = 1 }
    emitting { print }
    emitting && $0 == "}" { exit }
  ' "${source_file}"
}

prepare_command_guards() {
  local command_name
  local destination

  mkdir -p "${FAKE_BIN}"
  : > "${UNEXPECTED_COMMAND_LOG}"
  for command_name in curl wget git ssh nc cardano-cli gpg chattr sudo; do
    destination="${FAKE_BIN}/${command_name}"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf "%s" "${0##*/}" >> "${CNTOOLS_UNEXPECTED_COMMAND_LOG:?}"' \
      'printf " %q" "$@" >> "${CNTOOLS_UNEXPECTED_COMMAND_LOG:?}"' \
      'printf "\n" >> "${CNTOOLS_UNEXPECTED_COMMAND_LOG:?}"' \
      'exit 97' \
      > "${destination}"
    chmod 0755 "${destination}"
  done

  export PATH="${FAKE_BIN}:${BASE_PATH}"
  export CNTOOLS_UNEXPECTED_COMMAND_LOG="${UNEXPECTED_COMMAND_LOG}"
  export http_proxy=http://127.0.0.1:9
  export https_proxy=http://127.0.0.1:9
  export HTTP_PROXY=http://127.0.0.1:9
  export HTTPS_PROXY=http://127.0.0.1:9
}

validate_manifest() {
  jq -e '
    keys == [
      "backupPolicy",
      "blocklog",
      "contract",
      "coverageGaps",
      "derivedArtifacts",
      "description",
      "filenameDefaults",
      "history",
      "knownLegacyGaps",
      "modeContracts",
      "roots",
      "schemaVersion",
      "sourceAnchors",
      "transaction"
    ] and
    .schemaVersion == 1 and
    .contract == "cntools-legacy-persistent-artifacts" and
    (.description | type == "string" and length > 0) and
    (.roots | keys == [
      "asset",
      "blocklogDatabase",
      "blocklogDirectory",
      "history",
      "pool",
      "preRestoreArchive",
      "temporaryBase",
      "temporaryRuntime",
      "wallet"
    ]) and
    (.filenameDefaults | keys == ["asset", "pool", "wallet"]) and
    (.filenameDefaults.wallet | length == 38) and
    (.filenameDefaults.pool | length == 18) and
    (.filenameDefaults.asset | length == 4) and
    ([.filenameDefaults[][]] | length == 60) and
    all(.filenameDefaults[][];
      keys == ["role", "signingMaterial", "value", "variable"] and
      (.variable | test("^[A-Z][A-Z0-9_]+$")) and
      (.value | type == "string" and length > 0) and
      (.role | type == "string" and length > 0) and
      (.signingMaterial | type == "boolean")
    ) and
    ([.filenameDefaults[][] | .variable] as $variables |
      ($variables | length) == ($variables | unique | length)) and
    .derivedArtifacts.multisigPrefix == "ms_" and
    (.derivedArtifacts.multisigSigningVariants | length == 6) and
    (.transaction.cleanupRetentionBasenamePatterns == [
      "protparams.json",
      ".dialogrc",
      "offline_tx*",
      "*_cntools_backup*",
      "metadata_*",
      "asset*"
    ]) and
    ((.transaction.cleanupSample.expectedRetained +
      .transaction.cleanupSample.expectedSelectedForDeletion | sort) ==
      (.transaction.cleanupSample.files | sort)) and
    (.transaction.offlineEnvelopeSample | keys == [
      "date-created",
      "date-expire",
      "id",
      "script-file",
      "signing-file",
      "ttl",
      "type",
      "witness"
    ]) and
    (.backupPolicy.sourceRoots == ["wallet", "pool", "asset"]) and
    .backupPolicy.selection == "direct-child-directories-only" and
    .backupPolicy.rootLooseFilesIncluded == false and
    (.backupPolicy.onlineExcludedBasenames | length == 8) and
    (.backupPolicy.onlineExcludedBasenames ==
      (.backupPolicy.onlineExcludedBasenames | sort | unique)) and
    (.backupPolicy.offlineExcludedBasenames == []) and
    ((.backupPolicy.sampleTree.files -
      .backupPolicy.sampleTree.rootFilesIgnored | sort) ==
      .backupPolicy.sampleTree.expectedOfflineMembers) and
    (.backupPolicy.onlineExcludedBasenames as $excluded |
      (.backupPolicy.sampleTree.expectedOfflineMembers |
        map(select((split("/")[-1] as $name |
          $excluded | index($name)) == null)) | sort) ==
      .backupPolicy.sampleTree.expectedOnlineMembers) and
    ((.backupPolicy.sampleTree.onlineSigningMaterialStillIncluded -
      .backupPolicy.sampleTree.expectedOnlineMembers) == []) and
    (.backupPolicy.sampleTree.onlineSigningMaterialStillIncluded | length == 19) and
    (.backupPolicy.restore.duplicateRootArgumentSample.childCounts ==
      {"wallet": 2, "pool": 1, "asset": 1}) and
    (.backupPolicy.restore.duplicateRootArgumentSample.expectedArchiveArguments ==
      ["wallet", "wallet", "pool", "asset"]) and
    .history.retainedArchiveCount == 10 and
    .history.fileMode == "umask-derived" and
    .blocklog.schemaVersion == 1 and
    (.blocklog.tables | keys == [
      "blocklog",
      "epochdata",
      "replaylog",
      "statistics",
      "validationlog"
    ]) and
    (.blocklog.namedIndexes | length == 5) and
    (.blocklog.namedIndexes == (.blocklog.namedIndexes | sort | unique)) and
    (.modeContracts | length == 6) and
    all(.modeContracts[];
      (.operation | type == "string" and length > 0) and
      (.target | type == "string" and length > 0) and
      (.mode | test("^[0-7]{3}$")) and
      (.dynamicProbe | type == "boolean")
    ) and
    (.sourceAnchors | length >= 15) and
    ([.sourceAnchors[].id] as $ids |
      ($ids | length) == ($ids | unique | length)) and
    all(.sourceAnchors[];
      (.file | startswith("scripts/")) and
      (.needle | type == "string" and length > 0) and
      (.minimumMatches | type == "number" and . >= 1)
    ) and
    (.knownLegacyGaps | length == 7) and
    ([.knownLegacyGaps[].id] as $gap_ids |
      ($gap_ids | length) == ($gap_ids | unique | length)) and
    all(.knownLegacyGaps[];
      (.observation | type == "string" and length > 0) and
      (.impact | type == "string" and length > 0)
    ) and
    (.coverageGaps | length >= 7) and
    all(.coverageGaps[]; type == "string" and length > 0)
  ' "${MANIFEST}" >/dev/null || fail "persistent-artifact manifest is invalid"
}

validate_filename_defaults() {
  local domain
  local variable
  local value
  local needle

  while IFS=$'\t' read -r domain variable value; do
    needle="[[ -z \${${variable}} ]] && ${variable}=\"${value}\""
    assert_literal_matches \
      "${ENV_LIBRARY}" "${needle}" 1 \
      "${domain} filename default ${variable}"
  done < <(
    jq -r '
      .filenameDefaults | to_entries[] as $domain |
      $domain.value[] | [$domain.key, .variable, .value] | @tsv
    ' "${MANIFEST}"
  )

  assert_literal_matches \
    "${ENV_LIBRARY}" \
    '[[ -z ${WALLET_MULTISIG_PREFIX} ]] && WALLET_MULTISIG_PREFIX="ms_"' \
    1 "multisig filename prefix"
}

validate_source_anchors() {
  local anchor_id
  local relative_file
  local needle
  local minimum_matches
  local source_file

  while IFS=$'\t' read -r anchor_id relative_file needle minimum_matches; do
    source_file="${REPO_ROOT}/${relative_file}"
    assert_file_exists "${source_file}" "source anchor ${anchor_id}"
    assert_literal_matches \
      "${source_file}" "${needle}" "${minimum_matches}" \
      "source anchor ${anchor_id}"
  done < <(
    jq -r '.sourceAnchors[] |
      [.id, .file, .needle, (.minimumMatches | tostring)] | @tsv' \
      "${MANIFEST}"
  )
}

validate_online_exclusion_source() {
  local basename
  local filename_variable

  while IFS= read -r basename; do
    filename_variable="$(
      jq -er --arg basename "${basename}" '
        first(.filenameDefaults[][] | select(.value == $basename) | .variable)
      ' "${MANIFEST}"
    )" || fail "no filename variable owns online exclusion ${basename}"

    assert_literal_matches \
      "${CNTOOLS_SCRIPT}" "--exclude=\${${filename_variable}}" 1 \
      "online backup exclusion ${basename}"
    assert_literal_matches \
      "${CNTOOLS_SCRIPT}" "--exclude=\${${filename_variable}}.gpg" 1 \
      "online backup encrypted exclusion ${basename}.gpg"
  done < <(
    jq -r '.backupPolicy.onlineExcludedBasenames[] |
      select(endswith(".gpg") | not)' "${MANIFEST}"
  )
}

validate_known_undefined_hardware_names() {
  local variable

  while IFS= read -r variable; do
    assert_literal_matches \
      "${CNTOOLS_LIBRARY}" "\${${variable}}" 1 \
      "known undefined hardware filename reference ${variable}"
    if grep -Eq "(^|[^[:alnum:]_])${variable}[[:space:]]*=" "${ENV_LIBRARY}"; then
      fail "known legacy gap changed: ${variable} is now assigned in env.library"
    fi
  done < <(
    jq -r '.knownLegacyGaps[] |
      select(.id == "hardware-multisig-verification-filenames-have-no-default") |
      .variables[]' "${MANIFEST}"
  )
}

validate_library_runtime_contracts() (
  local runtime_root="${TEST_ROOT}/library-runtime"
  local artifact_file
  local actual_json
  local expected_json
  local expected_mode
  local expected_log

  shopt -s extglob
  set +u
  HOME="${runtime_root}/home"
  TMP_DIR="${runtime_root}/tmp"
  WALLET_FOLDER="${runtime_root}/wallet"
  POOL_FOLDER="${runtime_root}/pool"
  ASSET_FOLDER="${runtime_root}/asset"
  LOG_DIR="${runtime_root}/logs"
  CNTOOLS_MODE="offline"
  NETWORK_NAME="Preview"
  ADVANCED_MODE="false"
  ENABLE_ADVANCED="false"
  ENABLE_CHATTR="false"
  ENABLE_DIALOG="false"
  CHECK_KES="false"
  FG_BLUE=""
  FG_GREEN=""
  FG_GRAY=""
  FG_RED=""
  NC=""
  CURRENCY="off"
  unset CNTOOLS_LOG CURRENCY_URL TIMEOUT_NO_OF_SLOTS TX_TTL
  unset WALLET_SELECTION_FILTER_LIMIT KES_ALERT_PERIOD KES_WARNING_PERIOD
  unset CATALYST_API EXPLORER_TX
  mkdir -p "${HOME}" "${LOG_DIR}"
  umask 027

  myExit() {
    fail "cntools.library source-time initialization failed: $*"
  }

  # The source is legacy ambient-state code. Nounset is disabled only while it
  # establishes that state; all probes below return to strict mode.
  . "${CNTOOLS_LIBRARY}"
  set -u

  assert_eq "${TMP_DIR}" "${runtime_root}/tmp/cntools" \
    "CNTools runtime temporary root"
  assert_eq "${CNTOOLS_LOG}" "${runtime_root}/logs/cntools-history.log" \
    "CNTools history path"
  [[ -d "${TMP_DIR}" && -d "${WALLET_FOLDER}" &&
     -d "${POOL_FOLDER}" && -d "${ASSET_FOLDER}" ]] ||
    fail "cntools.library did not establish isolated artifact roots"

  artifact_file="${runtime_root}/mode-probe.key"
  : > "${artifact_file}"
  chmod 0666 "${artifact_file}"
  lockFile "${artifact_file}"
  assert_eq "$(file_mode "${artifact_file}")" "400" "lockFile mode"
  unlockFile "${artifact_file}"
  assert_eq "$(file_mode "${artifact_file}")" "600" "unlockFile mode"

  date() {
    case "$*" in
      '+%s') printf '%s\n' '1700000000' ;;
      '--iso-8601=s') printf '%s\n' '2023-11-14T22:13:20+00:00' ;;
      '--iso-8601=s --date=@1700003600')
        printf '%s\n' '2023-11-14T23:13:20+00:00'
        ;;
      '+%F %T %Z') printf '%s\n' '2026-08-05 12:34:56 UTC' ;;
      *) command date "$@" ;;
    esac
  }

  ttl_enter=3600
  ttl=1700003600
  buildOfflineJSON payment
  actual_json="$(jq -cS . <<< "${offlineJSON}")"
  expected_json="$(jq -cS '.transaction.offlineEnvelopeSample' "${MANIFEST}")"
  assert_eq "${actual_json}" "${expected_json}" "offline transaction envelope"

  logln INFO "persistent artifact probe"
  expected_log='2026-08-05 12:34:56 UTC [INFO]   persistent artifact probe'
  assert_eq "$(< "${CNTOOLS_LOG}")" "${expected_log}" "history log record"
  expected_mode="$(jq -r '.history.modeProbe.expectedMode' "${MANIFEST}")"
  assert_eq "$(file_mode "${CNTOOLS_LOG}")" "${expected_mode}" \
    "history log umask-derived mode"
)

validate_cleanup_predicate() (
  local cleanup_root="${TEST_ROOT}/cleanup-runtime"
  local relative_path
  local selected_file="${TEST_ROOT}/cleanup-selected.txt"
  local retained_file="${TEST_ROOT}/cleanup-retained.txt"

  while IFS= read -r relative_path; do
    mkdir -p "$(dirname "${cleanup_root}/${relative_path}")"
    printf 'temporary placeholder: %s\n' "${relative_path}" > \
      "${cleanup_root}/${relative_path}"
  done < <(jq -r '.transaction.cleanupSample.files[]' "${MANIFEST}")

  (
    cd "${cleanup_root}"
    find . -type f -not \( \
      -name 'protparams.json' -o \
      -name '.dialogrc' -o \
      -name 'offline_tx*' -o \
      -name '*_cntools_backup*' -o \
      -name 'metadata_*' -o \
      -name 'asset*' \
    \) -print | sed 's#^\./##'
  ) > "${selected_file}"
  assert_json_array_file \
    "${selected_file}" \
    '.transaction.cleanupSample.expectedSelectedForDeletion' \
    "main-menu cleanup selection"

  (
    cd "${cleanup_root}"
    find . -type f -print | sed 's#^\./##' | LC_ALL=C sort
  ) > "${retained_file}"
  assert_json_array_file \
    "${retained_file}" '.transaction.cleanupSample.files' \
    "cleanup characterization must not delete placeholder files"
)

validate_backup_membership() (
  local tree_root="${TEST_ROOT}/backup-tree"
  local restore_root="${TEST_ROOT}/backup-restore"
  local selected_file="${TEST_ROOT}/backup-selected.txt"
  local offline_members_file="${TEST_ROOT}/backup-offline-members.txt"
  local online_members_file="${TEST_ROOT}/backup-online-members.txt"
  local restored_directories_file="${TEST_ROOT}/backup-restored-directories.txt"
  local offline_archive="${TEST_ROOT}/offline-probe.tar"
  local online_archive="${TEST_ROOT}/online-probe.tar"
  local relative_path
  local root_name
  local signing_path
  local expected_mode
  local -a selected_directories=()
  local -a exclude_arguments=()

  while IFS= read -r relative_path; do
    mkdir -p "$(dirname "${tree_root}/${relative_path}")"
    printf 'non-secret placeholder: %s\n' "${relative_path}" > \
      "${tree_root}/${relative_path}"
  done < <(jq -r '.backupPolicy.sampleTree.files[]' "${MANIFEST}")

  (
    cd "${tree_root}"
    for root_name in wallet pool asset; do
      find "${root_name}" -mindepth 1 -maxdepth 1 -type d -print
    done
  ) | LC_ALL=C sort > "${selected_file}"
  assert_json_array_file \
    "${selected_file}" '.backupPolicy.sampleTree.selectedDirectories' \
    "backup direct-child selection"

  mapfile -t selected_directories < "${selected_file}"
  while IFS= read -r relative_path; do
    exclude_arguments+=("--exclude=${relative_path}")
  done < <(jq -r '.backupPolicy.onlineExcludedBasenames[]' "${MANIFEST}")

  umask 027
  (
    cd "${tree_root}"
    tar -cf "${offline_archive}" "${selected_directories[@]}"
    tar "${exclude_arguments[@]}" -cf "${online_archive}" \
      "${selected_directories[@]}"
  )

  tar -tf "${offline_archive}" |
    sed 's#^\./##' |
    awk 'length > 0 && substr($0, length($0), 1) != "/"' |
    LC_ALL=C sort > "${offline_members_file}"
  tar -tf "${online_archive}" |
    sed 's#^\./##' |
    awk 'length > 0 && substr($0, length($0), 1) != "/"' |
    LC_ALL=C sort > "${online_members_file}"

  assert_json_array_file \
    "${offline_members_file}" \
    '.backupPolicy.sampleTree.expectedOfflineMembers' \
    "offline backup membership"
  assert_json_array_file \
    "${online_members_file}" \
    '.backupPolicy.sampleTree.expectedOnlineMembers' \
    "online backup membership"

  while IFS= read -r signing_path; do
    grep -Fqx -- "${signing_path}" "${online_members_file}" ||
      fail "legacy online backup no longer includes characterized signing material ${signing_path}"
  done < <(
    jq -r '.backupPolicy.sampleTree.onlineSigningMaterialStillIncluded[]' \
      "${MANIFEST}"
  )

  expected_mode="$(jq -r '.backupPolicy.modeProbe.expectedMode' "${MANIFEST}")"
  assert_eq "$(file_mode "${offline_archive}")" "${expected_mode}" \
    "offline backup umask-derived mode"
  assert_eq "$(file_mode "${online_archive}")" "${expected_mode}" \
    "online backup umask-derived mode"

  mkdir -p "${restore_root}"
  tar -xf "${offline_archive}" -C "${restore_root}"
  (
    cd "${restore_root}"
    for root_name in wallet pool asset; do
      find "${root_name}" -mindepth 1 -maxdepth 1 -type d -print
    done
  ) | LC_ALL=C sort > "${restored_directories_file}"
  assert_json_array_file \
    "${restored_directories_file}" \
    '.backupPolicy.sampleTree.selectedDirectories' \
    "restore direct-child selection"
)

validate_pre_restore_argument_duplication() (
  local archive_root="${TEST_ROOT}/pre-restore-archive"
  local arguments_file="${TEST_ROOT}/pre-restore-arguments.txt"
  local item
  local directory
  local -a archive_list=()

  mkdir -p \
    "${archive_root}/wallet/alice" \
    "${archive_root}/wallet/bob" \
    "${archive_root}/pool/alpha" \
    "${archive_root}/asset/policy"

  (
    cd "${archive_root}"
    for item in wallet pool asset; do
      while IFS= read -r directory; do
        archive_list+=("${item}")
      done < <(
        find "${item}" -mindepth 1 -maxdepth 1 -type d -print |
          LC_ALL=C sort
      )
    done
    printf '%s\n' "${archive_list[@]}"
  ) > "${arguments_file}"

  assert_json_array_file_ordered \
    "${arguments_file}" \
    '.backupPolicy.restore.duplicateRootArgumentSample.expectedArchiveArguments' \
    "legacy pre-restore duplicate archive arguments"
)

validate_blocklog_schema() (
  local function_file="${TEST_ROOT}/create-blocklog-db.sh"
  local blocklog_root="${TEST_ROOT}/blocklog-runtime"
  local tables_file="${TEST_ROOT}/blocklog-tables.txt"
  local indexes_file="${TEST_ROOT}/blocklog-indexes.txt"
  local columns_file
  local table_name
  local expected_mode

  extract_function createBlocklogDB "${CNCLI_SCRIPT}" > "${function_file}"
  assert_literal_matches \
    "${function_file}" 'createBlocklogDB() {' 1 \
    "isolated blocklog schema function"
  . "${function_file}"

  BLOCKLOG_DIR="${blocklog_root}"
  BLOCKLOG_DB="${BLOCKLOG_DIR}/blocklog.db"
  umask 027
  createBlocklogDB >/dev/null
  assert_file_exists "${BLOCKLOG_DB}" "isolated blocklog database"
  assert_eq \
    "$(sqlite3 "${BLOCKLOG_DB}" 'PRAGMA user_version;')" \
    "$(jq -r '.blocklog.schemaVersion' "${MANIFEST}")" \
    "blocklog schema version"

  sqlite3 "${BLOCKLOG_DB}" \
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" \
    > "${tables_file}"
  assert_json_array_file "${tables_file}" '.blocklog.tables | keys' \
    "blocklog table inventory"

  while IFS= read -r table_name; do
    columns_file="${TEST_ROOT}/blocklog-columns-${table_name}.txt"
    sqlite3 "${BLOCKLOG_DB}" "PRAGMA table_info(${table_name});" |
      awk -F '|' '{ print $2 }' > "${columns_file}"
    assert_json_array_file_ordered \
      "${columns_file}" ".blocklog.tables.${table_name}" \
      "blocklog ${table_name} column inventory"
  done < <(jq -r '.blocklog.tables | keys[]' "${MANIFEST}")

  sqlite3 "${BLOCKLOG_DB}" \
    "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_autoindex_%' ORDER BY name;" \
    > "${indexes_file}"
  assert_json_array_file "${indexes_file}" '.blocklog.namedIndexes' \
    "blocklog named-index inventory"

  expected_mode="$(jq -r '.blocklog.modeProbe.expectedMode' "${MANIFEST}")"
  assert_eq "$(file_mode "${BLOCKLOG_DB}")" "${expected_mode}" \
    "blocklog database umask-derived mode"
)

for required_command in awk diff dirname find grep jq sed sort sqlite3 stat tar; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

for required_file in \
  "${MANIFEST}" \
  "${ENV_LIBRARY}" \
  "${CNTOOLS_LIBRARY}" \
  "${CNTOOLS_SCRIPT}" \
  "${CNODE_ADAPTER}" \
  "${CNCLI_SCRIPT}"; do
  assert_file_exists "${required_file}" "characterization input"
done

prepare_command_guards
validate_manifest
validate_filename_defaults
validate_source_anchors
validate_online_exclusion_source
validate_known_undefined_hardware_names
validate_library_runtime_contracts
validate_cleanup_predicate
validate_backup_membership
validate_pre_restore_argument_duplication
validate_blocklog_schema

[[ ! -s "${UNEXPECTED_COMMAND_LOG}" ]] ||
  fail "unexpected external command attempted: $(< "${UNEXPECTED_COMMAND_LOG}")"

printf 'CNTools persistent-artifact characterization: PASS\n'
