#!/usr/bin/env bash
# Exercise the Stage 3 immutable-generation lifecycle without invoking CNTools
# workflows or changing the legacy public launcher.
# shellcheck disable=SC1090
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools generation lifecycle tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

LC_ALL=C
export LC_ALL

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
LIFECYCLE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/lifecycle.sh"
SOURCE_MANIFEST_RELATIVE="scripts/common-helper-scripts/cntools/manifest.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-lifecycle.XXXXXX")"
TEST_ROOT="$(cd -P -- "${TEST_ROOT}" && pwd -P)"

cleanup() {
  if [[ "${CNTOOLS_LIFECYCLE_PRESERVE_TEST_ROOT:-N}" == "Y" ]]; then
    printf 'Preserved CNTools lifecycle test root: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+rwX "${TEST_ROOT}" >/dev/null 2>&1 || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'CNTools generation lifecycle test failed: %s\n' "$1" >&2
  exit 1
}

for required_command in awk cat chmod cmp cp dirname find grep jq ln mktemp mv ps \
  readlink sed sleep sort stat wc; do
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
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 -- "$1")" || return 1
  else
    return 1
  fi
  printf '%s\n' "${digest%% *}"
}

stat_inode() {
  stat -f '%i' "$1" 2>/dev/null || stat -c '%i' "$1"
}

stat_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1"
}

stat_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

copy_payload_source() {
  local destination="$1"
  local common="${destination}/scripts/common-helper-scripts"

  mkdir -p -- "${common}"
  cp -- "${REPO_ROOT}/scripts/common-helper-scripts/cntools.library" "${common}/"
  cp -- "${REPO_ROOT}/scripts/common-helper-scripts/cntools.conf.example" "${common}/"
  cp -R -- "${REPO_ROOT}/scripts/common-helper-scripts/cntools" "${common}/cntools"
}

reconstruct_legacy_monolith() {
  local source_root="$1"
  local facade="${source_root}/scripts/common-helper-scripts/cntools.library"
  local bundle_id="6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59"
  local bundle="${source_root}/scripts/common-helper-scripts/cntools/libs/legacy/${bundle_id}"
  local staged="${facade}.legacy.$$" member=""
  local -a members=(
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

  {
    sed -n '1,5p' "${facade}"
    awk '
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_PREFIX_BEGIN__" {
        print previous; inside=1; next
      }
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_PREFIX_END__" { inside=0; next }
      inside { print }
      { previous=$0 }
    ' "${facade}"
    awk '
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_INITIALIZATION_BEGIN__" {
        inside=1; next
      }
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_INITIALIZATION_END__" {
        inside=0; next
      }
      inside { print }
    ' "${facade}"
    cat "${bundle}/${members[0]}"
    awk '
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_INTERSTITIAL_BEGIN__" {
        inside=1; next
      }
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_INTERSTITIAL_END__" {
        inside=0; next
      }
      inside { print }
    ' "${facade}"
    for member in "${members[@]:1}"; do cat "${bundle}/${member}"; done
  } > "${staged}" || return 1
  [[ "$(sha256_file "${staged}")" == \
     "92e800f58948a570da401bef431d6e2449f25b337138f242ab3eeb48b0cf162b" ]] ||
    return 1
  mv -f "${staged}" "${facade}"
}

reconstruct_schema2_logical_body() {
  local source_root="$1" output="$2"
  local facade="${source_root}/scripts/common-helper-scripts/cntools.library"
  local manifest="${source_root}/${SOURCE_MANIFEST_RELATIVE}"
  local bundle_relative="" bundle="" member=""

  bundle_relative="$(jq -er '.legacyBundle.path' "${manifest}")" || return 1
  bundle="${source_root}/scripts/common-helper-scripts/${bundle_relative}"
  {
    awk '
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_PREFIX_BEGIN__" {
        print previous; inside=1; next
      }
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_PREFIX_END__" { inside=0; next }
      inside { print }
      { previous=$0 }
    ' "${facade}"
    awk '
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_INITIALIZATION_BEGIN__" {
        inside=1; next
      }
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_INITIALIZATION_END__" {
        inside=0; next
      }
      inside { print }
    ' "${facade}"
    while IFS= read -r member; do
      cat "${bundle}/${member}" || return 1
      if [[ "${member}" == "010-common-dialog.sh" ]]; then
        awk '
          $0 == "# __CNTOOLS_LEGACY_LOGICAL_INTERSTITIAL_BEGIN__" {
            inside=1; next
          }
          $0 == "# __CNTOOLS_LEGACY_LOGICAL_INTERSTITIAL_END__" {
            inside=0; next
          }
          inside { print }
        ' "${facade}"
      fi
    done < <(jq -er '.legacyBundle.members[].path' "${manifest}")
  } > "${output}"
}

prepare_changed_schema2_bundle() {
  local source_root="$1" change_kind="$2" execution_sentinel="${3:-}"
  local manifest="${source_root}/${SOURCE_MANIFEST_RELATIVE}"
  local facade="${source_root}/scripts/common-helper-scripts/cntools.library"
  local old_id="" new_id="" old_prefix="" new_prefix=""
  local old_bundle="" new_bundle="" changed_member=""
  local logical_body="${source_root}/changed-bundle.logical-body"
  local member_records="${source_root}/changed-bundle.members.ndjson"
  local canonical="${source_root}/changed-bundle.canonical"
  local logical_sha="" logical_size="" member="" member_path=""
  local member_sha="" member_size="" old_member_sha="" old_member_size=""

  old_id="$(jq -er '.legacyBundle.id' "${manifest}")" || return 1
  old_prefix="${old_id:0:8}"
  old_bundle="${source_root}/scripts/common-helper-scripts/cntools/libs/legacy/${old_id}"
  changed_member="${old_bundle}/100-transaction-hardware-price.sh"
  old_member_sha="$(sha256_file "${changed_member}")" || return 1
  old_member_size="$(wc -c < "${changed_member}")" || return 1
  old_member_size="${old_member_size//[[:space:]]/}"
  case "${change_kind}" in
    definition-only)
      printf '\n# Cross-ID definition-only lifecycle fixture.\n' >> \
        "${changed_member}" || return 1
      ;;
    sentinel)
      [[ -n "${execution_sentinel}" ]] || return 1
      printf '\nprintf cross-id-candidate-executed > %q\n' \
        "${execution_sentinel}" >> "${changed_member}" || return 1
      ;;
    *) return 1 ;;
  esac

  reconstruct_schema2_logical_body "${source_root}" "${logical_body}" ||
    return 1
  logical_sha="$(sha256_file "${logical_body}")" || return 1
  logical_size="$(wc -c < "${logical_body}")" || return 1
  logical_size="${logical_size//[[:space:]]/}"
  : > "${member_records}" || return 1
  {
    printf 'cntools-legacy-bundle-v1\n'
    printf 'facade\tcntools.library\n'
    printf 'logical-body\t%s\t%s\n' "${logical_size}" "${logical_sha}"
    while IFS= read -r member; do
      member_path="${old_bundle}/${member}"
      member_sha="$(sha256_file "${member_path}")" || return 1
      member_size="$(wc -c < "${member_path}")" || return 1
      member_size="${member_size//[[:space:]]/}"
      jq -cn --arg path "${member}" --arg sha256 "${member_sha}" \
        --argjson size "${member_size}" \
        '{mode:"0444",path:$path,sha256:$sha256,size:$size}' >> \
        "${member_records}" || return 1
      printf 'member\t%s\t0444\t%s\t%s\n' \
        "${member}" "${member_size}" "${member_sha}"
    done < <(jq -er '.legacyBundle.members[].path' "${manifest}")
  } > "${canonical}" || return 1
  new_id="$(sha256_file "${canonical}")" || return 1
  [[ "${new_id}" =~ ^[0-9a-f]{64}$ && "${new_id}" != "${old_id}" ]] ||
    return 1
  new_prefix="${new_id:0:8}"
  new_bundle="${source_root}/scripts/common-helper-scripts/cntools/libs/legacy/${new_id}"
  mv "${old_bundle}" "${new_bundle}" || return 1

  member_sha="$(sha256_file "${new_bundle}/100-transaction-hardware-price.sh")" ||
    return 1
  member_size="$(wc -c < \
    "${new_bundle}/100-transaction-hardware-price.sh")" || return 1
  member_size="${member_size//[[:space:]]/}"
  sed -E \
    -e "s/${old_id}/${new_id}/g" \
    -e "s/__guild_cntools_legacy_bundle_${old_prefix}/__guild_cntools_legacy_bundle_${new_prefix}/g" \
    -e "s/logical_body_sha=\"[0-9a-f]{64}\"/logical_body_sha=\"${logical_sha}\"/" \
    -e "s/logical_body_size=\"[0-9]+\"/logical_body_size=\"${logical_size}\"/" \
    -e "s/${old_member_sha}/${member_sha}/g" \
    -e "s/22753 ${old_member_size}/22753 ${member_size}/" \
    "${facade}" > "${facade}.changed" || return 1
  mv "${facade}.changed" "${facade}" || return 1
  atomic_jq_update "${manifest}" \
    --arg old_id "${old_id}" --arg id "${new_id}" \
    --arg logical_sha "${logical_sha}" --argjson logical_size "${logical_size}" \
    --slurpfile members "${member_records}" '
      .legacyBundle.id = $id |
      .legacyBundle.path = ("cntools/libs/legacy/" + $id) |
      .legacyBundle.logicalBodySha256 = $logical_sha |
      .legacyBundle.logicalBodySize = $logical_size |
      .legacyBundle.members = $members |
      .files |= map(
        if (.path | startswith("cntools/libs/legacy/" + $old_id + "/"))
        then .path |= sub($old_id; $id) |
             .source |= sub($old_id; $id)
        else . end)
    ' || return 1
  rm "${logical_body}" "${member_records}" "${canonical}" || return 1
}

atomic_jq_update() {
  local file="$1"
  shift
  local staged="${file}.stage.$$"

  jq "$@" "${file}" > "${staged}" || {
    rm -f -- "${staged}"
    return 1
  }
  mv -f -- "${staged}" "${file}"
}

