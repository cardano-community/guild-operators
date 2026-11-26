#!/usr/bin/env bash
# Dingo and Amaru follow their newest release until it fails. This covers the
# pinned path: the deploy profiles accept it, it installs what it records, the
# pin tool writes it, and the nightly decision proposes the right thing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-node-pin-test.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

API="${TEST_ROOT}/api"
export PINS_API_BASE="file://${API}"
unset GH_TOKEN
SHA_A="$(printf 'a%.0s' {1..64})"
SHA_B="$(printf 'b%.0s' {1..64})"

fake_github() { # $1 = repository, $2 = selector-matching name stem, $3... = tags, newest first
  local repository="$1" stem="$2" tag date=20 list="[]"
  shift 2
  mkdir -p "${API}/repos/${repository}/releases/tags"
  for tag in "$@"; do
    jq -n --arg tag "${tag}" --arg stem "${stem}" --arg a "sha256:${SHA_A}" --arg b "sha256:${SHA_B}" '{
      tag_name: $tag,
      assets: [
        {name: ($stem + "-" + $tag + "-x86_64.tar.gz"), browser_download_url: ("https://example.invalid/" + $tag + "/x86"), digest: $a},
        {name: ($stem + "-" + $tag + "-aarch64.tar.gz"), browser_download_url: ("https://example.invalid/" + $tag + "/arm"), digest: $b},
        {name: "unrelated.txt", browser_download_url: "https://example.invalid/other", digest: $a}
      ]
    }' > "${API}/repos/${repository}/releases/tags/${tag}"
    list="$(jq --arg tag "${tag}" --arg date "2026-10-${date}T00:00:00Z" \
      '. + [{tag_name: $tag, draft: false, published_at: $date}]' <<< "${list}")"
    date=$(( date - 1 ))
  done
  printf '%s\n' "${list}" > "${API}/release-list.json"
}

repo_checkout() { # $1 = implementation; a throwaway repository with a bare origin
  local implementation="$1"
  local work="${TEST_ROOT}/${implementation}/work"
  rm -rf -- "${TEST_ROOT:?}/${implementation}"
  mkdir -p "${work}/files/node-implementations/${implementation}" "${work}/files/tools"
  jq --arg stem "^${implementation}-[^/]+" '
    .github = "example/node" |
    .assets = {
      "linux-x86_64": ($stem + "-x86_64[.]tar[.]gz$"),
      "linux-aarch64": ($stem + "-aarch64[.]tar[.]gz$")
    }
  ' "${ROOT_DIR}/files/node-implementations/${implementation}/release.json" \
    > "${work}/files/node-implementations/${implementation}/release.json"
  cp "${ROOT_DIR}/files/tools/pin-node-release.sh" "${ROOT_DIR}/files/tools/check-node-release.sh" "${work}/files/tools/"
  git init --quiet --bare "${TEST_ROOT}/${implementation}/origin.git"
  git -C "${work}" init --quiet -b base
  git -C "${work}" config user.name test
  git -C "${work}" config user.email test@invalid
  git -C "${work}" add -A
  git -C "${work}" commit --quiet -m start
  git -C "${work}" remote add origin "${TEST_ROOT}/${implementation}/origin.git"
  git -C "${work}" push --quiet origin base
  git -C "${work}" fetch --quiet origin
  printf '%s' "${work}"
}

