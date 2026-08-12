#!/usr/bin/env bash
# Validate the Guild-owned source distribution manifest as data. This
# suite deliberately does not source deployment code: the manifest contract
# must remain independently reviewable and fail closed before target mutation.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'Guild source manifest tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

LC_ALL=C
export LC_ALL

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MANIFEST="${REPO_ROOT}/files/node-implementations/source-manifest.tsv"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-source-manifest.XXXXXX")"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'Guild source manifest test failed: %s\n' "$1" >&2
  exit 1
}

manifest_error() {
  local manifest="$1"
  local line_number="$2"
  local message="$3"

  printf '%s:%s: %s\n' "${manifest}" "${line_number}" "${message}" >&2
  return 1
}

for required_command in awk cmp grep jq mktemp; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

# This is the complete installed/retired Stage 1 inventory. Keeping the
# expected records here makes adding an owned path an intentional contract
# change instead of allowing an unreviewed record to become authoritative.
EXPECTED_ROWS=(
  $'common\tscripts/cnode-helper-scripts/guild-deploy.sh\tscripts/guild-deploy.sh\t0755\tmerge-header\tshell'
  $'common\tscripts/common-helper-scripts/lib/deployment.library\tscripts/lib/deployment.library\t0644\texact\tshell'
  $'common\tscripts/common-helper-scripts/lib/env.library\tscripts/lib/env.library\t0644\texact\tshell'
  $'common\tscripts/common-helper-scripts/lib/node-api.library\tscripts/lib/node-api.library\t0644\texact\tshell'
  $'common\tscripts/common-helper-scripts/lib/systemd.library\tscripts/lib/systemd.library\t0644\texact\tshell'
  $'common\tscripts/{implementation}-helper-scripts/{implementation}.adapter\tscripts/adapters/{implementation}.adapter\t0644\texact\tshell'
  $'common\tscripts/common-helper-scripts/env\tscripts/env\t0644\tmerge-header\tshell'
  $'common\t-\tscripts/deploy-as-systemd.sh\t-\tretire\t-'
  $'common\t-\tscripts/.env_branch\t-\tretire\t-'
  $'cnode\tscripts/cnode-helper-scripts/blockPerf.sh\tscripts/blockPerf.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/cnode-helper-scripts/cabal-build-all.sh\tscripts/cabal-build-all.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/cnode-helper-scripts/cncli.sh\tscripts/cncli.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/cnode-helper-scripts/cnode.sh\tscripts/cnode.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/common-helper-scripts/cntools.sh\tscripts/cntools.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/common-helper-scripts/cntools/manifest.json\tscripts/cntools/libs/legacy\t0700\tcntools-legacy-bundle\tcntools'
  $'cnode\tscripts/common-helper-scripts/cntools.library\tscripts/cntools.library\t0644\tmerge-header\tshell'
  $'cnode\tscripts/common-helper-scripts/cntools/manifest.json\tscripts/.cntools\t0700\tcntools-generation\tcntools'
  $'cnode\tscripts/cnode-helper-scripts/dbsync.sh\tscripts/dbsync.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/common-helper-scripts/gLiveView.sh\tscripts/gLiveView.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/cnode-helper-scripts/topologyUpdater.sh\tscripts/topologyUpdater.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/cnode-helper-scripts/logMonitor.sh\tscripts/logMonitor.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/cnode-helper-scripts/ogmios.sh\tscripts/ogmios.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/cnode-helper-scripts/submitapi.sh\tscripts/submitapi.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/cnode-helper-scripts/setup_mon.sh\tscripts/setup_mon.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/grest-helper-scripts/setup-grest.sh\tscripts/setup-grest.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/grest-helper-scripts/grest-poll.sh\tscripts/grest-poll.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/grest-helper-scripts/checkstatus.sh\tscripts/checkstatus.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/grest-helper-scripts/getmetrics.sh\tscripts/getmetrics.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/cnode-helper-scripts/mithril-client.sh\tscripts/mithril-client.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/cnode-helper-scripts/mithril-relay.sh\tscripts/mithril-relay.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/cnode-helper-scripts/mithril-signer.sh\tscripts/mithril-signer.sh\t0755\tmerge-header\tshell'
  $'cnode\tscripts/cnode-helper-scripts/mithril.library\tscripts/mithril.library\t0644\tmerge-header\tshell'
  $'cnode\tfiles/node-implementations/cnode/release.json\tfiles/cnode-release.json\t0644\texact\tjson'
  $'cnode\tfiles/node-implementations/cnode/cntools-changelog.md\tfiles/cntools-changelog.md\t0644\texact\ttext'
  $'cnode\tfiles/configs/cnode/{network}/alonzo-genesis.json\tfiles/alonzo-genesis.json\t0644\tpreserve-render\tjson'
  $'cnode\tfiles/configs/cnode/{network}/byron-genesis.json\tfiles/byron-genesis.json\t0644\tpreserve-render\tjson'
  $'cnode\tfiles/configs/cnode/{network}/conway-genesis.json\tfiles/conway-genesis.json\t0644\tpreserve-render\tjson'
  $'cnode\tfiles/configs/cnode/{network}/shelley-genesis.json\tfiles/shelley-genesis.json\t0644\tpreserve-render\tjson'
  $'cnode\tfiles/configs/cnode/{network}/topology.json\tfiles/topology.json\t0644\tpreserve-render\tjson'
  $'cnode\tfiles/configs/cnode/{network}/config.json\tfiles/config.json\t0644\tpreserve-render\tjson'
  $'cnode\tfiles/configs/cnode/{network}/db-sync-config.json\tfiles/dbsync.json\t0644\tpreserve-render\tjson'
  $'cnode\tfiles/configs/cnode/{network}/submitapi.json\tfiles/submitapi.json\t0644\texact\tjson'
  $'dingo\tscripts/dingo-helper-scripts/dingo.sh\tscripts/dingo.sh\t0755\texact\tshell'
  $'dingo\tscripts/common-helper-scripts/gLiveView.sh\tscripts/gLiveView.sh\t0755\tmerge-header\tshell'
  $'dingo\tscripts/common-helper-scripts/cntools/manifest.json\tscripts/cntools/libs/legacy\t0700\tcntools-legacy-bundle\tcntools'
  $'dingo\tscripts/common-helper-scripts/cntools.library\tscripts/cntools.library\t0644\tmerge-header\tshell'
  $'dingo\tscripts/common-helper-scripts/cntools.sh\tscripts/cntools.sh\t0755\tmerge-header\tshell'
  $'dingo\tscripts/common-helper-scripts/cntools/manifest.json\tscripts/.cntools\t0700\tcntools-generation\tcntools'
  $'dingo\tfiles/configs/dingo/{network}/dingo.yaml\tfiles/dingo.yaml\t0640\tpreserve-render\ttext'
  $'dingo\tfiles/configs/dingo/{network}/dingo.env\tscripts/dingo.env\t0640\tpreserve-render\tshell'
  $'dingo\tfiles/node-implementations/dingo/release.json\tfiles/dingo-release.json\t0644\texact\tjson'
  $'dingo\tfiles/node-implementations/cnode/cntools-changelog.md\tfiles/cntools-changelog.md\t0644\texact\ttext'
  $'amaru\tscripts/amaru-helper-scripts/amaru.sh\tscripts/amaru.sh\t0755\texact\tshell'
  $'amaru\tscripts/common-helper-scripts/gLiveView.sh\tscripts/gLiveView.sh\t0755\tmerge-header\tshell'
  $'amaru\tfiles/configs/amaru/{network}/amaru.env\tscripts/amaru.env\t0640\tpreserve-render\tshell'
  $'amaru\tfiles/configs/amaru/otelcol.yaml\tfiles/otelcol.yaml\t0644\texact\ttext'
  $'amaru\tfiles/node-implementations/amaru/release.json\tfiles/amaru-release.json\t0644\texact\tjson'
)