build_generation() {
  local cntools_root="$1"
  local variant="$2"
  local generation_version="${3:-13.5.7}"
  local generation_schema="${4:-3}"
  local bundle_variant="${5:-canonical}"
  local source_root="${TEST_ROOT}/payload-${variant}"
  local manifest="${source_root}/${SOURCE_MANIFEST_RELATIVE}"
  local root_module="${source_root}/scripts/common-helper-scripts/cntools/modules/root/module.json"
  local changed_source="scripts/common-helper-scripts/cntools/docs/TESTING.md"
  local inventory="${TEST_ROOT}/generation-${variant}.ndjson"
  local id_records="${TEST_ROOT}/generation-${variant}.tsv"
  local manifest_hash="" changed_hash="" generation_id=""
  local generation_dir="" path="" source="" mode="" validator="" hash=""
  local source_file="" target_file="" extra=""
  local version_tail="" version_minor="" version_patch=""

  copy_payload_source "${source_root}"
  if [[ "${generation_schema}" == "1" ]]; then
    reconstruct_legacy_monolith "${source_root}" || return 1
    atomic_jq_update "${root_module}" '
      .schemaVersion = 1 |
      del(.controlPolicy)
    ' || return 1
    atomic_jq_update "${manifest}" '
      .schemaVersion = 1 |
      .moduleApiVersion = 1 |
      del(.moduleSchemaVersion) |
      del(.legacyBundle) |
      .files |= map(select(
        (.path | startswith("cntools/libs/legacy/") | not) and
        ((.path | startswith("cntools/modules/root/") | not) or
         .path == "cntools/modules/root/module.json")
      ))
    ' || return 1
  elif [[ "${generation_schema}" == "2" ]]; then
    atomic_jq_update "${root_module}" '
      .schemaVersion = 1 |
      del(.controlPolicy)
    ' || return 1
    atomic_jq_update "${manifest}" '
      .schemaVersion = 2 |
      .moduleApiVersion = 1 |
      del(.moduleSchemaVersion) |
      .files |= map(select(
        (.path | startswith("cntools/modules/root/") | not) or
        .path == "cntools/modules/root/module.json"
      ))
    ' || return 1
  elif [[ "${generation_schema}" != "3" ]]; then
    return 1
  fi
  case "${bundle_variant}" in
    canonical) : ;;
    changed)
      prepare_changed_schema2_bundle \
        "${source_root}" definition-only ||
        return 1
      ;;
    sentinel)
      prepare_changed_schema2_bundle \
        "${source_root}" sentinel \
        "${TEST_ROOT}/cross-id-candidate.executed" ||
        return 1
      ;;
    *) return 1 ;;
  esac
  if [[ "${generation_version}" != "13.5.7" ]]; then
    printf '%s\n' "${generation_version}" > \
      "${source_root}/scripts/common-helper-scripts/cntools/VERSION"
    sed -E "s/^CNTOOLS_MAJOR_VERSION=.*/CNTOOLS_MAJOR_VERSION=${generation_version%%.*}/" \
      "${source_root}/scripts/common-helper-scripts/cntools.library" > \
      "${source_root}/cntools.library.version"
    mv -f -- "${source_root}/cntools.library.version" \
      "${source_root}/scripts/common-helper-scripts/cntools.library"
    version_tail="${generation_version#*.}"
    version_minor="${version_tail%%.*}"
    version_patch="${generation_version##*.}"
    sed -E \
      -e "s/^CNTOOLS_MINOR_VERSION=.*/CNTOOLS_MINOR_VERSION=${version_minor}/" \
      -e "s/^CNTOOLS_PATCH_VERSION=.*/CNTOOLS_PATCH_VERSION=${version_patch}/" \
      "${source_root}/scripts/common-helper-scripts/cntools.library" > \
      "${source_root}/cntools.library.version"
    mv -f -- "${source_root}/cntools.library.version" \
      "${source_root}/scripts/common-helper-scripts/cntools.library"
    atomic_jq_update "${manifest}" --arg version "${generation_version}" \
      '.version = $version' || return 1
  fi
  while IFS= read -r source; do
    changed_hash="$(sha256_file "${source_root}/${source}")" || return 1
    atomic_jq_update "${manifest}" \
      --arg source "${source}" --arg hash "${changed_hash}" '
        (.files[] | select(.source == $source) | .sha256) = $hash
      ' || return 1
  done < <(jq -r '.files[].source' "${manifest}")
  printf '\nLifecycle fixture %s.\n' "${variant}" >> "${source_root}/${changed_source}"
  changed_hash="$(sha256_file "${source_root}/${changed_source}")" || return 1
  atomic_jq_update "${manifest}" \
    --arg source "${changed_source}" --arg hash "${changed_hash}" '
      (.files[] | select(.source == $source) | .sha256) = $hash
    ' || return 1
  manifest_hash="$(sha256_file "${manifest}")" || return 1

  jq -cn \
    --arg path 'cntools/manifest.json' \
    --arg source "${SOURCE_MANIFEST_RELATIVE}" \
    --arg mode '0444' \
    --arg validator 'json' \
    --arg sha256 "${manifest_hash}" \
    '{path:$path, source:$source, mode:$mode,
      validator:$validator, sha256:$sha256}' > "${inventory}" || return 1
  jq -c '.files[]' "${manifest}" >> "${inventory}" || return 1
  jq -r -s 'sort_by(.path)[] | [.path, .mode, .sha256] | @tsv' \
    "${inventory}" > "${id_records}" || return 1
  generation_id="$(sha256_file "${id_records}")" || return 1
  [[ "${generation_id}" =~ ^[0-9a-f]{64}$ ]] || return 1
  generation_dir="${cntools_root}/generations/${generation_id}"
  [[ ! -e "${generation_dir}" && ! -L "${generation_dir}" ]] || return 1
  mkdir -p -- "${generation_dir}/cntools"

  cp -- "${manifest}" "${generation_dir}/cntools/manifest.json" || return 1
  chmod 0444 "${generation_dir}/cntools/manifest.json" || return 1
  while IFS=$'\t' read -r path source mode validator hash extra; do
    [[ -n "${path}" && -n "${source}" && -n "${mode}" &&
       -n "${validator}" && -n "${hash}" && -z "${extra}" ]] || return 1
    source_file="${source_root}/${source}"
    target_file="${generation_dir}/${path}"
    mkdir -p -- "$(dirname -- "${target_file}")" || return 1
    cp -- "${source_file}" "${target_file}" || return 1
    chmod "${mode}" "${target_file}" || return 1
  done < <(jq -r '.files[] | [.path, .source, .mode, .validator, .sha256] | @tsv' "${manifest}")

  jq -s \
    --arg id "${generation_id}" \
    --arg manifest_hash "${manifest_hash}" \
    --arg version "${generation_version}" \
    --argjson schema_version "${generation_schema}" '
      {
        schemaVersion: $schema_version,
        id: $id,
        version: $version,
        generationIdAlgorithm: "sha256-path-mode-content-v1",
        payloadManifest: "cntools/manifest.json",
        payloadManifestSha256: $manifest_hash,
        files: sort_by(.path)
      }
    ' "${inventory}" > "${generation_dir}/.generation.json" || return 1
  chmod 0444 "${generation_dir}/.generation.json" || return 1
  find "${generation_dir}" -depth -type d -exec chmod 0555 {} + || return 1
  printf '%s\n' "${generation_id}"
}

