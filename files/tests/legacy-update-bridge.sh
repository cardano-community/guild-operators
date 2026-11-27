#!/usr/bin/env bash
# Deployments made before CNTools 14 run update checks that fetch
# scripts/cnode-helper-scripts/<file> from their branch. This test runs that
# update check (the last env of that layout) against a fake GitHub, and checks
# the bridge env, the stubs and the guard that keep those deployments working.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/guild-legacy-bridge-test.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

SRC="${REPO_ROOT}/scripts/cnode-helper-scripts"
BRIDGE_ENV="${SRC}/env"
# sha256 of scripts/cnode-helper-scripts/env at the last master commit of the earlier layout
MASTER_ENV_SHA256="93cfb0e40d73543bfe4f95fc492230e745d9aecbf8aa82b80bb8fa8e90217c8e"
GUARDED=(cncli.sh blockPerf.sh mithril-client.sh mithril-signer.sh mithril-relay.sh mithril.library)
STUBS=(gLiveView.sh cntools.sh cntools.library)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

contains() {
  grep -qF -- "$2" "$1" || { cat "$1" >&2; fail "$3"; }
}

# --- The bridge env is the earlier env plus marked additions -------------------
sed '/^ *# >>> legacy-bridge/,/^ *# <<< legacy-bridge/d' "${BRIDGE_ENV}" > "${TEST_DIR}/master-env"
[[ "$(sha256 < "${TEST_DIR}/master-env")" == "${MASTER_ENV_SHA256}" ]] ||
  fail "the bridge env without its legacy-bridge blocks is not the last env of the earlier layout"
awk '/^# Do NOT modify/{exit} /legacy-bridge/{found=1} END{exit !found}' "${BRIDGE_ENV}" &&
  fail "a legacy-bridge block sits in the user section, which the earlier update check merges"
LEGACY_REF="$(sed -n 's/.*GUILD_LEGACY_REF="\([0-9a-f]\{40\}\)".*/\1/p' "${BRIDGE_ENV}")"
[[ -n ${LEGACY_REF} ]] || fail "GUILD_LEGACY_REF is not a full commit id"

