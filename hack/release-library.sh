#!/usr/bin/env bash
# release-library.sh FORK SUBDIR REASON DROP_WHEN tags a fork's module and opens the replaces.lock PR.
# release-library.sh --auto releases each inventory line its fork has changed.
# release-library.sh --removable prints the lines upstream has released the fix for.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"
# shellcheck disable=SC1091
source "${root}/hack/replace-lib.sh"

org="github.com/${gh_org}"
branch=rhtas/main
base="${SEALHOUSE_GIT_BASE:-https://github.com/${gh_org}}"
forks="${FORKS_LOCK:-${root}/forks.lock}"
sealhouse="$(mktemp -d)"
trap 'rm -rf "${sealhouse}"' EXIT

clone_fork() {
  local dir="${sealhouse}/$1" url
  [ ! -d "${dir}" ] || return 0
  url="$(awk -v f="$1" '$1 == f { print $2 }' "${forks}")"
  [ -n "${url}" ] || { echo "$1 is not a fork" >&2; return 1; }
  git clone -q --filter=blob:none -b "${branch}" "${base}/$1.git" "${dir}"
  git -C "${dir}" remote add upstream "${url}"
}

push_tag() {
  local token
  token="$(gh_app_token "${SYNC_APP_ID:?}" "${SYNC_APP_KEY:?}" '{"contents":"write"}' "$1")"
  # shellcheck disable=SC2016 # expanded by the credential helper
  GH_TOKEN="${token}" git -C "${sealhouse}/$1" -c credential.helper='!f() { echo username=x-access-token; echo "password=${GH_TOKEN}"; }; f' \
    push -q origin "refs/tags/$2"
}

# inventory_pr MODULE FORK_MODULE VERSION REASON DROP opens ci's replaces.lock PR.
inventory_pr() {
  local module="$1" line="$1 $2 $3 $4 $5" work slug new pr
  work="$(mktemp -d)"
  GH_TOKEN="$(gh_app_token "${BOT_APP_ID:?}" "${BOT_APP_KEY:?}" '{"contents":"write","pull_requests":"write"}' ci)"
  export GH_TOKEN
  gh_file "${gh_org}/ci" replaces.lock >"${work}/current"
  awk -v m="${module}" -v l="${line}" '$1 == m { print l; done = 1; next } { print } END { if (!done) print l }' "${work}/current" >"${work}/next"
  replaces_inventory "${work}/next" >/dev/null
  if cmp -s "${work}/current" "${work}/next"; then
    rm -rf "${work}"
    return 0
  fi
  slug="$(tr -c 'a-zA-Z0-9.\n' - <<<"${module}")"
  new="$(gh_commit "${gh_org}/ci" main "replaces.lock: ${module} => $2 $3" "replaces.lock=${work}/next")"
  jq -n --arg r "refs/heads/replaces-lock/${slug}-$3" --arg s "${new}" '{ref: $r, sha: $s}' | gh_api POST "/repos/${gh_org}/ci/git/refs" - >/dev/null
  pr="$(jq -n --arg t "replaces.lock: ${module} => $2 $3" --arg h "replaces-lock/${slug}-$3" \
    '{title: $t, head: $h, base: "main"}' | gh_api POST "/repos/${gh_org}/ci/pulls" -)"
  gh_graphql 'mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: SQUASH}) { clientMutationId } }' \
    "$(jq -r .node_id <<<"${pr}")"
  rm -rf "${work}"
  echo "ci PR $(jq -r .number <<<"${pr}"): ${line}"
}

# publish FORK SUBDIR REASON DROP
publish() {
  local module fork_module version
  read -r module fork_module version < <(release "${sealhouse}/$1" "$2")
  push_tag "$1" "$(tag_prefix "$2")${version}"
  inventory_pr "${module}" "${fork_module}" "${version}" "$3" "$4"
}

case "${1:-}" in
  --removable)
    while read -r _ fork_module _; do
      clone_fork "$(cut -d/ -f3 <<<"${fork_module}")"
    done < <(replaces_inventory)
    removable
    ;;
  --auto)
    while read -r module fork_module version reason drop; do
      fork="$(cut -d/ -f3 <<<"${fork_module}")"
      clone_fork "${fork}"
      rest="${fork_module#"${org}/${fork}"}"
      subdir="$(sed -E 's#/v([2-9]|[1-9][0-9]+)$##; s#^/##' <<<"${rest}")"
      subdir="${subdir:-.}"
      tag="$(tag_prefix "${subdir}")${version}"
      if git -C "${sealhouse}/${fork}" rev-parse -q --verify "refs/tags/${tag}" >/dev/null &&
        ! changed "${sealhouse}/${fork}" "${subdir}" "${tag}"; then
        echo "${module}: nothing new for consumers since ${tag}"
        continue
      fi
      publish "${fork}" "${subdir}" "${reason}" "${drop}"
    done < <(replaces_inventory)
    ;;
  -*) echo "usage: $0 FORK SUBDIR REASON DROP_WHEN | --auto | --removable" >&2; exit 2 ;;
  *)
    [ $# -eq 4 ] || { echo "usage: $0 FORK SUBDIR REASON DROP_WHEN | --auto | --removable" >&2; exit 2; }
    clone_fork "$1"
    publish "$@"
    ;;
esac
