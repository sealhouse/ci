#!/usr/bin/env bash
# vuln-fix.sh REPO BASE SUMMARY opens a PR on REPO's BASE taking every module vulncheck.sh's SUMMARY
# has a fix for to its fixed version, once vulns.lock lets ci take it. Go's own fixes (stdlib, toolchain) are a manual Go update.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

[ $# -eq 3 ] || { echo "usage: $0 REPO BASE SUMMARY" >&2; exit 2; }
repo="$1" base="$2" summary="$3"
full="${gh_org}/${repo}"
base_url="${SEALHOUSE_GIT_BASE:-https://github.com/${gh_org}}"
work="$(mktemp -d)"
trap 'chmod -R u+w "${work}" 2>/dev/null; rm -rf "${work}"' EXIT
export GOMODCACHE="${GOMODCACHE:-${work}/modcache}"
tree="${work}/${repo}"

# "<osv> <module> <fixed> <main module>" for each module fix vulns.lock lets ci take now.
fixes="$("${root}/hack/vuln-due.sh" "${summary}" |
  sed -nE 's/^fix available: ([^ ]+) in (.+)@[^,]+, fixed in ([^ ]+) \((.*)\)$/\1 \2 \3 \4/p' | awk '$2 != "stdlib" && $2 != "toolchain"')"

GH_TOKEN="$(gh_app_token "${BOT_APP_ID:?}" "${BOT_APP_KEY:?}" '{"contents":"write","pull_requests":"write"}' "${repo}")"
export GH_TOKEN
pulls="$(gh_api GET "/repos/${full}/pulls?state=open&per_page=100" | jq --arg b "${base}" '[.[] | select(.base.ref == $b and (.head.ref | startswith("vulns/")))]')"

# close_except NAME closes the open vulns PRs NAME supersedes.
close_except() {
  local number ref
  while read -r number ref; do
    [ -n "${number}" ] || continue
    jq -n '{state: "closed"}' | gh_api PATCH "/repos/${full}/pulls/${number}" - >/dev/null
    gh_api DELETE "/repos/${full}/git/refs/heads/${ref}" >/dev/null
    echo "${repo}: closed PR ${number} (${ref}), which ${1:-the fixed findings} supersedes"
  done < <(jq -r --arg n "$1" '.[] | select(.head.ref != $n) | "\(.number) \(.head.ref)"' <<<"${pulls}")
}

if [ -z "${fixes}" ]; then
  close_except ""
  echo "${repo}: no module fixes"
  exit 0
fi

git clone -q --filter=blob:none -b "${base}" "${base_url}/${repo}.git" "${tree}"
declare -A dirs
while read -r gomod; do
  dirs["$(go mod edit -json "${tree}/${gomod}" | jq -r .Module.Path)"]="$(dirname "${gomod}")"
done < <(git -C "${tree}" ls-files '*go.mod' 'go.mod' | grep -v '/testdata/' | sort -u)

# The newest fixed version per directory and module: "<dir> <module>@<version>", as a Go-Get trailer takes it.
gets="$(while read -r osv module fixed main; do
  dir="${dirs[${main}]:-}"
  [ -n "${dir}" ] || { echo "${repo}: no go.mod declares ${main}" >&2; exit 1; }
  # A sync regenerates only plain vX.Y.Z bumps.
  if ! [[ "${fixed}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${repo}: ${osv} is fixed in ${module} ${fixed}, which is not vX.Y.Z: it needs a maintainer" >&2
    echo "${osv}" >>"${work}/skipped"
    continue
  fi
  echo "${dir} ${module} ${fixed}"
done <<<"${fixes}" | LC_ALL=C sort -k1,1 -k2,2 -k3,3V | awk '{ last[$1 " " $2] = $3 } END { for (k in last) print k "@" last[k] }' | LC_ALL=C sort)"
# finish fails when a fix was left to a maintainer.
finish() { [ ! -s "${work}/skipped" ] || exit 1; exit 0; }
[ -n "${gets}" ] || finish
osvs="$(awk '{ print $1 }' <<<"${fixes}" | grep -vxF -f <(cat "${work}/skipped" 2>/dev/null) | sort -u | paste -sd, - | sed 's/,/, /g')"

name="vulns/$(sha256sum <<<"${gets}" | cut -c1-12)"
close_except "${name}"
read -r open sha < <(jq -r --arg n "${name}" '.[] | select(.head.ref == $n) | "\(.number) \(.head.sha)"' <<<"${pulls}") || true
if [ -n "${open}" ]; then
  # A PR its base has moved away from cannot merge: open it again on the new base.
  if [ "$(gh_api GET "/repos/${full}/pulls/${open}" | jq -r .mergeable)" != false ]; then
    bad="$(gh_api GET "/repos/${full}/commits/${sha}/check-runs?per_page=100" |
      jq -r '[.check_runs[] | select((.name | contains("hand-off") | not) and .status == "completed" and .conclusion != "success" and .conclusion != "skipped") | .name] | join(", ")')"
    if [ -n "${bad}" ]; then
      echo "${repo}: PR ${open} (${name}) needs a maintainer: ${bad}" >&2
      exit 1
    fi
    echo "${repo}: ${name} is open"
    finish
  fi
  jq -n '{state: "closed"}' | gh_api PATCH "/repos/${full}/pulls/${open}" - >/dev/null
  gh_api DELETE "/repos/${full}/git/refs/heads/${name}" >/dev/null
  echo "${repo}: closed PR ${open} (${name}), which no longer merges"
fi

while read -r dir modver; do
  go -C "${tree}/${dir}" get "${modver}" >/dev/null 2>&1 && go -C "${tree}/${dir}" mod tidy >/dev/null 2>&1 ||
    { echo "${repo}: go get ${modver} in ${dir} failed" >&2; exit 1; }
done <<<"${gets}"
specs=()
while read -r f; do
  specs+=("${f}=${tree}/${f}")
done < <(git -C "${tree}" status --porcelain -- ':(glob)**/go.mod' ':(glob)**/go.sum' | cut -c4-)
[ "${#specs[@]}" -gt 0 ] || { echo "${repo}: go get changed nothing for ${osvs}" >&2; exit 1; }

if [ "${base}" = rhtas/main ]; then
  headline="UPSTREAM: <drop>: Fix ${osvs}"
  body="$(sed 's/^/Go-Get: /' <<<"${gets}")"
else
  headline="Fix ${osvs}"
  body=""
fi
message="${headline}${body:+$'\n\n'${body}}"
new="$(gh_commit "${full}" "${base}" "${message}" "${specs[@]}")"
jq -n --arg r "refs/heads/${name}" --arg s "${new}" '{ref: $r, sha: $s}' | gh_api POST "/repos/${full}/git/refs" - >/dev/null
pr="$(jq -n --arg t "${headline}" --arg h "${name}" --arg b "${base}" --arg d "$(sed 's/^\([^ ]*\) /- `\1`: /' <<<"${gets}")" \
  '{title: $t, head: $h, base: $b, body: $d}' | gh_api POST "/repos/${full}/pulls" -)"
# The squash keeps the trailers, which a sync needs to regenerate the carry.
gh_graphql "mutation(\$id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: \$id, mergeMethod: SQUASH, commitHeadline: $(jq -n --arg s "${headline}" '$s'), commitBody: $(jq -n --arg s "${body}" '$s')}) { clientMutationId } }" \
  "$(jq -r .node_id <<<"${pr}")"
echo "${repo}: PR $(jq -r .number <<<"${pr}"): ${name} fixes ${osvs}"
finish
