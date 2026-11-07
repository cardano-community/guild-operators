#!/usr/bin/env bash
# Every binary the pre-release networks pin, on this machine's architecture:
# the checksum matches and the binary runs and reports the pinned version.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/guild-network-binaries.XXXXXX")"
trap 'rm -rf -- "${WORK}"' EXIT

case "$(uname -m)" in
  aarch64|arm64) ARCHITECTURE="linux-aarch64" ;;
  *) ARCHITECTURE="linux-x86_64" ;;
esac

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

check_component() { # $1 = binary, $2 = version, $3 = url, $4 = sha256
  local binary="$1" version="$2" url="$3" sha="$4"
  local archive="${WORK}/${sha}.tar.gz" extract="${WORK}/${sha}" found="" reported=""

  if [[ ! -f "${archive}" ]]; then
    curl --fail --silent --show-error --location --retry 2 --output "${archive}" "${url}" ||
      fail "could not download ${url}"
    [[ "$(sha256sum "${archive}" | awk '{print $1}')" == "${sha}" ]] ||
      fail "${url} does not match its pinned checksum"
    mkdir -p "${extract}"
    tar -xzf "${archive}" -C "${extract}" || fail "could not extract ${url}"
  fi
  # The cardano-cli releases name it after the architecture, such as cardano-cli-x86_64-linux.
  found="$(find "${extract}" -type f \( -name "${binary}" -o -name "${binary}-*-linux" \) | head -n 1)"
  [[ -n "${found}" ]] || fail "${url} has no ${binary}"
  chmod 0755 "${found}"
  reported="$("${found}" --version 2>&1 | head -n 1)" || fail "${binary} ${version} did not run: ${reported}"
  [[ "${reported}" == *" ${version}"* ]] ||
    fail "${binary} from ${url} reports '${reported}', expected ${version}"
  printf '  %-18s %-12s %s\n' "${binary}" "${version}" "ok"
}

for overlay in "${ROOT_DIR}"/files/node-implementations/cnode/networks/*.json; do
  printf '%s on %s\n' "$(basename "${overlay}" .json)" "${ARCHITECTURE}"
  check_component cardano-node \
    "$(jq -er '.version' "${overlay}")" \
    "$(jq -er --arg arch "${ARCHITECTURE}" '.artifacts[$arch].url' "${overlay}")" \
    "$(jq -er --arg arch "${ARCHITECTURE}" '.artifacts[$arch].sha256' "${overlay}")"
  check_component cardano-cli \
    "$(jq -er '.companions["cardano-cli"].version' "${overlay}")" \
    "$(jq -er --arg arch "${ARCHITECTURE}" '.companions["cardano-cli"].artifacts[$arch].url' "${overlay}")" \
    "$(jq -er --arg arch "${ARCHITECTURE}" '.companions["cardano-cli"].artifacts[$arch].sha256' "${overlay}")"
  if [[ "$(jq -r '.companions["cardano-db-sync"].version // empty' "${overlay}")" != "" ]]; then
    check_component cardano-db-sync \
      "$(jq -er '.companions["cardano-db-sync"].version' "${overlay}")" \
      "$(jq -er --arg arch "${ARCHITECTURE}" '.companions["cardano-db-sync"].artifacts[$arch].url' "${overlay}")" \
      "$(jq -er --arg arch "${ARCHITECTURE}" '.companions["cardano-db-sync"].artifacts[$arch].sha256' "${overlay}")"
  fi
done
printf 'network-binaries: PASS\n'