manifest_scope_implementations() {
  case "$1" in
    common) printf '%s\n' cnode dingo amaru ;;
    cnode|dingo|amaru) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

manifest_implementation_networks() {
  case "$1" in
    cnode) printf '%s\n' mainnet guild preprod preview ;;
    dingo|amaru) printf '%s\n' preprod preview ;;
    *) return 1 ;;
  esac
}

manifest_expand_path() {
  local path_template="$1"
  local implementation="$2"
  local network="$3"

  path_template="${path_template//\{implementation\}/${implementation}}"
  path_template="${path_template//\{network\}/${network}}"
  printf '%s\n' "${path_template}"
}

manifest_path_template_valid() {
  local path_template="$1"
  local stripped=""

  [[ -n "${path_template}" && "${path_template}" != "-" ]] || return 1
  [[ "${path_template}" =~ ^(scripts|files)/[A-Za-z0-9._/+@:\{\}-]+$ ]] ||
    return 1
  [[ "${path_template}" != /* &&
     "${path_template}" != */ &&
     "${path_template}" != *//* &&
     "${path_template}" != *\\* ]] || return 1
  stripped="${path_template//\{implementation\}/}"
  stripped="${stripped//\{network\}/}"
  [[ "${stripped}" != *'{'* && "${stripped}" != *'}'* ]] || return 1
}

