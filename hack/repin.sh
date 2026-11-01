#!/usr/bin/env bash
# repin.sh SHA opens a PR on every caller that does not pin ci at SHA.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

sha="$1"
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "bad commit ${sha}" >&2; exit 1; }
short="${sha:0:12}"

# Each caller is its own process, so set -e holds inside it.
if [ $# -eq 1 ]; then
  failed=0
  while read -r fork _; do
    "$0" "${sha}" "${fork}" rhtas/main "UPSTREAM: <drop>: Pin ci ${short}" "Ci-Pin: ${sha}" || failed=1
  done < <(grep -v '^#' "${FORKS_LOCK:-${root}/forks.lock}")
  "$0" "${sha}" secure-sign-pqc-operator main "Pin ci ${short}" "" || failed=1
  exit "${failed}"
fi

repo="$2" base="$3" headline="$4" body="$5"
full="${gh_org}/${repo}"
name="ci-pin/${short}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
GH_TOKEN="$(gh_app_token "${BOT_APP_ID:?}" "${BOT_APP_KEY:?}" '{"contents":"write","pull_requests":"write","workflows":"write"}' "${repo}")"
export GH_TOKEN

pulls="$(gh_api GET "/repos/${full}/pulls?state=open&per_page=100" |
  jq --arg b "${base}" '[.[] | select(.base.ref == $b and (.head.ref | startswith("ci-pin/")))]')"
while read -r number ref; do
  [ -n "${number}" ] || continue
  gh_api PATCH "/repos/${full}/pulls/${number}" '{"state":"closed"}' >/dev/null
  gh_api DELETE "/repos/${full}/git/refs/heads/${ref}" >/dev/null
  echo "${repo}: closed PR ${number} (${ref})"
done < <(jq -r --arg n "${name}" '.[] | select(.head.ref != $n) | "\(.number) \(.head.ref)"' <<<"${pulls}")
if [ "$(jq --arg n "${name}" '[.[] | select(.head.ref == $n)] | length' <<<"${pulls}")" -gt 0 ]; then
  echo "${repo}: ${name} is open"
  exit 0
fi

callers="$(gh_api GET "/repos/${full}/contents/.github/workflows?ref=${base}" |
  jq -r '.[] | select(.name | test("^sealhouse-.*\\.yaml$")) | .name')"
specs=()
for f in ${callers}; do
  gh_api GET "/repos/${full}/contents/.github/workflows/${f}?ref=${base}" | jq -r .content | base64 -d >"${work}/${f}"
  cp "${work}/${f}" "${work}/${f}.old"
  "${root}/hack/pin-ci.sh" "${sha}" "${work}/${f}"
  cmp -s "${work}/${f}" "${work}/${f}.old" || specs+=(".github/workflows/${f}=${work}/${f}")
done
if [ "${#specs[@]}" -eq 0 ]; then
  echo "${repo}: already pins ${short}"
  exit 0
fi
new="$(gh_commit "${full}" "${base}" "${headline}${body:+$'\n\n'${body}}" "${specs[@]}")"
jq -n --arg r "refs/heads/${name}" --arg s "${new}" '{ref: $r, sha: $s}' | gh_api POST "/repos/${full}/git/refs" - >/dev/null
pr="$(jq -n --arg t "${headline}" --arg h "${name}" --arg b "${base}" '{title: $t, head: $h, base: $b}' | gh_api POST "/repos/${full}/pulls" -)"
# The squash must keep the trailer, or a sync would not regenerate the pin.
gh_graphql "mutation(\$id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: \$id, mergeMethod: SQUASH, commitHeadline: \"${headline}\", commitBody: \"${body}\"}) { clientMutationId } }" \
  "$(jq -r .node_id <<<"${pr}")"
echo "${repo}: PR $(jq -r .number <<<"${pr}"): ${name}"
