#!/usr/bin/env bash
# sync-finish.sh FORK fast-forwards rhtas/main to a sync PR whose checks all passed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

fork="$1"
repo="${gh_org}/${fork}"
GH_TOKEN="$(gh_app_token "${SYNC_APP_ID:?}" "${SYNC_APP_KEY:?}" '{"contents":"write","pull_requests":"write","checks":"read","workflows":"write","actions":"write"}' "${fork}")"
export GH_TOKEN

# A sync can bring in upstream workflows, which GitHub registers as active.
gh_disable_foreign_workflows "${repo}"

pr="$(gh_api GET "/repos/${repo}/pulls?state=open&base=rhtas/main&head=${gh_org}:rhtas/sync" | jq '.[0] // empty')"
[ -n "${pr}" ] || { echo "${fork}: no sync PR"; exit 0; }
head="$(jq -r .head.sha <<<"${pr}")"
number="$(jq -r .number <<<"${pr}")"
# The guard fails on a sync PR by design, and the hand-off is what asked for this run.
checks="$(gh_api GET "/repos/${repo}/commits/${head}/check-runs?per_page=100" |
  jq '[.check_runs[] | select(.name | test("sync-merge-guard|hand-off") | not)]')"
if [ "$(jq length <<<"${checks}")" -eq 0 ] || [ "$(jq '[.[] | select(.status != "completed")] | length' <<<"${checks}")" -gt 0 ]; then
  echo "${fork}: PR ${number} is waiting for its checks"
  exit 0
fi
bad="$(jq -r '[.[] | select(.conclusion != "success" and .conclusion != "skipped") | .name] | join(", ")' <<<"${checks}")"
if [ -n "${bad}" ]; then
  echo "${fork}: PR ${number} needs a maintainer: ${bad}" >&2
  exit 1
fi
gh_graphql 'mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { clientMutationId } }' \
  "$(jq -r .node_id <<<"${pr}")"
jq -n --arg s "${head}" '{sha: $s, force: false}' | gh_api PATCH "/repos/${repo}/git/refs/heads/rhtas/main" - >/dev/null
gh_api DELETE "/repos/${repo}/git/refs/heads/rhtas/sync" >/dev/null
echo "${fork}: rhtas/main is ${head}"
