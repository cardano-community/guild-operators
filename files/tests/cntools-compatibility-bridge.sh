#!/usr/bin/env bash
# Focused contract for the shipped Stage 4 compatibility bridge. Synthetic
# installed generations and lifecycle seams keep this test bounded while the
# real bridge, registry, context, result, and dispatcher bytes execute.
# shellcheck disable=SC1090,SC2317
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools compatibility bridge tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

LC_ALL=C
export LC_ALL

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
PAYLOAD_MANIFEST="${CNTOOLS_ROOT}/manifest.json"
REAL_REGISTRY="${CNTOOLS_ROOT}/core/registry.sh"
REAL_CONTEXT="${CNTOOLS_ROOT}/core/context.sh"
REAL_RESULT="${CNTOOLS_ROOT}/core/result.sh"
REAL_DISPATCHER="${CNTOOLS_ROOT}/core/dispatcher.sh"
MODULES_ROOT="${CNTOOLS_ROOT}/modules/root"
MNEMONIC_BUNDLE_ID="$(printf 'b%.0s' {1..64})"
MNEMONIC_MEMBER_BASENAME='050-wallet-create-registration.sh'
MNEMONIC_SNAPSHOT_BASENAME='compatibility-wallet-mnemonic.sh'
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-bridge.XXXXXX")"
TEST_ROOT="$(cd -P -- "${TEST_ROOT}" && pwd -P)"
BRIDGE_DEFINITION=""
CALL_STATUS=0

bridge_test_cleanup() {
  chmod -R u+rwX "${TEST_ROOT}" >/dev/null 2>&1 || true
  rm -rf -- "${TEST_ROOT}"
}
trap bridge_test_cleanup EXIT

fail() {
  printf 'CNTools compatibility bridge test failed: %s\n' "$1" >&2
  exit 1
}

for command_name in bash chmod cmp cp find grep jq ln mkdir mktemp mv rm \
  rmdir sed sha256sum sort stat tr wc; do
  command -v "${command_name}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${command_name}"
done

for source_file in "${CNTOOLS_SCRIPT}" "${PAYLOAD_MANIFEST}" \
  "${REAL_REGISTRY}" "${REAL_CONTEXT}" "${REAL_RESULT}" \
  "${REAL_DISPATCHER}"; do
  [[ -f "${source_file}" && ! -L "${source_file}" ]] ||
    fail "required source is missing or unsafe: ${source_file}"
done

# Definition-only sourcing is a public entrypoint contract.
# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
source "${CNTOOLS_SCRIPT}"
BRIDGE_DEFINITION="$(declare -f cntools_compatibility_dispatch_action)" ||
  fail 'could not preserve the shipped compatibility bridge definition'

file_hash() {
  local output=""
  output="$(sha256sum -- "$1")" || return 1
  printf '%s\n' "${output%%[[:space:]]*}"
}

capture_call() {
  local stdout_file="$1" stderr_file="$2"
  shift 2
  : > "${stdout_file}"
  : > "${stderr_file}"
  set +e
  "$@" > "${stdout_file}" 2> "${stderr_file}"
  CALL_STATUS=$?
  set -e
}

assert_status() {
  [[ "${CALL_STATUS}" -eq "$1" ]] ||
    fail "$2: expected status $1, got ${CALL_STATUS}"
}

assert_empty() {
  [[ ! -s "$1" ]] || fail "$2: expected empty output"
}

assert_text() {
  local expected_file="${TEST_ROOT}/expected.$$.${RANDOM}"
  printf '%s' "$2" > "${expected_file}"
  cmp -s -- "$1" "${expected_file}" || fail "$3: output bytes changed"
  rm -f -- "${expected_file}"
}

assert_no_private_state() {
  [[ -z "$(find "$1" -mindepth 1 \
      \( -name 'cntools-compatibility.*' -o \
         -name "${MNEMONIC_SNAPSHOT_BASENAME}" \) -print -quit)" ]] ||
    fail "$2: private bridge state was retained"
}

write_action() {
  local target="$1" behavior="$2"

  case "${behavior}" in
    probe)
      {
        printf '%s\n' '#!/usr/bin/env bash' \
          'cntools_action_main() {' \
          '  local context_file="${1:-}" result_file="${2:-}"' \
          '  local arguments_file="${3:-}" status="${4:-0}" result_kind="${5:-absent}"' \
          '  local node_home_physical=""' \
          '  shift 5 || return 64' \
          '  printf "action:main:%s\n" "${CNTOOLS_BRIDGE_CASE:?}" >> "${CNTOOLS_BRIDGE_EVENTS:?}"' \
          '  node_home_physical="$(cd -P -- "${NODE_HOME}" && pwd -P)" || return 89' \
          '  jq -e --arg node_home "${node_home_physical}" "' \
          '    .schemaVersion == 1 and .apiVersion == 1 and' \
          '    .generationVersion == \"13.5.7\" and .mode == \"offline\" and' \
          '    .advanced == true and .nodeHome == \$node_home and' \
          '    .nodeImplementation == \"cnode\" and .nodeNetwork == \"preview\" and' \
          '    .features == [\"advanced\"] and' \
          '    .capabilities == [\"forging\",\"local-cli\",\"metrics\",\"n2c\"]' \
          '  " "${context_file}" >/dev/null 2>&1 || return 90' \
          '  cntools_generation_lock_acquire "${NODE_HOME}/scripts/.cntools" || return 91' \
          '  cntools_generation_lock_release "${NODE_HOME}/scripts/.cntools" || return 92' \
          '  printf "action:fresh-lock\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"' \
          '  printf "%s\0" "$@" > "${arguments_file}"' \
          '  case "${result_kind}" in' \
          '    absent) ;;' \
          '    valid)' \
          '      umask 077' \
          '      printf "%s\n" "{" "  \"data\": {}," "  \"schemaVersion\": 1" "}" > "${result_file}"' \
          '      chmod 600 "${result_file}"' \
          '      ;;' \
          '    malformed)' \
          '      printf "%s\n" "{" > "${result_file}"' \
          '      chmod 600 "${result_file}"' \
          '      ;;' \
          '    noncanonical)' \
          '      printf "%s\n" "{\"data\":{},\"schemaVersion\":1}" > "${result_file}"' \
          '      chmod 600 "${result_file}"' \
          '      ;;' \
          '    hardlink)' \
          '      ln -- "${arguments_file}" "${result_file}"' \
          '      ;;' \
          '    symlink)' \
          '      ln -s -- "${arguments_file}" "${result_file}"' \
          '      ;;' \
          '    oversized)' \
          '      head -c 1048577 /dev/zero | tr "\\0" a > "${result_file}"' \
          '      chmod 600 "${result_file}"' \
          '      ;;' \
          '    unsafe-mode)' \
          '      printf "%s\n" "{" "  \"data\": {}," "  \"schemaVersion\": 1" "}" > "${result_file}"' \
          '      chmod 644 "${result_file}"' \
          '      ;;' \
          '  esac' \
          '  printf "bridge-stdout:%s" "${status}"' \
          '  printf "bridge-stderr:%s" "${status}" >&2' \
          '  return "${status}"' \
          '}'
      } > "${target}"
      ;;
    inert)
      printf '%s\n' '#!/usr/bin/env bash' \
        'cntools_action_main() { return 64; }' > "${target}"
      ;;
    mnemonic-probe)
      printf '%s\n' '#!/usr/bin/env bash' \
        'cntools_action_main() {' \
        '  printf "action:main:%s\n" "${CNTOOLS_BRIDGE_CASE:?}" >> "${CNTOOLS_BRIDGE_EVENTS:?}"' \
        '  [[ "${CNTOOLS_BRIDGE_LOCKED:-N}" != Y ]] || return 93' \
        '  [[ "${CNTOOLS_BRIDGE_EXTDEBUG:-N}" != Y ]] || shopt -q extdebug || return 95' \
        '  createMnemonicWallet' \
        '}' \
        > "${target}"
      ;;
    *) return 1 ;;
  esac
  chmod 0444 "${target}"
}

