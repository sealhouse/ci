#!/usr/bin/env bash
# replace-consumers.sh opens a PR on every consumer that does not follow replaces.lock.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

base_url="${SEALHOUSE_GIT_BASE:-https://github.com/${gh_org}}"
work="$(mktemp -d)"
trap 'chmod -R u+w "${work}" 2>/dev/null; rm -rf "${work}"' EXIT
export GOMODCACHE="${GOMODCACHE:-${work}/modcache}"
id="$(replaces_inventory | sha256sum | cut -c1-12)"
if [ -n "${SEALHOUSE_REPLACES:-}" ]; then id="$(sha256sum "${SEALHOUSE_REPLACES}" | cut -c1-12)"; fi
name="replaces/${id}"
failed=0

# consumer REPO BASE HEADLINE BODY
consumer() {
  local repo="$1" base="$2" headline="$3" body="$4" full="${gh_org}/$1" tree="${work}/$1" pulls specs=() f message new pr number ref
  GH_TOKEN="$(gh_app_token "${BOT_APP_ID:?}" "${BOT_APP_KEY:?}" '{"contents":"write","pull_requests":"write"}' "${repo}")"
  export GH_TOKEN
  pulls="$(gh_api GET "/repos/${full}/pulls?state=open&per_page=100" | jq --arg b "${base}" '[.[] | select(.base.ref == $b and (.head.ref | startswith("replaces/")))]')"
  while read -r number ref; do
    [ -n "${number}" ] || continue
    jq -n '{state: "closed"}' | gh_api PATCH "/repos/${full}/pulls/${number}" - >/dev/null
    gh_api DELETE "/repos/${full}/git/refs/heads/${ref}" >/dev/null
    echo "${repo}: closed PR ${number} (${ref}), which ${name} supersedes"
  done < <(jq -r --arg n "${name}" '.[] | select(.head.ref != $n) | "\(.number) \(.head.ref)"' <<<"${pulls}")
  if [ "$(jq --arg n "${name}" '[.[] | select(.head.ref == $n)] | length' <<<"${pulls}")" -gt 0 ]; then
    echo "${repo}: ${name} is open"
    return 0
  fi
  git clone -q --filter=blob:none -b "${base}" "${base_url}/${repo}.git" "${tree}"
  [ -n "$(git -C "${tree}" ls-files '*go.mod' 'go.mod')" ] || return 0
  "${root}/hack/apply-replaces.sh" "${tree}"
  while read -r f; do
    specs+=("${f}=${tree}/${f}")
  done < <(git -C "${tree}" status --porcelain -- ':(glob)**/go.mod' ':(glob)**/go.sum' | cut -c4-)
  if [ "${#specs[@]}" -eq 0 ]; then
    echo "${repo}: follows the inventory"
    return 0
  fi
  message="${headline}${body:+$'\n\n'${body}}"
  new="$(gh_commit "${full}" "${base}" "${message}" "${specs[@]}")"
  jq -n --arg r "refs/heads/${name}" --arg s "${new}" '{ref: $r, sha: $s}' | gh_api POST "/repos/${full}/git/refs" - >/dev/null
  pr="$(jq -n --arg t "${headline}" --arg h "${name}" --arg b "${base}" '{title: $t, head: $h, base: $b}' | gh_api POST "/repos/${full}/pulls" -)"
  gh_graphql "mutation(\$id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: \$id, mergeMethod: SQUASH, commitHeadline: \"${headline//\"/\\\"}\", commitBody: \"${body}\"}) { clientMutationId } }" \
    "$(jq -r .node_id <<<"${pr}")"
  echo "${repo}: PR $(jq -r .number <<<"${pr}"): ${name}"
}

while read -r fork _; do
  consumer "${fork}" rhtas/main "UPSTREAM: <drop>: Replace modules as ci's replaces.lock asks" "Go-Replaces: replaces.lock" || failed=1
done < <(grep -v '^#' "${FORKS_LOCK:-${root}/forks.lock}")
consumer secure-sign-pqc-operator main "Replace modules as ci's replaces.lock ${id} asks" "" || failed=1
exit "${failed}"
