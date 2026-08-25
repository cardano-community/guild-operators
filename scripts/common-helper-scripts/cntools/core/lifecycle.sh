#!/usr/bin/env bash
# shellcheck shell=bash
# Immutable CNTools generation validation and canary pointer lifecycle.
#
# This library is safe to source: it defines functions only. Stage 1 deploys a
# candidate generation but deliberately does not call activate or rollback.

_cntools_generation_sha256() {
  local file="${1:-}"
  local digest=""

  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum -- "${file}" 2>/dev/null)" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 -- "${file}" 2>/dev/null)" || return 1
  else
    return 2
  fi
  digest="${digest%% *}"
  [[ "${digest}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s\n' "$(printf '%s' "${digest}" | tr '[:upper:]' '[:lower:]')"
}

_cntools_generation_sha256_stream() {
  local digest=""

  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum 2>/dev/null)" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 2>/dev/null)" || return 1
  else
    return 2
  fi
  digest="${digest%% *}"
  [[ "${digest}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s\n' "$(printf '%s' "${digest}" | tr '[:upper:]' '[:lower:]')"
}

_cntools_generation_file_mode() {
  local file="${1:-}"
  local mode=""

  [[ -e "${file}" && ! -L "${file}" ]] || return 1
  mode="$(find "${file}" -prune -printf '%m' 2>/dev/null)" || mode=""
  if [[ -z "${mode}" ]]; then
    if mode="$(stat -f '%Lp' "${file}" 2>/dev/null)"; then
      :
    else
      mode="$(stat -c '%a' -- "${file}" 2>/dev/null)" || return 1
    fi
  fi
  case "${mode}" in
    [0-7][0-7][0-7]) printf '0%s\n' "${mode}" ;;
    [0-7][0-7][0-7][0-7]) printf '%s\n' "${mode}" ;;
    *) return 1 ;;
  esac
}

_cntools_generation_id_valid() {
  [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]
}

_cntools_generation_relative_path_valid() {
  local path="${1:-}"
  local component=""
  local -a components=()

  [[ -n "${path}" && "${path}" != /* && "${path}" != */ &&
     "${path}" != *//* && ! "${path}" =~ [[:cntrl:]] &&
     "${path}" =~ ^[A-Za-z0-9._/+@:-]+$ ]] || return 1
  IFS='/' read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != "." &&
       "${component}" != ".." ]] || return 1
  done
}

_cntools_generation_path_has_no_symlink_components() {
  local path="${1:-}"
  local current="" component=""
  local -a components=()

  [[ "${path}" == /* && "${path}" != "/" ]] || return 1
  IFS='/' read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current}/${component}"
    [[ ! -L "${current}" ]] || return 1
    if [[ -e "${current}" && "${current}" != "${path}" ]]; then
      [[ -d "${current}" ]] || return 1
    fi
  done
}

_cntools_generation_root_validate() {
  local root="${1:-}"
  local mode=""

  [[ "${root}" == /* && "${root}" != "/" &&
     "${root}" == */scripts/.cntools &&
     -d "${root}" && ! -L "${root}" && -O "${root}" &&
     -d "${root}/generations" && ! -L "${root}/generations" &&
     -O "${root}/generations" ]] || return 2
  _cntools_generation_path_has_no_symlink_components "${root}" || return 2
  _cntools_generation_path_has_no_symlink_components "${root}/generations" ||
    return 2
  mode="$(_cntools_generation_file_mode "${root}")" || return 2
  [[ "${mode}" == "0700" ]] || return 2
  mode="$(_cntools_generation_file_mode "${root}/generations")" || return 2
  [[ "${mode}" == "0700" ]] || return 2
}