write_mnemonic_sidecar() {
  local target="$1" behavior="${2:-valid}"

  {
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'createNewWallet() { :; }' \
      'printWalletInfo() { :; }' \
      'buildOfflineJSON() { :; }' \
      'registerStakeWallet() { :; }' \
      'deregisterStakeWallet() { :; }'
    if [[ "${behavior}" != omit-shared ]]; then
      printf '%s\n' \
        '_cntools_compatibility_wallet_mnemonic_run() {' \
        '  [[ "${CNTOOLS_BRIDGE_LOCKED:-N}" != Y ]] || return 94' \
        '  printf "sidecar:run\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"' \
        '}'
    fi
    printf '%s\n' \
      'createMnemonicWallet() {' \
      '  _cntools_compatibility_wallet_mnemonic_run' \
      '}'
    case "${behavior}" in
      valid|omit-shared) ;;
      extra-reserved)
        printf '%s\n' 'cntools_dispatcher_run_action() { return 95; }'
        ;;
      extra-prefixed)
        printf '%s\n' '_cntools_compatibility_wallet_mnemonic_extra() { return 95; }'
        ;;
      source-output)
        printf '%s\n' 'printf "unsafe-sidecar-output\n"'
        ;;
      source-variable)
        printf '%s\n' 'CNTOOLS_UNSAFE_SIDECAR_VARIABLE=Y'
        ;;
      source-existing-variable)
        printf '%s\n' 'CNTOOLS_BRIDGE_CASE=sidecar-mutated'
        ;;
      source-alias)
        printf '%s\n' "alias cntools_unsafe_sidecar='printf unsafe'"
        ;;
      function-export)
        printf '%s\n' 'export -f createMnemonicWallet'
        ;;
      function-readonly)
        printf '%s\n' 'readonly -f createMnemonicWallet'
        ;;
      child-source-fail)
        printf '%s\n' 'return 96'
        ;;
      live-source-fail)
        printf '%s\n' \
          '[[ "${CNTOOLS_COMPATIBILITY_SIDECAR_CONTRACT:-N}" == Y ]] || return 97'
        ;;
      syntax-fail)
        printf '%s\n' 'if then'
        ;;
      *) return 1 ;;
    esac
    if [[ "${behavior}" != child-source-fail &&
          "${behavior}" != live-source-fail &&
          "${behavior}" != syntax-fail ]]; then
      # Synthetic authority assertion: the clean contract subprocess gets its
      # explicit marker; the live source must still be under the generation lock.
      printf '%s\n' \
        '[[ "${CNTOOLS_COMPATIBILITY_SIDECAR_CONTRACT:-N}" == Y ||' \
        '   "${CNTOOLS_BRIDGE_LOCKED:-N}" == Y ]] || return 98'
    fi
  } > "${target}"
  chmod 0444 "${target}"
}

write_lifecycle() {
  local target="$1"
  {
    printf '%s\n' '#!/usr/bin/env bash' \
      'cntools_generation_validate() {' \
      '  printf "lifecycle:validate\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"' \
      '  [[ "${CNTOOLS_BRIDGE_FAIL_GENERATION_VALIDATE:-N}" != Y ]]' \
      '}' \
      'cntools_generation_pointers_validate() {' \
      '  printf "lifecycle:pointers\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"' \
      '}' \
      'cntools_generation_lock_acquire() {' \
      '  local state_root="${1:-}"' \
      '  if [[ "${CNTOOLS_BRIDGE_LOCKED:-N}" == Y ]]; then return 75; fi' \
      '  CNTOOLS_BRIDGE_LOCKED=Y' \
      '  export CNTOOLS_BRIDGE_LOCKED' \
      '  printf "lock:acquire\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"' \
      '  [[ -n "${state_root}" ]]' \
      '}' \
      'cntools_generation_lock_release() {' \
      '  local state_root="${1:-}"' \
      '  [[ "${CNTOOLS_BRIDGE_LOCKED:-N}" == Y && -n "${state_root}" ]] || return 76' \
      '  if [[ "${CNTOOLS_BRIDGE_FAIL_RELEASE:-N}" == Y ]]; then' \
      '    printf "lock:release-failed\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"' \
      '    return 77' \
      '  fi' \
      '  CNTOOLS_BRIDGE_LOCKED=N' \
      '  export CNTOOLS_BRIDGE_LOCKED' \
      '  printf "lock:release\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"' \
      '  if [[ "${CNTOOLS_BRIDGE_PRUNE_AFTER_RELEASE:-N}" == Y &&' \
      '        ! -e "${NODE_HOME}/tmp/.bridge-generation-pruned" ]]; then' \
      '    : > "${NODE_HOME}/tmp/.bridge-generation-pruned"' \
      '    chmod -R u+w "${state_root}/generations" 2>/dev/null || return 78' \
      '    rm -rf -- "${state_root}/generations/"* || return 79' \
      '    printf "generation:pruned\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"' \
      '  fi' \
      '}'
  } > "${target}"
  chmod 0444 "${target}"
}