# ---- the deploy profiles accept a pin, and only a complete one -------------------
for implementation in dingo amaru; do
  (
    # shellcheck source=/dev/null
    . "${ROOT_DIR}/scripts/${implementation}-helper-scripts/deploy-${implementation}.sh"
    validate="${implementation}_deploy_validate_release_metadata"
    resolve="${implementation}_deploy_resolve_binary"
    rolling="${ROOT_DIR}/files/node-implementations/${implementation}/release.json"
    manifest="${TEST_ROOT}/${implementation}-manifest.json"
    "${validate}" "${rolling}" || fail "${implementation} rejected its rolling manifest"
    jq --arg a "${SHA_A}" --arg b "${SHA_B}" '.version = "1.2.3" | .artifacts = {
      "linux-x86_64": {url: "https://example.invalid/x86", sha256: $a},
      "linux-aarch64": {url: "https://example.invalid/arm", sha256: $b}
    }' "${rolling}" > "${manifest}"
    "${validate}" "${manifest}" || fail "${implementation} rejected a complete pin"

    # A pin installs exactly what it records, without asking GitHub.
    dispatcher_resolve_github_release() { fail "a pinned release asked GitHub for the newest one"; }
    "${resolve}" "${manifest}" linux-x86_64 >/dev/null || fail "${implementation} could not resolve its pin"
    upper="${implementation^^}"
    version_var="${upper}_RESOLVED_VERSION"; url_var="${upper}_RESOLVED_URL"; sha_var="${upper}_RESOLVED_SHA256"
    [[ "${!version_var}" == "1.2.3" ]] || fail "${implementation} resolved version ${!version_var}"
    [[ "${!url_var}" == "https://example.invalid/x86" ]] || fail "${implementation} resolved url ${!url_var}"
    [[ "${!sha_var}" == "${SHA_A}" ]] || fail "${implementation} resolved digest ${!sha_var}"
    "${resolve}" "${manifest}" linux-aarch64 >/dev/null || fail "${implementation} could not resolve its arm pin"
    [[ "${!sha_var}" == "${SHA_B}" ]] || fail "${implementation} resolved arm digest ${!sha_var}"

    reject() { # $1 = jq filter, $2 = description
      jq "$1" "${manifest}" > "${manifest}.bad"
      if "${validate}" "${manifest}.bad" >/dev/null 2>&1; then
        fail "${implementation} accepted ${2}"
      fi
    }
    reject 'del(.artifacts)' "a pin with no artifacts"
    reject 'del(.artifacts["linux-aarch64"])' "a pin missing an architecture"
    reject '.artifacts["linux-x86_64"].sha256 = "short"' "a pin with a bad digest"
    reject '.artifacts["linux-x86_64"].url = "http://example.invalid/x86"' "a pin without https"
    reject '.version = "latest"' "a rolling manifest with artifacts"
    reject '.version = "../1.2.3"' "an unsafe pinned version"
  ) || exit 1
done

# ---- the pin tool ----------------------------------------------------------------
work="$(repo_checkout dingo)"
fake_github example/node dingo v3.0.0 v2.0.0 v1.0.0
manifest="${work}/files/node-implementations/dingo/release.json"
before="$(cat "${manifest}")"
bash "${work}/files/tools/pin-node-release.sh" dingo v2.0.0 >/dev/null || fail "could not pin v2.0.0"
[[ "$(jq -r '.version' "${manifest}")" == "2.0.0" ]] || fail "the version keeps its v prefix"
[[ "$(jq -r '.artifacts["linux-x86_64"].url' "${manifest}")" == "https://example.invalid/v2.0.0/x86" ]] || fail "wrong x86 url"
[[ "$(jq -r '.artifacts["linux-aarch64"].sha256' "${manifest}")" == "${SHA_B}" ]] || fail "wrong arm digest"
jq -e '.assets["linux-x86_64"]' "${manifest}" >/dev/null || fail "the selectors were lost"
bash "${work}/files/tools/pin-node-release.sh" dingo latest >/dev/null || fail "could not unpin"
[[ "$(jq -cS . "${manifest}")" == "$(jq -cS . <<< "${before}")" ]] || fail "unpinning did not restore the manifest"

if bash "${work}/files/tools/pin-node-release.sh" dingo v9.9.9 >/dev/null 2>&1; then
  fail "pinned a release that does not exist"
fi
[[ "$(jq -cS . "${manifest}")" == "$(jq -cS . <<< "${before}")" ]] || fail "a failed pin changed the manifest"
jq 'del(.assets[0].digest)' "${API}/repos/example/node/releases/tags/v2.0.0" \
  > "${API}/repos/example/node/releases/tags/v2.0.0.next"
mv -f "${API}/repos/example/node/releases/tags/v2.0.0.next" "${API}/repos/example/node/releases/tags/v2.0.0"
if bash "${work}/files/tools/pin-node-release.sh" dingo v2.0.0 >/dev/null 2>&1; then
  fail "pinned a release with no published digest"
fi
[[ "$(jq -cS . "${manifest}")" == "$(jq -cS . <<< "${before}")" ]] || fail "a failed pin changed the manifest"

# ---- the nightly decision --------------------------------------------------------
fake_bin="${TEST_ROOT}/fake-bin"
mkdir -p "${fake_bin}"
GH_LOG="${TEST_ROOT}/gh.log"
export GH_LOG
cat > "${fake_bin}/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG}"
case "$1 $2" in
  "issue list"|"pr list") printf '' ;;
esac
GH
chmod 0755 "${fake_bin}/gh"
# A file:// URL can't carry a query, so the release listing is answered here.
REAL_CURL="$(command -v curl)"
export REAL_CURL RELEASE_LIST="${API}/release-list.json"
cat > "${fake_bin}/curl" <<'CURL'
#!/usr/bin/env bash
for argument in "$@"; do
  case "${argument}" in
    *"/releases?per_page="*) cat "${RELEASE_LIST}"; exit 0 ;;
  esac
