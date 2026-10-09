#!/usr/bin/env bash
# Toolbox transport fixture: never a cryptographic implementation.
set -euo pipefail
[[ "$1" == qr-code && "$2" == encode ]] || exit 2
shift 2
output='' input='' pin=''
while (($#)); do
  case "$1" in --pin) pin="$2" ;; --input) input="$2" ;; --output) output="$2" ;; --opts) [[ "$2" == img ]] || exit 2 ;; *) exit 2 ;; esac
  shift 2
done
[[ "${pin}" == 0042 && "$(< "${input}")" == ed25519e_sk1* ]] || exit 2
[[ "${TOOLBOX_TEST_FAIL:-N}" != Y ]] || exit 1
if [[ -n "${output}" ]]; then printf '\211PNG\r\n\032\nfixture encrypted QR' > "${output}"
else printf 'fixture console QR (encrypted)\n'; fi