build_fixture() {
  local root="$1" action_id="${2:-advanced.asset.list}"
  local sidecar_behavior="${3:-none}"
  local node="${root}/node" state_root=""
  local generation_id=""
  local generation="" action_relative="" action_directory="" lifecycle=""
  local inventory="${root}/inventory.ndjson" receipt="" metadata=""
  local manifest="" module_source="" mnemonic_fixture=N
  local bundle_relative="" bundle_directory="" sidecar=""
  local sidecar_hash="" sidecar_size=""
  local generation_version="13.5.7"

  case "${action_id}" in
    wallet.new.mnemonic|wallet.import.mnemonic)
      mnemonic_fixture=Y
      [[ "${sidecar_behavior}" != none ]] || sidecar_behavior=valid
      ;;
  esac

  state_root="${node}/scripts/.cntools"
  generation_id="$(printf 'a%.0s' {1..64})"
  generation="${state_root}/generations/${generation_id}"
  action_relative="${action_id//.//}"
  action_directory="${generation}/cntools/modules/root/${action_relative}"
  bundle_relative="cntools/libs/legacy/${MNEMONIC_BUNDLE_ID}"
  bundle_directory="${generation}/${bundle_relative}"
  sidecar="${bundle_directory}/${MNEMONIC_MEMBER_BASENAME}"
  lifecycle="${generation}/cntools/core/lifecycle.sh"
  receipt="${generation}/.generation.json"
  manifest="${generation}/cntools/manifest.json"
  module_source="${MODULES_ROOT}/${action_relative}/module.json"

  mkdir -p -- "${node}/tmp" "${node}/assets" "${node}/wallet" \
    "${node}/pool" "${state_root}/generations" "${generation}/cntools/core" \
    "${action_directory}"
  if [[ "${mnemonic_fixture}" == Y ]]; then
    mkdir -p -- "${bundle_directory}"
  fi
  chmod 0700 "${node}/tmp" "${state_root}" "${state_root}/generations"
  cp -- "${REAL_REGISTRY}" "${generation}/cntools/core/registry.sh"
  cp -- "${REAL_CONTEXT}" "${generation}/cntools/core/context.sh"
  cp -- "${REAL_RESULT}" "${generation}/cntools/core/result.sh"
  cp -- "${REAL_DISPATCHER}" "${generation}/cntools/core/dispatcher.sh"
  cp -- "${module_source}" "${action_directory}/module.json"
  if [[ "${mnemonic_fixture}" == Y ]]; then
    write_action "${action_directory}/action.sh" mnemonic-probe
    write_mnemonic_sidecar "${sidecar}" "${sidecar_behavior}"
    sidecar_hash="$(file_hash "${sidecar}")"
    sidecar_size="$(wc -c < "${sidecar}" | tr -d '[:space:]')"
  else
    write_action "${action_directory}/action.sh" probe
  fi
  write_lifecycle "${lifecycle}"
  if [[ "${mnemonic_fixture}" == Y ]]; then
    jq -nS --arg version "${generation_version}" \
      --arg id "${MNEMONIC_BUNDLE_ID}" \
      --arg path "${bundle_relative}" \
      --arg member "${MNEMONIC_MEMBER_BASENAME}" \
      --arg hash "${sidecar_hash}" --argjson size "${sidecar_size}" '
        {
          schemaVersion:3,
          version:$version,
          legacyBundle:{
            facade:"cntools.library",
            id:$id,
            idAlgorithm:"sha256-cntools-legacy-bundle-v1",
            logicalBodySha256:("c" * 64),
            logicalBodySize:1,
            members:[{mode:"0444",path:$member,sha256:$hash,size:$size}],
            path:$path,
            schemaVersion:1
          }
        }
      ' > "${manifest}"
  else
    jq -nS --arg version "${generation_version}" \
      '{schemaVersion:3,version:$version}' > "${manifest}"
  fi
  chmod 0444 "${generation}/cntools/core/"*.sh "${action_directory}/module.json" \
    "${action_directory}/action.sh" "${manifest}"

  : > "${inventory}"
  while IFS='|' read -r path source validator; do
    jq -cn --arg path "${path}" --arg source "${source}" \
      --arg validator "${validator}" \
      --arg hash "$(file_hash "${generation}/${path}")" \
      '{mode:"0444",path:$path,sha256:$hash,source:$source,validator:$validator}' \
      >> "${inventory}"
  done <<EOF
cntools/core/lifecycle.sh|scripts/common-helper-scripts/cntools/core/lifecycle.sh|shell
cntools/modules/root/${action_relative}/action.sh|scripts/common-helper-scripts/cntools/modules/root/${action_relative}/action.sh|shell
cntools/modules/root/${action_relative}/module.json|scripts/common-helper-scripts/cntools/modules/root/${action_relative}/module.json|json
EOF
  if [[ "${mnemonic_fixture}" == Y ]]; then
    jq -cn --arg path "${bundle_relative}/${MNEMONIC_MEMBER_BASENAME}" \
      --arg source "scripts/common-helper-scripts/${bundle_relative}/${MNEMONIC_MEMBER_BASENAME}" \
      --arg hash "${sidecar_hash}" '
        {mode:"0444",path:$path,sha256:$hash,source:$source,validator:"shell"}
      ' >> "${inventory}"
  fi
  jq -s --arg id "${generation_id}" --arg version "${generation_version}" '
    {schemaVersion:3,id:$id,version:$version,files:sort_by(.path)}
  ' "${inventory}" > "${receipt}"
  chmod 0444 "${receipt}"

  jq -nS --arg id "${generation_id}" --arg version "${generation_version}" '
    {
      schemaVersion:2,
      implementation:"cnode",
      network:"preview",
      cntoolsGeneration:{
        schemaVersion:1,id:$id,version:$version,
        path:("scripts/.cntools/generations/"+$id),
        fileCount:152,active:false
      }
    }
  ' > "${node}/.guild-source-receipt.json"
  jq -nS '
    {
      implementation:"cnode",network:"preview",
      capabilities:{forging:true,localCli:true,metrics:true,n2c:true}
    }
  ' > "${node}/.deployment.json"
  chmod 0644 "${node}/.guild-source-receipt.json" "${node}/.deployment.json"
  find "${generation}" -depth -type d -exec chmod 0555 {} +
  metadata="${node}|${generation}|${receipt}|${action_directory}"
  printf '%s\n' "${metadata}"
}

run_bridge() {
  local fixture="$1" case_name="$2" action_id="$3"
  shift 3
  local node="${fixture%%|*}" stdout_file="${TEST_ROOT}/${case_name}.stdout"
  local stderr_file="${TEST_ROOT}/${case_name}.stderr"
  local event_file="${TEST_ROOT}/${case_name}.events"
  local tmp_root="${node}/tmp"
  local fail_release="${CNTOOLS_BRIDGE_FAIL_RELEASE:-N}"
  local prune_after_release="${CNTOOLS_BRIDGE_PRUNE_AFTER_RELEASE:-N}"
  local copy_tamper="${CNTOOLS_BRIDGE_COPY_TAMPER:-none}"
  local fail_generation_validate="${CNTOOLS_BRIDGE_FAIL_GENERATION_VALIDATE:-N}"
  local ambient_mnemonic="${CNTOOLS_BRIDGE_AMBIENT_MNEMONIC:-N}"
  local ambient_extdebug="${CNTOOLS_BRIDGE_EXTDEBUG:-N}"

  : > "${event_file}"
  capture_call "${stdout_file}" "${stderr_file}" env \
    CNTOOLS_BRIDGE_EVENTS="${event_file}" \
    CNTOOLS_BRIDGE_CASE="${case_name}" \
    CNTOOLS_BRIDGE_FAIL_RELEASE="${fail_release}" \
    CNTOOLS_BRIDGE_PRUNE_AFTER_RELEASE="${prune_after_release}" \
    CNTOOLS_BRIDGE_COPY_TAMPER="${copy_tamper}" \
    CNTOOLS_BRIDGE_FAIL_GENERATION_VALIDATE="${fail_generation_validate}" \
    CNTOOLS_BRIDGE_AMBIENT_MNEMONIC="${ambient_mnemonic}" \
    CNTOOLS_BRIDGE_EXTDEBUG="${ambient_extdebug}" \
    NODE_HOME="${node}" TMP_DIR="${tmp_root}" CNTOOLS_MODE=OFFLINE \
    ADVANCED_MODE=true BLOCKLOG_DB="${node}/absent.db" \
    ASSET_FOLDER="${node}/assets" WALLET_FOLDER="${node}/wallet" \
    POOL_FOLDER="${node}/pool" \
    "${BASH}" -c '
      set +e
      set +u
      if [[ "${CNTOOLS_BRIDGE_EXTDEBUG:-N}" == Y ]]; then
        shopt -s extdebug
      fi
      eval "$1"
      if [[ "${CNTOOLS_BRIDGE_AMBIENT_MNEMONIC:-N}" == Y ]]; then
        _cntools_compatibility_wallet_mnemonic_run() {
          printf "ambient:shared\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"
          return 99
        }
        _cntools_compatibility_wallet_mnemonic_ambient() {
          printf "ambient:prefixed\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"
          return 99
        }
        buildOfflineJSON() { printf "ambient:build\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"; }
        createMnemonicWallet() {
          printf "ambient:create\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"
          return 99
        }
        createNewWallet() { printf "ambient:new\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"; }
        deregisterStakeWallet() { printf "ambient:deregister\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"; }
        printWalletInfo() { printf "ambient:info\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"; }
        registerStakeWallet() { printf "ambient:register\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"; }
      fi
      deployment_payload_sha256() {
        local output=""
        output="$(sha256sum -- "$1")" || return 1
        printf "%s\n" "${output%%[[:space:]]*}"
      }
      deployment_payload_is_current() {
        printf "authority:current\n" >> "${CNTOOLS_BRIDGE_EVENTS:?}"
        return 0
      }
      export -f deployment_payload_sha256 deployment_payload_is_current
      shift
      cntools_compatibility_dispatch_action "$@"
    ' bridge "${BRIDGE_DEFINITION}" "${action_id}" "$@"
  BRIDGE_STDOUT="${stdout_file}"
  BRIDGE_STDERR="${stderr_file}"
  BRIDGE_EVENTS="${event_file}"
  BRIDGE_NODE="${node}"
}