_cntools_generation_validate_json_contract() {
  local generation="${1:-}"
  local receipt="${generation}/.generation.json"
  local manifest="${generation}/cntools/manifest.json"

  jq -e -s '
    .[0] as $receipt | .[1] as $manifest |
    ($manifest.schemaVersion == 1 or $manifest.schemaVersion == 2 or
      $manifest.schemaVersion == 3) and
    ($receipt | type == "object" and
    keys == ["files", "generationIdAlgorithm", "id", "payloadManifest",
      "payloadManifestSha256", "schemaVersion", "version"] and
    .schemaVersion == $manifest.schemaVersion and
    (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    .generationIdAlgorithm == "sha256-path-mode-content-v1" and
    (.id | type == "string" and test("^[0-9a-f]{64}$")) and
    .payloadManifest == "cntools/manifest.json" and
    (.payloadManifestSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.files | type == "array" and
      length == (if $manifest.schemaVersion == 1 then 20
        elif $manifest.schemaVersion == 2 then 30 else 152 end)) and
    ([.files[].path] | length == (unique | length)) and
    ([.files[].path] == ([.files[].path] | sort)) and
    all(.files[];
      type == "object" and
      keys == ["mode", "path", "sha256", "source", "validator"] and
      (.path | type == "string" and test("^[A-Za-z0-9._/+@:-]+$") and
        (contains("//") | not) and
        (split("/") | all(. != "" and . != "." and . != ".."))) and
      (.source | type == "string" and test("^scripts/[A-Za-z0-9._/+@:-]+$") and
        (contains("//") | not) and
        (split("/") | all(. != "" and . != "." and . != ".."))) and
      (.mode == "0444" or .mode == "0555") and
      (.validator == "shell" or .validator == "json" or
        .validator == "text" or .validator == "config") and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
    ([.files[] | select(.path == "cntools/manifest.json" and
      .source == "scripts/common-helper-scripts/cntools/manifest.json" and
      .mode == "0444" and .validator == "json")] | length == 1))
  ' "${receipt}" "${manifest}" >/dev/null 2>&1
}

_cntools_generation_validate_version_handshake() {
  local generation="${1:-}"
  local version="${2:-}"
  local library="${generation}/cntools.library"
  local version_file="${generation}/cntools/VERSION"
  local major="" minor="" patch="" extra=""

  [[ -f "${library}" && ! -L "${library}" &&
     -f "${version_file}" && ! -L "${version_file}" ]] || return 2
  [[ "$(tr -d '\r\n' < "${version_file}")" == "${version}" ]] || return 2
  major="$(sed -n 's/^CNTOOLS_MAJOR_VERSION=\([0-9][0-9]*\)$/\1/p' \
    "${library}")"
  minor="$(sed -n 's/^CNTOOLS_MINOR_VERSION=\([0-9][0-9]*\)$/\1/p' \
    "${library}")"
  patch="$(sed -n 's/^CNTOOLS_PATCH_VERSION=\([0-9][0-9]*\)$/\1/p' \
    "${library}")"
  extra="$(grep -Ec '^CNTOOLS_(MAJOR|MINOR|PATCH)_VERSION=' "${library}" || true)"
  [[ "${extra}" == "3" && -n "${major}" && -n "${minor}" &&
     -n "${patch}" && "${major}.${minor}.${patch}" == "${version}" ]] ||
    return 2
}

_cntools_generation_expected_record() {
  local schema_version="${2:-}"
  local expected_bundle_id="${3:-}"
  local bundle_relative="" bundle_id="" bundle_member=""

  [[ "${schema_version}" == "1" || "${schema_version}" == "2" ||
     "${schema_version}" == "3" ]] || return 1
  case "${1:-}" in
    cntools.sh)
      printf '%s\t%s\t%s\n' \
        scripts/common-helper-scripts/cntools/launcher.sh 0555 shell
      ;;
    cntools.library)
      printf '%s\t%s\t%s\n' \
        scripts/common-helper-scripts/cntools.library 0444 shell
      ;;
    cntools.conf.example)
      printf '%s\t%s\t%s\n' \
        scripts/common-helper-scripts/cntools.conf.example 0444 config
      ;;
    cntools/VERSION)
      printf '%s\t%s\t%s\n' \
        scripts/common-helper-scripts/cntools/VERSION 0444 text
      ;;
    cntools/core/bootstrap.sh|cntools/core/config.sh|cntools/core/context.sh|cntools/core/registry.sh|cntools/core/dispatcher.sh|cntools/core/lifecycle.sh|cntools/core/result.sh)
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 shell
      ;;
    cntools/schema/module.schema.json|cntools/libs/manifest.json|cntools/modules/root/module.json|cntools/templates/action/module.json)
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 json
      ;;
    cntools/modules/root/*/module.json)
      [[ "${schema_version}" == "3" ]] || return 1
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 json
      ;;
    cntools/modules/root/*/action.sh)
      [[ "${schema_version}" == "3" ]] || return 1
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 shell
      ;;
    cntools/docs/ARCHITECTURE.md|cntools/docs/DEVELOPMENT.md|cntools/docs/TESTING.md)
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 text
      ;;
    cntools/templates/action/action.sh)
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 shell
      ;;
    cntools/libs/legacy/*/*)
      [[ "${schema_version}" == "2" || "${schema_version}" == "3" ]] ||
        return 1
      bundle_relative="${1#cntools/libs/legacy/}"
      bundle_id="${bundle_relative%%/*}"
      bundle_member="${bundle_relative#*/}"
      [[ "${#bundle_id}" == "64" && "${bundle_id}" != *[!0-9a-f]* &&
         "${bundle_id}" == "${expected_bundle_id}" &&
         "${bundle_member}" != */* ]] || return 1
      case "${bundle_member}" in
        010-common-dialog.sh|020-terminal-selection-security.sh|030-governance-query.sh|040-address-wallet-query.sh|050-wallet-create-registration.sh|060-wallet-actions.sh|070-pool-actions.sh|080-metadata-assets.sh|090-governance-actions.sh|100-transaction-hardware-price.sh) ;;
        *) return 1 ;;
      esac
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 shell
      ;;
    *) return 1 ;;
  esac
}

_cntools_generation_validate_manifest_contract() {
  local manifest="${1:-}" path="" source="" mode="" validator="" sha256=""
  local expected="" expected_source="" expected_mode="" expected_validator=""
  local count=0 expected_count=0 schema_version="" legacy_bundle_id=""
  local inventory_digest=""

  jq -e '
    def legacy_bundle_contract:
      type == "object" and
      keys == [
        "facade", "id", "idAlgorithm", "logicalBodySha256",
        "logicalBodySize", "members", "path", "schemaVersion"
      ] and
      .schemaVersion == 1 and
      .idAlgorithm == "sha256-cntools-legacy-bundle-v1" and
      (.id | type == "string" and test("^[0-9a-f]{64}$")) and
      .path == ("cntools/libs/legacy/" + .id) and
      .facade == "cntools.library" and
      (.logicalBodySize | type == "number" and . > 0 and . <= 16777216 and
        floor == .) and
      (.logicalBodySha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.members | type == "array" and length == 10) and
      ([.members[].path] == [
        "010-common-dialog.sh", "020-terminal-selection-security.sh",
        "030-governance-query.sh", "040-address-wallet-query.sh",
        "050-wallet-create-registration.sh", "060-wallet-actions.sh",
        "070-pool-actions.sh", "080-metadata-assets.sh",
        "090-governance-actions.sh", "100-transaction-hardware-price.sh"
      ]) and
      all(.members[];
        type == "object" and
        keys == ["mode", "path", "sha256", "size"] and
        .mode == "0444" and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.size | type == "number" and . > 0 and . <= 16777216 and
          floor == .));
    def legacy_file_contract($manifest):
      ([.legacyBundle.members[] as $member |
        $manifest.files[] |
        select(.path == ($manifest.legacyBundle.path + "/" + $member.path) and
          .source == ("scripts/common-helper-scripts/" +
            $manifest.legacyBundle.path + "/" + $member.path) and
          .mode == $member.mode and .validator == "shell" and
          .sha256 == $member.sha256)] | length == 10) and
      ([.files[] |
        select(.path | startswith($manifest.legacyBundle.path + "/"))] |
        length == 10) and
      ([.files[] |
        select(.path | startswith("cntools/libs/legacy/"))] | length == 10);
    . as $manifest |
    type == "object" and
    ((.schemaVersion == 1 and
      keys == [
        "compatibilityLibrary", "contextApiVersion", "entrypoint", "files",
        "generationIdAlgorithm", "libraryManifest", "moduleApiVersion",
        "moduleSchema", "releaseStage", "rootModule", "runtimeApiVersion",
        "schemaVersion", "version"
      ] and
      (.files | type == "array" and length == 19)) or
     ((.schemaVersion == 2 or .schemaVersion == 3) and
      .schemaVersion as $schema_version |
      keys == ([
        "compatibilityLibrary", "contextApiVersion", "entrypoint", "files",
        "generationIdAlgorithm", "legacyBundle", "libraryManifest",
        "moduleApiVersion", "moduleSchema"
      ] + (if $schema_version == 3 then ["moduleSchemaVersion"] else [] end) + [
        "releaseStage", "rootModule", "runtimeApiVersion", "schemaVersion",
        "version"
      ]) and
      (.files | type == "array" and
        length == (if $schema_version == 2 then 29 else 151 end)) and
      (.legacyBundle | legacy_bundle_contract) and
      legacy_file_contract($manifest))) and
    (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    .releaseStage == "shadow" and
    .runtimeApiVersion == 1 and .contextApiVersion == 1 and
    .moduleApiVersion == 1 and
    (if .schemaVersion == 3 then .moduleSchemaVersion == 2
     else has("moduleSchemaVersion") | not end) and
    .generationIdAlgorithm == "sha256-path-mode-content-v1" and
    .entrypoint == "cntools.sh" and
    .compatibilityLibrary == "cntools.library" and
    .moduleSchema == "cntools/schema/module.schema.json" and
    .libraryManifest == "cntools/libs/manifest.json" and
    .rootModule == "cntools/modules/root/module.json" and
    ([.files[].path] == ([.files[].path] | sort)) and
    ([.files[].path] | length == (unique | length)) and
    ([.files[].source] | length == (unique | length)) and
    (if .schemaVersion == 3 then
       ([.files[] | select(.path | startswith("cntools/modules/root/")) |
          select(.path | endswith("/module.json"))] | length == 69) and
       ([.files[] | select(.path | startswith("cntools/modules/root/")) |
          select(.path | endswith("/action.sh"))] | length == 54)
     else true end) and
    all(.files[];
      type == "object" and
      keys == ["mode", "path", "sha256", "source", "validator"] and
      (.path | type == "string") and (.source | type == "string") and
      (.mode == "0444" or .mode == "0555") and
      (.validator == "shell" or .validator == "json" or
        .validator == "text" or .validator == "config") and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
  ' "${manifest}" >/dev/null 2>&1 || return 2

  schema_version="$(jq -er '.schemaVersion' "${manifest}")" || return 2
  if [[ "${schema_version}" == "1" ]]; then
    expected_count=19
  elif [[ "${schema_version}" == "2" ]]; then
    expected_count=29
    legacy_bundle_id="$(jq -er '.legacyBundle.id' "${manifest}")" || return 2
  elif [[ "${schema_version}" == "3" ]]; then
    expected_count=151
    legacy_bundle_id="$(jq -er '.legacyBundle.id' "${manifest}")" || return 2
    # Bind the complete Stage 3 path allowlist (the exact Stage 2 base plus 68
    # new module metadata documents and 54 new action entrypoints). Normalize
    # only the manifest-bound content-addressed legacy bundle ID so a valid
    # later bundle revision retains the same structural allowlist.
    inventory_digest="$(jq -er --arg id "${legacy_bundle_id}" '
      .files[].path |
      sub("^cntools/libs/legacy/" + $id + "/";
        "cntools/libs/legacy/{bundle-id}/")
    ' "${manifest}" | _cntools_generation_sha256_stream)" || return 2
    [[ "${inventory_digest}" == \
       "07a70720d227054d376964dcbb01175cedb3a7ba4130a28ec3359654770f8a2c" ]] ||
      return 2
  else
    return 2
  fi

  while IFS=$'\t' read -r path source mode validator sha256; do
    [[ "${sha256}" =~ ^[0-9a-f]{64}$ ]] || return 2
    expected="$(_cntools_generation_expected_record \
      "${path}" "${schema_version}" "${legacy_bundle_id}")" || return 2
    IFS=$'\t' read -r expected_source expected_mode expected_validator \
      <<< "${expected}"
    [[ "${source}" == "${expected_source}" && "${mode}" == "${expected_mode}" &&
       "${validator}" == "${expected_validator}" ]] || return 2
    count=$((count + 1))
  done < <(jq -er '.files[] |
    [.path,.source,.mode,.validator,.sha256] | @tsv' "${manifest}")
  (( count == expected_count )) || return 2
}

# Rebuild the frozen pre-split logical body without sourcing candidate code.
# The facade sentinels deliberately exclude the transitional loader while
# retaining the historical merge marker, initialization and line 411 bridge.
_cntools_generation_validate_legacy_bundle() (
  local generation="${1:-}" manifest="${2:-}"
  local facade="${generation}/cntools.library" bundle_path="" bundle_dir=""
  local bundle_id="" bundle_id_record=""
  local member="" member_path="" member_mode="" member_size="" member_sha=""
  local actual_mode="" actual_size="" actual_sha="" canonical_id=""
  local logical_body_sha="" logical_body_size="" marker=""
  local work="" logical_body="" canonical="" inventory="" expected=""
  local sentinel=""
  local -a sentinels=(
    '# __CNTOOLS_LEGACY_LOGICAL_PREFIX_BEGIN__'
    '# __CNTOOLS_LEGACY_LOGICAL_PREFIX_END__'
    '# __CNTOOLS_LEGACY_LOGICAL_INITIALIZATION_BEGIN__'
    '# __CNTOOLS_LEGACY_LOGICAL_INITIALIZATION_END__'
    '# __CNTOOLS_LEGACY_LOGICAL_INTERSTITIAL_BEGIN__'
    '# __CNTOOLS_LEGACY_LOGICAL_INTERSTITIAL_END__'
  )

  [[ -f "${facade}" && ! -L "${facade}" && -O "${facade}" ]] || return 2
  marker='# Do NOT modify code below           #'
  [[ "$(grep -Fxc -- "${marker}" "${facade}" 2>/dev/null || true)" == "1" ]] ||
    return 2
  for sentinel in "${sentinels[@]}"; do
    [[ "$(grep -Fxc -- "${sentinel}" "${facade}" 2>/dev/null || true)" == "1" ]] ||
      return 2
  done

  bundle_id="$(jq -er '.legacyBundle.id' "${manifest}")" || return 2
  bundle_id_record="  \\builtin local bundle_id=\"${bundle_id}\""
  [[ "$(grep -Fxc -- "${bundle_id_record}" "${facade}" \
    2>/dev/null || true)" == "1" ]] || return 2
  bundle_path="$(jq -er '.legacyBundle.path' "${manifest}")" || return 2
  _cntools_generation_relative_path_valid "${bundle_path}" || return 2
  bundle_dir="${generation}/${bundle_path}"
  [[ -d "${bundle_dir}" && ! -L "${bundle_dir}" && -O "${bundle_dir}" ]] ||
    return 2
  actual_mode="$(_cntools_generation_file_mode "${bundle_dir}")" || return 2
  [[ "${actual_mode}" == "0555" ]] || return 2

  work="$(mktemp -d "${TMPDIR:-/tmp}/cntools-legacy-validation.XXXXXX")" ||
    return 2
  trap 'rm -rf -- "${work}"' EXIT
  chmod 0700 "${work}" || return 2
  logical_body="${work}/logical-body"
  canonical="${work}/canonical"
  inventory="${work}/inventory"
  expected="${work}/expected"
  : > "${logical_body}" || return 2
  : > "${expected}" || return 2

  printf '%s\n' "${marker}" >> "${logical_body}" || return 2
  awk '
    $0 == "# __CNTOOLS_LEGACY_LOGICAL_PREFIX_BEGIN__" {copy=1; next}
    $0 == "# __CNTOOLS_LEGACY_LOGICAL_PREFIX_END__" {copy=0; next}
    copy {print}
  ' "${facade}" >> "${logical_body}" || return 2
  awk '
    $0 == "# __CNTOOLS_LEGACY_LOGICAL_INITIALIZATION_BEGIN__" {copy=1; next}
    $0 == "# __CNTOOLS_LEGACY_LOGICAL_INITIALIZATION_END__" {copy=0; next}
    copy {print}
  ' "${facade}" >> "${logical_body}" || return 2

  while IFS=$'\t' read -r member member_mode member_size member_sha; do
    _cntools_generation_relative_path_valid "${member}" || return 2
    [[ "${member}" != */* && "${member_mode}" == "0444" &&
       "${member_size}" =~ ^(0|[1-9][0-9]*)$ &&
       "${member_sha}" =~ ^[0-9a-f]{64}$ ]] || return 2
    member_path="${bundle_dir}/${member}"
    [[ -f "${member_path}" && ! -L "${member_path}" && -O "${member_path}" ]] ||
      return 2
    actual_mode="$(_cntools_generation_file_mode "${member_path}")" || return 2
    actual_size="$(wc -c < "${member_path}" 2>/dev/null)" || return 2
    actual_size="${actual_size//[[:space:]]/}"
    actual_sha="$(_cntools_generation_sha256 "${member_path}")" || return 2
    [[ "${actual_mode}" == "${member_mode}" &&
       "${actual_size}" == "${member_size}" &&
       "${actual_sha}" == "${member_sha}" ]] || return 2
    printf '%s\n' "${member}" >> "${expected}" || return 2
    if [[ "${member}" == "010-common-dialog.sh" ]]; then
      cat -- "${member_path}" >> "${logical_body}" || return 2
      awk '
        $0 == "# __CNTOOLS_LEGACY_LOGICAL_INTERSTITIAL_BEGIN__" {copy=1; next}
        $0 == "# __CNTOOLS_LEGACY_LOGICAL_INTERSTITIAL_END__" {copy=0; next}
        copy {print}
      ' "${facade}" >> "${logical_body}" || return 2
    else
      cat -- "${member_path}" >> "${logical_body}" || return 2
    fi
  done < <(jq -er '.legacyBundle.members[] |
    [.path,.mode,(.size|tostring),.sha256] | @tsv' "${manifest}")

  find "${bundle_dir}" -mindepth 1 -maxdepth 1 -type f -print |
    sed "s#^${bundle_dir}/##" | LC_ALL=C sort > "${inventory}" || return 2
  LC_ALL=C sort -o "${expected}" "${expected}" || return 2
  cmp -s "${inventory}" "${expected}" || return 2
  [[ "$(find "${bundle_dir}" -mindepth 1 -maxdepth 1 ! -type f -print -quit \
    2>/dev/null)" == "" ]] || return 2

  logical_body_size="$(wc -c < "${logical_body}" 2>/dev/null)" || return 2
  logical_body_size="${logical_body_size//[[:space:]]/}"
  logical_body_sha="$(_cntools_generation_sha256 "${logical_body}")" || return 2
  [[ "$(grep -Fxc -- "${marker}" "${logical_body}" 2>/dev/null || true)" == "1" ]] ||
    return 2
  [[ "${logical_body_size}" == \
       "$(jq -er '.legacyBundle.logicalBodySize' "${manifest}")" &&
     "${logical_body_sha}" == \
       "$(jq -er '.legacyBundle.logicalBodySha256' "${manifest}")" ]] || return 2

  {
    printf 'cntools-legacy-bundle-v1\n'
    printf 'facade\t%s\n' "$(jq -er '.legacyBundle.facade' "${manifest}")" ||
      return 2
    printf 'logical-body\t%s\t%s\n' \
      "${logical_body_size}" "${logical_body_sha}"
    jq -er '.legacyBundle.members[] |
      "member\t\(.path)\t\(.mode)\t\(.size)\t\(.sha256)"' \
      "${manifest}" || return 2
  } > "${canonical}" || return 2
  canonical_id="$(_cntools_generation_sha256 "${canonical}")" || return 2
  [[ "${canonical_id}" == "$(jq -er '.legacyBundle.id' "${manifest}")" &&
     "${canonical_id}" == "${bundle_id}" &&
     "${canonical_id}" == "$(basename -- "${bundle_path}")" ]] || return 2
)

