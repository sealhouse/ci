#!/usr/bin/env bash
# sync-fork.sh FORK UPSTREAM_URL BRANCH mirrors upstream into FORK and opens its draft sync PR.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

fork="$1" upstream="$2" branch="$3"
repo="${gh_org}/${fork}"
GH_TOKEN="$(gh_app_token "${SYNC_APP_ID:?}" "${SYNC_APP_KEY:?}" '{"contents":"write","pull_requests":"write","workflows":"write"}' "${fork}")"
export GH_TOKEN
base="${SEALHOUSE_GIT_BASE:-https://github.com/${gh_org}}"
export GIT_AUTHOR_NAME=sealhouse-sync GIT_AUTHOR_EMAIL=sealhouse-sync@sealhouse.invalid
export GIT_COMMITTER_NAME=sealhouse-sync GIT_COMMITTER_EMAIL=sealhouse-sync@sealhouse.invalid

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
g() { git -C "${work}" "$@"; }
g init -q .
g symbolic-ref HEAD refs/heads/sealhouse-sync-work
# shellcheck disable=SC2016 # expanded by the credential helper
g config credential.helper '!f() { echo username=x-access-token; echo "password=${GH_TOKEN}"; }; f'
g remote add origin "${base}/${fork}.git"
g remote add upstream "${upstream}"
g fetch -q origin "refs/heads/rhtas/main:refs/heads/rhtas/main" "refs/heads/${branch}:refs/heads/${branch}"

FORK_UPSTREAM_BRANCH="${branch}" "${root}/hack/fork-sync.sh" "${work}"

# The mirror, and the upstream tags that version the fork's images and releases.
g fetch -q --tags upstream
g push -q origin "refs/heads/${branch}:refs/heads/${branch}"
mapfile -t tags < <(g for-each-ref --merged "refs/heads/${branch}" --format='%(refname)' refs/tags)
if [ "${#tags[@]}" -gt 0 ]; then g push -q origin "${tags[@]}"; fi

g rev-parse -q --verify refs/heads/rhtas/sync >/dev/null || exit 0
g push -q -f origin refs/heads/rhtas/sync:refs/heads/rhtas/sync
open="$(gh_api GET "/repos/${repo}/pulls?state=open&base=rhtas/main&head=${gh_org}:rhtas/sync" | jq length)"
if [ "${open}" -eq 0 ]; then
  jq -n --arg t "Sync upstream ${branch} $(g rev-parse --short "refs/heads/${branch}")" \
    '{title: $t, head: "rhtas/sync", base: "rhtas/main", draft: true}' | gh_api POST "/repos/${repo}/pulls" - >/dev/null
fi
echo "${fork}: rhtas/sync is $(g rev-parse --short refs/heads/rhtas/sync)"
