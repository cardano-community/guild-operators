#!/usr/bin/env bash
# The nightly decision for Dingo or Amaru, which follow their newest release:
#
#   newest works            nothing to do, or propose removing an existing pin
#   newest fails            find the newest release that works, propose pinning it,
#                           and open an issue
#
# It only ever proposes. A person merges the pull request.
#
#   files/tools/check-node-release.sh <dingo|amaru> <base branch>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
API_BASE="${PINS_API_BASE:-https://api.github.com}"
CHECK_COMMAND="${NODE_CHECK_COMMAND:-bash ${ROOT}/files/tests/latest-release-check.sh}"
MAX_RELEASES="${NODE_CHECK_MAX_RELEASES:-5}"
RUN_LINK="${NODE_CHECK_RUN_URL:-this run}"

IMPLEMENTATION="${1:?implementation}"
BASE_BRANCH="${2:?base branch}"
PROPOSAL="bot/pin-${IMPLEMENTATION}"
MANIFEST="files/node-implementations/${IMPLEMENTATION}/release.json"
ATTEMPT=0

cd "${ROOT}"

check_branch() { # $1 = branch. Each attempt gets its own target folder.
  ATTEMPT=$(( ATTEMPT + 1 ))
  # shellcheck disable=SC2086  # the command may carry its own arguments
  GUILD_SMOKE_TARGET="${IMPLEMENTATION}check${ATTEMPT}" ${CHECK_COMMAND} "${IMPLEMENTATION}" "$1"
}

publish_manifest() { # $1 = commit message
  git switch --quiet -C "${PROPOSAL}" "origin/${BASE_BRANCH}"
  git add "${MANIFEST}"
  git commit --quiet -m "$1"
  git push --quiet --force origin "${PROPOSAL}"
}

report_issue() { # $1 = title, $2 = body
  local number
  number="$(gh issue list --state open --search "in:title \"$1\"" --json number --jq '.[0].number // empty')"
  if [[ -n "${number}" ]]; then
    gh issue comment "${number}" --body "$2"
  else
    gh issue create --title "$1" --body "$2"
  fi
}

propose() { # $1 = title, $2 = body
  local number
  number="$(gh pr list --head "${PROPOSAL}" --state open --json number --jq '.[0].number // empty')"
  if [[ -n "${number}" ]]; then
    gh pr edit "${number}" --title "$1" --body "$2"
  else
    gh pr create --base "${BASE_BRANCH}" --head "${PROPOSAL}" --title "$1" --body "$2"
  fi
}

current_version="$(jq -er '.version' "${MANIFEST}")"

# ---- pinned earlier: has the newest release recovered? --------------------------
if [[ "${current_version}" != "latest" ]]; then
  bash files/tools/pin-node-release.sh "${IMPLEMENTATION}" latest >/dev/null
  publish_manifest "${IMPLEMENTATION}: follow the newest release again"
  if check_branch "${PROPOSAL}"; then
    propose "${IMPLEMENTATION}: follow the newest release again" \
      "${IMPLEMENTATION} is pinned to ${current_version}, and the newest release now passes the nightly check: ${RUN_LINK}"
  else
    printf '%s stays pinned to %s: the newest release still fails.\n' "${IMPLEMENTATION}" "${current_version}"
  fi
  exit 0
fi

# ---- following the newest release ------------------------------------------------
if check_branch "${BASE_BRANCH}"; then
  printf '%s: the newest release passes.\n' "${IMPLEMENTATION}"
  exit 0
fi

repository="$(jq -er '.github' "${MANIFEST}")"
# Oldest last, leaving out drafts and the newest release that just failed.
mapfile -t tags < <(
  curl --fail --silent --show-error --location --retry 2 --max-time 60 \
    ${GH_TOKEN:+--header "Authorization: Bearer ${GH_TOKEN}"} \
    "${API_BASE}/repos/${repository}/releases?per_page=$(( MAX_RELEASES + 3 ))" |
    jq -r '[.[] | select(.draft == false)] | sort_by(.published_at) | reverse | .[1:] | .[].tag_name' |
    head -n "${MAX_RELEASES}"
)
newest="$(curl --fail --silent --show-error --location --retry 2 --max-time 60 \
  ${GH_TOKEN:+--header "Authorization: Bearer ${GH_TOKEN}"} \
  "${API_BASE}/repos/${repository}/releases?per_page=$(( MAX_RELEASES + 3 ))" |
  jq -r '[.[] | select(.draft == false)] | sort_by(.published_at) | last | .tag_name')"

for tag in "${tags[@]}"; do
  git checkout --quiet "origin/${BASE_BRANCH}" -- "${MANIFEST}"
  bash files/tools/pin-node-release.sh "${IMPLEMENTATION}" "${tag}" >/dev/null || continue
  publish_manifest "${IMPLEMENTATION}: pin ${tag}, the newest release that works"
  if check_branch "${PROPOSAL}"; then
    propose "${IMPLEMENTATION}: pin ${tag}, the newest release that works" \
      "The newest ${IMPLEMENTATION} release, ${newest}, failed the nightly check, and ${tag} passed it: ${RUN_LINK}

Merging this keeps new deployments on ${tag}. The job proposes returning to the newest release once one passes."
    report_issue "Node release check: ${IMPLEMENTATION} ${newest} failed" \
      "${newest} failed the nightly check. A pull request pins ${tag}, which passed: ${RUN_LINK}"
    exit 0
  fi
done

report_issue "Node release check: ${IMPLEMENTATION} ${newest} failed" \
  "${newest} failed the nightly check, and so did the ${#tags[@]} releases before it, so nothing was proposed: ${RUN_LINK}"
exit 1