_cntools_generation_validate_metadata() {
  local generation="${1:-}"
  local manifest="${generation}/cntools/manifest.json"
  local receipt="${generation}/.generation.json"
  local library_manifest="${generation}/cntools/libs/manifest.json"
  local root_module="${generation}/cntools/modules/root/module.json"
  local schema_version=""

  _cntools_generation_validate_manifest_contract "${manifest}" || return 2
  schema_version="$(jq -er '.schemaVersion' "${manifest}")" || return 2
  if [[ "${schema_version}" == "2" || "${schema_version}" == "3" ]]; then
    _cntools_generation_validate_legacy_bundle \
      "${generation}" "${manifest}" || return 2
  fi
  jq -e -s '
    .[0] as $manifest | .[1] as $receipt |
    $manifest.version == $receipt.version and
    ($manifest.files | sort_by(.path)) ==
      ($receipt.files | map(select(.path != "cntools/manifest.json")) |
        sort_by(.path))
  ' "${manifest}" "${receipt}" >/dev/null 2>&1 || return 2
  [[ -f "${library_manifest}" && ! -L "${library_manifest}" &&
     -f "${root_module}" && ! -L "${root_module}" ]] || return 2
  # Stage 1 ships no shared modular libraries. Validate this frozen registry
  # contract as data; never source code from the generation being inspected.
  jq -e '
    type == "object" and
    keys == ["libraries", "runtimeApiVersion", "schemaVersion"] and
    .schemaVersion == 1 and .runtimeApiVersion == 1 and
    .libraries == []
  ' "${library_manifest}" >/dev/null 2>&1 || return 2
  if [[ "${schema_version}" == "3" ]]; then
    jq -e '
      type == "object" and
      keys == ["controlPolicy", "description", "id", "kind", "label",
        "schemaVersion", "visibility"] and
      .schemaVersion == 2 and .id == "root" and .kind == "menu" and
      .label == "CNTools" and .description == "CNTools application root" and
      .controlPolicy == "root" and
      (.visibility | type == "object" and
        keys == ["features", "modes", "nodeCapabilities"] and
        .modes == ["local", "light", "offline"] and
        .features == [] and .nodeCapabilities == [])
    ' "${root_module}" >/dev/null 2>&1 || return 2
  else
    # Schema 1/2 generations retain the exact v1 root metadata contract.
    jq -e '
      type == "object" and
      keys == ["description", "id", "kind", "label", "schemaVersion",
        "visibility"] and
      .schemaVersion == 1 and .id == "root" and .kind == "menu" and
      .label == "CNTools" and .description == "CNTools application root" and
      (.visibility | type == "object" and
        keys == ["features", "modes", "nodeCapabilities"] and
        .modes == ["local", "light", "offline"] and
        .features == [] and .nodeCapabilities == [])
    ' "${root_module}" >/dev/null 2>&1 || return 2
  fi
}