debug_last_bridge_failure() {
  printf 'bridge debug status=%s stdout=%s stderr=%s events=%s\n' \
    "${CALL_STATUS}" "$(< "${BRIDGE_STDOUT}")" "$(< "${BRIDGE_STDERR}")" \
    "$(tr '\n' ',' < "${BRIDGE_EVENTS}")" >&2
}

run_allowlist_contract() {
  local actual="${TEST_ROOT}/allowlist.actual" expected="${TEST_ROOT}/allowlist.expected"
  local script_fixture="${TEST_ROOT}/allowlist-source"
  local id="" stdout_file="${TEST_ROOT}/allowlist.stdout"
  local stderr_file="${TEST_ROOT}/allowlist.stderr"

  awk '
    /^  case "\$\{action_id\}" in$/ {capture=1; next}
    capture && /^    \*\)/ {exit}
    capture && /^    [a-z0-9.-]+\) .*;;$/ {
      line=$0; sub(/^    /,"",line); sub(/\).*/,"",line); print line
    }
  ' "${CNTOOLS_SCRIPT}" | sort > "${actual}"
  find "${MODULES_ROOT}" -type f -name module.json -print0 |
    xargs -0 jq -r 'select(.kind=="action") | .id' | sort > "${expected}"
  cmp -s -- "${actual}" "${expected}" || fail 'bridge allowlist drifted from action metadata'
  [[ "$(wc -l < "${actual}" | tr -d ' ')" == 54 ]] ||
    fail 'bridge allowlist did not contain exactly 54 IDs'

  mkdir -p -- "${script_fixture}/tmp"
  for id in '' unknown.action '../advanced.asset.list' 'advanced.asset.*' \
    $'advanced.asset.list\nnext'; do
    : > "${script_fixture}/events"
    capture_call "${stdout_file}" "${stderr_file}" env \
      NODE_HOME="${script_fixture}" TMP_DIR="${script_fixture}/tmp" \
      CNTOOLS_BRIDGE_EVENTS="${script_fixture}/events" "${BASH}" -c '
        eval "$1"
        deployment_payload_is_current() { printf called >> "${CNTOOLS_BRIDGE_EVENTS}"; }
        deployment_payload_sha256() { return 99; }
        cntools_compatibility_dispatch_action "$2"
      ' bridge "${BRIDGE_DEFINITION}" "${id}"
    assert_status 70 "rejected action ID ${id@Q}"
    assert_empty "${stdout_file}" 'rejected ID stdout'
    assert_empty "${stderr_file}" 'rejected ID stderr'
    assert_empty "${script_fixture}/events" 'rejected ID authority events'
    assert_no_private_state "${script_fixture}/tmp" 'rejected ID'
  done
}

prepare_fixture() {
  local case_name="$1"
  local fixture_root="${TEST_ROOT}/fixtures/${case_name}"
  mkdir -p -- "${fixture_root}"
  build_fixture "${fixture_root}" advanced.asset.list
}

prepare_mnemonic_fixture() {
  local case_name="$1" action_id="$2" behavior="${3:-valid}"
  local fixture_root="${TEST_ROOT}/fixtures/${case_name}"
  mkdir -p -- "${fixture_root}"
  build_fixture "${fixture_root}" "${action_id}" "${behavior}"
}

fixture_generation_path() {
  local remainder="${1#*|}"
  printf '%s\n' "${remainder%%|*}"
}

fixture_receipt_path() {
  local remainder="${1#*|}"
  remainder="${remainder#*|}"
  printf '%s\n' "${remainder%%|*}"
}

fixture_manifest_path() {
  printf '%s/cntools/manifest.json\n' "$(fixture_generation_path "$1")"
}

fixture_sidecar_path() {
  printf '%s/cntools/libs/legacy/%s/%s\n' \
    "$(fixture_generation_path "$1")" "${MNEMONIC_BUNDLE_ID}" \
    "${MNEMONIC_MEMBER_BASENAME}"
}

mutate_generation_manifest() {
  local fixture="$1" filter="$2" manifest="" stage=""
  manifest="$(fixture_manifest_path "${fixture}")"
  stage="${manifest}.stage"
  chmod u+w "${manifest%/*}" "${manifest}"
  jq "${filter}" "${manifest}" > "${stage}"
  mv -f -- "${stage}" "${manifest}"
  chmod 0444 "${manifest}"
}

assert_mnemonic_framework_failure() {
  local label="$1"
  assert_status 70 "${label}"
  assert_empty "${BRIDGE_STDOUT}" "${label} stdout"
  assert_empty "${BRIDGE_STDERR}" "${label} stderr"
  ! grep -Eq '^(action:main:|sidecar:run$|ambient:)' "${BRIDGE_EVENTS}" ||
    fail "${label}: untrusted mnemonic code executed"
  grep -Eq '^lock:release(-failed)?$' "${BRIDGE_EVENTS}" ||
    fail "${label}: generation lock release was not attempted"
  assert_no_private_state "${BRIDGE_NODE}/tmp" "${label}"
}

event_line() {
  local pattern="$1" event_file="$2"
  grep -n -m1 -E "${pattern}" "${event_file}" | cut -d: -f1
}