build_recomputed_invalid_generation() {
  local source_generation="$1"
  local cntools_root="$2"
  local variant="$3"
  local filter="$4"
  local stage="${TEST_ROOT}/invalid-${variant}.stage"
  local manifest="${stage}/cntools/manifest.json"
  local receipt="${stage}/.generation.json"
  local inventory="${TEST_ROOT}/invalid-${variant}.inventory.json"
  local canonical="${TEST_ROOT}/invalid-${variant}.canonical.tsv"
  local manifest_hash=""
  local generation_id=""
  local destination=""

  cp -R -- "${source_generation}" "${stage}" || return 1
  chmod -R u+rwX "${stage}" || return 1
  atomic_jq_update "${manifest}" "${filter}" || return 1
  manifest_hash="$(sha256_file "${manifest}")" || return 1
  jq -s --arg manifest_hash "${manifest_hash}" '
    [{
      path: "cntools/manifest.json",
      source: "scripts/common-helper-scripts/cntools/manifest.json",
      mode: "0444", validator: "json", sha256: $manifest_hash
    }] + .[0].files | sort_by(.path)
  ' "${manifest}" > "${inventory}" || return 1
  jq -r '.[] | [.path,.mode,.sha256] | @tsv' "${inventory}" > \
    "${canonical}" || return 1
  generation_id="$(sha256_file "${canonical}")" || return 1
  atomic_jq_update "${receipt}" --arg id "${generation_id}" \
    --arg hash "${manifest_hash}" --slurpfile files "${inventory}" '
      .id = $id |
      .payloadManifestSha256 = $hash |
      .files = $files[0]
    ' || return 1
  chmod 0444 "${manifest}" "${receipt}" || return 1
  destination="${cntools_root}/generations/${generation_id}"
  [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 1
  mv -- "${stage}" "${destination}" || return 1
  find "${destination}" -depth -type d -exec chmod 0555 {} + || return 1
  printf '%s\n' "${generation_id}"
}

build_schema1_substitution_generation() {
  local source_generation="$1" cntools_root="$2"
  local stage="${TEST_ROOT}/schema1-substitution.stage"
  local manifest="${stage}/cntools/manifest.json"
  local receipt="${stage}/.generation.json"
  local removed_path="cntools/docs/TESTING.md"
  local added_name="010-common-dialog.sh"
  local bundle_id="6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59"
  local added_path="cntools/libs/legacy/${bundle_id}/${added_name}"
  local added_source="scripts/common-helper-scripts/${added_path}"
  local inventory="${TEST_ROOT}/schema1-substitution.inventory.json"
  local canonical="${TEST_ROOT}/schema1-substitution.canonical.tsv"
  local member_hash="" manifest_hash="" generation_id="" destination=""
  local path="" mode=""

  cp -R "${source_generation}" "${stage}" || return 1
  chmod -R u+rwX "${stage}" || return 1
  rm "${stage}/${removed_path}" || return 1
  mkdir -p "$(dirname "${stage}/${added_path}")" || return 1
  cp "${REPO_ROOT}/${added_source}" "${stage}/${added_path}" || return 1
  chmod 0444 "${stage}/${added_path}" || return 1
  member_hash="$(sha256_file "${stage}/${added_path}")" || return 1
  atomic_jq_update "${manifest}" \
    --arg removed_path "${removed_path}" \
    --arg added_path "${added_path}" \
    --arg added_source "${added_source}" \
    --arg member_hash "${member_hash}" '
      .files = ([.files[] | select(.path != $removed_path)] + [{
        path: $added_path, source: $added_source, mode: "0444",
        validator: "shell", sha256: $member_hash
      }] | sort_by(.path))
    ' || return 1
  manifest_hash="$(sha256_file "${manifest}")" || return 1
  jq -s --arg manifest_hash "${manifest_hash}" '
    [{
      path: "cntools/manifest.json",
      source: "scripts/common-helper-scripts/cntools/manifest.json",
      mode: "0444", validator: "json", sha256: $manifest_hash
    }] + .[0].files | sort_by(.path)
  ' "${manifest}" > "${inventory}" || return 1
  jq -r '.[] | [.path,.mode,.sha256] | @tsv' "${inventory}" > \
    "${canonical}" || return 1
  generation_id="$(sha256_file "${canonical}")" || return 1
  atomic_jq_update "${receipt}" --arg id "${generation_id}" \
    --arg hash "${manifest_hash}" --slurpfile files "${inventory}" '
      .id = $id |
      .payloadManifestSha256 = $hash |
      .files = $files[0]
    ' || return 1
  while IFS=$'\t' read -r path mode; do
    chmod "${mode}" "${stage}/${path}" || return 1
  done < <(jq -r '.files[] | [.path,.mode] | @tsv' "${receipt}")
  chmod 0444 "${receipt}" || return 1
  destination="${cntools_root}/generations/${generation_id}"
  [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 1
  mv "${stage}" "${destination}" || return 1
  find "${destination}" -depth -type d -exec chmod 0555 {} + || return 1
  printf '%s\n' "${generation_id}"
}

build_schema2_foreign_id_substitution_generation() {
  local source_generation="$1" cntools_root="$2"
  local stage="${TEST_ROOT}/schema2-foreign-substitution.stage"
  local manifest="${stage}/cntools/manifest.json"
  local receipt="${stage}/.generation.json"
  local removed_path="cntools/docs/TESTING.md"
  local bundle_id="" foreign_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local member_name="010-common-dialog.sh" added_path="" added_source=""
  local inventory="${TEST_ROOT}/schema2-foreign-substitution.inventory.json"
  local canonical="${TEST_ROOT}/schema2-foreign-substitution.canonical.tsv"
  local member_hash="" manifest_hash="" generation_id="" destination=""
  local path="" mode=""

  cp -R "${source_generation}" "${stage}" || return 1
  chmod -R u+rwX "${stage}" || return 1
  bundle_id="$(jq -er '.legacyBundle.id' "${manifest}")" || return 1
  [[ "${bundle_id}" != "${foreign_id}" ]] || return 1
  added_path="cntools/libs/legacy/${foreign_id}/${member_name}"
  added_source="scripts/common-helper-scripts/${added_path}"
  rm "${stage}/${removed_path}" || return 1
  mkdir -p "$(dirname "${stage}/${added_path}")" || return 1
  cp "${stage}/cntools/libs/legacy/${bundle_id}/${member_name}" \
    "${stage}/${added_path}" || return 1
  chmod 0444 "${stage}/${added_path}" || return 1
  member_hash="$(sha256_file "${stage}/${added_path}")" || return 1
  atomic_jq_update "${manifest}" \
    --arg removed_path "${removed_path}" \
    --arg added_path "${added_path}" \
    --arg added_source "${added_source}" \
    --arg member_hash "${member_hash}" '
      .files = ([.files[] | select(.path != $removed_path)] + [{
        path: $added_path, source: $added_source, mode: "0444",
        validator: "shell", sha256: $member_hash
      }] | sort_by(.path))
    ' || return 1
  manifest_hash="$(sha256_file "${manifest}")" || return 1
  jq -s --arg manifest_hash "${manifest_hash}" '
    [{
      path: "cntools/manifest.json",
      source: "scripts/common-helper-scripts/cntools/manifest.json",
      mode: "0444", validator: "json", sha256: $manifest_hash
    }] + .[0].files | sort_by(.path)
  ' "${manifest}" > "${inventory}" || return 1
  jq -r '.[] | [.path,.mode,.sha256] | @tsv' "${inventory}" > \
    "${canonical}" || return 1
  generation_id="$(sha256_file "${canonical}")" || return 1
  atomic_jq_update "${receipt}" --arg id "${generation_id}" \
    --arg hash "${manifest_hash}" --slurpfile files "${inventory}" '
      .id = $id |
      .payloadManifestSha256 = $hash |
      .files = $files[0]
    ' || return 1
  while IFS=$'\t' read -r path mode; do
    chmod "${mode}" "${stage}/${path}" || return 1
  done < <(jq -r '.files[] | [.path,.mode] | @tsv' "${receipt}")
  chmod 0444 "${receipt}" || return 1
  destination="${cntools_root}/generations/${generation_id}"
  [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 1
  mv "${stage}" "${destination}" || return 1
  find "${destination}" -depth -type d -exec chmod 0555 {} + || return 1
  printf '%s\n' "${generation_id}"
}

build_schema3_inventory_substitution_generation() {
  local source_generation="$1" cntools_root="$2" variant="$3"
  local stage="${TEST_ROOT}/schema3-${variant}.stage"
  local manifest="${stage}/cntools/manifest.json"
  local receipt="${stage}/.generation.json"
  local inventory="${TEST_ROOT}/schema3-${variant}.inventory.json"
  local canonical="${TEST_ROOT}/schema3-${variant}.canonical.tsv"
  local removed_path="" added_path="" added_source="" added_hash=""
  local removed_action="" added_action="" added_action_source=""
  local action_hash="" manifest_hash="" generation_id="" destination=""
  local path="" mode=""

  cp -R -- "${source_generation}" "${stage}" || return 1
  chmod -R u+rwX "${stage}" || return 1
  case "${variant}" in
    base-to-fake-module)
      removed_path='cntools/docs/TESTING.md'
      added_path='cntools/modules/root/fake/module.json'
      added_source="scripts/common-helper-scripts/${added_path}"
      rm -- "${stage}/${removed_path}" || return 1
      mkdir -p -- "$(dirname -- "${stage}/${added_path}")" || return 1
      cp -- "${stage}/cntools/modules/root/blocks/module.json" \
        "${stage}/${added_path}" || return 1
      atomic_jq_update "${stage}/${added_path}" '
        .id = "fake" |
        .order = 110 |
        .shortcut = "y" |
        .label = "Fake" |
        .description = "Legacy CNTools menu: Fake"
      ' || return 1
      added_hash="$(sha256_file "${stage}/${added_path}")" || return 1
      atomic_jq_update "${manifest}" \
        --arg removed_path "${removed_path}" \
        --arg added_path "${added_path}" \
        --arg added_source "${added_source}" \
        --arg added_hash "${added_hash}" '
          .files = ([.files[] | select(.path != $removed_path)] + [{
            path: $added_path, source: $added_source, mode: "0444",
            validator: "json", sha256: $added_hash
          }] | sort_by(.path))
        ' || return 1
      ;;
    module-action-relocation)
      removed_path='cntools/modules/root/wallet/list/module.json'
      removed_action='cntools/modules/root/wallet/list/action.sh'
      added_path='cntools/modules/root/wallet/phantom/module.json'
      added_action='cntools/modules/root/wallet/phantom/action.sh'
      added_source="scripts/common-helper-scripts/${added_path}"
      added_action_source="scripts/common-helper-scripts/${added_action}"
      mkdir -p -- "${stage}/cntools/modules/root/wallet/phantom" || return 1
      cp -- "${stage}/${removed_path}" "${stage}/${added_path}" || return 1
      cp -- "${stage}/${removed_action}" "${stage}/${added_action}" || return 1
      rm -rf -- "${stage}/cntools/modules/root/wallet/list" || return 1
      atomic_jq_update "${stage}/${added_path}" '
        .id = "wallet.phantom" |
        .label = "Phantom" |
        .description = "Legacy CNTools workflow: Phantom"
      ' || return 1
      added_hash="$(sha256_file "${stage}/${added_path}")" || return 1
      action_hash="$(sha256_file "${stage}/${added_action}")" || return 1
      atomic_jq_update "${manifest}" \
        --arg removed_path "${removed_path}" \
        --arg removed_action "${removed_action}" \
        --arg added_path "${added_path}" \
        --arg added_source "${added_source}" \
        --arg added_hash "${added_hash}" \
        --arg added_action "${added_action}" \
        --arg added_action_source "${added_action_source}" \
        --arg action_hash "${action_hash}" '
          .files = ([.files[] |
            select(.path != $removed_path and .path != $removed_action)] + [{
              path: $added_path, source: $added_source, mode: "0444",
              validator: "json", sha256: $added_hash
            }, {
              path: $added_action, source: $added_action_source, mode: "0444",
              validator: "shell", sha256: $action_hash
            }] | sort_by(.path))
        ' || return 1
      ;;
    *) return 1 ;;
  esac

  manifest_hash="$(sha256_file "${manifest}")" || return 1
  jq -s --arg manifest_hash "${manifest_hash}" '
    [{
      path: "cntools/manifest.json",
      source: "scripts/common-helper-scripts/cntools/manifest.json",
      mode: "0444", validator: "json", sha256: $manifest_hash
    }] + .[0].files | sort_by(.path)
  ' "${manifest}" > "${inventory}" || return 1
  [[ "$(jq -er 'length' "${inventory}")" == 152 ]] || return 1
  jq -r '.[] | [.path,.mode,.sha256] | @tsv' "${inventory}" > \
    "${canonical}" || return 1
  generation_id="$(sha256_file "${canonical}")" || return 1
  atomic_jq_update "${receipt}" --arg id "${generation_id}" \
    --arg hash "${manifest_hash}" --slurpfile files "${inventory}" '
      .id = $id |
      .payloadManifestSha256 = $hash |
      .files = $files[0]
    ' || return 1
  while IFS=$'\t' read -r path mode; do
    chmod "${mode}" "${stage}/${path}" || return 1
  done < <(jq -r '.files[] | [.path,.mode] | @tsv' "${receipt}")
  chmod 0444 "${receipt}" || return 1
  destination="${cntools_root}/generations/${generation_id}"
  [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 1
  mv -- "${stage}" "${destination}" || return 1
  find "${destination}" -depth -type d -exec chmod 0555 {} + || return 1
  printf '%s\n' "${generation_id}"
}

build_rehashed_sentinel_generation() {
  local source_generation="$1"
  local cntools_root="$2"
  local variant="$3"
  local config_sentinel="$4"
  local registry_sentinel="$5"
  local stage="${TEST_ROOT}/rehashed-${variant}.stage"
  local manifest="${stage}/cntools/manifest.json"
  local receipt="${stage}/.generation.json"
  local canonical="${TEST_ROOT}/rehashed-${variant}.canonical.tsv"
  local member="" path="" hash="" manifest_hash="" generation_id=""
  local destination=""

  cp -R -- "${source_generation}" "${stage}" || return 1
  chmod -R u+rwX "${stage}" || return 1
  for member in config registry; do
    path="${stage}/cntools/core/${member}.sh"
    case "${member}" in
      config) printf '\nprintf executed > %q\n' "${config_sentinel}" >> "${path}" ;;
      registry) printf '\nprintf executed > %q\n' "${registry_sentinel}" >> "${path}" ;;
    esac
    hash="$(sha256_file "${path}")" || return 1
    atomic_jq_update "${manifest}" --arg path "cntools/core/${member}.sh" \
      --arg hash "${hash}" \
      '(.files[] | select(.path == $path) | .sha256) = $hash' || return 1
    atomic_jq_update "${receipt}" --arg path "cntools/core/${member}.sh" \
      --arg hash "${hash}" \
      '(.files[] | select(.path == $path) | .sha256) = $hash' || return 1
  done
  manifest_hash="$(sha256_file "${manifest}")" || return 1
  atomic_jq_update "${receipt}" --arg hash "${manifest_hash}" '
    .payloadManifestSha256 = $hash |
    (.files[] | select(.path == "cntools/manifest.json") | .sha256) = $hash
  ' || return 1
  jq -r '.files | sort_by(.path)[] | [.path,.mode,.sha256] | @tsv' \
    "${receipt}" > "${canonical}" || return 1
  generation_id="$(sha256_file "${canonical}")" || return 1
  atomic_jq_update "${receipt}" --arg id "${generation_id}" '.id = $id' ||
    return 1
  while IFS=$'\t' read -r path mode; do
    chmod "${mode}" "${stage}/${path}" || return 1
  done < <(jq -r '.files[] | [.path,.mode] | @tsv' "${receipt}")
  chmod 0444 "${receipt}" || return 1
  destination="${cntools_root}/generations/${generation_id}"
  [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 1
  mv -- "${stage}" "${destination}" || return 1
  find "${destination}" -depth -type d -exec chmod 0555 {} + || return 1
  printf '%s\n' "${generation_id}"
}