_cntools_generation_config_integer_valid() {
  local value="${1:-}" allow_zero="${2:-N}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
  (( 10#${value} <= 2147483647 )) || return 1
  [[ "${allow_zero}" == "Y" || "${value}" != "0" ]]
}

_cntools_generation_config_path_valid() {
  local path="${1:-}" component=""
  local -a components=()

  [[ "${path}" == /* && "${path}" != */ &&
     "${path}" =~ ^/[A-Za-z0-9._/+@:-]+$ && "${path}" != *//* ]] || return 1
  IFS='/' read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -z "${component}" ||
       ( "${component}" != "." && "${component}" != ".." ) ]] || return 1
  done
}

_cntools_generation_config_https_valid() {
  local value="${1:-}"
  local pattern='^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~%+,:@/-]*)?$'

  [[ "${value}" =~ ${pattern} ]]
}

_cntools_generation_config_value_valid() {
  local key="${1:-}" value="${2:-}" prefix="" suffix=""

  case "${key}" in
    CNTOOLS_CONFIG_VERSION) [[ "${value}" == "1" ]] ;;
    TIMEOUT_NO_OF_SLOTS|TX_TTL)
      _cntools_generation_config_integer_valid "${value}" N
      ;;
    KES_ALERT_PERIOD|KES_WARNING_PERIOD|WALLET_SELECTION_FILTER_LIMIT)
      _cntools_generation_config_integer_valid "${value}" Y
      ;;
    CHECK_KES|ENABLE_CHATTR|ENABLE_DIALOG|ENABLE_ADVANCED)
      [[ "${value}" == "true" || "${value}" == "false" ]]
      ;;
    CURRENCY)
      [[ "${value}" == "off" ||
         "${value}" =~ ^[a-z][a-z0-9_-]{0,15}$ ]]
      ;;
    CNTOOLS_MODE)
      [[ "${value}" == "local" || "${value}" == "light" ||
         "${value}" == "offline" ]]
      ;;
    CNTOOLS_LOG) _cntools_generation_config_path_valid "${value}" ;;
    CATALYST_API) _cntools_generation_config_https_valid "${value}" ;;
    EXPLORER_TX)
      _cntools_generation_config_https_valid "${value}" || return 1
      prefix="${value%%__tx_id__*}"
      [[ "${prefix}" != "${value}" ]] || return 1
      suffix="${value#*__tx_id__}"
      [[ "${suffix}" != *'__tx_id__'* ]]
      ;;
    *) return 1 ;;
  esac
}

_cntools_generation_validate_config_data() {
  local file="${1:-}" bytes="" line="" key="" value="" first_key=""
  local line_number=0
  local assignment_pattern='^([A-Z][A-Z0-9_]*)=([^[:space:]]+)$'
  local -A records=()

  [[ -f "${file}" && ! -L "${file}" ]] || return 2
  bytes="$(wc -c < "${file}" 2>/dev/null)" || return 2
  bytes="${bytes//[[:space:]]/}"
  [[ "${bytes}" =~ ^[0-9]+$ && "${bytes}" -le 32768 ]] || return 2
  if LC_ALL=C od -An -v -t u1 "${file}" 2>/dev/null |
      grep -Eq '(^|[[:space:]])0([[:space:]]|$)'; then
    return 2
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))
    [[ "${line}" != *$'\r'* ]] || return 2
    [[ "${line}" =~ ^[[:space:]]*$ ||
       "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ${assignment_pattern} ]] || return 2
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "${key}" in
      CNTOOLS_CONFIG_VERSION|TIMEOUT_NO_OF_SLOTS|CNTOOLS_LOG|CHECK_KES|KES_ALERT_PERIOD|KES_WARNING_PERIOD|TX_TTL|WALLET_SELECTION_FILTER_LIMIT|ENABLE_CHATTR|ENABLE_DIALOG|ENABLE_ADVANCED|CURRENCY|CNTOOLS_MODE|CATALYST_API|EXPLORER_TX) ;;
      *) return 2 ;;
    esac
    [[ -z "${records[${key}]+set}" ]] || return 2
    [[ -n "${first_key}" ]] || first_key="${key}"
    _cntools_generation_config_value_valid "${key}" "${value}" || return 2
    records["${key}"]="${value}"
  done < "${file}"
  [[ "${first_key}" == "CNTOOLS_CONFIG_VERSION" &&
     "${records[CNTOOLS_CONFIG_VERSION]:-}" == "1" ]]
}