# --- Every guard copy is the same, and runs before anything else ---------------
guard_sum=""
for file in "${GUARDED[@]}" "${STUBS[@]}"; do
  [[ $(grep -c '^# >>> legacy-layout-guard' "${SRC}/${file}") -eq 1 ]] || fail "${file} has no single legacy-layout-guard block"
  sum="$(awk '/^# >>> legacy-layout-guard/,/^# <<< legacy-layout-guard/' "${SRC}/${file}" | sha256)"
  [[ -n ${guard_sum} ]] || guard_sum="${sum}"
  [[ ${sum} == "${guard_sum}" ]] || fail "the legacy-layout-guard block in ${file} differs from ${GUARDED[0]}"
  # The first code after the block calls the guard.
  awk 'done { next } /^# <<< legacy-layout-guard/ { after = 1; next }
       after && !/^[[:space:]]*(#|$)/ { done = 1; ok = /^if legacy_layout_guard / } END { exit !ok }' "${SRC}/${file}" ||
    fail "${file} does not call the guard right after its block"
done
for file in "${GUARDED[@]}"; do
  # Nothing but the banner comes between the user section and the guard.
  awk '/^# Do NOT modify/ { banner = 1; next } banner && /^#+$/ && !seen { seen = 1; next }
       banner && !/^$/ { exit !/^# >>> legacy-layout-guard/ }' "${SRC}/${file}" ||
    fail "${file} runs code before the legacy-layout guard"
done

# --- New deployments never get the files kept for the earlier layout -----------
for file in env gLiveView.sh cntools.sh cntools.library; do
  if grep -q "scripts/cnode-helper-scripts/${file}\$" "${SRC}/deploy-cnode.sh"; then
    fail "deploy-cnode.sh installs scripts/cnode-helper-scripts/${file}, which only exists for the earlier layout"
  fi
done

# --- A fake GitHub and a deployment of the earlier layout ----------------------
FAKE_GH="${TEST_DIR}/gh"
REPO_URL_DIR="${FAKE_GH}/cardano-community/guild-operators"
LEGACY_DIR="${REPO_URL_DIR}/${LEGACY_REF}/scripts/cnode-helper-scripts"
mkdir -p "${TEST_DIR}/bin" "${LEGACY_DIR}"
ln -s "${REPO_ROOT}" "${REPO_URL_DIR}/alpha"
CURL_LOG="${TEST_DIR}/curl.log"
export FAKE_GH CURL_LOG

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'out=""; url=""' \
  'while (($#)); do' \
  '  case $1 in' \
  '    -o|-m) [[ $1 = -o ]] && out=$2; shift 2 ;;' \
  '    https://*) url=$1; shift ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'printf "%s\n" "${url}" >> "${CURL_LOG:?}"' \
  'src="${FAKE_GH:?}/${url#https://raw.githubusercontent.com/}"' \
  '[[ -f ${src} ]] || exit 22' \
  'if [[ -n ${out} ]]; then cp "${src}" "${out}"; else cat "${src}"; fi' \
  > "${TEST_DIR}/bin/curl"
chmod +x "${TEST_DIR}/bin/curl"

# Scripts as the earlier layout shipped them, reduced to what the update check reads.
write_old_script() { # $1 = file, $2 = user variable line, $3... = code
  local file=$1 user_line=$2
  shift 2
  printf '%s\n' '#!/usr/bin/env bash' \
    '######################################' \
    '# User Variables - Change as desired #' \
    '######################################' \
    "${user_line}" \
    '' \
    '######################################' \
    '# Do NOT modify code below           #' \
    '######################################' \
    "$@" > "${LEGACY_DIR}/${file}"
}
# shellcheck disable=SC2016
{
  write_old_script gLiveView.sh '#REFRESH_RATE=2' 'GLV_VERSION=v1.32.1' 'echo "OLD gLiveView $*"'
  write_old_script cntools.sh '#TIMEOUT_NO_OF_SLOTS=600' 'arg_copy=("$@")' \
    '. "$(dirname "$0")"/cntools.library || exit 1' 'echo "OLD cntools lib=${CNTOOLS_LIB} $*"'
  printf '%s\n' '#!/usr/bin/env bash' '######################################' \
    '# Do NOT modify code below           #' '######################################' \
    'CNTOOLS_MAJOR_VERSION=13' 'CNTOOLS_MINOR_VERSION=5' 'CNTOOLS_PATCH_VERSION=7' 'CNTOOLS_LIB=old' \
    > "${LEGACY_DIR}/cntools.library"
  write_old_script cncli.sh '#BATCH_AUTO_UPDATE=N' 'SKIP_UPDATE=N' '[[ $1 = "-u" ]] && SKIP_UPDATE=Y && shift' \
    'echo "OLD cncli skip=${SKIP_UPDATE} $*"'
  write_old_script mithril-signer.sh '#MITHRIL_HOME=' 'SKIP_UPDATE=N' \
    '[[ $1 =~ "-u" ]] || [[ $1 =~ "--skip-update" ]] && SKIP_UPDATE=Y && shift' \
    '. "$(dirname "$0")"/mithril.library' 'echo "OLD mithril-signer skip=${SKIP_UPDATE} lib=${MITHRIL_LIB} $*"'
  printf '%s\n' '#!/usr/bin/env bash' '######################################' \
    '# Do NOT modify code below           #' '######################################' \
    'MITHRIL_LIB=old' > "${LEGACY_DIR}/mithril.library"
}
cp "${TEST_DIR}/master-env" "${LEGACY_DIR}/env"

DEPLOY="${TEST_DIR}/opt/cnode"
new_deployment() {
  rm -rf "${DEPLOY}"
  mkdir -p "${DEPLOY}/scripts" "${DEPLOY}/files"
  cp "${LEGACY_DIR}"/{gLiveView.sh,cntools.sh,cntools.library,cncli.sh,mithril-signer.sh,mithril.library} "${DEPLOY}/scripts/"
  chmod +x "${DEPLOY}"/scripts/*.sh
  # An operator setting in the user section, which every update must keep.
  sed 's/^#CNODE_PORT=6000 /CNODE_PORT=6001 /' "${TEST_DIR}/master-env" > "${DEPLOY}/scripts/env"
  grep -q '^CNODE_PORT=6001 ' "${DEPLOY}/scripts/env" || fail "could not customise the deployment env"
  echo alpha > "${DEPLOY}/scripts/.env_branch"
  : > "${CURL_LOG}"
}

# The earlier env needs GNU coreutils (head -n -2), as on the Linux hosts it ran on.
for gnubin in /opt/homebrew/opt/coreutils/libexec/gnubin /usr/local/opt/coreutils/libexec/gnubin; do
  [[ $(uname) == Darwin && -d ${gnubin} ]] && PATH="${gnubin}:${PATH}" && break
done
export PATH="${TEST_DIR}/bin:${PATH}" HOME="${TEST_DIR}/home" TMP_DIR="${TEST_DIR}/tmp"
mkdir -p "${HOME}" "${TMP_DIR}"
unset CCLI CNODEBIN CNODE_HOME NWMAGIC G_ACCOUNT GUILD_LEGACY_REF

# Run the deployment's update check as its scripts do: source env, then checkUpdate.
# env takes the scripts folder from $0, so the shell runs as a script in it. It
# stops after its defaults (there is no cardano-cli here), which define
# checkUpdate and the URLs. $1 is the shell code, output goes to ${TEST_DIR}/out.
update_shell() {
  local code=$1
  shift
  # shellcheck disable=SC2016
  bash -c 'cd "$(dirname "$0")" || exit 99; . ./env offline >/dev/null 2>&1; '"${code}" \
    "${DEPLOY}/scripts/update-check" "$@" > "${TEST_DIR}/out" 2>&1 </dev/null
}

check() {
  # shellcheck disable=SC2016
  update_shell 'checkUpdate "$@"' "$@"
}

run() { # runs a deployment script without a terminal; output in ${TEST_DIR}/run.out
  (cd "${DEPLOY}/scripts" && "$@") > "${TEST_DIR}/run.out" 2>&1 </dev/null
}

same() { cmp -s "$1" "$2" || fail "$3"; }

check_rc() { # $1 = expected return code, then the checkUpdate arguments
  local want=$1 rc=0
  shift
  check "$@" || rc=$?
  [[ ${rc} -eq ${want} ]] || { cat "${TEST_DIR}/out" >&2; fail "checkUpdate $* returned ${rc}, expected ${want}"; }
}

run_rc() { # $1 = expected exit code, then the command
  local want=$1 rc=0
  shift
  run "$@" || rc=$?
  [[ ${rc} -eq ${want} ]] || { cat "${TEST_DIR}/run.out" >&2; fail "$* exited ${rc}, expected ${want}"; }
}

# --- Services keep running on the earlier env ----------------------------------
# Without a terminal (as in a CNCLI unit) nothing is replaced, and nothing fails.
new_deployment
check_rc 0 "${DEPLOY}/scripts/env" N N N
grep -q '^CNODE_PORT=6001 ' "${DEPLOY}/scripts/env" || fail "a check without a terminal changed env"
check_rc 0 "${DEPLOY}/scripts/cncli.sh" N
same "${DEPLOY}/scripts/cncli.sh" "${LEGACY_DIR}/cncli.sh" "a CNCLI service replaced cncli.sh without being asked"
contains "${CURL_LOG}" "alpha/scripts/cnode-helper-scripts/env" "env was not fetched from the deployment's branch"

# --- Accepting the env update pins the earlier scripts to the last release ----
new_deployment
check_rc 1 "${DEPLOY}/scripts/env" Y N N
grep -q '^legacyLayoutNotice()' "${DEPLOY}/scripts/env" || fail "the bridge env was not installed"
grep -q '^CNODE_PORT=6001 ' "${DEPLOY}/scripts/env" || fail "the env update dropped the operator's CNODE_PORT"
compgen -G "${DEPLOY}/scripts/archive/env_bkp*" >/dev/null || fail "the env update kept no backup"

: > "${CURL_LOG}"
NWMAGIC=1 check_rc 0 "${DEPLOY}/scripts/gLiveView.sh" Y
same "${DEPLOY}/scripts/gLiveView.sh" "${LEGACY_DIR}/gLiveView.sh" "gLiveView.sh changed although it matches the last release"
contains "${CURL_LOG}" "${LEGACY_REF}/scripts/cnode-helper-scripts/gLiveView.sh" "gLiveView.sh was not compared with the last release of the earlier layout"
contains "${TEST_DIR}/out" "Guild Operators moved to a new deployment layout" "the bridge printed no notice"
contains "${TEST_DIR}/out" "-C -s pd -n preprod -t cnode -p $(cd "${TEST_DIR}/opt" && pwd -P)" "the notice has no matching guild-deploy.sh -C command"
contains "${TEST_DIR}/out" "/guild-operators/alpha/scripts/cnode-helper-scripts/guild-deploy.sh" "the notice does not use the deployment's branch"

# Within one run the notice is printed once; env keeps following the branch with no
# update loop; grest scripts keep following the branch too.
update_shell 'checkUpdate ./env N N N; echo "env rc=$?"
  checkUpdate ./cncli.sh N; echo "cncli rc=$?"
  checkUpdate grest-poll.sh Y N N grest-helper-scripts; echo "grest rc=$?"'
[[ $(grep -c 'Guild Operators moved to a new deployment layout' "${TEST_DIR}/out") -eq 1 ]] || fail "the notice was not printed exactly once in one run"
contains "${TEST_DIR}/out" "env rc=0" "the bridge env offered itself as an update again"
contains "${TEST_DIR}/out" "cncli rc=0" "cncli.sh was not current against the last release"
contains "${TEST_DIR}/out" "grest rc=0" "the grest check failed"
if grep -q 'update(s) detected' "${TEST_DIR}/out"; then fail "the bridge env offered an update"; fi
contains "${CURL_LOG}" "${LEGACY_REF}/scripts/cnode-helper-scripts/cncli.sh" "cncli.sh was not compared with the last release"
contains "${CURL_LOG}" "alpha/scripts/grest-helper-scripts/grest-poll.sh" "grest-poll.sh no longer follows the branch"
# shellcheck disable=SC2016
update_shell 'echo "URL_DOCS=${URL_DOCS}"'
contains "${TEST_DIR}/out" "URL_DOCS=https://raw.githubusercontent.com/cardano-community/guild-operators/${LEGACY_REF}/docs/Scripts" \
  "CNTools 13 would show the changelog of the new layout"
same "${DEPLOY}/scripts/grest-poll.sh" "${REPO_ROOT}/scripts/grest-helper-scripts/grest-poll.sh" "grest-poll.sh was not installed from the branch"

# --- Declining env and accepting gLiveView 2.0 puts the earlier copy back -----
new_deployment
check_rc 0 "${DEPLOY}/scripts/env" N N N
check_rc 1 "${DEPLOY}/scripts/gLiveView.sh" Y
contains "${TEST_DIR}/out" "A new version of Koios gLiveView is available" "the earlier update check did not offer gLiveView 2.0"
contains "${TEST_DIR}/out" "v2.0.0" "the offered gLiveView version is not 2.0.0"
grep -q '^# >>> legacy-layout-guard' "${DEPLOY}/scripts/gLiveView.sh" || fail "the stub did not replace gLiveView.sh"
grep -q '^#REFRESH_RATE=2' "${DEPLOY}/scripts/gLiveView.sh" || fail "the stub lost gLiveView's user section"
run_rc 0 ./gLiveView.sh -u
contains "${TEST_DIR}/run.out" "OLD gLiveView -u" "the earlier gLiveView did not run with -u"
contains "${TEST_DIR}/run.out" "NOTICE: Guild Operators moved to a new deployment layout" "the gLiveView stub printed no notice"
same "${DEPLOY}/scripts/gLiveView.sh" "${LEGACY_DIR}/gLiveView.sh" "the earlier gLiveView.sh was not put back"
[[ -x "${DEPLOY}/scripts/gLiveView.sh" ]] || fail "the restored gLiveView.sh is not executable"

# Declining both keeps the earlier gLiveView: the stub is found, so the check passes.
new_deployment
check_rc 0 "${DEPLOY}/scripts/gLiveView.sh" N
same "${DEPLOY}/scripts/gLiveView.sh" "${LEGACY_DIR}/gLiveView.sh" "declining changed gLiveView.sh"

# --- CNTools: library and script both replaced, then only the library ---------
new_deployment
check_rc 1 "${DEPLOY}/scripts/cntools.library" Y Y N
contains "${TEST_DIR}/out" "A new version of Koios CNTools is available" "the earlier update check did not offer CNTools 14"
check_rc 1 "${DEPLOY}/scripts/cntools.sh" Y
run_rc 0 ./cntools.sh -o -u
contains "${TEST_DIR}/run.out" "OLD cntools lib=old -o -u" "the earlier CNTools did not run with its library and arguments"
same "${DEPLOY}/scripts/cntools.sh" "${LEGACY_DIR}/cntools.sh" "the earlier cntools.sh was not put back"
same "${DEPLOY}/scripts/cntools.library" "${LEGACY_DIR}/cntools.library" "the earlier cntools.library was not put back"

new_deployment
check_rc 1 "${DEPLOY}/scripts/cntools.library" Y Y N
run_rc 0 ./cntools.sh -a
contains "${TEST_DIR}/run.out" "OLD cntools lib=old -a -u" "CNTools was not run again with its arguments and -u"
same "${DEPLOY}/scripts/cntools.library" "${LEGACY_DIR}/cntools.library" "the earlier cntools.library was not put back"

# --- CNCLI with BATCH_AUTO_UPDATE pulls the new cncli.sh -----------------------
new_deployment
check_rc 1 "${DEPLOY}/scripts/cncli.sh" Y
grep -q '^#BATCH_AUTO_UPDATE=N' "${DEPLOY}/scripts/cncli.sh" || fail "the merged cncli.sh lost its user section"
run_rc 0 ./cncli.sh -u sync
contains "${TEST_DIR}/run.out" "OLD cncli skip=Y sync" "the earlier cncli.sh did not run once, with -u first"
same "${DEPLOY}/scripts/cncli.sh" "${LEGACY_DIR}/cncli.sh" "the earlier cncli.sh was not put back"

# --- Mithril: script and library, then only the library -----------------------
new_deployment
check_rc 1 "${DEPLOY}/scripts/mithril.library" Y N N
check_rc 1 "${DEPLOY}/scripts/mithril-signer.sh" Y
run_rc 0 ./mithril-signer.sh -u
contains "${TEST_DIR}/run.out" "OLD mithril-signer skip=Y lib=old" "the earlier Mithril signer did not run with its library"
same "${DEPLOY}/scripts/mithril-signer.sh" "${LEGACY_DIR}/mithril-signer.sh" "the earlier mithril-signer.sh was not put back"
same "${DEPLOY}/scripts/mithril.library" "${LEGACY_DIR}/mithril.library" "the earlier mithril.library was not put back"

new_deployment
check_rc 1 "${DEPLOY}/scripts/mithril.library" Y N N
run_rc 0 ./mithril-signer.sh
contains "${TEST_DIR}/run.out" "OLD mithril-signer skip=Y lib=old" "the earlier Mithril signer did not run again with its library"
same "${DEPLOY}/scripts/mithril.library" "${LEGACY_DIR}/mithril.library" "the earlier mithril.library was not put back"

# --- The guard picks the newest archived copy that is not a new-layout file ----
new_deployment
cp "${SRC}/cncli.sh" "${DEPLOY}/scripts/cncli.sh"
mkdir -p "${DEPLOY}/scripts/archive"
printf '#!/usr/bin/env bash\necho "OLDER cncli $*"\n' > "${DEPLOY}/scripts/archive/cncli.sh_bkp100"
printf '#!/usr/bin/env bash\necho "NEWEST cncli $*"\n' > "${DEPLOY}/scripts/archive/cncli.sh_bkp200"
cp "${SRC}/cncli.sh" "${DEPLOY}/scripts/archive/cncli.sh_bkp300"
run_rc 0 ./cncli.sh leaderlog
contains "${TEST_DIR}/run.out" "NEWEST cncli -u leaderlog" "the guard did not run the newest earlier copy with -u"

# Without an archived copy it stops with an explanation and changes nothing.
new_deployment
cp "${SRC}/cncli.sh" "${DEPLOY}/scripts/cncli.sh"
run_rc 1 ./cncli.sh sync
contains "${TEST_DIR}/run.out" "has no earlier copy of it to put back" "the guard did not explain the missing copy"
contains "${TEST_DIR}/run.out" "upgrade/#from-master" "the guard did not point to the upgrade guide"
same "${DEPLOY}/scripts/cncli.sh" "${SRC}/cncli.sh" "the guard changed cncli.sh without a copy to put back"

# --- On the current layout the guard does nothing --------------------------------
rc=0; (cd "${SRC}" && ./gLiveView.sh) > "${TEST_DIR}/run.out" 2>&1 </dev/null || rc=$?
[[ ${rc} -eq 1 ]] || fail "the gLiveView stub in the repository returned ${rc}"
contains "${TEST_DIR}/run.out" "gLiveView moved to scripts/common-helper-scripts/gLiveView.sh" "the stub did not say where gLiveView moved"
mkdir -p "${TEST_DIR}/no-env/archive"
cp "${SRC}/gLiveView.sh" "${TEST_DIR}/no-env/gLiveView.sh"
printf '#!/usr/bin/env bash\necho restored\n' > "${TEST_DIR}/no-env/archive/gLiveView.sh_bkp100"
rc=0; (cd "${TEST_DIR}/no-env" && ./gLiveView.sh) > "${TEST_DIR}/run.out" 2>&1 </dev/null || rc=$?
[[ ${rc} -eq 1 ]] || fail "the stub without an env of the earlier layout returned ${rc}"
same "${TEST_DIR}/no-env/gLiveView.sh" "${SRC}/gLiveView.sh" "the guard acted without an env of the earlier layout"

printf 'legacy update bridge tests passed\n'