assert_link() {
  local cntools_root="$1"
  local name="$2"
  local id="$3"
  local link="${cntools_root}/${name}"

  [[ -L "${link}" ]] || fail "${name} is not a symbolic link"
  [[ "$(readlink "${link}")" == "generations/${id}" ]] ||
    fail "${name} does not point to generations/${id}"
  [[ -d "${link}" ]] || fail "${name} is dangling"
}

assert_absent() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected path exists: $1"
}

pointer_state() {
  local cntools_root="$1"
  local output="$2"
  local name="" link=""

  : > "${output}"
  for name in active previous; do
    link="${cntools_root}/${name}"
    if [[ -L "${link}" ]]; then
      printf '%s\tlink\t%s\t%s\t%s\n' "${name}" "$(readlink "${link}")" \
        "$(stat_inode "${link}")" "$(stat_mtime "${link}")" >> "${output}"
    elif [[ -e "${link}" ]]; then
      printf '%s\tunsafe\n' "${name}" >> "${output}"
    else
      printf '%s\tabsent\n' "${name}" >> "${output}"
    fi
  done
}

expect_failure() {
  local context="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    fail "${context} unexpectedly succeeded"
  fi
}

wait_for_lifecycle_path() {
  local path="$1" process_id="${2:-}" attempt=0

  for ((attempt = 0; attempt < 300; attempt++)); do
    [[ -e "${path}" || -L "${path}" ]] && return 0
    if [[ -n "${process_id}" ]] && ! kill -0 "${process_id}" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 1
}

process_is_same_or_descendant() {
  local process_id="$1" ancestor_id="$2" parent_id="" attempt=0

  [[ "${process_id}" =~ ^[0-9]+$ && "${ancestor_id}" =~ ^[0-9]+$ ]] ||
    return 1
  while ((attempt < 32)) && [[ "${process_id}" != 0 && "${process_id}" != 1 ]]; do
    [[ "${process_id}" == "${ancestor_id}" ]] && return 0
    parent_id="$(ps -o ppid= -p "${process_id}" 2>/dev/null)" || return 1
    parent_id="${parent_id//[[:space:]]/}"
    [[ "${parent_id}" =~ ^[0-9]+$ ]] || return 1
    process_id="${parent_id}"
    attempt=$((attempt + 1))
  done
  return 1
}

run_advisory_lock_contract_tests() {
  local root="$1"
  local lifecycle="$2"
  local holder_script=''
  local ready="${TEST_ROOT}/advisory-normal.ready"
  local release="${TEST_ROOT}/advisory-normal.release"
  local released="${TEST_ROOT}/advisory-normal.released"
  local stop="${TEST_ROOT}/advisory-normal.stop"
  local output="${TEST_ROOT}/advisory-normal.output"
  local holder_pid="" child_pid="" status=0 expected_backend=""
  local kill_ready="${TEST_ROOT}/advisory-kill.ready"
  local kill_output="${TEST_ROOT}/advisory-kill.output"
  local kill_holder_pid="" recorded_kill_holder_pid="" kill_child_pid=""
  local main_pid="${BASHPID:-$$}" attempt=0 acquired="N"
  local lock_path="" lock_namespace="" control_artifact=""

  case "$(uname -s)" in
    Linux) expected_backend=flock ;;
    Darwin|FreeBSD|OpenBSD|NetBSD) expected_backend=lockf ;;
    *) expected_backend=unsupported ;;
  esac
  if [[ "${expected_backend}" == unsupported ]]; then
    expect_failure "unsupported advisory-lock platform" \
      cntools_generation_lock_acquire "${root}"
    return 0
  fi

  holder_script='
    set -euo pipefail
    lifecycle=$1; root=$2; ready=$3; release=$4; released=$5; stop=$6
    . "${lifecycle}"
    cntools_generation_lock_acquire "${root}"
    [[ "${CNTOOLS_GENERATION_LOCK_BACKEND}" == "$7" ]]
    IFS=$'\''\t'\'' read -r ready_marker ready_holder ready_identity ready_extra < \
      "${CNTOOLS_GENERATION_LOCK_CONTROL}/ready"
    [[ "${ready_marker}" == ready &&
       "${ready_holder}" == "${CNTOOLS_GENERATION_LOCK_HOLDER_PID}" &&
       "${ready_identity}" == "${CNTOOLS_GENERATION_LOCK_HOLDER_IDENTITY}" &&
       -z "${ready_extra}" ]]
    original_ready="ready\t${ready_holder}\t${ready_identity}"
    forged_identity="${ready_identity%?}0"
    [[ "${forged_identity}" != "${ready_identity}" ]] ||
      forged_identity="${ready_identity%?}1"
    printf "ready\t%s\t%s\n" "${ready_holder}" "${forged_identity}" > \
      "${CNTOOLS_GENERATION_LOCK_CONTROL}/ready"
    ! cntools_generation_lock_is_owned "${root}"
    printf "%b\n" "${original_ready}" > \
      "${CNTOOLS_GENERATION_LOCK_CONTROL}/ready"
    cntools_generation_lock_is_owned "${root}"
    sleep 60 & child=$!
    cleanup_holder() {
      if cntools_generation_lock_is_owned "${root}"; then
        cntools_generation_lock_release "${root}" || true
      fi
      kill "${child}" >/dev/null 2>&1 || true
      wait "${child}" >/dev/null 2>&1 || true
    }
    trap cleanup_holder EXIT
    (umask 077 && printf "%s\n" "${child}" > "${ready}")
    while [[ ! -e "${release}" && ! -L "${release}" ]]; do sleep 0.1; done
    cntools_generation_lock_release "${root}"
    (umask 077 && printf "released\n" > "${released}")
    while [[ ! -e "${stop}" && ! -L "${stop}" ]]; do sleep 0.1; done
  '
  "${BASH}" -c "${holder_script}" bash "${lifecycle}" "${root}" \
    "${ready}" "${release}" "${released}" "${stop}" "${expected_backend}" \
    > "${output}" 2>&1 &
  holder_pid=$!
  if ! wait_for_lifecycle_path "${ready}" "${holder_pid}"; then
    : > "${release}"
    : > "${stop}"
    wait "${holder_pid}" >/dev/null 2>&1 || true
    sed -n '1,100p' "${output}" >&2 || true
    fail "normal advisory-lock holder did not become ready"
  fi
  child_pid="$(< "${ready}")"
  lock_path="$(_cntools_generation_lock_path "${root}")" || {
    : > "${release}"
    : > "${stop}"
    wait "${holder_pid}" >/dev/null 2>&1 || true
    fail "could not resolve deterministic advisory-lock path"
  }
  lock_namespace="$(dirname -- "${lock_path}")"
  [[ -d "${lock_namespace}" && ! -L "${lock_namespace}" &&
     -O "${lock_namespace}" && "$(stat_mode "${lock_namespace}")" == 700 &&
     -f "${lock_path}" && ! -L "${lock_path}" && -O "${lock_path}" &&
     ! -s "${lock_path}" && "$(stat_mode "${lock_path}")" == 600 ]] || {
    : > "${release}"
    : > "${stop}"
    wait "${holder_pid}" >/dev/null 2>&1 || true
    fail "advisory-lock namespace or persistent lock file is unsafe"
  }
  expect_failure "second live advisory-lock contender" \
    cntools_generation_lock_acquire "${root}"
  : > "${release}"
  if ! wait_for_lifecycle_path "${released}" "${holder_pid}"; then
    : > "${stop}"
    wait "${holder_pid}" >/dev/null 2>&1 || true
    fail "normal lifecycle lock release did not complete"
  fi
  kill -0 "${child_pid}" 2>/dev/null || {
    : > "${stop}"
    wait "${holder_pid}" >/dev/null 2>&1 || true
    fail "unrelated child ended before post-release contention"
  }
  cntools_generation_lock_acquire "${root}" || {
    : > "${stop}"
    wait "${holder_pid}" >/dev/null 2>&1 || true
    fail "unrelated child inherited the normally released advisory lock"
  }
  cntools_generation_lock_release "${root}" || fail "contender release failed"
  : > "${stop}"
  if wait "${holder_pid}"; then status=0; else status=$?; fi
  [[ ${status} -eq 0 ]] || fail "normal advisory-lock holder failed"
  control_artifact="$(find "${lock_namespace}" -mindepth 1 -maxdepth 1 \
    -name "$(basename -- "${lock_path}").control.*" -print -quit)" ||
    fail "could not inspect advisory-lock control artifacts"
  [[ -z "${control_artifact}" ]] ||
    fail "normal advisory-lock release left a control artifact"

  "${BASH}" -c '
    set -euo pipefail
    lifecycle=$1; root=$2; ready=$3; expected=$4
    . "${lifecycle}"
    cntools_generation_lock_acquire "${root}"
    [[ "${CNTOOLS_GENERATION_LOCK_BACKEND}" == "${expected}" ]]
    sleep 60 & child=$!
    process_pid="${BASHPID:-$$}"
    (umask 077 && printf "%s\t%s\n" "${process_pid}" "${child}" > "${ready}")
    while :; do sleep 1; done
  ' bash "${lifecycle}" "${root}" "${kill_ready}" "${expected_backend}" \
    > "${kill_output}" 2>&1 &
  kill_holder_pid=$!
  if ! wait_for_lifecycle_path "${kill_ready}" "${kill_holder_pid}"; then
    kill -s TERM "${kill_holder_pid}" 2>/dev/null || true
    wait "${kill_holder_pid}" >/dev/null 2>&1 || true
    sed -n '1,100p' "${kill_output}" >&2 || true
    fail "SIGKILL advisory-lock holder did not become ready"
  fi
  IFS=$'\t' read -r recorded_kill_holder_pid kill_child_pid < "${kill_ready}"
  [[ "${recorded_kill_holder_pid}" =~ ^[0-9]+$ &&
     "${kill_child_pid}" =~ ^[0-9]+$ &&
     "${recorded_kill_holder_pid}" != "${main_pid}" ]] &&
     kill -0 "${recorded_kill_holder_pid}" 2>/dev/null &&
     process_is_same_or_descendant \
       "${recorded_kill_holder_pid}" "${kill_holder_pid}" || {
    kill -s TERM "${kill_holder_pid}" 2>/dev/null || true
    kill "${kill_child_pid}" 2>/dev/null || true
    wait "${kill_holder_pid}" >/dev/null 2>&1 || true
    fail "SIGKILL advisory-lock holder reported unsafe process IDs"
  }
  kill -s KILL "${recorded_kill_holder_pid}"
  wait "${kill_holder_pid}" >/dev/null 2>&1 || true
  kill -0 "${kill_child_pid}" 2>/dev/null ||
    fail "unrelated child did not survive lock-holder SIGKILL"
  for ((attempt = 0; attempt < 50; attempt++)); do
    if cntools_generation_lock_acquire "${root}"; then
      acquired="Y"
      break
    fi
    sleep 0.1
  done
  if [[ "${acquired}" != "Y" ]]; then
    kill "${kill_child_pid}" >/dev/null 2>&1 || true
    fail "SIGKILL or unrelated child retained the advisory lock"
  fi
  cntools_generation_lock_release "${root}" ||
    fail "post-SIGKILL contender release failed"
  kill "${kill_child_pid}" >/dev/null 2>&1 || true
  wait "${kill_child_pid}" >/dev/null 2>&1 || true
  control_artifact="$(find "${lock_namespace}" -mindepth 1 -maxdepth 1 \
    -name "$(basename -- "${lock_path}").control.*" -print -quit)" ||
    fail "could not inspect post-SIGKILL lock artifacts"
  [[ -z "${control_artifact}" ]] ||
    fail "SIGKILL advisory-lock recovery left a control artifact"

  # Override only the private selector in this isolated unit process. Production
  # has no environment-controlled backend: OS selection must fail closed when
  # its required kernel-lock implementation is unavailable.
  if "${BASH}" -c '
    set -euo pipefail
    . "$1"
    _cntools_generation_lock_backend() { return 2; }
    cntools_generation_lock_acquire "$2"
    cntools_generation_lock_release "$2"
  ' bash "${lifecycle}" "${root}" >/dev/null 2>&1; then
    fail "lifecycle selected the wrong platform advisory-lock backend"
  fi
}