run_success_status_result_contract() {
  local fixture="" arguments="${TEST_ROOT}/arguments.bin"
  local expected_arguments="${TEST_ROOT}/arguments.expected" status="" result_kind=""
  fixture="$(prepare_fixture success)"

  for status in 0 20 21 22 7 255; do
    result_kind=absent
    [[ "${status}" == 20 ]] && result_kind=valid
    run_bridge "${fixture}" "status-${status}" advanced.asset.list \
      "${arguments}" "${status}" "${result_kind}" '' 'two words' '*' '--' \
      $'line one\nline two'
    [[ "${CALL_STATUS}" -eq "${status}" ]] || debug_last_bridge_failure
    assert_status "${status}" "raw bridge status ${status}"
    assert_text "${BRIDGE_STDOUT}" "bridge-stdout:${status}" "status ${status} stdout"
    assert_text "${BRIDGE_STDERR}" "bridge-stderr:${status}" "status ${status} stderr"
    printf '%s\0' '' 'two words' '*' '--' $'line one\nline two' > "${expected_arguments}"
    cmp -s -- "${arguments}" "${expected_arguments}" ||
      fail "status ${status}: action argument bytes changed in transit"
    [[ "$(grep -c '^lock:release$' "${BRIDGE_EVENTS}" || true)" == 2 ]] ||
      fail "status ${status}: expected bridge and action lock releases"
    [[ "$(grep -n '^lock:release$' "${BRIDGE_EVENTS}" | head -1 | cut -d: -f1)" -lt \
       "$(grep -n '^action:main:' "${BRIDGE_EVENTS}" | cut -d: -f1)" ]] ||
      fail "status ${status}: action ran before bridge lock release"
    grep -Fqx 'action:fresh-lock' "${BRIDGE_EVENTS}" ||
      fail "status ${status}: action could not acquire a fresh generation lock"
    [[ "$(grep -c '^authority:current$' "${BRIDGE_EVENTS}" || true)" == 2 ]] ||
      fail "status ${status}: outer currentness check count changed"
    assert_no_private_state "${BRIDGE_NODE}/tmp" "status ${status}"
  done

  local result_case=""
  for result_case in malformed noncanonical hardlink symlink oversized unsafe-mode; do
    run_bridge "${fixture}" "result-${result_case}" advanced.asset.list \
      "${arguments}" 0 "${result_case}" sentinel
    assert_status 70 "${result_case} result"
    assert_text "${BRIDGE_STDOUT}" 'bridge-stdout:0' \
      "${result_case} result stdout"
    grep -Fq 'CNTools compatibility action produced an unsafe result.' \
      "${BRIDGE_STDERR}" || fail "${result_case} result diagnostic changed"
    assert_no_private_state "${BRIDGE_NODE}/tmp" "${result_case} result"
  done
}

mutate_receipt_record() {
  local fixture="$1" filter="$2"
  local remainder="${fixture#*|}" generation=""
  local rest="" receipt=""
  local stage="${receipt}.stage"

  generation="${remainder%%|*}"
  rest="${remainder#*|}"
  receipt="${rest%%|*}"
  stage="${receipt}.stage"
  chmod u+w "${generation}"
  chmod u+w "${receipt}"
  jq "${filter}" "${receipt}" > "${stage}"
  mv -f -- "${stage}" "${receipt}"
  chmod 0444 "${receipt}"
  # Keep the lifecycle hash record aligned when the mutation is unrelated to it.
  printf '%s\n' "${generation}" >/dev/null
}

run_receipt_binding_contract() {
  local case_name="" fixture="" filter="" arguments="${TEST_ROOT}/never.args"
  while IFS='|' read -r case_name filter; do
    fixture="$(prepare_fixture "receipt-${case_name}")"
    mutate_receipt_record "${fixture}" "${filter}"
    run_bridge "${fixture}" "receipt-${case_name}" advanced.asset.list \
      "${arguments}" 0 absent sentinel
    assert_status 70 "receipt ${case_name}"
    ! grep -q '^action:main:' "${BRIDGE_EVENTS}" ||
      fail "receipt ${case_name}: action executed"
    grep -Fqx 'lock:release' "${BRIDGE_EVENTS}" ||
      fail "receipt ${case_name}: early failure retained its lock"
    assert_no_private_state "${BRIDGE_NODE}/tmp" "receipt ${case_name}"
  done <<'EOF'
path|(.files[] | select(.path | endswith("/action.sh"))).path = "cntools/modules/root/advanced/asset/list/other.sh"
source|(.files[] | select(.path | endswith("/action.sh"))).source = "scripts/wrong/action.sh"
mode|(.files[] | select(.path | endswith("/action.sh"))).mode = "0555"
validator|(.files[] | select(.path | endswith("/action.sh"))).validator = "json"
hash|(.files[] | select(.path | endswith("/action.sh"))).sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
EOF
}

run_source_trust_gate_contract() {
  local fixture="" arguments="${TEST_ROOT}/source-gate.args"

  fixture="$(prepare_fixture lifecycle-hash)"
  mutate_receipt_record "${fixture}" '
    (.files[] | select(.path == "cntools/core/lifecycle.sh")).sha256 =
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  '
  run_bridge "${fixture}" lifecycle-hash advanced.asset.list \
    "${arguments}" 0 absent sentinel
  assert_status 70 'lifecycle receipt hash mismatch'
  [[ "$(grep -c '^authority:current$' "${BRIDGE_EVENTS}" || true)" == 1 ]] ||
    fail 'lifecycle mismatch passed the first authority boundary'
  ! grep -q '^lock:\|^lifecycle:\|^action:' "${BRIDGE_EVENTS}" ||
    fail 'untrusted lifecycle was sourced or action reached'

  fixture="$(prepare_fixture generation-validation)"
  CNTOOLS_BRIDGE_FAIL_GENERATION_VALIDATE=Y \
    run_bridge "${fixture}" generation-validation advanced.asset.list \
      "${arguments}" 0 absent sentinel
  assert_status 70 'full generation validation gate'
  grep -Fqx 'lifecycle:validate' "${BRIDGE_EVENTS}" ||
    fail 'generation validation seam was not invoked'
  grep -Fqx 'lock:release' "${BRIDGE_EVENTS}" ||
    fail 'generation validation failure retained its lock'
  ! grep -q '^action:main:' "${BRIDGE_EVENTS}" ||
    fail 'action ran after generation validation failure'
  assert_no_private_state "${BRIDGE_NODE}/tmp" 'generation validation failure'
}

run_snapshot_tamper_contract() {
  local fixture="" node="" arguments="${TEST_ROOT}/tamper.args"
  local fake_bin="${TEST_ROOT}/fake-cp"
  mkdir -p -- "${fake_bin}"

  fixture="$(prepare_fixture copy-byte)"
  node="${fixture%%|*}"
  cat > "${fake_bin}/cp" <<'EOF'
#!/usr/bin/env bash
/bin/cp "$@" || exit
source_file="${@: -2:1}"
target_file="${@: -1}"
case "${CNTOOLS_BRIDGE_COPY_TAMPER:-none}:${target_file}" in
  byte:*/action.sh) printf '\n# tampered\n' >> "${target_file}" ;;
  hardlink:*/action.sh)
    rm -f -- "${target_file}"
    ln -- "${source_file}" "${target_file}"
    ;;
  symlink:*/action.sh)
    rm -f -- "${target_file}"
    ln -s -- "${source_file}" "${target_file}"
    ;;
  signal:*/action.sh)
    kill -TERM "${PPID}"
    exit 99
    ;;