done
exec "${REAL_CURL}" "$@"
CURL
chmod 0755 "${fake_bin}/curl"
PATH="${fake_bin}:${PATH}"
FAKE_CHECK="${TEST_ROOT}/fake-check.sh"
cat > "${FAKE_CHECK}" <<'CHECK'
#!/usr/bin/env bash
# Fails while the checked-out manifest would install a release named in BAD_RELEASES.
printf '%s %s\n' "$1" "$2" >> "${CHECK_LOG}"
version="$(jq -r '.version' "${MANIFEST_PATH}")"
[[ " ${BAD_RELEASES} " != *" ${version} "* ]]
CHECK
chmod 0755 "${FAKE_CHECK}"
export NODE_CHECK_COMMAND="${FAKE_CHECK}"
export NODE_CHECK_MAX_RELEASES=5
CHECK_LOG="${TEST_ROOT}/check.log"
export CHECK_LOG

decide() { # $1 = checkout, then the releases that fail
  local work="$1"
  shift
  : > "${GH_LOG}"
  : > "${CHECK_LOG}"
  export MANIFEST_PATH="${work}/files/node-implementations/dingo/release.json"
  export BAD_RELEASES="$*"
  (cd "${work}" && bash files/tools/check-node-release.sh dingo base) >/dev/null 2>&1
}

# The newest release works: nothing is proposed.
work="$(repo_checkout dingo)"
fake_github example/node dingo v3.0.0 v2.0.0 v1.0.0
decide "${work}" none || fail "a passing release should succeed"
[[ ! -s "${GH_LOG}" ]] || fail "a passing release proposed something: $(cat "${GH_LOG}")"
[[ "$(wc -l < "${CHECK_LOG}")" -eq 1 ]] || fail "a passing release was checked more than once"

# The newest fails and so does the one before: it pins the newest that works.
work="$(repo_checkout dingo)"
fake_github example/node dingo v3.0.0 v2.0.0 v1.0.0
decide "${work}" latest 2.0.0 || fail "finding a good release should succeed"
grep -q '^pr create .*pin v1.0.0' "${GH_LOG}" || fail "did not propose v1.0.0: $(cat "${GH_LOG}")"
grep -q '^issue create .*v3.0.0 failed' "${GH_LOG}" || fail "did not report v3.0.0: $(cat "${GH_LOG}")"
[[ "$(git -C "${work}" show origin/bot/pin-dingo:files/node-implementations/dingo/release.json | jq -r '.version')" == "1.0.0" ]] ||
  fail "the proposal branch does not pin 1.0.0"
[[ "$(git -C "${work}" show origin/base:files/node-implementations/dingo/release.json | jq -r '.version')" == "latest" ]] ||
  fail "the base branch changed"

# Nothing works: an issue, no pull request, and the job fails so it shows up.
work="$(repo_checkout dingo)"
fake_github example/node dingo v3.0.0 v2.0.0 v1.0.0
if decide "${work}" latest 2.0.0 1.0.0; then
  fail "no good release should fail the job"
fi
grep -q '^issue create' "${GH_LOG}" || fail "did not report the failure"
grep -q '^pr create' "${GH_LOG}" && fail "proposed a release that failed"

# Pinned earlier, and the newest has recovered: propose following it again.
work="$(repo_checkout dingo)"
fake_github example/node dingo v3.0.0 v2.0.0 v1.0.0
bash "${work}/files/tools/pin-node-release.sh" dingo v2.0.0 >/dev/null
git -C "${work}" add -A
git -C "${work}" commit --quiet -m pinned
git -C "${work}" push --quiet origin base
git -C "${work}" fetch --quiet origin
decide "${work}" none || fail "a recovered release should succeed"
grep -q '^pr create .*follow the newest release again' "${GH_LOG}" || fail "did not propose unpinning: $(cat "${GH_LOG}")"

# Pinned, and the newest still fails: nothing new is proposed.
work="$(repo_checkout dingo)"
fake_github example/node dingo v3.0.0 v2.0.0 v1.0.0
bash "${work}/files/tools/pin-node-release.sh" dingo v2.0.0 >/dev/null
git -C "${work}" add -A
git -C "${work}" commit --quiet -m pinned
git -C "${work}" push --quiet origin base
git -C "${work}" fetch --quiet origin
decide "${work}" latest || fail "staying pinned is not a failure"
grep -q '^pr create' "${GH_LOG}" && fail "proposed unpinning while the newest fails"

printf 'node-release-pin: PASS\n'