[[ -f "${LIFECYCLE}" && ! -L "${LIFECYCLE}" ]] ||
  fail "lifecycle implementation is missing or unsafe: ${LIFECYCLE}"
source_output="$({
  . "${LIFECYCLE}"
  for function_name in \
    cntools_generation_validate \
    cntools_generation_activate \
    cntools_generation_rollback \
    cntools_generation_recover \
    cntools_generation_prune; do
    declare -F "${function_name}" >/dev/null || exit 97
  done
} 2>&1)" || fail "lifecycle file is not definition-only or omits its public API"
[[ -z "${source_output}" ]] ||
  fail "sourcing lifecycle implementation produced output: ${source_output}"
# shellcheck source=/dev/null
. "${LIFECYCLE}"

legacy_script="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
legacy_hash="$(sha256_file "${legacy_script}")" || fail "could not hash legacy CNTools"
legacy_inode="$(stat_inode "${legacy_script}")"

cntools_root="${TEST_ROOT}/node/scripts/.cntools"
mkdir -p -- "${cntools_root}/generations"
chmod 0700 "${cntools_root}" "${cntools_root}/generations"
generation_a="$(build_generation "${cntools_root}" a)" || fail "could not build generation A"
cntools_generation_validate \
  "${cntools_root}/generations/${generation_a}" "${generation_a}" ||
  fail "lifecycle validator rejected generation A"
generation_a_root="${cntools_root}/generations/${generation_a}"
[[ "$(find "${generation_a_root}" -type d | wc -l | tr -d ' ')" == 80 ]] ||
  fail "valid Stage 3 generation does not have exactly 80 directories"
[[ "$(find "${generation_a_root}" -type f | wc -l | tr -d ' ')" == 153 ]] ||
  fail "valid Stage 3 generation does not have exactly 153 regular files"
[[ -z "$(find "${generation_a_root}" -mindepth 1 \
  ! -type d ! -type f -print -quit)" ]] ||
  fail "valid Stage 3 generation contains a symlink or other object type"
jq -e '
  .schemaVersion == 3 and .moduleApiVersion == 1 and
  .moduleSchemaVersion == 2 and
  (.files | length == 151)
' "${cntools_root}/generations/${generation_a}/cntools/manifest.json" \
  >/dev/null || fail "current payload is not the exact schema-3/151-file shape"
jq -e '.schemaVersion == 3 and (.files | length == 152)' \
  "${cntools_root}/generations/${generation_a}/.generation.json" \
  >/dev/null || fail "current receipt is not the exact schema-3/152-file shape"
run_advisory_lock_contract_tests "${cntools_root}" "${LIFECYCLE}"

# The content ID is order-insensitive because its canonical input is sorted,
# but the immutable receipt itself has one deterministic representation.
# Lifecycle validation and activation must therefore reject an otherwise
# self-consistent receipt whose complete file inventory is merely reordered.
reordered_root="${TEST_ROOT}/reordered-receipt/node/scripts/.cntools"
reordered_generation="${reordered_root}/generations/${generation_a}"
reordered_receipt="${reordered_generation}/.generation.json"
reordered_canonical="${TEST_ROOT}/reordered-receipt.canonical.tsv"
reordered_before="${TEST_ROOT}/reordered-receipt.pointers.before"
reordered_after="${TEST_ROOT}/reordered-receipt.pointers.after"
mkdir -p -- "${reordered_root}/generations"
chmod 0700 "${reordered_root}" "${reordered_root}/generations"
cp -R -- "${cntools_root}/generations/${generation_a}" \
  "${reordered_generation}"
cntools_generation_validate "${reordered_generation}" "${generation_a}" ||
  fail "reordered-receipt fixture was not valid before mutation"
chmod 0755 "${reordered_generation}"
atomic_jq_update "${reordered_receipt}" '.files |= reverse' ||
  fail "could not reverse the generation receipt inventory"
chmod 0444 "${reordered_receipt}"
chmod 0555 "${reordered_generation}"
jq -e --arg id "${generation_a}" '
  .id == $id and [.files[].path] != ([.files[].path] | sort)
' "${reordered_receipt}" >/dev/null ||
  fail "reordered generation receipt did not retain its content ID"
jq -r '.files | sort_by(.path)[] | [.path,.mode,.sha256] | @tsv' \
  "${reordered_receipt}" > "${reordered_canonical}"
[[ "$(sha256_file "${reordered_canonical}")" == "${generation_a}" ]] ||
  fail "reordered receipt changed the canonical generation content ID"
pointer_state "${reordered_root}" "${reordered_before}"
expect_failure "generation with reordered receipt inventory" \
  cntools_generation_validate "${reordered_generation}" "${generation_a}"
expect_failure "activation with reordered receipt inventory" \
  cntools_generation_activate "${reordered_root}" "${generation_a}"
pointer_state "${reordered_root}" "${reordered_after}"
cmp -s "${reordered_before}" "${reordered_after}" || {
  diff -u "${reordered_before}" "${reordered_after}" >&2 || true
  fail "rejected reordered receipt changed activation pointers"
}

extra_directory="${cntools_root}/generations/${generation_a}/cntools/unlisted-empty"
chmod 0755 "$(dirname -- "${extra_directory}")"
mkdir -- "${extra_directory}"
chmod 0555 "${extra_directory}" "$(dirname -- "${extra_directory}")"
expect_failure "generation with an unlisted empty directory" \
  cntools_generation_validate \
    "${cntools_root}/generations/${generation_a}" "${generation_a}"
chmod 0755 "$(dirname -- "${extra_directory}")"
rmdir -- "${extra_directory}"
chmod 0555 "$(dirname -- "${extra_directory}")"
cntools_generation_validate \
  "${cntools_root}/generations/${generation_a}" "${generation_a}" ||
  fail "generation A did not validate after removing its unlisted directory"

invalid_root="${TEST_ROOT}/strict-invalid/scripts/.cntools"
mkdir -p -- "${invalid_root}/generations"
chmod 0700 "${invalid_root}" "${invalid_root}/generations"
invalid_extra="$(build_recomputed_invalid_generation \
  "${cntools_root}/generations/${generation_a}" "${invalid_root}" \
  extra-key '.unexpected = true')" ||
  fail "could not build recomputed extra-key manifest fixture"
expect_failure "recomputed manifest with an extra key" \
  cntools_generation_validate \
    "${invalid_root}/generations/${invalid_extra}" "${invalid_extra}"
invalid_entrypoint="$(build_recomputed_invalid_generation \
  "${cntools_root}/generations/${generation_a}" "${invalid_root}" \
  wrong-entrypoint '.entrypoint = "other.sh"')" ||
  fail "could not build recomputed entrypoint manifest fixture"
