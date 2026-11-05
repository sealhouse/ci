#!/usr/bin/env bash
# bump-update.sh brings the oldest bump or ci-pin PR that main has moved past up to date, one at a time.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

repo="${gh_org}/secure-sign-pqc-operator"
GH_TOKEN="$(gh_app_token "${BOT_APP_ID:?}" "${BOT_APP_KEY:?}" '{"contents":"write","pull_requests":"write","checks":"read","workflows":"write"}' secure-sign-pqc-operator)"
export GH_TOKEN
pulls="$(gh_api GET "/repos/${repo}/pulls?state=open&base=main&per_page=100" |
  jq -r '[.[] | select(.head.ref | startswith("bump/") or startswith("ci-pin/"))] | sort_by(.number) | .[] | "\(.number) \(.head.ref) \(.head.sha)"')"
while read -r number ref sha; do
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
  jq -n --arg s "${sha}" '{expected_head_sha: $s}' | gh_api PUT "/repos/${repo}/pulls/${number}/update-branch" - >/dev/null
  echo "PR ${number} (${ref}) was ${behind} behind main"
  exit 0
done <<<"${pulls}"