manifest_expanded_path_valid() {
  local expanded_path="$1"
  local component=""
  local -a components=()

  [[ "${expanded_path}" =~ ^(scripts|files)/[A-Za-z0-9._/+@:-]+$ ]] ||
    return 1
  [[ "${expanded_path}" != /* &&
     "${expanded_path}" != */ &&
     "${expanded_path}" != *//* &&
     "${expanded_path}" != *\\* ]] || return 1
  IFS='/' read -r -a components <<< "${expanded_path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != "." &&
       "${component}" != ".." ]] || return 1
  done
}

manifest_validate_source_file() {
  local source_path="$1"
  local validator="$2"
  local policy="$3"
  local absolute_source="${REPO_ROOT}/${source_path}"

  [[ -f "${absolute_source}" && ! -L "${absolute_source}" &&
     -s "${absolute_source}" ]] || return 1
  case "${validator}" in
    shell)
      "${BASH}" -n "${absolute_source}" >/dev/null 2>&1 || return 1
      ;;
    json|cntools)
      jq -e . "${absolute_source}" >/dev/null 2>&1 || return 1
      ;;
    text) ;;
    *) return 1 ;;
  esac
  if [[ "${policy}" == "merge-header" ]]; then
    grep -q '^# Do NOT modify code below' "${absolute_source}" || return 1
  fi
}