# Validate a complete immutable generation. Parameters: generation directory
# and optional expected full generation ID. No state is retained by the caller.
cntools_generation_validate() (
  local generation="${1:-}"
  local expected_id="${2:-}"
  local receipt="${generation}/.generation.json"
  local manifest="${generation}/cntools/manifest.json"
  local id="" version="" manifest_hash="" receipt_manifest_hash=""
  local path="" declared_source="" mode="" validator="" expected_hash=""
  local target="" actual_hash="" actual_mode="" canonical="" actual_files=""
  local expected_files="" actual_directories="" expected_directories=""
  local calculated_id="" directory="" parent_directory=""
  local validation_tmp=""

  [[ "${generation}" == /* && "${generation}" != "/" &&
     -d "${generation}" && ! -L "${generation}" && -O "${generation}" &&
     -f "${receipt}" && ! -L "${receipt}" && -O "${receipt}" &&
     -f "${manifest}" && ! -L "${manifest}" && -O "${manifest}" ]] ||
    return 2
  _cntools_generation_path_has_no_symlink_components "${generation}" || return 2
  [[ -z "${expected_id}" ]] || _cntools_generation_id_valid "${expected_id}" ||
    return 2
  command -v jq >/dev/null 2>&1 || return 2
  _cntools_generation_validate_json_contract "${generation}" || return 2
  id="$(jq -er '.id' "${receipt}")" || return 2
  version="$(jq -er '.version' "${receipt}")" || return 2
  [[ -z "${expected_id}" || "${id}" == "${expected_id}" ]] || return 2
  [[ "$(basename -- "${generation}")" == "${id}" ]] || return 2
  actual_mode="$(_cntools_generation_file_mode "${receipt}")" || return 2
  [[ "${actual_mode}" == "0444" ]] || return 2
  manifest_hash="$(_cntools_generation_sha256 "${manifest}")" || return 2
  receipt_manifest_hash="$(jq -er '.payloadManifestSha256' "${receipt}")" ||
    return 2
  [[ "${manifest_hash}" == "${receipt_manifest_hash}" ]] || return 2

  if find "${generation}" -type l -print -quit 2>/dev/null | grep -q .; then
    return 2
  fi
  if find "${generation}" ! -type d ! -type f -print -quit 2>/dev/null |
     grep -q .; then
    return 2
  fi
  while IFS= read -r directory; do
    [[ -O "${directory}" ]] || return 2
    actual_mode="$(_cntools_generation_file_mode "${directory}")" || return 2
    [[ "${actual_mode}" == "0555" ]] || return 2
  done < <(find "${generation}" -type d -print)

  validation_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cntools-generation-validation.XXXXXX")" ||
    return 2
  trap 'rm -rf -- "${validation_tmp}"' EXIT
  chmod 0700 "${validation_tmp}" || return 2
  canonical="${validation_tmp}/canonical.tsv"
  actual_files="${validation_tmp}/actual"
  expected_files="${validation_tmp}/expected"
  actual_directories="${validation_tmp}/actual-directories"
  expected_directories="${validation_tmp}/expected-directories"
  : > "${actual_files}" || return 2
  : > "${expected_files}" || return 2
  : > "${actual_directories}" || return 2
  printf '.\n' > "${expected_directories}" || return 2

  # Trust ordering is deliberate: validate every packaged byte, mode, and the
  # content-addressed ID without sourcing code from the inspected generation.
  while IFS=$'\t' read -r path declared_source mode validator expected_hash; do
    _cntools_generation_relative_path_valid "${path}" || {
      return 2
    }
    [[ "${declared_source}" == scripts/* ]] || return 2
    target="${generation}/${path}"
    [[ -f "${target}" && ! -L "${target}" && -O "${target}" ]] || {
      return 2
    }
    actual_mode="$(_cntools_generation_file_mode "${target}")" || return 2
    actual_hash="$(_cntools_generation_sha256 "${target}")" || return 2
    [[ "${actual_mode}" == "${mode}" && "${actual_hash}" == "${expected_hash}" ]] || {
      return 2
    }
    case "${validator}" in
      shell) "${BASH:-bash}" -n "${target}" >/dev/null 2>&1 || return 2 ;;
      json) jq -e . "${target}" >/dev/null 2>&1 || return 2 ;;
      text) [[ -s "${target}" ]] || return 2 ;;
      config) [[ -s "${target}" ]] || return 2 ;;
      *) return 2 ;;
    esac
    printf '%s\t%s\t%s\n' "${path}" "${mode}" "${expected_hash}" \
      >> "${canonical}" || return 2
    printf '%s\n' "${path}" >> "${expected_files}" || return 2
    parent_directory="$(dirname -- "${path}")" || return 2
    while [[ "${parent_directory}" != "." ]]; do
      printf '%s\n' "${parent_directory}" >> "${expected_directories}" ||
        return 2
      parent_directory="$(dirname -- "${parent_directory}")" || return 2
    done
  done < <(jq -er '.files[] | [.path,.source,.mode,.validator,.sha256] | @tsv' \
    "${receipt}")
  LC_ALL=C sort -o "${canonical}" "${canonical}" || return 2
  calculated_id="$(_cntools_generation_sha256 "${canonical}")" || return 2
  [[ "${calculated_id}" == "${id}" ]] || return 2
  find "${generation}" -type f ! -path "${receipt}" -print |
    sed "s#^${generation}/##" | LC_ALL=C sort > "${actual_files}" || return 2
  LC_ALL=C sort -o "${expected_files}" "${expected_files}" || return 2
  cmp -s "${actual_files}" "${expected_files}" || return 2
  while IFS= read -r directory; do
    if [[ "${directory}" == "${generation}" ]]; then
      printf '.\n' >> "${actual_directories}" || return 2
    else
      [[ "${directory}" == "${generation}"/* ]] || return 2
      printf '%s\n' "${directory#"${generation}/"}" \
        >> "${actual_directories}" || return 2
    fi
  done < <(find "${generation}" -type d -print)
  LC_ALL=C sort -u -o "${actual_directories}" "${actual_directories}" ||
    return 2
  LC_ALL=C sort -u -o "${expected_directories}" "${expected_directories}" ||
    return 2
  cmp -s "${actual_directories}" "${expected_directories}" || return 2

  _cntools_generation_validate_version_handshake "${generation}" "${version}" ||
    return 2

  _cntools_generation_validate_config_data \
    "${generation}/cntools.conf.example" || return 2
  _cntools_generation_validate_metadata "${generation}" || return 2
)

_cntools_generation_lock_path() {
  local root="${1:-}" node_home="" canonical_home="" physical_tmp=""
  local namespace="" namespace_mode="" key="" created="N"

  [[ "${root}" == /*/scripts/.cntools && "${root}" != "/scripts/.cntools" ]] ||
    return 2
  node_home="${root%/scripts/.cntools}"
  [[ -d "${node_home}" && ! -L "${node_home}" && -O "${node_home}" ]] ||
    return 2
  _cntools_generation_path_has_no_symlink_components "${node_home}" || return 2
  canonical_home="$(cd -P -- "${node_home}" 2>/dev/null && pwd -P)" || return 2
  [[ "${root}" == "${canonical_home}/scripts/.cntools" ]] || return 2
  physical_tmp="$(cd -P -- /tmp 2>/dev/null && pwd -P)" || return 2
  [[ "${physical_tmp}" == /* && -d "${physical_tmp}" &&
     ! -L "${physical_tmp}" ]] || return 2
  namespace="${physical_tmp}/guild-cntools-generation-locks-$(id -u)"
  if [[ ! -e "${namespace}" && ! -L "${namespace}" ]]; then
    if (umask 077 && mkdir -- "${namespace}") 2>/dev/null; then
      created="Y"
    fi
  fi
  [[ -d "${namespace}" && ! -L "${namespace}" && -O "${namespace}" ]] ||
    return 2
  _cntools_generation_path_has_no_symlink_components "${namespace}" || return 2
  namespace_mode="$(_cntools_generation_file_mode "${namespace}")" || return 2
  if [[ "${created}" == "Y" ]]; then
    chmod 0700 "${namespace}" || return 2
    namespace_mode="$(_cntools_generation_file_mode "${namespace}")" || return 2
  fi
  [[ "${namespace_mode}" == "0700" ]] || return 2
  key="$(printf '%s' "${root}" | cksum |
    awk '{printf "%s-%s", $1, $2}')" || return 2
  [[ "${key}" =~ ^[0-9]+-[0-9]+$ ]] || return 2
  printf '%s/target-%s.lock\n' "${namespace}" "${key}"
}

_cntools_generation_process_identity() {
  local pid="${1:-}" stat_line="" stat_tail="" started="" checksum=""
  local -a stat_fields=()

  [[ "${pid}" =~ ^[0-9]+$ ]] || return 2
  if [[ -r "/proc/${pid}/stat" ]]; then
    IFS= read -r stat_line < "/proc/${pid}/stat" || return 1
    stat_tail="${stat_line#*) }"
    [[ "${stat_tail}" != "${stat_line}" ]] || return 1
    read -r -a stat_fields <<< "${stat_tail}"
    started="${stat_fields[19]:-}"
    [[ "${started}" =~ ^[0-9]+$ ]] || return 1
    printf 'proc-%s\n' "${started}"
    return 0
  fi
  started="$(LC_ALL=C ps -o lstart= -p "${pid}" 2>/dev/null || true)"
  [[ -n "${started//[[:space:]]/}" ]] || return 1
  checksum="$(printf '%s' "${started}" | cksum |
    awk '{printf "%s-%s", $1, $2}')" || return 1
  [[ "${checksum}" =~ ^[0-9]+-[0-9]+$ ]] || return 1
  printf 'ps-%s\n' "${checksum}"
}

_cntools_generation_lock_backend() {
  local os="" backend=""

  os="$(command -p uname -s 2>/dev/null)" || return 2
  case "${os}" in
    Linux) backend="flock" ;;
    Darwin|FreeBSD|OpenBSD|NetBSD) backend="lockf" ;;
    *) return 2 ;;
  esac
  command -v "${backend}" >/dev/null 2>&1 || return 2
  printf '%s\n' "${backend}"
}

_cntools_generation_lock_control_cleanup() {
  local lock="${1:-}" control="${2:-}" mode=""

  [[ -n "${lock}" && "${control}" == "${lock}".control.[0-9]*.* ]] ||
    return 2
  if [[ ! -e "${control}" && ! -L "${control}" ]]; then
    return 0
  fi
  [[ -d "${control}" && ! -L "${control}" && -O "${control}" ]] ||
    return 2
  mode="$(_cntools_generation_file_mode "${control}")" || return 2
  [[ "${mode}" == "0700" ]] || return 2
  if [[ -e "${control}/ready" || -L "${control}/ready" ]]; then
    [[ -f "${control}/ready" && ! -L "${control}/ready" &&
       -O "${control}/ready" ]] || return 2
    mode="$(_cntools_generation_file_mode "${control}/ready")" || return 2
    [[ "${mode}" == "0600" ]] || return 2
    rm -f -- "${control}/ready" || return 2
  fi
  rmdir -- "${control}" || return 2
}

_cntools_generation_lock_holder_stop() {
  local lock="${1:-}" control="${2:-}" holder_pid="${3:-}" status=0

  [[ -n "${lock}" && "${control}" == "${lock}".control.[0-9]*.* &&
     "${holder_pid}" =~ ^[0-9]+$ ]] || return 2
  kill -TERM "${holder_pid}" 2>/dev/null || true
  wait "${holder_pid}" 2>/dev/null || true
  _cntools_generation_lock_control_cleanup "${lock}" "${control}" || status=2
  return "${status}"
}

_cntools_generation_lock_acquire() {
  local root="${1:-}"
  local recovery_authorized="${2:-N}"
  local lock="" mode="" backend="" parent_pid="" parent_identity=""
  local control="" ready="" holder_pid="" ready_value="" ready_marker=""
  local ready_holder_pid="" holder_identity="" ready_extra="" attempt=0
  local holder_status=0 env_path="" bash_path=""
  local deployment_transaction="${root%/scripts/.cntools}/.guild-deploy-transaction"

  lock="$(_cntools_generation_lock_path "${root}")" || return 2
  _cntools_generation_path_has_no_symlink_components "${lock}" || return 2
  if [[ -e "${deployment_transaction}" ||
        -L "${deployment_transaction}" ]]; then
    [[ "${recovery_authorized}" == "Y" ]] || return 2
    [[ -d "${deployment_transaction}" &&
       ! -L "${deployment_transaction}" &&
       -O "${deployment_transaction}" ]] || return 2
  fi
  if [[ ! -e "${lock}" && ! -L "${lock}" ]]; then
    (umask 077 && set -o noclobber && : > "${lock}") 2>/dev/null || true
  fi
  [[ -f "${lock}" && ! -L "${lock}" && -O "${lock}" &&
     ! -s "${lock}" ]] || return 2
  mode="$(_cntools_generation_file_mode "${lock}")" || return 2
  [[ "${mode}" == "0600" ]] || return 2
  backend="$(_cntools_generation_lock_backend)" || return 2
  parent_pid="${BASHPID:-$$}"
  parent_identity="$(_cntools_generation_process_identity "${parent_pid}")" ||
    return 2
  env_path="$(PATH=/usr/bin:/bin:/usr/sbin:/sbin builtin type -P env \
    2>/dev/null)" || return 2
  bash_path="${BASH:-}"
  [[ "${env_path}" == /* && -f "${env_path}" && -x "${env_path}" &&
     "${bash_path}" == /* && -f "${bash_path}" && -x "${bash_path}" ]] ||
    return 2
  control="$(mktemp -d \
    "${lock}.control.${parent_pid}.XXXXXXXX")" || return 2
  chmod 0700 "${control}" || {
    rmdir -- "${control}" 2>/dev/null || true
    return 2
  }
  ready="${control}/ready"
  (umask 077 && : > "${ready}") || {
    _cntools_generation_lock_control_cleanup "${lock}" "${control}" || true
    return 2
  }
  chmod 0600 "${ready}" || {
    _cntools_generation_lock_control_cleanup "${lock}" "${control}" || true
    return 2
  }
  # The lock holder is a separate TCB process. Start it with an empty
  # environment plus the fixed system search path so no exported function,
  # BASH_ENV hook, locale control, or caller shell state can enter it.
  "${env_path}" -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C LANG=C \
    "${bash_path}" --noprofile --norc -c '
    set -u
    lock="$1"
    backend="$2"
    parent_pid="$3"
    parent_identity="$4"
    control="$5"
    ready="${control}/ready"

    holder_identity() {
      local pid="$1" stat_line="" stat_tail="" started="" checksum=""
      local -a stat_fields=()
      if [[ -r "/proc/${pid}/stat" ]]; then
        IFS= read -r stat_line < "/proc/${pid}/stat" || return 1
        stat_tail="${stat_line#*) }"
        [[ "${stat_tail}" != "${stat_line}" ]] || return 1
        read -r -a stat_fields <<< "${stat_tail}"
        started="${stat_fields[19]:-}"
        [[ "${started}" =~ ^[0-9]+$ ]] || return 1
        printf "proc-%s\n" "${started}"
        return 0
      fi
      started="$(LC_ALL=C ps -o lstart= -p "${pid}" 9>&- 2>/dev/null || true)"
      if [[ -z "${started//[[:space:]]/}" ]]; then
        return 1
      fi
      checksum="$({ exec 9>&-; printf "%s" "${started}" | cksum |
        awk '\''{printf "%s-%s", $1, $2}'\''; })" || return 1
      [[ "${checksum}" =~ ^[0-9]+-[0-9]+$ ]] || return 1
      printf "ps-%s\n" "${checksum}"
    }

    holder_cleanup() {
      trap - EXIT HUP INT TERM
      exec 9>&- 2>/dev/null || true
      rm -f -- "${ready}" 2>/dev/null || true
      rmdir -- "${control}" 2>/dev/null || true
    }
    trap holder_cleanup EXIT
    trap "exit 0" HUP INT TERM
    exec 9>>"${lock}" || exit 2
    case "${backend}" in
      flock) flock -n 9 >/dev/null 2>&1 || exit 75 ;;
      lockf) lockf -s -t 1 9 >/dev/null 2>&1 || exit 75 ;;
      *) exit 2 ;;
    esac
    holder_own_pid="${BASHPID:-$$}"
    holder_own_identity="$(holder_identity "${holder_own_pid}" 9>&-)" || exit 2
    printf "ready\t%s\t%s\n" \
      "${holder_own_pid}" "${holder_own_identity}" > "${ready}" || exit 2
    while kill -0 "${parent_pid}" 2>/dev/null; do
      current_identity="$(holder_identity "${parent_pid}" 9>&-)" || exit 0
      [[ "${current_identity}" == "${parent_identity}" ]] || exit 0
      sleep 0.2 9>&- || exit 0
    done
  ' _ "${lock}" "${backend}" "${parent_pid}" "${parent_identity}" \
    "${control}" </dev/null >/dev/null 2>&1 &
  holder_pid=$!
  while (( attempt < 70 )); do
    ready_value=""
    if [[ -f "${ready}" && ! -L "${ready}" ]]; then
      IFS= read -r ready_value < "${ready}" || true
    fi
    if [[ "${ready_value}" == ready$'\t'* ]]; then
      IFS=$'\t' read -r ready_marker ready_holder_pid holder_identity \
        ready_extra <<< "${ready_value}"
      [[ "${ready_marker}" == "ready" &&
         "${ready_holder_pid}" == "${holder_pid}" &&
         "${holder_identity}" =~ ^(proc-[0-9]+|ps-[0-9]+-[0-9]+)$ &&
         -z "${ready_extra}" ]] && break
    fi
    if ! kill -0 "${holder_pid}" 2>/dev/null; then
      if wait "${holder_pid}"; then holder_status=0; else holder_status=$?; fi
      _cntools_generation_lock_control_cleanup \
        "${lock}" "${control}" >/dev/null 2>&1 || true
      [[ ${holder_status} -eq 75 ]] && return 1
      return 2
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if [[ "${ready_marker}" != "ready" ||
        "${ready_holder_pid}" != "${holder_pid}" ||
        ! "${holder_identity}" =~ ^(proc-[0-9]+|ps-[0-9]+-[0-9]+)$ ]]; then
    _cntools_generation_lock_holder_stop \
      "${lock}" "${control}" "${holder_pid}" >/dev/null 2>&1 || true
    return 2
  fi
  CNTOOLS_GENERATION_LOCK_PATH="${lock}"
  CNTOOLS_GENERATION_LOCK_ROOT="${root}"
  CNTOOLS_GENERATION_LOCK_BACKEND="${backend}"
  CNTOOLS_GENERATION_LOCK_CONTROL="${control}"
  CNTOOLS_GENERATION_LOCK_HOLDER_PID="${holder_pid}"
  CNTOOLS_GENERATION_LOCK_HOLDER_IDENTITY="${holder_identity}"
  CNTOOLS_GENERATION_LOCK_PID="${parent_pid}"
  _cntools_generation_lock_is_owned "${root}" || {
    _cntools_generation_lock_holder_stop \
      "${lock}" "${control}" "${holder_pid}" >/dev/null 2>&1 || true
    unset CNTOOLS_GENERATION_LOCK_PATH CNTOOLS_GENERATION_LOCK_ROOT
    unset CNTOOLS_GENERATION_LOCK_BACKEND CNTOOLS_GENERATION_LOCK_CONTROL
    unset CNTOOLS_GENERATION_LOCK_HOLDER_PID
    unset CNTOOLS_GENERATION_LOCK_HOLDER_IDENTITY CNTOOLS_GENERATION_LOCK_PID
    return 2
  }
}

_cntools_generation_lock_release() {
  local root="${CNTOOLS_GENERATION_LOCK_ROOT:-}"
  local lock="${CNTOOLS_GENERATION_LOCK_PATH:-}"
  local control="${CNTOOLS_GENERATION_LOCK_CONTROL:-}"
  local holder_pid="${CNTOOLS_GENERATION_LOCK_HOLDER_PID:-}"
  local status=0

  _cntools_generation_lock_is_owned "${root}" || return 1
  _cntools_generation_lock_holder_stop \
    "${lock}" "${control}" "${holder_pid}" || status=1
  unset CNTOOLS_GENERATION_LOCK_PATH CNTOOLS_GENERATION_LOCK_ROOT
  unset CNTOOLS_GENERATION_LOCK_BACKEND CNTOOLS_GENERATION_LOCK_CONTROL
  unset CNTOOLS_GENERATION_LOCK_HOLDER_PID
  unset CNTOOLS_GENERATION_LOCK_HOLDER_IDENTITY CNTOOLS_GENERATION_LOCK_PID
  return "${status}"
}

_cntools_generation_lock_is_owned() {
  local root="${1:-}" lock="" expected_lock="" mode="" control=""
  local holder_pid="${CNTOOLS_GENERATION_LOCK_HOLDER_PID:-}" ready_value=""
  local holder_identity="${CNTOOLS_GENERATION_LOCK_HOLDER_IDENTITY:-}"
  local ready_marker="" ready_holder_pid="" ready_identity="" ready_extra=""
  local current_holder_identity=""
  local backend="${CNTOOLS_GENERATION_LOCK_BACKEND:-}"

  expected_lock="$(_cntools_generation_lock_path "${root}")" || return 1
  lock="${CNTOOLS_GENERATION_LOCK_PATH:-}"
  control="${CNTOOLS_GENERATION_LOCK_CONTROL:-}"
  [[ "${lock}" == "${expected_lock}" &&
     "${CNTOOLS_GENERATION_LOCK_ROOT:-}" == "${root}" &&
     "${CNTOOLS_GENERATION_LOCK_PID:-}" == "${BASHPID:-$$}" &&
     "${holder_pid}" =~ ^[0-9]+$ &&
     ( "${backend}" == "flock" || "${backend}" == "lockf" ) &&
     -f "${lock}" && ! -L "${lock}" && -O "${lock}" &&
     ! -s "${lock}" && -d "${control}" && ! -L "${control}" &&
     -O "${control}" && -f "${control}/ready" &&
     ! -L "${control}/ready" && -O "${control}/ready" ]] || return 1
  _cntools_generation_path_has_no_symlink_components "${lock}" || return 1
  mode="$(_cntools_generation_file_mode "${lock}")" || return 1
  [[ "${mode}" == "0600" ]] || return 1
  mode="$(_cntools_generation_file_mode "${control}")" || return 1
  [[ "${mode}" == "0700" ]] || return 1
  mode="$(_cntools_generation_file_mode "${control}/ready")" || return 1
  [[ "${mode}" == "0600" ]] || return 1
  IFS= read -r ready_value < "${control}/ready" || return 1
  IFS=$'\t' read -r ready_marker ready_holder_pid ready_identity ready_extra \
    <<< "${ready_value}"
  [[ "${ready_marker}" == "ready" && -z "${ready_extra}" &&
     "${ready_holder_pid}" == "${holder_pid}" &&
     "${ready_identity}" == "${holder_identity}" &&
     "${holder_identity}" =~ ^(proc-[0-9]+|ps-[0-9]+-[0-9]+)$ ]] || return 1
  kill -0 "${holder_pid}" 2>/dev/null || return 1
  current_holder_identity="$(_cntools_generation_process_identity \
    "${holder_pid}")" || return 1
  [[ "${current_holder_identity}" == "${holder_identity}" ]]
}

_cntools_generation_state_is_settled() {
  local root="${1:-}" unsettled=""

  [[ ! -e "${root}/.generation-transaction" &&
     ! -L "${root}/.generation-transaction" ]] || return 1
  if [[ -d "${root}" && ! -L "${root}" ]]; then
    unsettled="$(find "${root}" -mindepth 1 -maxdepth 1 \
      \( -name '.generation-transaction.new' -o \
         -name '.generation-transaction.new.*' -o \
         -name '.active' -o -name '.active.*' -o \
         -name '.previous' -o -name '.previous.*' \) -print -quit)" || return 1
    [[ -z "${unsettled}" ]] || return 1
  fi
  return 0
}

# Acquire/release APIs allow the deployment transaction to share the same
# exclusion boundary as activation, rollback, recovery, and pruning.
cntools_generation_lock_acquire() {
  local root="${1:-}"

  _cntools_generation_root_validate "${root}" || return 2
  _cntools_generation_lock_acquire "${root}" || return $?
  if ! _cntools_generation_state_is_settled "${root}"; then
    _cntools_generation_lock_release >/dev/null 2>&1 || true
    return 2
  fi
}

# Deployment acquires the private advisory lock before a fresh `.cntools` root
# exists. Recovery authorization is accepted only while the owned outer
# durable transaction exists; ordinary lifecycle callers remain excluded.
cntools_generation_deployment_lock_acquire() {
  local root="${1:-}" recovery_authorized="${2:-N}"
  local parent="${root%/.cntools}"
  local deployment_transaction="${root%/scripts/.cntools}/.guild-deploy-transaction"

  [[ "${root}" == /*/scripts/.cntools && "${root}" != "/scripts/.cntools" &&
     -d "${parent}" && ! -L "${parent}" && -O "${parent}" ]] || return 2
  _cntools_generation_path_has_no_symlink_components "${root}" || return 2
  case "${recovery_authorized}" in
    N) ;;
    Y)
      [[ -d "${deployment_transaction}" &&
         ! -L "${deployment_transaction}" &&
         -O "${deployment_transaction}" ]] || return 2
      ;;
    *) return 2 ;;
  esac
  if [[ -e "${root}" || -L "${root}" ]]; then
    _cntools_generation_root_validate "${root}" || return 2
  fi
  _cntools_generation_lock_acquire "${root}" "${recovery_authorized}" || return $?
  if ! _cntools_generation_state_is_settled "${root}"; then
    _cntools_generation_lock_release >/dev/null 2>&1 || true
    return 2
  fi
}