esac
EOF
  chmod +x "${fake_bin}/cp"
  PATH="${fake_bin}:${PATH}" CNTOOLS_BRIDGE_COPY_TAMPER=byte \
    run_bridge "${fixture}" copy-byte \
    advanced.asset.list "${arguments}" 0 absent sentinel
  assert_status 70 'copied action byte tamper'
  ! grep -q '^action:main:' "${BRIDGE_EVENTS}" || fail 'tampered copied action executed'
  assert_no_private_state "${node}/tmp" 'copied action byte tamper'

  local tamper_kind=""
  for tamper_kind in hardlink symlink; do
    fixture="$(prepare_fixture "copy-${tamper_kind}")"
    PATH="${fake_bin}:${PATH}" CNTOOLS_BRIDGE_COPY_TAMPER="${tamper_kind}" \
      run_bridge "${fixture}" "copy-${tamper_kind}" advanced.asset.list \
        "${arguments}" 0 absent sentinel
    assert_status 70 "copied action ${tamper_kind}"
    ! grep -q '^action:main:' "${BRIDGE_EVENTS}" ||
      fail "copied action ${tamper_kind}: action executed"
    grep -Fqx 'lock:release' "${BRIDGE_EVENTS}" ||
      fail "copied action ${tamper_kind}: lock was retained"
    assert_no_private_state "${BRIDGE_NODE}/tmp" "copied action ${tamper_kind}"
  done

  fake_bin="${TEST_ROOT}/fake-chmod"
  mkdir -p -- "${fake_bin}"
  cat > "${fake_bin}/chmod" <<'EOF'
#!/usr/bin/env bash
/bin/chmod "$@" || exit
if [[ "${1:-}" == 0400 && "${*: -1}" == */action.sh ]]; then
  /bin/chmod 0600 "${*: -1}"
fi
EOF
  chmod +x "${fake_bin}/chmod"
  fixture="$(prepare_fixture copy-mode)"
  PATH="${fake_bin}:${PATH}" run_bridge "${fixture}" copy-mode \
    advanced.asset.list "${arguments}" 0 absent sentinel
  assert_status 70 'copied action mode tamper'
  ! grep -q '^action:main:' "${BRIDGE_EVENTS}" || fail 'wrong-mode copied action executed'
  grep -Fqx 'lock:release' "${BRIDGE_EVENTS}" || fail 'mode tamper retained its lock'
  assert_no_private_state "${BRIDGE_NODE}/tmp" 'copied action mode tamper'

  fixture="$(prepare_fixture module-id)"
  local remainder="${fixture#*|}" generation=""
  generation="${remainder%%|*}"
  local module="${generation}/cntools/modules/root/advanced/asset/list/module.json"
  chmod u+w "${generation}/cntools/modules/root/advanced/asset/list"
  chmod u+w "${module}"
  jq -S '.id = "advanced.asset.show"' "${module}" > "${module}.stage"
  mv -f -- "${module}.stage" "${module}"
  chmod 0444 "${module}"
  local rest="${remainder#*|}" receipt=""
  receipt="${rest%%|*}"
  chmod u+w "${generation}"
  chmod u+w "${receipt}"
  jq --arg hash "$(file_hash "${module}")" '
    (.files[] | select(.path | endswith("/module.json"))).sha256 = $hash
  ' "${receipt}" > "${receipt}.stage"
  mv -f -- "${receipt}.stage" "${receipt}"
  chmod 0444 "${receipt}"
  run_bridge "${fixture}" module-id advanced.asset.list \
    "${arguments}" 0 absent sentinel
  assert_status 70 'snapshot module ID mismatch'
  ! grep -q '^action:main:' "${BRIDGE_EVENTS}" || fail 'wrong-ID module executed'
}

run_release_failure_contract() {
  local fixture="" arguments="${TEST_ROOT}/release.args"
  fixture="$(prepare_fixture release-failure)"
  CNTOOLS_BRIDGE_FAIL_RELEASE=Y run_bridge "${fixture}" release-failure \
    advanced.asset.list "${arguments}" 0 absent sentinel
  assert_status 70 'generation lock release failure'
  ! grep -q '^action:main:' "${BRIDGE_EVENTS}" || fail 'action ran after release failure'
  assert_no_private_state "${BRIDGE_NODE}/tmp" 'release failure'
}

run_signal_cleanup_contract() {
  local point="" fixture="" fake_bin="" arguments="${TEST_ROOT}/signal.args"

  for point in before-copy during-copy after-copy; do
    fake_bin="${TEST_ROOT}/signal-${point}"
    mkdir -p -- "${fake_bin}"
    case "${point}" in
      before-copy)
        cat > "${fake_bin}/mktemp" <<'EOF'
#!/usr/bin/env bash
kill -TERM "${PPID}"
exit 99
EOF
        chmod +x "${fake_bin}/mktemp"
        ;;
      during-copy)
        cat > "${fake_bin}/cp" <<'EOF'
#!/usr/bin/env bash
/bin/cp "$@" || exit
if [[ "${*: -1}" == */action.sh ]]; then
  kill -TERM "${PPID}"
  exit 99
fi
EOF
        chmod +x "${fake_bin}/cp"
        ;;
      after-copy)
        cat > "${fake_bin}/chmod" <<'EOF'
#!/usr/bin/env bash
/bin/chmod "$@" || exit
if [[ "${1:-}" == 0400 && "${*: -1}" == */context.json ]]; then
  kill -TERM "${PPID}"
  exit 99
fi
EOF
        chmod +x "${fake_bin}/chmod"
        ;;
    esac
    fixture="$(prepare_fixture "signal-${point}")"
    PATH="${fake_bin}:${PATH}" run_bridge "${fixture}" "signal-${point}" \
      advanced.asset.list "${arguments}" 0 absent sentinel
    assert_status 70 "signal ${point}"
    ! grep -q '^action:main:' "${BRIDGE_EVENTS}" ||
      fail "signal ${point}: action executed"
    grep -Fqx 'lock:release' "${BRIDGE_EVENTS}" ||
      fail "signal ${point}: lock was retained"
    assert_no_private_state "${BRIDGE_NODE}/tmp" "signal ${point}"
  done
}

run_cleanup_failure_contract() {
  local fixture="" fake_bin="${TEST_ROOT}/cleanup-failure-bin"
  local arguments="${TEST_ROOT}/cleanup-failure.args"
  mkdir -p -- "${fake_bin}"
  cat > "${fake_bin}/rmdir" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  */cntools-compatibility.*) exit 88 ;;
  *) /bin/rmdir "$@" ;;
esac
EOF
  chmod +x "${fake_bin}/rmdir"
  fixture="$(prepare_fixture cleanup-failure)"
  PATH="${fake_bin}:${PATH}" run_bridge "${fixture}" cleanup-failure \
    advanced.asset.list "${arguments}" 0 absent sentinel
  assert_status 70 'cleanup failure override'
  assert_text "${BRIDGE_STDOUT}" 'bridge-stdout:0' 'cleanup failure stdout'
  assert_text "${BRIDGE_STDERR}" 'bridge-stderr:0' 'cleanup failure stderr'
}

run_generation_prune_contract() {
  local fixture="" arguments="${TEST_ROOT}/prune.args"
  fixture="$(prepare_fixture prune-after-release)"
  CNTOOLS_BRIDGE_PRUNE_AFTER_RELEASE=Y \
    run_bridge "${fixture}" prune-after-release advanced.asset.list \
    "${arguments}" 0 absent sentinel
  assert_status 0 'generation prune after release'
  grep -Fqx 'generation:pruned' "${BRIDGE_EVENTS}" ||
    fail 'generation was not pruned synchronously at bridge release'
  grep -q '^action:main:' "${BRIDGE_EVENTS}" ||
    fail 'snapshotted action did not run after generation prune'
}