validate_manifest_structure() {
  local manifest="$1"
  local first_line=""
  local line=""
  local without_tabs=""
  local line_number=0
  local record_count=0
  local implementation=""
  local source_path=""
  local target_path=""
  local mode=""
  local policy=""
  local validator=""
  local effective_implementation=""
  local network=""
  local expanded_source=""
  local expanded_target=""
  local source_key=""
  local target_key=""
  local validation_key=""
  local -A source_paths=()
  local -A target_paths=()
  local -A validated_sources=()

  [[ -f "${manifest}" && ! -L "${manifest}" && -s "${manifest}" ]] || {
    printf '%s: manifest is missing, empty, or a symbolic link\n' "${manifest}" >&2
    return 1
  }
  IFS= read -r first_line < "${manifest}" || return 1
  [[ "${first_line}" == '# Guild Operators deployment source manifest, schema 2.' ]] || {
    printf '%s: unsupported or missing schema declaration\n' "${manifest}" >&2
    return 1
  }

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" != *$'\r'* ]] ||
      manifest_error "${manifest}" "${line_number}" "carriage return is unsupported" || return 1
    without_tabs="${line//$'\t'/}"
    (( ${#line} - ${#without_tabs} == 5 )) ||
      manifest_error "${manifest}" "${line_number}" "expected exactly six tab-separated fields" || return 1
    IFS=$'\t' read -r implementation source_path target_path mode policy validator <<< "${line}"
    [[ -n "${implementation}" && -n "${source_path}" &&
       -n "${target_path}" && -n "${mode}" &&
       -n "${policy}" && -n "${validator}" ]] ||
      manifest_error "${manifest}" "${line_number}" "manifest fields must not be empty" || return 1

    case "${implementation}" in common|cnode|dingo|amaru) ;; *)
      manifest_error "${manifest}" "${line_number}" "unsupported implementation '${implementation}'" || return 1
    esac
    case "${policy}" in
      exact|merge-header|render-cnode|render-dingo|render-amaru|preserve-render|retire|cntools-legacy-bundle|cntools-generation) ;;
      *) manifest_error "${manifest}" "${line_number}" "unsupported policy '${policy}'" || return 1 ;;
    esac
    case "${mode}" in 0640|0644|0700|0755|-) ;; *)
      manifest_error "${manifest}" "${line_number}" "unsupported mode '${mode}'" || return 1 ;;
    esac
    case "${validator}" in shell|json|text|cntools|-) ;; *)
      manifest_error "${manifest}" "${line_number}" "unsupported validator '${validator}'" || return 1 ;;
    esac

    manifest_path_template_valid "${target_path}" ||
      manifest_error "${manifest}" "${line_number}" "unsafe or unsupported target path '${target_path}'" || return 1
    if [[ "${implementation}" != "common" &&
          ( "${source_path}" == *'{implementation}'* ||
            "${target_path}" == *'{implementation}'* ) ]]; then
      manifest_error "${manifest}" "${line_number}" "implementation placeholder is valid only for common records" || return 1
    fi

    if [[ "${policy}" == "retire" ]]; then
      [[ "${source_path}" == "-" && "${mode}" == "-" &&
         "${validator}" == "-" ]] ||
        manifest_error "${manifest}" "${line_number}" "retire records require '-' source, mode, and validator" || return 1
    else
      [[ "${source_path}" != "-" && "${mode}" != "-" &&
         "${validator}" != "-" ]] ||
        manifest_error "${manifest}" "${line_number}" "non-retire records cannot use '-' fields" || return 1
      manifest_path_template_valid "${source_path}" ||
        manifest_error "${manifest}" "${line_number}" "unsafe or unsupported source path '${source_path}'" || return 1
    fi

    if [[ "${policy}" == "merge-header" && "${validator}" != "shell" ]]; then
      manifest_error "${manifest}" "${line_number}" "merge-header requires the shell validator" || return 1
    fi
    if [[ "${policy}" == "cntools-generation" ]]; then
      [[ ( "${implementation}" == "cnode" ||
           "${implementation}" == "dingo" ) &&
         "${source_path}" == "scripts/common-helper-scripts/cntools/manifest.json" &&
         "${target_path}" == "scripts/.cntools" &&
         "${mode}" == "0700" && "${validator}" == "cntools" ]] ||
        manifest_error "${manifest}" "${line_number}" "cntools-generation requires the fixed cnode/Dingo source, target, mode, and validator" || return 1
    elif [[ "${policy}" == "cntools-legacy-bundle" ]]; then
      [[ ( "${implementation}" == "cnode" ||
           "${implementation}" == "dingo" ) &&
         "${source_path}" == "scripts/common-helper-scripts/cntools/manifest.json" &&
         "${target_path}" == "scripts/cntools/libs/legacy" &&
         "${mode}" == "0700" && "${validator}" == "cntools" ]] ||
        manifest_error "${manifest}" "${line_number}" "cntools-legacy-bundle requires the fixed cnode/Dingo source, target, mode, and validator" || return 1
    else
      [[ "${mode}" != "0700" && "${validator}" != "cntools" ]] ||
        manifest_error "${manifest}" "${line_number}" "0700/cntools are reserved for CNTools special policies" || return 1
    fi
    if [[ "${policy}" == "preserve-render" &&
          "${implementation}" == "common" ]]; then
      manifest_error "${manifest}" "${line_number}" "preserve-render requires an implementation-specific record" || return 1
    fi
    case "${policy}" in
      render-cnode) [[ "${implementation}" == "cnode" ]] ||
        manifest_error "${manifest}" "${line_number}" "render-cnode requires cnode scope" || return 1 ;;
      render-dingo) [[ "${implementation}" == "dingo" ]] ||
        manifest_error "${manifest}" "${line_number}" "render-dingo requires dingo scope" || return 1 ;;
      render-amaru) [[ "${implementation}" == "amaru" ]] ||
        manifest_error "${manifest}" "${line_number}" "render-amaru requires amaru scope" || return 1 ;;
    esac

    while IFS= read -r effective_implementation; do
      while IFS= read -r network; do
        expanded_target="$(manifest_expand_path "${target_path}" "${effective_implementation}" "${network}")" || return 1
        manifest_expanded_path_valid "${expanded_target}" ||
          manifest_error "${manifest}" "${line_number}" "target does not normalize safely: '${expanded_target}'" || return 1
        target_key="${effective_implementation}|${network}|${expanded_target}"
        [[ -z "${target_paths[${target_key}]+set}" ]] ||
          manifest_error "${manifest}" "${line_number}" "duplicate effective target '${expanded_target}' for ${effective_implementation}/${network}" || return 1
        target_paths["${target_key}"]="${line_number}"

        if [[ "${policy}" != "retire" ]]; then
          expanded_source="$(manifest_expand_path "${source_path}" "${effective_implementation}" "${network}")" || return 1
          manifest_expanded_path_valid "${expanded_source}" ||
            manifest_error "${manifest}" "${line_number}" "source does not normalize safely: '${expanded_source}'" || return 1
          source_key="${effective_implementation}|${network}|${expanded_source}"
          case "${policy}" in
            cntools-generation|cntools-legacy-bundle)
              source_key+="|${policy}"
              ;;
          esac
          [[ -z "${source_paths[${source_key}]+set}" ]] ||
            manifest_error "${manifest}" "${line_number}" "duplicate effective source '${expanded_source}' for ${effective_implementation}/${network}" || return 1
          source_paths["${source_key}"]="${line_number}"
          validation_key="${expanded_source}|${validator}|${policy}"
          if [[ -z "${validated_sources[${validation_key}]+set}" ]]; then
            manifest_validate_source_file "${expanded_source}" "${validator}" "${policy}" ||
              manifest_error "${manifest}" "${line_number}" "source failed ${validator}/${policy} validation: '${expanded_source}'" || return 1
            validated_sources["${validation_key}"]="Y"
          fi
        fi
      done < <(manifest_implementation_networks "${effective_implementation}")
    done < <(manifest_scope_implementations "${implementation}")
    record_count=$((record_count + 1))
  done < "${manifest}"

  (( record_count > 0 )) || {
    printf '%s: manifest contains no records\n' "${manifest}" >&2
    return 1
  }
}