expect_failure "recomputed manifest with a wrong entrypoint" \
  cntools_generation_validate \
    "${invalid_root}/generations/${invalid_entrypoint}" "${invalid_entrypoint}"
invalid_validator="$(build_recomputed_invalid_generation \
  "${cntools_root}/generations/${generation_a}" "${invalid_root}" \
  wrong-validator \
  '(.files[] | select(.path == "cntools/core/context.sh") | .validator) = "text"')" ||
  fail "could not build recomputed validator manifest fixture"
expect_failure "recomputed manifest with a changed member validator" \
  cntools_generation_validate \
    "${invalid_root}/generations/${invalid_validator}" "${invalid_validator}"

# Schema 1 is frozen to its exact original 19 payload members. A fully
# rehashed 19/20 generation cannot substitute a new legacy chunk for one old
# member merely because its count, hashes, receipt, and content ID agree.
schema1_root="${TEST_ROOT}/schema1-substitution/scripts/.cntools"
mkdir -p "${schema1_root}/generations"
chmod 0700 "${schema1_root}" "${schema1_root}/generations"
schema1_generation="$(build_generation \
  "${schema1_root}" schema1-original 13.5.7 1)" ||
  fail "could not build the exact schema-1 generation"
jq -e '
  .schemaVersion == 1 and (.files | length == 19) and
  (has("legacyBundle") | not)
' "${schema1_root}/generations/${schema1_generation}/cntools/manifest.json" \
  >/dev/null || fail "schema-1 payload fixture is not the exact 19-file shape"
jq -e '
  .schemaVersion == 1 and (.files | length == 20)
' "${schema1_root}/generations/${schema1_generation}/.generation.json" \
  >/dev/null || fail "schema-1 receipt fixture is not the exact 20-file shape"
cntools_generation_validate \
  "${schema1_root}/generations/${schema1_generation}" \
  "${schema1_generation}" || fail "current lifecycle rejected exact schema 1"
cntools_generation_activate "${schema1_root}" "${schema1_generation}" ||
  fail "could not activate the exact schema-1 generation"
schema1_substitution="$(build_schema1_substitution_generation \
  "${schema1_root}/generations/${schema1_generation}" "${schema1_root}")" ||
  fail "could not build fully rehashed schema-1 substitution fixture"
jq -e '
  .schemaVersion == 1 and (.files | length == 19) and
  any(.files[]; .path | endswith("/010-common-dialog.sh")) and
  (any(.files[]; .path == "cntools/docs/TESTING.md") | not)
' "${schema1_root}/generations/${schema1_substitution}/cntools/manifest.json" \
  >/dev/null || fail "schema-1 substitution fixture is not count-preserving"
pointer_state "${schema1_root}" "${TEST_ROOT}/schema1-substitution.before"
expect_failure "fully rehashed schema-1 member substitution" \
  cntools_generation_validate \
    "${schema1_root}/generations/${schema1_substitution}" \
    "${schema1_substitution}"
expect_failure "activation of fully rehashed schema-1 member substitution" \
  cntools_generation_activate "${schema1_root}" "${schema1_substitution}"
pointer_state "${schema1_root}" "${TEST_ROOT}/schema1-substitution.after"
cmp -s "${TEST_ROOT}/schema1-substitution.before" \
  "${TEST_ROOT}/schema1-substitution.after" ||
  fail "rejected schema-1 substitution changed generation pointers"

# Schema 2 binds every legacy member to the one declared content-addressed
# bundle. A valid basename beneath a different 64-hex directory cannot replace
# an unrelated base payload member while preserving the 29/30 counts.
schema2_substitution_root="${TEST_ROOT}/schema2-substitution/scripts/.cntools"
mkdir -p "${schema2_substitution_root}/generations"
chmod 0700 "${schema2_substitution_root}" \
  "${schema2_substitution_root}/generations"
schema2_substitution_base="$(build_generation \
  "${schema2_substitution_root}" schema2-substitution-base 13.5.7 2)" ||
  fail "could not build schema-2 substitution baseline"
cntools_generation_activate \
  "${schema2_substitution_root}" "${schema2_substitution_base}" ||
  fail "could not activate schema-2 substitution baseline"
schema2_substitution="$(build_schema2_foreign_id_substitution_generation \
  "${schema2_substitution_root}/generations/${schema2_substitution_base}" \
  "${schema2_substitution_root}")" ||
  fail "could not build fully rehashed schema-2 foreign-ID substitution"
jq -e '
  .schemaVersion == 2 and (.files | length == 29) and
  (.legacyBundle.id !=
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") and
  any(.files[];
    .path ==
      "cntools/libs/legacy/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/010-common-dialog.sh") and
  (any(.files[]; .path == "cntools/docs/TESTING.md") | not)
' "${schema2_substitution_root}/generations/${schema2_substitution}/cntools/manifest.json" \
  >/dev/null || fail "schema-2 foreign-ID substitution is not count-preserving"
jq -e '.schemaVersion == 2 and (.files | length == 30)' \
  "${schema2_substitution_root}/generations/${schema2_substitution}/.generation.json" \
  >/dev/null || fail "schema-2 substitution receipt is not paired 2/30"
pointer_state "${schema2_substitution_root}" \
  "${TEST_ROOT}/schema2-substitution.before"
expect_failure "fully rehashed schema-2 foreign-ID substitution" \
  cntools_generation_validate \
    "${schema2_substitution_root}/generations/${schema2_substitution}" \
    "${schema2_substitution}"
expect_failure "activation of schema-2 foreign-ID substitution" \
  cntools_generation_activate \
    "${schema2_substitution_root}" "${schema2_substitution}"
pointer_state "${schema2_substitution_root}" \
  "${TEST_ROOT}/schema2-substitution.after"
cmp -s "${TEST_ROOT}/schema2-substitution.before" \
  "${TEST_ROOT}/schema2-substitution.after" ||
  fail "rejected schema-2 foreign-ID substitution changed pointers"

# Schema 3 is not merely a count envelope. Its exact base 29 plus 68 added
# module metadata and 54 action paths are frozen even when a candidate is
# fully rehashed, re-ID'd, and retains the 151/152 counts.
schema3_substitution_root="${TEST_ROOT}/schema3-substitution/scripts/.cntools"
mkdir -p "${schema3_substitution_root}/generations"
chmod 0700 "${schema3_substitution_root}" \
  "${schema3_substitution_root}/generations"
schema3_substitution_base="$(build_generation \
  "${schema3_substitution_root}" schema3-substitution-base 13.5.7 3)" ||
  fail "could not build schema-3 substitution baseline"
cntools_generation_activate \
  "${schema3_substitution_root}" "${schema3_substitution_base}" ||
  fail "could not activate schema-3 substitution baseline"
for schema3_substitution_variant in \
  base-to-fake-module module-action-relocation; do
  schema3_substitution="$(build_schema3_inventory_substitution_generation \
    "${schema3_substitution_root}/generations/${schema3_substitution_base}" \
    "${schema3_substitution_root}" "${schema3_substitution_variant}")" ||
    fail "could not build schema-3 ${schema3_substitution_variant} fixture"
  schema3_substitution_generation="${schema3_substitution_root}/generations/${schema3_substitution}"
  jq -e '.schemaVersion == 3 and .moduleApiVersion == 1 and
    .moduleSchemaVersion == 2 and (.files | length == 151)' \
    "${schema3_substitution_generation}/cntools/manifest.json" >/dev/null ||
    fail "schema-3 ${schema3_substitution_variant} manifest lost 3/151 shape"
  jq -e '.schemaVersion == 3 and (.files | length == 152)' \
    "${schema3_substitution_generation}/.generation.json" >/dev/null ||
    fail "schema-3 ${schema3_substitution_variant} receipt lost 3/152 shape"
  case "${schema3_substitution_variant}" in
    base-to-fake-module)
      jq -e '
        any(.files[]; .path == "cntools/modules/root/fake/module.json") and
        (any(.files[]; .path == "cntools/docs/TESTING.md") | not)
      ' "${schema3_substitution_generation}/cntools/manifest.json" \
        >/dev/null || fail 'schema-3 base-member substitution was not exact'
      ;;
    module-action-relocation)
      jq -e '
        any(.files[];
          .path == "cntools/modules/root/wallet/phantom/module.json") and
        any(.files[];
          .path == "cntools/modules/root/wallet/phantom/action.sh") and
        (any(.files[];
          .path == "cntools/modules/root/wallet/list/module.json") | not) and
        (any(.files[];
          .path == "cntools/modules/root/wallet/list/action.sh") | not)
      ' "${schema3_substitution_generation}/cntools/manifest.json" \
        >/dev/null || fail 'schema-3 module/action relocation was not exact'
      ;;
  esac
  pointer_state "${schema3_substitution_root}" \
    "${TEST_ROOT}/schema3-${schema3_substitution_variant}.before"
  expect_failure "fully rehashed schema-3 ${schema3_substitution_variant}" \
    cntools_generation_validate "${schema3_substitution_generation}" \
      "${schema3_substitution}"
  expect_failure \
    "activation of fully rehashed schema-3 ${schema3_substitution_variant}" \
    cntools_generation_activate "${schema3_substitution_root}" \
      "${schema3_substitution}"
  pointer_state "${schema3_substitution_root}" \
    "${TEST_ROOT}/schema3-${schema3_substitution_variant}.after"
  cmp -s "${TEST_ROOT}/schema3-${schema3_substitution_variant}.before" \
    "${TEST_ROOT}/schema3-${schema3_substitution_variant}.after" ||
    fail "rejected schema-3 ${schema3_substitution_variant} changed pointers"
done

# Installed launcher diagnostics require the authenticated outer receipt and
# deployment metadata exercised by cntools-generation-diagnostics.sh. This
# lifecycle fixture is intentionally generation-only; its no-execution checks
# below validate every executable core member through the already trusted
# lifecycle implementation.
assert_absent "${cntools_root}/active"
assert_absent "${cntools_root}/previous"

cntools_generation_activate "${cntools_root}" "${generation_a}" ||
  fail "first generation activation failed"
assert_link "${cntools_root}" active "${generation_a}"
assert_absent "${cntools_root}/previous"
pointer_state "${cntools_root}" "${TEST_ROOT}/activation-a.before"
sleep 1
cntools_generation_activate "${cntools_root}" "${generation_a}" ||
  fail "idempotent generation activation failed"