cntools_generation_lock_release() {
  local root="${1:-}"

  _cntools_generation_lock_is_owned "${root}" || return 2
  _cntools_generation_lock_release || return 2
}

cntools_generation_lock_is_owned() {
  _cntools_generation_lock_is_owned "${1:-}"
}

# Validate the reserved root and both canary pointers under the lifecycle lock.
# Callers already holding the lock retain it; read-only callers acquire and
# release a short-lived lock and reject every unsettled journal state.
cntools_generation_pointers_validate() {
  local root="${1:-}" acquired="N" status=0

  _cntools_generation_root_validate "${root}" || return 2
  if ! _cntools_generation_lock_is_owned "${root}"; then
    _cntools_generation_lock_acquire "${root}" || return $?
    acquired="Y"
  fi
  _cntools_generation_state_is_settled "${root}" || status=2
  if [[ ${status} -eq 0 ]]; then
    _cntools_generation_pointers_validate_unlocked "${root}" || status=$?
  fi
  if [[ "${acquired}" == "Y" ]]; then
    _cntools_generation_lock_release || [[ ${status} -ne 0 ]] || status=2
  fi
  return "${status}"
}

_cntools_generation_pointer_read() {
  local root="${1:-}"
  local name="${2:-}"
  local pointer="${root}/${name}" target="" id=""

  case "${name}" in active|previous) ;; *) return 2 ;; esac
  if [[ ! -e "${pointer}" && ! -L "${pointer}" ]]; then
    return 0
  fi
  [[ -L "${pointer}" ]] || return 2
  target="$(readlink "${pointer}")" || return 2
  [[ "${target}" =~ ^generations/([0-9a-f]{64})$ ]] || return 2
  id="${BASH_REMATCH[1]}"
  [[ -d "${root}/${target}" && ! -L "${root}/${target}" ]] || return 2
  cntools_generation_validate "${root}/${target}" "${id}" || return 2
  printf '%s\n' "${id}"
}