run_mnemonic_success_contract() {
  local action_id="" case_name="" fixture="" release_line=""
  local action_line="" sidecar_line=""

  for action_id in wallet.new.mnemonic wallet.import.mnemonic; do
    case_name="mnemonic-${action_id//./-}"
    fixture="$(prepare_mnemonic_fixture "${case_name}" "${action_id}")"
    CNTOOLS_BRIDGE_AMBIENT_MNEMONIC=Y \
      run_bridge "${fixture}" "${case_name}" "${action_id}"
    [[ ${CALL_STATUS} -eq 0 ]] || debug_last_bridge_failure
    assert_status 0 "${action_id} authenticated sidecar"
    assert_empty "${BRIDGE_STDOUT}" "${action_id} stdout"
    assert_empty "${BRIDGE_STDERR}" "${action_id} stderr"
    grep -Fqx "action:main:${case_name}" "${BRIDGE_EVENTS}" ||
      fail "${action_id}: snapshotted action did not run"
    [[ "$(grep -c '^sidecar:run$' "${BRIDGE_EVENTS}" || true)" == 1 ]] ||
      fail "${action_id}: authenticated sidecar did not run exactly once"
    ! grep -q '^ambient:' "${BRIDGE_EVENTS}" ||
      fail "${action_id}: ambient mnemonic helper retained authority"
    release_line="$(event_line '^lock:release$' "${BRIDGE_EVENTS}")"
    action_line="$(event_line '^action:main:' "${BRIDGE_EVENTS}")"
    sidecar_line="$(event_line '^sidecar:run$' "${BRIDGE_EVENTS}")"
    [[ "${release_line}" -lt "${action_line}" &&
       "${action_line}" -lt "${sidecar_line}" ]] ||
      fail "${action_id}: lock/action/sidecar ordering changed"
    [[ "$(grep -c '^authority:current$' "${BRIDGE_EVENTS}" || true)" == 2 ]] ||
      fail "${action_id}: outer authority check count changed"
    assert_no_private_state "${BRIDGE_NODE}/tmp" "${action_id} success"
  done

  case_name=mnemonic-extdebug
  fixture="$(prepare_mnemonic_fixture "${case_name}" wallet.new.mnemonic)"
  CNTOOLS_BRIDGE_AMBIENT_MNEMONIC=Y CNTOOLS_BRIDGE_EXTDEBUG=Y \
    run_bridge "${fixture}" "${case_name}" wallet.new.mnemonic
  [[ ${CALL_STATUS} -eq 0 ]] || debug_last_bridge_failure
  assert_status 0 'ambient extdebug mnemonic sidecar'
  assert_empty "${BRIDGE_STDOUT}" 'ambient extdebug stdout'
  assert_empty "${BRIDGE_STDERR}" 'ambient extdebug stderr'
  grep -Fqx 'sidecar:run' "${BRIDGE_EVENTS}" ||
    fail 'ambient extdebug changed the function inventory contract'
  ! grep -q '^ambient:' "${BRIDGE_EVENTS}" ||
    fail 'ambient extdebug restored an ambient helper'
  assert_no_private_state "${BRIDGE_NODE}/tmp" 'ambient extdebug success'
}

run_mnemonic_metadata_contract() {
  local case_name="" fixture="" filter="" sidecar_relative=""

  for case_name in manifest-member-missing manifest-member-duplicate \
    manifest-bundle-path manifest-member-path manifest-member-mode \
    manifest-member-hash manifest-member-size; do
    fixture="$(prepare_mnemonic_fixture "${case_name}" wallet.new.mnemonic)"
    case "${case_name}" in
      manifest-member-missing)
        filter='.legacyBundle.members = []'
        ;;
      manifest-member-duplicate)
        filter='.legacyBundle.members += [.legacyBundle.members[0]]'
        ;;
      manifest-bundle-path)
        filter='.legacyBundle.path = "cntools/libs/legacy/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"'
        ;;
      manifest-member-path)
        filter='.legacyBundle.members[0].path = "other.sh"'
        ;;
      manifest-member-mode)
        filter='.legacyBundle.members[0].mode = "0555"'
        ;;
      manifest-member-hash)
        filter='.legacyBundle.members[0].sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"'
        ;;
      manifest-member-size)
        filter='.legacyBundle.members[0].size += 1'
        ;;
    esac
    mutate_generation_manifest "${fixture}" "${filter}"
    CNTOOLS_BRIDGE_AMBIENT_MNEMONIC=Y \
      run_bridge "${fixture}" "${case_name}" wallet.new.mnemonic
    assert_mnemonic_framework_failure "${case_name}"
  done

  sidecar_relative="cntools/libs/legacy/${MNEMONIC_BUNDLE_ID}/${MNEMONIC_MEMBER_BASENAME}"
  for case_name in receipt-member-missing receipt-member-duplicate \
    receipt-member-source receipt-member-mode receipt-member-validator \
    receipt-member-hash; do
    fixture="$(prepare_mnemonic_fixture "${case_name}" wallet.new.mnemonic)"
    case "${case_name}" in
      receipt-member-missing)
        filter=".files |= map(select(.path != \"${sidecar_relative}\"))"
        ;;
      receipt-member-duplicate)
        filter="(.files[] | select(.path == \"${sidecar_relative}\")) as \$record | .files += [\$record]"
        ;;
      receipt-member-source)
        filter="(.files[] | select(.path == \"${sidecar_relative}\")).source = \"scripts/wrong/050.sh\""
        ;;
      receipt-member-mode)
        filter="(.files[] | select(.path == \"${sidecar_relative}\")).mode = \"0555\""
        ;;
      receipt-member-validator)
        filter="(.files[] | select(.path == \"${sidecar_relative}\")).validator = \"json\""
        ;;
      receipt-member-hash)
        filter="(.files[] | select(.path == \"${sidecar_relative}\")).sha256 = \"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\""
        ;;
    esac
    mutate_receipt_record "${fixture}" "${filter}"
    CNTOOLS_BRIDGE_AMBIENT_MNEMONIC=Y \
      run_bridge "${fixture}" "${case_name}" wallet.new.mnemonic
    assert_mnemonic_framework_failure "${case_name}"
  done
}