assert_required_inventory() {
  local manifest="$1"
  local line=""
  local expected=""
  local actual=""
  local actual_count=0
  local -A expected_rows=()
  local -A actual_rows=()

  for expected in "${EXPECTED_ROWS[@]}"; do
    [[ -z "${expected_rows[${expected}]+set}" ]] ||
      fail "test inventory contains a duplicate expected record: ${expected}"
    expected_rows["${expected}"]="Y"
  done
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ -z "${actual_rows[${line}]+set}" ]] ||
      fail "manifest contains a duplicate raw record: ${line}"
    actual_rows["${line}"]="Y"
    actual_count=$((actual_count + 1))
  done < "${manifest}"

  [[ ${actual_count} -eq ${#EXPECTED_ROWS[@]} ]] ||
    fail "expected ${#EXPECTED_ROWS[@]} source records, found ${actual_count}"
  for expected in "${EXPECTED_ROWS[@]}"; do
    [[ -n "${actual_rows[${expected}]+set}" ]] ||
      fail "required source record is missing: ${expected}"
  done
  for actual in "${!actual_rows[@]}"; do
    [[ -n "${expected_rows[${actual}]+set}" ]] ||
      fail "unsupported source record is present: ${actual}"
  done
}

assert_cntools_reader_isolation_order() {
  local manifest="$1"
  local selected_implementation=""
  local implementation="" source_path="" target_path="" mode=""
  local policy="" validator="" extra=""
  local first_applicable_policy="" first_ordinary_target=""

  for selected_implementation in cnode dingo; do
    first_applicable_policy=""
    first_ordinary_target=""
    while IFS=$'\t' read -r implementation source_path target_path mode \
      policy validator extra; do
      [[ -n "${implementation}" && "${implementation}" != \#* ]] || continue
      [[ -z "${extra}" ]] ||
        fail "reader-isolation order probe found an extra source-manifest field"
      [[ "${implementation}" == "common" ||
         "${implementation}" == "${selected_implementation}" ]] || continue
      [[ -n "${first_applicable_policy}" ]] ||
        first_applicable_policy="${policy}"
      case "${policy}" in
        cntools-legacy-bundle|cntools-generation) continue ;;
      esac
      first_ordinary_target="${target_path}"
      break
    done < "${manifest}"
    [[ "${first_applicable_policy}" == "cntools-legacy-bundle" ]] ||
      fail "${selected_implementation} legacy bundle is not the first applicable source record"
    [[ "${first_ordinary_target}" == "scripts/cntools.library" ]] ||
      fail "${selected_implementation} facade is not the first ordinary activation target"
  done
}

expect_structural_rejection() {
  local name="$1"
  local awk_program="$2"
  local candidate="${TEST_ROOT}/${name}.tsv"

  awk "${awk_program}" "${MANIFEST}" > "${candidate}" ||
    fail "could not build ${name} manifest mutation"
  if validate_manifest_structure "${candidate}" >/dev/null 2>&1; then
    fail "structural validator accepted ${name} mutation"
  fi
}

validate_manifest_structure "${MANIFEST}" ||
  fail "checked-in source manifest failed structural validation"
assert_required_inventory "${MANIFEST}"
assert_cntools_reader_isolation_order "${MANIFEST}"
cmp -s "${REPO_ROOT}/docs/Scripts/cntools-changelog.md" \
  "${REPO_ROOT}/files/node-implementations/cnode/cntools-changelog.md" ||
  fail "packaged CNTools changelog differs from its documentation source"

# Prove that each fail-closed boundary exercised above is active rather than a
# descriptive check that happens to accept the checked-in file.
expect_structural_rejection extra-column '
  BEGIN { changed = 0 }
  !changed && $0 !~ /^#/ && NF { print $0 "\textra"; changed = 1; next }
  { print }
'
expect_structural_rejection unknown-implementation '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $0 !~ /^#/ && NF { $1 = "other"; changed = 1 }
  { print }
'
expect_structural_rejection traversal-source '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $0 !~ /^#/ && NF && $5 != "retire" {
    $2 = "scripts/../unsafe.sh"; changed = 1
  }
  { print }
'
expect_structural_rejection unknown-placeholder '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $0 !~ /^#/ && NF && $5 != "retire" {
    $2 = "scripts/{account}/unsafe.sh"; changed = 1
  }
  { print }
'
expect_structural_rejection unsupported-policy '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $0 !~ /^#/ && NF { $5 = "copy-ish"; changed = 1 }
  { print }
'
expect_structural_rejection unsupported-mode '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $0 !~ /^#/ && NF && $5 != "retire" {
    $4 = "0777"; changed = 1
  }
  { print }