pointer_state "${cntools_root}" "${TEST_ROOT}/activation-a.after"
cmp -s "${TEST_ROOT}/activation-a.before" "${TEST_ROOT}/activation-a.after" ||
  fail "idempotent activation rewrote generation pointers"
cntools_generation_recover "${cntools_root}" ||
  fail "no-op generation recovery failed"
pointer_state "${cntools_root}" "${TEST_ROOT}/activation-a.recovered"
cmp -s "${TEST_ROOT}/activation-a.after" "${TEST_ROOT}/activation-a.recovered" ||
  fail "no-op recovery changed generation pointers"

# A hard interruption may leave strict transaction-owned pointer temporaries.
# Recovery removes only self-consistent artifacts, restores the journal state,
# and leaves the canary pointers immediately valid.
valid_pointer_orphan="${cntools_root}/.active.99999999.12345"
printf 'schemaVersion=1\nactive=%s\nprevious=absent\n' "${generation_a}" > \
  "${cntools_root}/.generation-transaction"
chmod 0600 "${cntools_root}/.generation-transaction"
ln -s "generations/${generation_a}" "${valid_pointer_orphan}"
cntools_generation_recover "${cntools_root}" ||
  fail "valid interrupted generation artifacts were not recoverable"
assert_absent "${cntools_root}/.generation-transaction"
assert_absent "${valid_pointer_orphan}"
assert_link "${cntools_root}" active "${generation_a}"
assert_absent "${cntools_root}/previous"
cntools_generation_pointers_validate "${cntools_root}" ||
  fail "recovered generation pointers did not validate"

# Ambiguous pointer/journal artifacts are operator evidence: recovery must fail
# closed and preserve them byte-for-byte for inspection.
malformed_pointer_orphan="${cntools_root}/.active.99999999.23456"
printf 'schemaVersion=1\nactive=%s\nprevious=absent\n' "${generation_a}" > \
  "${cntools_root}/.generation-transaction"
chmod 0600 "${cntools_root}/.generation-transaction"
ln -s ../outside-generation "${malformed_pointer_orphan}"
expect_failure "malformed pointer orphan recovery" \
  cntools_generation_recover "${cntools_root}"
[[ -f "${cntools_root}/.generation-transaction" &&
   -L "${malformed_pointer_orphan}" &&
   "$(readlink "${malformed_pointer_orphan}")" == ../outside-generation ]] ||
  fail "failed pointer-orphan recovery did not preserve its evidence"
rm -- "${malformed_pointer_orphan}" "${cntools_root}/.generation-transaction"

malformed_journal_orphan="${cntools_root}/.generation-transaction.new.99999999"
printf 'not-a-generation-journal\n' > "${malformed_journal_orphan}"
chmod 0600 "${malformed_journal_orphan}"
expect_failure "malformed journal orphan recovery" \
  cntools_generation_recover "${cntools_root}"
[[ -f "${malformed_journal_orphan}" &&
   "$(< "${malformed_journal_orphan}")" == not-a-generation-journal ]] ||
  fail "failed journal-orphan recovery did not preserve its evidence"
rm -- "${malformed_journal_orphan}"

generation_b="$(build_generation "${cntools_root}" b)" || fail "could not build generation B"
[[ "${generation_b}" != "${generation_a}" ]] ||
  fail "distinct payloads produced the same generation ID"
assert_link "${cntools_root}" active "${generation_a}"
assert_absent "${cntools_root}/previous"
cntools_generation_activate "${cntools_root}" "${generation_b}" ||
  fail "generation B activation failed"
assert_link "${cntools_root}" active "${generation_b}"
assert_link "${cntools_root}" previous "${generation_a}"
cntools_generation_rollback "${cntools_root}" ||
  fail "generation rollback failed"
assert_link "${cntools_root}" active "${generation_a}"
assert_link "${cntools_root}" previous "${generation_b}"

pointer_state "${cntools_root}" "${TEST_ROOT}/invalid.before"
expect_failure "missing generation activation" \
  cntools_generation_activate "${cntools_root}" \
  0000000000000000000000000000000000000000000000000000000000000000
pointer_state "${cntools_root}" "${TEST_ROOT}/invalid.after"
cmp -s "${TEST_ROOT}/invalid.before" "${TEST_ROOT}/invalid.after" ||
  fail "missing generation activation changed pointers"

generation_b_file="${cntools_root}/generations/${generation_b}/cntools/docs/TESTING.md"
generation_b_saved="${TEST_ROOT}/generation-b.TESTING.md"
cp -- "${generation_b_file}" "${generation_b_saved}"
chmod 0644 "${generation_b_file}"
printf 'corrupt\n' >> "${generation_b_file}"
chmod 0444 "${generation_b_file}"
expect_failure "corrupt previous generation validation" \
  cntools_generation_validate "${cntools_root}/generations/${generation_b}" "${generation_b}"
pointer_state "${cntools_root}" "${TEST_ROOT}/corrupt.before"
expect_failure "rollback to corrupt previous generation" \
  cntools_generation_rollback "${cntools_root}"
pointer_state "${cntools_root}" "${TEST_ROOT}/corrupt.after"
cmp -s "${TEST_ROOT}/corrupt.before" "${TEST_ROOT}/corrupt.after" ||
  fail "failed corrupt-generation rollback changed pointers"
chmod 0644 "${generation_b_file}"
cp -- "${generation_b_saved}" "${generation_b_file}"
chmod 0444 "${generation_b_file}"
cntools_generation_validate \
  "${cntools_root}/generations/${generation_b}" "${generation_b}" ||
  fail "restored generation B did not validate"

# Executable generation members are untrusted until their recorded bytes have
# been checked. A syntactically valid tamper must be rejected without being
# sourced, even when its body would otherwise have an observable side effect.
for tampered_member in \
  cntools/core/bootstrap.sh \
  cntools/core/config.sh \
  cntools/core/lifecycle.sh \
  cntools/core/registry.sh; do
  tampered_file="${cntools_root}/generations/${generation_b}/${tampered_member}"
  tampered_saved="${TEST_ROOT}/$(basename "${tampered_member}").saved"
  tamper_sentinel="${TEST_ROOT}/$(basename "${tampered_member}").executed"
  cp -- "${tampered_file}" "${tampered_saved}"
  chmod 0644 "${tampered_file}"
  printf '#!/usr/bin/env bash\nprintf executed > %q\n' \
    "${tamper_sentinel}" > "${tampered_file}"
  chmod 0444 "${tampered_file}"
  expect_failure "tampered ${tampered_member} validation" \
    cntools_generation_validate \
      "${cntools_root}/generations/${generation_b}" "${generation_b}"
  assert_absent "${tamper_sentinel}"
  chmod 0644 "${tampered_file}"
  cp -- "${tampered_saved}" "${tampered_file}"
  chmod 0444 "${tampered_file}"
done
cntools_generation_validate \
  "${cntools_root}/generations/${generation_b}" "${generation_b}" ||
  fail "generation B did not validate after no-execution tamper cases"

outside_generation="${TEST_ROOT}/outside-generation"
cp -R -- "${cntools_root}/generations/${generation_b}" "${outside_generation}"
symlink_id=2222222222222222222222222222222222222222222222222222222222222222
ln -s "${outside_generation}" "${cntools_root}/generations/${symlink_id}"
pointer_state "${cntools_root}" "${TEST_ROOT}/symlink.before"
expect_failure "symlinked generation activation" \
  cntools_generation_activate "${cntools_root}" "${symlink_id}"
pointer_state "${cntools_root}" "${TEST_ROOT}/symlink.after"
cmp -s "${TEST_ROOT}/symlink.before" "${TEST_ROOT}/symlink.after" ||
  fail "symlinked generation activation changed pointers"

unsafe_root="${TEST_ROOT}/unsafe/scripts/.cntools"
mkdir -p -- "${unsafe_root}/generations"
chmod 0700 "${unsafe_root}" "${unsafe_root}/generations"
unsafe_a="$(build_generation "${unsafe_root}" unsafe-a)" ||
  fail "could not build unsafe-pointer generation"
ln -s ../../outside "${unsafe_root}/active"
pointer_state "${unsafe_root}" "${TEST_ROOT}/unsafe-pointer.before"
expect_failure "unsafe existing active pointer" \
  cntools_generation_activate "${unsafe_root}" "${unsafe_a}"
pointer_state "${unsafe_root}" "${TEST_ROOT}/unsafe-pointer.after"
cmp -s "${TEST_ROOT}/unsafe-pointer.before" "${TEST_ROOT}/unsafe-pointer.after" ||
  fail "unsafe active-pointer refusal changed pointers"

generation_c="$(build_generation "${cntools_root}" c)" || fail "could not build generation C"
generation_d="$(build_generation "${cntools_root}" d)" || fail "could not build generation D"
mkdir -- "${cntools_root}/generations/operator-sentinel"
printf 'operator data\n' > "${cntools_root}/generations/operator-sentinel/keep"
cntools_generation_prune "${cntools_root}" "${generation_c}" ||
  fail "safe generation pruning failed"
[[ -d "${cntools_root}/generations/${generation_a}" &&
   -d "${cntools_root}/generations/${generation_b}" &&
   -d "${cntools_root}/generations/${generation_c}" ]] ||
  fail "pruning removed active, previous, or explicitly retained generation"
assert_absent "${cntools_root}/generations/${generation_d}"
[[ -f "${cntools_root}/generations/operator-sentinel/keep" ]] ||
  fail "pruning removed an unvalidated operator directory"
[[ -L "${cntools_root}/generations/${symlink_id}" ]] ||
  fail "pruning followed or removed an unvalidated generation symlink"

# Lifecycle operations must remain valid across a normal version transition.
# Generation A's packaged lifecycle owns the initial activation, validates and
# activates B, and can still roll back to A after B becomes active.
cross_version_root="${TEST_ROOT}/cross-version/scripts/.cntools"
mkdir -p -- "${cross_version_root}/generations"
chmod 0700 "${cross_version_root}" "${cross_version_root}/generations"
cross_version_a="$(build_generation \
  "${cross_version_root}" version-13-5-7 13.5.7 1)" ||
  fail "could not build cross-version generation A"
cross_version_b="$(build_generation \
  "${cross_version_root}" version-13-5-8 13.5.8 1)" ||
  fail "could not build cross-version generation B"
cntools_generation_validate \
  "${cross_version_root}/generations/${cross_version_a}" \
  "${cross_version_a}" || fail "13.5.7 lifecycle rejected generation A"
cntools_generation_validate \
  "${cross_version_root}/generations/${cross_version_b}" \
  "${cross_version_b}" || fail "13.5.7 lifecycle rejected generation B (13.5.8)"
