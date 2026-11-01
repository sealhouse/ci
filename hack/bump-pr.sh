#!/usr/bin/env bash
# bump-pr.sh FORK COMMIT IMAGE BRANCH opens the operator bump PR for a fork's pushed image.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

fork="$1" commit="$2" image="$3" branch="$4"
registry="${REGISTRY_HOST:-ghcr.io}"
operator="${gh_org}/secure-sign-pqc-operator"
crane_args=()
case "${registry}" in localhost:*) crane_args=(--insecure) ;; esac

# The inputs come from another repo's workflow: check each against what it claims.
awk '!/^#/ { print $1 }' "${root}/forks.lock" | grep -qx "${fork}" || { echo "${fork} is not a fork" >&2; exit 1; }
[[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || { echo "bad commit ${commit}" >&2; exit 1; }
[[ "${branch}" =~ ^(rhtas/main|release-[0-9]+\.[0-9]+)$ ]] || { echo "bad branch ${branch}" >&2; exit 1; }
re="^${registry}/${gh_org}/([a-z0-9-]+)@(sha256:[0-9a-f]{64})\$"
[[ "${image}" =~ ${re} ]] || { echo "bad image ${image}" >&2; exit 1; }
component="${BASH_REMATCH[1]}" digest="${BASH_REMATCH[2]}"
short="${commit:0:12}"
tagged="$(crane digest "${crane_args[@]}" "${registry}/${gh_org}/${component}:${branch//\//-}-${short}")"
[ "${tagged}" = "${digest}" ] || { echo "${component} ${branch} ${short} is ${tagged}, not ${digest}" >&2; exit 1; }

GH_TOKEN="$(gh_app_token "${BOT_APP_ID:?}" "${BOT_APP_KEY:?}" '{"contents":"write","pull_requests":"write"}' secure-sign-pqc-operator)"
export GH_TOKEN

case "${branch}" in
  release-*) version="${branch#release-}" ;;
  *) version="$(gh_api GET "/repos/${operator}/contents/versions?ref=main" |
    jq -r '.[] | select(.type == "dir") | .name' | grep -E '^[0-9]+\.[0-9]+$' | sort -V | tail -1)" ;;
esac
file="versions/${version}/images.env"
key="$(printf '%s' "${component}" | tr 'a-z-' 'A-Z_')_IMAGE"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
gh_api GET "/repos/${operator}/contents/${file}?ref=main" | jq -r .content | base64 -d >"${work}/images.env"
if ! grep -q "^${key}=" "${work}/images.env"; then
  echo "operator ${file} has no ${key}: there is no bump"
  exit 0
fi
if grep -qx "${key}=${image}" "${work}/images.env"; then
  echo "operator ${file} already pins ${image}"
  exit 0
fi
sed -i "s#^${key}=.*#${key}=${image}#" "${work}/images.env"

slug="$(printf '%s' "${key}" | tr 'A-Z_' 'a-z-')"
bump="bump/${version}-${slug}-${short}"
new="$(gh_commit "${operator}" main "Bump the ${version} ${component} image to ${fork} ${branch} ${short}" "${file}=${work}/images.env")"
jq -n --arg r "refs/heads/${bump}" --arg s "${new}" '{ref: $r, sha: $s}' | gh_api POST "/repos/${operator}/git/refs" - >/dev/null
pr="$(jq -n --arg t "Bump the ${version} ${component} image to ${fork} ${branch} ${short}" --arg h "${bump}" \
  '{title: $t, head: $h, base: "main"}' | gh_api POST "/repos/${operator}/pulls" -)"
echo "operator PR $(jq -r .number <<<"${pr}"): ${bump}"

# A newer image makes an open bump of the same key stale.
gh_api GET "/repos/${operator}/pulls?state=open&base=main&per_page=100" |
  jq -r --arg p "bump/${version}-${slug}-" --arg b "${bump}" \
    '.[] | select((.head.ref | startswith($p)) and .head.ref != $b) | "\(.number) \(.head.ref)"' |
  while read -r number ref; do
    gh_api PATCH "/repos/${operator}/pulls/${number}" '{"state":"closed"}' >/dev/null
    gh_api DELETE "/repos/${operator}/git/refs/heads/${ref}" >/dev/null
    echo "closed stale PR ${number}: ${ref}"
  done

gh_graphql 'mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: SQUASH}) { clientMutationId } }' \
  "$(jq -r .node_id <<<"${pr}")"