run_mnemonic_source_contract() {
  local case_name="" fixture="" sidecar="" sidecar_directory=""

  for case_name in source-missing source-byte source-mode source-hardlink; do
    fixture="$(prepare_mnemonic_fixture "${case_name}" wallet.new.mnemonic)"
    sidecar="$(fixture_sidecar_path "${fixture}")"
    sidecar_directory="${sidecar%/*}"
    case "${case_name}" in
      source-missing)
        chmod u+w "${sidecar_directory}"
        rm -f -- "${sidecar}"
        ;;
      source-byte)
        chmod u+w "${sidecar}"
        printf '\n# source tamper\n' >> "${sidecar}"
        chmod 0444 "${sidecar}"
        ;;
      source-mode)
        chmod 0644 "${sidecar}"
        ;;
      source-hardlink)
        chmod u+w "${sidecar_directory}"
        ln -- "${sidecar}" "${sidecar}.peer"
        ;;
    esac
    CNTOOLS_BRIDGE_AMBIENT_MNEMONIC=Y \
      run_bridge "${fixture}" "${case_name}" wallet.new.mnemonic
    assert_mnemonic_framework_failure "${case_name}"
  done

  for case_name in omit-shared extra-reserved extra-prefixed source-output \
    source-variable source-existing-variable source-alias function-export \
    function-readonly child-source-fail live-source-fail syntax-fail; do
    fixture="$(prepare_mnemonic_fixture "source-contract-${case_name}" \
      wallet.new.mnemonic "${case_name}")"
    CNTOOLS_BRIDGE_AMBIENT_MNEMONIC=Y \
      run_bridge "${fixture}" "source-contract-${case_name}" \
        wallet.new.mnemonic
    assert_mnemonic_framework_failure "source contract ${case_name}"
  done
}

run_mnemonic_snapshot_contract() {
  local fake_bin="${TEST_ROOT}/mnemonic-snapshot-bin" fixture=""
  local tamper_kind="" case_name=""
  mkdir -p -- "${fake_bin}"
  cat > "${fake_bin}/cp" <<'EOF'
#!/usr/bin/env bash
/bin/cp "$@" || exit
source_file="${@: -2:1}"
target_file="${@: -1}"
case "${CNTOOLS_BRIDGE_COPY_TAMPER:-none}:${target_file}" in
  byte:*/compatibility-wallet-mnemonic.sh)
    printf '\n# copied sidecar tamper\n' >> "${target_file}"
    ;;
  hardlink:*/compatibility-wallet-mnemonic.sh)
    rm -f -- "${target_file}"
    ln -- "${source_file}" "${target_file}"
    ;;
  symlink:*/compatibility-wallet-mnemonic.sh)
    rm -f -- "${target_file}"
    ln -s -- "${source_file}" "${target_file}"
    ;;
  signal:*/compatibility-wallet-mnemonic.sh)
    kill -TERM "${PPID}"
    exit 99
    ;;
esac
EOF
  chmod +x "${fake_bin}/cp"

  for tamper_kind in byte hardlink symlink; do
    case_name="snapshot-sidecar-${tamper_kind}"
    fixture="$(prepare_mnemonic_fixture "${case_name}" wallet.new.mnemonic)"
    PATH="${fake_bin}:${PATH}" CNTOOLS_BRIDGE_COPY_TAMPER="${tamper_kind}" \
      CNTOOLS_BRIDGE_AMBIENT_MNEMONIC=Y \
      run_bridge "${fixture}" "${case_name}" wallet.new.mnemonic
    assert_mnemonic_framework_failure "${case_name}"
  done

  fake_bin="${TEST_ROOT}/mnemonic-mode-bin"
  mkdir -p -- "${fake_bin}"
  cat > "${fake_bin}/chmod" <<'EOF'
#!/usr/bin/env bash
/bin/chmod "$@" || exit
if [[ "${1:-}" == 0400 && "${*: -1}" == \
      */compatibility-wallet-mnemonic.sh ]]; then
  /bin/chmod 0600 "${*: -1}"
fi
EOF
  chmod +x "${fake_bin}/chmod"
  case_name=snapshot-sidecar-mode
  fixture="$(prepare_mnemonic_fixture "${case_name}" wallet.new.mnemonic)"
  PATH="${fake_bin}:${PATH}" CNTOOLS_BRIDGE_AMBIENT_MNEMONIC=Y \
    run_bridge "${fixture}" "${case_name}" wallet.new.mnemonic
  assert_mnemonic_framework_failure "${case_name}"

  fake_bin="${TEST_ROOT}/mnemonic-signal-bin"
  mkdir -p -- "${fake_bin}"
  cat > "${fake_bin}/cp" <<'EOF'
#!/usr/bin/env bash
/bin/cp "$@" || exit
if [[ "${*: -1}" == */compatibility-wallet-mnemonic.sh ]]; then
  kill -TERM "${PPID}"
  exit 99
fi
EOF
  chmod +x "${fake_bin}/cp"
  case_name=signal-during-sidecar-copy
  fixture="$(prepare_mnemonic_fixture "${case_name}" wallet.new.mnemonic)"
  PATH="${fake_bin}:${PATH}" CNTOOLS_BRIDGE_AMBIENT_MNEMONIC=Y \
    run_bridge "${fixture}" "${case_name}" wallet.new.mnemonic
  assert_mnemonic_framework_failure "${case_name}"
}

run_mnemonic_release_prune_contract() {
  local fixture="" case_name="" release_line="" prune_line=""
  local action_line="" sidecar_line=""

  case_name=mnemonic-release-failure
  fixture="$(prepare_mnemonic_fixture "${case_name}" wallet.new.mnemonic)"
  CNTOOLS_BRIDGE_FAIL_RELEASE=Y CNTOOLS_BRIDGE_AMBIENT_MNEMONIC=Y \
    run_bridge "${fixture}" "${case_name}" wallet.new.mnemonic
  assert_mnemonic_framework_failure "${case_name}"

  case_name=mnemonic-prune-after-release
  fixture="$(prepare_mnemonic_fixture "${case_name}" wallet.import.mnemonic)"
  CNTOOLS_BRIDGE_PRUNE_AFTER_RELEASE=Y CNTOOLS_BRIDGE_AMBIENT_MNEMONIC=Y \
    run_bridge "${fixture}" "${case_name}" wallet.import.mnemonic
  [[ ${CALL_STATUS} -eq 0 ]] || debug_last_bridge_failure
  assert_status 0 'mnemonic generation prune after release'
  assert_empty "${BRIDGE_STDOUT}" 'mnemonic prune stdout'
  assert_empty "${BRIDGE_STDERR}" 'mnemonic prune stderr'
  release_line="$(event_line '^lock:release$' "${BRIDGE_EVENTS}")"
  prune_line="$(event_line '^generation:pruned$' "${BRIDGE_EVENTS}")"
  action_line="$(event_line '^action:main:' "${BRIDGE_EVENTS}")"
  sidecar_line="$(event_line '^sidecar:run$' "${BRIDGE_EVENTS}")"
  [[ "${release_line}" -lt "${prune_line}" &&
     "${prune_line}" -lt "${action_line}" &&
     "${action_line}" -lt "${sidecar_line}" ]] ||
    fail 'mnemonic prune-safe source/action order changed'
  ! grep -q '^ambient:' "${BRIDGE_EVENTS}" ||
    fail 'mnemonic prune restored an ambient helper'
  assert_no_private_state "${BRIDGE_NODE}/tmp" 'mnemonic prune success'
}

run_allowlist_contract
run_success_status_result_contract
run_receipt_binding_contract
run_source_trust_gate_contract
run_snapshot_tamper_contract
run_release_failure_contract
run_signal_cleanup_contract
run_cleanup_failure_contract
run_generation_prune_contract
run_mnemonic_success_contract
run_mnemonic_metadata_contract
run_mnemonic_source_contract
run_mnemonic_snapshot_contract
run_mnemonic_release_prune_contract

printf 'CNTools compatibility bridge contract tests passed\n'