cntools_generation_activate "${cross_version_root}" "${cross_version_a}" ||
  fail "cross-version generation A activation failed"
cntools_generation_activate "${cross_version_root}" "${cross_version_b}" ||
  fail "cross-version generation B activation failed"
assert_link "${cross_version_root}" active "${cross_version_b}"
assert_link "${cross_version_root}" previous "${cross_version_a}"
cntools_generation_rollback "${cross_version_root}" ||
  fail "cross-version rollback to generation A failed"
assert_link "${cross_version_root}" active "${cross_version_a}"
assert_link "${cross_version_root}" previous "${cross_version_b}"

# The authenticated Stage 2 lifecycle must bridge the immutable Stage 1
# 19/20 generation shape and the Stage 2 29/30 shape in both directions.
cross_shape_root="${TEST_ROOT}/cross-shape/scripts/.cntools"
mkdir -p "${cross_shape_root}/generations"
chmod 0700 "${cross_shape_root}" "${cross_shape_root}/generations"
cross_shape_a="$(build_generation \
  "${cross_shape_root}" shape-a-schema1 13.5.7 1)" ||
  fail "could not build cross-shape schema-1 generation A"
cross_shape_b="$(build_generation \
  "${cross_shape_root}" shape-b-schema2 13.5.7 2)" ||
  fail "could not build cross-shape schema-2 generation B"
jq -e '.schemaVersion == 1 and (.files | length == 20)' \
  "${cross_shape_root}/generations/${cross_shape_a}/.generation.json" \
  >/dev/null || fail "cross-shape generation A is not receipt shape 1/20"
jq -e '.schemaVersion == 2 and (.files | length == 30)' \
  "${cross_shape_root}/generations/${cross_shape_b}/.generation.json" \
  >/dev/null || fail "cross-shape generation B is not receipt shape 2/30"
(
  # Only authenticated B code owns all cross-shape mutations.
  # shellcheck source=/dev/null
  . "${cross_shape_root}/generations/${cross_shape_b}/cntools/core/lifecycle.sh"
  cntools_generation_validate \
    "${cross_shape_root}/generations/${cross_shape_a}" "${cross_shape_a}"
  cntools_generation_validate \
    "${cross_shape_root}/generations/${cross_shape_b}" "${cross_shape_b}"
  cntools_generation_activate "${cross_shape_root}" "${cross_shape_a}"
  cntools_generation_activate "${cross_shape_root}" "${cross_shape_b}"
  cntools_generation_rollback "${cross_shape_root}"
  cntools_generation_activate "${cross_shape_root}" "${cross_shape_b}"
) || fail "authenticated B lifecycle could not bridge A 19/20 and B 29/30"
assert_link "${cross_shape_root}" active "${cross_shape_b}"
assert_link "${cross_shape_root}" previous "${cross_shape_a}"

# The authenticated Stage 3 lifecycle must likewise bridge the frozen Stage 2
# 29/30 generation shape and the current Stage 3 151/152 shape both ways.
cross_stage3_root="${TEST_ROOT}/cross-stage3/scripts/.cntools"
mkdir -p "${cross_stage3_root}/generations"
chmod 0700 "${cross_stage3_root}" "${cross_stage3_root}/generations"
cross_stage3_a="$(build_generation \
  "${cross_stage3_root}" stage3-a-schema2 13.5.7 2)" ||
  fail "could not build cross-Stage3 schema-2 generation A"
cross_stage3_b="$(build_generation \
  "${cross_stage3_root}" stage3-b-schema3 13.5.7 3)" ||
  fail "could not build cross-Stage3 schema-3 generation B"
jq -e '.schemaVersion == 2 and (.files | length == 30)' \
  "${cross_stage3_root}/generations/${cross_stage3_a}/.generation.json" \
  >/dev/null || fail "cross-Stage3 generation A is not receipt shape 2/30"
jq -e '.schemaVersion == 3 and (.files | length == 152)' \
  "${cross_stage3_root}/generations/${cross_stage3_b}/.generation.json" \
  >/dev/null || fail "cross-Stage3 generation B is not receipt shape 3/152"
(
  # Only authenticated schema-3 code owns these cross-generation mutations.
  # shellcheck source=/dev/null
  . "${cross_stage3_root}/generations/${cross_stage3_b}/cntools/core/lifecycle.sh"
  cntools_generation_validate \
    "${cross_stage3_root}/generations/${cross_stage3_a}" "${cross_stage3_a}"
  cntools_generation_validate \
    "${cross_stage3_root}/generations/${cross_stage3_b}" "${cross_stage3_b}"
  cntools_generation_activate "${cross_stage3_root}" "${cross_stage3_a}"
  cntools_generation_activate "${cross_stage3_root}" "${cross_stage3_b}"
  cntools_generation_rollback "${cross_stage3_root}"
  cntools_generation_activate "${cross_stage3_root}" "${cross_stage3_b}"
) || fail "authenticated Stage 3 lifecycle could not bridge 2/30 and 3/152"
assert_link "${cross_stage3_root}" active "${cross_stage3_b}"
assert_link "${cross_stage3_root}" previous "${cross_stage3_a}"

# Schema 2 is data-driven across legitimate bundle revisions. Trusted current
# lifecycle code validates two distinct, internally consistent bundle IDs,
# moves ID1 -> ID2, rolls back, and moves forward again without sourcing any
# candidate facade or chunk during validation/activation.
cross_id_root="${TEST_ROOT}/cross-id/scripts/.cntools"
cross_id_sentinel="${TEST_ROOT}/cross-id-candidate.executed"
mkdir -p "${cross_id_root}/generations"
chmod 0700 "${cross_id_root}" "${cross_id_root}/generations"
cross_id_generation_a="$(build_generation \
  "${cross_id_root}" cross-id-a 13.5.7 2 canonical)" ||
  fail "could not build cross-ID generation A"
cross_id_generation_b="$(build_generation \
  "${cross_id_root}" cross-id-b 13.5.7 2 changed)" ||
  fail "could not build cross-ID generation B"
cross_id_inspected="$(build_generation \
  "${cross_id_root}" cross-id-inspected 13.5.7 2 sentinel)" ||
  fail "could not build cross-ID no-execution candidate"
cross_id_bundle_a="$(jq -er '.legacyBundle.id' \
  "${cross_id_root}/generations/${cross_id_generation_a}/cntools/manifest.json")"
cross_id_bundle_b="$(jq -er '.legacyBundle.id' \
  "${cross_id_root}/generations/${cross_id_generation_b}/cntools/manifest.json")"
[[ "${cross_id_bundle_a}" != "${cross_id_bundle_b}" ]] ||
  fail "cross-ID fixture produced the same legacy bundle ID"
(
  # shellcheck source=/dev/null
  . "${cross_id_root}/generations/${cross_id_generation_a}/cntools/core/lifecycle.sh"
  cntools_generation_validate \
    "${cross_id_root}/generations/${cross_id_generation_a}" \
    "${cross_id_generation_a}"
  cntools_generation_validate \
    "${cross_id_root}/generations/${cross_id_generation_b}" \
    "${cross_id_generation_b}"
  cntools_generation_validate \
    "${cross_id_root}/generations/${cross_id_inspected}" \
    "${cross_id_inspected}"
  [[ ! -e "${cross_id_sentinel}" && ! -L "${cross_id_sentinel}" ]]
  cntools_generation_activate "${cross_id_root}" "${cross_id_generation_a}"
  cntools_generation_activate "${cross_id_root}" "${cross_id_generation_b}"
  cntools_generation_rollback "${cross_id_root}"
  cntools_generation_activate "${cross_id_root}" "${cross_id_generation_b}"
) || fail "trusted lifecycle could not bridge schema-2 bundle IDs"
assert_link "${cross_id_root}" active "${cross_id_generation_b}"
assert_link "${cross_id_root}" previous "${cross_id_generation_a}"
assert_absent "${cross_id_sentinel}"

# A generation receipt is self-authenticating data, not authority to execute
# the generation it describes. Even a fully rehashed and re-ID'd candidate may
# contain syntactically valid top-level code in config/registry; trusted B's
# lifecycle may inspect and recover pointers to it without sourcing those files.
inspection_root="${TEST_ROOT}/untrusted-inspection/scripts/.cntools"
mkdir -p -- "${inspection_root}/generations"
chmod 0700 "${inspection_root}" "${inspection_root}/generations"
trusted_inspector="$(build_generation "${inspection_root}" trusted-inspector)" ||
  fail "could not build trusted inspection generation B"
config_sentinel="${TEST_ROOT}/rehashed-config.executed"
registry_sentinel="${TEST_ROOT}/rehashed-registry.executed"
inspected_generation="$(build_rehashed_sentinel_generation \
  "${inspection_root}/generations/${trusted_inspector}" \
  "${inspection_root}" untrusted-a \
  "${config_sentinel}" "${registry_sentinel}")" ||
  fail "could not build fully rehashed untrusted generation A"
(
  # shellcheck source=/dev/null
  . "${inspection_root}/generations/${trusted_inspector}/cntools/core/lifecycle.sh"
  cntools_generation_validate \
    "${inspection_root}/generations/${inspected_generation}" \
    "${inspected_generation}"
) || fail "trusted B lifecycle rejected the self-consistent inspection fixture"
assert_absent "${config_sentinel}"
assert_absent "${registry_sentinel}"
printf 'schemaVersion=1\nactive=%s\nprevious=%s\n' \
  "${inspected_generation}" "${trusted_inspector}" > \
  "${inspection_root}/.generation-transaction"
chmod 0600 "${inspection_root}/.generation-transaction"
(
  # shellcheck source=/dev/null
  . "${inspection_root}/generations/${trusted_inspector}/cntools/core/lifecycle.sh"
  cntools_generation_recover "${inspection_root}"
) || fail "trusted B lifecycle could not recover inspected A pointers"
assert_link "${inspection_root}" active "${inspected_generation}"
assert_link "${inspection_root}" previous "${trusted_inspector}"
assert_absent "${config_sentinel}"
assert_absent "${registry_sentinel}"

[[ "$(sha256_file "${legacy_script}")" == "${legacy_hash}" &&
   "$(stat_inode "${legacy_script}")" == "${legacy_inode}" ]] ||
  fail "generation lifecycle changed the legacy public CNTools launcher"

printf 'CNTools Stage 3 generation lifecycle tests passed (active %s, previous %s)\n' \
  "${generation_a}" "${generation_b}"