_cntools_generation_atomic_replace() {
  local source_path="${1:-}" target_path="${2:-}"
  local mv_help="" mv_h_probe=""

  [[ -L "${source_path}" && -n "${target_path}" ]] || return 2
  if mv --version 2>/dev/null | grep -q 'GNU coreutils'; then
    mv -Tf -- "${source_path}" "${target_path}"
    return $?
  fi
  mv_help="$(mv --help 2>&1 || true)"
  if [[ "${mv_help}" == *BusyBox* &&
        ( "${mv_help}" == *'-T'* || "${mv_help}" == *'T]'* ) ]]; then
    mv -Tf -- "${source_path}" "${target_path}"
    return $?
  fi
  mv_h_probe="$(mv -h 2>&1 || true)"
  if [[ "${mv_h_probe}" != *'illegal option'* &&
        "${mv_h_probe}" != *'invalid option'* &&
        "${mv_h_probe}" != *'unrecognized option'* ]]; then
    # BSD mv follows a target symlink to a directory unless -h is supplied.
    mv -fh -- "${source_path}" "${target_path}"
    return $?
  fi
  return 2
}

_cntools_generation_pointer_set() {
  local root="${1:-}" name="${2:-}" id="${3:-}"
  local pointer="${root}/${name}" temporary=""

  case "${name}" in active|previous) ;; *) return 2 ;; esac
  [[ ! -e "${pointer}" || -L "${pointer}" ]] || return 2
  if [[ -z "${id}" ]]; then
    [[ ! -e "${pointer}" || -L "${pointer}" ]] || return 2
    rm -f -- "${pointer}"
    return $?
  fi
  _cntools_generation_id_valid "${id}" || return 2
  cntools_generation_validate "${root}/generations/${id}" "${id}" || return 2
  temporary="${root}/.${name}.${BASHPID:-$$}.${RANDOM}"
  [[ ! -e "${temporary}" && ! -L "${temporary}" ]] || return 2
  ln -s "generations/${id}" "${temporary}" || return 2
  _cntools_generation_atomic_replace "${temporary}" "${pointer}" || {
    rm -f -- "${temporary}"
    return 2
  }
}

_cntools_generation_pointers_validate_unlocked() {
  local root="${1:-}"

  _cntools_generation_root_validate "${root}" || return 2
  _cntools_generation_pointer_read "${root}" active >/dev/null || return 2
  _cntools_generation_pointer_read "${root}" previous >/dev/null || return 2
}

_cntools_generation_journal_write() {
  local root="${1:-}" active="${2:-}" previous="${3:-}"
  local journal="${root}/.generation-transaction"
  local temporary=""

  [[ ! -e "${journal}" && ! -L "${journal}" ]] || return 2
  temporary="$(mktemp "${journal}.new.XXXXXX")" || return 2
  [[ -f "${temporary}" && ! -L "${temporary}" && -O "${temporary}" ]] || {
    rm -f -- "${temporary}" 2>/dev/null || true
    return 2
  }
  if ! printf 'schemaVersion=1\nactive=%s\nprevious=%s\n' \
      "${active:-absent}" "${previous:-absent}" > "${temporary}" ||
     ! chmod 0600 "${temporary}"; then
    rm -f -- "${temporary}" 2>/dev/null || true
    return 2
  fi
  mv -- "${temporary}" "${journal}" || {
    rm -f -- "${temporary}" 2>/dev/null || true
    return 2
  }
}

_cntools_generation_journal_file_valid() {
  local journal="${1:-}" schema="" active="" previous="" extra=""
  local mode=""

  [[ -f "${journal}" && ! -L "${journal}" && -O "${journal}" ]] || return 2
  mode="$(_cntools_generation_file_mode "${journal}")" || return 2
  [[ "${mode}" == "0600" ]] || return 2
  {
    IFS= read -r schema
    IFS= read -r active
    IFS= read -r previous
    ! IFS= read -r extra
  } < "${journal}" || return 2
  [[ "${schema}" == "schemaVersion=1" && "${active}" == active=* &&
     "${previous}" == previous=* ]] || return 2
  active="${active#active=}"
  previous="${previous#previous=}"
  [[ "${active}" == "absent" ]] || _cntools_generation_id_valid "${active}" ||
    return 2
  [[ "${previous}" == "absent" ]] ||
    _cntools_generation_id_valid "${previous}" || return 2
}

