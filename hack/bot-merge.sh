#!/usr/bin/env bash
# bot-merge.sh [REPO BASE] merges green ci-pin, replaces, vulns and bump PRs that only sealhouse-bot wrote, on every caller or on REPO.
# On a fork it brings the oldest green one that rhtas/main has moved past up to date, once no other is running its checks;
# one that failed only for a replace rhtas/main has since taken counts as green for this.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

# Each caller is its own process, so set -e holds inside it.
if [ $# -eq 0 ]; then
  failed=0
  while read -r fork _; do
    "$0" "${fork}" rhtas/main || failed=1
  done < <(grep -v '^#' "${FORKS_LOCK:-${root}/forks.lock}")
  "$0" secure-sign-pqc-operator main || failed=1
  exit "${failed}"
fi

repo="$1" base="$2"
full="${gh_org}/${repo}"
bot="sealhouse-bot[bot]"
GH_TOKEN="$(gh_app_token "${BOT_APP_ID:?}" "${BOT_APP_KEY:?}" '{"contents":"write","pull_requests":"write","checks":"read","actions":"read","workflows":"write"}' "${repo}" ci)"
export GH_TOKEN

pulls="$(gh_api GET "/repos/${full}/pulls?state=open&base=${base}&per_page=100")"
# A merge would move rhtas/main under the sync PR, which only fast-forwards.
if [ "$(jq '[.[] | select(.head.ref == "rhtas/sync")] | length' <<<"${pulls}")" -gt 0 ]; then
  echo "${repo}: waiting for the sync PR"
  exit 0
fi

# pin_only PIN reads a PR's files and passes when each one only moves sealhouse-*.yaml pins to PIN.
pin_only() {
  jq -e --arg p "$1" '
    def pins: sub("(?<a>sealhouse/ci/\\.github/workflows/[a-z-]+\\.yaml@)[0-9a-f]{40}"; "\(.a)PIN") | sub("^(?<a> *ci-ref: )[0-9a-f]{40}"; "\(.a)PIN");
    def moves_pins:
      ((.patch // "") | split("\n") | map(select(test("^[-+]")))) as $l |
      ($l | map(select(startswith("-")) | .[1:])) as $old | ($l | map(select(startswith("+")) | .[1:])) as $new |
      ($new | length) > 0 and ($old | map(pins)) == ($new | map(pins)) and all($new[]; (pins != .) and contains($p));
    length > 0 and all(.[];
      (.filename | test("^\\.github/workflows/sealhouse-[a-z-]+\\.yaml$")) and .status == "modified" and moves_pins)' >/dev/null
}

# bump_only REF reads a PR's files and passes when they only move REF's image to a digest of the image REF names.
bump_only() {
  [[ "$1" =~ ^bump/([0-9]+\.[0-9]+)-(([a-z0-9-]+)-image)-[0-9a-f]{12}$ ]] || return 1
  jq -e --arg f "versions/${BASH_REMATCH[1]}/images.env" --arg k "$(tr 'a-z-' 'A-Z_' <<<"${BASH_REMATCH[2]}")=" \
    --arg i "${REGISTRY_HOST:-ghcr.io}/${gh_org}/${BASH_REMATCH[3]}@sha256:" '
    ((.[0].patch // "") | split("\n") | map(select(test("^[-+]")))) as $l |
    length == 1 and .[0].filename == $f and .[0].status == "modified" and
      ($l | length) == 2 and ($l[0] | startswith("-" + $k)) and ($l[1] | test("^\\+" + $k + $i + "[0-9a-f]{64}$"))' >/dev/null
}

waiting="" stale=""
while read -r number ref sha author; do
  [ -n "${number}" ] || continue
  if [ "${author}" != "${bot}" ]; then
    echo "${repo}: PR ${number} (${ref}) is not from ${bot}: it needs a maintainer"
    continue
  fi
  commits="$(gh_api GET "/repos/${full}/pulls/${number}/commits?per_page=100")"
  if ! jq -e --arg b "${bot}" 'length > 0 and all(.[]; .author.login == $b and (.committer.login == "web-flow" or .committer.login == $b) and .commit.verification.verified)' <<<"${commits}" >/dev/null; then
    echo "${repo}: PR ${number} (${ref}) has a commit ${bot} did not sign: it needs a maintainer"
    continue
  fi
  checks="$(gh_api GET "/repos/${full}/commits/${sha}/check-runs?per_page=100" | jq '[.check_runs[] | select(.name | contains("hand-off") | not)]')"
  if [ "$(jq length <<<"${checks}")" -eq 0 ] || [ "$(jq '[.[] | select(.status != "completed")] | length' <<<"${checks}")" -gt 0 ]; then
    echo "${repo}: PR ${number} (${ref}) is waiting for its checks"
    waiting="${number}"
    continue
  fi
  bad="$(jq -r '[.[] | select(.conclusion != "success" and .conclusion != "skipped") | .name] | join(", ")' <<<"${checks}")"
  if [ -n "${bad}" ]; then
    if [ "${base}" = rhtas/main ] && replace_retry "${full}" "${base}" "${sha}" "${checks}"; then
      echo "${repo}: PR ${number} (${ref}) failed only for a replace ${base} has since taken"
      [ -n "${stale}" ] || stale="${number} ${sha} ${ref}"
    else
      echo "${repo}: PR ${number} (${ref}) needs a maintainer: ${bad}"
    fi
    continue
  fi
  files="$(gh_api GET "/repos/${full}/pulls/${number}/files?per_page=100")"
  case "${ref}" in
    ci-pin/*)
      pin="$(jq -r '[.[].patch // "" | split("\n")[] | select(startswith("+")) | capture("(?<s>[0-9a-f]{40})").s] | first // ""' <<<"${files}")"
      if [[ ! "${pin}" == "${ref#ci-pin/}"* ]] || ! pin_only "${pin}" <<<"${files}" ||
        ! gh_api GET "/repos/${gh_org}/ci/compare/${pin}...main" | jq -e '.status == "ahead" or .status == "identical"' >/dev/null; then
        echo "${repo}: PR ${number} (${ref}) changes more than the pin to a ci main commit: it needs a maintainer"
        continue
      fi
      ;;
    bump/*)
      if ! bump_only "${ref}" <<<"${files}"; then
        echo "${repo}: PR ${number} (${ref}) changes more than its image's digest: it needs a maintainer"
        continue
      fi
      ;;
    replaces/* | vulns/*)
      if ! jq -e 'length > 0 and all(.[]; .filename | test("(^|/)go\\.(mod|sum)$"))' <<<"${files}" >/dev/null; then
        echo "${repo}: PR ${number} (${ref}) changes more than go.mod and go.sum: it needs a maintainer"
        continue
      fi
      ;;
  esac
  # A fork merges only what was tested on its rhtas/main; the operator's bump-update.sh does this for main.
  if [ "${base}" = rhtas/main ]; then
    behind="$(gh_api GET "/repos/${full}/compare/${base}...${sha}" | jq -r .behind_by)"
    if [ "${behind}" -gt 0 ]; then
      echo "${repo}: PR ${number} (${ref}) is ${behind} behind ${base}"
      [ -n "${stale}" ] || stale="${number} ${sha} ${ref}"
      continue
    fi
  fi
  # The squash keeps the first commit's trailers, which a sync needs to regenerate the carry.
  message="$(jq -r '.[0].commit.message' <<<"${commits}")"
  if ! jq -n --arg s "${sha}" --arg t "${message%%$'\n'*}" --arg m "$(sed '1,/^$/d' <<<"${message}")" \
    '{merge_method: "squash", sha: $s, commit_title: $t, commit_message: $m}' |
    gh_api PUT "/repos/${full}/pulls/${number}/merge" - >/dev/null; then
    echo "${repo}: PR ${number} (${ref}) could not merge yet"
    continue
  fi
  echo "${repo}: merged PR ${number} (${ref})"
done < <(jq -r '[.[] | select(.head.ref | test("^(ci-pin|replaces|vulns|bump)/"))] | sort_by(.number) | .[] | "\(.number) \(.head.ref) \(.head.sha) \(.user.login)"' <<<"${pulls}")

# One update at a time: its lane hands off to the next run, which merges it and updates the next.
[ -n "${stale}" ] || exit 0
read -r number sha ref <<<"${stale}"
if [ -n "${waiting}" ]; then
  echo "${repo}: PR ${number} (${ref}) waits for PR ${waiting}'s checks before it is brought up to date"
elif jq -n --arg s "${sha}" '{expected_head_sha: $s}' | gh_api PUT "/repos/${full}/pulls/${number}/update-branch" - >/dev/null; then
  echo "${repo}: brought PR ${number} (${ref}) up to date with ${base}"
else
  echo "${repo}: PR ${number} (${ref}) could not be brought up to date: it needs a maintainer"
fi
