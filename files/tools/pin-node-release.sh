#!/usr/bin/env bash
# Pin Dingo or Amaru to one release, or return it to following the newest.
#
#   files/tools/pin-node-release.sh <dingo|amaru> <release tag>
#   files/tools/pin-node-release.sh <dingo|amaru> latest
#
# These implementations follow their newest release. A pin is for when that
# release fails the nightly check. It records GitHub's published digests, so the
# deployment downloads exactly what was tested.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
API_BASE="${PINS_API_BASE:-https://api.github.com}"

die() {
  printf 'pin-node-release: %s\n' "$*" >&2
  exit 1
}

IMPLEMENTATION="${1:-}"
TAG="${2:-}"
case "${IMPLEMENTATION}" in
  dingo|amaru) ;;
  *) die "usage: pin-node-release.sh <dingo|amaru> <release tag|latest>" ;;
esac
[[ -n "${TAG}" ]] || die "usage: pin-node-release.sh <dingo|amaru> <release tag|latest>"
MANIFEST="${ROOT}/files/node-implementations/${IMPLEMENTATION}/release.json"
[[ -f "${MANIFEST}" ]] || die "no release manifest for ${IMPLEMENTATION} in this checkout"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/guild-node-pin.XXXXXX")"
trap 'rm -rf -- "${STAGE}"' EXIT

if [[ "${TAG}" == "latest" ]]; then
  jq '.version = "latest" | del(.artifacts)' "${MANIFEST}" > "${STAGE}/release.json"
  cp "${STAGE}/release.json" "${MANIFEST}"
  printf '%s now follows its newest release.\n' "${IMPLEMENTATION}"
  exit 0
fi

[[ "${TAG}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || die "unsafe release tag '${TAG}'"
REPOSITORY="$(jq -er '.github' "${MANIFEST}")"
curl --fail --silent --show-error --location --retry 2 --max-time 60 \
  ${GH_TOKEN:+--header "Authorization: Bearer ${GH_TOKEN}"} \
  --output "${STAGE}/github.json" \
  "${API_BASE}/repos/${REPOSITORY}/releases/tags/${TAG}" ||
  die "${REPOSITORY} has no release ${TAG}"

# The same rule the rolling path uses: exactly one uploaded asset for each
# architecture, and a digest GitHub published for it.
if ! jq -e --arg version "${TAG#v}" --slurpfile release "${STAGE}/github.json" '
    $release[0] as $github |
    (.assets | to_entries | map(
      .key as $architecture | .value as $selector |
      [$github.assets[] | select(.name | test($selector))] as $matches |
      if ($matches | length) != 1 then
        error("expected one asset for \($architecture), found \($matches | length)")
      elif ($matches[0].digest // "" | test("^sha256:[0-9a-f]{64}$") | not) then
        error("GitHub publishes no sha256 digest for \($matches[0].name)")
      else
        {key: $architecture, value: {
          url: $matches[0].browser_download_url,
          sha256: ($matches[0].digest | ltrimstr("sha256:"))
        }}
      end
    ) | from_entries) as $artifacts |
    .version = $version | .artifacts = $artifacts
  ' "${MANIFEST}" > "${STAGE}/release.json" 2> "${STAGE}/error"; then
  die "could not pin ${TAG}: $(sed 's/^jq: error[^:]*: //' "${STAGE}/error")"
fi
cp "${STAGE}/release.json" "${MANIFEST}"
printf '%s is now pinned to %s.\n' "${IMPLEMENTATION}" "${TAG}"