_cntools_generation_journal_orphan_cleanup() {
  local root="${1:-}" orphan=""

  while IFS= read -r orphan; do
    [[ -n "${orphan}" ]] || continue
    if _cntools_generation_journal_file_valid "${orphan}"; then
      rm -f -- "${orphan}" || return 2
    else
      printf 'CNTools: preserving unsafe generation journal temporary: %s\n' \
        "${orphan}" >&2
    fi
  done < <(find "${root}" -mindepth 1 -maxdepth 1 \
    \( -name '.generation-transaction.new' -o \
       -name '.generation-transaction.new.*' \) -print)
}

_cntools_generation_pointer_orphan_cleanup() {
  local root="${1:-}" orphan="" name="" target=""

  while IFS= read -r orphan; do
    [[ -n "${orphan}" ]] || continue
    name="$(basename -- "${orphan}")"
    [[ "${name}" =~ ^\.(active|previous)\.[0-9]+\.[0-9]+$ &&
       -L "${orphan}" ]] || return 2
    target="$(readlink "${orphan}")" || return 2
    [[ "${target}" =~ ^generations/[0-9a-f]{64}$ ]] || return 2
    rm -f -- "${orphan}" || return 2
  done < <(find "${root}" -mindepth 1 -maxdepth 1 \
    \( -name '.active' -o -name '.active.*' -o \
       -name '.previous' -o -name '.previous.*' \) -print)
}

_cntools_generation_recover_unlocked() {
  local root="${1:-}"
  local journal="${root}/.generation-transaction"
  local schema="" active="" previous="" extra=""

  _cntools_generation_journal_orphan_cleanup "${root}" || return 2
  _cntools_generation_pointer_orphan_cleanup "${root}" || return 2
  if [[ ! -e "${journal}" && ! -L "${journal}" ]]; then
    _cntools_generation_state_is_settled "${root}" || return 2
    return 0
  fi
  _cntools_generation_journal_file_valid "${journal}" || return 2
  {
    IFS= read -r schema
    IFS= read -r active
    IFS= read -r previous
    ! IFS= read -r extra
  } < "${journal}" || return 2
  [[ "${schema}" == "schemaVersion=1" && "${active}" == active=* &&
     "${previous}" == previous=* ]] || return 2
  active="${active#active=}"
  previous="${previous#previous=}"
  [[ "${active}" == "absent" ]] && active=""
  [[ "${previous}" == "absent" ]] && previous=""
  [[ -z "${active}" ]] || _cntools_generation_id_valid "${active}" || return 2
  [[ -z "${previous}" ]] || _cntools_generation_id_valid "${previous}" || return 2
  _cntools_generation_pointer_set "${root}" previous "${previous}" || return 2
  _cntools_generation_pointer_set "${root}" active "${active}" || return 2
  rm -f -- "${journal}" || return 2
  _cntools_generation_state_is_settled "${root}"
}

cntools_generation_recover() (
  local root="${1:-}" status=0
  _cntools_generation_root_validate "${root}" || return 2
  _cntools_generation_lock_acquire "${root}" || return $?
  _cntools_generation_recover_unlocked "${root}" || status=$?
  _cntools_generation_lock_release || [[ ${status} -ne 0 ]] || status=2
  return "${status}"
)

cntools_generation_activate() (
  local root="${1:-}" id="${2:-}" active="" previous="" status=0
  _cntools_generation_root_validate "${root}" || return 2
  _cntools_generation_id_valid "${id}" || return 2
  cntools_generation_validate "${root}/generations/${id}" "${id}" || return 2
  _cntools_generation_lock_acquire "${root}" || return $?
  _cntools_generation_recover_unlocked "${root}" || status=$?
  if [[ ${status} -eq 0 ]]; then
    active="$(_cntools_generation_pointer_read "${root}" active)" || status=$?
  fi
  if [[ ${status} -eq 0 ]]; then
    previous="$(_cntools_generation_pointer_read "${root}" previous)" || status=$?
  fi
  if [[ ${status} -eq 0 && "${active}" == "${id}" ]]; then
    _cntools_generation_lock_release || return 2
    return 0
  fi
  if [[ ${status} -eq 0 ]]; then
    _cntools_generation_journal_write "${root}" "${active}" "${previous}" ||
      status=$?
  fi
  if [[ ${status} -eq 0 ]]; then
    _cntools_generation_pointer_set "${root}" previous "${active}" || status=$?
  fi
  if [[ ${status} -eq 0 ]]; then
    _cntools_generation_pointer_set "${root}" active "${id}" || status=$?
  fi
  if [[ ${status} -eq 0 ]]; then
    rm -f -- "${root}/.generation-transaction" || status=$?
  else
    _cntools_generation_recover_unlocked "${root}" >/dev/null 2>&1 || true
  fi
  _cntools_generation_lock_release || [[ ${status} -ne 0 ]] || status=2
  return "${status}"
)

cntools_generation_rollback() (
  local root="${1:-}" active="" previous="" status=0
  _cntools_generation_root_validate "${root}" || return 2
  _cntools_generation_lock_acquire "${root}" || return $?
  _cntools_generation_recover_unlocked "${root}" || status=$?
  if [[ ${status} -eq 0 ]]; then
    active="$(_cntools_generation_pointer_read "${root}" active)" || status=$?
    previous="$(_cntools_generation_pointer_read "${root}" previous)" || status=$?
  fi
  if [[ ${status} -eq 0 && ( -z "${active}" || -z "${previous}" ) ]]; then
    status=1
  fi
  if [[ ${status} -eq 0 ]]; then
    _cntools_generation_journal_write "${root}" "${active}" "${previous}" ||
      status=$?
  fi
  if [[ ${status} -eq 0 ]]; then
    _cntools_generation_pointer_set "${root}" previous "${active}" || status=$?
  fi
  if [[ ${status} -eq 0 ]]; then
    _cntools_generation_pointer_set "${root}" active "${previous}" || status=$?
  fi
  if [[ ${status} -eq 0 ]]; then
    rm -f -- "${root}/.generation-transaction" || status=$?
  elif [[ -e "${root}/.generation-transaction" ]]; then
    _cntools_generation_recover_unlocked "${root}" >/dev/null 2>&1 || true
  fi
  _cntools_generation_lock_release || [[ ${status} -ne 0 ]] || status=2
  return "${status}"
)

_cntools_generation_prune_unlocked() {
  local root="${1:-}" keep_id="${2:-}" active="" previous=""
  local entry="" id="" status=0
  local -A retained=()

  _cntools_generation_id_valid "${keep_id}" || return 2
  cntools_generation_validate "${root}/generations/${keep_id}" "${keep_id}" ||
    return 2
  active="$(_cntools_generation_pointer_read "${root}" active)" || return 2
  previous="$(_cntools_generation_pointer_read "${root}" previous)" || return 2
  retained["${keep_id}"]="Y"
  [[ -z "${active}" ]] || retained["${active}"]="Y"
  [[ -z "${previous}" ]] || retained["${previous}"]="Y"

  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    id="$(basename -- "${entry}")"
    if [[ -L "${entry}" || ! -d "${entry}" || ! -O "${entry}" ]] ||
       ! _cntools_generation_id_valid "${id}"; then
      printf 'CNTools: preserving unsafe or unknown generation entry: %s\n' \
        "${entry}" >&2
      continue
    fi
    [[ -z "${retained[${id}]+set}" ]] || continue
    if ! cntools_generation_validate "${entry}" "${id}"; then
      printf 'CNTools: preserving invalid unreferenced generation: %s\n' \
        "${entry}" >&2
      continue
    fi
    chmod -R u+rwX "${entry}" || {
      status=2
      continue
    }
    rm -rf -- "${entry}" || status=2
  done < <(find "${root}/generations" -mindepth 1 -maxdepth 1 -print)
  return "${status}"
}

cntools_generation_prune() (
  local root="${1:-}" keep_id="${2:-}" status=0

  _cntools_generation_root_validate "${root}" || return 2
  _cntools_generation_id_valid "${keep_id}" || return 2
  _cntools_generation_lock_acquire "${root}" || return $?
  _cntools_generation_recover_unlocked "${root}" || status=$?
  if [[ ${status} -eq 0 ]]; then
    _cntools_generation_prune_unlocked "${root}" "${keep_id}" || status=$?
  fi
  _cntools_generation_lock_release || [[ ${status} -ne 0 ]] || status=2
  return "${status}"
)

# Prune while retaining a deployment-owned generation lock across receipt and
# metadata commit. The caller remains responsible for releasing the lock.
cntools_generation_prune_locked() {
  local root="${1:-}" keep_id="${2:-}"

  _cntools_generation_root_validate "${root}" || return 2
  _cntools_generation_lock_is_owned "${root}" || return 2
  _cntools_generation_state_is_settled "${root}" || return 2
  _cntools_generation_prune_unlocked "${root}" "${keep_id}"
}
