#!/usr/bin/env bash
# bump-update.sh brings the oldest bump or ci-pin PR that main has moved past up to date, one at a time.
# A bump is rebuilt on main rather than merged with it, as two bumps of images.env conflict.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

repo="${gh_org}/secure-sign-pqc-operator"
GH_TOKEN="$(gh_app_token "${BOT_APP_ID:?}" "${BOT_APP_KEY:?}" '{"contents":"write","pull_requests":"write","checks":"read","workflows":"write"}' secure-sign-pqc-operator)"
export GH_TOKEN

# rebuild NUMBER REF SHA TITLE puts the image line bump PR NUMBER sets on main's images.env, and moves REF there.
rebuild() {
  local number="$1" ref="$2" sha="$3" title="$4" file key line work new
  [[ "${ref}" =~ ^bump/([0-9]+\.[0-9]+)-([a-z0-9-]+)-[0-9a-f]{12}$ ]] || return 1
  file="versions/${BASH_REMATCH[1]}/images.env"
  key="$(tr 'a-z-' 'A-Z_' <<<"${BASH_REMATCH[2]}")"
  line="$(gh_api GET "/repos/${repo}/contents/${file}?ref=${sha}" | jq -r .content | base64 -d | grep -E "^${key}=")" || return 1
  work="$(mktemp)"
  gh_api GET "/repos/${repo}/contents/${file}?ref=main" | jq -r .content | base64 -d >"${work}" || return 1
  grep -q "^${key}=" "${work}" || return 1
  if grep -qxF "${line}" "${work}"; then
    gh_api PATCH "/repos/${repo}/pulls/${number}" '{"state":"closed"}' >/dev/null || return 1
    gh_api DELETE "/repos/${repo}/git/refs/heads/${ref}" >/dev/null || return 1
    echo "PR ${number} (${ref}) is already on main: closed"
    return 0
  fi
  awk -v k="${key}=" -v l="${line}" 'index($0, k) == 1 { $0 = l } { print }' "${work}" >"${work}.new" || return 1
  new="$(gh_commit "${repo}" main "${title}" "${file}=${work}.new")" || return 1
  jq -n --arg s "${new}" '{sha: $s, force: true}' | gh_api PATCH "/repos/${repo}/git/refs/heads/${ref}" - >/dev/null || return 1
  rm -f "${work}" "${work}.new"
}

pulls="$(gh_api GET "/repos/${repo}/pulls?state=open&base=main&per_page=100" |
  jq -r '[.[] | select(.head.ref | startswith("bump/") or startswith("ci-pin/"))] | sort_by(.number) | .[] | "\(.number) \(.head.ref) \(.head.sha) \(.title)"')"
while read -r number ref sha title; do
  [ -n "${number}" ] || continue
  checks="$(gh_api GET "/repos/${repo}/commits/${sha}/check-runs?per_page=100" | jq '[.check_runs[] | select(.name | contains("hand-off") | not)]')"
  if [ "$(jq length <<<"${checks}")" -eq 0 ] || [ "$(jq '[.[] | select(.status != "completed")] | length' <<<"${checks}")" -gt 0 ]; then
    echo "PR ${number} (${ref}) is waiting for its checks"
    exit 0
  fi
  bad="$(jq -r '[.[] | select(.conclusion != "success" and .conclusion != "skipped") | .name] | join(", ")' <<<"${checks}")"
  if [ -n "${bad}" ]; then
    echo "PR ${number} (${ref}) needs a maintainer: ${bad}"
    continue
  fi
  behind="$(gh_api GET "/repos/${repo}/compare/main...${ref}" | jq -r .behind_by)"
  [ "${behind}" -gt 0 ] || continue
  case "${ref}" in
    bump/*)
      rebuild "${number}" "${ref}" "${sha}" "${title}" ||
        { echo "PR ${number} (${ref}) could not be rebuilt on main: it needs a maintainer"; continue; } ;;
    *)
      jq -n --arg s "${sha}" '{expected_head_sha: $s}' | gh_api PUT "/repos/${repo}/pulls/${number}/update-branch" - >/dev/null ||
        { echo "PR ${number} (${ref}) could not be updated: it needs a maintainer"; continue; } ;;
  esac
  echo "PR ${number} (${ref}) was ${behind} behind main"
  exit 0
done <<<"${pulls}"