'
expect_structural_rejection unsupported-validator '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $0 !~ /^#/ && NF && $5 != "retire" {
    $6 = "eval"; changed = 1
  }
  { print }
'
expect_structural_rejection malformed-retire '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $0 !~ /^#/ && NF && $5 == "retire" {
    $4 = "0644"; changed = 1
  }
  { print }
'
expect_structural_rejection cntools-generation-common-scope '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $5 == "cntools-generation" {
    $1 = "common"; changed = 1
  }
  { print }
'
expect_structural_rejection cntools-generation-wrong-source '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $5 == "cntools-generation" {
    $2 = "scripts/common-helper-scripts/cntools/VERSION"; changed = 1
  }
  { print }
'
expect_structural_rejection cntools-generation-wrong-target '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $5 == "cntools-generation" {
    $3 = "scripts/cntools"; changed = 1
  }
  { print }
'
expect_structural_rejection cntools-generation-wrong-mode '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $5 == "cntools-generation" {
    $4 = "0644"; changed = 1
  }
  { print }
'
expect_structural_rejection cntools-generation-wrong-validator '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $5 == "cntools-generation" {
    $6 = "json"; changed = 1
  }
  { print }
'
expect_structural_rejection cntools-legacy-bundle-common-scope '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $5 == "cntools-legacy-bundle" {
    $1 = "common"; changed = 1
  }
  { print }
'
expect_structural_rejection cntools-legacy-bundle-wrong-source '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $5 == "cntools-legacy-bundle" {
    $2 = "scripts/common-helper-scripts/cntools/VERSION"; changed = 1
  }
  { print }
'
expect_structural_rejection cntools-legacy-bundle-wrong-target '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $5 == "cntools-legacy-bundle" {
    $3 = "scripts/cntools/libs"; changed = 1
  }
  { print }
'
expect_structural_rejection cntools-legacy-bundle-wrong-mode '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $5 == "cntools-legacy-bundle" {
    $4 = "0644"; changed = 1
  }
  { print }
'
expect_structural_rejection cntools-legacy-bundle-wrong-validator '
  BEGIN { FS = OFS = "\t"; changed = 0 }
  !changed && $5 == "cntools-legacy-bundle" {
    $6 = "json"; changed = 1
  }
  { print }
'
expect_structural_rejection duplicate-effective-path '
  { lines[NR] = $0; if (first == "" && $0 !~ /^#/ && NF) first = $0 }
  END { for (i = 1; i <= NR; i++) print lines[i]; print first }
'

# A structurally valid source can still be outside the approved installed
# inventory. It must be rejected by the exact inventory gate.
unsupported_candidate="${TEST_ROOT}/unsupported-record.tsv"
awk '{ print } END {
  print "cnode\tscripts/cnode-helper-scripts/deploy-cnode.sh\tscripts/unsupported-profile.sh\t0755\texact\tshell"
}' "${MANIFEST}" > "${unsupported_candidate}"
validate_manifest_structure "${unsupported_candidate}" ||
  fail "unsupported-record fixture was not structurally valid"
if (
  assert_required_inventory "${unsupported_candidate}"
) >/dev/null 2>&1; then
  fail "inventory gate accepted an unsupported source record"
fi

printf 'Guild source manifest contract tests passed (%d records)\n' \
  "${#EXPECTED_ROWS[@]}"
